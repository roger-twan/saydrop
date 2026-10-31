#!/bin/bash
# Compatibility entry point; runs the full core, real-time buffer, and host checks.
set -euo pipefail
exec bash "$(cd "$(dirname "$0")" && pwd)/check-cloud.sh" "$@"
