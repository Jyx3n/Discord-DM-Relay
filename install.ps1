<#
.SYNOPSIS
  Installs DMRelay: a Vencord plugin + local receiver that lets a
  backtalk-based voice assistant read your Discord DMs out loud.

.DESCRIPTION
  This script:
    1. Checks for git, Node.js, and pnpm (installs pnpm via npm if missing)
    2. Clones Vencord's source into .\vencord-src
    3. Copies the DMRelay plugin into it and builds it
    4. Injects the build into the Discord branch you choose
    5. Generates fresh secrets and sets up the local receiver
  It does NOT touch your backtalk installation  -  see README.md for the
  (manual, ~15 line) voice-announcement integration step.

.NOTES
  Windows only. Run from inside the DMRelay-release folder:
    powershell -ExecutionPolicy Bypass -File install.ps1
#>

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Warn2($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

Write-Step "Checking prerequisites"

foreach ($cmd in @("git", "node")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: '$cmd' is required and was not found on PATH." -ForegroundColor Red
        Write-Host "Install it, then run this script again." -ForegroundColor Red
        exit 1
    }
}

if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Warn2 "pnpm not found  -  installing it via npm (one-time)..."
    npm install -g pnpm | Out-Null
}

Write-Step "Which Discord branch do you want to patch?"
Write-Host "  1) Canary  (recommended  -  separate from your main Discord)"
Write-Host "  2) PTB"
Write-Host "  3) Stable  (your everyday Discord  -  think twice)"
$choice = Read-Host "Enter 1, 2, or 3"
$branch = switch ($choice) {
    "1" { "canary" }
    "2" { "ptb" }
    "3" { "stable" }
    default { Write-Host "Invalid choice."; exit 1 }
}

if ($branch -eq "stable") {
    Write-Warn2 "You picked your everyday Discord account's branch."
    Write-Warn2 "Read the RISKS section of README.md before continuing."
    $confirm = Read-Host "Type YES to continue anyway"
    if ($confirm -ne "YES") { Write-Host "Aborted."; exit 0 }
}

$vencordDir = Join-Path $root "vencord-src"

if (-not (Test-Path $vencordDir)) {
    Write-Step "Cloning Vencord into .\vencord-src"
    git clone --depth 1 https://github.com/Vencord/Vencord.git $vencordDir
} else {
    Write-Step "Vencord source already present, skipping clone"
}

Write-Step "Copying the DMRelay plugin into Vencord's userplugins"
$pluginDest = Join-Path $vencordDir "src\userplugins\DMRelay"
New-Item -ItemType Directory -Force -Path $pluginDest | Out-Null
Copy-Item (Join-Path $root "plugin\index.ts") (Join-Path $pluginDest "index.ts") -Force

Write-Step "Generating fresh secrets (never share these)"
function New-Secret {
    $bytes = New-Object byte[] 24
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    -join ($bytes | ForEach-Object { $_.ToString("x2") })
}
$dmrelaySecret = New-Secret
$triggerSecret = New-Secret

(Get-Content (Join-Path $pluginDest "index.ts") -Raw) `
    -replace "CHANGE_ME_generate_your_own_secret", $dmrelaySecret |
    Set-Content (Join-Path $pluginDest "index.ts") -Encoding utf8

$receiverDir = Join-Path $root "receiver"
$secretsFile = Join-Path $receiverDir "secrets.local.json"
@{
    dmrelay_secret          = $dmrelaySecret
    backtalk_trigger_secret = $triggerSecret
    branch                  = $branch
} | ConvertTo-Json | Set-Content $secretsFile -Encoding utf8

Write-Step "Installing dependencies and building the plugin (this takes a minute)"
Push-Location $vencordDir
pnpm install --frozen-lockfile 2>$null
if ($LASTEXITCODE -ne 0) { pnpm install }
pnpm build
Pop-Location

Write-Step "Downloading the Vencord installer"
$installerDir = Join-Path $vencordDir "dist\Installer"
New-Item -ItemType Directory -Force -Path $installerDir | Out-Null
$installerExe = Join-Path $installerDir "VencordInstallerCli.exe"
if (-not (Test-Path $installerExe)) {
    Invoke-WebRequest -Uri "https://github.com/Vencord/Installer/releases/latest/download/VencordInstallerCli.exe" -OutFile $installerExe
}

Write-Step "Patching Discord ($branch)"
$env:VENCORD_USER_DATA_DIR = $vencordDir
& $installerExe -install -branch $branch
Remove-Item Env:\VENCORD_USER_DATA_DIR

$pythonCmd = Get-Command pythonw -ErrorAction SilentlyContinue
if (-not $pythonCmd) { $pythonCmd = Get-Command python -ErrorAction SilentlyContinue }
if (-not $pythonCmd) {
    Write-Warn2 "python was not found on PATH - install it, then re-run this script to finish setup."
} else {
    Write-Step "Setting the receiver to start automatically (Windows login)"
    $startupDir = [Environment]::GetFolderPath("Startup")
    $launcherVbs = Join-Path $startupDir "DMRelayReceiver.vbs"
    # VBScript, not a .bat: Run with windowstyle 0 means no console window
    # ever flashes up at every login, unlike "start /min" in a batch file.
    $receiverScript = Join-Path $receiverDir "receiver.py"
    $innerCmd = "`"$($pythonCmd.Source)`" `"$receiverScript`""
    $vbsCmdLiteral = $innerCmd.Replace('"', '""')
    $vbsContent = "Set WshShell = CreateObject(`"WScript.Shell`")`r`nWshShell.Run `"$vbsCmdLiteral`", 0, False"
    Set-Content -Path $launcherVbs -Value $vbsContent -Encoding ASCII
    Write-Host "    Receiver will auto-start on every Windows login from now on."
    Write-Host "    Starting it now for this session too..."
    Start-Process -WindowStyle Hidden -FilePath $pythonCmd.Source -ArgumentList "`"$receiverDir\receiver.py`""
}

Write-Host "`n====================================================" -ForegroundColor Green
Write-Host " Done. Next steps:" -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green
Write-Host "1. Start Discord ($branch) if it isn't already running."
Write-Host "2. Settings -> Vencord -> Plugins -> search 'DMRelay' -> enable it."
Write-Host "3. The receiver is already running, and will auto-start every login."
Write-Host "   To stop auto-start, delete: $startupDir\DMRelayReceiver.vbs"
Write-Host "4. OPTIONAL  -  spoken announcements: see README.md 'Voice integration'"
Write-Host "   to add the small trigger-server snippet to your own backtalk fork."
Write-Host "5. RECOMMENDED  -  see README.md 'Agent behavior rules': have your"
Write-Host "   agent check the receiver is alive at its own startup, in case"
Write-Host "   the auto-start entry above ever silently stops working."
Write-Host "`nIf Discord ($branch) ever auto-updates, the Vencord patch gets wiped."
Write-Host "Re-run: `$env:VENCORD_USER_DATA_DIR='$vencordDir'; & '$installerExe' -install -branch $branch"
