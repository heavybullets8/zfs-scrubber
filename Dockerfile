FROM alpine:3.23

RUN apk add --no-cache crane bash curl libuuid libblkid

COPY --from=ghcr.io/sigstore/cosign/cosign:v3.0.6@sha256:de9c65609e6bde17e6b48de485ee788407c9502fa08b8f4459f595b21f56cd00 /ko-app/cosign /usr/local/bin/
RUN cosign version

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
