#!/usr/bin/env bash
set -euo pipefail

root="$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
cd -- "$root"

python3 -B - <<'PY'
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

TIMING = re.compile(
    r"\b(?:p(?:50|95|99)(?:\.\d+)?|RgMaxTime|jitter)\b|"
    r"(?<![\w.])\d+(?:[.,]\d+)*\s*"
    r"(?:(?:[µμ]s|us|ns|ms|(?:nano|micro|milli)seconds?)\b|\u6beb\u79d2|\u5fae\u79d2|\u5948\u79d2)",
    re.IGNORECASE,
)
PRIVATE_KEY = re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")
TOKEN = re.compile(
    r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|"
    r"(?:AKIA|ASIA)[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{10,})\b"
)
SECRET_ASSIGNMENT = re.compile(
    r"\b(?:api[ _-]?key|access[ _-]?token|client[ _-]?secret|password|"
    r"(?:license|licence|activation)[ _-]?(?:key|serial|token))\s*[:=]\s*[\"'`]?"
    r"[A-Za-z0-9+/_=-]{14,}(?=$|[\s\"'`])",
    re.IGNORECASE,
)
LONG_HEX = re.compile(r"(?<![\da-f])[\da-f]{32,}(?![\da-f])", re.IGNORECASE)
BASE64 = re.compile(r"(?=.*[a-z])(?=.*[A-Z])(?=.*\d)[A-Za-z0-9+/]{32,}={0,2}")
HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0002fa1f]")
BLOCKED_SUFFIXES = (
    ".vmdk", ".img", ".qnx", ".ifs", ".key", ".pem", ".run", ".msi", ".exe",
    ".apk", ".deb", ".zip", ".tar", ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst",
    ".tgz", ".tbz2", ".7z", ".rar",
)
CODE_SUFFIXES = (".c", ".cc", ".cpp", ".h", ".hh", ".hpp", ".cmake", ".fpp", ".py", ".sh")


def public_document(name):
    return name == "README.md" or (name.startswith("docs/") and not name.startswith("docs/internal/"))


def read_allowlist():
    fragments, digests = {}, {}
    for number, entry in enumerate(Path("scripts/public-docs-allow.txt").read_text(encoding="utf-8").splitlines(), 1):
        if not entry or entry.startswith("#"):
            continue
        name, separator, value = entry.partition(":")
        if not separator or not public_document(name) or not value:
            raise SystemExit(f"scripts/public-docs-allow.txt:{number}: expected a public file and exact text")
        if value.startswith("sha256:"):
            digest = value.removeprefix("sha256:")
            if not re.fullmatch(r"[a-f0-9]{64}", digest):
                raise SystemExit(f"scripts/public-docs-allow.txt:{number}: invalid line digest")
            digests.setdefault(name, set()).add(digest)
        else:
            fragments.setdefault(name, []).append(value)
    return fragments, digests


def possible_secret(line):
    if PRIVATE_KEY.search(line) or TOKEN.search(line) or SECRET_ASSIGNMENT.search(line):
        return True
    candidate = line.strip().strip("\"'`")
    if re.fullmatch(r"[A-Fa-f0-9]{40}|[A-Fa-f0-9]{64}", candidate):
        return False
    unusual_hex = any(len(match.group()) not in (40, 64) for match in LONG_HEX.finditer(line))
    return unusual_hex or BASE64.fullmatch(candidate) is not None


def unauthorized_timing(name, line, fragments, digests):
    hits = list(TIMING.finditer(line))
    if not hits:
        return False
    if name in digests and hashlib.sha256(line.encode("utf-8")).hexdigest() in digests[name]:
        return False
    spans = [
        (match.start(), match.end())
        for fragment in fragments.get(name, ())
        for match in re.finditer(re.escape(fragment), line)
    ]
    return any(not any(start <= hit.start() and hit.end() <= end for start, end in spans) for hit in hits)


def check():
    fragments, digests = read_allowlist()
    errors = []
    tracked = subprocess.check_output(["git", "ls-files", "-z"]).split(b"\0")
    for raw_name in filter(None, tracked):
        name = os.fsdecode(raw_name)
        path = Path(name)
        lower = path.name.lower()
        if lower.endswith(BLOCKED_SUFFIXES) or lower.startswith(("id_", "qnxsdp-env.")):
            errors.append(f"{name}: tracked credential, SDK asset, or archive")
        if name.startswith("docs/en/") and not name.isascii():
            errors.append(f"{name}: use ASCII in English documentation paths")
        if path.is_symlink():
            data = os.fsencode(os.readlink(path))
        elif path.is_file():
            data = path.read_bytes()
        else:
            continue
        if b"\0" in data:
            continue
        source_code = name.startswith(("src/", "scripts/", "FprimeQnx/", "FprimeQnxReference/")) and (
            lower.endswith(CODE_SUFFIXES) or lower == "cmakelists.txt"
        )
        public = public_document(name)
        for number, line in enumerate(data.decode("utf-8", errors="replace").splitlines(), 1):
            location = f"{name}:{number}"
            if possible_secret(line):
                errors.append(f"{location}: possible credential")
            if source_code and HAN.search(line):
                errors.append(f"{location}: use English in source and scripts")
            if public and unauthorized_timing(name, line, fragments, digests):
                errors.append(f"{location}: timing text outside the public allowlist")
    if errors:
        print("\n".join(dict.fromkeys(errors)), file=sys.stderr)
        return 1
    print("Public document and tracked-file checks passed.")
    return 0


raise SystemExit(check())
PY
