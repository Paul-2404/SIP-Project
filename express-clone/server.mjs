/**
 * Express Orchestrator — Own Voice TTS
 * Manages jobs, chunking, Python service lifecycle, and audio delivery.
 */

import express from "express";
import { createReadStream, existsSync, mkdirSync, unlinkSync, readdirSync } from "fs";
import { writeFile, readFile } from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";
import { randomUUID } from "crypto";
import { spawn, execSync } from "child_process";
import fetch from "node-fetch";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");

// ─── Config ──────────────────────────────────────────────────────────────────
const EXPRESS_PORT = 3100;
const VOICE_PORT   = 8100;
const VOICE_BASE   = `http://127.0.0.1:${VOICE_PORT}`;
const LOG_DIR      = path.join(ROOT, "runtime-logs", "express-clone");
const AUDIO_DIR    = LOG_DIR;                    // chunks & final WAVs land here
const REF_AUDIO    = path.join(ROOT, "myvoice.weba");

// Chunk size limits (chars)
const CHUNK_TARGET = 150;
const CHUNK_MAX    = 220;

mkdirSync(LOG_DIR,   { recursive: true });
mkdirSync(AUDIO_DIR, { recursive: true });

// ─── Logger ──────────────────────────────────────────────────────────────────
function log(...args) {
  const ts = new Date().toISOString();
  console.log(`[Express ${ts}]`, ...args);
}

// ─── Job Store (in-memory) ────────────────────────────────────────────────────
/**
 * @type {Map<string, {
 *   id: string, status: 'queued'|'running'|'done'|'failed',
 *   percent: number, label: string,
 *   resultPath?: string, error?: string,
 *   createdAt: number
 * }>}
 */
const jobs = new Map();
let activeJobId = null;

function createJob() {
  const id = randomUUID();
  jobs.set(id, {
    id, status: "queued", percent: 0,
    label: "Queued", createdAt: Date.now(),
  });
  return id;
}

function updateJob(id, patch) {
  const job = jobs.get(id);
  if (job) jobs.set(id, { ...job, ...patch });
}

// Purge jobs older than 1 hour to avoid unbounded memory growth
setInterval(() => {
  const cutoff = Date.now() - 3_600_000;
  for (const [id, job] of jobs) {
    if (job.createdAt < cutoff) {
      if (job.resultPath && existsSync(job.resultPath)) unlinkSync(job.resultPath);
      jobs.delete(id);
    }
  }
}, 600_000);

// ─── Python Service Lifecycle ─────────────────────────────────────────────────
let pyProcess = null;

async function isVoiceServiceUp() {
  try {
    const res = await fetch(`${VOICE_BASE}/status`, { signal: AbortSignal.timeout(2500) });
    return res.ok;
  } catch {
    return false;
  }
}

async function ensureVoiceService() {
  if (await isVoiceServiceUp()) return;

  log("Starting Python voice service…");
  const appPy = path.join(ROOT, "voice_service", "app.py");

  pyProcess = spawn(
    "python",
    [appPy],
    {
      env: { ...process.env, VOICE_PORT: String(VOICE_PORT) },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
      detached: false,
    }
  );

  pyProcess.stdout.on("data", d => process.stdout.write(`[PY] ${d}`));
  pyProcess.stderr.on("data", d => process.stderr.write(`[PY] ${d}`));
  pyProcess.on("exit", code => {
    log(`Python voice service exited (code ${code})`);
    pyProcess = null;
  });

  // Wait up to 90 s for service to come up (model download on first run)
  const deadline = Date.now() + 90_000;
  while (Date.now() < deadline) {
    await sleep(2000);
    if (await isVoiceServiceUp()) {
      log("Python voice service is up.");
      return;
    }
  }
  log("WARNING: Python voice service did not come up within 90 s; continuing anyway.");
}

// ─── Text Chunker ─────────────────────────────────────────────────────────────
/**
 * Split text into sentence-aware chunks.
 * Strategy:
 *   1. Split on sentence-ending punctuation keeping the delimiter.
 *   2. Merge short sentences until CHUNK_TARGET is reached or CHUNK_MAX exceeded.
 */
function splitIntoChunks(text) {
  // Split on sentence boundaries
  const sentences = text
    .replace(/([.!?…]+)\s+/g, "$1\n")
    .split("\n")
    .map(s => s.trim())
    .filter(Boolean);

  const chunks = [];
  let current = "";

  for (const sentence of sentences) {
    // If even a single sentence exceeds CHUNK_MAX, hard-split it
    if (sentence.length > CHUNK_MAX) {
      // Flush current buffer first
      if (current) { chunks.push(current.trim()); current = ""; }
      // Hard-split on word boundary
      const words = sentence.split(" ");
      let buf = "";
      for (const w of words) {
        if ((buf + " " + w).trim().length > CHUNK_MAX) {
          if (buf) chunks.push(buf.trim());
          buf = w;
        } else {
          buf = (buf + " " + w).trim();
        }
      }
      if (buf) current = buf;
      continue;
    }

    const candidate = current ? current + " " + sentence : sentence;
    if (candidate.length <= CHUNK_TARGET) {
      current = candidate;
    } else if (current.length >= CHUNK_TARGET || candidate.length > CHUNK_MAX) {
      chunks.push(current.trim());
      current = sentence;
    } else {
      current = candidate;
    }
  }
  if (current.trim()) chunks.push(current.trim());
  return chunks.filter(Boolean);
}

// ─── ffmpeg Helpers ───────────────────────────────────────────────────────────
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function mergeWavFiles(chunkPaths, outPath) {
  if (chunkPaths.length === 1) {
    // No merge needed
    await writeFile(outPath, await readFile(chunkPaths[0]));
    return;
  }

  // Write concat list
  const listPath = path.join(AUDIO_DIR, `concat_${Date.now()}.txt`);
  const listContent = chunkPaths.map(p => `file '${p.replace(/\\/g, "/")}'`).join("\n");
  await writeFile(listPath, listContent, "utf8");

  await new Promise((resolve, reject) => {
    const ff = spawn("ffmpeg", [
      "-y", "-f", "concat", "-safe", "0",
      "-i", listPath,
      "-c", "copy",
      outPath,
    ]);
    ff.on("close", code => {
      try { unlinkSync(listPath); } catch {}
      code === 0 ? resolve() : reject(new Error(`ffmpeg exit ${code}`));
    });
    ff.on("error", err => reject(new Error(`ffmpeg spawn error: ${err.message}`)));
  });
}

// ─── Synthesis Orchestrator ───────────────────────────────────────────────────
async function runSynthesisJob(jobId, text) {
  const chunks = splitIntoChunks(text);
  log(`Job ${jobId}: ${chunks.length} chunk(s) for ${text.length} chars`);

  updateJob(jobId, { status: "running", percent: 2, label: "Starting synthesis…" });

  const chunkPaths = [];

  for (let i = 0; i < chunks.length; i++) {
    const chunk = chunks[i];
    const chunkFile = path.join(AUDIO_DIR, `${jobId}_chunk${i}.wav`);
    const pct = Math.round(5 + ((i / chunks.length) * 85));
    updateJob(jobId, {
      percent: pct,
      label: `Generating chunk ${i + 1}/${chunks.length}…`,
    });

    log(`Job ${jobId} chunk ${i + 1}/${chunks.length}: "${chunk.slice(0, 60)}…"`);

    let attempt = 0;
    const MAX_ATTEMPTS = 3;
    while (attempt < MAX_ATTEMPTS) {
      try {
        const res = await fetch(`${VOICE_BASE}/synthesize`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ text: chunk, job_id: jobId, out_path: chunkFile }),
          signal: AbortSignal.timeout(180_000),   // 3 min per chunk
        });
        if (!res.ok) {
          const errText = await res.text().catch(() => "");
          throw new Error(`Voice service ${res.status}: ${errText}`);
        }
        break;
      } catch (err) {
        attempt++;
        log(`Job ${jobId} chunk ${i} attempt ${attempt} failed: ${err.message}`);
        if (attempt >= MAX_ATTEMPTS) throw err;
        await sleep(2000);
      }
    }
    chunkPaths.push(chunkFile);
  }

  // Merge
  updateJob(jobId, { percent: 93, label: "Merging audio chunks…" });
  const finalPath = path.join(AUDIO_DIR, `${jobId}_final.wav`);
  await mergeWavFiles(chunkPaths, finalPath);

  // Cleanup chunks
  for (const cp of chunkPaths) {
    try { unlinkSync(cp); } catch {}
  }

  updateJob(jobId, {
    status: "done", percent: 100, label: "Done",
    resultPath: finalPath,
  });
  log(`Job ${jobId} complete → ${finalPath}`);
}

// ─── Express App ──────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());

// Serve UI
app.get("/", (req, res) => {
  res.sendFile(path.join(__dirname, "site.html"));
});

// GET /api/status
app.get("/api/status", async (req, res) => {
  // Attempt to recover voice service if down
  const up = await isVoiceServiceUp();
  if (!up) ensureVoiceService().catch(e => log("ensureVoiceService error:", e.message));

  let voiceStatus = { modelLoaded: false, cloneReady: false, device: "unknown", error: null };
  try {
    const r = await fetch(`${VOICE_BASE}/status`, { signal: AbortSignal.timeout(2000) });
    if (r.ok) voiceStatus = await r.json();
  } catch {}

  res.json({
    ...voiceStatus,
    serviceUp: up,
    activeJobId,
    activeJobStatus: activeJobId ? jobs.get(activeJobId)?.status ?? null : null,
  });
});

// POST /api/speak
app.post("/api/speak", async (req, res) => {
  const { text } = req.body;
  if (!text || !text.trim()) {
    return res.status(400).json({ error: "Text is required." });
  }

  // Concurrency guard
  if (activeJobId) {
    const activeJob = jobs.get(activeJobId);
    if (activeJob && (activeJob.status === "queued" || activeJob.status === "running")) {
      return res.status(409).json({
        error: "Another generation is in progress. Please wait.",
        jobId: activeJobId,
      });
    }
  }

  // Check service readiness
  const up = await isVoiceServiceUp();
  if (!up) {
    ensureVoiceService().catch(() => {});
    return res.status(503).json({ error: "Voice service is starting up. Please retry shortly." });
  }

  // Fast-fail if clone not ready
  let status;
  try {
    const r = await fetch(`${VOICE_BASE}/status`, { signal: AbortSignal.timeout(2000) });
    status = await r.json();
  } catch {
    return res.status(503).json({ error: "Could not reach voice service." });
  }

  if (!status.cloneReady) {
    return res.status(503).json({
      error: status.error
        ? `Clone failed: ${status.error}`
        : "Clone not ready yet. Please wait for model initialisation.",
    });
  }

  // Create job and respond immediately
  const jobId = createJob();
  activeJobId = jobId;
  res.json({ jobId });

  // Run synthesis asynchronously
  runSynthesisJob(jobId, text.trim())
    .catch(err => {
      log(`Job ${jobId} failed:`, err.message);
      updateJob(jobId, { status: "failed", label: "Failed", error: err.message });
    })
    .finally(() => {
      if (activeJobId === jobId) activeJobId = null;
    });
});

// GET /api/job/:id
app.get("/api/job/:id", (req, res) => {
  const job = jobs.get(req.params.id);
  if (!job) return res.status(404).json({ error: "Job not found." });

  const { id, status, percent, label, error } = job;
  const resultUrl = status === "done" ? `/api/audio/${id}` : undefined;
  res.json({ id, status, percent, label, resultUrl, error });
});

// GET /api/audio/:jobId → stream final wav
app.get("/api/audio/:jobId", (req, res) => {
  const job = jobs.get(req.params.jobId);
  if (!job) return res.status(404).json({ error: "Job not found." });
  if (job.status !== "done") return res.status(409).json({ error: "Audio not ready yet." });
  if (!job.resultPath || !existsSync(job.resultPath)) {
    return res.status(404).json({ error: "Audio file missing on disk." });
  }

  res.setHeader("Content-Type", "audio/wav");
  res.setHeader("Content-Disposition", `inline; filename="speech_${req.params.jobId}.wav"`);
  createReadStream(job.resultPath).pipe(res);
});

// ─── Startup ──────────────────────────────────────────────────────────────────
app.listen(EXPRESS_PORT, "127.0.0.1", async () => {
  log(`Server listening → http://127.0.0.1:${EXPRESS_PORT}`);
  await ensureVoiceService();
  log("Init complete. Ready.");
});
