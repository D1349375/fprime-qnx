#!/usr/bin/env bash
####
# import-ref.sh: regenerate adoption/Ref from the pinned upstream Ref deployment plus adoption/ref-qnx.patch.
#
# The patch is the complete list of changes an existing F Prime deployment needs to run on QNX with FprimeQnx.
# Re-run this after bumping the lib/fprime submodule; a failing patch means upstream Ref changed and the diff
# needs review.
####
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/lib/fprime/TestDeploymentsProject/Ref"
DST="${ROOT}/adoption/Ref"
PATCH="${ROOT}/adoption/ref-qnx.patch"

if [ ! -d "${SRC}" ]; then
    echo "error: ${SRC} not found. Run: git submodule update --init lib/fprime" >&2
    exit 1
fi

rm -rf "${DST}"
cp -a "${SRC}" "${DST}"
patch --quiet --forward --no-backup-if-mismatch -d "${ROOT}/adoption" -p1 < "${PATCH}"
echo "adoption/Ref regenerated from $(git -C "${ROOT}/lib/fprime" describe --tags --always) + ref-qnx.patch"
