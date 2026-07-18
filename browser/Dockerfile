FROM linuxserver/firefox:latest

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates iproute2 iputils-ping \
    && rm -rf /var/lib/apt/lists/*