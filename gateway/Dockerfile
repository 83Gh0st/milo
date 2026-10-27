# Build from the repo root:  docker build -f gateway/Dockerfile -t milo-gateway .
FROM python:3.12-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN useradd -r -u 10001 milo
WORKDIR /srv
COPY gateway/requirements.txt gateway/requirements.txt
RUN pip install --no-cache-dir -r gateway/requirements.txt
COPY gateway/app gateway/app
COPY contracts contracts
USER milo
WORKDIR /srv/gateway
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/healthz')"
# One worker keeps the in-memory rate limiter exact; scale vertically, or move limits to Redis before adding replicas.
CMD ["uvicorn","app.main:app_factory","--factory","--host","0.0.0.0","--port","8000","--proxy-headers","--forwarded-allow-ips","*","--timeout-keep-alive","75"]
