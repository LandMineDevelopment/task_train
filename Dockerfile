FROM node:22-bookworm-slim

COPY requirements-dev.txt /tmp/requirements-dev.txt

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash git postgresql-client python3 python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m pip install --break-system-packages "psycopg[binary]>=3.3,<4" -r /tmp/requirements-dev.txt \
    && npm install --global opencode-ai@1.18.3

RUN useradd --create-home --shell /bin/bash app
COPY --chmod=755 docker/app-entrypoint.sh /usr/local/bin/app-entrypoint
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/app-entrypoint"]

CMD ["bash"]
