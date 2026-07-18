FROM alpine:3.19 AS dash-gen

RUN apk add --no-cache ffmpeg python3

# Synthetic 2-minute clip, 3 video renditions (for ABR) + audio, packaged as
# DASH. Generated at build time so the image is self-contained — no
# participant-facing content/tooling needed, just a generic MPD to pull.
RUN mkdir -p /dash && \
    ffmpeg -f lavfi -i "testsrc2=duration=120:size=1280x720:rate=25" \
           -f lavfi -i "sine=frequency=1000:duration=120" \
           -filter_complex "[0:v]split=3[v1][v2][v3]; \
                            [v1]scale=1280:720[v1out]; \
                            [v2]scale=960:540[v2out]; \
                            [v3]scale=640:360[v3out]" \
           -map "[v1out]" -c:v:0 libx264 -b:v:0 2000k -x264-params "keyint=100:scenecut=0" \
           -map "[v2out]" -c:v:1 libx264 -b:v:1 800k  -x264-params "keyint=100:scenecut=0" \
           -map "[v3out]" -c:v:2 libx264 -b:v:2 300k  -x264-params "keyint=100:scenecut=0" \
           -map 1:a -c:a aac -b:a 64k \
           -use_template 1 -use_timeline 0 -seg_duration 4 \
           -init_seg_name 'init-stream$RepresentationID$.$ext$' \
           -media_seg_name 'chunk-stream$RepresentationID$-$Number$.$ext$' \
           -adaptation_sets "id=0,streams=0,1,2 id=1,streams=3" \
           -f dash /dash/manifest.mpd
# (use_timeline off: with it on, ffmpeg emits a per-Representation
# SegmentTimeline instead of a numeric SegmentTemplate duration/timescale.
# No %05d zero-padding in the segment name: godash's segment-number
# substitution does a literal "$Number$" string replace with no formatting.
# See dash-fixup.py for why $RepresentationID$ also needs resolving.)

COPY dash-fixup.py /dash-fixup.py
RUN python3 /dash-fixup.py /dash/manifest.mpd

FROM golang:1.22-alpine AS quic-build

WORKDIR /src
COPY quicserve/go.mod quicserve/go.sum* ./
RUN go mod download

COPY quicserve/ .
RUN CGO_ENABLED=0 go build -o /quicserve .

FROM golang:1.24-alpine AS networkquality-build

RUN GOBIN=/out go install github.com/network-quality/goserver/cmd/networkqualityd@latest

FROM alpine:3.19

RUN apk add --no-cache \
    iperf3 \
    python3

WORKDIR /app

COPY entrypoint.sh /app/
COPY --from=dash-gen /dash /var/www/dash
COPY --from=quic-build /quicserve /app/quicserve
COPY --from=networkquality-build /out/networkqualityd /app/networkqualityd
COPY certs /app/certs

RUN chmod +x /app/entrypoint.sh

EXPOSE 5201 8000
EXPOSE 4433/udp
EXPOSE 4043

ENTRYPOINT ["/app/entrypoint.sh"]
