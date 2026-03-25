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
    echo "Usage: $0 <build_id> [build_id ...]"
    exit 1
fi

BUILD_IDS=("$@")

trap cleanup EXIT INT TERM

GRPC_PORT=$(get_random_port 5000 9999)
HTTP_PORT=$(get_random_port 10000 19999)

# Use the temp dir provided by the test harness, or HYDRA_DATA as fallback.
CONFIG_DIR="${T2_HARNESS_TEMP_DIR:-${HYDRA_DATA:?}}"
CONFIG_FILE="${CONFIG_DIR}/config.toml"

# Read store settings from the Apache-style HYDRA_CONFIG if present.
DEST_STORE_URI="" USE_SUBSTITUTES=""
if [[ -n "${HYDRA_CONFIG:-}" && -f "${HYDRA_CONFIG}" ]]; then
    DEST_STORE_URI=$(sed -n 's/^\s*store_uri\s*=\s*//p' "${HYDRA_CONFIG}" | head -1 | xargs || true)
    USE_SUBSTITUTES=$(sed -n 's/^\s*use-substitutes\s*=\s*//p' "${HYDRA_CONFIG}" | head -1 | xargs || true)
fi

{
    echo "dbUrl = \"${HYDRA_DATABASE_URL:?}\""
    echo "hydraDataDir = \"${CONFIG_DIR}/data\""
    [[ -n "${DEST_STORE_URI}" ]] && echo "remoteStoreAddr = [\"${DEST_STORE_URI}\"]"
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

# Submit all builds. Returns 200 even if a build is already finished.
for bid in "${BUILD_IDS[@]}"; do
    curl -s --fail -X POST \
        --json "{\"buildId\": ${bid}}" \
        "http://[::1]:${HTTP_PORT}/build_one"
done

# Poll until every build is no longer active.
while true; do
    # If the builder crashed, fail fast with its exit code instead of
    # waiting for the queue-runner to time out the orphaned builds.
    if ! kill -0 "${BUILDER_PID}" 2>/dev/null; then
        wait "${BUILDER_PID}" 2>/dev/null && builder_rc=0 || builder_rc=$?
        echo >&2 "builder (pid ${BUILDER_PID}) exited unexpectedly (exit code ${builder_rc})"
        if (( builder_rc > 128 )); then
            echo >&2 "builder was killed by signal $(( builder_rc - 128 ))"
        fi
        exit 1
    fi

    all_done=true
    for bid in "${BUILD_IDS[@]}"; do
        status=$(curl -s "http://[::1]:${HTTP_PORT}/status/build/${bid}/active")
        if [[ "${status}" == *"true"* ]]; then
            all_done=false
            break
        fi
    done
    "${all_done}" && break
    sleep 2
done
