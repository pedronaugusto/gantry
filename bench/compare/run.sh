#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1
exec "${PYTHON:-python3}" "$(dirname "$0")/run.py" "$@"
