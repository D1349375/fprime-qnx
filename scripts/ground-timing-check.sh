#!/usr/bin/env bash
# Compare the same seeded FlightSW scenario with GDS disabled and enabled.
set -euo pipefail
if [[ $# -gt 1 || "${1:-}" == --help ]]; then
    echo 'Usage: scripts/ground-timing-check.sh [rounds-per-mode] (default: 20)'
    [[ $# -le 1 ]]
    exit
fi
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exec "$root/scripts/gds-check.sh" --timing "${1:-20}"
