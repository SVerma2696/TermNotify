# TermNotify for PowerShell
#
# What is this?
#   When you tell the computer to do a job, and the job takes a while,
#   this file sends a little "ding!" message to your phone when the job
#   is done. Like a kitchen timer that rings when the cookies are ready!
#
# Where does it work?
#   In PowerShell (the blue or black typing window), Windows Terminal,
#   and the typing window inside VS Code.
#
# Magic words you can type:
#   tn-test   = send a pretend message, to check it works
#   tn-off    = be quiet in this window
#   tn-on     = start talking again in this window

# If we already loaded this file, stop here. We don't want to do
# everything twice, just like you don't put on two pairs of shoes.
if ($global:__TN_Loaded) { return }
$global:__TN_Loaded = $true

# This is our toy box. It holds every setting we need to remember.
# These are the "starting" values. The settings file can change them.
$global:__TN = @{
    ConfigPath = Join-Path $HOME '.termnotify.conf'   # where the settings file lives
    Server     = 'https://ntfy.sh'                    # the post office that carries messages to your phone
    Topic      = ''                                   # your secret mailbox name
    Threshold  = 3                                    # how many seconds a job must take before we tell you
    Ignore     = @()                                  # programs we never tell you about
    IgnoreBare = @()                                  # programs we skip only when typed all by themselves
    Token      = ''                                   # a secret key, only for special private post offices
    Retry      = 30                                   # minutes to keep trying if the internet is gone
    Enabled    = $true                                # $true = talking, $false = being quiet
    LastId     = -1                                   # the last job we checked, so we never check it twice
    Client     = $null                                # our backup way of sending, made only if we need it
    SenderReady = $null                               # did our main sender get built? (not known yet)
}

# Read the settings file, one line at a time, like reading a list
# your mom wrote. Each line looks like NAME=value.
function global:Import-TermNotifyConfig {
    $path = $global:__TN.ConfigPath
    # No settings file? Then just use the starting values.
    if (-not (Test-Path -LiteralPath $path)) { return }
    foreach ($line in Get-Content -LiteralPath $path) {
        # Skip lines that don't look like TN_SOMETHING=value (like notes with #).
        if ($line -notmatch '^\s*(TN_[A-Z_]+)\s*=\s*(.*?)\s*$') { continue }
        $key = $Matches[1]; $val = $Matches[2]
        # Look at the name, and put the value in the right spot in the toy box.
        switch ($key) {
            'TN_SERVER'      { if ($val) { $global:__TN.Server = $val.TrimEnd('/') } }
            'TN_TOPIC'       { $global:__TN.Topic = $val }
            'TN_THRESHOLD'   { if ($val -match '^\d+$') { $global:__TN.Threshold = [int]$val } }   # only if it's a number
            'TN_IGNORE'      { $global:__TN.Ignore = @($val.ToLower() -split '\s+' | Where-Object { $_ }) }   # split "a b c" into a list
            'TN_IGNORE_BARE' { $global:__TN.IgnoreBare = @($val.ToLower() -split '\s+' | Where-Object { $_ }) }
            'TN_TOKEN'       { $global:__TN.Token = $val }
            'TN_RETRY_MINUTES' { if ($val -match '^\d+$') { $global:__TN.Retry = [int]$val } }
            'TN_ENABLED'     { $global:__TN.Enabled = ($val -notmatch '^(0|false|no|off)$') }   # "off" means be quiet
        }
    }
}

# Turn a length of time into easy words, like "2m 14s"
# (2 minutes and 14 seconds) or "1h 05m" (1 hour and 5 minutes).
function global:Format-TNDuration([TimeSpan]$t) {
    $h = [int][math]::Floor($t.TotalHours)
    $m = [int][math]::Floor($t.TotalMinutes)
    $s = [int][math]::Floor($t.TotalSeconds)
    if ($h -ge 1) { return ('{0}h {1:00}m' -f $h, $t.Minutes) }   # an hour or more
    if ($m -ge 1) { return ('{0}m {1:00}s' -f $m, $t.Seconds) }   # a minute or more
    return ('{0}s' -f $s)                                         # just seconds
}

# This is our mail carrier. It is written in a different computer
# language (C#) so it can keep working in the background, even after
# you go back to typing. If the internet is gone (like when your laptop
# is waking up), it waits a bit and tries again, and again.
$global:__TN_SenderSource = @'
using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading.Tasks;

public static class TermNotifySender {
    // One shared "phone line" to the internet that we reuse every time.
    static readonly HttpClient Client = MakeClient();

    static HttpClient MakeClient() {
        var c = new HttpClient();
        c.Timeout = TimeSpan.FromSeconds(15);   // if nobody answers in 15 seconds, stop waiting
        return c;
    }

    // Send the message. Gives back "" (nothing) if it worked, or what
    // went wrong if it didn't. Keeps trying for up to retryMinutes when
    // there is no internet or the post office is too busy.
    public static Task<string> Send(string url, string json, string token, int retryMinutes) {
        return Task.Run(async () => {
            DateTime deadline = DateTime.UtcNow.AddMinutes(retryMinutes);   // when we give up
            int delay = 5;                                                  // wait 5 seconds before the first retry
            string error = "";
            while (true) {
                bool retryable = true;   // is this a problem where trying again could help?
                try {
                    // Write the letter and put it in the envelope.
                    var req = new HttpRequestMessage(HttpMethod.Post, url);
                    req.Content = new StringContent(json, Encoding.UTF8, "application/json");
                    if (!String.IsNullOrEmpty(token)) {
                        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);   // add the secret key
                    }
                    // Mail it, and wait to hear back.
                    var resp = await Client.SendAsync(req).ConfigureAwait(false);
                    int code = (int)resp.StatusCode;
                    if (code >= 200 && code < 300) return "";   // 200-something means "got it, thanks!"
                    error = "ntfy answered " + code + ": " + await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                    // 500-something = the post office is broken right now. 429 = "slow down!"
                    // Those might get better, so we try again. Other answers won't.
                    retryable = code >= 500 || code == 429;
                } catch (Exception ex) {
                    error = ex.GetBaseException().Message;   // probably no internet, so try again later
                }
                if (!retryable || DateTime.UtcNow >= deadline) return error;   // time to give up
                await Task.Delay(TimeSpan.FromSeconds(delay)).ConfigureAwait(false);   // take a little nap
                delay = Math.Min(delay * 2, 60);   // nap twice as long next time, but never more than 1 minute
            }
        });
    }
}
'@

# Build the mail carrier above. We only do this once. If it can't be
# built, we remember that and use a simpler backup plan instead.
function global:Initialize-TNSender {
    if ($null -ne $global:__TN.SenderReady) { return $global:__TN.SenderReady }   # already tried? use that answer
    try {
        # Turn on the safe, modern way of talking to websites (TLS 1.2).
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    try {
        if (-not ('TermNotifySender' -as [type])) {
            # The new PowerShell (7) and the old one (5.1) need different
            # building blocks, so we hand each one the right blocks.
            $refs = if ($PSVersionTable.PSEdition -eq 'Core') {
                'System.Net.Http', 'System.Net.Primitives', 'System.Runtime', 'System.Threading.Tasks'
            } else {
                'System.Net.Http'
            }
            Add-Type -TypeDefinition $global:__TN_SenderSource -ReferencedAssemblies $refs -ErrorAction Stop
        }
        $global:__TN.SenderReady = $true
    } catch {
        $global:__TN.SenderReady = $false   # couldn't build it, so use the backup plan (it tries just once)
    }
    return $global:__TN.SenderReady
}

# Send one message to your phone.
#   -Title    = the big words at the top
#   -Message  = the smaller words underneath
#   -Tags     = little pictures (emoji) to show
#   -Priority = how loud it is (3 = normal, 4 = louder)
#   -Wait     = wait to find out if it worked (used by tn-test)
function global:Send-TermNotify {
    param(
        [string]$Title    = 'TermNotify is working',
        [string]$Message  = "Test notification from $env:COMPUTERNAME",
        [string[]]$Tags   = @('bell'),
        [int]$Priority    = 3,
        [switch]$Wait
    )
    # No mailbox name? We can't send anything, so say so and stop.
    if (-not $global:__TN.Topic) {
        Write-Warning "TermNotify: no topic set. Edit $($global:__TN.ConfigPath)"
        return
    }

    # Pack everything into a neat little bundle (JSON) the post office understands.
    $body = [ordered]@{
        topic    = $global:__TN.Topic
        title    = $Title
        message  = $Message
        tags     = [string[]]$Tags
        priority = $Priority
    } | ConvertTo-Json -Compress
    $url = "$($global:__TN.Server)/"

    if (Initialize-TNSender) {
        # Plan A: our mail carrier who keeps trying.
        $retry = if ($Wait) { 0 } else { $global:__TN.Retry }   # a test should answer right away
        $task = [TermNotifySender]::Send($url, $body, $global:__TN.Token, $retry)
        if ($Wait) { $err = $task.GetAwaiter().GetResult() }
    } else {
        # Plan B: send it once, the simple way.
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

    # If we waited (a test), tell you how it went: green = yay, yellow = uh-oh.
    if ($Wait) {
        if (-not $err) {
            Write-Host "Sent to topic '$($global:__TN.Topic)'. Check your phone." -ForegroundColor Green
        } else {
            Write-Warning "Could not send: $err  (Is this PC online? Your phone can be on cellular data.)"
        }
    }
}

# Find the name of the program in what you typed.
# "python train.py"  ->  name is "python", and it is NOT by itself.
# "python"           ->  name is "python", and it IS by itself (Bare).
function global:Get-TNProgramName([string]$cmd) {
    $c = $cmd.Trim() -replace '^[&.]\s+', ''   # throw away a leading & or . (they just mean "run this")
    # Grab the first word (it might have "quotes" around it), and the rest.
    if ($c -match '^\s*(?:"([^"]+)"|''([^'']+)''|(\S+))(.*)$') {
        $tok  = ($Matches[1], $Matches[2], $Matches[3] | Where-Object { $_ } | Select-Object -First 1)
        $rest = $Matches[4].Trim()
        # Keep only the last part of a path (C:\tools\git.exe -> git.exe), then drop .exe and friends.
        $name = ($tok -split '[\\/]')[-1] -replace '\.(exe|cmd|bat|ps1|com)$', ''
        return @{ Name = $name.ToLower(); Bare = ($rest -eq '') }
    }
    return @{ Name = ''; Bare = $true }
}

# This runs every time you finish a job. It asks:
#   Did the job take long enough? Is it a program we should skip?
#   Did it work, break, or get stopped? Then it sends the right message.
function global:Invoke-TNCheck([bool]$ok) {
    try {
        if (-not $global:__TN.Enabled -or -not $global:__TN.Topic) { return }   # quiet mode, or no mailbox
        $h = Get-History -Count 1                                              # look at the last job you ran
        if (-not $h -or $h.Id -eq $global:__TN.LastId) { return }              # nothing new? (you just pressed Enter)
        $global:__TN.LastId = $h.Id

        # How long did it take? Too short? Then don't bother you.
        $dur = $h.EndExecutionTime - $h.StartExecutionTime
        if ($dur.TotalSeconds -lt $global:__TN.Threshold) { return }

        # Is this a program we promised to skip?
        $cmd  = $h.CommandLine.Trim()
        $prog = Get-TNProgramName $cmd
        if ($global:__TN.Ignore -contains $prog.Name) { return }
        if ($prog.Bare -and $global:__TN.IgnoreBare -contains $prog.Name) { return }

        # Pick the words and the picture for the message.
        $time   = Format-TNDuration $dur
        $status = [string]$h.ExecutionStatus
        if ($status -eq 'Stopped') {
            # You pressed Ctrl+C to stop it.
            $title = "Stopped after $time"; $tags = @('octagonal_sign'); $prio = 3
        } elseif ($ok -and $status -eq 'Completed') {
            # It worked! Hooray!
            $title = "Done in $time";       $tags = @('white_check_mark'); $prio = 3
        } else {
            # Something went wrong, so this one is a bit louder.
            $title = "Failed after $time";  $tags = @('x'); $prio = 4
        }

        # Long commands get cut short (200 letters max) so the message fits.
        $short = if ($cmd.Length -gt 200) { $cmd.Substring(0, 197) + '...' } else { $cmd }
        # Which folder were you in? We only show the last folder's name.
        $loc = (Get-Location).Path
        $folder = Split-Path -Leaf $loc
        if (-not $folder) { $folder = $loc }

        Send-TermNotify -Title $title -Message "$short`n$folder - $env:COMPUTERNAME" -Tags $tags -Priority $prio
    } catch { }   # if anything goes wrong here, ignore it: your typing window must never break
}

# The three magic words from the top of this file.
function global:tn-test { Send-TermNotify -Wait }
function global:tn-off  { $global:__TN.Enabled = $false; Write-Host 'TermNotify muted in this window.' }
function global:tn-on   { $global:__TN.Enabled = $true;  Write-Host 'TermNotify on.' }

# Read the settings file now.
Import-TermNotifyConfig

# The "prompt" is the PS C:\...> text that shows up when the computer is
# ready for you to type again. That moment means "the last job is done!"
# So we sneak our check in right before the prompt is drawn.
#
# We keep the old prompt and still draw it, so your window looks the same.
# (Starship and oh-my-posh throw the old prompt away, so TermNotify's line
# must come AFTER them in your profile.)
$global:__TN_OrigPrompt = $function:prompt
function global:prompt {
    $tnOk = $?                 # did the last job work? remember it before anything changes it
    Invoke-TNCheck $tnOk       # maybe send a message to your phone
    if (-not $tnOk) { Write-Error 'failure' -ErrorAction Ignore }   # put the "did it work?" answer back the way it was
    if ($global:__TN_OrigPrompt) { & $global:__TN_OrigPrompt }      # draw your normal prompt
    else { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
}
