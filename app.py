"""
Pinyin Input App - Main
System tray application that orchestrates:
  1. Pinyin Input — system-wide pinyin tone input
  2. Dictionary — highlight text & translate with hotkey
  3. OCR Capture — screen region OCR for non-selectable Chinese text
"""

import os
import sys
import threading
import tempfile
import tkinter as tk
from tkinter import messagebox
from pynput import keyboard
import pystray
from PIL import Image, ImageDraw
import json

from pinyin_input import PinyinInputHandler
from dictionary import DictionaryHandler
from ocr_capture import OCRCapture
from tts_service import TTSService


class PinyinApp:
    def __init__(self):
        self.tray = None

        self.config_path = os.path.expanduser("~/.pinyin_dict_config.json")
        self.translation_shortcut = "<alt>+x"
        self.ocr_shortcut = "<alt>+s"
        self.ocr_auto_translate = False

        self.load_config()

        # Initialize modules
        self.pinyin = PinyinInputHandler()
        self.tts = TTSService()
        self.dictionary = DictionaryHandler(tts_service=self.tts)
        self.dictionary.set_shortcut(self.translation_shortcut)

        self.ocr = OCRCapture(
            dictionary_handler=self.dictionary,
            tts_service=self.tts,
            auto_translate=self.ocr_auto_translate,
        )

        # OCR hotkey listener
        self.ocr_hotkey_listener = None

    def load_config(self):
        try:
            if os.path.exists(self.config_path):
                with open(self.config_path, "r", encoding="utf-8") as f:
                    config = json.load(f)
                    self.translation_shortcut = config.get("translation_shortcut", "<alt>+x")
                    self.ocr_shortcut = config.get("ocr_shortcut", "<alt>+s")
                    self.ocr_auto_translate = config.get("ocr_auto_translate", False)
        except:
            pass

    def save_config(self):
        try:
            config = {
                "translation_shortcut": self.translation_shortcut,
                "ocr_shortcut": self.ocr_shortcut,
                "ocr_auto_translate": bool(self.ocr_auto_translate),
            }
            config_dir = os.path.dirname(self.config_path) or "."
            fd, temp_path = tempfile.mkstemp(prefix="pinyin-config-", suffix=".json", dir=config_dir)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(config, f)
                os.replace(temp_path, self.config_path)
            except Exception:
                try:
                    os.close(fd)
                except Exception:
                    pass
                if os.path.exists(temp_path):
                    os.remove(temp_path)
                raise
        except Exception as e:
            print(f"Failed to save config: {e}")

    def get_resource_path(self, relative_path):
        """ Get absolute path to resource, works for dev and for PyInstaller """
        try:
            # PyInstaller creates a temp folder and stores path in _MEIPASS
            base_path = sys._MEIPASS
        except Exception:
            base_path = os.path.abspath(".")

        return os.path.join(base_path, relative_path)

    def create_icon_image(self, active=True):
        icon_path = self.get_resource_path("icon.png")
        if os.path.exists(icon_path):
            image = Image.open(icon_path).convert("RGBA")
            if hasattr(Image, "Resampling"):
                image = image.resize((64, 64), Image.Resampling.LANCZOS)
            else:
                image = image.resize((64, 64), Image.ANTIALIAS)

            if not active:
                image = image.convert('L').convert('RGBA')
            return image

        width = 64
        height = 64
        image = Image.new('RGBA', (width, height), (0, 0, 0, 0))
        dc = ImageDraw.Draw(image)

        # Color based on state: Blue gradient for active, Gray for disabled
        main_color = (66, 135, 245) if active else (120, 120, 120)
        border_color = (33, 90, 180) if active else (80, 80, 80)

        dc.ellipse([5, 5, 59, 59], fill=main_color, outline=border_color, width=2)
        # Add a subtle highlight
        dc.ellipse([15, 12, 49, 32], fill=(255, 255, 255, 60))

        # Use simple text as logo
        dc.text((22, 18), "P", fill="white", font=None)  # Default font is usually very small
        return image

    def toggle_pinyin(self, icon, item):
        is_enabled = self.pinyin.toggle()
        self.tray.icon = self.create_icon_image(is_enabled)

    def show_info(self, icon, item):
        # Open a simple reference window
        def create_win():
            root = tk.Tk()
            root.title("Pinyin Input - Quick Start")
            root.geometry("360x300")
            root.attributes("-topmost", True)

            tk.Label(root, text="Pinyin Input Helper", font=("Arial", 14, "bold"), pady=10).pack()

            # Pinyin section
            tk.Label(root, text="Type Pinyin then 1-4 for tones:", font=("Arial", 10)).pack()

            ref = [("ma1", "mā"), ("ma2", "má"), ("ma3", "mǎ"), ("ma4", "mà"), ("lv3", "lǚ")]
            for cmd, res in ref:
                tk.Label(root, text=f"{cmd}  ➜  {res}", font=("Consolas", 11)).pack(anchor="w", padx=90)

            # Divider
            tk.Frame(root, height=1, bg="#cccccc").pack(fill="x", padx=20, pady=8)

            # Dictionary shortcut
            display_shortcut = self.translation_shortcut.replace('<', '').replace('>', '').replace('+', ' + ').title()
            tk.Label(root, text=f"📖 Highlight text & press  {display_shortcut}\nto translate to Vietnamese", font=("Arial", 9, "italic"), fg="#0055ff", pady=3).pack()

            # OCR shortcut
            display_ocr = self.ocr_shortcut.replace('<', '').replace('>', '').replace('+', ' + ').title()
            tk.Label(root, text=f"🔍 Press  {display_ocr}  to OCR\nscreen text (Circle to Search)", font=("Arial", 9, "italic"), fg="#cc5500", pady=3).pack()

            tk.Button(root, text="Got it!", command=root.destroy, width=15).pack(pady=5)
            root.mainloop()

        threading.Thread(target=create_win).start()

    def open_settings(self, icon, item):
        def _show_settings():
            root = tk.Tk()
            root.title("Settings")
            root.geometry("360x340")
            root.attributes("-topmost", True)

            tk.Label(root, text="Shortcuts", font=("Arial", 12, "bold"), pady=10).pack()

            # --- Translation Shortcut ---
            tk.Label(root, text="📖 Translation Shortcut", font=("Arial", 10), anchor="w").pack(fill="x", padx=20)

            frame1 = tk.Frame(root)
            frame1.pack(pady=5)

            parts = self.translation_shortcut.split("+")
            mod_val = parts[0].strip("<>") if len(parts) > 1 else "alt"
            key_val = parts[1] if len(parts) > 1 else "d"

            mod_var1 = tk.StringVar(value=mod_val.capitalize())
            tk.OptionMenu(frame1, mod_var1, "Alt", "Ctrl", "Shift").pack(side="left", padx=5)

            tk.Label(frame1, text="+", font=("Arial", 12)).pack(side="left")

            key_var1 = tk.StringVar(value=key_val.upper())
            entry1 = tk.Entry(frame1, textvariable=key_var1, width=5, font=("Arial", 12), justify="center")
            entry1.pack(side="left", padx=5)

            # --- OCR Shortcut ---
            tk.Label(root, text="🔍 OCR Capture Shortcut", font=("Arial", 10), anchor="w").pack(fill="x", padx=20, pady=(10, 0))

            frame2 = tk.Frame(root)
            frame2.pack(pady=5)

            parts2 = self.ocr_shortcut.split("+")
            mod_val2 = parts2[0].strip("<>") if len(parts2) > 1 else "alt"
            key_val2 = parts2[1] if len(parts2) > 1 else "s"

            mod_var2 = tk.StringVar(value=mod_val2.capitalize())
            tk.OptionMenu(frame2, mod_var2, "Alt", "Ctrl", "Shift").pack(side="left", padx=5)

            tk.Label(frame2, text="+", font=("Arial", 12)).pack(side="left")

            key_var2 = tk.StringVar(value=key_val2.upper())
            entry2 = tk.Entry(frame2, textvariable=key_var2, width=5, font=("Arial", 12), justify="center")
            entry2.pack(side="left", padx=5)

            auto_translate_var = tk.BooleanVar(master=root, value=bool(self.ocr_auto_translate))
            tk.Label(root, text="OCR Result Behavior", font=("Arial", 10), anchor="w").pack(fill="x", padx=20, pady=(14, 0))
            auto_translate_cb = tk.Checkbutton(
                root,
                text="Auto-translate OCR results after capture",
                variable=auto_translate_var,
                anchor="w",
                justify="left",
            )
            auto_translate_cb.pack(fill="x", padx=20, pady=(4, 0))

            def save():
                m1 = mod_var1.get().lower()
                k1 = key_var1.get().lower()
                m2 = mod_var2.get().lower()
                k2 = key_var2.get().lower()

                if len(k1) == 1 and k1.isalnum() and len(k2) == 1 and k2.isalnum():
                    root.update_idletasks()
                    self.translation_shortcut = f"<{m1}>+{k1}"
                    self.ocr_shortcut = f"<{m2}>+{k2}"
                    self.ocr_auto_translate = bool(auto_translate_var.get())
                    self.save_config()

                    # Restart listeners with new shortcuts
                    self.dictionary.set_shortcut(self.translation_shortcut)
                    self.restart_ocr_hotkey()
                    self.ocr.set_auto_translate(self.ocr_auto_translate)

                    print(f"Saved OCR auto-translate: {self.ocr_auto_translate}")
                    root.destroy()

                    # Show confirmation
                    msg = tk.Tk()
                    msg.withdraw()
                    messagebox.showinfo(
                        "Saved",
                        f"Translation: {mod_var1.get()} + {k1.upper()}\n"
                        f"OCR: {mod_var2.get()} + {k2.upper()}\n"
                        f"Auto-translate OCR: {'On' if self.ocr_auto_translate else 'Off'}",
                        parent=msg
                    )
                    msg.destroy()
                else:
                    messagebox.showerror("Error", "Keys must be single letters or numbers.", parent=root)

            tk.Button(root, text="Save", command=save, width=15, bg="#0066cc", fg="white").pack(pady=15)
            root.mainloop()

        threading.Thread(target=_show_settings).start()

    def restart_ocr_hotkey(self):
        """Restart the OCR hotkey listener."""
        if self.ocr_hotkey_listener:
            try:
                self.ocr_hotkey_listener.stop()
            except:
                pass
        self.ocr_hotkey_listener = keyboard.GlobalHotKeys({
            self.ocr_shortcut: self.ocr.capture_region
        })
        self.ocr_hotkey_listener.start()

    def on_quit(self, icon, item):
        self.tray.stop()
        self.pinyin.stop()
        self.dictionary.stop()
        if self.ocr_hotkey_listener:
            try:
                self.ocr_hotkey_listener.stop()
            except:
                pass
        os._exit(0)

    def run(self):
        print("Pinyin Input App is running...")

        # Start modules
        self.pinyin.start()
        self.dictionary.start()
        self.restart_ocr_hotkey()

        # Build Tray Menu
        menu = pystray.Menu(
            pystray.MenuItem("Pinyin Input", self.toggle_pinyin, checked=lambda item: self.pinyin.enabled, default=True),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("🔍 OCR Capture", lambda icon, item: self.ocr.capture_region()),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Settings", self.open_settings),
            pystray.MenuItem("Quick Guide", self.show_info),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem("Quit", self.on_quit)
        )

        self.tray = pystray.Icon("PinyinInput", self.create_icon_image(True), "Pinyin Input Helper", menu)

        self.tray.run()

if __name__ == "__main__":
    app = PinyinApp()
    app.run()
