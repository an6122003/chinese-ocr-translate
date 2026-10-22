"""
Pinyin Input Module
Handles keyboard listening and tone mark replacement for system-wide pinyin input.
"""

import threading
import time
from pynput import keyboard
from pynput.keyboard import Key, Controller
import pinyin_logic


class PinyinInputHandler:
    def __init__(self):
        self.enabled = True
        self.char_buffer = ""
        self.max_buffer_size = 12
        self.controller = Controller()
        self.listener = None
        self.replacing = False  # Prevent recursive replacement

    def is_vowel(self, char):
        return char.lower() in "aeiouüvāáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ"

    def get_pinyin_syllable(self, buffer):
        if not buffer:
            return ""
        letters = ""
        for char in reversed(buffer):
            if char.isalpha():
                letters = char + letters
            else:
                break

        # Find the longest valid pinyin syllable matching the end of the input
        from pinyin_logic import VALID_SYLLABLES, remove_tone_marks
        for i in range(len(letters)):
            suffix = letters[i:]
            clean_suffix = remove_tone_marks(suffix).lower().replace('ü', 'v')
            if clean_suffix in VALID_SYLLABLES:
                return suffix

        return ""

    def perform_replace(self, syllable, accented):
        self.replacing = True
        try:
            # Note: The '1/2/3/4' is already being typed by the OS.
            # We need len(syllable) + 1 backspaces.

            # Use small delays for better compatibility across apps
            time.sleep(0.01)

            # Backspace the syllable + the number key
            for _ in range(len(syllable) + 1):
                self.controller.press(Key.backspace)
                self.controller.release(Key.backspace)
                time.sleep(0.005)  # Tiny delay for OS event buffer

            # Type the accented version
            self.controller.type(accented)

            # Clear buffer and add accented result (optional, helps for concatenated pinyin)
            self.char_buffer = self.char_buffer[:-len(syllable)] + accented
        finally:
            self.replacing = False

    def on_press(self, key):
        if not self.enabled or self.replacing:
            return

        try:
            if hasattr(key, 'char') and key.char:
                char = key.char
                if char in "1234" and self.char_buffer:
                    syllable = self.get_pinyin_syllable(self.char_buffer)
                    if syllable:
                        tone = int(char)
                        accented = pinyin_logic.get_accented_pinyin(syllable, tone)

                        if accented != syllable + char:
                            # Start replacement in background thread
                            threading.Thread(target=self.perform_replace, args=(syllable, accented)).start()
                            return

                # Limit buffer size
                self.char_buffer += char
                if len(self.char_buffer) > self.max_buffer_size:
                    self.char_buffer = self.char_buffer[-self.max_buffer_size:]

            elif key in (Key.space, Key.enter, Key.tab, Key.left, Key.right, Key.up, Key.down, Key.home, Key.end, Key.page_up, Key.page_down, Key.delete):
                self.char_buffer = ""
            elif key == Key.backspace:
                if self.char_buffer:
                    self.char_buffer = self.char_buffer[:-1]
        except AttributeError:
            # Handles keys that don't have .char explicitly if they slip through
            pass

    def toggle(self):
        """Toggle pinyin input on/off."""
        self.enabled = not self.enabled
        self.char_buffer = ""
        return self.enabled

    def start(self):
        """Start the keyboard listener."""
        self.listener = keyboard.Listener(on_press=self.on_press)
        self.listener.start()

    def stop(self):
        """Stop the keyboard listener."""
        if self.listener:
            self.listener.stop()
