"""SSRF and egress guard for custom provider base URLs. Stdlib only so the
unit suite can exercise it without the web stack.

Rules (Phase 3A):
- https only, except http for localhost/LAN loopback which is allowed only
  when ENV=dev AND allow_lan is explicitly set (local Ollama/LM Studio).
- The hostname is resolved (injectable resolver for tests) and loopback,
  link-local, RFC1918, carrier-grade NAT, unspecified, multicast and the
  cloud-metadata address are rejected in prod. In dev they are rejected too
  unless allow_lan is set (localhost http still needs the flag).
- No credentials in the URL, no exotic ports, bounded length.
- Redirects are never followed cross-host (the HTTP layer disables them).
"""
import ipaddress
import socket
import urllib.parse

METADATA_IPS = {"169.254.169.254", "fd00:ec2::254"}
MAX_URL_LEN = 500


def default_resolver(host: str) -> list[str]:
    try:
        return sorted({r[4][0] for r in socket.getaddrinfo(host, None)})
    except socket.gaierror:
        return []


def _bad_ip(ip: str) -> str | None:
    if ip in METADATA_IPS:
        return "cloud metadata address"
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return "unparseable address"
    if a.is_loopback:
        return "loopback"
    if a.is_link_local:
        return "link-local"
    if a.is_multicast or a.is_unspecified:
        return "non-routable"
    if isinstance(a, ipaddress.IPv4Address) and (a.is_private or ipaddress.ip_address(ip) in ipaddress.ip_network("100.64.0.0/10")):
        return "private range"
    if isinstance(a, ipaddress.IPv6Address) and (a.is_private or a.is_site_local):
        return "private range"
    return None


def check_base_url(url: str, *, env: str, allow_lan: bool = False, resolve=default_resolver) -> str:
    """Validates a provider base URL. Returns the normalised URL (no trailing
    slash) or raises ValueError naming the rule that rejected it."""
    u = (url or "").strip()
    if not u or len(u) > MAX_URL_LEN:
        raise ValueError("empty or overlong url")
    try:
        p = urllib.parse.urlsplit(u)
    except ValueError:
        raise ValueError("malformed url")
    if p.scheme not in ("https", "http"):
        raise ValueError("only https (or dev-local http) is allowed")
    if p.username or p.password:
        raise ValueError("credentials must not be embedded in the url")
    host = (p.hostname or "").lower()
    if not host:
        raise ValueError("missing hostname")
    if p.port is not None and not (1 <= p.port <= 65535):
        raise ValueError("bad port")
    if p.scheme == "http" and not (env != "prod" and allow_lan):
        raise ValueError("http needs ENV=dev and explicit local-provider opt-in")
    ips = resolve(host)
    if not ips:
        raise ValueError(f"cannot resolve {host}")
    for ip in ips:
        why = _bad_ip(ip)
        if why and not (env != "prod" and allow_lan):
            raise ValueError(f"{host} resolves to a disallowed address ({ip}: {why})")
    return f"{p.scheme}://{p.netloc}{p.path.rstrip('/')}"
