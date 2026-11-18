-- TermNotify for Command Prompt (cmd.exe), loaded by Clink.
-- Sends a push notification to your phone (via ntfy) when a command
-- runs longer than TN_THRESHOLD seconds. Needs curl.exe (built into
-- Windows 10/11) and Clink (https://chrisant996.github.io/clink/).

local conf = {
    server = "https://ntfy.sh",
    topic = "",
    threshold = 60,
    ignore = {},
    ignore_bare = {},
    token = "",
    retry_minutes = 30,
    enabled = true,
}

local function word_set(s)
    local set = {}
    for w in s:gmatch("%S+") do set[w:lower()] = true end
    return set
end

local function load_conf()
    local path = (os.getenv("USERPROFILE") or "") .. "\\.termnotify.conf"
    local f = io.open(path, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*(TN_[%u_]+)%s*=%s*(.-)%s*$")
        if k == "TN_SERVER" and v ~= "" then conf.server = (v:gsub("/+$", ""))
        elseif k == "TN_TOPIC" then conf.topic = v
        elseif k == "TN_THRESHOLD" and tonumber(v) then conf.threshold = tonumber(v)
        elseif k == "TN_IGNORE" then conf.ignore = word_set(v)
        elseif k == "TN_IGNORE_BARE" then conf.ignore_bare = word_set(v)
        elseif k == "TN_TOKEN" then conf.token = v
        elseif k == "TN_RETRY_MINUTES" and tonumber(v) then conf.retry_minutes = tonumber(v)
        elseif k == "TN_ENABLED" then
            local off = { ["0"] = true, ["false"] = true, ["no"] = true, ["off"] = true }
            conf.enabled = not off[v:lower()]
        end
    end
    f:close()
end

local function json_escape(s)
    local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return (s:gsub('[%c"\\]', function(c)
        return map[c] or string.format("\\u%04x", c:byte())
    end))
end

local function format_duration(secs)
    local floor = math.floor   -- no // operator: Clink may run Lua 5.2
    if secs >= 3600 then
        return string.format("%dh %02dm", floor(secs / 3600), floor((secs % 3600) / 60))
    elseif secs >= 60 then
        return string.format("%dm %02ds", floor(secs / 60), secs % 60)
    end
    return string.format("%ds", secs)
end

local function program_name(line)
    local tok, rest = line:match('^%s*"([^"]+)"(.*)$')
    if not tok then tok, rest = line:match("^%s*(%S+)(.*)$") end
    if not tok then return "", true end
    local name = tok:match("([^\\/]+)$") or tok
    name = name:lower():gsub("%.exe$", ""):gsub("%.cmd$", ""):gsub("%.bat$", ""):gsub("%.com$", "")
    return name, (rest:match("^%s*$") ~= nil)
end

local pid = (os.getpid and os.getpid()) or math.random(100000, 999999)
local tmpdir = os.getenv("TEMP") or os.getenv("TMP") or "."
local counter = 0
local retry_flags   -- worked out on first send

-- curl 7.71+ (Windows 11) can retry when the PC is offline; older curl can't.
local function get_retry_flags()
    if retry_flags then return retry_flags end
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

-- Delete payload files from sends that finished (or gave up) long ago.
local function cleanup_old_files()
    if not os.globfiles then return end
    local ok, files = pcall(os.globfiles, tmpdir .. "\\termnotify_*.json")
    if not ok or type(files) ~= "table" then return end
    local cutoff = os.time() - (conf.retry_minutes + 5) * 60
    for _, name in ipairs(files) do
        local stamp = tonumber(name:match("termnotify_(%d+)_"))
        if stamp and stamp < cutoff then
            local full = name:find("[\\/]") and name or (tmpdir .. "\\" .. name)
            os.remove(full)
        end
    end
end

local function send(title, message, tags, priority)
    if conf.topic == "" then return end
    local json = string.format(
        '{"topic":"%s","title":"%s","message":"%s","tags":["%s"],"priority":%d}',
        json_escape(conf.topic), json_escape(title), json_escape(message), json_escape(tags), priority)

    -- One file per notification, so a send that is still retrying is never overwritten.
    counter = counter + 1
    local tmp = string.format("%s\\termnotify_%d_%d_%d.json", tmpdir, os.time(), pid, counter)
    local f = io.open(tmp, "wb")
    if not f then return end
    f:write(json)
    f:close()

    local auth = ""
    if conf.token ~= "" then auth = ' -H "Authorization: Bearer ' .. conf.token .. '"' end
    -- "start /b" runs curl in the background so the prompt comes back instantly.
    os.execute('start "" /b curl.exe -s -m 15 -o nul' .. get_retry_flags() .. auth ..
               ' --data-binary "@' .. tmp .. '" "' .. conf.server .. '/"')
    cleanup_old_files()
end

-- Exposed for testing.
termnotify = { conf = conf, load_conf = load_conf, json_escape = json_escape,
               format_duration = format_duration, program_name = program_name, send = send }

local start_time, last_line

local function on_end_edit(line)
    start_time = os.time()
    last_line = line
end

local function on_begin_edit()
    if not start_time then return end
    local elapsed = os.time() - start_time
    local line = last_line or ""
    start_time, last_line = nil, nil

    if not conf.enabled or conf.topic == "" then return end
    if elapsed < conf.threshold or line:match("^%s*$") then return end

    local name, bare = program_name(line)
    if conf.ignore[name] or (bare and conf.ignore_bare[name]) then return end

    local code = 0
    if os.geterrorlevel then
        local ok, v = pcall(os.geterrorlevel)
        if ok and v then code = v end
    end

    local time = format_duration(elapsed)
    local title, tags, prio
    if code == 0 then
        title, tags, prio = "Done in " .. time, "white_check_mark", 3
    else
        title, tags, prio = "Failed (exit " .. code .. ") after " .. time, "x", 4
    end

    local cmd = line:gsub("^%s+", ""):gsub("%s+$", "")
    if #cmd > 200 then cmd = cmd:sub(1, 197) .. "..." end
    local cwd = (os.getcwd and os.getcwd()) or ""
    local folder = cwd:match("([^\\/]+)[\\/]?$") or cwd

    send(title, cmd .. "\n" .. folder .. " - " .. (os.getenv("COMPUTERNAME") or "PC"), tags, prio)
end

load_conf()

if clink and clink.onendedit and clink.onbeginedit then
    clink.onendedit(on_end_edit)
    clink.onbeginedit(on_begin_edit)
end
