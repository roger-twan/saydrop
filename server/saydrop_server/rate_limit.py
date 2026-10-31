import hashlib
import hmac
import secrets
import time
from collections import deque

from saydrop_server.config import Settings
from saydrop_server.errors import ApiError


class RateLimiter:
    """Monotonic sliding windows. IPs are keyed with a process-only key, never persisted."""
    def __init__(self, settings: Settings, clock=time.monotonic):
        self.settings = settings
        self.clock = clock
        self.key = secrets.token_bytes(32)
        self.buckets: dict[str, tuple[deque, float]] = {}
        # A derived finite ceiling, not an unbounded table of source addresses.
        self.max_buckets = settings.register_global_hour + settings.ip_minute * settings.max_active_tasks + 1

    def ip_key(self, ip: str) -> str:
        return hmac.new(self.key, ip.encode(), hashlib.sha256).hexdigest()

    def cleanup(self):
        now = self.clock()
        for key, (events, window) in list(self.buckets.items()):
            while events and events[0] <= now - window:
                events.popleft()
            if not events:
                del self.buckets[key]

    def check(self, dimensions: list[tuple[str, int, float]]):
        self.cleanup()
        now = self.clock()
        missing = {key for key, _, _ in dimensions if key not in self.buckets}
        if len(self.buckets) + len(missing) > self.max_buckets:
            raise ApiError("rate_limited", 429, retryable=True)
        for key, limit, _ in dimensions:
            current = self.buckets.get(key)
            if current and len(current[0]) >= limit:
                raise ApiError("rate_limited", 429, retryable=True)
        for key, _, window in dimensions:
            if key not in self.buckets:
                self.buckets[key] = (deque(), window)
            self.buckets[key][0].append(now)

    def registration(self, ip: str):
        self.check([("register-global", self.settings.register_global_hour, 3600),
                    ("register-ip:" + self.ip_key(ip), self.settings.register_ip_hour, 3600)])

    def ip_request(self, ip: str):
        self.check([("request-ip:" + self.ip_key(ip), self.settings.ip_minute, 60)])

    def installation(self, owner: str):
        self.check([("installation:" + owner, self.settings.installation_minute, 60)])
