# TermNotify for PowerShell
# Sends a push notification to your phone (via ntfy) when a command
# runs longer than TN_THRESHOLD seconds. Loaded from your PowerShell
# profile, so it works in Windows Terminal, plain PowerShell, and the
# VS Code integrated terminal (Windows PowerShell 5.1 and PowerShell 7+).
#
# Commands:  tn-test  (send a test)   tn-off / tn-on  (mute this window)

if ($global:__TN_Loaded) { return }
$global:__TN_Loaded = $true

$global:__TN = @{
    ConfigPath = Join-Path $HOME '.termnotify.conf'
    Server     = 'https://ntfy.sh'
    Topic      = ''
    Threshold  = 60
    Ignore     = @()
    IgnoreBare = @()
    Token      = ''
    Retry      = 30
    Enabled    = $true
    LastId     = -1
    Client     = $null
    SenderReady = $null
}

function global:Import-TermNotifyConfig {
    $path = $global:__TN.ConfigPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -notmatch '^\s*(TN_[A-Z_]+)\s*=\s*(.*?)\s*$') { continue }
        $key = $Matches[1]; $val = $Matches[2]
        switch ($key) {
            'TN_SERVER'      { if ($val) { $global:__TN.Server = $val.TrimEnd('/') } }
            'TN_TOPIC'       { $global:__TN.Topic = $val }
            'TN_THRESHOLD'   { if ($val -match '^\d+$') { $global:__TN.Threshold = [int]$val } }
            'TN_IGNORE'      { $global:__TN.Ignore = @($val.ToLower() -split '\s+' | Where-Object { $_ }) }
            'TN_IGNORE_BARE' { $global:__TN.IgnoreBare = @($val.ToLower() -split '\s+' | Where-Object { $_ }) }
            'TN_TOKEN'       { $global:__TN.Token = $val }
            'TN_RETRY_MINUTES' { if ($val -match '^\d+$') { $global:__TN.Retry = [int]$val } }
            'TN_ENABLED'     { $global:__TN.Enabled = ($val -notmatch '^(0|false|no|off)$') }
        }
    }
}

function global:Format-TNDuration([TimeSpan]$t) {
    $h = [int][math]::Floor($t.TotalHours)
    $m = [int][math]::Floor($t.TotalMinutes)
    $s = [int][math]::Floor($t.TotalSeconds)
    if ($h -ge 1) { return ('{0}h {1:00}m' -f $h, $t.Minutes) }
    if ($m -ge 1) { return ('{0}m {1:00}s' -f $m, $t.Seconds) }
    return ('{0}s' -f $s)
}

# Background sender written in C# so it can keep retrying after the prompt
# returns (for example while your laptop is reconnecting to the internet).
$global:__TN_SenderSource = @'
using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading.Tasks;

public static class TermNotifySender {
    static readonly HttpClient Client = MakeClient();

    static HttpClient MakeClient() {
        var c = new HttpClient();
        c.Timeout = TimeSpan.FromSeconds(15);
        return c;
    }

    // Returns "" on success, otherwise the last error. Retries with backoff
    // for up to retryMinutes when there is no connection or the server is busy.
    public static Task<string> Send(string url, string json, string token, int retryMinutes) {
        return Task.Run(async () => {
            DateTime deadline = DateTime.UtcNow.AddMinutes(retryMinutes);
            int delay = 5;
            string error = "";
            while (true) {
                bool retryable = true;
                try {
                    var req = new HttpRequestMessage(HttpMethod.Post, url);
                    req.Content = new StringContent(json, Encoding.UTF8, "application/json");
                    if (!String.IsNullOrEmpty(token)) {
                        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                    }
                    var resp = await Client.SendAsync(req).ConfigureAwait(false);
                    int code = (int)resp.StatusCode;
                    if (code >= 200 && code < 300) return "";
                    error = "ntfy answered " + code + ": " + await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    retryable = code >= 500 || code == 429;
                } catch (Exception ex) {
                    error = ex.GetBaseException().Message;
                }
                if (!retryable || DateTime.UtcNow >= deadline) return error;
                await Task.Delay(TimeSpan.FromSeconds(delay)).ConfigureAwait(false);
                delay = Math.Min(delay * 2, 60);
            }
        });
    }
}
'@

function global:Initialize-TNSender {
    if ($null -ne $global:__TN.SenderReady) { return $global:__TN.SenderReady }
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    try {
        if (-not ('TermNotifySender' -as [type])) {
            $refs = if ($PSVersionTable.PSEdition -eq 'Core') {
                'System.Net.Http', 'System.Net.Primitives', 'System.Runtime', 'System.Threading.Tasks'
            } else {
                'System.Net.Http'
            }
            Add-Type -TypeDefinition $global:__TN_SenderSource -ReferencedAssemblies $refs -ErrorAction Stop
        }
        $global:__TN.SenderReady = $true
    } catch {
        $global:__TN.SenderReady = $false   # fall back to a single attempt below
    }
    return $global:__TN.SenderReady
}

function global:Send-TermNotify {
    param(
        [string]$Title    = 'TermNotify is working',
        [string]$Message  = "Test notification from $env:COMPUTERNAME",
        [string[]]$Tags   = @('bell'),
        [int]$Priority    = 3,
        [switch]$Wait
    )
    if (-not $global:__TN.Topic) {
        Write-Warning "TermNotify: no topic set. Edit $($global:__TN.ConfigPath)"
        return
    }

    $body = [ordered]@{
        topic    = $global:__TN.Topic
        title    = $Title
        message  = $Message
        tags     = [string[]]$Tags
        priority = $Priority
    } | ConvertTo-Json -Compress
    $url = "$($global:__TN.Server)/"

    if (Initialize-TNSender) {
        $retry = if ($Wait) { 0 } else { $global:__TN.Retry }   # a test should answer right away
        $task = [TermNotifySender]::Send($url, $body, $global:__TN.Token, $retry)
        if ($Wait) { $err = $task.GetAwaiter().GetResult() }
    } else {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        if (-not $global:__TN.Client) {
            $global:__TN.Client = [System.Net.Http.HttpClient]::new()
            $global:__TN.Client.Timeout = [TimeSpan]::FromSeconds(15)
        }
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $url)
        $req.Content = [System.Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
        if ($global:__TN.Token) {
            $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $global:__TN.Token)
        }
        $task = $global:__TN.Client.SendAsync($req)
        if ($Wait) {
            try {
                $resp = $task.GetAwaiter().GetResult()
                $err = if ($resp.IsSuccessStatusCode) { '' } else { "ntfy answered $([int]$resp.StatusCode)" }
            } catch { $err = $_.Exception.GetBaseException().Message }
        }
    }

    if ($Wait) {
        if (-not $err) {
            Write-Host "Sent to topic '$($global:__TN.Topic)'. Check your phone." -ForegroundColor Green
        } else {
            Write-Warning "Could not send: $err  (Is this PC online? Your phone can be on cellular data.)"
        }
    }
}

function global:Get-TNProgramName([string]$cmd) {
    $c = $cmd.Trim() -replace '^[&.]\s+', ''
    if ($c -match '^\s*(?:"([^"]+)"|''([^'']+)''|(\S+))(.*)$') {
        $tok  = ($Matches[1], $Matches[2], $Matches[3] | Where-Object { $_ } | Select-Object -First 1)
        $rest = $Matches[4].Trim()
        $name = ($tok -split '[\\/]')[-1] -replace '\.(exe|cmd|bat|ps1|com)$', ''
        return @{ Name = $name.ToLower(); Bare = ($rest -eq '') }
    }
    return @{ Name = ''; Bare = $true }
}

function global:Invoke-TNCheck([bool]$ok) {
    try {
        if (-not $global:__TN.Enabled -or -not $global:__TN.Topic) { return }
        $h = Get-History -Count 1
        if (-not $h -or $h.Id -eq $global:__TN.LastId) { return }
        $global:__TN.LastId = $h.Id

        $dur = $h.EndExecutionTime - $h.StartExecutionTime
        if ($dur.TotalSeconds -lt $global:__TN.Threshold) { return }

        $cmd  = $h.CommandLine.Trim()
        $prog = Get-TNProgramName $cmd
        if ($global:__TN.Ignore -contains $prog.Name) { return }
        if ($prog.Bare -and $global:__TN.IgnoreBare -contains $prog.Name) { return }

        $time   = Format-TNDuration $dur
        $status = [string]$h.ExecutionStatus
        if ($status -eq 'Stopped') {
            $title = "Stopped after $time"; $tags = @('octagonal_sign'); $prio = 3
        } elseif ($ok -and $status -eq 'Completed') {
            $title = "Done in $time";       $tags = @('white_check_mark'); $prio = 3
        } else {
            $title = "Failed after $time";  $tags = @('x'); $prio = 4
        }

        $short = if ($cmd.Length -gt 200) { $cmd.Substring(0, 197) + '...' } else { $cmd }
        $loc = (Get-Location).Path
        $folder = Split-Path -Leaf $loc
        if (-not $folder) { $folder = $loc }

        Send-TermNotify -Title $title -Message "$short`n$folder - $env:COMPUTERNAME" -Tags $tags -Priority $prio
    } catch { }   # a notification problem must never break your prompt
}

function global:tn-test { Send-TermNotify -Wait }
function global:tn-off  { $global:__TN.Enabled = $false; Write-Host 'TermNotify muted in this window.' }
function global:tn-on   { $global:__TN.Enabled = $true;  Write-Host 'TermNotify on.' }

Import-TermNotifyConfig

# Wrap whatever prompt is already defined (default, posh-git, etc.).
# Starship / oh-my-posh replace the prompt without calling the old one,
# so the TermNotify line must come AFTER them in your profile.
$global:__TN_OrigPrompt = $function:prompt
function global:prompt {
    $tnOk = $?
    Invoke-TNCheck $tnOk
    if (-not $tnOk) { Write-Error 'failure' -ErrorAction Ignore }   # hand $? back unchanged
    if ($global:__TN_OrigPrompt) { & $global:__TN_OrigPrompt }
    else { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
}
