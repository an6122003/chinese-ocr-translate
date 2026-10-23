# HanLens dictionary data — sources and licences

`hanzi.sqlite` (built by `scripts/build_dictionary.py`) combines the sources below. Because it adapts
CC BY-SA 4.0 material (CVDICT and CC-CEDICT), **the database itself is licensed under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)**. The HanLens source code is not affected.

Changes made: CVDICT and CC-CEDICT entries were merged per (traditional, simplified, pinyin) reading;
duplicate senses removed; Hán Việt readings, HSK levels and word frequencies attached to entries;
Tatoeba sentences indexed by simplified form.

| Data | Source (pinned version) | Licence | Credit |
|---|---|---|---|
| Vietnamese definitions | [CVDICT](https://github.com/ph0ngp/CVDICT) — *Từ điển Hán Việt CVDICT* by Phong Phan, commit `c379d909` (vendored: the upstream repository is no longer online; copy from the fork `teefan/CVDICT`) | CC BY-SA 4.0 | Phong Phan; based on CC-CEDICT |
| English definitions | [CC-CEDICT](https://www.mdbg.net/chinese/dictionary?page=cc-cedict), via the Zhongwen extension at commit `5b92f3e` (audited 2026-10-23) | CC BY-SA 4.0 | MDBG; CEDICT — Copyright © 1997, 1998 Paul Andrew Denisowski |
| Hán Việt readings | [hanviet-pinyin-wordlist](https://github.com/ph0ngp/hanviet-pinyin-wordlist), commit `b9923df9` (vendored; fork `teefan/hanviet-pinyin-wordlist`) | MIT | Copyright © 2024 Phong Phan — `vendor/licenses/hanviet-pinyin-wordlist-LICENSE.txt` |
| Hán Việt validation | Thiều Chửu, *Hán Việt tự điển* (1942), digitized by [catusf/tudien](https://github.com/catusf/tudien) at commit `a7dd918` — used to keep native (Nôm) readings such as 喝 "húp" out of the Hán Việt column, and as a fallback | Public domain; digitization CC0-1.0 | Thiều Chửu; catusf/tudien |
| Character readings, variants, reading frequencies | [Unicode Han Database (Unihan)](https://www.unicode.org/charts/unihan.html) 18.0.0 | Unicode License v3 | Copyright © 1991–2026 Unicode, Inc. — `vendor/licenses/unicode-license.txt` |
| Example sentences | [Tatoeba](https://tatoeba.org) export of 2026-10-17 (vendored subset with each sentence's id and author) | CC BY 2.0 FR | Tatoeba contributors; each sentence is credited in the app as "Tatoeba #id · author" |
| HSK 3.0 levels | [ivankra/hsk30](https://github.com/ivankra/hsk30), commit `4ff9e39` | MIT | Copyright © 2023 Ivan Krasilnikov, © 2021 Shawky — `vendor/licenses/hsk30-LICENSE.txt` |
| Word frequencies | [jieba](https://github.com/fxsjy/jieba) `dict.txt`, commit `67fa2e3` | MIT | Copyright © 2013 Sun Junyi — `vendor/licenses/jieba-LICENSE.txt` |
| Grammar links | Keyword list from [Zhongwen](https://github.com/cschiller/zhongwen) (`grammarKeywordsMin.json`), linking to the [Chinese Grammar Wiki](https://resources.allsetlearning.com/chinese/grammar/) by AllSet Learning | Zhongwen repository: GPL-2.0 | Christian Schiller; AllSet Learning |

## Notes

- **Translation services**: Google Translate (online) and Apple's Translation framework (on-device) are used
  at runtime; nothing from them is stored in the bundled data.
- **Vendored copies**: CVDICT and the Hán Việt list disappeared from GitHub in 2026; the vendored files are
  byte-identical to the last upstream commits (SHA-256 `4dde4b20…0948` and `dd90d59d…6d66`, verified against
  two independent copies).
- **Not used**: Tatoeba audio (no licence for reuse), dictionaries with unclear licences (OVDP, TrungViet,
  hvdic/thivien, VietPhrase).
