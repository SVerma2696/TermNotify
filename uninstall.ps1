# Removes TermNotify. Run uninstall.cmd (double-click) or:
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
#
# What does this do?
#   It cleans up everything the installer added, like putting your
#   toys back in the box when playtime is over.

$begin = '# >>> TermNotify >>>'                       # the "start here" sticker we look for
$end   = '# <<< TermNotify <<<'                       # the "end here" sticker we look for
$docs  = [Environment]::GetFolderPath('MyDocuments')  # your Documents folder (even if OneDrive moved it)

# Take our lines out of both PowerShell profiles (the old and the new one).
foreach ($dir in 'WindowsPowerShell', 'PowerShell') {
    $profilePath = Join-Path (Join-Path $docs $dir) 'profile.ps1'
    if (-not (Test-Path $profilePath)) { continue }   # no profile? nothing to clean
    $text = Get-Content $profilePath -Raw
    if (-not $text.Contains($begin)) { continue }     # no sticker? we were never here
    # Cut out everything from the "start" sticker to the "end" sticker.
    # Everything else in your profile stays just the way it was.
    $pattern = '(\r?\n)?' + [regex]::Escape($begin) + '[\s\S]*?' + [regex]::Escape($end) + '(\r?\n)?'
    Set-Content -Path $profilePath -Value ([regex]::Replace($text, $pattern, '')) -NoNewline -Encoding UTF8
    Write-Host "Removed hook from $profilePath"
}

# Take our script out of Clink's folder (for Command Prompt).
$lua = Join-Path $env:LOCALAPPDATA 'clink\termnotify.lua'
if (Test-Path $lua) { Remove-Item $lua -Force; Write-Host "Removed $lua" }

# Throw away the folder where we kept the scripts.
$dest = Join-Path $HOME '.termnotify'
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force; Write-Host "Removed $dest" }

# Your settings file has your secret mailbox name, so we ask first
# before throwing it away. If you just press Enter, we keep it.
$conf = Join-Path $HOME '.termnotify.conf'
if (Test-Path $conf) {
    $a = Read-Host "Also delete your settings file ($conf)? [y/N]"
    if ($a -match '^(y|yes)$') { Remove-Item $conf -Force; Write-Host "Removed $conf" }
}

Write-Host 'TermNotify removed. Reopen your terminals. (Clink, if installed, stays; remove it in Settings > Apps.)'
