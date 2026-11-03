"""Staging demo probe: proves real image bytes come back (never just HTTP 200).

Usage (no secrets needed - the hosted demo key stays in the Modal secret):
  python gateway/scripts/probe_image.py [gateway-base-url]
Writes probe_image_out.png next to this script; exit 0 only when the
returned bytes are a real PNG/JPEG/WebP/GIF/AVIF image.
"""
import json, struct, sys, urllib.request, urllib.error

BASE = (sys.argv[1] if len(sys.argv) > 1 else "https://arjun3314508--milo-gateway-staging-web.us-east.modal.run").rstrip("/")

def post(path, body, token=None, timeout=90):
    req = urllib.request.Request(BASE + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json",
                                          **({"Authorization": "Bearer " + token} if token else {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, {}, e.read()

def is_image(raw: bytes) -> bool:
    return (raw[:8] == b"\x89PNG\r\n\x1a\n" or raw[:2] == b"\xff\xd8" or raw[:6] in (b"GIF87a", b"GIF89a")
            or (len(raw) >= 12 and raw[:4] == b"RIFF" and raw[8:12] == b"WEBP")
            or (len(raw) >= 12 and raw[4:8] == b"ftyp" and raw[8:12] in (b"avif", b"avis")))

def main() -> int:
    s, _, b = post("/v1/session", {"install_id": "d" * 20, "app_version": "1.0.0", "platform": "android"})
    if s != 200:
        print(f"session failed: {s} {b[:200]!r}")
        return 1
    token = json.loads(b)["token"]
    s, headers, b = post("/v1/image", {"prompt": "a red kite flying over a green hill"}, token)
    print(f"image: status={s} provider={headers.get('X-Milo-Provider')} model={headers.get('X-Milo-Model')} "
          f"route={headers.get('X-Milo-Route')} bytes={len(b)} magic={b[:12].hex()}")
    if s != 200 or not is_image(b):
        print(f"FAIL: not a real image (body[:200]={b[:200]!r})")
        return 1
    out = __file__.replace("probe_image.py", "probe_image_out.png")
    open(out, "wb").write(b)
    print(f"OK: real image bytes written to {out}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
