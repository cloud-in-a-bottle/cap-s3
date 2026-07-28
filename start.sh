#!/bin/sh
# Launch MinIO (S3 API on 127.0.0.1:9000) plus the Caddy Host-rewrite
# sidecar (public on :8080). POSIX sh only — the base image has no bash,
# and we avoid RUN-installing one for crun portability.
set -eu

PERSIST="${OPENHOST_APP_DATA_DIR:-/data}"
DATA_DIR="$PERSIST/data"
CONFIG_DIR="$PERSIST/config"
CRED_FILE="$CONFIG_DIR/root-credentials.env"
mkdir -p "$DATA_DIR" "$CONFIG_DIR"

# First boot with no baked creds: generate a stable pair and persist it.
if [ -z "${MINIO_ROOT_USER:-}" ] || [ -z "${MINIO_ROOT_PASSWORD:-}" ]; then
	if [ -f "$CRED_FILE" ]; then
		. "$CRED_FILE"
	else
		echo "[cap-s3] generating root credentials"
		MINIO_ROOT_USER="cap-$(head -c 8 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 8)"
		MINIO_ROOT_PASSWORD="$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
		umask 077
		printf 'MINIO_ROOT_USER=%s\nMINIO_ROOT_PASSWORD=%s\n' "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >"$CRED_FILE"
		umask 022
	fi
fi
export MINIO_ROOT_USER MINIO_ROOT_PASSWORD

# The upstream image sets *_FILE variants that conflict with the plain
# env vars and make login/auth flaky; clear them.
unset MINIO_ROOT_USER_FILE MINIO_ROOT_PASSWORD_FILE \
	MINIO_ACCESS_KEY_FILE MINIO_SECRET_KEY_FILE \
	MINIO_KMS_SECRET_KEY_FILE MINIO_CONFIG_ENV_FILE 2>/dev/null || true

echo "[cap-s3] starting minio (data=$DATA_DIR)"
minio server "$DATA_DIR" \
	--config-dir "$CONFIG_DIR" \
	--address ":9000" \
	--console-address "127.0.0.1:9001" &
MINIO_PID=$!

# Wait for the S3 API to accept before creating the bucket / starting Caddy.
i=0
while [ "$i" -lt 30 ]; do
	if mc alias set local "http://127.0.0.1:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; then
		break
	fi
	if ! kill -0 "$MINIO_PID" 2>/dev/null; then
		echo "[cap-s3] minio exited before binding :9000"
		wait "$MINIO_PID" || true
		exit 1
	fi
	i=$((i + 1))
	sleep 1
done

# Pre-create the Cap bucket (cap-web also does this; idempotent).
BUCKET="${CAP_S3_BUCKET:-cap}"
mc mb --ignore-existing "local/$BUCKET" >/dev/null 2>&1 || true

echo "[cap-s3] starting caddy sidecar on :8080 -> 127.0.0.1:9000"
export XDG_DATA_HOME=/tmp/caddy XDG_CONFIG_HOME=/tmp/caddy
mkdir -p /tmp/caddy
caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

trap 'kill -TERM "$MINIO_PID" "$CADDY_PID" 2>/dev/null || true; wait || true' TERM INT

# Exit if either child dies.
while kill -0 "$MINIO_PID" 2>/dev/null && kill -0 "$CADDY_PID" 2>/dev/null; do
	sleep 2
done

echo "[cap-s3] a child process exited; shutting down"
kill -TERM "$MINIO_PID" "$CADDY_PID" 2>/dev/null || true
wait || true
