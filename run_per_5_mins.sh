#!/bin/bash
# continuous_monitor.sh

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET_SCRIPT=${TARGET_SCRIPT:-"$SCRIPT_DIR/hpc_gpu_status.sh"}
INTERVAL_SECONDS=${INTERVAL_SECONDS:-300}

while true; do
    bash "$TARGET_SCRIPT"
    sleep "$INTERVAL_SECONDS"
done
