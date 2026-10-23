#!/usr/bin/env python3
"""Edit only the existing %sudo ALL rule in the main sudoers configuration."""
import argparse
import re
from pathlib import Path

GROUP_LINE = re.compile(r"^[ \t]*%sudo(?:[ \t]|$)")
SUPPORTED = re.compile(
    r"^(?P<prefix>[ \t]*%sudo[ \t]+ALL=\((?:ALL|ALL:ALL)\)[ \t]+)"
    r"(?P<permission>ALL|NOPASSWD:[ \t]+ALL)"
    r"(?P<suffix>[ \t]*(?:#.*)?)$"
)


def convert(contents: str) -> str:
    lines = contents.splitlines(keepends=True)
    matches = []
    for index, line in enumerate(lines):
        text = line.rstrip("\r\n")
        if GROUP_LINE.match(text):
            parsed = SUPPORTED.fullmatch(text)
            if parsed is None:
                raise ValueError("Unsupported %sudo rule: edit manually with visudo")
            matches.append((index, parsed, line[len(text):]))
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one active %sudo rule, found {len(matches)}")
    index, parsed, ending = matches[0]
    if parsed.group("permission") != "ALL":
        return contents
    lines[index] = (
        parsed.group("prefix") + "NOPASSWD: ALL" + parsed.group("suffix") + ending
    )
    return "".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    source = args.source.read_text(encoding="utf-8")
    candidate = convert(source)
    args.destination.write_text(candidate, encoding="utf-8")


if __name__ == "__main__":
    main()
