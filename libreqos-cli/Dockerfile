FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      iproute2 \
      bash \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://download.libreqos.com/cli/install.sh -o /tmp/libreqos-install.sh \
    && sh /tmp/libreqos-install.sh \
    && rm -f /tmp/libreqos-install.sh

WORKDIR /data/libreqos
