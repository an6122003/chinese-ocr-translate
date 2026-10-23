#!/usr/bin/env python3
"""Rebuild Data/vendor/tatoeba-cmn.tsv.gz — Mandarin example sentences with English and
Vietnamese translations from Tatoeba (CC BY 2.0 FR). Each row keeps the sentence id and the
author's username, which the licence requires us to credit.

Tatoeba's exports change weekly, so the processed subset is vendored and this script is only
run occasionally:   python3 -I macos/scripts/update_tatoeba.py
"""
import bz2
import csv
import gzip
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
CACHE = ROOT / "Data" / "cache" / "tatoeba"
OUTPUT = ROOT / "Data" / "vendor" / "tatoeba-cmn.tsv.gz"
BASE = "https://downloads.tatoeba.org/exports/per_language/"
FILES = [
    "cmn/cmn_sentences_detailed.tsv.bz2",
    "cmn/cmn-eng_links.tsv.bz2",
    "cmn/cmn-vie_links.tsv.bz2",
    "eng/eng_sentences.tsv.bz2",
    "vie/vie_sentences.tsv.bz2",
]
MIN_HAN, MAX_HAN = 3, 40


def fetch(path: str) -> pathlib.Path:
    destination = CACHE / pathlib.Path(path).name
    if not destination.exists():
        print(f"↓ {path}")
        request = urllib.request.Request(BASE + path, headers={"User-Agent": "HanLens-data-builder/1.0"})
        temporary = destination.with_suffix(".part")
        with urllib.request.urlopen(request, timeout=300) as response, temporary.open("wb") as out:
            while chunk := response.read(1 << 20):
                out.write(chunk)
        temporary.replace(destination)
    return destination


def rows(path: pathlib.Path):
    with bz2.open(path, "rt", encoding="utf-8", newline="") as handle:
        for line in handle:
            yield line.rstrip("\n").split("\t")


def han_count(text: str) -> int:
    return sum(1 for ch in text if "㐀" <= ch <= "鿿" or "豈" <= ch <= "﫿")


def main() -> int:
    CACHE.mkdir(parents=True, exist_ok=True)
    paths = {pathlib.Path(p).name: fetch(p) for p in FILES}

    chinese = {}
    for fields in rows(paths["cmn_sentences_detailed.tsv.bz2"]):
        if len(fields) < 4 or fields[1] != "cmn":
            continue
        sentence_id, text, user = int(fields[0]), fields[2].strip(), fields[3].strip()
        if MIN_HAN <= han_count(text) <= MAX_HAN and "\t" not in text:
            chinese[sentence_id] = (text, user if user != "\\N" else "")

    def linked(links_file: str, sentences_file: str, language: str) -> dict:
        targets = {}
        for fields in rows(paths[links_file]):
            source, target = int(fields[0]), int(fields[1])
            if source in chinese:
                targets.setdefault(source, []).append(target)
        wanted = {t for ts in targets.values() for t in ts}
        texts = {}
        for fields in rows(paths[sentences_file]):
            if len(fields) >= 3 and fields[1] == language and int(fields[0]) in wanted:
                texts[int(fields[0])] = fields[2].strip()
        # The oldest translation (lowest id) is usually the canonical one.
        return {s: texts[min(t for t in ts if t in texts)] for s, ts in targets.items() if any(t in texts for t in ts)}

    english = linked("cmn-eng_links.tsv.bz2", "eng_sentences.tsv.bz2", "eng")
    vietnamese = linked("cmn-vie_links.tsv.bz2", "vie_sentences.tsv.bz2", "vie")

    seen = set()
    kept = []
    # Sentences with a Vietnamese translation first, so duplicates keep the Vietnamese one.
    for sentence_id in sorted(chinese, key=lambda i: (i not in vietnamese, i)):
        text, user = chinese[sentence_id]
        if text in seen or (sentence_id not in english and sentence_id not in vietnamese):
            continue
        seen.add(text)
        kept.append((sentence_id, user, text, english.get(sentence_id, ""), vietnamese.get(sentence_id, "")))
    kept.sort()

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with gzip.GzipFile(OUTPUT, "wb", compresslevel=9, mtime=0) as raw:
        with open_text(raw) as out:
            writer = csv.writer(out, delimiter="\t", lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
            writer.writerow(["id", "user", "zh", "en", "vi"])
            writer.writerows(kept)
    with_vi = sum(1 for row in kept if row[4])
    print(f"Wrote {len(kept)} sentences ({with_vi} with Vietnamese) to {OUTPUT.relative_to(ROOT.parent)}")
    return 0


def open_text(raw):
    import io
    return io.TextIOWrapper(raw, encoding="utf-8", newline="")


if __name__ == "__main__":
    sys.exit(main())
