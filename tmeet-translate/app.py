"""T-Meet caption translator.

Small HTTP service that translates live caption lines between English, Hindi and
Nepali with the open source IndicTrans2 distilled models (MIT license), on CPU.

POST /translate  {"text": "...", "source": "ne-NP", "target": "en-US"}
             ->  {"text": "...", "cached": false, "ms": 312}
GET  /health
"""
import logging
import os
import threading
import time
from collections import OrderedDict

import torch
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

try:
    from IndicTransToolkit.processor import IndicProcessor
except ImportError:  # newer toolkit releases export it from the package root
    from IndicTransToolkit import IndicProcessor

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("tmeet-translate")

# Leave most CPU cores to BigBlueButton's media services.
torch.set_num_threads(int(os.environ.get("TORCH_THREADS", "2")))

NUM_BEAMS = int(os.environ.get("NUM_BEAMS", "2"))
CACHE_SIZE = int(os.environ.get("CACHE_SIZE", "5000"))
MAX_CHARS = 500

# Browser speech locales -> IndicTrans2 language tags
LANGS = {
    "en": "eng_Latn",
    "hi": "hin_Deva",
    "ne": "npi_Deva",
}

MODELS = {
    "en-indic": "ai4bharat/indictrans2-en-indic-dist-200M",
    "indic-en": "ai4bharat/indictrans2-indic-en-dist-200M",
    "indic-indic": "ai4bharat/indictrans2-indic-indic-dist-320M",
}


def lang_tag(locale: str) -> str:
    tag = LANGS.get(locale.split("-")[0].lower())
    if not tag:
        raise HTTPException(status_code=400, detail=f"unsupported language: {locale}")
    return tag


def model_key(src: str, tgt: str) -> str:
    if src == "eng_Latn":
        return "en-indic"
    if tgt == "eng_Latn":
        return "indic-en"
    return "indic-indic"


class Translator:
    def __init__(self):
        self.processor = IndicProcessor(inference=True)
        self.models = {}
        self.load_lock = threading.Lock()
        # One generation at a time keeps CPU use predictable during meetings.
        self.run_lock = threading.Lock()
        self.cache = OrderedDict()

    def _load(self, key: str):
        with self.load_lock:
            if key not in self.models:
                name = MODELS[key]
                started = time.time()
                tokenizer = AutoTokenizer.from_pretrained(name, trust_remote_code=True)
                model = AutoModelForSeq2SeqLM.from_pretrained(name, trust_remote_code=True)
                model.eval()
                # int8 weights for Linear layers: about 4x less RAM and faster on CPU
                model = torch.quantization.quantize_dynamic(model, {torch.nn.Linear}, dtype=torch.qint8)
                self.models[key] = (tokenizer, model)
                log.info("loaded %s in %.1fs", name, time.time() - started)
        return self.models[key]

    def translate(self, text: str, src: str, tgt: str) -> tuple[str, bool]:
        cache_key = (src, tgt, text)
        if cache_key in self.cache:
            self.cache.move_to_end(cache_key)
            return self.cache[cache_key], True

        tokenizer, model = self._load(model_key(src, tgt))
        with self.run_lock:
            batch = self.processor.preprocess_batch([text], src_lang=src, tgt_lang=tgt)
            inputs = tokenizer(batch, truncation=True, padding="longest",
                               return_tensors="pt", return_attention_mask=True)
            with torch.inference_mode():
                generated = model.generate(**inputs, use_cache=True, min_length=0,
                                           max_length=256, num_beams=NUM_BEAMS,
                                           num_return_sequences=1)
            decoded = tokenizer.batch_decode(generated, skip_special_tokens=True,
                                             clean_up_tokenization_spaces=True)
            result = self.processor.postprocess_batch(decoded, lang=tgt)[0]

        self.cache[cache_key] = result
        if len(self.cache) > CACHE_SIZE:
            self.cache.popitem(last=False)
        return result, False


translator = Translator()
app = FastAPI(title="T-Meet translate", docs_url=None, redoc_url=None)


class TranslateRequest(BaseModel):
    text: str = Field(..., max_length=MAX_CHARS)
    source: str
    target: str


@app.on_event("startup")
def preload():
    for key in [k for k in os.environ.get("PRELOAD", "").split(",") if k]:
        translator._load(key)


@app.get("/health")
def health():
    return {"status": "ok", "loaded": sorted(translator.models)}


@app.post("/translate")
def translate(req: TranslateRequest):
    text = req.text.strip()
    src, tgt = lang_tag(req.source), lang_tag(req.target)
    if not text or src == tgt:
        return {"text": text, "cached": True, "ms": 0}
    started = time.time()
    result, cached = translator.translate(text, src, tgt)
    return {"text": result, "cached": cached, "ms": int((time.time() - started) * 1000)}
