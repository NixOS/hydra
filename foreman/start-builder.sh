#!/bin/sh

. ./foreman/common.sh

wait_for_queue_runner_grpc

export RUST_BACKTRACE="${RUST_BACKTRACE:-1}"

exec hydra-builder
