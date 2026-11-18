# TermNotify installer. Run install.cmd (double-click) or:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = 'Stop'
$src      = $PSScriptRoot
$dest     = Join-Path $HOME '.termnotify'
$confPath = Join-Path $HOME '.termnotify.conf'
$begin    = '# >>> TermNotify >>>'
$end      = '# <<< TermNotify <<<'

function Ask([string]$q, [bool]$defaultYes = $true) {
    $hint = if ($defaultYes) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$q $hint"
    if (-not $a) { return $defaultYes }
    return $a -match '^(y|yes)$'
}

Write-Host ''
Write-Host '=== TermNotify installer ===' -ForegroundColor Cyan

# 1. Copy the hook scripts to ~\.termnotify
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $src 'termnotify.ps1'), (Join-Path $src 'termnotify.lua'), (Join-Path $src 'uninstall.ps1') $dest -Force
Get-ChildItem $dest | Unblock-File
Write-Host "[1/5] Scripts copied to $dest"

# 2. Settings file with a private, hard-to-guess ntfy topic
if (Test-Path $confPath) {
    $topic = ((Get-Content $confPath) -match '^\s*TN_TOPIC\s*=' | Select-Object -First 1) -replace '^\s*TN_TOPIC\s*=\s*', ''
    Write-Host "[2/5] Keeping existing settings ($confPath)"
} else {
    $chars = 'abcdefghjkmnpqrstuvwxyz23456789'
    $bytes = New-Object byte[] 12
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $topic = 'termnotify-' + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
    $custom = Read-Host "[2/5] Your notification topic will be '$topic'. Press Enter to accept, or type your own"
    if ($custom) { $topic = $custom.Trim() }

    @"
# TermNotify settings. Open a new terminal after editing.

# ntfy server and topic. Anyone who knows the topic name can read it,
# so keep it long and random.
TN_SERVER=https://ntfy.sh
TN_TOPIC=$topic

# Notify when a command runs at least this many seconds.
TN_THRESHOLD=60

# Never notify for these programs (interactive tools you leave open).
TN_IGNORE=ssh vim nvim vi nano less more man top htop btop

# Skip these only when run with no arguments (an interactive REPL/shell).
# "python train.py" still notifies; plain "python" does not.
TN_IGNORE_BARE=python python3 py ipython node bash zsh wsl pwsh powershell cmd claude

# If this PC is offline when a command finishes, keep retrying this
# many minutes in the background (0 = try once).
TN_RETRY_MINUTES=30

# Access token, only if you use a protected ntfy server.
TN_TOKEN=

# Set to off to pause notifications everywhere.
TN_ENABLED=on
"@ | Set-Content -Path $confPath -Encoding ASCII
    Write-Host "      Settings saved to $confPath"
}

# 3. PowerShell profiles (covers Windows PowerShell 5.1, PowerShell 7, VS Code terminal)
$policy = Get-ExecutionPolicy
if ($policy -in 'Restricted', 'AllSigned', 'Undefined') {
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
        Write-Host "      PowerShell was set to block profile scripts ($policy); changed to RemoteSigned for your user."
    } catch {
        Write-Warning "Could not change the execution policy: $($_.Exception.Message)"
    }
}

$docs = [Environment]::GetFolderPath('MyDocuments')   # follows OneDrive redirection
$block = @"
$begin
if (Test-Path "`$HOME\.termnotify\termnotify.ps1") { . "`$HOME\.termnotify\termnotify.ps1" }
$end
"@
foreach ($dir in 'WindowsPowerShell', 'PowerShell') {
    $profilePath = Join-Path (Join-Path $docs $dir) 'profile.ps1'
    New-Item -ItemType Directory -Force -Path (Split-Path $profilePath) | Out-Null
    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
    if ($existing -and $existing.Contains($begin)) {
        Write-Host "[3/5] Already in $profilePath"
        continue
    }
    $sep = if ($existing -and -not $existing.EndsWith("`n")) { "`r`n" } else { '' }
    Add-Content -Path $profilePath -Value ($sep + $block) -Encoding UTF8
    Write-Host "[3/5] Added to $profilePath"
}

# 4. Command Prompt support through Clink
$clinkProfile = Join-Path $env:LOCALAPPDATA 'clink'
New-Item -ItemType Directory -Force -Path $clinkProfile | Out-Null
Copy-Item (Join-Path $src 'termnotify.lua') $clinkProfile -Force
$clinkFound = (Get-Command clink -ErrorAction SilentlyContinue) -or
              (Test-Path "${env:ProgramFiles(x86)}\clink") -or (Test-Path "$env:ProgramFiles\clink")
if ($clinkFound) {
    Write-Host "[4/5] Clink found; Command Prompt hook installed to $clinkProfile"
} else {
    Write-Host '[4/5] Command Prompt needs Clink (a free add-on) to detect when commands finish.'
    if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Ask '      Install Clink now with winget?' $true)) {
        winget install --id chrisant996.Clink -e --accept-package-agreements --accept-source-agreements
        Write-Host '      Clink installed. New Command Prompt windows will load the hook.'
    } else {
        Write-Host '      Skipped. Later, run: winget install chrisant996.Clink'
    }
}

# 5. Phone setup and test
Write-Host ''
Write-Host '[5/5] Set up your phone:' -ForegroundColor Cyan
Write-Host '   1. Install the free "ntfy" app (App Store on iPhone, Google Play on Android).'
Write-Host '   2. Open it, tap +, and subscribe to this topic (keep the default server):'
Write-Host ''
Write-Host "        $topic" -ForegroundColor Yellow
Write-Host ''
Write-Host '   3. Allow notifications when the app asks.'
Write-Host ''
if (Ask 'Send a test notification now?' $true) {
    . (Join-Path $dest 'termnotify.ps1')
    Import-TermNotifyConfig
    Send-TermNotify -Wait
}

Write-Host ''
Write-Host 'Done. Close and reopen your terminals (including VS Code) to start.' -ForegroundColor Green
Write-Host 'Try it:  Start-Sleep 65   (PowerShell)   or   timeout /t 65   (Command Prompt)'
