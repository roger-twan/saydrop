#ifndef SAYDROP_REALTIME_H
#define SAYDROP_REALTIME_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque, preallocated single-producer/single-consumer PCM ring.
///
/// The producer is the realtime audio tap. It may only call one of the write
/// functions. The consumer is a single non-realtime conversion worker. Frames
/// are stored as interleaved native float32 samples, even when the tap input is
/// planar. A full ring rejects the entire incoming buffer and latches overflow;
/// it never overwrites unread samples.
typedef struct SDRTSPSCRing SDRTSPSCRing;

/// Allocates all ring storage before recording starts. `channels` is limited to
/// 1...32 and `capacity_frames` must be nonzero.
SDRTSPSCRing *sdrt_spsc_ring_create(uint32_t capacity_frames, uint32_t channels);

/// Releases storage after the tap has been removed and the worker has stopped.
void sdrt_spsc_ring_destroy(SDRTSPSCRing *ring);

/// Copies interleaved float32 frames into the ring. Returns false without
/// writing any frame when there is insufficient free capacity or bad input.
bool sdrt_spsc_ring_write_interleaved_f32(
    SDRTSPSCRing *ring,
    const float *frames,
    uint32_t frame_count
);

/// Copies planar float32 frames into the ring, interleaving all native channels
/// in channel order. This supports multichannel AVAudioPCMBuffer input without
/// dropping channels in the realtime tap. Returns false without partial writes
/// on a full ring or invalid input.
bool sdrt_spsc_ring_write_planar_f32(
    SDRTSPSCRing *ring,
    float * const *channel_frames,
    uint32_t frame_count
);

/// Copies up to `maximum_frames` interleaved frames to the non-realtime
/// consumer buffer and returns the number copied.
uint32_t sdrt_spsc_ring_read_interleaved_f32(
    SDRTSPSCRing *ring,
    float *destination,
    uint32_t maximum_frames
);

/// Returns the number of frames currently available to the single consumer.
uint32_t sdrt_spsc_ring_available_frames(const SDRTSPSCRing *ring);

/// Clears the acknowledgement consumed by start/resume before a new tap is
/// installed. The next successful write acknowledges that the hardware path has
/// produced an effective buffer.
void sdrt_spsc_ring_reset_first_buffer(SDRTSPSCRing *ring);

/// Returns whether any successful write occurred since the last reset.
bool sdrt_spsc_ring_has_first_buffer(const SDRTSPSCRing *ring);

/// Atomically consumes the latched full-ring condition. A producer that sees a
/// full ring must return promptly; the non-realtime worker reports the failure
/// and stops capture.
bool sdrt_spsc_ring_take_overflow(SDRTSPSCRing *ring);

/// Latches an unsupported-tap-buffer fault for the worker to report. This is
/// safe for the realtime producer and performs only an atomic store.
void sdrt_spsc_ring_mark_invalid_input(SDRTSPSCRing *ring);

/// Atomically consumes an invalid-input fault latched by the producer.
bool sdrt_spsc_ring_take_invalid_input(SDRTSPSCRing *ring);

/// Exposes immutable ring geometry to the conversion worker.
uint32_t sdrt_spsc_ring_capacity_frames(const SDRTSPSCRing *ring);
uint32_t sdrt_spsc_ring_channel_count(const SDRTSPSCRing *ring);

#ifdef __cplusplus
}
#endif

#endif
