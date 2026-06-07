#!/bin/bash
# =============================================================================
# Build the Pluto+ GPS firmware in Docker.
# Run this from the directory containing Dockerfile + docker-build-inner.sh.
#
# Usage:
#   ./docker-run.sh                        # build without Vivado (Linux/rootfs only)
#   ./docker-run.sh --vivado /opt/Xilinx   # mount your Vivado install for full build
#
# Output firmware lands in ./output/
# =============================================================================

IMAGE="plutoplus-gps-builder"
VIVADO_HOST=""

# Named volume keeps src inside Linux filesystem (avoids Windows chmod issues)
docker volume create plutoplus-src-cache &>/dev/null

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vivado) VIVADO_HOST="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Create output dir
mkdir -p output

# Build the Docker image (only rebuilds if Dockerfile changed)
echo "[*] Building Docker image..."
docker build -t "$IMAGE" .

# Construct Vivado mount if provided
VIVADO_MOUNT=""
if [ -n "$VIVADO_HOST" ]; then
    echo "[*] Mounting Vivado from: $VIVADO_HOST"
    VIVADO_MOUNT="-v ${VIVADO_HOST}:/opt/Xilinx:ro"
fi

echo "[*] Starting build container (logging to build.log)..."
docker run --rm \
    -v "$(pwd)/docker-build-inner.sh:/build/scripts/docker-build-inner.sh:ro" \
    -v "$(pwd)/output:/build/output" \
    -v "plutoplus-src-cache:/build/src" \
    $VIVADO_MOUNT \
    --name plutoplus-gps-build \
    "$IMAGE" 2>&1 | tee build.log
