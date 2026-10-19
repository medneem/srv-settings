#!/usr/bin/env python3
"""Merge trusted Docker registry mirrors into a daemon.json copy.

Usage: docker_mirrors.py SOURCE OUTPUT
SOURCE may be missing. OUTPUT is a staging path that is atomically moved
into place by docker.sh only after validation.
"""
import json
import os
import sys

MIRRORS = (
    "https://dh-mirror.gitverse.ru",
    "https://dockerhub.timeweb.cloud",
    "https://dockerhub1.beget.com",
    "https://mirror.gcr.io",
)


def merged_config(existing):
    if not isinstance(existing, dict):
        raise ValueError("daemon.json must contain a JSON object")
    before = existing.get("registry-mirrors", [])
    if not isinstance(before, list) or not all(
        isinstance(value, str) for value in before
    ):
        raise ValueError("registry-mirrors must be an array of strings")
    merged = dict(existing)
    merged["registry-mirrors"] = list(dict.fromkeys([*before, *MIRRORS]))
    return merged


def render(source, destination):
    if os.path.exists(source):
        with open(source, encoding="utf-8") as handle:
            existing = json.load(handle)
    else:
        existing = {}
    data = merged_config(existing)
    with open(destination, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    os.chmod(destination, 0o644)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: docker_mirrors.py SOURCE OUTPUT")
    try:
        render(sys.argv[1], sys.argv[2])
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"Cannot update Docker mirrors: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
