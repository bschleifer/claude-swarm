#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./test/bats/bin/bats test/*.bats "$@"
