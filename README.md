# Own Voice TTS

Local text-to-speech app that clones your voice using [Chatterbox TTS](https://github.com/resemble-ai/chatterbox).  
No paid APIs. Runs entirely on your machine. GPU-accelerated (GTX 1650+) or CPU fallback.

---

## Quick Start

### Prerequisites
- Windows 10/11
- Node.js 20+
- Python 3.11
- NVIDIA GPU (optional — CPU fallback works, slower)
- A voice reference file in the project root (10–30 seconds of clean speech):
  `myvoice.webm` **or** `myvoice.weba` **or** `myvoice.wav`

### 1. Add your voice reference

Record or export a clean 10–30 second audio sample of your voice and save it as **any** of:

| Filename | Format | Notes |
|----------|--------|-------|
| `myvoice.webm` | WebM/Opus | ✅ Browser `MediaRecorder` output |
| `myvoice.weba` | WebM Audio | ✅ Same container, audio-only variant |
| `myvoice.wav` | PCM WAV | ✅ Skips ffmpeg conversion step |

Place the chosen file in the **project root**. The app auto-detects whichever is present (`.webm` checked first).

### 2. Install everything
```powershell
npm run voice:setup
```
This installs Node packages, PyTorch (CUDA 12.1 if GPU detected, else CPU), Chatterbox TTS, FastAPI, and ffmpeg.

### 3. Start the app
```powershell
npm run express:voice
```

### 4. Open the browser
```
http://127.0.0.1:3100
```

Wait ~30–90 seconds for the model to load and clone to warm up (one-time per session).  
Once the status badge shows **"Clone ready"**, type any text and click **Generate Speech**.

---

## Architecture

```
Browser ──► Express (3100) ──► FastAPI voice service (8100)
                │                        │
                │                  chatterbox-tts
                │                  (CUDA or CPU)
                │
         Job Store (in-memory)
         ffmpeg audio merge
         /runtime-logs/express-clone/
```

### API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/status` | Clone readiness, device mode, active job |
| POST | `/api/speak` | Start job → returns `{ jobId }` immediately |
| GET | `/api/job/:id` | Poll status: `queued/running/done/failed` + progress % |
| GET | `/api/audio/:jobId` | Stream final WAV when done |

### Long Text Handling

Text is split sentence-aware into ~150-char chunks (hard max 220 chars).  
Each chunk is synthesised sequentially against the cloned voice.  
Chunks are merged with `ffmpeg concat` into one final WAV.  
No request can time out — jobs run asynchronously.

### Concurrency

Only one synthesis job runs at a time. A second request while one is active returns HTTP 409 with the existing `jobId`.

---

## File Structure

```
SIP Project/
├── express-clone/
│   ├── server.mjs          ← Express orchestrator
│   └── site.html           ← Frontend UI
├── voice_service/
│   └── app.py              ← FastAPI + Chatterbox TTS
├── scripts/
│   ├── setup-local-voice.ps1
│   └── prepare-gpt-sovits-dataset.ps1
├── runtime-logs/
│   └── express-clone/      ← chunk WAVs, final WAVs (auto-purged after 1h)
├── myvoice.weba            ← YOUR voice reference (you provide this)
├── myvoice_ref.wav         ← auto-generated PCM conversion
└── package.json
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Status stuck at "Loading model…" | First run downloads ~1 GB. Wait 2–5 min. |
| `ffmpeg not found` | Run `winget install Gyan.FFmpeg` then restart terminal |
| Clone warm-up fails | Check `myvoice.weba` exists and is valid audio (>5 s) |
| Job fails mid-synthesis | Python service may have crashed; next `/api/speak` auto-restarts it |
| CUDA out of memory | Edit `voice_service/app.py` and force `device="cpu"` |

---

## License

MIT — use freely for personal/research purposes.  
Chatterbox TTS is licensed separately by Resemble AI.
