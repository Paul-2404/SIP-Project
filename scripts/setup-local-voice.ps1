# setup-local-voice.ps1
# Installs all dependencies for the Own Voice TTS app.
# Run via:  npm run voice:setup
# ---------------------------------------------------------------------------
$ErrorActionPreference = "Stop"
$PSScriptRoot_safe = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot       = Split-Path -Parent $PSScriptRoot_safe

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Own Voice TTS - Local Setup" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Helper: test if a command exists in PATH
function Test-Cmd {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# 1. Node.js dependencies
# ---------------------------------------------------------------------------
Write-Host "[1/6] Installing Node.js dependencies..." -ForegroundColor Yellow
Set-Location $ProjectRoot
npm install --prefer-offline
if ($LASTEXITCODE -ne 0) { npm install }
Write-Host "      Node dependencies OK." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Python check
# ---------------------------------------------------------------------------
Write-Host "[2/6] Checking Python 3.11..." -ForegroundColor Yellow
if (-not (Test-Cmd "python")) {
    Write-Host "      ERROR: Python not found. Install Python 3.11 from python.org" -ForegroundColor Red
    exit 1
}
$pyver = python --version 2>&1
Write-Host "      Found: $pyver" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Upgrade pip
# ---------------------------------------------------------------------------
Write-Host "[3/6] Upgrading pip..." -ForegroundColor Yellow
python -m pip install --upgrade pip --quiet
Write-Host "      pip OK." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Detect GPU
# ---------------------------------------------------------------------------
Write-Host "[4/6] Detecting GPU..." -ForegroundColor Yellow

$hasCuda = $false
$gpuName = "none"
try {
    $gpuOut = nvidia-smi --query-gpu=name --format=csv,noheader 2>&1
    if ($LASTEXITCODE -eq 0 -and $gpuOut -match "NVIDIA") {
        $hasCuda = $true
        $gpuName = $gpuOut.Trim()
        Write-Host "      GPU detected: $gpuName" -ForegroundColor Cyan
    }
} catch {}

if (-not $hasCuda) {
    Write-Host "      No NVIDIA GPU found - will use CPU mode." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 5. Python packages
#    Install order matters:
#      a) chatterbox-tts first  -> pulls in torch==2.6.0 (CPU) as dependency
#      b) Re-install torch with CUDA wheels if GPU present (overrides CPU build)
#      c) Install accelerate  -> required by transformers for LlamaModel
#      d) Install fastapi, uvicorn, pydantic
# ---------------------------------------------------------------------------
Write-Host "[5/6] Installing Python packages..." -ForegroundColor Yellow

# -- 5a. chatterbox-tts (pins torch==2.6.0 as a dependency)
Write-Host "      Installing chatterbox-tts (this may take a while)..." -ForegroundColor Gray
python -m pip install chatterbox-tts --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "      WARN: chatterbox-tts returned non-zero exit - continuing..." -ForegroundColor Yellow
}

# -- 5b. Upgrade torch to CUDA build if GPU available
if ($hasCuda) {
    Write-Host "      Upgrading torch to CUDA 12.4 build (required for GTX 1650)..." -ForegroundColor Cyan
    # torch 2.6.0 is available with cu124; matching torchvision is 0.21.0
    python -m pip install `
        "torch==2.6.0+cu124" `
        "torchaudio==2.6.0+cu124" `
        "torchvision==0.21.0+cu124" `
        --index-url https://download.pytorch.org/whl/cu124 `
        --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "      WARN: CUDA torch install failed - falling back to CPU torch 2.6.0" -ForegroundColor Yellow
        python -m pip install "torch==2.6.0" "torchaudio==2.6.0" "torchvision==0.21.0" --quiet
    }
} else {
    Write-Host "      Ensuring CPU torch==2.6.0..." -ForegroundColor Gray
    python -m pip install "torch==2.6.0" "torchaudio==2.6.0" "torchvision==0.21.0" --quiet
}

# -- 5c. accelerate: required by transformers for LlamaModel to load correctly
Write-Host "      Installing accelerate (transformers dependency)..." -ForegroundColor Gray
python -m pip install accelerate --quiet

# -- 5d. FastAPI, uvicorn, pydantic
$packages = @("fastapi", "uvicorn[standard]", "pydantic>=2.0")
foreach ($pkg in $packages) {
    Write-Host "      Installing $pkg ..." -ForegroundColor Gray
    python -m pip install $pkg --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "      WARN: $pkg returned non-zero - continuing..." -ForegroundColor Yellow
    }
}

Write-Host "      Python packages OK." -ForegroundColor Green

# -- 5e. Quick import sanity check
Write-Host "      Verifying chatterbox import..." -ForegroundColor Gray
$importCheck = python -c "from chatterbox.tts import ChatterboxTTS; print('ok')" 2>&1
if ($importCheck -match "ok") {
    Write-Host "      chatterbox import OK." -ForegroundColor Green
} else {
    Write-Host "      WARN: chatterbox import check failed:" -ForegroundColor Yellow
    Write-Host "      $importCheck" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 6. ffmpeg
# ---------------------------------------------------------------------------
Write-Host "[6/6] Checking ffmpeg..." -ForegroundColor Yellow

if (Test-Cmd "ffmpeg") {
    Write-Host "      ffmpeg already available in PATH." -ForegroundColor Green
} else {
    Write-Host "      ffmpeg not in PATH - trying winget..." -ForegroundColor Yellow
    $wingetOk = $false

    if (Test-Cmd "winget") {
        try {
            # Try install first; if already installed winget exits 0 with "already installed" msg
            winget install --id Gyan.FFmpeg -e --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
            # winget exits 0 on success or "already installed"
            $wingetOk = $true
        } catch {
            $wingetOk = $false
        }
    }

    if (-not $wingetOk) {
        Write-Host ""
        Write-Host "  *** MANUAL ACTION REQUIRED ***" -ForegroundColor Red
        Write-Host "  ffmpeg could not be installed automatically." -ForegroundColor Red
        Write-Host "  Download from: https://ffmpeg.org/download.html" -ForegroundColor Yellow
        Write-Host "  Extract the zip and add the bin folder to your PATH," -ForegroundColor Yellow
        Write-Host "  then re-run: npm run voice:setup" -ForegroundColor Yellow
        Write-Host ""
    }

    # Refresh PATH in current session
    $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)
    $userPath    = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
    $env:PATH    = "$machinePath;$userPath"

    if (Test-Cmd "ffmpeg") {
        Write-Host "      ffmpeg available." -ForegroundColor Green
    } else {
        Write-Host "      WARNING: ffmpeg still not found in PATH after install." -ForegroundColor Yellow
        Write-Host "      Audio chunk merging will fail until ffmpeg is on PATH." -ForegroundColor Yellow
        Write-Host "      Restart your terminal after installing ffmpeg." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Reference audio check
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "--- Reference Audio Check ----------------------------------" -ForegroundColor Cyan

$refCandidates = @("myvoice.webm", "myvoice.weba", "myvoice.wav")
$refFound = $null
foreach ($name in $refCandidates) {
    $candidate = Join-Path $ProjectRoot $name
    if (Test-Path $candidate) {
        $refFound = $candidate
        break
    }
}

if ($null -ne $refFound) {
    $refSize = (Get-Item $refFound).Length
    $refName = Split-Path $refFound -Leaf
    $refKB   = [math]::Round($refSize / 1024, 1)
    Write-Host "  [OK] Found $refName ($refKB KB)" -ForegroundColor Green
} else {
    Write-Host "  [MISSING] No reference audio found in: $ProjectRoot" -ForegroundColor Red
    Write-Host "  Accepted filenames: myvoice.webm | myvoice.weba | myvoice.wav" -ForegroundColor Yellow
    Write-Host "  Record 10-30 seconds of clean speech and place it in the project root." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Ensure runtime log dir exists
# ---------------------------------------------------------------------------
$logDir = Join-Path $ProjectRoot "runtime-logs\express-clone"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Next step - start the app:" -ForegroundColor White
Write-Host "    npm run express:voice" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Then open: http://127.0.0.1:3100" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
