FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /src
COPY pyproject.toml README.md ./
COPY app ./app
RUN pip install . && rm -rf /src

RUN useradd --system --uid 10001 --home-dir /data buddy \
    && mkdir /data && chown buddy:buddy /data
USER buddy
WORKDIR /data

# The SQLite database lives in /data; mount a volume there.
ENV SB_DATABASE_URL=sqlite:////data/shoppingbuddy.db
VOLUME /data
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"

# One worker only: SQLite (see README). Proxy headers come from Traefik, the only way in.
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "1", "--proxy-headers", "--forwarded-allow-ips", "*"]
