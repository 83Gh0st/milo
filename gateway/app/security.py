import hashlib, time
from collections import defaultdict, deque
import jwt
from fastapi import HTTPException, Request


def device_hash(install_id: str) -> str:
    return hashlib.sha256(install_id.encode()).hexdigest()[:32]


def issue_token(s, install_id: str) -> str:
    now = int(time.time())
    return jwt.encode({"sub": device_hash(install_id), "iat": now, "exp": now + s.token_ttl_s, "typ": "milo"}, s.jwt_secret, algorithm="HS256")


def verify_token(s, token: str) -> str:
    try:
        return jwt.decode(token, s.jwt_secret, algorithms=["HS256"])["sub"]
    except jwt.PyJWTError:
        raise HTTPException(401, {"error": "bad_token"})


class RateLimiter:
    """Per-device sliding minute window plus a UTC-day counter. In-memory: run one replica, or swap for Redis before scaling out."""
    def __init__(self, per_min: int, per_day: int):
        self.per_min, self.per_day = per_min, per_day
        self.win: dict[str, deque] = defaultdict(deque)
        self.day: dict[str, list] = {}
        self.n = 0

    def check(self, key: str) -> None:
        now, today = time.monotonic(), time.strftime("%Y-%m-%d", time.gmtime())
        self.n += 1
        if self.n % 2000 == 0:  # prune idle keys
            self.win = defaultdict(deque, {k: v for k, v in self.win.items() if v and now - v[-1] < 60})
            self.day = {k: v for k, v in self.day.items() if v[0] == today}
        q = self.win[key]
        while q and now - q[0] > 60:
            q.popleft()
        d = self.day.get(key)
        if not d or d[0] != today:
            d = self.day[key] = [today, 0]
        if len(q) >= self.per_min or d[1] >= self.per_day:
            raise HTTPException(429, {"error": "rate_limited"}, headers={"Retry-After": "10"})
        q.append(now)
        d[1] += 1


class DemoLimiter:
    """Per-installation demo quotas for the hosted (deployer-credential) path.

    In-memory like RateLimiter: the gateway is pinned to one container, so
    counts are exact. BYOK (vault) requests never touch this limiter - they
    spend the family's own quota. Keys are device hashes, never install ids,
    keys, audio, or content.
    """

    def __init__(self, *, requests_per_day: int, image_per_day: int, segment_per_day: int,
                 voice_minutes_per_day: float, max_concurrent: int):
        self.requests_per_day = requests_per_day
        self.image_per_day = image_per_day
        self.segment_per_day = segment_per_day
        self.voice_bytes_per_day = int(voice_minutes_per_day * 60 * 48000)  # 24 kHz PCM16 = 48000 B/s
        self.max_concurrent = max_concurrent
        self._day: dict[tuple[str, str], list] = {}  # (device, cap) -> [utc-day, count]
        self._inflight = 0

    def _count(self, device: str, cap: str) -> int:
        today = time.strftime("%Y-%m-%d", time.gmtime())
        d = self._day.get((device, cap))
        if not d or d[0] != today:
            d = self._day[(device, cap)] = [today, 0]
        return d

    def check(self, device: str, capability: str) -> None:
        """Raises 429 demo_quota_exceeded when this installation is out of
        demo allowance for the capability (or overall). Rejected requests
        consume nothing."""
        caps = [("all", self.requests_per_day)]
        if capability == "image":
            caps.append(("image", self.image_per_day))
        if capability == "segment":
            caps.append(("segment", self.segment_per_day))
        rows = [(self._count(device, cap), limit) for cap, limit in caps]
        for d, limit in rows:
            if d[1] >= limit:
                raise HTTPException(429, {"error": "demo_quota_exceeded", "capability": capability,
                                          "message": "Demo limit reached for today. Milo still works offline."},
                                    headers={"Retry-After": "3600"})
        for d, _ in rows:
            d[1] += 1

    def check_voice_bytes(self, device: str, total_bytes: int) -> None:
        if self.voice_bytes_per_day <= 0:
            return
        d = self._count(device, "voice_bytes")
        if d[1] + total_bytes > self.voice_bytes_per_day:
            raise HTTPException(429, {"error": "demo_quota_exceeded", "capability": "voice",
                                      "message": "Demo voice limit reached for today. You can still type."},
                                headers={"Retry-After": "3600"})
        d[1] += total_bytes

    def acquire(self) -> None:
        if self._inflight >= self.max_concurrent:
            raise HTTPException(429, {"error": "demo_busy",
                                      "message": "Milo is busy with other visitors. Try again in a moment."},
                                headers={"Retry-After": "5"})
        self._inflight += 1

    def release(self) -> None:
        self._inflight = max(0, self._inflight - 1)


async def auth(request: Request) -> str:
    """Bearer device token -> device hash. Also applies the per-device rate limit."""
    h = request.headers.get("authorization", "")
    if not h.lower().startswith("bearer "):
        raise HTTPException(401, {"error": "missing_token"})
    dev = verify_token(request.app.state.settings, h[7:].strip())
    request.app.state.limiter.check(dev)
    return dev
