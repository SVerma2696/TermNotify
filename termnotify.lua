-- TermNotify for Command Prompt (the black cmd.exe window).
--
-- What is this?
--   When a job you typed takes a while, this sends a "ding!" message
--   to your phone when it's finished. Like a kitchen timer for the
--   computer!
--
-- It needs two helpers:
--   * Clink: a free add-on that tells us when you start and finish a job.
--     https://chrisant996.github.io/clink/
--   * curl.exe: a little program already inside Windows 10/11 that
--     knows how to send things over the internet.

-- Our toy box of settings. These are the "starting" values.
-- The settings file can change them.
local conf = {
    server = "https://ntfy.sh",   -- the post office that carries messages to your phone
    topic = "",                   -- your secret mailbox name
    threshold = 3,                -- how many seconds a job must take before we tell you
    ignore = {},                  -- programs we never tell you about
    ignore_bare = {},             -- programs we skip only when typed all by themselves
    token = "",                   -- a secret key, only for special private post offices
    retry_minutes = 30,           -- minutes to keep trying if the internet is gone
    enabled = true,               -- true = talking, false = being quiet
}

-- Turn "ssh vim less" into a list we can check quickly,
-- like sorting toys into labeled boxes.
local function word_set(s)
    local set = {}
    for w in s:gmatch("%S+") do set[w:lower()] = true end
    return set
end

-- Read the settings file, one line at a time.
-- Each line looks like NAME=value.
local function load_conf()
    local path = (os.getenv("USERPROFILE") or "") .. "\\.termnotify.conf"
    local f = io.open(path, "r")
    if not f then return end   -- no settings file? use the starting values
    for line in f:lines() do
        local k, v = line:match("^%s*(TN_[%u_]+)%s*=%s*(.-)%s*$")
        -- Look at the name, and put the value in the right spot.
        if k == "TN_SERVER" and v ~= "" then conf.server = (v:gsub("/+$", ""))
        elseif k == "TN_TOPIC" then conf.topic = v
        elseif k == "TN_THRESHOLD" and tonumber(v) then conf.threshold = tonumber(v)
        elseif k == "TN_IGNORE" then conf.ignore = word_set(v)
        elseif k == "TN_IGNORE_BARE" then conf.ignore_bare = word_set(v)
        elseif k == "TN_TOKEN" then conf.token = v
        elseif k == "TN_RETRY_MINUTES" and tonumber(v) then conf.retry_minutes = tonumber(v)
        elseif k == "TN_ENABLED" then
            -- Any of these words means "be quiet".
            local off = { ["0"] = true, ["false"] = true, ["no"] = true, ["off"] = true }
            conf.enabled = not off[v:lower()]
        end
    end
    f:close()
end

-- Some letters (like " and \) confuse the post office, so we put a
-- little \ in front of them. It's like putting tricky words in quotes.
local function json_escape(s)
    local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return (s:gsub('[%c"\\]', function(c)
        return map[c] or string.format("\\u%04x", c:byte())
    end))
end

-- Turn a number of seconds into easy words,
-- like "2m 14s" (2 minutes, 14 seconds) or "1h 05m".
local function format_duration(secs)
    local floor = math.floor   -- no // operator: Clink may run Lua 5.2
    if secs >= 3600 then
        return string.format("%dh %02dm", floor(secs / 3600), floor((secs % 3600) / 60))   -- an hour or more
    elseif secs >= 60 then
        return string.format("%dm %02ds", floor(secs / 60), secs % 60)                     -- a minute or more
    end
    return string.format("%ds", secs)                                                      -- just seconds
end

-- Find the name of the program in what you typed.
-- "python train.py"  ->  "python", and it's NOT by itself.
-- "python"           ->  "python", and it IS by itself.
local function program_name(line)
    local tok, rest = line:match('^%s*"([^"]+)"(.*)$')               -- first word in "quotes"?
    if not tok then tok, rest = line:match("^%s*(%S+)(.*)$") end    -- or a plain first word
    if not tok then return "", true end
    local name = tok:match("([^\\/]+)$") or tok                      -- C:\tools\git.exe -> git.exe
    name = name:lower():gsub("%.exe$", ""):gsub("%.cmd$", ""):gsub("%.bat$", ""):gsub("%.com$", "")   -- drop the ending
    return name, (rest:match("^%s*$") ~= nil)
end

-- Things we need to give each message its own name tag.
local pid = (os.getpid and os.getpid()) or math.random(100000, 999999)   -- this window's number
local tmpdir = os.getenv("TEMP") or os.getenv("TMP") or "."               -- a folder for scrap paper
local counter = 0                                                         -- counts our messages: 1, 2, 3...
local retry_flags   -- worked out on first send

-- Newer curl (7.71 or later, which comes with Windows 11) can keep
-- trying when the internet is gone. Older curl can't. So we ask curl
-- how old it is, and only use the "keep trying" words if it knows them.
local function get_retry_flags()
    if retry_flags then return retry_flags end   -- already asked? use the answer
    retry_flags = ""
    local p = io.popen("curl.exe --version 2>nul")
    if p then
        local out = p:read("*l") or ""
        p:close()
        local maj, min = out:match("^curl (%d+)%.(%d+)")
        maj, min = tonumber(maj), tonumber(min)
        if maj and (maj > 7 or (maj == 7 and min >= 71)) and conf.retry_minutes > 0 then
            retry_flags = string.format(" --retry 1000 --retry-delay 20 --retry-all-errors --retry-max-time %d",
                                        conf.retry_minutes * 60)
        end
    end
    return retry_flags
end

-- Clean up! Throw away old scrap-paper files from messages that were
-- sent (or given up on) a long time ago.
local function cleanup_old_files()
    if not os.globfiles then return end
    local ok, files = pcall(os.globfiles, tmpdir .. "\\termnotify_*.json")
    if not ok or type(files) ~= "table" then return end
    local cutoff = os.time() - (conf.retry_minutes + 5) * 60   -- anything older than this is trash
    for _, name in ipairs(files) do
        local stamp = tonumber(name:match("termnotify_(%d+)_"))   -- the time is written in the file's name
        if stamp and stamp < cutoff then
            local full = name:find("[\\/]") and name or (tmpdir .. "\\" .. name)
            os.remove(full)
        end
    end
end

-- Send one message to your phone.
local function send(title, message, tags, priority)
    if conf.topic == "" then return end   -- no mailbox name? can't send
    -- Pack everything into a neat bundle (JSON) the post office understands.
    local json = string.format(
        '{"topic":"%s","title":"%s","message":"%s","tags":["%s"],"priority":%d}',
        json_escape(conf.topic), json_escape(title), json_escape(message), json_escape(tags), priority)

    -- Write the bundle on its own piece of scrap paper (a file).
    -- One file per message, so a message that's still trying is never scribbled over.
    counter = counter + 1
    local tmp = string.format("%s\\termnotify_%d_%d_%d.json", tmpdir, os.time(), pid, counter)
    local f = io.open(tmp, "wb")
    if not f then return end
    f:write(json)
    f:close()

    -- Add the secret key, if you have one.
    local auth = ""
    if conf.token ~= "" then auth = ' -H "Authorization: Bearer ' .. conf.token .. '"' end
    -- "start /b" runs curl in the background so the prompt comes back instantly.
    -- (curl goes off to mail the letter, and you can keep typing.)
    os.execute('start "" /b curl.exe -s -m 15 -o nul' .. get_retry_flags() .. auth ..
               ' --data-binary "@' .. tmp .. '" "' .. conf.server .. '/"')
    cleanup_old_files()
end

-- Exposed for testing.
termnotify = { conf = conf, load_conf = load_conf, json_escape = json_escape,
               format_duration = format_duration, program_name = program_name, send = send }

-- When did the job start, and what did you type?
local start_time, last_line

-- Clink calls this when you press Enter. Start the stopwatch!
local function on_end_edit(line)
    start_time = os.time()
    last_line = line
end

-- Clink calls this when the window is ready for you to type again.
-- That means the job is done! Stop the stopwatch and decide what to say.
local function on_begin_edit()
    if not start_time then return end   -- no stopwatch running? nothing to do
    local elapsed = os.time() - start_time
    local line = last_line or ""
    start_time, last_line = nil, nil    -- reset the stopwatch for next time

    if not conf.enabled or conf.topic == "" then return end              -- quiet mode, or no mailbox
    if elapsed < conf.threshold or line:match("^%s*$") then return end   -- too quick, or you typed nothing

    -- Is this a program we promised to skip?
    local name, bare = program_name(line)
    if conf.ignore[name] or (bare and conf.ignore_bare[name]) then return end

    -- Ask cmd how the job went. 0 means "it worked!"
    -- Any other number means something went wrong.
    local code = 0
    if os.geterrorlevel then
        local ok, v = pcall(os.geterrorlevel)
        if ok and v then code = v end
    end

    -- Pick the words and the picture for the message.
    local time = format_duration(elapsed)
    local title, tags, prio
    if code == 0 then
        title, tags, prio = "Done in " .. time, "white_check_mark", 3                -- hooray!
    else
        title, tags, prio = "Failed (exit " .. code .. ") after " .. time, "x", 4   -- uh-oh, a bit louder
    end

    -- Tidy up what you typed, and cut it short (200 letters max) so it fits.
    local cmd = line:gsub("^%s+", ""):gsub("%s+$", "")
    if #cmd > 200 then cmd = cmd:sub(1, 197) .. "..." end
    -- Which folder were you in? We only show the last folder's name.
    local cwd = (os.getcwd and os.getcwd()) or ""
    local folder = cwd:match("([^\\/]+)[\\/]?$") or cwd

    send(title, cmd .. "\n" .. folder .. " - " .. (os.getenv("COMPUTERNAME") or "PC"), tags, prio)
end

-- Read the settings file now.
load_conf()

-- Ask Clink to call our two helpers: one when you press Enter,
-- and one when the window is ready for typing again.
if clink and clink.onendedit and clink.onbeginedit then
    clink.onendedit(on_end_edit)
    clink.onbeginedit(on_begin_edit)
end
