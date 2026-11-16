#!/usr/bin/env python3
"""Select the unique large existing Btrfs filesystem and expose its UUID symlink."""

import argparse
import json
import os
import pathlib
import sys


def walk_devices(blockdevices):
    for device in blockdevices:
        yield device
        yield from walk_devices(device.get("children", []))


def discover(document, min_bytes):
    matches = [
        device
        for device in walk_devices(document.get("blockdevices", []))
        if device.get("fstype") == "btrfs"
        and int(device.get("size") or 0) >= min_bytes
        and device.get("uuid")
    ]
    if len(matches) != 1:
        candidates = [
            f'{item.get("path", "?")}:{item.get("fstype", "unknown")}:{item.get("size", 0)}'
            for item in matches
        ]
        raise ValueError(
            "Expected exactly one Btrfs filesystem at or above the configured size; "
            f"found {len(matches)} candidates: {candidates}"
        )
    return matches[0]["uuid"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--min-bytes", type=int, required=True)
    parser.add_argument("--link", required=True)
    args = parser.parse_args()

    try:
        uuid = discover(json.load(sys.stdin), args.min_bytes)
        link = pathlib.Path(args.link)
        link.parent.mkdir(parents=True, exist_ok=True)
        temporary = link.with_name(link.name + ".new")
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        temporary.symlink_to(f"/dev/disk/by-uuid/{uuid}")
        os.replace(temporary, link)
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print(f"NAS discovery failed without changing any disk: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
