# TermNotify installer. Run install.cmd (double-click) or:
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#
# What does this do?
#   It sets everything up for you, in 5 steps, like building with
#   blocks: copy the files, make a settings file, teach PowerShell,
#   teach Command Prompt, and then help you set up your phone.

$ErrorActionPreference = 'Stop'                       # if something breaks, stop right away
$src      = $PSScriptRoot                             # the folder this installer is in
$dest     = Join-Path $HOME '.termnotify'             # where we'll keep the scripts
$confPath = Join-Path $HOME '.termnotify.conf'        # where we'll keep your settings
$begin    = '# >>> TermNotify >>>'                    # a "start here" sticker for your profile
$end      = '# <<< TermNotify <<<'                    # an "end here" sticker for your profile

# Ask you a yes-or-no question. If you just press Enter,
# we pick the answer shown in CAPITAL letters.
function Ask([string]$q, [bool]$defaultYes = $true) {
    $hint = if ($defaultYes) { '[Y/n]' } else { '[y/N]' }
    $a = Read-Host "$q $hint"
    if (-not $a) { return $defaultYes }
    return $a -match '^(y|yes)$'
}

Write-Host ''
Write-Host '=== TermNotify installer ===' -ForegroundColor Cyan

# Step 1: Copy the scripts into a folder in your user folder.
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $src 'termnotify.ps1'), (Join-Path $src 'termnotify.lua'), (Join-Path $src 'uninstall.ps1') $dest -Force
Get-ChildItem $dest | Unblock-File   # tell Windows "these files are OK to run"
Write-Host "[1/5] Scripts copied to $dest"

# Step 2: Make a settings file with a secret mailbox name (topic)
# that's really hard to guess.
if (Test-Path $confPath) {
    # You already have settings? Keep them, and just read your mailbox name.
    $topic = ((Get-Content $confPath) -match '^\s*TN_TOPIC\s*=' | Select-Object -First 1) -replace '^\s*TN_TOPIC\s*=\s*', ''
    Write-Host "[2/5] Keeping existing settings ($confPath)"
} else {
    # Make up a random name, like drawing letters out of a hat.
    # (We skip letters that look alike, such as 0 and o, or 1 and l.)
    $chars = 'abcdefghjkmnpqrstuvwxyz23456789'
    $bytes = New-Object byte[] 12
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $topic = 'termnotify-' + (-join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] }))
    $custom = Read-Host "[2/5] Your notification topic will be '$topic'. Press Enter to accept, or type your own"
    if ($custom) { $topic = $custom.Trim() }

    # Write the settings file. The lines starting with # are notes for you.
    @"
# TermNotify settings. Open a new terminal after editing.

# ntfy server and topic. Anyone who knows the topic name can read it,
# so keep it long and random.
TN_SERVER=https://ntfy.sh
TN_TOPIC=$topic

# Notify when a command runs at least this many seconds.
TN_THRESHOLD=3

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

# Step 3: Teach PowerShell about TermNotify. This covers the old
# PowerShell (5.1), the new one (7), and the VS Code typing window.

# Some computers say "no scripts allowed!" We change that to the
# safe setting Microsoft recommends, just for you (not the whole PC).
$policy = Get-ExecutionPolicy
if ($policy -in 'Restricted', 'AllSigned', 'Undefined') {
    try {
        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
        Write-Host "      PowerShell was set to block profile scripts ($policy); changed to RemoteSigned for your user."
    } catch {
        Write-Warning "Could not change the execution policy: $($_.Exception.Message)"
    }
}

# Find your Documents folder (even if OneDrive moved it somewhere else).
$docs = [Environment]::GetFolderPath('MyDocuments')   # follows OneDrive redirection
# These 3 lines get added to your profile. A "profile" is a list of
# things PowerShell does every time it opens, like a morning routine.
$block = @"
$begin
if (Test-Path "`$HOME\.termnotify\termnotify.ps1") { . "`$HOME\.termnotify\termnotify.ps1" }
$end
"@
# Old PowerShell keeps its profile in "WindowsPowerShell", new
# PowerShell keeps it in "PowerShell". We add our lines to both.
foreach ($dir in 'WindowsPowerShell', 'PowerShell') {
    $profilePath = Join-Path (Join-Path $docs $dir) 'profile.ps1'
    New-Item -ItemType Directory -Force -Path (Split-Path $profilePath) | Out-Null
    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
    # Already has our "start here" sticker? Then don't add it twice.
    if ($existing -and $existing.Contains($begin)) {
        Write-Host "[3/5] Already in $profilePath"
        continue
    }
    $sep = if ($existing -and -not $existing.EndsWith("`n")) { "`r`n" } else { '' }   # start on a fresh line
    Add-Content -Path $profilePath -Value ($sep + $block) -Encoding UTF8
    Write-Host "[3/5] Added to $profilePath"
}

# Step 4: Teach Command Prompt about TermNotify. Command Prompt can't
# tell when a job is done on its own, so it needs a helper called Clink.
$clinkProfile = Join-Path $env:LOCALAPPDATA 'clink'
New-Item -ItemType Directory -Force -Path $clinkProfile | Out-Null
Copy-Item (Join-Path $src 'termnotify.lua') $clinkProfile -Force   # Clink reads scripts from this folder
# Is Clink already on this computer? Look in all the usual places.
$clinkFound = (Get-Command clink -ErrorAction SilentlyContinue) -or
              (Test-Path "${env:ProgramFiles(x86)}\clink") -or (Test-Path "$env:ProgramFiles\clink")
if ($clinkFound) {
    Write-Host "[4/5] Clink found; Command Prompt hook installed to $clinkProfile"
} else {
    # Not there? Offer to get it with winget (Windows' own app store helper).
    Write-Host '[4/5] Command Prompt needs Clink (a free add-on) to detect when commands finish.'
    if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Ask '      Install Clink now with winget?' $true)) {
        winget install --id chrisant996.Clink -e --accept-package-agreements --accept-source-agreements
        Write-Host '      Clink installed. New Command Prompt windows will load the hook.'
    } else {
        Write-Host '      Skipped. Later, run: winget install chrisant996.Clink'
    }
}

# Step 5: Help you set up your phone, then send a test message.
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
    . (Join-Path $dest 'termnotify.ps1')   # load TermNotify right here, just for the test
    Import-TermNotifyConfig
    Send-TermNotify -Wait
}

# All done! Old windows don't know about TermNotify yet, so they need a restart.
Write-Host ''
Write-Host 'Done. Close and reopen your terminals (including VS Code) to start.' -ForegroundColor Green
Write-Host 'Try it:  Start-Sleep 5   (PowerShell)   or   timeout /t 5   (Command Prompt)'
