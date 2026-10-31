#include "SaydropRealtime.h"

#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

struct SDRTSPSCRing {
    uint32_t capacity_frames;
    uint32_t channels;
    float *storage;
    _Atomic uint64_t read_index;
    _Atomic uint64_t write_index;
    _Atomic bool first_buffer;
    _Atomic bool overflow;
    _Atomic bool invalid_input;
};

static bool sdrt_valid_ring(const SDRTSPSCRing *ring) {
    return ring != NULL && ring->storage != NULL && ring->capacity_frames > 0U && ring->channels > 0U;
}

static uint64_t sdrt_used_frames(const SDRTSPSCRing *ring, uint64_t write_index, uint64_t read_index) {
    (void)ring;
    return write_index - read_index;
}

static bool sdrt_reserve_write(SDRTSPSCRing *ring, uint32_t frame_count, uint64_t *write_index_out) {
    if (!sdrt_valid_ring(ring) || frame_count == 0U || frame_count > ring->capacity_frames) {
        if (ring != NULL) {
            atomic_store_explicit(&ring->invalid_input, true, memory_order_relaxed);
        }
        return false;
    }

    const uint64_t write_index = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    const uint64_t read_index = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    const uint64_t used = sdrt_used_frames(ring, write_index, read_index);

    if (used > ring->capacity_frames || frame_count > ring->capacity_frames - used) {
        atomic_store_explicit(&ring->overflow, true, memory_order_relaxed);
        return false;
    }

    *write_index_out = write_index;
    return true;
}

static void sdrt_commit_write(SDRTSPSCRing *ring, uint64_t write_index, uint32_t frame_count) {
    atomic_store_explicit(&ring->write_index, write_index + frame_count, memory_order_release);
    atomic_store_explicit(&ring->first_buffer, true, memory_order_release);
}

SDRTSPSCRing *sdrt_spsc_ring_create(uint32_t capacity_frames, uint32_t channels) {
    if (capacity_frames == 0U || channels == 0U || channels > 32U) {
        return NULL;
    }

    const size_t samples = (size_t)capacity_frames * (size_t)channels;
    if (samples / channels != capacity_frames || samples > SIZE_MAX / sizeof(float)) {
        return NULL;
    }

    SDRTSPSCRing *ring = calloc(1U, sizeof(*ring));
    if (ring == NULL) {
        return NULL;
    }

    ring->storage = calloc(samples, sizeof(float));
    if (ring->storage == NULL) {
        free(ring);
        return NULL;
    }

    ring->capacity_frames = capacity_frames;
    ring->channels = channels;
    atomic_init(&ring->read_index, 0U);
    atomic_init(&ring->write_index, 0U);
    atomic_init(&ring->first_buffer, false);
    atomic_init(&ring->overflow, false);
    atomic_init(&ring->invalid_input, false);
    if (!atomic_is_lock_free(&ring->read_index) || !atomic_is_lock_free(&ring->write_index) ||
        !atomic_is_lock_free(&ring->first_buffer) || !atomic_is_lock_free(&ring->overflow) ||
        !atomic_is_lock_free(&ring->invalid_input)) {
        free(ring->storage);
        free(ring);
        return NULL;
    }
    return ring;
}

void sdrt_spsc_ring_destroy(SDRTSPSCRing *ring) {
    if (ring == NULL) {
        return;
    }
    free(ring->storage);
    ring->storage = NULL;
    free(ring);
}

bool sdrt_spsc_ring_write_interleaved_f32(SDRTSPSCRing *ring, const float *frames, uint32_t frame_count) {
    if (frames == NULL) {
        if (ring != NULL) {
            atomic_store_explicit(&ring->invalid_input, true, memory_order_relaxed);
        }
        return false;
    }

    uint64_t write_index = 0U;
    if (!sdrt_reserve_write(ring, frame_count, &write_index)) {
        return false;
    }

    const uint32_t channels = ring->channels;
    const uint32_t first_slot = (uint32_t)(write_index % ring->capacity_frames);
    const uint32_t first_frames = frame_count < ring->capacity_frames - first_slot
        ? frame_count
        : ring->capacity_frames - first_slot;
    const size_t first_samples = (size_t)first_frames * channels;

    memcpy(ring->storage + (size_t)first_slot * channels, frames, first_samples * sizeof(float));
    if (first_frames < frame_count) {
        const uint32_t second_frames = frame_count - first_frames;
        memcpy(ring->storage, frames + first_samples, (size_t)second_frames * channels * sizeof(float));
    }

    sdrt_commit_write(ring, write_index, frame_count);
    return true;
}

bool sdrt_spsc_ring_write_planar_f32(SDRTSPSCRing *ring, float * const *channel_frames, uint32_t frame_count) {
    if (channel_frames == NULL) {
        if (ring != NULL) {
            atomic_store_explicit(&ring->invalid_input, true, memory_order_relaxed);
        }
        return false;
    }

    uint64_t write_index = 0U;
    if (!sdrt_reserve_write(ring, frame_count, &write_index)) {
        return false;
    }

    const uint32_t channels = ring->channels;
    for (uint32_t channel = 0U; channel < channels; ++channel) {
        if (channel_frames[channel] == NULL) {
            atomic_store_explicit(&ring->invalid_input, true, memory_order_relaxed);
            return false;
        }
    }

    for (uint32_t frame = 0U; frame < frame_count; ++frame) {
        const uint32_t slot = (uint32_t)((write_index + frame) % ring->capacity_frames);
        float *destination = ring->storage + (size_t)slot * channels;
        for (uint32_t channel = 0U; channel < channels; ++channel) {
            destination[channel] = channel_frames[channel][frame];
        }
    }

    sdrt_commit_write(ring, write_index, frame_count);
    return true;
}

uint32_t sdrt_spsc_ring_read_interleaved_f32(SDRTSPSCRing *ring, float *destination, uint32_t maximum_frames) {
    if (!sdrt_valid_ring(ring) || destination == NULL || maximum_frames == 0U) {
        return 0U;
    }

    const uint64_t read_index = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    const uint64_t write_index = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    const uint64_t available = sdrt_used_frames(ring, write_index, read_index);
    if (available == 0U || available > ring->capacity_frames) {
        return 0U;
    }

    const uint32_t frame_count = available < maximum_frames ? (uint32_t)available : maximum_frames;
    const uint32_t channels = ring->channels;
    const uint32_t first_slot = (uint32_t)(read_index % ring->capacity_frames);
    const uint32_t first_frames = frame_count < ring->capacity_frames - first_slot
        ? frame_count
        : ring->capacity_frames - first_slot;
    const size_t first_samples = (size_t)first_frames * channels;

    memcpy(destination, ring->storage + (size_t)first_slot * channels, first_samples * sizeof(float));
    if (first_frames < frame_count) {
        const uint32_t second_frames = frame_count - first_frames;
        memcpy(destination + first_samples, ring->storage, (size_t)second_frames * channels * sizeof(float));
    }

    atomic_store_explicit(&ring->read_index, read_index + frame_count, memory_order_release);
    return frame_count;
}

uint32_t sdrt_spsc_ring_available_frames(const SDRTSPSCRing *ring) {
    if (!sdrt_valid_ring(ring)) {
        return 0U;
    }
    const uint64_t read_index = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    const uint64_t write_index = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    const uint64_t available = sdrt_used_frames(ring, write_index, read_index);
    return available <= ring->capacity_frames ? (uint32_t)available : 0U;
}

void sdrt_spsc_ring_reset_first_buffer(SDRTSPSCRing *ring) {
    if (ring != NULL) {
        atomic_store_explicit(&ring->first_buffer, false, memory_order_release);
    }
}

bool sdrt_spsc_ring_has_first_buffer(const SDRTSPSCRing *ring) {
    return ring != NULL && atomic_load_explicit(&ring->first_buffer, memory_order_acquire);
}

bool sdrt_spsc_ring_take_overflow(SDRTSPSCRing *ring) {
    return ring != NULL && atomic_exchange_explicit(&ring->overflow, false, memory_order_acq_rel);
}

void sdrt_spsc_ring_mark_invalid_input(SDRTSPSCRing *ring) {
    if (ring != NULL) {
        atomic_store_explicit(&ring->invalid_input, true, memory_order_relaxed);
    }
}

bool sdrt_spsc_ring_take_invalid_input(SDRTSPSCRing *ring) {
    return ring != NULL && atomic_exchange_explicit(&ring->invalid_input, false, memory_order_acq_rel);
}

uint32_t sdrt_spsc_ring_capacity_frames(const SDRTSPSCRing *ring) {
    return sdrt_valid_ring(ring) ? ring->capacity_frames : 0U;
}

uint32_t sdrt_spsc_ring_channel_count(const SDRTSPSCRing *ring) {
    return sdrt_valid_ring(ring) ? ring->channels : 0U;
}
