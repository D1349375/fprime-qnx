#!/usr/bin/env python3
"""Check offline Markdown links in the tracked repository."""

import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
import sys
import unicodedata
from urllib.parse import unquote, urlsplit

TARGET = r"(<[^>\n]+>|(?:\\[()]|[^()\s])+)"
LINK = re.compile(r"\[[^\]\n]+\]\(\s*" + TARGET + r"(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
REFERENCE = re.compile(r"^ {0,3}\[[^\]\n]+\]:\s*" + TARGET)
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
HEADING = re.compile(r"^ {0,3}#{1,6}\s+(.+?)\s*$")
SETEXT = re.compile(r"^ {0,3}(?:=+|-+)\s*$")
IDENTIFIER = re.compile(r"\b(?:id|name)=[\"']([^\"']+)[\"']")


def prose(lines):
    fence = ""
    for number, line in enumerate(lines, 1):
        marker = FENCE.match(line)
        if marker:
            token = marker.group(1)
            if not fence:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence) and not line[marker.end():].strip():
                fence = ""
        elif not fence:
            yield number, line


def anchor_ids(lines):
    anchors = set()
    previous = ""
    previous_number = 0
    for number, line in lines:
        heading = HEADING.match(line)
        if line.lstrip().startswith("<"):
            anchors.update(IDENTIFIER.findall(line))
        title = None
        if heading:
            title = heading.group(1)
        elif SETEXT.fullmatch(line) and previous.strip() and previous_number == number - 1:
            title = previous.strip()
        previous, previous_number = line, number
        if title is None:
            continue
        title = re.sub(r"\s+#*$", "", title).lower()
        title = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", title)
        slug = "".join(
            "-" if char.isspace() else char
            for char in title
            if char.isspace() or char in "-_" or unicodedata.category(char)[0] in "LMN"
        )
        unique = slug
        index = 0
        while unique in anchors:
            index += 1
            unique = f"{slug}-{index}"
        anchors.add(unique)
    return anchors


def tracked_paths(root):
    records = subprocess.check_output(
        ["git", "ls-files", "--stage", "-z"], cwd=root,
    ).split(b"\0")
    tracked = {}
    for record in filter(None, records):
        metadata, name = record.split(b"\t", 1)
        tracked[os.fsdecode(name)] = metadata.split()[0]
    return tracked


def destination(source, value):
    link = urlsplit(value.removeprefix("<").removesuffix(">").replace(r"\(", "(").replace(r"\)", ")"))
    if link.scheme or link.netloc or link.path.startswith("/"):
        return None
    relative = unquote(link.path)
    path = posixpath.normpath(posixpath.join(posixpath.dirname(source), relative)) if relative else source
    if path == ".." or path.startswith("../"):
        return None
    return path, unquote(link.fragment)


def check(root):
    tracked = tracked_paths(root)
    submodules = {name for name, mode in tracked.items() if mode == b"160000"}
    targets = set(tracked)
    for name in tracked:
        targets.update(str(parent) for parent in PurePosixPath(name).parents)
    markdown = {
        name: list(prose((root / name).read_text(encoding="utf-8").splitlines()))
        for name, mode in tracked.items()
        if name.lower().endswith(".md") and mode in (b"100644", b"100755") and (root / name).is_file()
    }
    anchors = {name: anchor_ids(lines) for name, lines in markdown.items()}
    errors = []
    for source, lines in markdown.items():
        for number, line in lines:
            matches = [*LINK.finditer(line), *REFERENCE.finditer(line)]
            for match in matches:
                target = destination(source, match.group(1))
                if target is None:
                    continue
                path, fragment = target
                if path not in targets and not any(path.startswith(name + "/") for name in submodules):
                    errors.append(f"{source}:{number}: missing link target {path}")
                elif fragment and path in anchors and fragment not in anchors[path]:
                    errors.append(f"{source}:{number}: missing anchor #{fragment} in {path}")
    if errors:
        print("\n".join(dict.fromkeys(errors)), file=sys.stderr)
        return 1
    print("Repository Markdown links and anchors passed.")
    return 0


if __name__ == "__main__":
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    raise SystemExit(check(root))
