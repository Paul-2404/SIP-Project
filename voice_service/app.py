"""
FastAPI Local Voice Service — Chatterbox TTS
Handles model loading, reference audio cloning, and chunk-level synthesis.
"""

import os
import sys
import time
import traceback
import hashlib
import tempfile
from pathlib import Path
from typing import Optional

import torch
import torchaudio
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel
import uvicorn

# ─── Paths ────────────────────────────────────────────────────────────────────
BASE_DIR = Path(__file__).parent.parent
AUDIO_DIR = BASE_DIR / "runtime-logs" / "express-clone"
AUDIO_DIR.mkdir(parents=True, exist_ok=True)

REF_AUDIO_PATH = BASE_DIR / "myvoice.weba"
REF_WAV_PATH = BASE_DIR / "myvoice_ref.wav"   # converted reference

# ─── App State ────────────────────────────────────────────────────────────────
app = FastAPI(title="OwnVoice TTS Service")

state = {
    "model": None,
    "model_loaded": False,
    "clone_ready": False,
    "device": "cpu",
    "load_error": None,
    "loaded_at": None,
}


# ─── Startup ──────────────────────────────────────────────────────────────────
@app.on_event("startup")
async def startup():
    """Load model on startup in the background (non-blocking for uvicorn)."""
    import threading
    t = threading.Thread(target=_load_model_and_clone, daemon=True)
    t.start()


def _load_model_and_clone():
    try:
        _load_model()
        _prepare_clone()
    except Exception as e:
        state["load_error"] = str(e)
        traceback.print_exc()


def _load_model():
    from chatterbox.tts import ChatterboxTTS

    device = "cuda" if torch.cuda.is_available() else "cpu"
    state["device"] = device
    print(f"[VoiceService] Loading ChatterboxTTS on {device.upper()}…", flush=True)

    model = ChatterboxTTS.from_pretrained(device=device)
    state["model"] = model
    state["model_loaded"] = True
    state["loaded_at"] = time.time()
    print("[VoiceService] Model loaded.", flush=True)


def _prepare_clone():
    """Convert reference .weba → .wav then warm-up with a test phrase."""
    global state

    if not REF_AUDIO_PATH.exists():
        print(f"[VoiceService] Reference audio not found: {REF_AUDIO_PATH}", flush=True)
        state["clone_ready"] = False
        return

    # Convert weba → wav using ffmpeg if not already done
    if not REF_WAV_PATH.exists() or REF_WAV_PATH.stat().st_size < 1000:
        print("[VoiceService] Converting reference audio to PCM WAV…", flush=True)
        ret = os.system(
            f'ffmpeg -y -i "{REF_AUDIO_PATH}" -ar 22050 -ac 1 -f wav "{REF_WAV_PATH}" >nul 2>&1'
        )
        if ret != 0 or not REF_WAV_PATH.exists():
            state["load_error"] = "ffmpeg failed to convert myvoice.weba → myvoice_ref.wav"
            print(f"[VoiceService] {state['load_error']}", flush=True)
            return

    # Warm-up: generate 1 second of speech, discard, ensures clone embeddings cached
    print("[VoiceService] Warming up clone voice (first inference)…", flush=True)
    try:
        _synthesize_chunk("Hello.", str(REF_WAV_PATH), str(AUDIO_DIR / "_warmup.wav"))
        (AUDIO_DIR / "_warmup.wav").unlink(missing_ok=True)
        state["clone_ready"] = True
        print("[VoiceService] Clone ready.", flush=True)
    except Exception as e:
        state["load_error"] = f"Clone warm-up failed: {e}"
        print(f"[VoiceService] {state['load_error']}", flush=True)
        traceback.print_exc()


def _synthesize_chunk(text: str, ref_wav: str, out_wav: str) -> None:
    """Run Chatterbox synthesis for a single text chunk."""
    model = state["model"]
    if model is None:
        raise RuntimeError("Model not loaded")

    wav = model.generate(
        text,
        audio_prompt_path=ref_wav,
        exaggeration=0.5,
        cfg_weight=0.5,
    )
    torchaudio.save(out_wav, wav, model.sr)


# ─── Endpoints ────────────────────────────────────────────────────────────────

class SynthRequest(BaseModel):
    text: str
    job_id: str
    out_path: str          # absolute path where the final wav should be saved


@app.get("/status")
async def get_status():
    return {
        "modelLoaded": state["model_loaded"],
        "cloneReady": state["clone_ready"],
        "device": state["device"],
        "error": state["load_error"],
    }


@app.post("/synthesize")
async def synthesize(req: SynthRequest):
    """
    Synthesize a SINGLE chunk of text.
    Called sequentially by the Express orchestrator for each sentence chunk.
    """
    if not state["model_loaded"]:
        raise HTTPException(503, "Model not loaded yet")
    if not state["clone_ready"]:
        raise HTTPException(503, "Clone not ready yet")

    text = req.text.strip()
    if not text:
        raise HTTPException(400, "Empty text")

    ref_wav = str(REF_WAV_PATH)
    if not Path(ref_wav).exists():
        raise HTTPException(503, "Reference WAV not found; clone not prepared")

    try:
        _synthesize_chunk(text, ref_wav, req.out_path)
    except Exception as e:
        traceback.print_exc()
        raise HTTPException(500, f"Synthesis error: {e}")

    return {"ok": True, "out_path": req.out_path}


@app.get("/audio/{filename}")
async def serve_audio(filename: str):
    path = AUDIO_DIR / filename
    if not path.exists():
        raise HTTPException(404, "Audio file not found")
    return FileResponse(str(path), media_type="audio/wav")


# ─── Entry ────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    port = int(os.environ.get("VOICE_PORT", "8100"))
    uvicorn.run("app:app", host="127.0.0.1", port=port, reload=False)
