#!/usr/bin/env python3
"""Download the pinned dictionary sources into macos/Data/cache and verify their SHA-256.

Sources whose upstream disappeared (CVDICT, the Hán Việt word list) and the processed
Tatoeba subset are vendored in macos/Data/vendor instead and are not downloaded here.

Usage:  python3 -I macos/scripts/fetch_sources.py [--update-lock]
"""
import hashlib
import json
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "Data"
CACHE = DATA / "cache"
LOCK = DATA / "sources.lock.json"


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: pathlib.Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": "HanLens-data-builder/1.0"})
    temporary = destination.with_suffix(destination.suffix + ".part")
    with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as out:
        while chunk := response.read(1 << 20):
            out.write(chunk)
    temporary.replace(destination)


def main() -> int:
    update_lock = "--update-lock" in sys.argv
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    CACHE.mkdir(parents=True, exist_ok=True)
    changed = False
    for source in lock["sources"]:
        path = CACHE / source["file"]
        expected = source.get("sha256")
        if path.exists() and expected and sha256(path) == expected:
            print(f"✓ {source['file']} (cached)")
            continue
        print(f"↓ {source['file']} ← {source['url']}")
        download(source["url"], path)
        actual = sha256(path)
        if expected and actual != expected and not update_lock:
            path.unlink()
            print(f"  ✗ checksum mismatch for {source['file']}: expected {expected}, got {actual}", file=sys.stderr)
            return 1
        if actual != expected:
            # First download (trust on first use) or an explicit --update-lock.
            source["sha256"] = actual
            changed = True
        print(f"  ✓ {actual}")
    if changed:
        LOCK.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"Updated {LOCK.relative_to(ROOT.parent)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
