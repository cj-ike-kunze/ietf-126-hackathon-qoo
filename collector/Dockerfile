FROM golang:1.22-alpine AS build

WORKDIR /src

COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -o /collector .

FROM alpine:3.19

COPY --from=build /collector /app/collector

ENTRYPOINT ["/app/collector"]
