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
    echo "Cleaning up processes..."
    if [[ -n "${QUEUE_RUNNER_PID:-}" ]]; then
        kill "${QUEUE_RUNNER_PID}" 2>/dev/null || true
    fi
    if [[ -n "${BUILDER_PID:-}" ]]; then
        kill "${BUILDER_PID}" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
    echo "Cleanup complete"
}

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <build_id>"
    echo "Example: $0 12345"
    exit 1
fi

BUILD_ID="$1"

trap cleanup EXIT INT TERM

GRPC_PORT=$(get_random_port 5000 9999)
HTTP_PORT=$(get_random_port 10000 19999)

echo "Using GRPC port: ${GRPC_PORT}"
echo "Using HTTP port: ${HTTP_PORT}"

echo "Starting queue-runner..."
RUST_LOG=queue_runner=debug,info NO_COLOR=1 hydra-queue-runner \
    --rest-bind "[::]:${HTTP_PORT}" \
    --grpc-bind "[::]:${GRPC_PORT}" \
    --config-path <(echo -e "dbUrl= \"${HYDRA_DATABASE_URL}\"\nhydraDataDir=\"${HYDRA_DATA}\"") \
    --disable-queue-monitor-loop &
QUEUE_RUNNER_PID=$!
sleep 0.5

echo "Starting builder..."
RUST_LOG=builder=debug,info NO_COLOR=1 hydra-builder --gateway-endpoint "http://[::]:${GRPC_PORT}" &
BUILDER_PID=$!
sleep 2

echo "Waiting for services to start..."

echo "Services started successfully!"
echo "queue-runner PID: ${QUEUE_RUNNER_PID}"
echo "builder PID: ${BUILDER_PID}"

# Function to submit build and monitor
submit_and_monitor_build() {
    local build_id="$1"

    echo "Submitting build ${build_id}..."

    curl -s --fail -X POST \
        --json "{\"buildId\": ${build_id}}" \
        "http://[::1]:${HTTP_PORT}/build_one"
    echo "Monitoring build ${build_id}..."
    sleep 2 # wait a couple of seconds till job is dispatched

    while true; do
        local status_response
        status_response=$(curl -s "http://[::1]:${HTTP_PORT}/status/build/${build_id}/active")
        echo "Status response: ${status_response}"

        # Check if build is still active
        if [[ "${status_response}" == *"false"* ]] || [[ "${status_response}" == *"null"* ]] || [[ "${status_response}" == *"\"active\": false"* ]]; then
            echo "Build ${build_id} is no longer active"
            break
        elif [[ "${status_response}" == *"true"* ]] || [[ "${status_response}" == *"\"active\": true"* ]]; then
            echo "Build ${build_id} is still active, waiting..."
            sleep 2
        else
            echo "Unexpected status response: ${status_response}"
            sleep 2
        fi
    done

    echo "Build ${build_id} completed!"
}

submit_and_monitor_build "${BUILD_ID}"

echo "All done! Services will be cleaned up automatically."
