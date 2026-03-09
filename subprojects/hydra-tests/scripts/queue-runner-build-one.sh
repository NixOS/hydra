#!/usr/bin/env bash

set -euo pipefail
set -x

get_random_port() {
    local port_min=$1
    local port_max=$2
    local port

    while :; do
        port=$(shuf -i "${port_min}-${port_max}" -n 1)

        if ! ss -ltn "( sport = :${port} )" 2>/dev/null | grep -q ":${port}"; then
            echo "${port}"
            return 0
        fi
    done
}

cleanup() {
    kill "${QUEUE_RUNNER_PID:-}" "${BUILDER_PID:-}" 2>/dev/null || true
    wait 2>/dev/null || true
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <build_id>"
    exit 1
fi

BUILD_ID="$1"

trap cleanup EXIT INT TERM

GRPC_PORT=$(get_random_port 5000 9999)
HTTP_PORT=$(get_random_port 10000 19999)

# Use the temp dir provided by the test harness, or HYDRA_DATA as fallback.
CONFIG_DIR="${T2_HARNESS_TEMP_DIR:-${HYDRA_DATA:?}}"
CONFIG_FILE="${CONFIG_DIR}/config.toml"

# Read store settings from the Apache-style HYDRA_CONFIG if present.
USE_SUBSTITUTES=""
if [[ -n "${HYDRA_CONFIG:-}" && -f "${HYDRA_CONFIG}" ]]; then
    USE_SUBSTITUTES=$(sed -n 's/^\s*use-substitutes\s*=\s*//p' "${HYDRA_CONFIG}" | head -1 | xargs || true)
fi

{
    echo "dbUrl = \"${HYDRA_DATABASE_URL:?}\""
    echo "hydraDataDir = \"${CONFIG_DIR}/data\""
    [[ "${USE_SUBSTITUTES}" == "1" ]] && echo "useSubstitutes = true"
} > "${CONFIG_FILE}"

RUST_LOG=queue_runner=debug,info NO_COLOR=1 hydra-queue-runner \
    --config-path "${CONFIG_FILE}" \
    --rest-bind "[::]:${HTTP_PORT}" \
    --grpc-bind "[::]:${GRPC_PORT}" \
    --disable-queue-monitor-loop &
QUEUE_RUNNER_PID=$!

# Wait for the REST server to become available before starting the builder.
for _ in $(seq 1 30); do
    curl -sf "http://[::1]:${HTTP_PORT}/status" >/dev/null 2>&1 && break
    sleep 0.5
done

RUST_LOG=builder=debug,info NO_COLOR=1 hydra-builder --gateway-endpoint "http://[::1]:${GRPC_PORT}" &
BUILDER_PID=$!

# Wait for the builder to register as a machine.
for _ in $(seq 1 30); do
    curl -sf "http://[::1]:${HTTP_PORT}/status/machines" 2>/dev/null | grep -q '"hostname"' && break
    sleep 0.5
done

# Submit build and poll until it finishes.
curl -s --fail -X POST \
    --json "{\"buildId\": ${BUILD_ID}}" \
    "http://[::1]:${HTTP_PORT}/build_one"
sleep 2

while true; do
    status=$(curl -s "http://[::1]:${HTTP_PORT}/status/build/${BUILD_ID}/active")
    [[ "${status}" == *"true"* ]] || break
    sleep 2
done
