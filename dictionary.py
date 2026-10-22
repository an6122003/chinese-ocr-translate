"""
Dictionary Module
Handles Chinese text translation, pinyin annotation, word segmentation,
and the translation tooltip UI.
"""

import re
import threading
import time
import tkinter as tk
from pynput.keyboard import Key, Controller
from pynput import keyboard
import pyperclip
import pypinyin
from deep_translator import GoogleTranslator
import jieba


class DictionaryHandler:
    def __init__(self, tts_service=None):
        self.controller = Controller()
        self.hotkey_listener = None
        self.shortcut = "<alt>+x"
        self.tts = tts_service
        self._cjk_spacing_pattern = re.compile(
            r"(?<=[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3000-\u303f\uff00-\uffef])\s+"
            r"(?=[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3000-\u303f\uff00-\uffef])"
        )

    def normalize_text(self, text):
        """Collapse OCR-style spaces between adjacent CJK characters/punctuation."""
        if not text:
            return ""

        text = text.replace("\u00a0", " ")
        text = self._cjk_spacing_pattern.sub("", text)
        return text.strip()

    def _place_window_on_screen(self, window, x, y):
        window.update_idletasks()
        min_x = window.winfo_vrootx()
        min_y = window.winfo_vrooty()
        max_x = min_x + max(0, window.winfo_vrootwidth() - window.winfo_reqwidth())
        max_y = min_y + max(0, window.winfo_vrootheight() - window.winfo_reqheight())
        x = min(max(int(x), min_x), max_x)
        y = min(max(int(y), min_y), max_y)
        window.geometry(f"+{x}+{y}")

    def _make_window_draggable(self, window, drag_widgets):
        drag_state = {"x": 0, "y": 0}

        def _start_drag(event):
            drag_state["x"] = event.x_root - window.winfo_x()
            drag_state["y"] = event.y_root - window.winfo_y()

        def _on_drag(event):
            new_x = event.x_root - drag_state["x"]
            new_y = event.y_root - drag_state["y"]
            self._place_window_on_screen(window, new_x, new_y)

        for widget in drag_widgets:
            widget.bind("<ButtonPress-1>", _start_drag, add="+")
            widget.bind("<B1-Motion>", _on_drag, add="+")

    def _bind_drag_tree(self, window, widget, ignored=None):
        ignored = set(ignored or [])
        if widget not in ignored:
            self._make_window_draggable(window, [widget])
        for child in widget.winfo_children():
            if child not in ignored:
                self._bind_drag_tree(window, child, ignored)

    def set_shortcut(self, shortcut):
        """Update the translation shortcut key combination."""
        self.shortcut = shortcut
        self.restart_hotkey_listener()

    def restart_hotkey_listener(self):
        """Restart the global hotkey listener with the current shortcut."""
        if self.hotkey_listener:
            try:
                self.hotkey_listener.stop()
            except:
                pass
        self.hotkey_listener = keyboard.GlobalHotKeys({self.shortcut: self.translate_highlighted})
        self.hotkey_listener.start()

    def translate_highlighted(self):
        """Translate the currently highlighted/selected text."""
        # We need a small thread to not block the listener
        def _task():
            try:
                original_clip = pyperclip.paste()
            except:
                original_clip = ""

            # Wait a brief moment so the user physically releases Alt/Shift.
            # If they hold it, Windows sees Ctrl+Alt+C and ignores the copy command.
            time.sleep(0.4)

            # Force release typical modifier keys just in case
            for mod in [Key.alt, Key.alt_l, Key.alt_r, Key.shift, Key.shift_l, Key.shift_r, Key.ctrl, Key.ctrl_l, Key.ctrl_r, Key.cmd]:
                try:
                    self.controller.release(mod)
                except:
                    pass

            # Clear clipboard to know when copy arrives
            try:
                pyperclip.copy("")
            except:
                pass

            # Simulate Ctrl+C
            self.controller.press(Key.ctrl)
            self.controller.press('c')
            self.controller.release('c')
            self.controller.release(Key.ctrl)

            # Wait up to 1 second for clipboard to receive new text
            text = ""
            for _ in range(15):
                time.sleep(0.1)
                try:
                    text = pyperclip.paste().strip()
                except:
                    break
                if text:
                    break

            if not text:
                # Copy failed (nothing highlighted or OS blocked it)
                try:
                    if original_clip:
                        pyperclip.copy(original_clip)
                except:
                    pass
                return

            # Restore original clipboard
            try:
                pyperclip.copy(original_clip)
            except:
                pass

            # Translate
            self.translate_and_show(text)
        threading.Thread(target=_task).start()

    def translate_and_show(self, text):
        """Translate text and show the tooltip. Can be called directly for OCR results."""
        try:
            data = self.get_translation_data(text)
            if data:
                self.show_translation_tooltip(
                    data["zh"], data["pinyin"], data["vietnamese"], data["breakdown"]
                )
        except Exception as e:
            print(f"Translation failed: {e}")

    def get_translation_data(self, text):
        """Get translation data without showing UI. Returns dict or None."""
        try:
            text = self.normalize_text(text)

            pinyin_res = pypinyin.pinyin(text, style=pypinyin.Style.TONE)
            pinyin_text = " ".join([item[0] for item in pinyin_res])
            vietnamese = GoogleTranslator(source='auto', target='vi').translate(text)

            # Word Component Breakdown
            words = list(jieba.cut(text))
            # Only keep words with chinese characters
            words = [w for w in words if w.strip() and any('\u4e00' <= char <= '\u9fff' for char in w)]

            breakdown = ""
            if len(words) > 1:  # if it's already a single word, no need to break down
                sep = " | "
                joined_words = sep.join(words)
                try:
                    translated_words = GoogleTranslator(source='auto', target='vi').translate(joined_words).split(sep.strip())
                    breakdown = "\nComponent Breakdown:\n"
                    for i, w in enumerate(words):
                        py = " ".join([item[0] for item in pypinyin.pinyin(w, style=pypinyin.Style.TONE)])
                        mean = translated_words[i].strip() if i < len(translated_words) else "?"
                        mean = mean.strip("| ")
                        breakdown += f"• {w} ({py}) : {mean}\n"
                except:
                    pass  # if segment translation blocks/fails, ignore the breakdown

            return {
                "zh": text,
                "pinyin": pinyin_text,
                "vietnamese": vietnamese,
                "breakdown": breakdown
            }
        except Exception as e:
            print(f"Translation failed: {e}")
            return None

    def show_translation_tooltip(self, zh, pi, vi, breakdown="", x=None, y=None):
        """Show a floating tooltip window with translation results."""
        def _show():
            if x is None or y is None:
                from pynput.mouse import Controller as MouseController
                mouse = MouseController()
                mx, my = mouse.position
            else:
                mx, my = x, y

            w = tk.Tk()
            w.overrideredirect(True)
            w.attributes('-topmost', True)
            w.geometry(f"+{int(mx)+15}+{int(my)+15}")
            w.config(bg="#999999")

            inner = tk.Frame(w, bg="#ffffff", padx=15, pady=12)
            inner.pack(fill="both", expand=True, padx=1, pady=1)

            header = tk.Frame(inner, bg="#ffffff")
            header.pack(fill="x", pady=(0, 8))
            tk.Label(header, text="Translation", font=("Segoe UI", 10, "bold"), bg="#ffffff", fg="#666666").pack(side="left")
            close_btn = tk.Button(
                header,
                text="X",
                font=("Segoe UI", 9, "bold"),
                bg="#e6e6e6",
                fg="#333333",
                activebackground="#d6d6d6",
                activeforeground="#111111",
                bd=0,
                padx=8,
                pady=2,
                cursor="hand2",
                command=lambda: w.destroy(),
            )
            close_btn.pack(side="right")

            # Using Text widget to allow selection
            text_box = tk.Text(inner, wrap="word", bg="#ffffff", fg="#222", bd=0, highlightthickness=0, width=45, font=("Microsoft YaHei", 12))
            text_box.pack(fill="both", expand=True)

            text_box.tag_configure("zh", font=("Microsoft YaHei", 15, "bold"), foreground="#222")
            text_box.tag_configure("pi", font=("Segoe UI", 13, "bold"), foreground="#0066cc")
            text_box.tag_configure("vi", font=("Segoe UI", 13), foreground="#444")
            text_box.tag_configure("br", font=("Segoe UI", 11), foreground="#666")

            text_box.insert("end", zh + "\n", "zh")
            text_box.insert("end", pi + "\n", "pi")
            text_box.insert("end", vi + "\n", "vi")

            if breakdown:
                text_box.insert("end", breakdown, "br")

            # Make read-only while allowing Ctrl+C
            text_box.bind("<Key>", lambda e: "break" if e.keysym.lower() != "c" or not (e.state & 0x0004) else None)

            line_count = 4 + (breakdown.count("\n") if breakdown else 0)
            text_box.config(height=min(18, line_count))

            btn_row = tk.Frame(inner, bg="#ffffff")
            btn_row.pack(fill="x", pady=(10, 0))

            if self.tts:
                speak_btn = tk.Button(
                    btn_row,
                    text="Speak",
                    font=("Segoe UI", 10),
                    bg="#2d6fff",
                    fg="#ffffff",
                    activebackground="#4488ff",
                    activeforeground="#ffffff",
                    bd=0,
                    padx=16,
                    pady=6,
                    cursor="hand2",
                    command=lambda: self.tts.speak_async(zh),
                )
                speak_btn.pack(side="left", padx=(0, 8))

                stop_btn = tk.Button(
                    btn_row,
                    text="Stop",
                    font=("Segoe UI", 10),
                    bg="#999999",
                    fg="#ffffff",
                    activebackground="#777777",
                    activeforeground="#ffffff",
                    bd=0,
                    padx=16,
                    pady=6,
                    cursor="hand2",
                    command=self.tts.stop,
                )
                stop_btn.pack(side="left")

            def close_win(e=None):
                w.destroy()

            w.bind("<Escape>", close_win)

            self._bind_drag_tree(w, header, ignored={close_btn})
            self._place_window_on_screen(w, int(mx) + 15, int(my) + 15)
            w.after(100, w.focus_force)
            w.mainloop()

        threading.Thread(target=_show).start()

    def start(self):
        """Start the dictionary hotkey listener."""
        self.restart_hotkey_listener()

    def stop(self):
        """Stop the dictionary hotkey listener."""
        if self.hotkey_listener:
            try:
                self.hotkey_listener.stop()
            except:
                pass
