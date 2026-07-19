#!/usr/bin/env python3
"""Validate and compare Acro desktop release tags."""

import re
import sys

TAG_PATTERN = re.compile(
    r"^desktop-v(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)"
    r"(?:-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$"
)
PRERELEASE_RANK = {"alpha": 0, "beta": 1, "rc": 2}


def parse_tag(tag: str) -> tuple[int, int, int, int, int]:
    match = TAG_PATTERN.fullmatch(tag)
    if match is None:
        raise ValueError(f"invalid desktop release tag: {tag}")
    prerelease = match.group(4)
    return (
        int(match.group(1)),
        int(match.group(2)),
        int(match.group(3)),
        PRERELEASE_RANK.get(prerelease, 3),
        int(match.group(5) or 0),
    )


def desktop_tags(lines: list[str]) -> list[str]:
    return [tag for line in lines if (tag := line.strip()).startswith("desktop-v")]


def ensure_newer(candidate: str, existing: list[str]) -> None:
    candidate_key = parse_tag(candidate)
    for tag in existing:
        if candidate_key <= parse_tag(tag):
            raise ValueError(f"{candidate} must be newer than existing release {tag}")


def latest(existing: list[str], channel: str) -> str:
    if channel not in {"stable", "beta"}:
        raise ValueError(f"invalid release channel: {channel}")
    candidates = [
        tag
        for tag in existing
        if (parse_tag(tag)[3] == 3) == (channel == "stable")
    ]
    return max(candidates, key=parse_tag, default="")


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in {"verify", "latest"}:
        raise SystemExit("usage: release_versions.py verify <tag> | latest <stable|beta>")
    existing = desktop_tags(sys.stdin.readlines())
    try:
        if sys.argv[1] == "verify":
            ensure_newer(sys.argv[2], existing)
        else:
            print(latest(existing, sys.argv[2]))
    except ValueError as error:
        raise SystemExit(str(error)) from error


if __name__ == "__main__":
    main()
