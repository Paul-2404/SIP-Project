# ──────────────────────────────────────────────────────────────────────────────
# prepare-gpt-sovits-dataset.ps1
# Optional: prepares a transcript CSV from myvoice.weba for GPT-SoVITS or
# Whisper-based dataset creation. Use if you want a fallback dataset approach.
# ──────────────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Continue"
$PSScriptRoot_safe = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot       = Split-Path -Parent $PSScriptRoot_safe

Write-Host "Preparing dataset transcript from myvoice.weba..." -ForegroundColor Cyan

$refAudio = Join-Path $ProjectRoot "myvoice.weba"
$outDir   = Join-Path $ProjectRoot "dataset"
$outCsv   = Join-Path $outDir "transcript.csv"

if (-not (Test-Path $refAudio)) {
    Write-Host "ERROR: myvoice.weba not found." -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# Convert weba to wav
$wavPath = Join-Path $outDir "myvoice.wav"
ffmpeg -y -i $refAudio -ar 22050 -ac 1 -f wav $wavPath 2>&1 | Out-Null

if (-not (Test-Path $wavPath)) {
    Write-Host "ERROR: ffmpeg conversion failed." -ForegroundColor Red
    exit 1
}

Write-Host "Converted to WAV: $wavPath" -ForegroundColor Green

# Try to transcribe with whisper if installed
$whisperOk = $false
try {
    $whisperCheck = python -c "import whisper; print('ok')" 2>&1
    if ($whisperCheck -eq "ok") { $whisperOk = $true }
} catch {}

if ($whisperOk) {
    Write-Host "Transcribing with Whisper (base model)..." -ForegroundColor Yellow
    $transcript = python -c @"
import whisper, json, sys
model = whisper.load_model('base')
result = model.transcribe(r'$($wavPath.Replace("\","\\"))')
print(result['text'].strip())
"@
    Write-Host "Transcript: $transcript" -ForegroundColor White
    Set-Content -Path $outCsv -Value "filename,text`nmyvoice.wav,`"$transcript`""
    Write-Host "Saved transcript to: $outCsv" -ForegroundColor Green
} else {
    Write-Host "Whisper not installed. Creating empty transcript CSV." -ForegroundColor Yellow
    Set-Content -Path $outCsv -Value "filename,text`nmyvoice.wav,`"[Add transcript here]`""
    Write-Host "Edit $outCsv with the transcript of myvoice.weba for dataset training." -ForegroundColor Cyan
}

Write-Host "Done." -ForegroundColor Green
