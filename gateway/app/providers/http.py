"""Minimal async HTTP for provider adapters. Dependency-free module: the real
transport imports httpx lazily (CI/prod have it); tests inject a fake.

Transports speak only stdlib exceptions so adapters map them uniformly:
TimeoutError -> ProviderError(timeout), ConnectionError/OSError ->
ProviderError(unreachable). Redirects are never followed (SSRF guard).
"""
import json


class HttpStream:
    """One streamed response. Chunks are raw bytes; the adapter parses SSE."""

    def __init__(self, status, headers, chunks, body_prefix=b""):
        self.status, self.headers, self._chunks = status, headers, chunks
        self.body_prefix = body_prefix  # first bytes (for error sniffing)

    async def __aiter__(self):
        async for c in self._chunks:
            yield c


class HttpxTransport:
    def __init__(self, max_bytes=2_000_000):
        self.max_bytes = max_bytes

    def _client(self, timeout):
        import httpx  # lazy: CI/prod dependency, never imported in unit tests
        return httpx.AsyncClient(timeout=httpx.Timeout(connect=10.0, read=timeout, write=timeout, pool=timeout),
                                 follow_redirects=False)

    async def post_stream(self, url, headers, payload, timeout=30):
        import httpx
        try:
            client = self._client(timeout)
            req = client.build_request("POST", url, headers=headers, json=payload)
            resp = await client.send(req, stream=True)
        except httpx.TimeoutException:
            raise TimeoutError(url)
        except httpx.ConnectError as e:
            raise ConnectionError(str(e))

        async def chunks():
            total = 0
            try:
                async for c in resp.aiter_bytes():
                    total += len(c)
                    if total > self.max_bytes:
                        break
                    yield c
            finally:
                await resp.aclose()
                await client.aclose()

        return HttpStream(resp.status_code, dict(resp.headers), chunks())

    async def post_json(self, url, headers, payload, timeout=30):
        import httpx
        try:
            async with self._client(timeout) as client:
                r = await client.post(url, headers=headers, json=payload)
        except httpx.TimeoutException:
            raise TimeoutError(url)
        except httpx.ConnectError as e:
            raise ConnectionError(str(e))
        try:
            data = r.json()
        except ValueError:
            data = {}
        return r.status_code, data

    async def get_json(self, url, headers, timeout=15):
        import httpx
        try:
            async with self._client(timeout) as client:
                r = await client.get(url, headers=headers)
        except httpx.TimeoutException:
            raise TimeoutError(url)
        except httpx.ConnectError as e:
            raise ConnectionError(str(e))
        try:
            data = r.json()
        except ValueError:
            data = {}
        return r.status_code, data


def default_transport():
    return HttpxTransport()
