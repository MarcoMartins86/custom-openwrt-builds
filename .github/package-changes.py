#!/usr/bin/env python3
"""Lists what changed between two ImageBuilder package lists (*.manifest).

usage: package-changes.py before.manifest now.manifest

Prints the changes as Markdown, or nothing when the two lists are the same.
"""
import sys


def read(path):
    """Reads lines of the form "name - version" into a dict."""
    packages = {}
    with open(path, encoding="utf-8") as manifest:
        for line in manifest:
            name, sep, version = line.strip().partition(" - ")
            if sep:
                packages[name] = version
    return packages


def main():
    before, now = read(sys.argv[1]), read(sys.argv[2])
    updated = sorted(n for n in before.keys() & now.keys() if before[n] != now[n])
    added = sorted(now.keys() - before.keys())
    removed = sorted(before.keys() - now.keys())
    if updated:
        print("| Package | Before | Now |")
        print("|---|---|---|")
        for name in updated:
            print(f"| `{name}` | {before[name]} | {now[name]} |")
        print()
    if added:
        print("Added: " + ", ".join(f"`{n}` {now[n]}" for n in added))
        print()
    if removed:
        print("Removed: " + ", ".join(f"`{n}` {before[n]}" for n in removed))
        print()


main()
