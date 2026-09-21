--[[
    UniFi Protect Setup — Control4 DriverWorks driver

    Creates and configures one "UniFi Protect Camera" driver per Protect camera,
    so an installer enters the console address and API key once.

    This driver is NOT in the media or event path. After setup each camera
    driver runs on its own; removing this driver leaves them all working.

    Flow for Create / Update Cameras:
      1. read the camera list from Protect
      2. ask every existing camera driver who it is (IDENTIFY_CAMERA) so ones
         added by hand, or from an earlier install, are adopted not duplicated
      3. after a short wait for replies, add a driver for each camera that has
         none, and push configuration to all of them
--]]

local DRIVER_VERSION = "3"
local CAMERA_DRIVER   = "unifi_protect_camera.c4z"
local PERSIST_MANAGED = "managed_cameras"     -- camera_id -> device_id
local ADOPT_WAIT_MS   = 3000
-- Configuring every camera in the same instant tripped Protect's rate limit
-- (HTTP 429). Cameras are worked through one at a time, this far apart.
local STAGGER_MS      = 2500

local g = {
    address   = "",
    apiKey    = "",
    snapshots = "Off",
    enableRtsp = "Yes",
    logMode   = "Off",
    logLevel  = 2,
    cameras   = {},      -- latest list from Protect: { {id=, name=}, ... }
    syncTimer = nil,
    busy      = false,
    applied   = 0,
}

--=============================================================================
-- Logging
--=============================================================================
local LVL = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 }

local function log(level, fmt, ...)
    if g.logMode == "Off" or level > g.logLevel then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    msg = "[ProtectSetup] " .. msg
    if g.logMode == "Print" or g.logMode == "Print and Log" then print(msg) end
    if g.logMode == "Log" or g.logMode == "Print and Log" then C4:DebugLog(msg) end
end

local function status(text)
    C4:UpdateProperty("Setup Status", text)
    log(LVL.INFO, "%s", text)
end

--=============================================================================
-- JSON (shared with the camera driver)
--=============================================================================
local Json = {}
do
    local pos, str

    local function skip()
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1 else break end
        end
    end

    local parseValue

    local function parseString()
        pos = pos + 1
        local out = {}
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then pos = pos + 1; return table.concat(out) end
            if c == "\\" then
                local e = str:sub(pos + 1, pos + 1)
                if e == "n" then out[#out+1] = "\n"
                elseif e == "t" then out[#out+1] = "\t"
                elseif e == "r" then out[#out+1] = "\r"
                elseif e == "b" then out[#out+1] = "\b"
                elseif e == "f" then out[#out+1] = "\f"
                elseif e == "u" then
                    local hex = str:sub(pos + 2, pos + 5)
                    local n = tonumber(hex, 16)
                    -- Non-BMP and multi-byte codepoints are passed through as '?';
                    -- camera names with emoji will look odd but will not break parsing.
                    out[#out+1] = (n and n < 128) and string.char(n) or "?"
                    pos = pos + 4
                else out[#out+1] = e end
                pos = pos + 2
            else
                out[#out+1] = c
                pos = pos + 1
            end
        end
        return table.concat(out)
    end

    local function parseNumber()
        local s = pos
        while pos <= #str and str:sub(pos, pos):match("[%d%.eE%+%-]") do pos = pos + 1 end
        return tonumber(str:sub(s, pos - 1))
    end

    local function parseArray()
        local arr, n = {}, 0
        pos = pos + 1
        skip()
        if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while pos <= #str do
            n = n + 1
            arr[n] = parseValue()
            skip()
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == "]" then break end
            if c ~= "," then break end
            skip()
        end
        return arr
    end

    local function parseObject()
        local obj = {}
        pos = pos + 1
        skip()
        if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while pos <= #str do
            skip()
            if str:sub(pos, pos) ~= '"' then break end
            local k = parseString()
            skip()
            if str:sub(pos, pos) ~= ":" then break end
            pos = pos + 1
            skip()
            obj[k] = parseValue()
            skip()
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == "}" then break end
            if c ~= "," then break end
        end
        return obj
    end

    parseValue = function()
        skip()
        local c = str:sub(pos, pos)
        if c == "{" then return parseObject() end
        if c == "[" then return parseArray() end
        if c == '"' then return parseString() end
        if c == "t" then pos = pos + 4; return true end
        if c == "f" then pos = pos + 5; return false end
        if c == "n" then pos = pos + 4; return nil end
        return parseNumber()
    end

    function Json.decode(s)
        if type(s) ~= "string" or s == "" then return nil end
        str, pos = s, 1
        local ok, res = pcall(parseValue)
        if not ok then return nil, res end
        return res
    end
end


--=============================================================================
-- Persistence
--=============================================================================
local function getManaged()
    local m = C4:PersistGetValue(PERSIST_MANAGED)
    return type(m) == "table" and m or {}
end

local function saveManaged(m)
    C4:PersistSetValue(PERSIST_MANAGED, m)
    local n = 0
    for _ in pairs(m) do n = n + 1 end
    C4:UpdateProperty("Cameras Managed", tostring(n))
end

--=============================================================================
-- HTTP
--=============================================================================
local function apiGet(path, cb)
    if g.address == "" or g.apiKey == "" then
        cb(false, nil, 0)
        return
    end
    C4:url()
        :OnDone(function(transfer, responses, errCode, errMsg)
            local resp = responses and responses[#responses]
            local code = resp and resp.code or 0
            local body = resp and resp.body or ""
            if errCode ~= 0 and code == 0 then
                log(LVL.ERROR, "Cannot reach %s: %s", g.address, tostring(errMsg))
                cb(false, nil, 0)
            elseif code ~= 200 then
                log(LVL.ERROR, "HTTP %d on %s", code, path)
                cb(false, nil, code)
            else
                cb(true, Json.decode(body), code)
            end
        end)
        :SetOption("ssl_verify_peer", false)
        :SetOption("ssl_verify_host", false)
        :SetOption("fail_on_error", false)
        :SetOption("timeout", 10)
        :Get("https://" .. g.address .. "/proxy/protect/integration/v1" .. path,
             { ["X-API-KEY"] = g.apiKey, ["Accept"] = "application/json" })
end

--=============================================================================
-- Camera configuration
--=============================================================================
local function configFor(cam)
    return {
        address     = g.address,
        api_key     = g.apiKey,
        camera_id   = cam.id,
        camera_name = cam.name,
        snapshots   = g.snapshots,
        enable_rtsp = g.enableRtsp,
        parent_id   = tostring(C4:GetDeviceID()),
    }
end

local function pushConfig(deviceId, cam)
    C4:SendToDevice(deviceId, "SET_PROTECT_CONFIG", configFor(cam))
end

-- Device names come from Protect; a C4 device name cannot be empty.
local function displayName(cam)
    local n = tostring(cam.name or ""):gsub("^%s*(.-)%s*$", "%1")
    return n ~= "" and n or ("Camera " .. tostring(cam.id):sub(-6))
end

--=============================================================================
-- Staggering
--=============================================================================
local function runStaggered(jobs, onDone)
    if #jobs == 0 then
        if onDone then onDone() end
        return
    end
    for i, job in ipairs(jobs) do
        local last = (i == #jobs)
        local run = function()
            job()
            if last and onDone then onDone() end
        end
        if i == 1 then run() else C4:SetTimer((i - 1) * STAGGER_MS, run) end
    end
end

--=============================================================================
-- Sync
--=============================================================================
local function finishSync()
    local managed = getManaged()
    local room = C4:RoomGetId()
    local jobs, added, updated = {}, 0, 0

    for _, cam in ipairs(g.cameras) do
        local devId = managed[cam.id]
        if devId then
            updated = updated + 1
            table.insert(jobs, function() pushConfig(devId, cam) end)
        else
            added = added + 1
            table.insert(jobs, function()
                C4:AddDevice(CAMERA_DRIVER, room, displayName(cam), function(newId)
                    if not newId or newId == 0 then
                        log(LVL.ERROR, "Could not add a driver for %s. Is %s loaded in Composer?",
                            displayName(cam), CAMERA_DRIVER)
                        return
                    end
                    local m = getManaged()
                    m[cam.id] = newId
                    saveManaged(m)
                    pushConfig(newId, cam)
                    log(LVL.INFO, "Added %s (device %d)", displayName(cam), newId)
                end)
            end)
        end
    end

    local total = #jobs
    status(string.format("Configuring %d camera%s, one every %.1fs...",
        total, total == 1 and "" or "s", STAGGER_MS / 1000))
    runStaggered(jobs, function()
        g.busy = false
        status(string.format("Done: %d added, %d updated", added, updated))
    end)
end

local function syncCameras()
    if g.busy then
        log(LVL.WARN, "A sync is already running")
        return
    end
    if g.address == "" or g.apiKey == "" then
        status("Enter NVR Address and API Key first")
        return
    end
    g.busy = true
    status("Reading cameras from Protect...")

    apiGet("/cameras", function(ok, data, code)
        if not ok or type(data) ~= "table" then
            g.busy = false
            status(code == 401 and "Auth Failed - check API Key"
                   or ("Could not read cameras (HTTP " .. tostring(code) .. ")"))
            return
        end

        g.cameras = {}
        local list = data.cameras or data
        for _, cam in ipairs(list) do
            if type(cam) == "table" and cam.id then
                table.insert(g.cameras, { id = cam.id, name = cam.name })
            end
        end
        C4:UpdateProperty("Cameras Found", tostring(#g.cameras))

        -- Adopt camera drivers we did not create (added by hand, or left
        -- behind by an earlier install) before creating anything, so a
        -- re-run never duplicates.
        local managed = getManaged()
        local known = {}
        for _, id in pairs(managed) do known[tonumber(id)] = true end
        local asked = 0
        local existing = C4:GetDevicesByC4iName(CAMERA_DRIVER)
        if type(existing) == "table" then
            for rawId in pairs(existing) do
                local devId = tonumber(rawId)
                if devId and not known[devId] then
                    C4:SendToDevice(devId, "IDENTIFY_CAMERA",
                        { parent_device_id = tostring(C4:GetDeviceID()) })
                    asked = asked + 1
                end
            end
        end

        if asked > 0 then
            status(string.format("Found %d cameras; checking %d existing drivers...", #g.cameras, asked))
            if g.syncTimer then g.syncTimer:Cancel() end
            g.syncTimer = C4:SetTimer(ADOPT_WAIT_MS, function()
                g.syncTimer = nil
                finishSync()
            end)
        else
            finishSync()
        end
    end)
end

local function pushSettings()
    local managed = getManaged()
    local byId = {}
    for _, c in ipairs(g.cameras) do byId[c.id] = c end
    local jobs = {}
    for camId, devId in pairs(managed) do
        local cam = byId[camId] or { id = camId }
        table.insert(jobs, function() pushConfig(devId, cam) end)
    end
    local n = #jobs
    status(string.format("Pushing settings to %d camera%s...", n, n == 1 and "" or "s"))
    runStaggered(jobs, function()
        status(string.format("Settings pushed to %d camera%s", n, n == 1 and "" or "s"))
    end)
end

local function testConnection()
    apiGet("/meta/info", function(ok, data, code)
        if ok then
            local v = type(data) == "table" and (data.applicationVersion or data.version) or "?"
            status("Connected - Protect " .. tostring(v))
        elseif code == 401 or code == 403 then
            status("Auth Failed - check API Key")
        else
            status("Connection failed (HTTP " .. tostring(code) .. ")")
        end
    end)
end

--=============================================================================
-- Inbound
--=============================================================================
function ExecuteCommand(sCommand, tParams)
    tParams = tParams or {}

    if sCommand == "LUA_ACTION" then
        sCommand = tParams.ACTION or ""
        if sCommand == "TestConnection" then testConnection()
        elseif sCommand == "SyncCameras" then syncCameras()
        elseif sCommand == "PushSettings" then pushSettings()
        elseif sCommand == "ForgetCameras" then
            saveManaged({})
            status("Forgot managed cameras. Drivers are untouched; the next sync re-adopts them.")
        end
        return
    end

    -- A camera driver answering IDENTIFY_CAMERA.
    if sCommand == "ADOPT_RESPONSE" then
        local devId = tonumber(tParams.device_id)
        local camId = tParams.camera_id
        if devId and camId and camId ~= "" then
            local m = getManaged()
            if not m[camId] then
                m[camId] = devId
                saveManaged(m)
                log(LVL.INFO, "Adopted existing driver %d for camera %s", devId, camId)
            end
        else
            log(LVL.DEBUG, "Unconfigured camera driver %s ignored", tostring(tParams.device_id))
        end
        return
    end

    if sCommand == "CONFIG_APPLIED" then
        g.applied = g.applied + 1
        log(LVL.DEBUG, "Device %s applied config", tostring(tParams.device_id))
        return
    end
end

function OnPropertyChanged(name)
    local v = Properties[name]
    if v == nil then return end
    if name == "NVR Address" then g.address = (v:gsub("^%s*(.-)%s*$", "%1"))
    elseif name == "API Key" then g.apiKey = (v:gsub("^%s*(.-)%s*$", "%1"))
    elseif name == "Snapshots" then g.snapshots = v
    elseif name == "Enable RTSP in Protect" then g.enableRtsp = v
    elseif name == "Log Mode" then g.logMode = v
    elseif name == "Log Level" then g.logLevel = tonumber(v:sub(1, 1)) or 2
    end
end

function OnDriverLateInit()
    for _, name in ipairs({ "Log Mode", "Log Level", "NVR Address", "API Key", "Snapshots", "Enable RTSP in Protect" }) do
        pcall(OnPropertyChanged, name)
    end
    C4:UpdateProperty("Driver Version", DRIVER_VERSION)
    saveManaged(getManaged())   -- refresh the count
    if g.address ~= "" and g.apiKey ~= "" then
        testConnection()
    else
        status("Enter NVR Address and API Key")
    end
end

function OnDriverDestroyed()
    if g.syncTimer then g.syncTimer:Cancel() end
end
