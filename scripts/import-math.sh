#!/usr/bin/env bash
####
# import-math.sh: regenerate adoption/math-tutorial from the pinned F Prime MathComponent tutorial plus
# adoption/math-qnx.patch.
#
# The tutorial (fprime-community/fprime-tutorial-math-component, Apache-2.0) is a third-party F Prime project with its
# own components, ports and types. Its lib/fprime submodule is replaced by this project's pinned F Prime, and the patch
# lists every source change the project needs to run on QNX with FprimeQnx.
#
# Environment: MATH_TUTORIAL_URL (default: the GitHub repository) to import from a local mirror.
####
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="${MATH_TUTORIAL_URL:-https://github.com/fprime-community/fprime-tutorial-math-component.git}"
REV=6dbbdc47d48315086c65354a7ea4d2f9352ee760
FPRIME="${ROOT}/lib/fprime"
DST="${ROOT}/adoption/math-tutorial"
PATCH="${ROOT}/adoption/math-qnx.patch"

if [ ! -e "${FPRIME}/cmake/FPrime.cmake" ]; then
    echo "error: ${FPRIME} not found. Run: git submodule update --init lib/fprime" >&2
    exit 1
fi

rm -rf "${DST}"
git clone --quiet --no-checkout -- "${URL}" "${DST}"
git -C "${DST}" -c advice.detachedHead=false checkout --quiet --detach "${REV}"
[ "$(git -C "${DST}" rev-parse HEAD)" = "${REV}" ] || { echo "error: tutorial is not at ${REV}" >&2; exit 1; }

# Use the project's pinned F Prime in place of the tutorial's own submodule. The shared clone reuses local objects.
FPRIME_REV="$(git -C "${FPRIME}" rev-parse HEAD)"
rmdir "${DST}/lib/fprime"
git clone --quiet --shared --no-checkout -- "${FPRIME}" "${DST}/lib/fprime"
git -C "${DST}/lib/fprime" -c advice.detachedHead=false checkout --quiet --detach "${FPRIME_REV}"

patch --quiet --forward --no-backup-if-mismatch -d "${DST}" -p1 < "${PATCH}"
echo "adoption/math-tutorial regenerated from tutorial ${REV} + math-qnx.patch"
echo "lib/fprime: $(git -C "${DST}/lib/fprime" describe --tags --always) (tutorial pin" \
    "$(git -C "${DST}" rev-parse --short HEAD:lib/fprime))"
