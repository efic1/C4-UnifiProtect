--[[
    Setup driver tests.   Run from the repository root:   lua5.1 test/setup_tests.lua

    The end-to-end section loads REAL camera driver instances in their own
    environments and routes C4:SendToDevice between them, so the whole chain
    (setup -> AddDevice -> SET_PROTECT_CONFIG -> camera -> snapshot served) is
    exercised rather than asserted piecewise.
--]]

package.path = "test/?.lua;" .. package.path
local stub = require("c4stub")
local SETUP = "drivers/setup/"
local CAM   = "drivers/camera/"

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("  PASS  " .. name)
    else failed = failed + 1; print("  FAIL  " .. name .. "\n        " .. tostring(err)) end
end
local function eq(a, b, w) if a ~= b then error(string.format("%s: expected %s, got %s", w or "value", tostring(b), tostring(a)), 2) end end
local function truthy(v, w) if not v then error((w or "value") .. ": expected truthy", 2) end end
local function contains(h, n, w) if not tostring(h):find(n, 1, true) then error(string.format("%s: %q not in %q", w or "value", n, tostring(h)), 2) end end

-- Runs timers until none are due. Staggered work is spread over timers, so
-- tests drain explicitly at the point where the work should be finished.
local function drain(st)
    for _ = 1, 100 do
        local due = false
        for _, tm in ipairs(st.timers) do
            if not tm.cancelled and not tm.fired and not tm.repeating then due = true end
        end
        if not due then return end
        st.fireTimers(function(tm) return not tm.repeating end)
    end
end

local CAMERAS = '[{"id":"C1","name":"Front Door - G5"},{"id":"C2","name":"Pool"},{"id":"C3","name":""}]'

local function setup(opts)
    opts = opts or {}
    local st = stub.new({
        routes = opts.routes or { ["/cameras$"] = { body = CAMERAS }, ["meta/info"] = { body = '{"applicationVersion":"6.2.1"}' } },
        existingDevices = opts.existing or {},
        deviceId = 10,
    })
    st.load(SETUP .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "192.0.2.10")
    st.set("API Key", "SETUPKEY")
    return st
end

local function messages(st, cmd)
    local out = {}
    for _, m in ipairs(st.sentToDevice) do if m.command == cmd then table.insert(out, m) end end
    return out
end

print("\nUniFi Protect Setup driver\n")

print("Creating cameras")

test("one driver is added per Protect camera", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(#st.added, 3, "drivers added")
    for _, a in ipairs(st.added) do eq(a.file, "unifi_protect_camera.c4z", "driver file") end
end)

test("drivers are added to the setup driver's room", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    for _, a in ipairs(st.added) do eq(a.room, 7, "room") end
end)

test("drivers are named after their Protect cameras", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(st.added[1].name, "Front Door - G5", "first name")
    eq(st.added[2].name, "Pool", "second name")
end)

test("a camera with no name still gets a usable device name", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    truthy(st.added[3].name ~= "", "name must not be empty")
    contains(st.added[3].name, "Camera", "fallback name")
end)

test("each new driver receives its configuration", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    local cfg = messages(st, "SET_PROTECT_CONFIG")
    eq(#cfg, 3, "configs sent")
    local c = cfg[1].params
    eq(c.address, "192.0.2.10", "address")
    eq(c.api_key, "SETUPKEY", "api key")
    eq(c.camera_id, "C1", "camera id")
    eq(c.parent_id, "10", "parent id")
end)

test("snapshot setting is forwarded", function()
    local st = setup()
    st.set("Snapshots", "On")
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(messages(st, "SET_PROTECT_CONFIG")[1].params.snapshots, "On", "snapshots")
end)

test("RTSP auto-enable setting is forwarded", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(messages(st, "SET_PROTECT_CONFIG")[1].params.enable_rtsp, "Yes", "default Yes")
    st.sentToDevice = {}
    st.set("Enable RTSP in Protect", "No")
    ExecuteCommand("LUA_ACTION", { ACTION = "PushSettings" })
    drain(st)
    eq(messages(st, "SET_PROTECT_CONFIG")[1].params.enable_rtsp, "No", "after change")
end)

print("\nRe-running")

test("a second run adds nothing and updates everything", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    local before = #st.added
    st.sentToDevice = {}
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(#st.added, before, "no duplicates on re-run")
    eq(#messages(st, "SET_PROTECT_CONFIG"), 3, "all three updated")
end)

test("a camera added in Protect later is picked up", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    st.routes["/cameras$"] = { body = CAMERAS:gsub("%]$", ',{"id":"C4","name":"Garage"}]') }
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(#st.added, 4, "one more driver")
    eq(st.added[4].name, "Garage", "new camera")
end)

print("\nAdopting existing drivers")

test("existing camera drivers are asked to identify", function()
    local st = setup({ existing = { ["300"] = true, ["301"] = true } })
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(#messages(st, "IDENTIFY_CAMERA"), 2, "identify requests")
end)

test("an adopted driver is not duplicated", function()
    local st = setup({ existing = { ["300"] = true } })
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    -- the existing driver answers before the adoption wait expires
    ExecuteCommand("ADOPT_RESPONSE", { device_id = "300", camera_id = "C2" })
    drain(st)
    eq(#st.added, 2, "only the two unmatched cameras are added")
    local toAdopted
    for _, m in ipairs(messages(st, "SET_PROTECT_CONFIG")) do
        if m.device == 300 then toAdopted = m end
    end
    truthy(toAdopted, "the adopted driver receives config")
    eq(toAdopted.params.camera_id, "C2", "adopted driver keeps its camera")
end)

test("an unconfigured existing driver is not adopted", function()
    local st = setup({ existing = { ["300"] = true } })
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    ExecuteCommand("ADOPT_RESPONSE", { device_id = "300", camera_id = "" })
    drain(st)
    eq(#st.added, 3, "all three cameras get new drivers")
end)

print("\nPushing settings")

test("rotating the API key reaches every camera", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    st.sentToDevice = {}
    st.set("API Key", "ROTATEDKEY")
    ExecuteCommand("LUA_ACTION", { ACTION = "PushSettings" })
    drain(st)
    local cfg = messages(st, "SET_PROTECT_CONFIG")
    eq(#cfg, 3, "pushed to all")
    for _, m in ipairs(cfg) do eq(m.params.api_key, "ROTATEDKEY", "new key") end
end)

print("\nPacing (rate limiting)")

-- v2 configured every camera in the same instant; Protect answered HTTP 429.
test("only one camera is configured immediately", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    eq(#st.added, 1, "drivers added before any timer fires")
end)

test("the rest follow at spaced intervals", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    local delays = {}
    for _, tm in ipairs(st.timers) do table.insert(delays, tm.ms) end
    table.sort(delays)
    eq(#delays, 2, "two cameras deferred")
    truthy(delays[1] >= 2000, "first deferral at least 2s, got " .. delays[1])
    truthy(delays[2] - delays[1] >= 2000, "deferrals at least 2s apart")
end)

test("Push Settings is paced the same way", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    st.sentToDevice, st.timers = {}, {}
    ExecuteCommand("LUA_ACTION", { ACTION = "PushSettings" })
    eq(#messages(st, "SET_PROTECT_CONFIG"), 1, "pushed immediately")
    drain(st)
    eq(#messages(st, "SET_PROTECT_CONFIG"), 3, "pushed after the pacing")
end)

test("status reports progress, then completion", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    contains(st.props["Setup Status"], "Configuring 3 cameras", "in progress")
    drain(st)
    contains(st.props["Setup Status"], "Done", "finished")
end)

test("a sync cannot be started while one is running", function()
    local st = setup()
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(#st.added, 3, "no duplicates from a double press")
end)

print("\nFailure handling")

test("bad API key reports auth failure and adds nothing", function()
    local st = setup({ routes = { ["/cameras$"] = { code = 401, body = "{}" } } })
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(#st.added, 0, "nothing added")
    contains(st.props["Setup Status"], "Auth Failed", "status")
end)

test("missing credentials are reported, not attempted", function()
    local st = stub.new({})
    st.load(SETUP .. "driver.lua")
    st.set("Log Mode", "Off")
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(#st.requests, 0, "no request made")
    contains(st.props["Setup Status"], "NVR Address", "status")
end)

test("malformed camera list does not crash", function()
    local st = setup({ routes = { ["/cameras$"] = { body = '{"broken":' } } })
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
end)

test("a failed AddDevice does not record a camera", function()
    local st = setup()
    st.C4.AddDevice = function(self, file, room, name, cb) if cb then cb(0) end end
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(st)
    eq(st.persist["managed_cameras"] and next(st.persist["managed_cameras"]) or nil, nil,
       "nothing recorded as managed")
end)

--=============================================================================
print("\nEnd to end: setup driver -> real camera drivers -> served snapshot")
--=============================================================================

-- Loads each camera driver in an isolated environment so their globals
-- (g, Properties, handlers) do not collide, then routes SendToDevice.
local function loadCameraInstance(deviceId, routes)
    local st = stub.new({ routes = routes, deviceId = deviceId })
    local env = setmetatable({}, { __index = _G })
    env.C4 = st.C4
    env.Properties = st.props
    local chunk = assert(loadfile(CAM .. "driver.lua"))
    setfenv(chunk, env)
    chunk()
    st.env = env
    env.OnPropertyChanged("Log Mode")
    return st
end

test("created cameras stream, and serve snapshots from their own camera", function()
    local cameraRoutes = function(camId)
        return {
            ["rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/TOK-' .. camId .. '?enableSrtp"}' },
            -- Keyed on the camera id: a fetch aimed at the wrong camera must
            -- NOT get this frame. (A bare "/snapshot" route hid exactly that.)
            -- Host AND camera id: a fetch aimed at the wrong console or the
            -- wrong camera must not get this frame.
            ["^https://192%.0%.2%.10/proxy/protect/integration/v1/cameras/" .. camId .. "/snapshot"]
                = { body = "JPEG-OF-" .. camId },
        }
    end

    local s = setup()
    s.set("Snapshots", "On")
    local cams = {}

    -- AddDevice spins up a genuine camera driver instance...
    s.C4.AddDevice = function(self, file, room, name, cb)
        s.nextDeviceId = s.nextDeviceId + 1
        local id = s.nextDeviceId
        table.insert(s.added, { file = file, name = name, id = id })
        cams[id] = { name = name }
        if cb then cb(id) end
        return id
    end
    -- ...and SendToDevice delivers to it.
    s.C4.SendToDevice = function(self, dev, cmd, params)
        table.insert(s.sentToDevice, { device = dev, command = cmd, params = params })
        local c = cams[dev]
        if not c then return end
        if not c.st then
            c.st = loadCameraInstance(dev, cameraRoutes(params.camera_id))
        end
        c.st.env.ExecuteCommand(cmd, params)
    end

    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(s)
    eq(#s.added, 3, "three drivers")

    local port = 56000
    for id, c in pairs(cams) do
        local env, st = c.st.env, c.st
        local camId = st.props["Camera ID"]
        truthy(camId and camId ~= "", "camera " .. c.name .. " configured")

        -- video
        local rtsp = env.UIRequest("GET_RTSP_H264_QUERY_STRING", {})
        contains(rtsp, "TOK-" .. camId, c.name .. " RTSP token")

        -- snapshot server: comes up, offers a URL, serves this camera's frame
        port = port + 1
        env.OnServerStatusChanged(port, "ONLINE", "snapshot")
        contains(env.UIRequest("GET_SNAPSHOT_URLS", {}), ":" .. port .. "/", c.name .. " snapshot URL")
        local served
        st.C4.ServerSend = function(self, h, data) served = data end
        env.OnServerDataIn(1, "GET /snapshot.jpg HTTP/1.1\r\n\r\n", "1.1.1.1", 1, "snapshot")
        contains(served or "", "JPEG-OF-" .. camId, c.name .. " serves its own frame")
        contains(served or "", "200 OK", c.name .. " HTTP status")
    end
end)

test("every camera gets a distinct snapshot listener", function()
    -- One listener per camera driver, each on its own OS-assigned port.
    local s = setup()
    s.set("Snapshots", "On")
    local servers = 0
    local cams = {}
    s.C4.AddDevice = function(self, file, room, name, cb)
        s.nextDeviceId = s.nextDeviceId + 1
        cams[s.nextDeviceId] = true
        if cb then cb(s.nextDeviceId) end
    end
    s.C4.SendToDevice = function(self, dev, cmd, params)
        if not cams[dev] then return end
        local inst = loadCameraInstance(dev, { ["/snapshot"] = { body = "J" } })
        inst.C4.CreateServer = function(self2, port) 
            servers = servers + 1
            eq(port, 0, "listener asks the OS for a port")
            return true
        end
        inst.env.ExecuteCommand(cmd, params)
    end
    ExecuteCommand("LUA_ACTION", { ACTION = "SyncCameras" })
    drain(s)
    eq(servers, 3, "one listener per camera")
end)

print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
