#!/usr/bin/env python3
"""Build Data/hanzi.sqlite, the offline dictionary bundled with HanLens.

Inputs (see Data/sources.lock.json and Data/vendor/):
  CVDICT (Vietnamese senses) + CC-CEDICT (English senses) merged per (traditional, simplified, pinyin);
  the Hán Việt word list keyed by (traditional character, pinyin) for reading-correct Hán Việt;
  Unihan for simplified↔traditional variants, common readings and reading frequencies;
  HSK 3.0 levels; jieba word frequencies; Tatoeba example sentences; Chinese Grammar Wiki keywords.

The resulting database is an adaptation of CC BY-SA 4.0 data and is itself CC BY-SA 4.0
(see Data/LICENSES.md).

Usage:  python3 -I macos/scripts/build_dictionary.py
"""
import csv
import gzip
import io
import json
import pathlib
import re
import sqlite3
import sys
import unicodedata
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "Data"
CACHE = DATA / "cache"
VENDOR = DATA / "vendor"
OUTPUT = DATA / "hanzi.sqlite"
SCHEMA_VERSION = 1
MAX_WORD_LENGTH = 12

ENTRY_LINE = re.compile(r"^(\S+) (\S+) \[([^\]]*)\] /(.*)/\s*$")
SYLLABLE = re.compile(r"^([a-zA-Zü:]+)([1-5])$")
TONE_MARKS = {"̄": 1, "́": 2, "̌": 3, "̀": 4}


def is_han(ch: str) -> bool:
    cp = ord(ch)
    return (0x4E00 <= cp <= 0x9FFF or 0x3400 <= cp <= 0x4DBF or 0xF900 <= cp <= 0xFAFF or cp == 0x3007
            or 0x20000 <= cp <= 0x323AF or 0x2F800 <= cp <= 0x2FA1F)


# ---------------------------------------------------------------------------------------------
# Pinyin helpers (keys must match the Swift side: Pinyin.comparisonKey + tone digit, ü → v)

def syllable_key(numbered: str) -> str | None:
    """'Hang2' → 'hang2', 'lu:4' → 'lv4', 'r5' → 'r5'; None for non-syllables like '·' or 'A'."""
    match = SYLLABLE.match(numbered)
    if not match:
        return None
    body = match.group(1).lower().replace("u:", "v").replace("ü", "v")
    return body + match.group(2)


def marked_to_key(marked: str) -> str:
    """'xíng' → 'xing2', 'lǜ' → 'lv4', 'le' → 'le5'."""
    tone = 5
    letters = []
    for ch in unicodedata.normalize("NFD", marked.strip().lower()):
        if ch in TONE_MARKS:
            tone = TONE_MARKS[ch]
        elif ch == "̈":
            if letters and letters[-1] == "u":
                letters[-1] = "v"
        elif ch.isalpha():
            letters.append(ch)
    return "".join(letters).replace("ü", "v") + str(tone)


def toneless(key: str) -> str:
    return key.rstrip("12345")


# ---------------------------------------------------------------------------------------------
# Readers

def read_cedict_like(lines, label: str) -> dict:
    """Parses CC-CEDICT-format lines into {(trad, simp, pinyin): [senses]} preserving order."""
    entries: dict = {}
    malformed = 0
    for raw in lines:
        line = raw.rstrip("\r\n")
        if not line or line.startswith("#"):
            continue
        match = ENTRY_LINE.match(line)
        if not match:
            malformed += 1
            continue
        trad, simp, pinyin, definitions = match.groups()
        pinyin = " ".join(pinyin.split())
        senses = entries.setdefault((trad, simp, pinyin), [])
        for sense in definitions.split("/"):
            sense = sense.strip()
            if sense and sense not in senses:
                senses.append(sense)
    print(f"  {label}: {len(entries):,} entries ({malformed} malformed lines skipped)")
    return entries


def read_unihan() -> dict:
    """Returns the Unihan fields we use, keyed by character."""
    wanted = {"kMandarin", "kHanyuPinlu", "kVietnamese", "kTraditionalVariant", "kSimplifiedVariant"}
    fields: dict = {name: {} for name in wanted}
    with zipfile.ZipFile(CACHE / "Unihan-18.0.0.zip") as archive:
        for member in ("Unihan_Readings.txt", "Unihan_Variants.txt"):
            with archive.open(member) as handle:
                for line in io.TextIOWrapper(handle, encoding="utf-8"):
                    if not line.startswith("U+"):
                        continue
                    code, field, value = line.rstrip("\n").split("\t", 2)
                    if field in wanted:
                        fields[field][chr(int(code[2:], 16))] = value
    print(f"  Unihan: kMandarin {len(fields['kMandarin']):,}, kHanyuPinlu {len(fields['kHanyuPinlu']):,}, "
          f"kVietnamese {len(fields['kVietnamese']):,}")
    return fields


def variant_chars(value: str | None) -> list:
    if not value:
        return []
    return [chr(int(token.split("<")[0][2:], 16)) for token in value.split() if token.startswith("U+")]


# Vietnamese tone marks (combining forms) — everything else (â ê ô ơ ư ă đ) is part of the base syllable.
VN_TONES = {"\u0300": 1, "\u0301": 2, "\u0303": 3, "\u0309": 4, "\u0323": 5}


def vn_key(syllable: str) -> tuple:
    """Spelling-insensitive key for a Vietnamese syllable: 'hoà' = 'hòa', 'thuỷ' = 'thủy', 'ký' = 'kí'."""
    base, tone = [], 0
    for ch in unicodedata.normalize("NFD", syllable.strip().lower()):
        if ch in VN_TONES:
            tone = VN_TONES[ch]
        else:
            base.append(ch)
    text = unicodedata.normalize("NFC", "".join(base))
    if len(text) >= 2 and text[-1] == "y" and text[-2] not in "aeiouăâêôơưy":
        text = text[:-1] + "i"
    return text, tone


def read_thieu_chuu() -> dict:
    """{char: [Hán Việt readings]} from Thiều Chửu's Hán Việt tự điển (1942)."""
    readings: dict = {}
    with (CACHE / "TudienThienChuu.tab").open(encoding="utf-8") as handle:
        for line in handle:
            if "\t" not in line:
                continue
            char, rest = line.split("\t", 1)
            head = re.sub(r"\(.*?\)", "", rest.split("<br>")[0])
            values = [r.strip().lower() for r in head.split("|") if r.strip()]
            if char.strip() and values:
                readings[char.strip()] = values
    print(f"  Thiều Chửu: {len(readings):,} characters")
    return readings


def read_hanviet(valid_syllables: set) -> tuple:
    """(by_reading {(char, key): [hv…]}, any_reading {char: [hv…]}, all_rows {char: [[hv…]…]}).

    The word list sometimes gives a native (Nôm) reading such as 喝 → "húp" or 讀 → "đọc". Readings that are not
    Sino-Vietnamese syllables at all (absent from every Thiều Chửu entry) are moved behind valid ones.
    """
    by_reading: dict = {}
    any_reading: dict = {}
    all_rows: dict = {}
    demoted = 0
    with (VENDOR / "hanviet.csv").open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            char = row["char"].strip()
            readings = [r.strip() for r in re.findall(r"'([^']*)'", row["hanviet"]) if r.strip()]
            if not char or not readings:
                continue
            ordered = sorted(readings, key=lambda r: vn_key(r) not in valid_syllables)
            if ordered[0] != readings[0]:
                demoted += 1
            readings = ordered
            all_rows.setdefault(char, []).append(readings)
            pinyin = row["pinyin"].strip()
            if pinyin == "*":
                any_reading.setdefault(char, readings)
            else:
                key = syllable_key(pinyin) or marked_to_key(pinyin)
                by_reading.setdefault((char, key), readings)
    print(f"  Hán Việt list: {len(by_reading):,} char+reading rows, {len(any_reading):,} any-reading rows "
          f"({demoted} rows reordered to put a Sino-Vietnamese reading first)")
    return by_reading, any_reading, all_rows


def read_hsk() -> list:
    """[(simplified, traditional, cedict_keys[(trad, simp, pinyin)], level)]"""
    rows = []
    reference = re.compile(r"([^\s|\[\]]+)\|?([^\s|\[\]]*)\[([^\]]+)\]")
    with (CACHE / "hsk30.csv").open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            level = 7 if row["Level"].startswith("7") else int(row["Level"])
            keys = []
            for trad, simp, pinyin in reference.findall(row["CEDICT"]):
                keys.append((trad, simp or trad, " ".join(pinyin.split())))
            rows.append((row["Simplified"].strip(), row["Traditional"].strip(), keys, level))
    print(f"  HSK 3.0: {len(rows):,} words")
    return rows


def read_jieba() -> dict:
    frequencies: dict = {}
    with (CACHE / "jieba-dict.txt").open(encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                frequencies[parts[0]] = max(frequencies.get(parts[0], 0), int(parts[1]))
    print(f"  jieba: {len(frequencies):,} words")
    return frequencies


# ---------------------------------------------------------------------------------------------

def main() -> int:
    print("Reading sources…")
    with (CACHE / "cedict_ts.u8").open(encoding="utf-8") as handle:
        cedict = read_cedict_like(handle, "CC-CEDICT")
    with gzip.open(VENDOR / "CVDICT.u8.gz", "rt", encoding="utf-8") as handle:
        cvdict = read_cedict_like(handle, "CVDICT")
    unihan = read_unihan()
    thieu_chuu = read_thieu_chuu()
    valid_syllables = {vn_key(r) for values in thieu_chuu.values() for r in values}
    hv_by_reading, hv_any, hv_rows = read_hanviet(valid_syllables)
    hsk = read_hsk()
    jieba = read_jieba()
    grammar = list(json.loads((CACHE / "grammarKeywordsMin.json").read_text(encoding="utf-8")).keys())

    # --- Merge Vietnamese and English senses -------------------------------------------------
    def loose(key):
        trad, simp, pinyin = key
        return (trad, simp, pinyin.lower().replace("u:", "v"))

    cedict_loose = {}
    for key in cedict:
        cedict_loose.setdefault(loose(key), key)
    merged: dict = {}
    order: list = []
    for key, senses in cedict.items():
        merged[key] = {"en": senses, "vi": []}
        order.append(key)
    matched_exact = matched_loose = added_vi_only = 0
    for key, senses in cvdict.items():
        if key in merged:
            merged[key]["vi"] = senses
            matched_exact += 1
        elif loose(key) in cedict_loose:
            merged[cedict_loose[loose(key)]]["vi"] = senses
            matched_loose += 1
        else:
            merged[key] = {"en": [], "vi": senses}
            order.append(key)
            added_vi_only += 1
    with_vi = sum(1 for value in merged.values() if value["vi"])
    print(f"Merged: {len(merged):,} entries; Vietnamese for {with_vi:,} "
          f"({matched_exact:,} exact, {matched_loose:,} loose, {added_vi_only:,} CVDICT-only)")

    # --- Simplified ↔ traditional character maps --------------------------------------------
    simp_to_trad: dict = {}
    trad_to_simp: dict = {}
    for (trad, simp, _pinyin) in order:
        if len(trad) == len(simp):
            for t, s in zip(trad, simp):
                if is_han(t) and is_han(s):
                    simp_to_trad.setdefault(s, [])
                    if t not in simp_to_trad[s]:
                        simp_to_trad[s].append(t)
                    trad_to_simp.setdefault(t, s)
    for char, value in unihan["kTraditionalVariant"].items():
        for t in variant_chars(value):
            simp_to_trad.setdefault(char, [])
            if t not in simp_to_trad[char]:
                simp_to_trad[char].append(t)
    for char, value in unihan["kSimplifiedVariant"].items():
        variants = [v for v in variant_chars(value) if v != char] or variant_chars(value)
        if variants:
            trad_to_simp.setdefault(char, variants[0])

    # --- Reading frequencies -------------------------------------------------------------------
    pinlu: dict = {}  # (char, key) → count
    for char, value in unihan["kHanyuPinlu"].items():
        for marked, count in re.findall(r"([^\s(]+)\((\d+)\)", value):
            pinlu[(char, marked_to_key(marked))] = int(count)

    # --- Hán Việt -------------------------------------------------------------------------------
    hv_toneless: dict = {}
    for (char, key), readings in hv_by_reading.items():
        hv_toneless.setdefault((char, toneless(key)), readings)

    def hanviet_for(trad_char: str, simp_char: str, key: str | None) -> str:
        """Hán Việt for one character in a specific reading; a non-Sino-Vietnamese (Nôm) reading is replaced by
        Thiều Chửu's reading when he lists one."""
        reading = hanviet_lookup(trad_char, simp_char, key)
        if reading and vn_key(reading) not in valid_syllables:
            for char in [trad_char, simp_char] + simp_to_trad.get(simp_char, []):
                if char in thieu_chuu:
                    return thieu_chuu[char][0]
        return reading

    def hanviet_lookup(trad_char: str, simp_char: str, key: str | None) -> str:
        candidates = [trad_char] + ([simp_char] if simp_char != trad_char else [])
        candidates += [t for t in simp_to_trad.get(simp_char, []) if t not in candidates]
        if key:
            for char in candidates:
                if (char, key) in hv_by_reading:
                    return hv_by_reading[(char, key)][0]
            for char in candidates:  # tone-insensitive: neutral tones and alternate tone spellings
                matches = hv_toneless.get((char, toneless(key)))
                if matches:
                    return matches[0]
        for char in candidates:
            if char in hv_any:
                return hv_any[char][0]
        for char in candidates:
            if char in hv_rows:
                return hv_rows[char][0][0]
        for char in candidates:
            if char in thieu_chuu:
                return thieu_chuu[char][0]
        for char in candidates:  # last resort; kVietnamese mixes in Nôm readings, so only accept Sino-Vietnamese ones
            for value in unihan["kVietnamese"].get(char, "").split():
                if vn_key(value) in valid_syllables:
                    return value
        return ""

    # --- HSK levels ------------------------------------------------------------------------------
    hsk_level: dict = {}
    hsk_by_simplified: dict = {}
    for simplified, _traditional, keys, level in hsk:
        for key in keys:
            if key in merged:
                hsk_level[key] = min(level, hsk_level.get(key, 99))
            elif loose(key) in cedict_loose:
                real = cedict_loose[loose(key)]
                hsk_level[real] = min(level, hsk_level.get(real, 99))
        if not keys:
            hsk_by_simplified.setdefault(simplified, level)
    for key in order:
        if key not in hsk_level and key[1] in hsk_by_simplified and not key[2][:1].isupper():
            hsk_level[key] = hsk_by_simplified[key[1]]

    # --- Build the database ----------------------------------------------------------------------
    print("Writing database…")
    temporary = OUTPUT.with_suffix(".sqlite.tmp")
    if temporary.exists():
        temporary.unlink()
    db = sqlite3.connect(temporary)
    db.executescript("""
        PRAGMA page_size = 4096;
        PRAGMA journal_mode = OFF;
        PRAGMA synchronous = OFF;
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE entries (
            id INTEGER PRIMARY KEY,
            trad TEXT NOT NULL,
            simp TEXT NOT NULL,
            pinyin TEXT NOT NULL,       -- CC-CEDICT numbered pinyin
            vi TEXT,                    -- Vietnamese senses, newline-separated
            en TEXT,                    -- English senses, newline-separated
            hv TEXT,                    -- Hán Việt per character, '|'-separated ('' if unknown)
            hsk INTEGER,                -- HSK 3.0 level (1–6, 7 = 7–9)
            freq INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE chars (
            ch TEXT PRIMARY KEY,
            hanviet TEXT,               -- comma-separated, the reading for the most common pronunciation first
            pinyin TEXT                 -- most common Mandarin reading, tone-marked
        ) WITHOUT ROWID;
        CREATE TABLE char_readings (
            ch TEXT NOT NULL,
            pinyin TEXT NOT NULL,       -- 'hang2', 'lv4', 'le5'
            hanviet TEXT NOT NULL,
            PRIMARY KEY (ch, pinyin)
        ) WITHOUT ROWID;
        CREATE TABLE sentences (
            id INTEGER PRIMARY KEY,     -- Tatoeba sentence id
            zh TEXT NOT NULL,
            zh_s TEXT NOT NULL,         -- simplified form, for searching
            en TEXT,
            vi TEXT,
            author TEXT
        );
        CREATE TABLE grammar (word TEXT PRIMARY KEY) WITHOUT ROWID;
    """)

    entry_rows = []
    hv_complete = hv_partial = 0
    max_length = 0
    for index, key in enumerate(order, start=1):
        trad, simp, pinyin = key
        senses = merged[key]
        syllables = [syllable_key(token) for token in pinyin.split()]
        hv = ""
        if len(trad) == len(simp) == len(syllables) and all(is_han(c) for c in trad) and all(syllables):
            readings = [hanviet_for(t, s, k) for t, s, k in zip(trad, simp, syllables)]
            if any(readings):
                hv = "|".join(readings)
                if all(readings):
                    hv_complete += 1
                else:
                    hv_partial += 1
        if len(simp) == 1 and syllables and syllables[0]:
            frequency = pinlu.get((simp, syllables[0]), 0) or pinlu.get((trad, syllables[0]), 0)
        else:
            frequency = jieba.get(simp, 0)
        max_length = max(max_length, len(simp), len(trad))
        entry_rows.append((index, trad, simp, pinyin, "\n".join(senses["vi"]) or None, "\n".join(senses["en"]) or None,
                           hv or None, hsk_level.get(key), frequency))
    db.executemany("INSERT INTO entries VALUES (?,?,?,?,?,?,?,?,?)", entry_rows)
    db.execute("CREATE INDEX entries_simp ON entries(simp)")
    db.execute("CREATE INDEX entries_trad ON entries(trad)")
    print(f"  entries: {len(entry_rows):,}; Hán Việt complete for {hv_complete:,}, partial {hv_partial:,}")

    # Character readings: every (character, pronunciation) pair seen in single-character entries.
    reading_rows: dict = {}
    char_pronunciations: dict = {}
    for (trad, simp, pinyin) in order:
        if len(trad) != 1 or len(simp) != 1:
            continue
        key = syllable_key(pinyin)
        if not key or pinyin[:1].isupper() and (trad, simp, pinyin.lower()) in merged:
            continue
        hv = hanviet_for(trad, simp, key)
        for char in {trad, simp}:
            if is_han(char):
                char_pronunciations.setdefault(char, [])
                if key not in char_pronunciations[char]:
                    char_pronunciations[char].append(key)
                if hv:
                    reading_rows.setdefault((char, key), hv)
    for (char, key), readings in hv_by_reading.items():
        reading_rows.setdefault((char, key), readings[0])
    db.executemany("INSERT INTO char_readings VALUES (?,?,?)", [(c, k, h) for (c, k), h in reading_rows.items()])
    print(f"  char readings: {len(reading_rows):,}")

    # Characters: common Mandarin reading, Hán Việt readings ordered by how common their pronunciation is.
    def reading_frequency(char: str, key: str) -> int:
        return pinlu.get((char, key), 0)

    char_rows = []
    all_chars = set(char_pronunciations) | {c for c, _ in hv_by_reading} | set(hv_any)
    for (trad, simp, _p) in order:
        all_chars.update(c for c in trad + simp if is_han(c))
    for char in sorted(all_chars):
        keys = sorted(char_pronunciations.get(char, []), key=lambda k: -reading_frequency(char, k))
        common = unihan["kMandarin"].get(char, "").split()
        if common:
            common_key = marked_to_key(common[0])
            keys = sorted(keys, key=lambda k: (k != common_key, -reading_frequency(char, k)))
        hv_list = []
        for key in keys:
            hv = reading_rows.get((char, key))
            if hv and hv not in hv_list:
                hv_list.append(hv)
        for candidate in [char] + simp_to_trad.get(char, []):
            for readings in hv_rows.get(candidate, []):
                for hv in readings:
                    if hv not in hv_list and vn_key(hv) in valid_syllables:
                        hv_list.append(hv)
        if not hv_list:
            for candidate in [char] + simp_to_trad.get(char, []):
                for hv in thieu_chuu.get(candidate, []):
                    if hv not in hv_list:
                        hv_list.append(hv)
        mandarin = common[0] if common else None
        char_rows.append((char, ",".join(hv_list) or None, mandarin))
    db.executemany("INSERT INTO chars VALUES (?,?,?)", char_rows)
    print(f"  characters: {len(char_rows):,} ({sum(1 for r in char_rows if r[1]):,} with Hán Việt)")

    # Example sentences, searchable in simplified form.
    trad_words = {}
    for (trad, simp, _p) in order:
        if trad != simp and 1 < len(trad) <= 4:
            trad_words.setdefault(trad, simp)

    def to_simplified(text: str) -> str:
        out = []
        i = 0
        while i < len(text):
            for length in (4, 3, 2):
                piece = text[i:i + length]
                if len(piece) == length and piece in trad_words:
                    out.append(trad_words[piece])
                    i += length
                    break
            else:
                out.append(trad_to_simp.get(text[i], text[i]))
                i += 1
        return "".join(out)

    sentence_rows = []
    with gzip.open(VENDOR / "tatoeba-cmn.tsv.gz", "rt", encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle, delimiter="\t"):
            zh = row["zh"]
            sentence_rows.append((int(row["id"]), zh, to_simplified(zh), row["en"] or None, row["vi"] or None,
                                  row["user"] or None))
    db.executemany("INSERT INTO sentences VALUES (?,?,?,?,?,?)", sentence_rows)
    print(f"  sentences: {len(sentence_rows):,}")

    db.executemany("INSERT OR IGNORE INTO grammar VALUES (?)", [(w,) for w in grammar])

    sources = json.loads((DATA / "sources.lock.json").read_text(encoding="utf-8"))["sources"]
    meta = {
        "schema_version": str(SCHEMA_VERSION),
        "max_word_length": str(min(max_length, MAX_WORD_LENGTH)),
        "entries": str(len(entry_rows)),
        "license": "CC BY-SA 4.0 (adaptation of CVDICT and CC-CEDICT); see LICENSES.md",
        "sources": json.dumps([{"name": s["name"], "url": s["url"], "license": s["license"]} for s in sources]
                              + [{"name": "CVDICT", "url": "https://github.com/ph0ngp/CVDICT", "license": "CC BY-SA 4.0"},
                                 {"name": "hanviet-pinyin-wordlist", "url": "https://github.com/ph0ngp/hanviet-pinyin-wordlist",
                                  "license": "MIT"},
                                 {"name": "Tatoeba", "url": "https://tatoeba.org", "license": "CC BY 2.0 FR"}],
                              ensure_ascii=False),
    }
    db.executemany("INSERT INTO meta VALUES (?,?)", list(meta.items()))
    db.commit()
    db.execute("VACUUM")
    db.close()
    temporary.replace(OUTPUT)
    print(f"Wrote {OUTPUT.relative_to(ROOT.parent)} ({OUTPUT.stat().st_size / 1e6:.1f} MB)")

    report(sqlite3.connect(OUTPUT))
    return 0


def report(db: sqlite3.Connection) -> None:
    """Spot checks that are easy to eyeball."""
    print("\nSpot checks:")
    for word in ["银行", "行长", "图书馆", "长城", "学习", "觉得", "干净", "了解", "中国", "银行家", "一石二鸟",
                 "喝水", "读书", "种树", "号码", "什么", "比较"]:
        rows = db.execute("SELECT pinyin, hv, hsk, freq, substr(replace(vi, char(10), '; '), 1, 60) FROM entries "
                          "WHERE simp = ? ORDER BY hsk IS NULL, freq DESC", (word,)).fetchall()
        for pinyin, hv, hsk, freq, vi in rows[:2]:
            print(f"  {word:6} [{pinyin}] HV={hv} HSK={hsk} freq={freq} vi={vi}")
    for char in ["行", "长", "了", "学", "们", "这", "喝", "读", "种", "号", "什", "比"]:
        print(f"  char {char}: {db.execute('SELECT hanviet, pinyin FROM chars WHERE ch = ?', (char,)).fetchone()}")


if __name__ == "__main__":
    sys.exit(main())
