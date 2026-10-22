"""
OCR Capture Module
Provides a fullscreen overlay for selecting screen regions and performing OCR
on Chinese characters. Inspired by Android's "Circle to Search" feature.

Uses Windows native OCR (winocr) for fast, lightweight recognition.
Falls back to a message if winocr is not available.
"""

import ctypes
import re
import threading
import tkinter as tk

import pyperclip

try:
    import mss
    import mss.tools
    HAS_MSS = True
except ImportError:
    HAS_MSS = False

try:
    import winocr
    HAS_WINOCR = True
except ImportError:
    HAS_WINOCR = False

from PIL import Image, ImageEnhance, ImageTk


class OCRCapture:
    def __init__(self, dictionary_handler=None, tts_service=None, auto_translate=False):
        self._enable_dpi_awareness()
        self.dictionary = dictionary_handler
        self.tts = tts_service
        self.auto_translate = auto_translate
        self.overlay = None
        self.canvas = None
        self.start_x = 0
        self.start_y = 0
        self.rect_id = None
        self.glow_ids = []
        self._animation_running = False
        self._pulse_phase = 0
        self._anim_task = None
        self._monitor_left = 0
        self._monitor_top = 0
        self._monitor_width = 0
        self._monitor_height = 0
        self.bg_image = None
        self._bg_photo = None
        self._cjk_spacing_pattern = re.compile(
            r"(?<=[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3000-\u303f\uff00-\uffef])\s+"
            r"(?=[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3000-\u303f\uff00-\uffef])"
        )

        # Spawn a dedicated, persistent UI thread for all Tk interactions.
        self.root = None
        self._root_ready = threading.Event()
        threading.Thread(target=self._run_tk_root, daemon=True).start()
        self._root_ready.wait()

    def set_auto_translate(self, enabled):
        self.auto_translate = bool(enabled)

    def _normalize_ocr_text(self, text):
        """Remove artificial OCR spacing inside Chinese text while keeping normal word spaces."""
        if not text:
            return ""

        text = text.replace("\u00a0", " ")
        text = self._cjk_spacing_pattern.sub("", text)
        return text.strip()

    def _enable_dpi_awareness(self):
        """Keep Tk and screen capture coordinates aligned on scaled displays."""
        try:
            user32 = ctypes.windll.user32
            per_monitor_v2 = ctypes.c_void_p(-4)
            if user32.SetProcessDpiAwarenessContext(per_monitor_v2):
                return
        except Exception:
            pass

        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
            return
        except Exception:
            pass

        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except Exception:
            pass

    def _run_tk_root(self):
        self.root = tk.Tk()
        self.root.withdraw()
        self._root_ready.set()
        self.root.mainloop()

    def capture_region(self):
        """Launch the overlay for region selection on the monitor under the cursor."""
        if not HAS_MSS:
            self._show_error("mss library not installed.\nRun: pip install mss")
            return
        if not HAS_WINOCR:
            self._show_error("winocr library not installed.\nRun: pip install winocr")
            return

        self.root.after(0, self._launch)

    def _launch(self):
        if self.overlay:
            return

        class POINT(ctypes.Structure):
            _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

        pt = POINT()
        ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))

        with mss.mss() as sct:
            target_mon = sct.monitors[1]
            for mon in sct.monitors[1:]:
                if (
                    mon["left"] <= pt.x < mon["left"] + mon["width"]
                    and mon["top"] <= pt.y < mon["top"] + mon["height"]
                ):
                    target_mon = mon
                    break

            screenshot = sct.grab(target_mon)
            self.bg_image = Image.frombytes("RGB", screenshot.size, screenshot.rgb)
            self._monitor_left = target_mon["left"]
            self._monitor_top = target_mon["top"]
            self._monitor_width = target_mon["width"]
            self._monitor_height = target_mon["height"]

        self.overlay = tk.Toplevel(self.root)
        self.overlay.withdraw()
        self.overlay.overrideredirect(True)
        self.overlay.attributes("-topmost", True)
        self.overlay.config(bg="#000000", cursor="crosshair")
        self.overlay.geometry(
            f"{self._monitor_width}x{self._monitor_height}+{self._monitor_left}+{self._monitor_top}"
        )
        self.overlay.update_idletasks()

        self.canvas = tk.Canvas(
            self.overlay,
            width=self._monitor_width,
            height=self._monitor_height,
            highlightthickness=0,
            bg="#000000",
            cursor="crosshair",
        )
        self.canvas.pack(fill="both", expand=True)

        darkened = ImageEnhance.Brightness(self.bg_image).enhance(0.35)
        self._bg_photo = ImageTk.PhotoImage(darkened)
        self.canvas.create_image(0, 0, anchor="nw", image=self._bg_photo)

        self.canvas.create_text(
            self._monitor_width // 2,
            80,
            text="Drag to select text region  |  Right-click or ESC to cancel",
            fill="#ffffff",
            font=("Segoe UI", 16, "bold"),
            anchor="center",
        )
        self.canvas.create_text(
            self._monitor_width // 2,
            120,
            text="Release to OCR the selected area",
            fill="#aaaaaa",
            font=("Segoe UI", 11),
            anchor="center",
        )

        self.canvas.bind("<ButtonPress-1>", self._on_press)
        self.canvas.bind("<B1-Motion>", self._on_drag)
        self.canvas.bind("<ButtonRelease-1>", self._on_release)
        self.overlay.bind("<Escape>", self._cancel)
        self.canvas.bind("<Escape>", self._cancel)
        self.canvas.bind("<ButtonPress-3>", self._cancel)

        self.overlay.deiconify()
        self._force_focus(self.overlay)

    def _force_focus(self, window):
        window.focus_force()
        window.lift()

    def _on_press(self, event):
        self.start_x = event.x
        self.start_y = event.y
        self._clear_glow()

        for i, alpha_hex in enumerate(["#1a5cff", "#2d6fff", "#4488ff"]):
            glow_width = 6 - i * 2
            gid = self.canvas.create_rectangle(
                self.start_x,
                self.start_y,
                self.start_x,
                self.start_y,
                outline=alpha_hex,
                width=glow_width,
                dash=(),
            )
            self.glow_ids.append(gid)

        self.rect_id = self.canvas.create_rectangle(
            self.start_x,
            self.start_y,
            self.start_x,
            self.start_y,
            outline="#00aaff",
            width=2,
            dash=(6, 4),
        )

        self._animation_running = True
        self._pulse_phase = 0
        self._animate_border()

    def _on_drag(self, event):
        if self.rect_id:
            self.canvas.coords(self.rect_id, self.start_x, self.start_y, event.x, event.y)
        for gid in self.glow_ids:
            self.canvas.coords(gid, self.start_x, self.start_y, event.x, event.y)

    def _animate_border(self):
        if not self._animation_running or not self.overlay or not self.rect_id:
            return

        self._pulse_phase = (self._pulse_phase + 1) % 20
        intensity = abs(10 - self._pulse_phase) / 10.0
        r = int(100 * intensity)
        g = int(170 + 85 * intensity)
        b = 255
        color = f"#{r:02x}{g:02x}{b:02x}"

        try:
            self.canvas.itemconfig(self.rect_id, outline=color)
            self._anim_task = self.overlay.after(50, self._animate_border)
        except Exception:
            pass

    def _clear_glow(self):
        for gid in self.glow_ids:
            try:
                self.canvas.delete(gid)
            except Exception:
                pass
        self.glow_ids = []

    def _on_release(self, event):
        end_x, end_y = event.x, event.y

        x1, y1 = min(self.start_x, end_x), min(self.start_y, end_y)
        x2, y2 = max(self.start_x, end_x), max(self.start_y, end_y)

        if (x2 - x1) < 10 or (y2 - y1) < 10:
            self._cancel()
            return

        region = self.bg_image.crop((x1, y1, x2, y2))
        popup_x = self._monitor_left + ((x1 + x2) // 2)
        popup_y = self._monitor_top + y2 + 10

        self._cancel()
        threading.Thread(target=self._do_ocr, args=(region, popup_x, popup_y), daemon=True).start()

    def _do_ocr(self, image, popup_x, popup_y):
        try:
            text = ""
            for lang in ["zh-Hans", "zh-Hant", "en"]:
                if text:
                    break
                try:
                    op = winocr.recognize_pil(image, lang=lang)
                    op.wait(10)
                    result = op.get_results()
                    text = result.text.strip() if result and result.text else ""
                except Exception:
                    pass

            if text:
                noise_chars = ["<", ">"]
                for char in noise_chars:
                    text = text.replace(char, "")
                text = self._normalize_ocr_text(text)

            if not text:
                self.root.after(0, lambda: self._show_no_text_popup(popup_x, popup_y))
                return

            self.root.after(0, lambda: self._show_result_popup(text, popup_x, popup_y))
        except Exception as e:
            print(f"OCR failed: {e}")

    def _show_result_popup(self, text, x, y):
        w = tk.Toplevel(self.root)
        w.overrideredirect(True)
        w.attributes("-topmost", True)
        w.config(bg="#1a1a2e")
        w.geometry(f"+{int(x)}+{int(y)}")

        outer = tk.Frame(w, bg="#1a1a2e", padx=2, pady=2)
        outer.pack(fill="both", expand=True)

        inner = tk.Frame(outer, bg="#16213e", padx=16, pady=14)
        inner.pack(fill="both", expand=True)

        header_frame = tk.Frame(inner, bg="#16213e")
        header_frame.pack(fill="x", pady=(0, 8))

        tk.Label(
            header_frame,
            text="OCR",
            font=("Segoe UI Emoji", 14),
            bg="#16213e",
            fg="#ffffff",
        ).pack(side="left", padx=(0, 8))
        tk.Label(
            header_frame,
            text="OCR Result",
            font=("Segoe UI", 11, "bold"),
            bg="#16213e",
            fg="#8899aa",
        ).pack(side="left")
        close_btn = tk.Button(
            header_frame,
            text="X",
            font=("Segoe UI", 10, "bold"),
            bg="#2b3554",
            fg="#ffffff",
            activebackground="#445070",
            activeforeground="#ffffff",
            bd=0,
            padx=8,
            pady=2,
            cursor="hand2",
            command=lambda: self._safe_destroy(w),
        )
        close_btn.pack(side="right")

        text_frame = tk.Frame(inner, bg="#0f3460", padx=12, pady=10)
        text_frame.pack(fill="x", pady=(0, 10))

        text_label = tk.Text(
            text_frame,
            wrap="word",
            bg="#0f3460",
            fg="#e0e0e0",
            bd=0,
            highlightthickness=0,
            width=45,
            height=min(6, max(1, text.count("\n") + 1)),
            font=("Microsoft YaHei", 14),
            selectbackground="#2d6fff",
            selectforeground="#ffffff",
        )
        text_label.insert("1.0", text)
        text_label.bind(
            "<Key>",
            lambda e: "break" if e.keysym.lower() not in ("c",) or not (e.state & 0x0004) else None,
        )
        text_label.pack(fill="both", expand=True)

        translate_frame = tk.Frame(inner, bg="#16213e")
        translate_content = tk.Text(
            translate_frame,
            wrap="word",
            bg="#16213e",
            fg="#e0e0e0",
            bd=0,
            highlightthickness=0,
            width=45,
            height=1,
            font=("Microsoft YaHei", 12),
            selectbackground="#2d6fff",
            selectforeground="#ffffff",
        )

        translate_content.tag_configure("pi", font=("Segoe UI", 13, "bold"), foreground="#66ccff")
        translate_content.tag_configure("vi", font=("Segoe UI", 13), foreground="#88ddaa")
        translate_content.tag_configure("br", font=("Segoe UI", 11), foreground="#8899aa")
        translate_content.tag_configure("loading", font=("Segoe UI", 11, "italic"), foreground="#666688")
        translate_content.pack(fill="both", expand=True, pady=(8, 0))

        btn_frame = tk.Frame(inner, bg="#16213e")
        btn_frame.pack(fill="x", pady=(10, 0))

        def copy_text():
            pyperclip.copy(text)
            copy_btn.config(bg="#27ae60", text="Copied")
            w.after(800, lambda: self._safe_destroy(w))

        def translate_text():
            if not self.dictionary:
                return

            translate_btn.config(state="disabled", text="Translating...", bg="#555555")
            copy_btn.config(state="disabled")

            translate_frame.pack(fill="x", pady=(6, 0), before=btn_frame)
            translate_content.config(state="normal")
            translate_content.delete("1.0", "end")
            translate_content.insert("end", "Translating...", "loading")
            translate_content.config(state="disabled")

            def _do_translate():
                try:
                    data = self.dictionary.get_translation_data(text)

                    def _update_ui():
                        translate_content.config(state="normal")
                        translate_content.delete("1.0", "end")
                        if data:
                            translate_content.insert("end", data["pinyin"] + "\n", "pi")
                            translate_content.insert("end", data["vietnamese"] + "\n", "vi")
                            if data["breakdown"]:
                                translate_content.insert("end", data["breakdown"], "br")
                            line_count = 2 + (data["breakdown"].count("\n") if data["breakdown"] else 0)
                            translate_content.config(height=min(12, max(2, line_count)))
                        else:
                            translate_content.insert("end", "Translation failed", "loading")
                            translate_content.config(height=1)
                        translate_content.config(state="disabled")
                        copy_btn.config(state="normal")
                        translate_btn.pack_forget()

                    self.root.after(0, _update_ui)
                except Exception:
                    self.root.after(0, lambda: copy_btn.config(state="normal"))

            threading.Thread(target=_do_translate, daemon=True).start()

        def speak_text():
            if not self.tts:
                return

            speak_btn.config(state="disabled", text="Speaking...")

            def _ready():
                self.root.after(0, lambda: speak_btn.config(state="normal", text="Speak"))

            def _error(message):
                print(f"TTS failed: {message}")
                self.root.after(0, lambda: speak_btn.config(state="normal", text="Speak"))

            self.tts.speak_async(text, on_ready=_ready, on_error=_error)

        copy_btn = tk.Button(
            btn_frame,
            text="Copy Text",
            font=("Segoe UI", 11),
            bg="#2d6fff",
            fg="#ffffff",
            activebackground="#4488ff",
            activeforeground="#ffffff",
            bd=0,
            padx=20,
            pady=8,
            cursor="hand2",
            command=copy_text,
        )
        copy_btn.pack(side="left", fill="x", expand=True, padx=(0, 4))

        if self.tts:
            speak_btn = tk.Button(
                btn_frame,
                text="Speak",
                font=("Segoe UI", 11),
                bg="#6c5ce7",
                fg="#ffffff",
                activebackground="#7d6cf0",
                activeforeground="#ffffff",
                bd=0,
                padx=20,
                pady=8,
                cursor="hand2",
                command=speak_text,
            )
            speak_btn.pack(side="left", fill="x", expand=True, padx=(0, 4))

            stop_btn = tk.Button(
                btn_frame,
                text="Stop",
                font=("Segoe UI", 11),
                bg="#636e72",
                fg="#ffffff",
                activebackground="#7f8c8d",
                activeforeground="#ffffff",
                bd=0,
                padx=20,
                pady=8,
                cursor="hand2",
                command=self.tts.stop,
            )
            stop_btn.pack(side="left", fill="x", expand=True, padx=(0, 4))

        translate_btn = tk.Button(
            btn_frame,
            text="Translate",
            font=("Segoe UI", 11),
            bg="#e94560",
            fg="#ffffff",
            activebackground="#ff6b81",
            activeforeground="#ffffff",
            bd=0,
            padx=20,
            pady=8,
            cursor="hand2",
            command=translate_text,
        )
        translate_btn.pack(side="right", fill="x", expand=True, padx=(4, 0))

        if self.auto_translate and self.dictionary:
            w.after(50, translate_text)

        w.bind("<Escape>", lambda e: self._safe_destroy(w))
        w.bind("<ButtonPress-3>", lambda e: self._safe_destroy(w))
        self._bind_drag_tree(w, header_frame, ignored={close_btn})
        self._place_window_on_screen(w, x, y)
        self._force_focus(w)

    def _show_no_text_popup(self, x, y):
        w = tk.Toplevel(self.root)
        w.overrideredirect(True)
        w.attributes("-topmost", True)
        w.geometry(f"+{int(x)}+{int(y)}")
        w.config(bg="#1a1a2e")

        inner = tk.Frame(w, bg="#16213e", padx=16, pady=12)
        inner.pack(fill="both", expand=True, padx=2, pady=2)
        header = tk.Frame(inner, bg="#16213e")
        header.pack(fill="x")
        tk.Label(header, text="No text detected", font=("Segoe UI", 12), bg="#16213e", fg="#aaaaaa").pack(side="left")
        close_btn = tk.Button(
            header,
            text="X",
            font=("Segoe UI", 9, "bold"),
            bg="#2b3554",
            fg="#ffffff",
            activebackground="#445070",
            activeforeground="#ffffff",
            bd=0,
            padx=8,
            pady=2,
            cursor="hand2",
            command=lambda: self._safe_destroy(w),
        )
        close_btn.pack(side="right")
        tk.Label(inner, text="Try selecting a larger area", font=("Segoe UI", 9), bg="#16213e", fg="#666688").pack(pady=(4, 0))

        w.bind("<Escape>", lambda e: self._safe_destroy(w))
        w.after(2500, lambda: self._safe_destroy(w))

        self._bind_drag_tree(w, header, ignored={close_btn})
        self._place_window_on_screen(w, x, y)
        self._force_focus(w)

    def _show_error(self, message):
        def _show():
            from tkinter import messagebox

            messagebox.showerror("OCR Error", message)

        self.root.after(0, _show)

    def _safe_destroy(self, widget):
        try:
            widget.destroy()
        except Exception:
            pass

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

    def _cancel(self, event=None):
        self._animation_running = False

        if self._anim_task:
            try:
                self.root.after_cancel(self._anim_task)
            except Exception:
                pass
            self._anim_task = None

        if self.overlay:
            self._safe_destroy(self.overlay)

        self.overlay = None
        self.canvas = None
        self.rect_id = None
        self.glow_ids = []
        self._bg_photo = None
