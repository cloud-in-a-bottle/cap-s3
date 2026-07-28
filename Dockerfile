# cap-s3: MinIO S3 storage for self-hosted Cap, fronted by a Caddy
# Host-rewrite sidecar.
#
# Why the sidecar: the OpenHost router strips the inbound Host header
# and forwards to 127.0.0.1:<port>, but Cap hands the browser SigV4
# presigned S3 URLs whose signature covers the public Host
# (cap-s3.<zone>). MinIO recomputes the signature from the Host it
# receives, so a stripped Host breaks every presigned URL. The router
# does preserve the original host in X-Forwarded-Host, so Caddy
# restores Host from it before handing the request to MinIO — and the
# signatures match again, over the normal HTTPS subdomain.
#
# No RUN steps: some OpenHost hosts run a crun that rejects the OCI
# metadata of RUN layers, so we only COPY prebuilt static binaries
# onto a glibc base (the MinIO/mc binaries are built against glibc;
# an alpine/musl base can fail to exec them).

FROM caddy:2 AS caddy-src
FROM minio/minio:latest AS minio-src

FROM debian:bookworm-slim

COPY --from=caddy-src /usr/bin/caddy /usr/bin/caddy
COPY --from=minio-src /usr/bin/minio /usr/bin/minio
COPY --from=minio-src /usr/bin/mc /usr/bin/mc

COPY Caddyfile /etc/caddy/Caddyfile
COPY start.sh /usr/local/bin/start.sh

# Root credentials. OpenHost has no per-app env injection, so for this
# dev instance the S3 access key/secret are set here and shared with
# cap-web's CAP_AWS_ACCESS_KEY/SECRET. start.sh falls back to
# generating + persisting a pair if these are unset.
ENV MINIO_ROOT_USER=cap-s3-access-key
ENV MINIO_ROOT_PASSWORD=cap-s3-secret-key-change-me-1234567890
ENV CAP_S3_BUCKET=cap

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/start.sh"]
