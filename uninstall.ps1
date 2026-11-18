# Removes TermNotify. Run uninstall.cmd (double-click) or:
#   powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1

$begin = '# >>> TermNotify >>>'
$end   = '# <<< TermNotify <<<'
$docs  = [Environment]::GetFolderPath('MyDocuments')

foreach ($dir in 'WindowsPowerShell', 'PowerShell') {
    $profilePath = Join-Path (Join-Path $docs $dir) 'profile.ps1'
    if (-not (Test-Path $profilePath)) { continue }
    $text = Get-Content $profilePath -Raw
    if (-not $text.Contains($begin)) { continue }
    $pattern = '(\r?\n)?' + [regex]::Escape($begin) + '[\s\S]*?' + [regex]::Escape($end) + '(\r?\n)?'
    Set-Content -Path $profilePath -Value ([regex]::Replace($text, $pattern, '')) -NoNewline -Encoding UTF8
    Write-Host "Removed hook from $profilePath"
}

$lua = Join-Path $env:LOCALAPPDATA 'clink\termnotify.lua'
if (Test-Path $lua) { Remove-Item $lua -Force; Write-Host "Removed $lua" }

$dest = Join-Path $HOME '.termnotify'
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force; Write-Host "Removed $dest" }

$conf = Join-Path $HOME '.termnotify.conf'
if (Test-Path $conf) {
    $a = Read-Host "Also delete your settings file ($conf)? [y/N]"
    if ($a -match '^(y|yes)$') { Remove-Item $conf -Force; Write-Host "Removed $conf" }
}

Write-Host 'TermNotify removed. Reopen your terminals. (Clink, if installed, stays; remove it in Settings > Apps.)'
