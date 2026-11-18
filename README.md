A Windows terminal add-on I built to learn shell prompt hooks,
background networking that never blocks the prompt, and push
notifications -- one settings file shared by PowerShell and Command
Prompt, with your phone buzzing when a long command finishes.

# TermNotify📱🔔
Get a push notification on your phone (**iPhone or Android**) when a
terminal command that ran for **3 seconds or more** finishes. Start a
long build, upload, or training run, walk away, and your phone tells
you when it's done and whether it worked. It hooks into **PowerShell**
(5.1 and 7, including the **VS Code** terminal and Windows Terminal)
and **Command Prompt** (through the free **Clink** add-on), and sends
through the free **ntfy** service, with no account needed.

---

## 📥 Get It (about 2 minutes)
1. Download or clone this repo and double-click **`install.cmd`**.
   * It picks a random private topic name for your notifications.
     Press Enter to accept it.
   * If Clink isn't installed, answer **Y** so Command Prompt is
     covered too.
2. On your phone, open the **ntfy** app, tap **+**, and subscribe to
   the topic the installer printed. Keep the default server.
3. Answer **Y** to "Send a test notification". Your phone should buzz.
4. Close and reopen your terminals, including VS Code.

Try it: run `Start-Sleep 5` in PowerShell, or `timeout /t 5` in
Command Prompt, then wait for your phone.

| Your phone | Get the app | First-time setup |
|---|---|---|
| iPhone | **ntfy** on the App Store | Allow notifications when the app asks, or later in Settings → Notifications → ntfy. |
| Android | **ntfy** on Google Play | Allow notifications. If they arrive late, set the ntfy app's battery usage to **Unrestricted**. |

---

## 📂 Project Structure
```
TermNotify/
├── .gitattributes        # Keeps CRLF line endings on .cmd/.ps1 so Windows can run them
├── .gitignore            # Ignores your personal .termnotify.conf (it holds your private topic)
├── install.cmd           # Double-click installer (runs install.ps1)
├── install.ps1           # Copies scripts, creates settings, hooks your shells, sends a test
├── README.md             # Project documentation
├── termnotify.lua        # Command Prompt hook, loaded by Clink
├── termnotify.ps1        # PowerShell hook (PowerShell 5.1 and 7, VS Code, Windows Terminal)
├── uninstall.cmd         # Double-click uninstaller (runs uninstall.ps1)
└── uninstall.ps1         # Removes everything the installer added
```

---

## ⚙️ Features
* **Notifies you about long commands.** Anything that runs 3 seconds
  or more (you can change the limit) sends a notification when it ends.
* **Tells you how it went:**
  * ✅ **Done in 2m 14s**: finished successfully
  * ❌ **Failed after 1m 05s**: errored, sent at higher priority
    (Command Prompt also shows the exit code)
  * 🛑 **Stopped after 3m 40s**: you pressed Ctrl+C (PowerShell)
* **Says which command and where.** The message shows the command, the
  folder it ran in, and the PC's name.
* **Works in all your terminals:** the VS Code integrated terminal,
  Windows PowerShell 5.1, PowerShell 7, Windows Terminal, and Command
  Prompt (through the free Clink add-on).
* **Works on iPhone and Android.** It uses the free ntfy app, with no
  account needed.
* **Your phone doesn't need WiFi or Bluetooth.** Notifications arrive
  over cellular data or any WiFi network, from anywhere.
* **Recovers from dropped connections.** If the PC is offline when a
  command finishes, it keeps retrying in the background for up to 30
  minutes.
* **Never slows your terminal.** Sending happens in the background,
  and errors never break your prompt.
* **Skips interactive programs.** `ssh`, `vim`, `less` and similar
  never notify. Plain `python` or `node` (a REPL) doesn't notify, but
  `python train.py` does.
* **Can be muted** in one window or paused everywhere.

---

## 🚀 How to Use It
Once installed there's nothing to run. Work in your terminal as usual,
and any command that takes 3 seconds or longer notifies your phone when
it ends.

PowerShell commands (including the VS Code terminal):

| Command   | What it does |
|-----------|--------------|
| `tn-test` | Sends a test notification and shows any error |
| `tn-off`  | Mutes notifications in this window only |
| `tn-on`   | Unmutes this window |

To pause everywhere, including Command Prompt, set `TN_ENABLED=off` in
the settings file.

### Settings
Edit `%USERPROFILE%\.termnotify.conf` (for example
`notepad $HOME\.termnotify.conf`), then open a new terminal.

| Setting            | Default | Meaning |
|--------------------|---------|---------|
| `TN_THRESHOLD`     | `3`     | Minimum run time, in seconds, before a command notifies |
| `TN_IGNORE`        | `ssh vim nano less ...` | Programs that never notify |
| `TN_IGNORE_BARE`   | `python node pwsh ...`  | Ignored only when run with no arguments |
| `TN_RETRY_MINUTES` | `30`    | How long to keep retrying while the PC is offline (`0` = try once) |
| `TN_TOPIC`         | random  | Your ntfy topic. Anyone who knows it can read it, so keep it secret |
| `TN_SERVER`        | `https://ntfy.sh` | Change this if you self-host ntfy |
| `TN_TOKEN`         | empty   | Access token for a protected ntfy server |
| `TN_ENABLED`       | `on`    | `off` pauses everything |

Your settings file lives in your user folder, not in this repo, so
your topic is never committed.

---

## 🖥️ Platform & Connection Notes
This project is Windows-only (Windows 10 or 11), with these
differences specifically accounted for in the code:

* **How your phone and PC connect:** the PC never talks to the phone
  directly, so there's no Bluetooth and no need to be on the same
  network.
  ```
  PC ──internet──► ntfy.sh ──internet──► ntfy app on your phone
  ```
  * **Phone:** any internet connection, so cellular data is fine.
  * **PC:** needs some internet connection when the command finishes
    -- WiFi, Ethernet (including a USB-C Ethernet adapter), or **USB
    tethering**: plug your phone into the PC with a cable and share its
    cellular data, using no WiFi or Bluetooth.
    * Android: Settings → Network → Hotspot & tethering → USB tethering
    * iPhone: Settings → Personal Hotspot, then plug in. Windows needs
      Apple's iTunes / Apple Devices app for the driver.
  * If the PC has no connection at all, the notification waits and is
    sent as soon as it's back online, for up to 30 minutes
    (`TN_RETRY_MINUTES`).
* **Windows 10 vs. 11:** Command Prompt sends with the `curl.exe`
  built into Windows. Retrying while offline needs curl 7.71 or newer
  (shipped with Windows 11); on older curl, Command Prompt tries once.
  PowerShell's retry works on both.
* **PowerShell 5.1 vs. 7:** the background sender is compiled at load
  time with `Add-Type`, against the right .NET assemblies for whichever
  edition is running. If that ever fails, it falls back to a single
  send attempt instead of breaking.
* **OneDrive-redirected Documents:** the installer finds your profile
  folders with `[Environment]::GetFolderPath('MyDocuments')`, so it
  still lands in the right place when OneDrive has moved Documents.
* **Execution policy:** if PowerShell was blocking profile scripts,
  the installer sets your user's policy to `RemoteSigned` (Microsoft's
  recommended setting).

---

## 🛠️ Troubleshooting
* **No notification:** run `tn-test`. It tells you whether the PC
  reached ntfy. Then check that the topic in the phone app exactly
  matches `TN_TOPIC`.
* **iPhone:** make sure notifications are allowed for ntfy in
  Settings → Notifications.
* **Android:** if notifications arrive late, set the ntfy app's
  battery usage to Unrestricted.
* **Starship / oh-my-posh:** these replace the PowerShell prompt. The
  `# >>> TermNotify >>>` block must come **after** their init line in
  `Documents\PowerShell\profile.ps1` and
  `Documents\WindowsPowerShell\profile.ps1`.
* **Command Prompt "Failed" by mistake:** cmd's `%ERRORLEVEL%` isn't
  reset by some built-in commands, so an earlier failure can
  occasionally carry over.

---

## 🔒 Privacy
* **What gets sent:** only the command text (cut to 200 characters),
  the folder name, and the PC name, and only to your topic.
* **Your topic is the password.** Anyone who knows the topic name can
  read it, so the installer generates a long random one with a
  cryptographic random-number generator. Keep it secret.
* **Never committed:** `.termnotify.conf` lives in your user folder and
  is also listed in `.gitignore`.
* **Full control:** self-host ntfy and point `TN_SERVER` at it, with
  `TN_TOKEN` if your server requires an access token.

---

## 🔌 System Integrations (Data Flow)
### Detecting a finished command
```
PowerShell:      prompt function wrapper -> Get-History (start/end time, status) -> Invoke-TNCheck
Command Prompt:  clink.onendedit (Enter pressed) ... clink.onbeginedit (prompt back) -> elapsed time + %ERRORLEVEL%
```
**Note:** PowerShell wraps whatever prompt was already defined
(default, posh-git, etc.) and hands `$?` back unchanged, so other
tools that check the last command's success still see the right
answer. Both hooks then apply the same checks: over the threshold,
not muted, and not an ignored program.

### Sending the notification
```
PowerShell:      Send-TermNotify -> TermNotifySender.Send (C#, background Task) -> POST JSON to TN_SERVER
Command Prompt:  send() -> %TEMP%\termnotify_*.json -> start /b curl.exe --data-binary -> POST JSON to TN_SERVER
```
Both send the same JSON body (`topic`, `title`, `message`, `tags`,
`priority`). The PowerShell sender retries with exponential backoff
(5s, 10s, 20s ... up to 60s apart) only on network errors, `5xx`, or
`429`, and gives up straight away on other errors. Command Prompt
writes one payload file per notification, so a send that's still
retrying is never overwritten, and old files are cleaned up after the
retry window ends.

### Installer ⇄ Your shells
```
install.ps1  -> ~\.termnotify\ (scripts)  +  ~\.termnotify.conf (settings)
             -> # >>> TermNotify >>> block in both PowerShell profile.ps1 files
             -> %LOCALAPPDATA%\clink\termnotify.lua
uninstall.ps1 -> removes exactly those, and asks before deleting your settings
```

---

## 📘 Concepts Demonstrated
* **Shell prompt hooking** -- detecting "a command just finished" by
  wrapping PowerShell's `prompt` function and using Clink's
  `onendedit` / `onbeginedit` events, with no wrapper command to type.
* **Non-blocking background networking** -- a small C# sender compiled
  on the fly with `Add-Type`, and `start /b curl.exe` on the Command
  Prompt side, so the prompt returns instantly.
* **Retry with exponential backoff** -- retrying only the errors worth
  retrying, with a time limit, so a laptop that's reconnecting still
  gets its notification.
* **Fail-safe design** -- every notification path is wrapped so a
  network or config problem can never break your prompt.
* **One config, two languages** -- the same `KEY=value` settings file
  is parsed by both the PowerShell and Lua hooks.
* **Idempotent install/uninstall** -- marker-delimited profile blocks
  (`# >>> TermNotify >>>`) that are never added twice and are removed
  cleanly.
* **Push notifications over a pub/sub service** -- ntfy topics,
  priorities, and emoji tags, with no account or app server of your own.

---

## 🔧 Requirements
* Windows 10 or 11 (Windows 11 recommended; curl and the retry
  features are built in)
* The **ntfy** app on your phone: App Store (iPhone) or Google Play
  (Android)
* For Command Prompt only: **Clink**. The installer can install it
  with winget.

---

## 🗑️ Uninstall
Double-click **`uninstall.cmd`**. It removes the profile lines, the
Clink script and `%USERPROFILE%\.termnotify`, and asks before deleting
your settings. Clink itself stays installed; remove it in
Settings → Apps if you no longer want it.

---

## 🎓 Credits & Attributions
* **[ntfy](https://ntfy.sh/)** -- the free, open-source push
  notification service and phone app that delivers every notification.
* **[Clink](https://chrisant996.github.io/clink/)** by Chris Antos --
  the Command Prompt add-on that tells TermNotify when a command starts
  and finishes.
