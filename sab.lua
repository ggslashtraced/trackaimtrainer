-- job_joiner.lua
-- saves jobids to jobids.json and refreshes if older than 30 minutes
-- queues sab.lua to run on teleport

local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local PLACE_ID = tostring(game.PlaceId)
local JOBS_FILE = "jobids.json"
local JOBS_URL = ("https://games.roblox.com/v1/games/%s/servers/Public?sortOrder=Asc&limit=50"):format(PLACE_ID)

-- You can either queue the remote URL below OR inline sab.lua contents
local REMOTE_SAB_URL = "https://raw.githubusercontent.com/ggslashtraced/trackaimtrainer/refs/heads/main/sab.lua"
-- If you prefer to queue an inline payload (embedded sab contents), set INLINE_PAYLOAD to true
local INLINE_PAYLOAD = false

-- If INLINE_PAYLOAD==true, set INLINE_SAB_PAYLOAD to the payload string (see note below).
-- It's often easier to use REMOTE_SAB_URL (default). If you want inline, set INLINE_PAYLOAD=true and
-- paste the contents of sab.lua into INLINE_SAB_PAYLOAD (escaped). For safety we default to remote.
local INLINE_SAB_PAYLOAD = nil

local MIN_AGE_SECONDS = 30 * 60 -- 30 minutes

-- robust request function (user-provided style)
local function requestFunc(tab)
    if syn and syn.request then
        return syn.request(tab)
    elseif http_request then
        return http_request(tab)
    elseif request then
        return request(tab)
    else
        error("No HTTP request function found")
    end
end

-- time helper
local function now()
    local ok, t = pcall(function() return os.time() end)
    if ok and type(t) == "number" then return t end
    ok, t = pcall(function() return tick() end)
    if ok and type(t) == "number" then return t end
    return 0
end

-- file helpers
local function fileExists(path)
    if type(isfile) == "function" then
        return isfile(path)
    end
    local ok = pcall(function() readfile(path) end)
    return ok
end

local function saveJobs(jobs)
    local payload = {
        jobs = jobs,
        fetched_at = now()
    }
    pcall(function() writefile(JOBS_FILE, HttpService:JSONEncode(payload)) end)
end

local function loadJobsFromFile()
    if not fileExists(JOBS_FILE) then return nil end
    local ok, raw = pcall(function() return readfile(JOBS_FILE) end)
    if not ok or not raw then return nil end
    local ok2, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 or type(decoded) ~= "table" then return nil end
    return decoded
end

-- fetch up to 50 public servers job ids
local function fetchJobsFromRoblox()
    local ok, res = pcall(function()
        return requestFunc({
            Url = JOBS_URL,
            Method = "GET",
            Headers = { ["User-Agent"] = "Roblox/WinInet" }
        })
    end)
    if not ok or not res or (res.StatusCode and res.StatusCode ~= 200) then
        warn("Failed to fetch jobs", res and res.StatusCode)
        return {}
    end

    local body = res.Body or (res and res.body) or ""
    local ok2, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok2 or type(data) ~= "table" or type(data.data) ~= "table" then
        warn("Bad jobs payload")
        return {}
    end

    local jobs = {}
    for _, v in ipairs(data.data) do
        if v and v.id then
            table.insert(jobs, tostring(v.id))
        end
    end
    return jobs
end

-- get jobs respecting file + age rules
local function getJobs()
    local fileData = loadJobsFromFile()
    if fileData and type(fileData) == "table" then
        if type(fileData.fetched_at) == "number" and type(fileData.jobs) == "table" and #fileData.jobs > 0 then
            local age = now() - fileData.fetched_at
            if age <= MIN_AGE_SECONDS then
                return fileData.jobs
            end
        end
    end

    local jobs = fetchJobsFromRoblox()
    if #jobs > 0 then
        pcall(saveJobs, jobs)
    end
    return jobs
end

-- robust queue-on-teleport helper
local function queueLoadOnTeleport()
    local payload
    if INLINE_PAYLOAD and INLINE_SAB_PAYLOAD and type(INLINE_SAB_PAYLOAD) == "string" then
        payload = INLINE_SAB_PAYLOAD
    else
        payload = ("loadstring(game:HttpGet('%s'))()"):format(REMOTE_SAB_URL)
    end

    local function tryCall(fn, arg)
        if type(fn) ~= "function" then return false end
        local ok, err = pcall(function() fn(arg) end)
        if not ok then
            warn("queue attempt failed:", err)
            return false
        end
        return true
    end

    local candidates = {
        function() return _G.queue_on_teleport end,
        function() return queue_on_teleport end,
        function() return queueteleport end,
        function() return QueueOnTeleport end,
        function() return queueOnTeleport end,
        function() return _G.QueueOnTeleport end,
        function() return (syn and syn.queue_on_teleport) end,
        function() return (syn and syn.queueOnTeleport) end,
        function() return (syn and syn.queue_on_teleport and syn.queue_on_teleport) end,
    }

    for _, getFn in ipairs(candidates) do
        local ok, fn = pcall(getFn)
        if ok and type(fn) == "function" then
            if tryCall(fn, payload) then
                return true
            end
        end
    end

    -- last-resort: copy payload to clipboard and notify
    pcall(function()
        if setclipboard then setclipboard(payload) end
        if toclipboard then toclipboard(payload) end
    end)

    local msg = "No queue_on_teleport API found. Payload copied to clipboard if supported. Paste it into your exploit's queue box."
    if type(notify) == "function" then pcall(notify, "QueueOnTeleport missing", msg) else warn(msg) end
    return false
end

-- remove first jobid and save
local function popFirstJobAndSave(jobs)
    if type(jobs) ~= "table" or #jobs == 0 then return {} end
    table.remove(jobs, 1)
    pcall(saveJobs, jobs)
    return jobs
end

-- main loop
spawn(function()
    local jobs = getJobs() or {}
    if #jobs == 0 then
        warn("No jobs found")
        return
    end

    while true do
        local fileData = loadJobsFromFile()
        if fileData and type(fileData.jobs) == "table" and #fileData.jobs > 0 then
            jobs = fileData.jobs
        end

        local currentJob = jobs[1]
        if not currentJob then
            jobs = fetchJobsFromRoblox()
            if #jobs == 0 then
                warn("No jobs available, waiting 30s then retry")
                wait(30)
                continue
            else
                pcall(saveJobs, jobs)
                currentJob = jobs[1]
            end
        end

        local okQueue = queueLoadOnTeleport()
        if not okQueue then
            if type(notify) == "function" then
                pcall(notify, "Incompatible Exploit", "Your exploit does not support queue_on_teleport / queueteleport")
            else
                warn("Incompatible Exploit: missing queue_on_teleport / queueteleport")
            end
            return
        end

        local success, err = pcall(function()
            TeleportService:TeleportToPlaceInstance(tonumber(PLACE_ID), currentJob, Players.LocalPlayer)
        end)
        if not success then
            warn("Teleport failed:", err)
            jobs = popFirstJobAndSave(jobs)
            wait(3)
        else
            jobs = popFirstJobAndSave(jobs)
            wait(2)
        end

        wait(1)
    end
end)
