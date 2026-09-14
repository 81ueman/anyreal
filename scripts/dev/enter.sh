#!/usr/bin/env bash
# Open an interactive shell in the development container.
set -euo pipefail
NAME="${ANYREAL_DEV_NAME:-anyreal-dev}"
exec docker exec -it -w /work "${NAME}" bash -l
