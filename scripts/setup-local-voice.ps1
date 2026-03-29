# ──────────────────────────────────────────────────────────────────────────────
# setup-local-voice.ps1
# Installs all dependencies for the Own Voice TTS app.
# Run from the project root with:
#   npm run voice:setup
# ──────────────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"
$PSScriptRoot_safe     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot           = Split-Path -Parent $PSScriptRoot_safe

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Own Voice TTS — Local Setup" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ── Helper: Check if a command exists ────────────────────────────────────────
function Test-Cmd($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# ── 1. Node dependencies ──────────────────────────────────────────────────────
Write-Host "[1/6] Installing Node.js dependencies..." -ForegroundColor Yellow
Set-Location $ProjectRoot
npm install --prefer-offline
if ($LASTEXITCODE -ne 0) { npm install }
Write-Host "      Node dependencies OK." -ForegroundColor Green

# ── 2. Python environment check ───────────────────────────────────────────────
Write-Host "[2/6] Checking Python 3.11..." -ForegroundColor Yellow
if (-not (Test-Cmd "python")) {
    Write-Host "      ERROR: Python not found. Install Python 3.11 from python.org" -ForegroundColor Red
    exit 1
}
$pyver = python --version 2>&1
Write-Host "      Found: $pyver" -ForegroundColor Green

# ── 3. pip upgrade ────────────────────────────────────────────────────────────
Write-Host "[3/6] Upgrading pip..." -ForegroundColor Yellow
python -m pip install --upgrade pip --quiet
Write-Host "      pip OK." -ForegroundColor Green

# ── 4. PyTorch + CUDA ────────────────────────────────────────────────────────
Write-Host "[4/6] Installing PyTorch (CUDA 12.1 if GPU present, else CPU)..." -ForegroundColor Yellow

# Detect GPU
$hasCuda = $false
try {
    $gpuOut = nvidia-smi --query-gpu=name --format=csv,noheader 2>&1
    if ($LASTEXITCODE -eq 0 -and $gpuOut -match "NVIDIA") {
        $hasCuda = $true
        Write-Host "      GPU detected: $gpuOut" -ForegroundColor Cyan
    }
} catch {}

if ($hasCuda) {
    Write-Host "      Installing torch with CUDA 12.1 support..." -ForegroundColor Cyan
    python -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121 --quiet
} else {
    Write-Host "      No GPU detected — installing CPU-only torch..." -ForegroundColor Yellow
    python -m pip install torch torchvision torchaudio --quiet
}
Write-Host "      PyTorch OK." -ForegroundColor Green

# ── 5. Python packages ────────────────────────────────────────────────────────
Write-Host "[5/6] Installing Python packages (FastAPI, Chatterbox TTS, etc.)..." -ForegroundColor Yellow

$packages = @(
    "fastapi",
    "uvicorn[standard]",
    "chatterbox-tts",
    "pydantic>=2.0"
)

foreach ($pkg in $packages) {
    Write-Host "      Installing $pkg..." -ForegroundColor Gray
    python -m pip install $pkg --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "      WARN: $pkg install returned non-zero; continuing..." -ForegroundColor Yellow
    }
}
Write-Host "      Python packages OK." -ForegroundColor Green

# ── 6. ffmpeg ─────────────────────────────────────────────────────────────────
Write-Host "[6/6] Checking ffmpeg..." -ForegroundColor Yellow

if (Test-Cmd "ffmpeg") {
    Write-Host "      ffmpeg already available." -ForegroundColor Green
} else {
    Write-Host "      ffmpeg not found. Attempting install via winget..." -ForegroundColor Yellow
    $wingetOk = $false

    if (Test-Cmd "winget") {
        try {
            winget install --id Gyan.FFmpeg -e --silent --accept-source-agreements --accept-package-agreements
            $wingetOk = ($LASTEXITCODE -eq 0)
        } catch {}
    }

    if (-not $wingetOk) {
        Write-Host "      winget install failed. Trying Chocolatey..." -ForegroundColor Yellow
        if (Test-Cmd "choco") {
            choco install ffmpeg -y
        } else {
            Write-Host ""
            Write-Host "  ┌──────────────────────────────────────────────────────┐" -ForegroundColor Red
            Write-Host "  │  MANUAL ACTION REQUIRED: ffmpeg not installed.       │" -ForegroundColor Red
            Write-Host "  │  Download from: https://ffmpeg.org/download.html     │" -ForegroundColor Red
            Write-Host "  │  Extract and add to PATH, then re-run setup.         │" -ForegroundColor Red
            Write-Host "  └──────────────────────────────────────────────────────┘" -ForegroundColor Red
            Write-Host ""
        }
    }

    # Refresh PATH so ffmpeg is visible without restarting shell
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")

    if (Test-Cmd "ffmpeg") {
        Write-Host "      ffmpeg installed successfully." -ForegroundColor Green
    } else {
        Write-Host "      WARNING: ffmpeg still not in PATH. Audio merge will fail." -ForegroundColor Yellow
        Write-Host "      Install manually and add to PATH." -ForegroundColor Yellow
    }
}

# ── Reference audio check ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Reference Audio Check ─────────────────────────────────" -ForegroundColor Cyan
$refAudio = Join-Path $ProjectRoot "myvoice.weba"
if (Test-Path $refAudio) {
    $size = (Get-Item $refAudio).Length
    Write-Host "  ✓ Found myvoice.weba ($([math]::Round($size/1024, 1)) KB)" -ForegroundColor Green
} else {
    Write-Host "  ✗ myvoice.weba NOT found at: $refAudio" -ForegroundColor Red
    Write-Host "    Record a 10–30 second clean voice sample and save it as myvoice.weba" -ForegroundColor Yellow
    Write-Host "    in the project root, then run this setup again." -ForegroundColor Yellow
}

# ── Runtime log dirs ──────────────────────────────────────────────────────────
$logDir = Join-Path $ProjectRoot "runtime-logs\express-clone"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  To start the app:" -ForegroundColor White
Write-Host "    npm run express:voice" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Then open: http://127.0.0.1:3100" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
