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


async def auth(request: Request) -> str:
    """Bearer device token -> device hash. Also applies the per-device rate limit."""
    h = request.headers.get("authorization", "")
    if not h.lower().startswith("bearer "):
        raise HTTPException(401, {"error": "missing_token"})
    dev = verify_token(request.app.state.settings, h[7:].strip())
    request.app.state.limiter.check(dev)
    return dev
