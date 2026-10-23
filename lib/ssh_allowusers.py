#!/usr/bin/env python3
"""Safely add an SSH AllowUsers entry in the global sshd_config scope.

AllowUsers directives append to the allow-list; avoid rewriting any existing
allow-list and never put global directives inside a Match section.
"""
import argparse
import re
from pathlib import Path

_VALID_LOGIN = re.compile(r"[a-z_][a-z0-9_-]{0,31}\Z")
_ALLOW = re.compile(r"^\s*AllowUsers(?:\s+|$)", re.IGNORECASE)
_MATCH = re.compile(r"^\s*Match(?:\s+|$)", re.IGNORECASE)


def add_user(contents: str, name: str) -> str:
    if not _VALID_LOGIN.fullmatch(name) or name == "root":
        raise ValueError("Неверное имя пользователя для AllowUsers")

    lines = contents.splitlines(keepends=True)
    boundary = next(
        (i for i, line in enumerate(lines)
         if _MATCH.match(line) and not line.lstrip().startswith("#")),
        len(lines),
    )
    for line in lines[:boundary]:
        if line.lstrip().startswith("#"):
            continue
        if _ALLOW.match(line):
            tokens = line.split("#", 1)[0].split()[1:]
            if name in tokens:
                return contents

    entry = f"AllowUsers {name}\n"
    if boundary == len(lines):
        prefix = "" if not contents or contents.endswith("\n") else "\n"
        return contents + prefix + entry

    if boundary and not lines[boundary - 1].endswith("\n"):
        lines[boundary - 1] += "\n"
    lines.insert(boundary, entry)
    return "".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("username")
    args = parser.parse_args()

    contents = args.source.read_text(encoding="utf-8")
    result = add_user(contents, args.username)
    args.destination.write_text(result, encoding="utf-8")


if __name__ == "__main__":
    main()
