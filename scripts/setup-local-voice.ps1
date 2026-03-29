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
# 4. PyTorch (CUDA 12.1 if GPU present, else CPU)
# ---------------------------------------------------------------------------
Write-Host "[4/6] Installing PyTorch..." -ForegroundColor Yellow

$hasCuda = $false
try {
    $gpuOut = nvidia-smi --query-gpu=name --format=csv,noheader 2>&1
    if ($LASTEXITCODE -eq 0 -and $gpuOut -match "NVIDIA") {
        $hasCuda = $true
        Write-Host "      GPU detected: $gpuOut" -ForegroundColor Cyan
    }
} catch {}

if ($hasCuda) {
    Write-Host "      Installing torch with CUDA 12.1..." -ForegroundColor Cyan
    python -m pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121 --quiet
} else {
    Write-Host "      No GPU detected - installing CPU-only torch..." -ForegroundColor Yellow
    python -m pip install torch torchvision torchaudio --quiet
}
Write-Host "      PyTorch OK." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 5. Python packages: FastAPI, Chatterbox TTS, uvicorn, pydantic
# ---------------------------------------------------------------------------
Write-Host "[5/6] Installing Python packages..." -ForegroundColor Yellow

$packages = @(
    "fastapi",
    "uvicorn[standard]",
    "chatterbox-tts",
    "pydantic>=2.0"
)

foreach ($pkg in $packages) {
    Write-Host "      Installing $pkg ..." -ForegroundColor Gray
    python -m pip install $pkg --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "      WARN: $pkg returned non-zero exit - continuing..." -ForegroundColor Yellow
    }
}
Write-Host "      Python packages OK." -ForegroundColor Green

# ---------------------------------------------------------------------------
# 6. ffmpeg
# ---------------------------------------------------------------------------
Write-Host "[6/6] Checking ffmpeg..." -ForegroundColor Yellow

if (Test-Cmd "ffmpeg") {
    Write-Host "      ffmpeg already available." -ForegroundColor Green
} else {
    Write-Host "      ffmpeg not found. Trying winget..." -ForegroundColor Yellow
    $wingetOk = $false

    if (Test-Cmd "winget") {
        try {
            winget install --id Gyan.FFmpeg -e --silent --accept-source-agreements --accept-package-agreements
            $wingetOk = ($LASTEXITCODE -eq 0)
        } catch {}
    }

    if (-not $wingetOk) {
        Write-Host "      winget failed. Trying Chocolatey..." -ForegroundColor Yellow
        if (Test-Cmd "choco") {
            choco install ffmpeg -y
        } else {
            Write-Host "" 
            Write-Host "  *** MANUAL ACTION REQUIRED ***" -ForegroundColor Red
            Write-Host "  ffmpeg is not installed and could not be auto-installed." -ForegroundColor Red
            Write-Host "  Download from: https://ffmpeg.org/download.html" -ForegroundColor Yellow
            Write-Host "  Extract the zip and add the 'bin' folder to your PATH," -ForegroundColor Yellow
            Write-Host "  then re-run: npm run voice:setup" -ForegroundColor Yellow
            Write-Host ""
        }
    }

    # Refresh PATH in current session after install
    $machinePath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::Machine)
    $userPath    = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
    $env:PATH    = "$machinePath;$userPath"

    if (Test-Cmd "ffmpeg") {
        Write-Host "      ffmpeg installed OK." -ForegroundColor Green
    } else {
        Write-Host "      WARNING: ffmpeg still not in PATH - audio merge will fail." -ForegroundColor Yellow
        Write-Host "      Install manually from https://ffmpeg.org and add to PATH." -ForegroundColor Yellow
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
    $refSize  = (Get-Item $refFound).Length
    $refName  = Split-Path $refFound -Leaf
    $refKB    = [math]::Round($refSize / 1024, 1)
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
