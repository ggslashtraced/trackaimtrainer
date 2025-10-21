-- autobot job-joiner + queue-on-teleport loader
-- saves jobids to jobids.json and refreshes if older than 30 minutes

local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local PLACE_ID = tostring(game.PlaceId)
local JOBS_FILE = "jobids.json"
local JOBS_URL = ("https://games.roblox.com/v1/games/%s/servers/Public?sortOrder=Asc&limit=50"):format(PLACE_ID)
local SCRIPT_URL = "https://raw.githubusercontent.com/ggslashtraced/trackaimtrainer/refs/heads/main/sab.lua"
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

-- safe now() to store timestamp
local function now()
    local ok, t = pcall(function() return os.time() end)
    if ok and type(t) == "number" then return t end
    ok, t = pcall(function() return tick() end)
    if ok and type(t) == "number" then return t end
    return 0
end

-- file helpers (exploit envs usually provide isfile/readfile/writefile)
local function fileExists(path)
    if type(isfile) == "function" then
        return isfile(path)
    end
    -- fallback: pcall readfile
    local ok = pcall(function() readfile(path) end)
    return ok
end

local function saveJobs(jobs)
    local payload = {
        jobs = jobs,
        fetched_at = now()
    }
    writefile(JOBS_FILE, HttpService:JSONEncode(payload))
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
    if not ok or not res or res.StatusCode ~= 200 then
        warn("Failed to fetch jobs", res and res.StatusCode)
        return {}
    end

    local ok2, data = pcall(function() return HttpService:JSONDecode(res.Body) end)
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
        -- if file exists and has jobs and timestamp
        if type(fileData.fetched_at) == "number" and type(fileData.jobs) == "table" and #fileData.jobs > 0 then
            local age = now() - fileData.fetched_at
            if age <= MIN_AGE_SECONDS then
                -- use existing file (do not rewrite)
                return fileData.jobs
            end
            -- else: file older than MIN_AGE_SECONDS -> fallthrough to fetch new
        else
            -- malformed file -> we will fetch new and overwrite
        end
    end

    -- fetch new and save
    local jobs = fetchJobsFromRoblox()
    if #jobs > 0 then
        pcall(saveJobs, jobs)
    end
    return jobs
end

-- queue the teleport-load payload so the target script runs after teleport
local function queueLoadOnTeleport()
    local payload = ("loadstring(game:HttpGet('%s'))()"):format(SCRIPT_URL)
    -- try multiple common queue functions
    if type(queue_on_teleport) == "function" then
        pcall(queue_on_teleport, payload)
        return true
    elseif type(queueteleport) == "function" then
        pcall(queueteleport, payload)
        return true
    elseif syn and type(syn.queue_on_teleport) == "function" then
        pcall(syn.queue_on_teleport, payload)
        return true
    else
        -- no supported queue found
        return false
    end
end

-- remove first jobid from saved file (and rewrite)
local function popFirstJobAndSave(jobs)
    if type(jobs) ~= "table" or #jobs == 0 then return {} end
    table.remove(jobs, 1)
    pcall(saveJobs, jobs)
    return jobs
end

-- main flow: respects file existence, queue loader, teleport to first jobid, then remove it from file
spawn(function()
    local jobs = getJobs() or {}
    if #jobs == 0 then
        warn("No jobs found")
        return
    end

    while true do
        -- reload jobs from file at loop start in case something else updated it
        local fileData = loadJobsFromFile()
        if fileData and type(fileData.jobs) == "table" and #fileData.jobs > 0 then
            jobs = fileData.jobs
        end

        local currentJob = jobs[1]
        if not currentJob then
            -- try refetch
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

        -- queue the sab.lua loader so after teleport it re-executes the tracking script
        local okQueue = queueLoadOnTeleport()
        if not okQueue then
            -- fallback notify if there's a function named notify (user used it earlier), else warn
            if type(notify) == "function" then
                pcall(notify, "Incompatible Exploit", "Your exploit does not support queue_on_teleport / queueteleport")
            else
                warn("Incompatible Exploit: missing queue_on_teleport / queueteleport")
            end
            return
        end

        -- teleport to the job instance
        local success, err = pcall(function()
            TeleportService:TeleportToPlaceInstance(tonumber(PLACE_ID), currentJob, Players.LocalPlayer)
        end)
        if not success then
            warn("Teleport failed:", err)
            -- remove the bad job and continue
            jobs = popFirstJobAndSave(jobs)
            wait(3)
        else
            -- if teleport succeeds, the local script will be terminated and the queued payload will run in the new instance.
            -- still attempt to clean the file (best-effort) before teleporting
            jobs = popFirstJobAndSave(jobs)
            -- give a short pause; normally script stops here due to teleport
            wait(2)
        end

        -- small throttle before next cycle just in case
        wait(1)
    end
end)
