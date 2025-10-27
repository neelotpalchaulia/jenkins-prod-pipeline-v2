FROM golang:1.23 AS builder
WORKDIR /src/app
COPY app/ .
RUN go test ./... && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /bin/app

FROM gcr.io/distroless/base-debian12
COPY --from=builder /bin/app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
