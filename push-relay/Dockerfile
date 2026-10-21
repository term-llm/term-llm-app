FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /push-relay .

# distroless/static includes CA certificates for api.push.apple.com.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /push-relay /push-relay
EXPOSE 8080
ENTRYPOINT ["/push-relay"]
CMD ["serve"]
