# consumer/Dockerfile
FROM golang:1.21 AS builder
WORKDIR /app
COPY go.mod  ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o consumer main.go

FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=builder /app/consumer .
EXPOSE 8080
CMD ["./consumer"]