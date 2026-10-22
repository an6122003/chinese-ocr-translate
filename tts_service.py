"""
Offline Chinese TTS service using sherpa-onnx.

The model is downloaded on first use into a local tts_models directory so the
desktop app stays lightweight while still working fully offline afterward.
"""

import os
import queue
import sys
import tempfile
import threading
import winsound

import sherpa_onnx


class TTSService:
    MODEL_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-melo-tts-zh_en.tar.bz2"
    MODEL_DIRNAME = "vits-melo-tts-zh_en"

    def __init__(self):
        self._tts = None
        self._voice = None
        self._backend = None
        self._model_lock = threading.Lock()
        self._play_lock = threading.Lock()
        self._current_wav = None
        self._sapi_queue = queue.Queue()
        self._sapi_ready = threading.Event()
        self._sapi_worker = None
        self._sapi_shutdown = False
        self._sapi_init_error = None

    def speak_async(self, text, on_ready=None, on_error=None):
        def _task():
            try:
                cleaned = (text or "").strip()
                if not cleaned:
                    raise ValueError("No text to speak.")

                backend = self._get_backend()
                if backend == "sherpa":
                    tts = self._tts
                    audio = tts.generate(cleaned, sid=0, speed=1.0)

                    fd, wav_path = tempfile.mkstemp(prefix="pinyin-tts-", suffix=".wav")
                    os.close(fd)
                    sherpa_onnx.write_wave(wav_path, audio.samples, tts.sample_rate)

                    with self._play_lock:
                        self.stop()
                        self._current_wav = wav_path
                        winsound.PlaySound(wav_path, winsound.SND_FILENAME | winsound.SND_ASYNC)
                    if on_ready:
                        on_ready()
                else:
                    self._speak_with_sapi(cleaned, on_ready=on_ready, on_error=on_error)
            except Exception as e:
                if on_error:
                    on_error(str(e))

        threading.Thread(target=_task, daemon=True).start()

    def stop(self):
        backend = self._backend
        if backend == "sapi":
            self._enqueue_sapi_command(("stop", None, None, None))
            return

        self._stop_sherpa_playback()

    def _get_backend(self):
        with self._model_lock:
            if self._backend is not None:
                return self._backend

            try:
                self._ensure_sapi_worker()
                self._backend = "sapi"
                return self._backend
            except Exception as e:
                print(f"Windows TTS unavailable, trying sherpa-onnx: {e}")

            try:
                self._tts = self._create_sherpa_tts()
                self._backend = "sherpa"
                return self._backend
            except Exception as e:
                raise RuntimeError(f"No working Chinese TTS backend available: {e}") from e

    def _stop_sherpa_playback(self):
        with self._play_lock:
            winsound.PlaySound(None, winsound.SND_PURGE)
            if self._current_wav and os.path.exists(self._current_wav):
                try:
                    os.remove(self._current_wav)
                except OSError:
                    pass
            self._current_wav = None

    def _ensure_sapi_worker(self):
        if self._sapi_worker and self._sapi_worker.is_alive():
            return

        self._sapi_ready.clear()
        self._sapi_shutdown = False
        self._sapi_init_error = None
        self._sapi_worker = threading.Thread(target=self._run_sapi_worker, daemon=True)
        self._sapi_worker.start()
        if not self._sapi_ready.wait(timeout=10):
            raise RuntimeError("Timed out initializing Windows TTS.")
        if self._sapi_init_error:
            raise RuntimeError(self._sapi_init_error)

    def _run_sapi_worker(self):
        try:
            import pythoncom
            from win32com.client import Dispatch

            pythoncom.CoInitialize()
            self._voice = Dispatch("SAPI.SpVoice")
            self._select_chinese_voice(self._voice)
            self._sapi_ready.set()

            while not self._sapi_shutdown:
                command, payload, on_ready, on_error = self._sapi_queue.get()
                try:
                    if command == "shutdown":
                        self._sapi_shutdown = True
                        try:
                            self._voice.Speak("", 3)
                        except Exception:
                            pass
                        continue

                    if command == "stop":
                        self._voice.Speak("", 3)
                        continue

                    if command == "speak":
                        self._voice.Speak("", 3)
                        self._voice.Speak(payload, 3)
                        if on_ready:
                            on_ready()
                except Exception as e:
                    if on_error:
                        on_error(str(e))
                finally:
                    self._sapi_queue.task_done()
        except Exception as e:
            self._sapi_init_error = f"Windows TTS initialization failed: {e}"
            self._sapi_ready.set()
        finally:
            try:
                import pythoncom

                pythoncom.CoUninitialize()
            except Exception:
                pass

    def _enqueue_sapi_command(self, item):
        self._ensure_sapi_worker()
        self._sapi_queue.put(item)

    def _speak_with_sapi(self, text, on_ready=None, on_error=None):
        self._enqueue_sapi_command(("speak", text, on_ready, on_error))

    def _create_sherpa_tts(self):
        model_dir = self._ensure_model()
        config = sherpa_onnx.OfflineTtsConfig(
            model=sherpa_onnx.OfflineTtsModelConfig(
                vits=sherpa_onnx.OfflineTtsVitsModelConfig(
                    model=os.path.join(model_dir, "model.onnx"),
                    lexicon=os.path.join(model_dir, "lexicon.txt"),
                    tokens=os.path.join(model_dir, "tokens.txt"),
                    data_dir=model_dir,
                    dict_dir=os.path.join(model_dir, "dict"),
                ),
                num_threads=max(1, min(4, (os.cpu_count() or 2) // 2)),
                provider="cpu",
            ),
            rule_fsts="",
            rule_fars="",
            max_num_sentences=1,
        )
        if not config.validate():
            raise RuntimeError("Invalid sherpa-onnx TTS model configuration.")

        return sherpa_onnx.OfflineTts(config)

    def _ensure_model(self):
        models_root = os.path.join(self._get_app_root(), "tts_models")
        os.makedirs(models_root, exist_ok=True)

        model_dir = os.path.join(models_root, self.MODEL_DIRNAME)
        model_file = os.path.join(model_dir, "model.onnx")
        lexicon_file = os.path.join(model_dir, "lexicon.txt")
        tokens_file = os.path.join(model_dir, "tokens.txt")
        phontab_file = os.path.join(model_dir, "phontab")

        if all(os.path.exists(path) for path in (model_file, lexicon_file, tokens_file, phontab_file)):
            return model_dir

        raise RuntimeError("Bundled sherpa-onnx model is incomplete.")

    def _get_app_root(self):
        if getattr(sys, "frozen", False):
            return os.path.dirname(sys.executable)
        return os.path.dirname(os.path.abspath(__file__))

    def _select_chinese_voice(self, voice):
        voices = voice.GetVoices()
        for i in range(voices.Count):
            token = voices.Item(i)
            text = " ".join(
                part for part in [getattr(token, "Id", ""), token.GetDescription()]
            ).lower()
            if any(marker in text for marker in ("zh", "chinese", "mandarin", "huihui", "xiaoxiao", "yaoyao")):
                voice.Voice = token
                return
        raise RuntimeError("No Chinese Windows voice is installed.")
