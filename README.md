# Pinyin Input & Chinese Dictionary 🏮

A lightweight Windows background utility for typing Pinyin with tone marks, translating Chinese text, and performing OCR on non-selectable Chinese characters.

> **🍎 On a Mac?** See [`macos/`](macos/README.md) — **HanLens**, a native macOS version with circle-to-search
> selection, offline Vietnamese dictionary, Hán Việt readings, example sentences, subtitle "Follow" mode and more.
> [Download the latest DMG](https://github.com/an6122003/chinese-ocr-translate/releases/latest), or build it with
> `cd macos && make install`. Ideas for an iPad version: [`docs/ipados-circle-to-search.md`](docs/ipados-circle-to-search.md).

## ✨ Features

### 📝 Pinyin Input
- **System-wide**: Works in any app (Notepad, Word, Chrome, etc.)
- **Intuitive**: Just type the Pinyin syllable and press `1`, `2`, `3`, or `4`.
- **Smart**: Automatically places the tone mark on the correct vowel (standard rules).
- **Lightweight**: Minimal CPU/RAM usage.

### 📖 Dictionary / Translation
- **Highlight & Translate**: Select any Chinese text, press `Alt+X` to get:
  - Pinyin annotations
  - Vietnamese translation
  - Word component breakdown (jieba segmentation)
- **Configurable Shortcut**: Change the hotkey in Settings.

### 🔍 OCR Capture (Circle to Search)
- **Screen Capture**: Press `Alt+S` to activate the selection overlay.
- **Drag to Select**: Draw a rectangle around any Chinese text on screen.
- **Two Actions**:
  - 📋 **Copy Text** — copies recognized text to clipboard
  - 📖 **Translate** — opens the dictionary tooltip with pinyin + translation
- Works on **non-selectable text** (images, PDFs, videos, etc.)
- Uses **Windows native OCR** — fast and no extra models needed.

## 🚀 How to Use

1. **Run the app**: Execute `run_pinyin.bat` or run `python app.py` directly.
2. **Type Pinyin**: For example, type `ma`.
3. **Add Tone**: Press `1`. It immediately becomes `mā`.
   - `na2` ➔ `ná`
   - `na3` ➔ `nǎ`
   - `bu4` ➔ `bù`
   - `lv3` ➔ `lǚ` (typing `v` works for `ü`)
4. **Translate**: Highlight Chinese text → press `Alt+X`
5. **OCR**: Press `Alt+S` → drag over text → Copy or Translate

## 🛠 Prerequisites
- **Python 3.x**
- **Windows 10/11** (for OCR feature)
- Chinese OCR language pack (auto-detected; install via Windows Settings if needed)

## 📦 Install Dependencies
```bash
pip install -r requirements.txt
```

Or manually:
```bash
pip install pynput pystray Pillow pypinyin deep_translator jieba pyperclip winocr mss
```

## ⚙️ OCR Language Pack

If OCR doesn't detect Chinese text, install the language pack (run PowerShell as Admin):
```powershell
Add-WindowsCapability -Online -Name "Language.OCR~~~zh-CN~0.0.1.0"
```

## 📜 Standard Tone Rules
This app follows the standard Pinyin tone placement hierarchy:
1. `a` always gets the mark.
2. If no `a`, then `e` or `o` gets it.
3. If `iu` or `ui`, the second vowel gets it.
4. Otherwise, the primary vowel gets it.

---
Enjoy typing Pinyin! 🚀
