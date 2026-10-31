import asyncio
from datetime import timedelta

import pytest
from test_api import FakeProvider
from test_storage import make_store

from saydrop_server.config import Settings
from saydrop_server.errors import ApiError
from saydrop_server.rate_limit import RateLimiter
from saydrop_server.storage import Store, migrate, process_lock
from saydrop_server.tasks import TaskManager


def test_registration_rate_limit_and_short_ip_ttl(tmp_path):
    store, _, _ = make_store(tmp_path)
    now = [100.0]
    limiter = RateLimiter(store.settings, clock=lambda: now[0])
    for _ in range(5):
        limiter.registration("192.0.2.1")
    with pytest.raises(ApiError, match="rate_limited"):
        limiter.registration("192.0.2.1")
    assert "192.0.2.1" not in repr(limiter.buckets)
    now[0] += 3600
    limiter.cleanup()
    assert not limiter.buckets
    limiter.registration("192.0.2.1")


def test_global_registration_and_installation_rate(tmp_path):
    store, owner, _ = make_store(tmp_path)
    limiter = RateLimiter(store.settings)
    for i in range(100):
        limiter.registration(f"192.0.2.{i}")
    with pytest.raises(ApiError, match="rate_limited"):
        limiter.registration("198.51.100.1")
    for _ in range(60):
        limiter.installation(owner)
    with pytest.raises(ApiError, match="rate_limited"):
        limiter.installation(owner)


def test_single_process_lock_and_explicit_migration(tmp_path):
    path = tmp_path / "metadata.sqlite3"
    with process_lock(path):
        with pytest.raises(RuntimeError, match="one process"):
            with process_lock(path):
                pass
    settings = Settings(token_pepper="p" * 64, fingerprint_key="f" * 64, database_path=path)
    with pytest.raises(RuntimeError, match="migrate"):
        Store(settings)
    migrate(path)
    migrate(path)  # migration command itself is idempotent
    store = Store(settings)
    with store.engine.connect() as conn:
        assert conn.exec_driver_sql("PRAGMA journal_mode").scalar_one() == "wal"
        assert conn.exec_driver_sql("PRAGMA foreign_keys").scalar_one() == 1
        assert conn.exec_driver_sql("PRAGMA user_version").scalar_one() == 3
    store.engine.dispose()


def test_bad_or_zero_budget_fail_closed(tmp_path):
    env = tmp_path / ".env"
    for value in ["", "wrong", "-1", "0"]:
        env.write_text("SAYDROP_TOKEN_PEPPER=" + "p" * 64 + "\nSAYDROP_FINGERPRINT_KEY=" + "f" * 64 +
                       "\nSAYDROP_DAILY_BUDGET_UNITS=" + value + "\n")
        settings = Settings.load(env)
        assert not settings.budget_available()


def test_reserved_orphan_released_after_restart_deadline(tmp_path):
    store, owner, now = make_store(tmp_path)
    store.reserve(owner, "orphan", "f", "raw")
    store.recover()
    assert store.quota(owner)["reserved"] == 1
    now[0] += timedelta(seconds=61)
    store.release_orphaned()
    assert store.status(owner, "orphan")["status"] == "failed"
    assert store.quota(owner)["reserved"] == 0


async def test_cancel_before_dispatch_no_provider_or_quota(tmp_path):
    import time
    store, owner, _ = make_store(tmp_path)
    provider = FakeProvider()
    manager = TaskManager(store, provider, store.settings)
    store.reserve(owner, "cancel-before", "f", "raw")
    manager.start(owner, "cancel-before", b"fake-memory-audio", "raw", time.monotonic() + 60)
    store.cancel(owner, "cancel-before")
    manager.cancel(owner, "cancel-before")
    await asyncio.sleep(0)
    await asyncio.sleep(0)
    assert provider.stt_calls == 0
    assert store.quota(owner)["used"] == 0 and store.quota(owner)["reserved"] == 0
    assert store.status(owner, "cancel-before")["status"] == "cancelled"
    await manager.shutdown()


async def test_stt_timeout_unknown_without_replay(tmp_path):
    import time
    store, owner, _ = make_store(tmp_path)
    store.settings.stt_timeout = 0.01
    provider = FakeProvider()
    provider.gate = asyncio.Event()
    manager = TaskManager(store, provider, store.settings)
    store.reserve(owner, "timeout", "f", "raw")
    manager.start(owner, "timeout", b"fake-memory-audio", "raw", time.monotonic() + 60)
    await asyncio.gather(*manager.jobs.values())
    assert store.status(owner, "timeout")["status"] == "unknown"
    assert store.quota(owner)["used"] == 1 and provider.stt_calls == 1
    _, new = store.reserve(owner, "timeout", "f", "raw")
    assert not new
    await manager.shutdown()


async def test_global_task_capacity_no_queue(tmp_path):
    import time
    store, _, _ = make_store(tmp_path)
    provider = FakeProvider()
    provider.gate = asyncio.Event()
    manager = TaskManager(store, provider, store.settings)
    owners = [store.register("0.1", "macos-arm64")[0] for _ in range(5)]
    for i, owner in enumerate(owners[:4]):
        manager.claim_upload()
        assert manager.has_result_capacity()
        store.reserve(owner, str(i), "f", "raw")
        manager.start(owner, str(i), b"fake-memory-audio", "raw", time.monotonic() + 60)
        manager.uploads -= 1
    with pytest.raises(ApiError, match="rate_limited"):
        manager.claim_upload()
    assert len(manager.jobs) == 4
    await manager.shutdown()
