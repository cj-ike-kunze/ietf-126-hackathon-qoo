FROM alpine:3.19

RUN apk add --no-cache \
    iproute2 \
    iproute2-tc \
    tcpdump \
    iptables \
    wireguard-tools \
    python3 \
    py3-flask \
    py3-waitress

WORKDIR /app

COPY api.py entrypoint.sh /app/
COPY profiles/ /app/profiles/

RUN chmod +x /app/entrypoint.sh /app/profiles/*.sh

EXPOSE 9000

ENTRYPOINT ["/app/entrypoint.sh"]
