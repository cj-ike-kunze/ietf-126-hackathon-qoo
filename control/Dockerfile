FROM alpine:3.19

RUN apk add --no-cache python3

WORKDIR /app

COPY *.html /app/

EXPOSE 8080

ENTRYPOINT ["python3", "-m", "http.server", "8080"]
