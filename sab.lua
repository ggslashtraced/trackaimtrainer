-- sab.lua
-- runs inside each server: scans Plots/AnimalPodiums, finds animals > $1M/s, sends webhook

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RUN_SERVICE = game:GetService("RunService")

local WEBHOOK = "https://discordapp.com/api/webhooks/1430218527465406474/eqqZHo0Wfdk2-DE47skAmXqQpnRL53JkC_LhC9NvLQGZs7-v-KV544NvgX-ZFCrInbIr"
local PLACE_ID = tostring(game.PlaceId)
local JOB_ID = tostring(game.JobId or "unknown")
local MIN_GEN_THRESHOLD = 1e6 -- 1,000,000 per second

-- robust HTTP request
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

-- parse "$8.7K/s" / "$1.2M/s" -> number
local function parseGeneration(genText)
    if not genText or type(genText) ~= "string" then return nil end
    -- match like $8.7K/s or $870/s or $1.2M/s
    local num, unit = genText:match("%$(%d+%.?%d*)([KM]?)")
    if not num then return nil end
    local n = tonumber(num)
    if not n then return nil end
    if unit == "K" then n = n * 1e3
    elseif unit == "M" then n = n * 1e6 end
    return n
end

-- scan plots and return animals above threshold
local function scanAnimals()
    local found = {}
    local plotsRoot = Workspace:FindFirstChild("Plots") or Workspace -- fallback to Workspace if path differs
    for _, plot in pairs((plotsRoot:GetChildren())) do
        if plot:IsA("Model") or type(plot) == "Instance" then
            local podiums = plot:FindFirstChild("AnimalPodiums")
            if podiums and podiums:GetChildren() then
                for _, podium in ipairs(podiums:GetChildren()) do
                    local base = podium:FindFirstChild("Base")
                    local spawn = base and base:FindFirstChild("Spawn")
                    local attachment = spawn and spawn:FindFirstChild("Attachment")
                    local overhead = attachment and attachment:FindFirstChild("AnimalOverhead")
                    if overhead then
                        local display = overhead:FindFirstChild("DisplayName")
                        local gen = overhead:FindFirstChild("Generation")
                        local rarity = overhead:FindFirstChild("Rarity")
                        local price = overhead:FindFirstChild("Price")
                        local mutation = overhead:FindFirstChild("Mutation")

                        local genNum = gen and parseGeneration(gen.Text)
                        if genNum and genNum > MIN_GEN_THRESHOLD then
                            table.insert(found, {
                                Name = (display and display.Text) or "Unknown",
                                Rarity = (rarity and rarity.Text) or "Unknown",
                                Mutation = (mutation and mutation.Text) or "",
                                Generation = (gen and gen.Text) or "Unknown",
                                GenerationValue = genNum,
                                Price = (price and price.Text) or "Unknown",
                                Plot = plot.Name or "Unknown",
                                Podium = podium.Name or "Unknown"
                            })
                        end
                    end
                end
            end
        end
    end
    return found
end

-- build roblox join link
local function makeJoinLink(jobid)
    return ("roblox://placeid=%s&gameinstance=%s"):format(PLACE_ID, tostring(jobid))
end

-- format animals for Discord message body (plain content)
local function formatAnimalsForDiscord(animals)
    if not animals or #animals == 0 then return "None" end
    local s = ""
    for i, a in ipairs(animals) do
        local mutPart = a.Mutation ~= "" and (" | "..a.Mutation) or ""
        s = s .. string.format("**%s**%s — %s — Price: %s\n", a.Name, mutPart, a.Generation, a.Price)
    end
    return s
end

-- robust send
local function sendToDiscord(jobid, animals)
    local playercount = #Players:GetPlayers()
    local joinLink = makeJoinLink(jobid)
    local content = string.format(
        "**JobID:** %s\n**Players:** %d\n**Join:** %s\n\n**Animals > $1M/s:**\n%s",
        tostring(jobid),
        playercount,
        joinLink,
        formatAnimalsForDiscord(animals)
    )

    local body = HttpService:JSONEncode({content = content})
    local ok, res = pcall(function()
        return requestFunc({
            Url = WEBHOOK,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = body
        })
    end)
    if not ok or not res then
        warn("Webhook post failed", res and (res.StatusCode or res.status) or "no response")
        return false
    end
    if (res.StatusCode and res.StatusCode >= 200 and res.StatusCode < 300) or (res.status and res.status >= 200 and res.status < 300) then
        return true
    else
        warn("Webhook responded:", res.StatusCode or res.status, res.Body or res.body)
        return false
    end
end

-- main runner: scan, send (with retries), optional cooldown
spawn(function()
    -- tiny delay so game can load
    local maxWait = 8
    for i=1, maxWait do
        if Workspace:IsAncestorOf(Players.LocalPlayer.Character or Players.LocalPlayer) then break end
        wait(0.5)
    end

    local animals = {}
    local ok, res = pcall(function() animals = scanAnimals() end)
    if not ok then
        warn("scanAnimals failed:", res)
        return
    end

    if not animals or #animals == 0 then
        -- nothing to report; optionally exit quietly
        -- you can uncomment to still notify empty servers:
        -- sendToDiscord(JOB_ID, animals)
        return
    end

    -- send, with a small retry loop to be safer
    local attempts = 0
    local success = false
    while attempts < 3 and not success do
        attempts = attempts + 1
        local s, e = pcall(function() return sendToDiscord(JOB_ID, animals) end)
        if s and e then
            success = true
        else
            warn("send attempt failed, retrying in 2s", attempts, e)
            wait(2)
        end
    end

    -- optional: after reporting, wait a bit then destroy this script / hang to avoid double posts
    wait(1)
end)
