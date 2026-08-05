# ---------- Build stage ----------
FROM golang:1.22-alpine AS builder

WORKDIR /app

RUN apk add --no-cache git

COPY main.go .

RUN go mod init dns-stub \
 && go get github.com/miekg/dns@v1.1.58 \
 && CGO_ENABLED=0 go build -ldflags="-s -w" -o dns-stub
# ---------- Runtime stage ----------
FROM alpine:3.19

RUN adduser -D -H -u 10001 dnsuser

WORKDIR /app

COPY --from=builder /app/dns-stub .

USER dnsuser

EXPOSE 53/udp
EXPOSE 53/tcp

ENTRYPOINT ["./dns-stub"]
