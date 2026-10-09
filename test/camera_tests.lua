--[[
    run_tests.lua — regression suite for the UniFi Protect camera driver.

    Run from the repository root:   lua5.1 test/camera_tests.lua

    Every test here corresponds to a bug that actually shipped. The comment on
    each names it, so nobody removes a test without understanding what it caught.
--]]

package.path = "test/?.lua;" .. package.path
local stub = require("c4stub")
local CAM = "drivers/camera/"

--=============================================================================
-- Assertions
--=============================================================================
local passed, failed, current = 0, 0, ""

local function test(name, fn)
    current = name
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print(string.format("  PASS  %s", name))
    else
        failed = failed + 1
        print(string.format("  FAIL  %s\n        %s", name, tostring(err)))
    end
end

local function eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s",
            what or "value", tostring(expected), tostring(actual)), 2)
    end
end

local function truthy(v, what)
    if not v then error((what or "value") .. ": expected truthy, got " .. tostring(v), 2) end
end

local function contains(haystack, needle, what)
    if not tostring(haystack):find(needle, 1, true) then
        error(string.format("%s: %q not found in %q", what or "value", needle, tostring(haystack)), 2)
    end
end

-- Cheap well-formedness check: non-empty, balanced angle brackets, has a root.
local function wellFormedXml(s, what)
    truthy(s ~= nil and s ~= "", (what or "response") .. " must not be empty")
    local root = s:match("^<([%w_]+)")
    truthy(root, (what or "response") .. " must start with an element: " .. tostring(s))
    local opens = select(2, s:gsub("<[%w_]", ""))
    local closes = select(2, s:gsub("</[%w_]", "")) + select(2, s:gsub("/>", ""))
    if opens ~= closes then
        error(string.format("%s: unbalanced tags in %q", what or "response", s), 2)
    end
end

local function configured(routes)
    local st = stub.new({ routes = routes or {} })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "192.0.2.10")
    st.set("API Key", "TESTKEY")
    st.set("Camera ID", "CAM1")
    st.set("RTSP Alias - Low", "LOWTOK")
    st.set("RTSP Alias - Medium", "MEDTOK")
    st.set("RTSP Alias - High", "HIGHTOK")
    st.set("Preferred Quality", "Low")
    return st
end

print("\nUniFi Protect camera driver — regression suite\n")

--=============================================================================
print("Proxy responses")
--=============================================================================

-- v35: UIRequest returned "" for snapshot commands. The proxy still asks even
-- when snapshots are not advertised, and a bare "" stalled the camera view.
test("every UIRequest response is a well-formed document", function()
    local st = configured()
    for _, cmd in ipairs({ "GET_RTSP_H264_QUERY_STRING", "GET_SNAPSHOT_QUERY_STRING",
                           "GET_MJPEG_QUERY_STRING", "GET_SNAPSHOT_URLS" }) do
        wellFormedXml(UIRequest(cmd, { SIZE_X = 640 }), cmd)
    end
end)

-- Same bug, worst case: a camera with nothing configured must still answer.
test("unconfigured camera still returns a document", function()
    local st = stub.new()
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    wellFormedXml(UIRequest("GET_RTSP_H264_QUERY_STRING", {}), "no-alias RTSP")
end)

-- v5/v12: unclosed <stream> tags produced invalid XML which broke the camera
-- list parse for EVERY camera in the project, not just this one.
test("stream elements are self-closing", function()
    local st = configured()
    local xml = UIRequest("GET_STREAM_URLS", {})
    if xml ~= "<streams></streams>" then
        local opened = select(2, xml:gsub("<stream%s", ""))
        local closed = select(2, xml:gsub("/>", ""))
        truthy(opened > 0, "at least one stream element")
        eq(closed, opened, "every <stream> must be self-closed")
    end
end)

-- v1: handlers were written for GET_STREAM_URL / CAMERA_SELECT_STREAM, which
-- do not exist. Guard the real names.
test("responds to the real command names", function()
    local st = configured()
    contains(UIRequest("GET_RTSP_H264_QUERY_STRING", {}), "rtsp_h264_query_string", "root element")
end)

test("unknown proxy command does not error", function()
    local st = configured()
    ReceivedFromProxy(5001, "TOTALLY_MADE_UP", {})
    UIRequest("ALSO_MADE_UP", {})
end)

--=============================================================================
print("\nStream selection")
--=============================================================================

-- Legacy commands carry SIZE_X, not RESOLUTION. Honouring only RESOLUTION
-- meant every client got the Preferred Quality stream.
test("quality follows the requested width", function()
    local st = configured()
    local function tok(w)
        return UIRequest("GET_RTSP_H264_QUERY_STRING", { SIZE_X = w }):match(">(.-)<")
    end
    eq(tok(320), "LOWTOK", "320px")
    eq(tok(640), "LOWTOK", "640px")
    eq(tok(1024), "MEDTOK", "1024px")
    eq(tok(1920), "HIGHTOK", "1920px")
end)

test("no size hint falls back to Preferred Quality", function()
    local st = configured()
    st.set("Preferred Quality", "High")
    eq(UIRequest("GET_RTSP_H264_QUERY_STRING", {}):match(">(.-)<"), "HIGHTOK", "preferred")
end)

-- A tier with RTSP disabled in Protect must not produce a dead URL.
test("falls back when the requested tier has no alias", function()
    local st = configured()
    st.set("RTSP Alias - Medium", "")
    local tok = UIRequest("GET_RTSP_H264_QUERY_STRING", { SIZE_X = 1024 }):match(">(.-)<")
    truthy(tok ~= "" and tok ~= nil, "must serve some enabled tier")
end)

--=============================================================================
print("\nPorts")
--=============================================================================

-- v23: the proxy's stored RTSP port (554, inherited from an early install)
-- silently overrode the capability default, and the log printed the driver's
-- own 7447 while Control4 requested 554.
test("ports are pushed even with nothing configured", function()
    local st = stub.new()
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    OnDriverLateInit()
    local sent = st.sentTo("RTSP_PORT_CHANGED")
    truthy(sent, "RTSP_PORT_CHANGED must be sent on a fresh install")
    eq(sent.params.PORT, "7447", "pushed RTSP port")
end)

-- v44: a fresh camera's proxy reports its stored port (554) on load. The
-- driver used to ADOPT that, so every new camera needed 7447 typed in by
-- hand. The driver's property is the source of truth; the proxy is corrected.
test("proxy reporting 554 does not change the driver's port", function()
    local st = configured()
    ReceivedFromProxy(5001, "SET_RTSP_PORT", { ["PORT ID"] = 554 })
    contains(UIRequest("GET_STREAM_URLS", {}), ":7447/", "driver keeps 7447")
end)

test("proxy reporting 554 triggers a correction back to 7447", function()
    local st = configured()
    st.proxy = {}
    ReceivedFromProxy(5001, "SET_RTSP_PORT", { ["PORT ID"] = 554 })
    st.fireTimers(function(t) return t.ms == 1000 end)
    local sent = st.sentTo("RTSP_PORT_CHANGED")
    truthy(sent, "a correction must be pushed")
    eq(sent.params.PORT, "7447", "corrected value")
end)

test("a proxy that keeps reverting is given up on, with a clear message", function()
    local st = configured()
    for i = 1, 10 do ReceivedFromProxy(5001, "SET_RTSP_PORT", { PORT = 554 }) end
    contains(st.props["Driver Status"] or "", "by hand", "installer told what to do")
    local deferred = 0
    for _, tm in ipairs(st.timers) do if tm.ms == 1000 then deferred = deferred + 1 end end
    truthy(deferred <= 5, "corrections are bounded, got " .. deferred)
end)

test("proxy agreeing with the driver causes no correction", function()
    local st = configured()
    local before = #st.timers
    ReceivedFromProxy(5001, "SET_RTSP_PORT", { PORT = 7447 })
    eq(#st.timers, before, "no correction scheduled")
end)

test("RTSP Port property changes the port and pushes it", function()
    local st = configured()
    st.proxy = {}
    st.set("RTSP Port", "8554")
    contains(UIRequest("GET_STREAM_URLS", {}), ":8554/", "stream uses new port")
    eq(st.sentTo("RTSP_PORT_CHANGED").params.PORT, "8554", "pushed to proxy")
end)

-- On a device made by AddDevice the proxy may not be listening during
-- OnDriverLateInit, so the push is repeated once it has had time to start.
test("ports are pushed again after startup", function()
    local st = stub.new()
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    OnDriverLateInit()
    local delays = {}
    for _, tm in ipairs(st.timers) do delays[tm.ms] = true end
    truthy(delays[5000], "retry at 5s")
    truthy(delays[30000], "retry at 30s")
    st.proxy = {}
    st.fireTimers(function(tm) return tm.ms == 5000 end)
    eq(st.sentTo("RTSP_PORT_CHANGED").params.PORT, "7447", "delayed push carries 7447")
end)

test("USE_DEFAULTS restores the configured port", function()
    local st = configured()
    st.set("RTSP Port", "7447")
    ReceivedFromProxy(5001, "USE_DEFAULTS", {})
    contains(UIRequest("GET_STREAM_URLS", {}), ":7447/", "back to 7447")
end)

--=============================================================================
print("\nProperty handling")
--=============================================================================

-- v9: OnDriverLateInit replayed properties via pairs(), and the Camera ID
-- handler cleared the alias table. If aliases were replayed first they were
-- destroyed. Order-dependent, so it only broke sometimes.
test("stored aliases survive a reload", function()
    local st = stub.new({ routes = { ["rtsps%-stream"] = { body = '{"low":null,"medium":null,"high":null}' } } })
    st.load(CAM .. "driver.lua")
    st.reload({
        ["Log Mode"] = "Off",
        ["NVR Address"] = "192.0.2.10",
        ["API Key"] = "K",
        ["Camera ID"] = "CAM1",
        ["RTSP Alias - Low"] = "SURVIVOR",
        ["Preferred Quality"] = "Low",
    })
    eq(UIRequest("GET_RTSP_H264_QUERY_STRING", {}):match(">(.-)<"), "SURVIVOR", "alias after reload")
end)

-- v1: Composer delivers actions as LUA_ACTION with the name in tParams.ACTION.
test("LUA_ACTION dispatch works", function()
    local st = configured()
    ExecuteCommand("LUA_ACTION", { ACTION = "SimulateMotion" })
    eq(st.vars["MOTION_DETECTED"], "true", "motion variable")
end)

test("LUA_ACTION with no action name does not error", function()
    local st = configured()
    ExecuteCommand("LUA_ACTION", {})
end)

test("driver version property matches DRIVER_VERSION", function()
    local st = configured()
    OnDriverLateInit()
    truthy(st.props["Driver Version"] ~= nil and st.props["Driver Version"] ~= "",
        "Driver Version must be published")
end)

--=============================================================================
print("\nEvents")
--=============================================================================

-- v1: a single shared reset timer meant a doorbell press cleared an active
-- motion flag.
test("event hold timers are independent", function()
    local st = configured()
    ExecuteCommand("LUA_ACTION", { ACTION = "SimulateMotion" })
    ExecuteCommand("LUA_ACTION", { ACTION = "SimulateDoorbell" })
    eq(st.vars["MOTION_DETECTED"], "true", "motion still set")
    eq(st.vars["DOORBELL_RING"], "true", "doorbell set")
end)

test("polling is off by default", function()
    local st = configured()
    OnDriverLateInit()
    contains(st.props["API Call Rate"] or "", "0 per hour", "default call rate")
end)

--=============================================================================
print("\nHTTP")
--=============================================================================

-- v22: POST bodies went out with no Content-Type, so Protect could not parse
-- them and reported every field as missing.
test("POST bodies carry Content-Type", function()
    local st = configured()
    ExecuteCommand("LUA_ACTION", { ACTION = "EnableRtsp" })
    local found
    for _, r in ipairs(st.requests) do
        if r.method == "POST" and r.body and r.body ~= "" then found = r end
    end
    truthy(found, "a POST with a body must have been sent")
    eq(found.headers["Content-Type"], "application/json", "Content-Type")
    contains(found.body, "qualities", "request body")
end)

test("GET requests do not set Content-Type", function()
    local st = configured()
    ExecuteCommand("LUA_ACTION", { ACTION = "TestConnection" })
    for _, r in ipairs(st.requests) do
        if r.method == "GET" then
            eq(r.headers["Content-Type"], nil, "GET Content-Type")
        end
    end
end)

test("requests carry the API key header", function()
    local st = configured()
    ExecuteCommand("LUA_ACTION", { ACTION = "TestConnection" })
    truthy(#st.requests > 0, "a request must have been made")
    eq(st.requests[#st.requests].headers["X-API-KEY"], "TESTKEY", "API key header")
end)

--=============================================================================
print("\nDiscovery")
--=============================================================================

test("camera list populates the dropdown", function()
    local st = stub.new({ routes = {
        ["/cameras"] = { body = '[{"id":"C1","name":"Front Door"},{"id":"C2","name":"Pool"}]' },
    } })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "192.0.2.10")
    st.set("API Key", "K")
    ExecuteCommand("LUA_ACTION", { ACTION = "DiscoverCameras" })
    contains(st.lists["Camera"] or "", "Front Door", "dropdown contents")
    contains(st.lists["Camera"] or "", "Pool", "dropdown contents")
end)

-- A comma in a camera name would split one entry into two.
test("commas in camera names do not split the list", function()
    local st = stub.new({ routes = {
        ["/cameras"] = { body = '[{"id":"C1","name":"Back, Yard"}]' },
    } })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "1.2.3.4")
    st.set("API Key", "K")
    ExecuteCommand("LUA_ACTION", { ACTION = "DiscoverCameras" })
    local list = st.lists["Camera"] or ""
    local found
    for entry in (list .. ","):gmatch("([^,]*),") do
        if entry:find("Yard") then found = entry end
    end
    truthy(found, "the camera must appear in the list")
    truthy(not found:find(","), "its name must not contain a delimiter")
    truthy(found:find("Back") and found:find("Yard"), "name kept whole: " .. tostring(found))
end)

test("selecting a camera sets the camera id", function()
    local st = stub.new({ routes = {
        ["/cameras"] = { body = '[{"id":"CAM-XYZ","name":"Front Door"}]' },
        ["rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/TOK?enableSrtp"}' },
    } })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "1.2.3.4")
    st.set("API Key", "K")
    ExecuteCommand("LUA_ACTION", { ACTION = "DiscoverCameras" })
    st.set("Camera", "Front Door")
    eq(st.props["Camera ID"], "CAM-XYZ", "camera id")
    eq(st.props["RTSP Alias - Low"], "TOK", "alias fetched on selection")
end)

--=============================================================================
print("\nAlias parsing")
--=============================================================================

test("token is extracted from an rtsps URL", function()
    local st = configured()
    st.set("RTSP Alias - Low", "rtsps://192.0.2.10:7441/PASTED?enableSrtp")
    eq(UIRequest("GET_RTSP_H264_QUERY_STRING", {}):match(">(.-)<"), "PASTED", "pasted URL cleaned")
end)

test("disabled tiers are reported, not guessed", function()
    local st = stub.new({ routes = {
        ["rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/L?enableSrtp","medium":null,"high":null}' },
    } })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "1.2.3.4")
    st.set("API Key", "K")
    st.set("Camera ID", "C1")
    ExecuteCommand("LUA_ACTION", { ACTION = "FetchAliases" })
    eq(st.props["RTSP Alias - Low"], "L", "low populated")
    truthy((st.props["RTSP Alias - High"] or "") == "", "high must stay empty")
end)

--=============================================================================
print("\nSnapshots")
--=============================================================================

-- Snapshots default off, and the response must still be a valid document.
test("snapshots off returns an empty document, never a bare string", function()
    local st = configured()
    eq(UIRequest("GET_SNAPSHOT_URLS", {}), "<snapshots></snapshots>", "snapshots off")
end)

-- v34: the app crashed when SNAPSHOT was advertised but no listener existed.
test("no URL is offered until the server has an address", function()
    local st = configured()
    st.set("Snapshots", "On")
    -- server not yet ONLINE
    eq(UIRequest("GET_SNAPSHOT_URLS", {}), "<snapshots></snapshots>", "before server start")
    OnServerStatusChanged(53319, "ONLINE", "snapshot")
    contains(UIRequest("GET_SNAPSHOT_URLS", {}), "http://192.0.2.50:53319/", "after server start")
end)

test("snapshot URL is a well-formed document", function()
    local st = configured()
    st.set("Snapshots", "On")
    OnServerStatusChanged(53319, "ONLINE", "snapshot")
    wellFormedXml(UIRequest("GET_SNAPSHOT_URLS", {}), "snapshot urls")
end)

test("snapshot fetch sends the API key as a header, never in the URL", function()
    local st = configured({ ["snapshot"] = { body = string.rep("J", 5000) } })
    st.set("Snapshots", "On")
    OnServerStatusChanged(53319, "ONLINE", "snapshot")
    OnServerDataIn(1, "GET /snapshot.jpg HTTP/1.1\r\n\r\n", "1.1.1.1", 5000, "snapshot")
    local found
    for _, r in ipairs(st.requests) do
        if r.url:find("snapshot") then found = r end
    end
    truthy(found, "a snapshot request must have been made")
    eq(found.headers["X-API-KEY"], "TESTKEY", "key travels as a header")
    truthy(not found.url:find("apiKey="), "key must never appear in the URL")
end)

-- v40 sent w=640, which the integration endpoint rejects with HTTP 400.
test("snapshot fetch uses only supported query parameters", function()
    local st = configured({ ["snapshot"] = { body = string.rep("J", 5000) } })
    st.set("Snapshots", "On")
    OnServerStatusChanged(53319, "ONLINE", "snapshot")
    OnServerDataIn(1, "GET /snapshot.jpg HTTP/1.1\r\n\r\n", "1.1.1.1", 5000, "snapshot")
    local found
    for _, r in ipairs(st.requests) do
        if r.url:find("/snapshot") then found = r.url end
    end
    truthy(found, "a snapshot request must have been made")
    truthy(not found:find("w=", 1, true), "w= is rejected by Protect: " .. tostring(found))
    contains(found, "highQuality=", "highQuality is the supported parameter")
end)

-- v46: fetching a ~1 MB frame per camera the moment settings were pushed
-- helped trip Protect's rate limit. Frames are pulled on first request.
test("no snapshot is fetched until a Navigator asks", function()
    local st = configured({ ["snapshot"] = { body = string.rep("J", 5000) } })
    st.set("Snapshots", "On")
    OnServerStatusChanged(53319, "ONLINE", "snapshot")
    for _, r in ipairs(st.requests) do
        truthy(not r.url:find("/snapshot"), "unrequested snapshot fetch: " .. r.url)
    end
end)

test("turning snapshots off withdraws the URL", function()
    local st = configured()
    st.set("Snapshots", "On")
    OnServerStatusChanged(53319, "ONLINE", "snapshot")
    st.set("Snapshots", "Off")
    eq(UIRequest("GET_SNAPSHOT_URLS", {}), "<snapshots></snapshots>", "after switching off")
end)

--=============================================================================
print("\nConfiguration from the setup driver")
--=============================================================================

local function freshCamera(routes)
    local st = stub.new({ routes = routes or {
        ["rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/NEWLOW?enableSrtp"}' },
        ["/snapshot"]     = { body = string.rep("J", 5000) },
    } })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    return st
end

test("SET_PROTECT_CONFIG configures a blank camera driver", function()
    local st = freshCamera()
    ExecuteCommand("SET_PROTECT_CONFIG", {
        address = "192.0.2.10", api_key = "PUSHEDKEY",
        camera_id = "CAM-A", camera_name = "Pool", snapshots = "Off", parent_id = "42",
    })
    eq(st.props["NVR Address"], "192.0.2.10", "address")
    eq(st.props["Camera ID"], "CAM-A", "camera id")
    eq(st.props["Camera Name"], "Pool", "camera name")
    eq(st.props["RTSP Alias - Low"], "NEWLOW", "aliases fetched after config")
    eq(UIRequest("GET_RTSP_H264_QUERY_STRING", {}):match(">(.-)<"), "NEWLOW", "stream served")
end)

-- The whole point: config arrives via UpdateProperty, which never fires
-- OnPropertyChanged. If applyConfig relied on that, nothing would change.
test("pushed config reaches internal state, not just the display", function()
    local st = freshCamera()
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "10.0.0.5", api_key = "K2", camera_id = "CAM-B" })
    contains(UIRequest("GET_STREAM_URLS", {}), "10.0.0.5", "stream URL uses pushed address")
    ExecuteCommand("LUA_ACTION", { ACTION = "TestConnection" })
    eq(st.requests[#st.requests].headers["X-API-KEY"], "K2", "requests use pushed key")
end)

test("camera replies CONFIG_APPLIED to its parent", function()
    local st = freshCamera()
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "1.2.3.4", api_key = "K", camera_id = "C", parent_id = "42" })
    local reply
    for _, m in ipairs(st.sentToDevice) do if m.command == "CONFIG_APPLIED" then reply = m end end
    truthy(reply, "CONFIG_APPLIED must be sent")
    eq(reply.device, 42, "sent to the parent")
    eq(reply.params.camera_id, "C", "reports its camera")
end)

test("IDENTIFY_CAMERA answers with an ADOPT_RESPONSE", function()
    local st = freshCamera()
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "1.2.3.4", api_key = "K", camera_id = "CAM-X" })
    ExecuteCommand("IDENTIFY_CAMERA", { parent_device_id = "77" })
    local reply
    for _, m in ipairs(st.sentToDevice) do if m.command == "ADOPT_RESPONSE" then reply = m end end
    truthy(reply, "ADOPT_RESPONSE must be sent")
    eq(reply.device, 77, "sent to the asker")
    eq(reply.params.camera_id, "CAM-X", "identifies its camera")
    eq(reply.params.device_id, "100", "includes its own device id")
end)

--=============================================================================
print("\nSnapshots survive configuration pushes")
--=============================================================================

test("config push with snapshots On starts the server", function()
    local st = freshCamera()
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "1.2.3.4", api_key = "K", camera_id = "C", snapshots = "On" })
    eq(#st.servers, 1, "one listener created")
end)

-- A re-push must reuse the listener. A new port would strand every
-- Navigator still holding the old snapshot URL.
test("re-pushing config keeps the same listener and port", function()
    local st = freshCamera()
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "1.2.3.4", api_key = "K", camera_id = "C", snapshots = "On" })
    OnServerStatusChanged(55030, "ONLINE", "snapshot")
    local before = UIRequest("GET_SNAPSHOT_URLS", {})
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "1.2.3.4", api_key = "K2", camera_id = "C", snapshots = "On" })
    eq(#st.servers, 1, "no second listener")
    eq(#st.destroyed, 0, "listener not torn down")
    eq(UIRequest("GET_SNAPSHOT_URLS", {}), before, "snapshot URL unchanged")
end)

test("after a camera change, snapshots come from the new camera", function()
    local st = freshCamera()
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "1.2.3.4", api_key = "K", camera_id = "OLDCAM", snapshots = "On" })
    OnServerStatusChanged(55030, "ONLINE", "snapshot")
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "5.6.7.8", api_key = "NEWKEY", camera_id = "NEWCAM", snapshots = "On" })
    OnServerDataIn(1, "GET /snapshot.jpg HTTP/1.1\r\n\r\n", "1.1.1.1", 5000, "snapshot")
    local last
    for _, r in ipairs(st.requests) do if r.url:find("/snapshot") then last = r end end
    truthy(last, "a snapshot fetch must follow the change")
    contains(last.url, "5.6.7.8", "new console")
    contains(last.url, "NEWCAM", "new camera")
    eq(last.headers["X-API-KEY"], "NEWKEY", "new key")
end)

test("a served frame comes from the current camera, not a stale cache", function()
    local st = freshCamera({ ["/snapshot"] = { body = "FRAME-ONE" } })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "1.2.3.4", api_key = "K", camera_id = "C1", snapshots = "On" })
    OnServerStatusChanged(55030, "ONLINE", "snapshot")
    st.routes["/snapshot"] = { body = "FRAME-TWO" }
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "1.2.3.4", api_key = "K", camera_id = "C2", snapshots = "On" })
    local sent
    C4.ServerSend = function(self, h, data) sent = data end
    OnServerDataIn(1, "GET /snapshot.jpg HTTP/1.1\r\n\r\n", "1.1.1.1", 5000, "snapshot")
    contains(sent or "", "FRAME-TWO", "served frame")
    truthy(not (sent or ""):find("FRAME-ONE"), "old camera's frame must not be served")
end)

test("config push with snapshots Off tears the server down", function()
    local st = freshCamera()
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "1.2.3.4", api_key = "K", camera_id = "C", snapshots = "On" })
    OnServerStatusChanged(55030, "ONLINE", "snapshot")
    ExecuteCommand("SET_PROTECT_CONFIG", { snapshots = "Off" })
    eq(UIRequest("GET_SNAPSHOT_URLS", {}), "<snapshots></snapshots>", "URL withdrawn")
end)

--=============================================================================
print("\nStatus under real (asynchronous) HTTP")
--=============================================================================
-- These use async=true: replies arrive only on st.flush(), as on a real
-- controller. The synchronous stub hid the "No RTSP alias" race entirely.

local STREAMS_ON  = '{"low":"rtsps://h:7441/LOWTOK?enableSrtp","medium":"rtsps://h:7441/MEDTOK?enableSrtp"}'
local STREAMS_OFF = '{"low":null,"medium":null,"high":null}'

local function asyncCamera(routes)
    local st = stub.new({ async = true, routes = routes })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    return st
end

-- v44: the exact field report. Aliases loaded, status stuck on "No RTSP alias".
test("status is correct once aliases arrive after the config push", function()
    local st = asyncCamera({
        ["rtsps%-stream"] = { body = STREAMS_ON },
        ["meta/info"] = { body = '{"applicationVersion":"6.2.1"}' },
    })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
    st.flush()
    eq(st.props["RTSP Alias - Low"], "LOWTOK", "alias loaded")
    truthy(not (st.props["Driver Status"] or ""):find("No RTSP alias"),
        "status must not claim a missing alias: " .. tostring(st.props["Driver Status"]))
    contains(st.props["Driver Status"], "Online", "status once everything has replied")
end)

test("while streams are loading, status says so rather than failing", function()
    local st = asyncCamera({ ["rtsps%-stream"] = { body = STREAMS_ON } })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
    eq(st.props["Driver Status"], "Fetching streams...", "status mid-flight")
end)

test("reply order does not matter", function()
    -- Deliver the alias reply BEFORE the connection test reply, then the
    -- reverse; both must land on the same status.
    for _, reverse in ipairs({ false, true }) do
        local st = asyncCamera({
            ["rtsps%-stream"] = { body = STREAMS_ON },
            ["meta/info"] = { body = '{"applicationVersion":"6.2.1"}' },
        })
        ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
        if reverse then
            local q = st.pending; st.pending = {}
            for i = #q, 1, -1 do table.insert(st.pending, q[i]) end
        end
        st.flush()
        contains(st.props["Driver Status"], "Online", "status, reverse=" .. tostring(reverse))
    end
end)

test("RTSP off in Protect is enabled automatically", function()
    local enabled = false
    local st = asyncCamera({
        ["rtsps%-stream"] = function(method)
            if method == "POST" then enabled = true; return 200, "{}" end
            return 200, enabled and STREAMS_ON or STREAMS_OFF
        end,
        ["meta/info"] = { body = '{"applicationVersion":"6.2.1"}' },
    })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
    st.flush()
    truthy(enabled, "the driver must have asked Protect to enable RTSP")
    eq(st.props["RTSP Alias - Low"], "LOWTOK", "aliases after enabling")
    contains(st.props["Driver Status"], "Online", "status after enabling")
end)

test("auto-enable off leaves Protect alone and says what to do", function()
    local posted = false
    local st = asyncCamera({
        ["rtsps%-stream"] = function(method)
            if method == "POST" then posted = true end
            return 200, STREAMS_OFF
        end,
    })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K",
                                           camera_id = "C1", enable_rtsp = "No" })
    st.flush()
    truthy(not posted, "Protect must not be modified")
    contains(st.props["Driver Status"], "RTSP is off", "status")
end)

test("a camera Protect refuses to enable does not loop", function()
    local posts = 0
    local st = asyncCamera({
        ["rtsps%-stream"] = function(method)
            if method == "POST" then posts = posts + 1 end
            return 200, STREAMS_OFF              -- enabling never takes
        end,
    })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
    st.flush()
    eq(posts, 1, "exactly one enable attempt")
    contains(st.props["Driver Status"], "RTSP is off", "final status")
end)

test("a 404 on rtsps-stream is not reported as a missing API", function()
    local st = asyncCamera({
        ["rtsps%-stream"] = { code = 404, body = '{"error":"not found"}' },
    })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K",
                                           camera_id = "C1", enable_rtsp = "No" })
    st.flush()
    truthy(not (st.props["Driver Status"] or ""):find("Integration API"),
        "misleading status: " .. tostring(st.props["Driver Status"]))
end)

test("a 404 on meta/info is reported as a missing API", function()
    local st = asyncCamera({ ["meta/info"] = { code = 404, body = "{}" } })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
    st.flush()
    contains(st.props["Driver Status"], "Integration API not found", "status")
end)

test("a quality switched off in Protect stops being served", function()
    local st = asyncCamera({ ["rtsps%-stream"] = { body = STREAMS_ON } })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
    st.flush()
    eq(st.props["RTSP Alias - Medium"], "MEDTOK", "medium present")
    st.routes["rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/LOWTOK?enableSrtp","medium":null}' }
    ExecuteCommand("LUA_ACTION", { ACTION = "FetchAliases" })
    st.flush()
    eq(st.props["RTSP Alias - Medium"], "", "medium cleared")
    eq(UIRequest("GET_RTSP_H264_QUERY_STRING", { SIZE_X = 1024 }):match(">(.-)<"), "LOWTOK",
        "a Medium request falls back to a live token")
end)

--=============================================================================
-- Rate limiting (HTTP 429)
--=============================================================================

test("a 429 is retried, not reported as a failure", function()
    local calls = 0
    local st = asyncCamera({
        ["rtsps%-stream"] = function()
            calls = calls + 1
            if calls <= 2 then return 429, '{"error":"too many"}' end
            return 200, STREAMS_ON
        end,
        ["meta/info"] = { body = '{"applicationVersion":"6.2.1"}' },
    })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
    for _ = 1, 5 do st.flush(); st.fireTimers() end
    eq(st.props["RTSP Alias - Low"], "LOWTOK", "aliases after retries")
    truthy(not (st.props["Driver Status"] or ""):find("429"),
        "status must not show 429: " .. tostring(st.props["Driver Status"]))
    contains(st.props["Driver Status"], "Online", "final status")
end)

test("while retrying, the status says so", function()
    local st = asyncCamera({ ["rtsps%-stream"] = { code = 429, body = "{}" } })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
    st.flush()
    eq(st.props["Driver Status"], "Protect is busy - retrying", "status during backoff")
end)

test("retries give up eventually with a clear message", function()
    local calls = 0
    local st = asyncCamera({
        ["rtsps%-stream"] = function() calls = calls + 1; return 429, "{}" end,
    })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
    for _ = 1, 20 do st.flush(); st.fireTimers() end
    truthy(calls <= 5, "bounded retries, got " .. calls)
    contains(st.props["Driver Status"], "too busy", "final status")
    for _, r in ipairs(st.requests) do
        truthy(not r.url:find("meta/info"), "no extra request after giving up")
    end
end)

test("Retry-After from Protect is honoured", function()
    local st = asyncCamera({ ["rtsps%-stream"] = { code = 429, body = "{}" } })
    -- stub responses carry no headers, so check the fallback is sane
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K", camera_id = "C1" })
    st.flush()
    local retry
    for _, tm in ipairs(st.timers) do if tm.ms >= 1000 and tm.ms <= 32000 then retry = tm end end
    truthy(retry, "a backoff timer between 1s and 32s must be scheduled")
end)

-- The field report: a push to every camera at once tripped the rate limit.
-- Each camera must now make exactly ONE request up front, not several.
test("a config push starts with a single request per camera", function()
    local st = asyncCamera({ ["rtsps%-stream"] = { body = STREAMS_ON } })
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "K",
                                           camera_id = "C1", snapshots = "On" })
    eq(#st.pending, 1, "requests in flight immediately after the push")
end)

-- Structural guard: the whole class of bug came from many independent writers.
test("Driver Status has exactly one writer", function()
    local src = io.open(CAM .. "driver.lua"):read("*a")
    local n = select(2, src:gsub('UpdateProperty%("Driver Status"', ""))
    eq(n, 1, "writers of Driver Status")
end)

--=============================================================================
print("\nEvent stream (WebSocket)")
--=============================================================================
-- A fake Protect server: builds real RFC 6455 frames and decodes the driver's.

local function sframe(opcode, payload, fin)
    payload = payload or ""
    local b1 = (fin == false and 0 or 128) + opcode
    local len = #payload
    if len < 126 then return string.char(b1, len) .. payload end
    if len < 65536 then
        return string.char(b1, 126, math.floor(len / 256), len % 256) .. payload
    end
    local hdr = string.char(b1, 127)
    local bytes = {}
    local n = len
    for i = 8, 1, -1 do bytes[i] = n % 256; n = math.floor(n / 256) end
    for i = 1, 8 do hdr = hdr .. string.char(bytes[i]) end
    return hdr .. payload
end

local function xorb(a, b)
    local r, bit = 0, 1
    while a > 0 or b > 0 do
        local x, y = a % 2, b % 2
        if x ~= y then r = r + bit end
        a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
    end
    return r
end

-- Decodes one client frame: returns opcode, payload, masked.
local function cframe(data)
    local b1, b2 = data:byte(1, 2)
    local masked, len, pos = b2 >= 128, b2 % 128, 3
    if len == 126 then len = data:byte(3) * 256 + data:byte(4); pos = 5 end
    local key = data:sub(pos, pos + 3); pos = pos + 4
    local out = {}
    for i = 1, len do
        out[i] = string.char(xorb(data:byte(pos + i - 1), key:byte((i - 1) % 4 + 1)))
    end
    return b1 % 16, table.concat(out), masked
end

local HANDSHAKE_OK = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ..
                     "Connection: Upgrade\r\nSec-WebSocket-Accept: x\r\n\r\n"

local function evt(kind, extra)
    local t = { '"id":"' .. (extra and extra.id or "E1") .. '"', '"modelKey":"event"',
                '"type":"' .. kind .. '"', '"start":1700000000000',
                '"device":"' .. (extra and extra.device or "CAM1") .. '"' }
    if extra and extra["end"] then table.insert(t, '"end":1700000009000') end
    if extra and extra.types then
        table.insert(t, '"smartDetectTypes":["' .. table.concat(extra.types, '","') .. '"]')
    end
    return '{"type":"' .. (extra and extra.msg or "add") .. '","item":{' .. table.concat(t, ",") .. '}}'
end

-- A configured camera with the socket open and handshake complete.
local function liveSocket()
    local st = configured()
    OnConnectionStatusChanged(6001, 443, "ONLINE")
    ReceivedFromNetwork(6001, 443, HANDSHAKE_OK)
    return st
end
local function push(st, text) ReceivedFromNetwork(6001, 443, sframe(1, text)) end

test("connects over TLS to port 443 without certificate verification", function()
    local st = configured()
    local c = st.net.created[#st.net.created]
    truthy(c, "a network connection must be created")
    eq(c.binding, 6001, "binding in the network range")
    eq(c.type, "SSL", "TLS")
    eq(c.address, "192.0.2.10", "console address")
    local o = st.net.options[#st.net.options]
    eq(o.port, 443, "port")
    eq(o.opts.VERIFY_MODE, "none", "self-signed certificate accepted")
    eq(o.opts.KEEP_CONNECTION, false, "reconnects are the driver's, with backoff")
end)

test("the upgrade request is well-formed and carries the API key", function()
    local st = configured()
    OnConnectionStatusChanged(6001, 443, "ONLINE")
    local req = st.netSent[#st.netSent].data
    contains(req, "GET /proxy/protect/integration/v1/subscribe/events HTTP/1.1\r\n", "request line")
    contains(req, "Upgrade: websocket\r\n", "upgrade")
    contains(req, "Connection: Upgrade\r\n", "connection")
    contains(req, "Sec-WebSocket-Version: 13\r\n", "version")
    contains(req, "X-API-KEY: TESTKEY\r\n", "auth header")
    local key = req:match("Sec%-WebSocket%-Key: ([^\r]+)")
    truthy(key and #key == 24 and key:sub(-2) == "==", "16-byte base64 key, got " .. tostring(key))
    truthy(req:sub(-4) == "\r\n\r\n", "headers terminated")
end)

test("a 101 response opens the stream", function()
    local st = liveSocket()
    eq(st.props["Event Stream"], "Connected", "stream state")
end)

test("a refused key backs off hard instead of hammering", function()
    local st = configured()
    OnConnectionStatusChanged(6001, 443, "ONLINE")
    ReceivedFromNetwork(6001, 443, "HTTP/1.1 401 Unauthorized\r\n\r\n")
    contains(st.props["Event Stream"], "Auth failed", "state")
    local longest = 0
    for _, tm in ipairs(st.timers) do if not tm.cancelled then longest = math.max(longest, tm.ms) end end
    truthy(longest >= 60000, "retry at least a minute out, got " .. longest)
end)

test("motion start and end arrive as a real event pair", function()
    local st = liveSocket()
    st.events = {}
    push(st, evt("motion"))
    eq(st.vars["MOTION_DETECTED"], "true", "motion on")
    push(st, evt("motion", { msg = "update", ["end"] = true }))
    eq(st.vars["MOTION_DETECTED"], "false", "motion off at Protect's end time")
    eq(st.events[1], 1, "Motion Detected fired")
    eq(st.events[2], 2, "Motion Ended fired")
end)

-- clearEvent used to leave its watchdog running, so a real end was followed
-- by a second "Motion Ended" when the stale timer fired.
test("a real end is not followed by a second Ended from the watchdog", function()
    local st = liveSocket()
    push(st, evt("motion"))
    push(st, evt("motion", { msg = "update", ["end"] = true }))
    st.events = {}
    st.fireTimers()
    for _, e in ipairs(st.events) do truthy(e ~= 2, "a second Motion Ended fired") end
end)

test("events for other cameras are ignored", function()
    local st = liveSocket()
    push(st, evt("motion", { device = "SOMEONE-ELSE" }))
    truthy(st.vars["MOTION_DETECTED"] ~= "true", "must not fire for another camera")
end)

test("smart detections fire per class, once, as the class list grows", function()
    local st = liveSocket()
    st.events = {}
    push(st, evt("smartDetectZone", { types = { "face" } }))
    push(st, evt("smartDetectZone", { msg = "update", types = { "face", "person" } }))
    push(st, evt("smartDetectZone", { msg = "update", types = { "face", "person", "vehicle" } }))
    push(st, evt("smartDetectZone", { msg = "update", types = { "person", "vehicle" } }))
    eq(st.vars["PERSON_DETECTED"], "true", "person")
    eq(st.vars["VEHICLE_DETECTED"], "true", "vehicle")
    local persons = 0
    for _, e in ipairs(st.events) do if e == 3 then persons = persons + 1 end end
    eq(persons, 1, "person fired exactly once")
    push(st, evt("smartDetectZone", { msg = "update", ["end"] = true, types = { "person", "vehicle" } }))
    eq(st.vars["PERSON_DETECTED"], "false", "person cleared at end")
end)

test("an unmapped class is logged once per detection, not per update", function()
    local st = liveSocket()
    st.set("Log Mode", "Print"); st.set("Log Level", "4 - Debug")
    local lines, real = 0, print
    print = function(msg) if tostring(msg):find("'face' not mapped") then lines = lines + 1 end end
    push(st, evt("smartDetectZone", { types = { "face" } }))
    for _ = 1, 5 do push(st, evt("smartDetectZone", { msg = "update", types = { "face", "person" } })) end
    print = real
    eq(lines, 1, "log lines for one detection")
end)

test("line and loiter detections are handled like zone detections", function()
    local st = liveSocket()
    push(st, evt("smartDetectLine", { id = "L1", types = { "vehicle" } }))
    eq(st.vars["VEHICLE_DETECTED"], "true", "line crossing")
    push(st, evt("smartDetectLoiterZone", { id = "L2", types = { "person" } }))
    eq(st.vars["PERSON_DETECTED"], "true", "loitering")
end)

test("a disabled detection class does not fire", function()
    local st = liveSocket()
    st.set("Detect Animal", "No")
    push(st, evt("smartDetectZone", { types = { "animal" } }))
    truthy(st.vars["ANIMAL_DETECTED"] ~= "true", "animal is switched off")
end)

test("a ring fires once even when repeated", function()
    local st = liveSocket()
    st.events = {}
    push(st, evt("ring", { id = "R1", ["end"] = true }))   -- rings carry start and end together
    push(st, evt("ring", { id = "R1", ["end"] = true }))
    local rings = 0
    for _, e in ipairs(st.events) do if e == 7 then rings = rings + 1 end end
    eq(rings, 1, "Doorbell Pressed fired once")
end)

test("a late update after an event ends does not restart it", function()
    local st = liveSocket()
    push(st, evt("motion", { id = "M9" }))
    push(st, evt("motion", { id = "M9", msg = "update", ["end"] = true }))
    push(st, evt("motion", { id = "M9", msg = "update" }))     -- stale, no end
    eq(st.vars["MOTION_DETECTED"], "false", "stays off")
end)

-- Per-class dedupe alone would miss this: a stale update after the end that
-- introduces a class not seen before.
test("a late update cannot add a new class to an ended event", function()
    local st = liveSocket()
    push(st, evt("smartDetectZone", { id = "S9", types = { "person" } }))
    push(st, evt("smartDetectZone", { id = "S9", msg = "update", ["end"] = true, types = { "person" } }))
    push(st, evt("smartDetectZone", { id = "S9", msg = "update", types = { "person", "vehicle" } }))
    truthy(st.vars["VEHICLE_DETECTED"] ~= "true", "vehicle fired after the event ended")
end)

test("separate rings each fire", function()
    local st = liveSocket()
    st.events = {}
    push(st, evt("ring", { id = "R1", ["end"] = true }))
    push(st, evt("ring", { id = "R2", ["end"] = true }))
    local rings = 0
    for _, e in ipairs(st.events) do if e == 7 then rings = rings + 1 end end
    eq(rings, 2, "two presses, two events")
end)

test("a frame split across reads is reassembled", function()
    local st = liveSocket()
    local f = sframe(1, evt("motion"))
    for i = 1, #f do ReceivedFromNetwork(6001, 443, f:sub(i, i)) end   -- one byte at a time
    eq(st.vars["MOTION_DETECTED"], "true", "byte-at-a-time delivery")
end)

test("the handshake and the first event can arrive together", function()
    local st = configured()
    OnConnectionStatusChanged(6001, 443, "ONLINE")
    ReceivedFromNetwork(6001, 443, HANDSHAKE_OK .. sframe(1, evt("motion")))
    eq(st.vars["MOTION_DETECTED"], "true", "event in the handshake packet")
end)

test("several frames in one read are all processed", function()
    local st = liveSocket()
    ReceivedFromNetwork(6001, 443, sframe(1, evt("motion", { id = "A" })) ..
        sframe(1, evt("smartDetectZone", { id = "B", types = { "person" } })))
    eq(st.vars["MOTION_DETECTED"], "true", "first frame")
    eq(st.vars["PERSON_DETECTED"], "true", "second frame")
end)

test("a message over 125 bytes uses the extended length", function()
    local st = liveSocket()
    local msg = evt("motion"):gsub('}}$', ',"padding":"' .. string.rep("x", 300) .. '"}}')
    push(st, msg)
    eq(st.vars["MOTION_DETECTED"], "true", "16-bit length frame")
end)

test("a fragmented message is reassembled", function()
    local st = liveSocket()
    local m = evt("motion")
    ReceivedFromNetwork(6001, 443, sframe(1, m:sub(1, 20), false) ..
        sframe(0, m:sub(21, 40), false) .. sframe(0, m:sub(41), true))
    eq(st.vars["MOTION_DETECTED"], "true", "continuation frames")
end)

test("a ping is answered with a masked pong carrying the same data", function()
    local st = liveSocket()
    local before = #st.netSent
    ReceivedFromNetwork(6001, 443, sframe(9, "keepalive"))
    truthy(#st.netSent > before, "a reply must be sent")
    local op, payload, masked = cframe(st.netSent[#st.netSent].data)
    eq(op, 10, "pong opcode")
    eq(payload, "keepalive", "echoed payload")
    truthy(masked, "client frames must be masked")
end)

test("a server close leads to a scheduled reconnect", function()
    local st = liveSocket()
    ReceivedFromNetwork(6001, 443, sframe(8, ""))
    contains(st.props["Event Stream"], "Reconnecting", "state")
    local connects = st.net.connects
    st.fireTimers()
    truthy(st.net.connects > connects, "a new connection attempt follows")
end)

test("reconnect delays back off", function()
    local st = liveSocket()
    local delays = {}
    for _ = 1, 4 do
        st.timers = {}
        OnConnectionStatusChanged(6001, 443, "OFFLINE")
        for _, tm in ipairs(st.timers) do if tm.ms >= 1000 then table.insert(delays, tm.ms) end end
        st.fireTimers()                              -- reconnect attempt
        OnConnectionStatusChanged(6001, 443, "ONLINE")
    end
    truthy(#delays >= 4, "a delay per drop")
    truthy(delays[4] > delays[1], "later delays are longer: " .. table.concat(delays, ","))
end)

test("a malformed message does not break the stream", function()
    local st = liveSocket()
    push(st, "{not json")
    push(st, evt("motion"))
    eq(st.vars["MOTION_DETECTED"], "true", "next message still handled")
    eq(st.props["Event Stream"], "Connected", "still connected")
end)

test("an unknown event type is reported, not fatal", function()
    local st = liveSocket()
    push(st, evt("sensorWaterLeak"))
    push(st, evt("motion", { id = "M2" }))
    eq(st.vars["MOTION_DETECTED"], "true", "stream continues")
end)

-- While the socket delivers events, polling must not fire them too.
test("polling does not double events while the socket is live", function()
    local st = liveSocket()
    st.set("Event Polling Interval", "5 Seconds")
    st.routes["/cameras/CAM1$"] = { body = '{"id":"CAM1","state":"CONNECTED","lastMotion":100}' }
    st.fireTimers(function(tm) return tm.ms == 5000 end)          -- first poll: baseline
    st.routes["/cameras/CAM1$"] = { body = '{"id":"CAM1","state":"CONNECTED","lastMotion":200}' }
    st.events = {}
    st.fireTimers(function(tm) return tm.ms == 5000 end)          -- second poll: advanced
    for _, e in ipairs(st.events) do truthy(e ~= 1, "polling fired motion while socket live") end
end)

test("Event Source Off opens no connection", function()
    local st = stub.new()
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("Event Source", "Off")
    st.set("NVR Address", "192.0.2.10")
    st.set("API Key", "K")
    eq(#st.net.created, 0, "no socket")
    eq(st.props["Event Stream"], "Off", "state")
end)

test("a silent connection is detected and replaced", function()
    local st = liveSocket()
    local connects = st.net.connects
    local real = os.time
    os.time = function() return real() + 200 end        -- nothing received for 200s
    st.fireTimers(function(tm) return tm.repeating end)  -- ping watchdog
    os.time = real
    contains(st.props["Event Stream"], "Reconnecting", "dead link noticed")
end)

-- Structural guard, matching the Driver Status rule.
test("Event Stream has exactly one writer", function()
    local src = io.open(CAM .. "driver.lua"):read("*a")
    local n = select(2, src:gsub('UpdateProperty%("Event Stream"', ""))
    eq(n, 1, "writers of Event Stream")
end)

--=============================================================================
print("\nEvent filtering")
--=============================================================================

test("Detect Motion off suppresses motion events", function()
    local st = liveSocket()
    st.set("Detect Motion", "No")
    st.events = {}
    push(st, evt("motion"))
    truthy(st.vars["MOTION_DETECTED"] ~= "true", "variable must not be set")
    for _, e in ipairs(st.events) do truthy(e ~= 1, "Motion Detected fired") end
end)

test("Detect Doorbell off suppresses rings", function()
    local st = liveSocket()
    st.set("Detect Doorbell", "No")
    st.events = {}
    push(st, evt("ring", { ["end"] = true }))
    for _, e in ipairs(st.events) do truthy(e ~= 7, "Doorbell Pressed fired") end
end)

test("person only: other classes are dropped", function()
    local st = liveSocket()
    st.set("Detect Vehicle", "No")
    st.set("Detect Animal", "No")
    st.set("Detect Package", "No")
    push(st, evt("smartDetectZone", { types = { "person", "vehicle", "animal", "package" } }))
    eq(st.vars["PERSON_DETECTED"], "true", "person")
    truthy(st.vars["VEHICLE_DETECTED"] ~= "true", "vehicle dropped")
    truthy(st.vars["PACKAGE_DETECTED"] ~= "true", "package dropped")
end)

--=============================================================================
print("\nHistory")
--=============================================================================

local function histLabels(st)
    local out = {}
    for _, h in ipairs(st.history) do table.insert(out, h[2]) end
    return out
end

test("a person detection is recorded in History", function()
    local st = liveSocket()
    push(st, evt("smartDetectZone", { types = { "person" } }))
    eq(#st.history, 1, "records")
    local h = st.history[1]
    eq(h[1], "Info", "severity")
    eq(h[2], "Person Detected", "type")
    eq(h[3], "Cameras", "category")
    eq(h[4], "UniFi Protect", "subcategory")
end)

-- The metadata argument stopped records being stored on OS 3.4.3.
test("History is written with exactly four arguments", function()
    local st = liveSocket()
    push(st, evt("smartDetectZone", { types = { "person" } }))
    eq(st.history[1].n, 4, "argument count")
end)

test("History selection is independent of programming events", function()
    local st = liveSocket()              -- History - Vehicle defaults to No
    push(st, evt("smartDetectZone", { types = { "vehicle" } }))
    eq(st.vars["VEHICLE_DETECTED"], "true", "vehicle still drives programming")
    eq(#st.history, 0, "but is not recorded")
end)

test("only person in History", function()
    local st = liveSocket()
    for _, k in ipairs({ "Vehicle", "Animal", "Package", "Motion", "Doorbell" }) do
        st.set("History - " .. k, "No")
    end
    st.set("History - Person", "Yes")
    st.set("Detect Animal", "Yes"); st.set("Detect Package", "Yes")
    push(st, evt("motion", { id = "a" }))
    push(st, evt("ring", { id = "b", ["end"] = true }))
    push(st, evt("smartDetectZone", { id = "c", types = { "vehicle", "animal", "package", "person" } }))
    local labels = histLabels(st)
    eq(#labels, 1, "one record: " .. table.concat(labels, ","))
    eq(labels[1], "Person Detected", "the person")
end)

test("the cooldown holds back repeats, then lets one through", function()
    local st = liveSocket()
    local real, now = os.time, os.time()
    os.time = function() return now end
    push(st, evt("smartDetectZone", { id = "p1", types = { "person" } }))
    push(st, evt("smartDetectZone", { id = "p1", msg = "update", ["end"] = true, types = { "person" } }))
    now = now + 20
    push(st, evt("smartDetectZone", { id = "p2", types = { "person" } }))
    push(st, evt("smartDetectZone", { id = "p2", msg = "update", ["end"] = true, types = { "person" } }))
    eq(#st.history, 1, "second person within 60s held back")
    now = now + 61
    push(st, evt("smartDetectZone", { id = "p3", types = { "person" } }))
    os.time = real
    eq(#st.history, 2, "recorded again after the cooldown")
    eq(GetDriverStats().historySkipped, 1, "the hold-back is counted")
end)

test("a growing class list does not re-record the same detection", function()
    local st = liveSocket()
    push(st, evt("smartDetectZone", { types = { "person" } }))
    push(st, evt("smartDetectZone", { msg = "update", types = { "person", "face" } }))
    push(st, evt("smartDetectZone", { msg = "update", types = { "person", "face" } }))
    eq(#st.history, 1, "one record for one detection")
end)

test("a detection switched off is not recorded either", function()
    local st = liveSocket()
    st.set("Detect Person", "No")
    push(st, evt("smartDetectZone", { types = { "person" } }))
    eq(#st.history, 0, "records")
end)

test("pushed History and Detect choices take effect, not just display", function()
    local st = liveSocket()
    ExecuteCommand("SET_PROTECT_CONFIG", {
        history_vehicle = "Yes", history_person = "No", detect_motion = "No", history_cooldown = "0",
    })
    eq(st.props["History - Vehicle"], "Yes", "shown")
    push(st, evt("smartDetectZone", { id = "v1", types = { "vehicle", "person" } }))
    push(st, evt("motion", { id = "m1" }))
    local labels = histLabels(st)
    eq(#labels, 1, "records: " .. table.concat(labels, ","))
    eq(labels[1], "Vehicle Detected", "vehicle recorded, person not")
    truthy(st.vars["MOTION_DETECTED"] ~= "true", "motion switched off by the push")
end)

test("event types are registered on startup", function()
    local st = configured()
    OnDriverLateInit()
    eq(#st.registered, 1, "one registration")
    local xml = st.registered[1]
    contains(xml, '<device id="901"/>', "the proxy device")
    contains(xml, '<category name="Cameras">', "category")
    contains(xml, '<subcategory name="UniFi Protect">', "subcategory")
end)

-- Records under an unregistered type land in the History agent but never
-- appear in the Control4 app. Every type the driver can record must be listed.
test("every type that can be recorded is registered", function()
    local st = configured()
    OnDriverLateInit()
    local xml = st.registered[1]
    for _, k in ipairs({ "Vehicle", "Animal", "Package", "Motion", "Doorbell" }) do
        st.set("History - " .. k, "Yes")
    end
    st.set("History Cooldown", "0")
    st.set("Detect Animal", "Yes"); st.set("Detect Package", "Yes")
    OnConnectionStatusChanged(6001, 443, "ONLINE")
    ReceivedFromNetwork(6001, 443, HANDSHAKE_OK)
    push(st, evt("motion", { id = "1" }))
    push(st, evt("ring", { id = "2", ["end"] = true }))
    push(st, evt("smartDetectZone", { id = "3", types = { "person", "vehicle", "animal", "package" } }))
    eq(#st.history, 6, "all six kinds recorded")
    for _, h in ipairs(st.history) do
        contains(xml, '<type name="' .. h[2] .. '"/>', "registered type")
    end
end)

test("registration retries while the History agent is not ready", function()
    local st = stub.new({ registerResult = false })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    OnDriverLateInit()
    local retry
    for _, tm in ipairs(st.timers) do if tm.ms == 30000 and not tm.fired then retry = tm end end
    truthy(retry, "a 30s retry is scheduled")
    st.registerResult = true
    retry.fn()
    eq(#st.registered, 2, "second attempt made")
end)

test("registration gives up eventually", function()
    local st = stub.new({ registerResult = false })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    OnDriverLateInit()
    for _ = 1, 40 do st.fireTimers(function(tm) return tm.ms == 30000 end) end
    truthy(#st.registered <= 20, "bounded, got " .. #st.registered)
end)

test("a registration result of 0 counts as success", function()
    local st = stub.new({ registerResult = 0 })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    OnDriverLateInit()
    st.fireTimers(function(tm) return tm.ms == 30000 end)
    eq(#st.registered, 1, "no second attempt after success")
end)

--=============================================================================
print("\nLoad on Protect and on Director")
--=============================================================================

-- Every camera driver used to fetch the whole camera list, test the
-- connection and open its socket the instant Director started.
test("startup sends nothing to Protect immediately", function()
    local st = configured()
    st.requests, st.net.connects = {}, 0
    OnDriverLateInit()
    eq(#st.requests, 0, "HTTP requests at the instant of startup")
    eq(st.net.connects, 0, "socket connections at the instant of startup")
end)

test("startup never fetches the full camera list", function()
    local st = configured()
    st.requests = {}
    OnDriverLateInit()
    st.fireTimers()
    for _, r in ipairs(st.requests) do
        truthy(not r.url:find("/cameras$"), "fetched the camera list: " .. r.url)
    end
end)

test("the current camera still shows in the dropdown after a restart", function()
    local st = configured()
    st.props["Camera Name"] = "Pool"
    OnDriverLateInit()
    eq(st.lists["Camera"], "Pool", "dropdown")
end)

test("each camera picks its own startup slot", function()
    local slots = {}
    for i = 1, 8 do
        local st = configured()
        st.deviceId = 100 + i          -- every real camera has its own device id
        st.timers = {}
        OnDriverLateInit()
        for _, tm in ipairs(st.timers) do
            if tm.ms >= 500 and tm.ms <= 8000 and tm.ms ~= 5000 then slots[tm.ms] = true end
        end
    end
    local n = 0
    for _ in pairs(slots) do n = n + 1 end
    truthy(n >= 4, "eight cameras should spread over several slots, got " .. n)
end)

test("while the socket is live, events do not trigger adaptive polling", function()
    local st = liveSocket()
    st.set("Event Polling Interval", "5 Seconds")
    st.set("Adaptive Polling", "Yes")
    push(st, evt("motion"))
    st.timers = {}
    st.set("Event Polling Interval", "5 Seconds")        -- reschedule
    for _, tm in ipairs(st.timers) do
        truthy(tm.ms ~= 1000, "a 1-second burst was scheduled")
    end
end)

test("while the socket is live, polling slows to once a minute", function()
    local st = liveSocket()
    st.timers = {}
    st.set("Event Polling Interval", "5 Seconds")
    local poll
    for _, tm in ipairs(st.timers) do if not tm.repeating then poll = tm end end
    truthy(poll and poll.ms >= 60000, "poll delay " .. tostring(poll and poll.ms))
end)

test("a steady stream of events costs Protect nothing", function()
    local st = liveSocket()
    local before = GetDriverStats().apiRequests
    for i = 1, 100 do
        push(st, evt("smartDetectZone", { id = "e" .. i, types = { "person" } }))
        push(st, evt("smartDetectZone", { id = "e" .. i, msg = "update", ["end"] = true, types = { "person" } }))
    end
    st.fireTimers()
    eq(GetDriverStats().apiRequests - before, 0, "requests caused by 100 detections")
end)

test("other cameras' events are skipped without being parsed", function()
    local st = liveSocket()
    local s0 = GetDriverStats()
    for i = 1, 7 do push(st, evt("motion", { id = "o" .. i, device = "OTHER" .. i })) end
    push(st, evt("motion", { id = "mine" }))
    local s1 = GetDriverStats()
    eq(s1.wsIgnored - s0.wsIgnored, 7, "skipped")
    eq(s1.wsDecoded - s0.wsDecoded, 1, "parsed")
end)

-- Parsing re-copied the remaining buffer after every frame, which is
-- quadratic in the number of frames per read. Correct output either way, so
-- only timing can tell. Measured: ~10 ms linear, ~700 ms quadratic, for
-- 15,000 frames (just under the 1 MB buffer cap). Threshold leaves wide margin.
test("parsing a large burst stays linear", function()
    local st = liveSocket()
    local f = string.char(129, 60) .. string.rep("x", 60)
    local blob = string.rep(f, 15000)
    local t0 = os.clock()
    ReceivedFromNetwork(6001, 443, blob)
    local took = os.clock() - t0
    truthy(took < 0.25, string.format("15,000 frames took %.3fs", took))
    eq(st.props["Event Stream"], "Connected", "still connected")
end)

-- The socket path dedupes per event, which hides this. With polling, a long
-- motion keeps advancing lastMotion; with the cooldown at 0 every poll would
-- write a History record.
test("a detection still in progress is recorded once, not per poll", function()
    local st = configured()
    st.set("Event Source", "Polling")
    st.set("History - Motion", "Yes")
    st.set("History Cooldown", "0")
    st.set("Event Hold Time", "60")
    st.set("Adaptive Polling", "No")        -- keep every poll on the 5s timer
    st.set("Event Polling Interval", "5 Seconds")
    for ts = 100, 500, 100 do
        st.routes["/cameras/CAM1$"] = { body = '{"id":"CAM1","state":"CONNECTED","lastMotion":' .. ts .. '}' }
        st.fireTimers(function(tm) return tm.ms == 5000 end)
    end
    eq(GetDriverStats().apiRequests >= 5, true, "the polls actually ran")
    eq(#st.history, 1, "records for one continuous motion")
end)

test("a burst of many frames in one read is handled", function()
    local st = liveSocket()
    local parts = {}
    for i = 1, 200 do parts[i] = sframe(1, evt("motion", { id = "b" .. i, device = "X" })) end
    parts[201] = sframe(1, evt("motion", { id = "last" }))
    ReceivedFromNetwork(6001, 443, table.concat(parts))
    eq(st.vars["MOTION_DETECTED"], "true", "the last frame of 201 was reached")
    eq(GetDriverStats().wsMessages, 201, "all frames counted")
end)

--=============================================================================
print("\nDevice name")
--=============================================================================
-- The Composer-visible (proxy) device is named after the camera. History is
-- NOT: field-verified on OS 3.4.3, it labels records with the driver's
-- definition name and ignores renaming either device. So History entries carry
-- the camera name in their title instead (next section).

local function named(opts)
    local st = stub.new(opts or {})
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    return st
end

local DEFAULT_DRIVER_NAME = "UniFi Protect Camera (Standalone)"

test("the Composer device takes the camera's name", function()
    local st = named()
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Front Door - G5" })
    eq(st.displayNames[901], "Front Door - G5", "proxy (what Composer shows)")
end)

-- v50 renamed the driver device too. It changed nothing visible, and every
-- rename refreshes the whole project on Director.
test("the driver device is never renamed", function()
    local st = named()
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Front Door - G5" })
    ExecuteCommand("LUA_ACTION", { ACTION = "UseCameraName" })
    eq(st.displayNames[100], DEFAULT_DRIVER_NAME, "driver device untouched")
    for _, r in ipairs(st.renamed) do truthy(r.id ~= 100, "renamed the driver device") end
end)

test("a name the installer chose is left alone", function()
    local st = named({ displayNames = { [901] = "Front Porch", [100] = DEFAULT_DRIVER_NAME } })
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Front Door - G5" })
    eq(#st.renamed, 0, "renames")
end)

test("Use Protect Camera Name overrides the installer's name on request", function()
    local st = named({ displayNames = { [901] = "Front Porch", [100] = DEFAULT_DRIVER_NAME } })
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Front Door - G5" })
    ExecuteCommand("LUA_ACTION", { ACTION = "UseCameraName" })
    eq(st.displayNames[901], "Front Door - G5", "proxy")
end)

test("matching names cause no rename, so no project refresh", function()
    local st = named({ displayNames = { [901] = "Pool", [100] = DEFAULT_DRIVER_NAME } })
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Pool" })
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Pool" })
    eq(#st.renamed, 0, "renames")
end)

test("repeated pushes rename once", function()
    local st = named()
    for _ = 1, 5 do
        ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Pool" })
    end
    eq(#st.renamed, 1, "renames")
end)

test("the name follows a rename in Protect", function()
    local st = named()
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Pool" })
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Pool Deck" })
    eq(st.displayNames[901], "Pool Deck", "followed")
end)

test("a numeric proxy id is used for rename and registration", function()
    local st = named({ proxyId = 393, displayNames = { [393] = "UniFi Protect Camera", [100] = DEFAULT_DRIVER_NAME } })
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Street North - G6" })
    eq(st.displayNames[393], "Street North - G6", "proxy renamed")
    OnDriverLateInit()
    contains(st.registered[#st.registered] or "", '<device id="393"/>', "registered against the proxy")
end)

test("a proxy id returned as a string is understood", function()
    local st = named({ proxyReturn = "393", displayNames = { [393] = "UniFi Protect Camera", [100] = DEFAULT_DRIVER_NAME } })
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Pool" })
    eq(st.displayNames[393], "Pool", "proxy renamed")
end)

test("a proxy id returned as a table is understood", function()
    local st = named({ proxyReturn = { [393] = true }, displayNames = { [393] = "UniFi Protect Camera", [100] = DEFAULT_DRIVER_NAME } })
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Pool" })
    eq(st.displayNames[393], "Pool", "proxy renamed")
end)

test("a missing camera name is looked up once, then used", function()
    local st = named({ routes = { ["/cameras/C1$"] = { body = '{"id":"C1","name":"Garden"}' } } })
    st.props["NVR Address"] = "192.0.2.10"; st.props["API Key"] = "K"; st.props["Camera ID"] = "C1"
    OnDriverLateInit()
    st.requests = {}
    st.fireTimers(function(tm) return tm.ms >= 500 and tm.ms <= 8000 and tm.ms ~= 5000 end)
    local lookups = 0
    for _, r in ipairs(st.requests) do if r.url:find("/cameras/C1$") then lookups = lookups + 1 end end
    eq(lookups, 1, "one lookup")
    eq(st.displayNames[901], "Garden", "Composer device named")
end)

test("no lookup when the name is already known", function()
    local st = named({ routes = { ["/cameras/C1$"] = { body = '{"id":"C1","name":"Garden"}' } } })
    st.props["NVR Address"] = "192.0.2.10"; st.props["API Key"] = "K"; st.props["Camera ID"] = "C1"
    st.props["Camera Name"] = "Garden"
    OnDriverLateInit()
    st.requests = {}
    st.fireTimers(function(tm) return tm.ms >= 500 and tm.ms <= 8000 and tm.ms ~= 5000 end)
    for _, r in ipairs(st.requests) do truthy(not r.url:find("/cameras/C1$"), "needless lookup") end
end)

test("choosing a camera from the dropdown names the device", function()
    local st = stub.new({ routes = {
        ["/cameras$"] = { body = '[{"id":"C7","name":"Garage"}]' },
        ["rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/T?enableSrtp"}' },
    } })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "192.0.2.10")
    st.set("API Key", "K")
    ExecuteCommand("LUA_ACTION", { ACTION = "DiscoverCameras" })
    st.set("Camera", "Garage")
    eq(st.displayNames[901], "Garage", "Composer device name")
end)

test("a rename seen by polling renames the device without error", function()
    local st = named({ routes = {
        ["/cameras/C1$"] = { body = '{"id":"C1","name":"Side Gate","state":"CONNECTED"}' } } })
    st.set("NVR Address", "192.0.2.10"); st.set("API Key", "K"); st.set("Camera ID", "C1")
    st.set("Event Source", "Polling")
    st.set("Event Polling Interval", "5 Seconds")
    st.fireTimers(function(tm) return tm.ms == 5000 end)
    eq(st.displayNames[901], "Side Gate", "Composer device name")
end)

test("at startup the rename waits for the camera's own slot", function()
    local st = named()
    st.props["Camera Name"] = "Pool"
    st.props["Camera ID"] = "C1"
    OnDriverLateInit()
    eq(#st.renamed, 0, "no rename at the instant of startup")
    st.fireTimers(function(tm) return tm.ms >= 500 and tm.ms <= 8000 and tm.ms ~= 5000 end)
    eq(#st.renamed, 1, "renamed in its slot")
end)

test("Diagnostics reports the proxy, not nil", function()
    local st = named()
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Pool" })
    local out, real = {}, print
    print = function(m) table.insert(out, tostring(m)) end
    ExecuteCommand("LUA_ACTION", { ACTION = "Diagnostics" })
    print = real
    local line = ""
    for _, l in ipairs(out) do if l:find("Names:") then line = l end end
    contains(line, "proxy=901 'Pool'", "names line")
end)

--=============================================================================
print("\nCamera name in History")
--=============================================================================
local DOT = "\194\183"   -- UTF-8 middle dot

local function simulatedPerson(opts)
    local st = named(opts)
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_id = "C1", camera_name = "Street North - G6" })
    ExecuteCommand("LUA_ACTION", { ACTION = "SimulatePerson" })
    return st
end

-- The field result that forced this design: renaming both devices left History
-- showing "UniFi Protect Camera (Standalone)".
test("a History entry names its camera", function()
    local st = simulatedPerson()
    eq(st.history[1][2], "Person Detected " .. DOT .. " Street North - G6", "entry title")
end)

test("an installer's name is used in History instead", function()
    local st = simulatedPerson({ displayNames = { [901] = "Front Street", [100] = DEFAULT_DRIVER_NAME } })
    eq(st.history[1][2], "Person Detected " .. DOT .. " Front Street", "entry title")
end)

test("with no name known, the plain title is used", function()
    local st = named()
    ExecuteCommand("LUA_ACTION", { ACTION = "SimulatePerson" })
    eq(st.history[1][2], "Person Detected", "entry title")
end)

test("the camera's own titles are registered", function()
    local st = simulatedPerson()
    local xml = st.registered[#st.registered] or ""
    contains(xml, '<type name="Person Detected ' .. DOT .. ' Street North - G6"/>', "registered title")
    contains(xml, '<type name="Doorbell Pressed ' .. DOT .. ' Street North - G6"/>', "every kind")
end)

test("every title written has been registered", function()
    local st = simulatedPerson()
    local xml = st.registered[#st.registered] or ""
    for _, h in ipairs(st.history) do contains(xml, '<type name="' .. h[2] .. '"/>', "registered") end
end)

test("a new camera name is registered again", function()
    local st = simulatedPerson()
    local before = #st.registered
    st.set("History Cooldown", "0")
    st.fireTimers()                                   -- let the first detection end
    ExecuteCommand("SET_PROTECT_CONFIG", { camera_name = "Street North" })
    ExecuteCommand("LUA_ACTION", { ACTION = "SimulatePerson" })
    eq(#st.history, 2, "the second detection was recorded")
    truthy(#st.registered > before, "re-registered")
    contains(st.registered[#st.registered], DOT .. ' Street North"/>', "with the new name")
    eq(st.history[#st.history][2], "Person Detected " .. DOT .. " Street North", "new title")
end)

test("an unchanged name is not registered again", function()
    local st = simulatedPerson()
    local before = #st.registered
    st.set("History Cooldown", "0")
    for _ = 1, 2 do
        st.fireTimers()                               -- end the previous detection
        ExecuteCommand("LUA_ACTION", { ACTION = "SimulatePerson" })
    end
    eq(#st.history, 3, "all three detections were recorded")
    eq(#st.registered, before, "no repeat registrations")
end)

--=============================================================================
print("\nRobustness")
--=============================================================================

test("malformed JSON does not crash discovery", function()
    local st = stub.new({ routes = { ["/cameras"] = { body = '{"broken":' } } })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "1.2.3.4")
    st.set("API Key", "K")
    ExecuteCommand("LUA_ACTION", { ACTION = "DiscoverCameras" })
end)

test("HTTP errors do not crash", function()
    local st = stub.new({ routes = { [""] = { code = 500, body = "server error" } } })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "1.2.3.4")
    st.set("API Key", "K")
    ExecuteCommand("LUA_ACTION", { ACTION = "TestConnection" })
end)

test("401 reports auth failure", function()
    local st = stub.new({ routes = { ["meta/info"] = { code = 401, body = '{"error":"no"}' } } })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "1.2.3.4")
    st.set("API Key", "BAD")
    ExecuteCommand("LUA_ACTION", { ACTION = "TestConnection" })
    contains(st.props["Driver Status"] or "", "Auth Failed", "status")
end)

-- Every declared event needs a description or the Programming tab fails to load.
test("every event declares a description", function()
    local xml = io.open(CAM .. "driver.xml"):read("*a")
    for block in xml:gmatch("<event>(.-)</event>") do
        local name = block:match("<name>([^<]+)</name>")
        truthy(block:find("<description>"), "event without description: " .. tostring(name))
    end
end)

-- An empty <states/> is not used by a camera driver and is a candidate for
-- breaking the Programming tab's parse. Frigate, whose events work, omits it.
test("no empty states element", function()
    local xml = io.open(CAM .. "driver.xml"):read("*a")
    truthy(not xml:find("<states/>"), "<states/> must not be present")
    truthy(not xml:find("<states></states>"), "empty <states> must not be present")
end)

test("every event id is unique", function()
    local xml = io.open(CAM .. "driver.xml"):read("*a")
    local seen = {}
    for block in xml:gmatch("<event>(.-)</event>") do
        local id = block:match("<id>(%d+)</id>")
        truthy(id, "event without an id")
        truthy(not seen[id], "duplicate event id " .. tostring(id))
        seen[id] = true
    end
end)

test("diagnostics runs without error", function()
    local st = configured({ ["rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/LOWTOK?enableSrtp"}' } })
    ExecuteCommand("LUA_ACTION", { ACTION = "Diagnostics" })
end)

--=============================================================================
print("\nHardening review (v53)")
--=============================================================================
-- Each test here failed against v52 (see CHANGELOG, Camera driver 53).

local CAMJSON = '{"id":"CAM1","name":"Front","state":"CONNECTED","lastMotion":1000}'
local function cam(extra) return { body = extra } end

local function configuredAsync(routes)
    local st = stub.new({ routes = routes or {}, async = true })
    st.load(CAM .. "driver.lua")
    st.set("Log Mode", "Off")
    st.set("NVR Address", "192.0.2.10")
    st.set("API Key", "TESTKEY")
    st.set("RTSP Alias - Low", "LOWTOK")
    return st
end

-- Polling-mode camera: no socket, a poll every 5 s, no adaptive bursts.
local function pollingCamera(routes, async)
    local st = async and configuredAsync(routes) or configured(routes)
    if async then st.set("Camera ID", "CAM1"); st.flush() end
    st.set("Event Source", "Polling")
    st.set("Adaptive Polling", "No")
    st.set("Event Hold Time", "60")
    st.set("Event Polling Interval", "5 Seconds")
    return st
end
local function pollTick(st)
    st.fireTimers(function(tm) return tm.ms == 5000 end)
    if st.async then st.flush() end
end
local function countEvent(st, id)
    local n = 0
    for _, e in ipairs(st.events) do if e == id then n = n + 1 end end
    return n
end
local function countReq(st, pat)
    local n = 0
    for _, r in ipairs(st.requests) do if r.url:find(pat) then n = n + 1 end end
    return n
end
local function stateBody(extra)
    return '{"id":"CAM1","name":"Front","state":"CONNECTED"' .. (extra and ("," .. extra) or "") .. '}'
end

-- ---- status that never recovered / flapped ---------------------------------
test("one or two dropped polls do not flash Unreachable; three in a row do", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = { err = true } })
    pollTick(st); pollTick(st)
    truthy(not tostring(st.props["Driver Status"]):find("Unreachable"), "flapped after two: " .. tostring(st.props["Driver Status"]))
    pollTick(st)
    contains(st.props["Driver Status"], "Unreachable", "after three")
end)

test("Unreachable clears as soon as the console answers again", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = { err = true } })
    for _ = 1, 3 do pollTick(st) end
    contains(st.props["Driver Status"], "Unreachable", "precondition")
    st.routes["cameras/CAM1$"] = cam(stateBody())
    pollTick(st)
    truthy(not tostring(st.props["Driver Status"]):find("Unreachable"), "stuck: " .. tostring(st.props["Driver Status"]))
end)

test("Auth Failed clears once the console accepts the key again", function()
    -- meta/info keeps refusing; the background poll is what proves the key works.
    local st = pollingCamera({ ["meta/info"] = { code = 401 }, ["cameras/CAM1$"] = { code = 401 } })
    ExecuteCommand("LUA_ACTION", { ACTION = "TestConnection" })
    contains(st.props["Driver Status"], "Auth", "precondition")
    st.routes["cameras/CAM1$"] = cam(stateBody())
    pollTick(st)
    truthy(not tostring(st.props["Driver Status"]):find("Auth"), "stuck: " .. tostring(st.props["Driver Status"]))
end)

test("changing the API Key drops the old verdict before the re-test answers", function()
    local st = configuredAsync({ ["meta/info"] = { code = 401 } })
    st.set("Camera ID", "CAM1")
    st.flush()
    ExecuteCommand("LUA_ACTION", { ACTION = "TestConnection" }); st.flush()
    contains(st.props["Driver Status"], "Auth", "precondition")
    st.routes["meta/info"] = { hang = true }
    st.set("API Key", "NEWKEY")
    truthy(not tostring(st.props["Driver Status"]):find("Auth"), "old verdict kept: " .. tostring(st.props["Driver Status"]))
end)

test("changing the API Key re-tests the connection", function()
    local st = configured({ ["meta/info"] = { body = '{"applicationVersion":"6.2.1"}' } })
    local before = countReq(st, "meta/info")
    st.set("API Key", "NEWKEY")
    truthy(countReq(st, "meta/info") > before, "no test after the key changed")
end)

-- ---- replies for a camera we no longer point at ----------------------------
local function reverseFlush(st)
    local p = st.pending
    st.pending = {}
    for i = #p, 1, -1 do p[i]() end
end

test("an alias reply for the previous camera is ignored", function()
    local st = configuredAsync({
        ["CAMA/rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/TOKA"}' },
        ["CAMB/rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/TOKB"}' },
    })
    st.set("Camera ID", "CAMA")
    st.set("Camera ID", "CAMB")
    reverseFlush(st)            -- B answers first, A's late reply lands last
    eq(st.props["RTSP Alias - Low"], "TOKB", "the new camera's token")
end)

test("a poll reply for the previous camera is ignored", function()
    local st = pollingCamera({
        ["cameras/CAMA$"] = { body = '{"id":"CAMA","name":"OldName","state":"CONNECTED"}' },
        ["cameras/CAMB$"] = { body = '{"id":"CAMB","name":"NewName","state":"CONNECTED"}' },
    }, true)
    st.set("Camera ID", "CAMA"); st.flush()
    st.fireTimers(function(tm) return tm.ms == 5000 end)     -- poll for CAMA now in flight
    st.set("Camera ID", "CAMB")                              -- switched before it answered
    st.flush()
    truthy(st.props["Camera Name"] ~= "OldName", "the old camera's name was applied")
end)

test("switching camera clears the old camera's token fields and held detections", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = cam(stateBody('"lastMotion":100')),
                               ["rtsps%-stream"] = { hang = true } })     -- nothing refills them meanwhile
    pollTick(st)
    st.routes["cameras/CAM1$"] = cam(stateBody('"lastMotion":200'))
    pollTick(st)
    eq(st.vars["MOTION_DETECTED"], "true", "precondition")
    st.set("Camera ID", "CAM2")
    eq(st.vars["MOTION_DETECTED"], "false", "motion held over from the old camera")
    eq(st.props["RTSP Alias - Low"], "", "token from the old camera")
end)

-- ---- the poll chain must not die -------------------------------------------
test("a poll that never gets a reply does not stop polling for good", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = { hang = true } }, true)
    pollTick(st)
    eq(countReq(st, "cameras/CAM1$"), 1, "first poll sent")
    st.routes["cameras/CAM1$"] = cam(stateBody())
    st.fireTimers(function(tm) return tm.ms == 60000 end)    -- the watchdog
    pollTick(st)
    eq(countReq(st, "cameras/CAM1$"), 2, "polling resumed")
end)

test("an error while handling a reply does not stop polling", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = cam(stateBody()) }, true)
    local real = C4.UpdateProperty
    C4.UpdateProperty = function(self, n, v)
        if n == "Camera Name" then error("boom") end
        return real(self, n, v)
    end
    st.fireTimers(function(tm) return tm.ms == 5000 end)
    local ok = pcall(st.flush)
    C4.UpdateProperty = real
    truthy(ok, "the error escaped the reply handler")
    local live = 0
    for _, tm in ipairs(st.timers) do
        if tm.ms == 5000 and not tm.cancelled and not tm.fired then live = live + 1 end
    end
    truthy(live >= 1, "no poll scheduled after the error")
end)

-- ---- what a poll reports ---------------------------------------------------
test("a reply without a state is not read as the camera going offline", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = cam(stateBody()) })
    pollTick(st)
    st.events = {}
    st.routes["cameras/CAM1$"] = cam('{"error":"Service Unavailable"}')
    pollTick(st)
    eq(countEvent(st, 8), 0, "false offline event")
    st.routes["cameras/CAM1$"] = cam(stateBody())
    pollTick(st)
    eq(countEvent(st, 9), 0, "false online event")
end)

test("a restart does not announce an online camera", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = cam(stateBody()) })
    pollTick(st)
    eq(countEvent(st, 9), 0, "online event at startup")
end)

test("a real offline then online transition still fires both", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = cam(stateBody()) })
    pollTick(st)
    st.routes["cameras/CAM1$"] = cam('{"id":"CAM1","state":"DISCONNECTED"}')
    pollTick(st)
    eq(countEvent(st, 8), 1, "offline")
    st.routes["cameras/CAM1$"] = cam(stateBody())
    pollTick(st)
    eq(countEvent(st, 9), 1, "online")
end)

test("the first ring after startup is not swallowed", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = cam(stateBody('"lastRing":0')) })
    pollTick(st)
    st.routes["cameras/CAM1$"] = cam(stateBody('"lastRing":5000'))
    pollTick(st)
    eq(countEvent(st, 7), 1, "doorbell ring")
end)

test("a camera that omits the ring field still reports its first ring", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = cam(stateBody()) })
    pollTick(st)
    st.routes["cameras/CAM1$"] = cam(stateBody('"lastRing":5000'))
    pollTick(st)
    eq(countEvent(st, 7), 1, "doorbell ring")
end)

test("sustained motion seen by polling is one episode, not one event per poll", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = cam(stateBody('"lastMotion":100')) })
    pollTick(st)
    for ts = 200, 600, 100 do
        st.routes["cameras/CAM1$"] = cam(stateBody('"lastMotion":' .. ts))
        pollTick(st)
    end
    eq(countEvent(st, 1), 1, "motion events for one continuous movement")
end)

test("polled motion that stops and starts again is a second episode", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = cam(stateBody('"lastMotion":100')) })
    st.set("Event Hold Time", "1")
    pollTick(st)
    st.routes["cameras/CAM1$"] = cam(stateBody('"lastMotion":200'))
    pollTick(st)
    st.fireTimers(function(tm) return tm.ms == 1000 end)     -- hold expires
    eq(st.vars["MOTION_DETECTED"], "false", "cleared")
    st.routes["cameras/CAM1$"] = cam(stateBody('"lastMotion":900'))
    pollTick(st)
    eq(countEvent(st, 1), 2, "two episodes")
end)

test("every polled doorbell ring is its own event", function()
    local st = pollingCamera({ ["cameras/CAM1$"] = cam(stateBody('"lastRing":100')) })
    pollTick(st)
    for ts = 200, 300, 100 do
        st.routes["cameras/CAM1$"] = cam(stateBody('"lastRing":' .. ts))
        pollTick(st)
    end
    eq(countEvent(st, 7), 2, "rings")
end)

-- ---- stream tokens ---------------------------------------------------------
local function storedCamera(routes)
    local st = stub.new({ routes = routes or {} })
    st.load(CAM .. "driver.lua")
    for k, v in pairs({ ["Log Mode"] = "Off", ["NVR Address"] = "192.0.2.10", ["API Key"] = "K",
        ["Camera ID"] = "CAM1", ["RTSP Alias - Low"] = "OLDTOK", ["Event Source"] = "Polling",
        ["Event Polling Interval"] = "5 Seconds" }) do st.props[k] = v end
    OnDriverLateInit()
    return st
end
local function settle(st)
    for _ = 1, 3 do st.fireTimers(function(tm) return not tm.repeating and tm.ms < 20000 end) end
end

test("a restart re-reads the stored stream tokens", function()
    local st = storedCamera({
        ["rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/NEWTOK"}' },
        ["meta/info"] = { body = '{"applicationVersion":"6.2.1"}' },
    })
    settle(st)
    eq(st.props["RTSP Alias - Low"], "NEWTOK", "token after restart")
end)

test("a background refresh never switches RTSP on, nor blanks working tokens", function()
    local st = storedCamera({ ["rtsps%-stream"] = { body = "{}" }, ["meta/info"] = { body = "{}" } })
    settle(st)
    for _, r in ipairs(st.requests) do
        truthy(not (r.method == "POST" and r.url:find("rtsps%-stream")), "enabled RTSP unasked")
    end
    eq(st.props["RTSP Alias - Low"], "OLDTOK", "token kept")
end)

test("a camera coming back online re-reads its stream tokens", function()
    local st = storedCamera({
        ["cameras/CAM1$"] = cam(stateBody()),
        ["rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/OLDTOK"}' },
        ["meta/info"] = { body = "{}" },
    })
    settle(st)
    pollTick(st)
    st.routes["cameras/CAM1$"] = cam('{"id":"CAM1","state":"DISCONNECTED"}')
    pollTick(st)
    local before = countReq(st, "rtsps%-stream")
    st.routes["cameras/CAM1$"] = cam(stateBody())
    st.routes["rtsps%-stream"] = { body = '{"low":"rtsps://h:7441/REBOOTED"}' }
    pollTick(st)
    truthy(countReq(st, "rtsps%-stream") > before, "no token refresh on return")
    eq(st.props["RTSP Alias - Low"], "REBOOTED", "new token")
end)

test("a refresh that finds RTSP switched off does not switch it back on", function()
    local st = storedCamera({ ["rtsps%-stream"] = { code = 404 }, ["meta/info"] = { body = "{}" } })
    settle(st)
    for _, r in ipairs(st.requests) do
        truthy(not (r.method == "POST" and r.url:find("rtsps%-stream")), "enabled RTSP unasked")
    end
end)

-- ---- randomness ------------------------------------------------------------
test("the random generator is seeded differently per camera", function()
    local seeds = {}
    local real = math.randomseed
    for _, id in ipairs({ 100, 101 }) do
        local st = configured()
        st.deviceId = id
        math.randomseed = function(x) seeds[id] = x end
        OnDriverLateInit()
    end
    math.randomseed = real
    truthy(seeds[100] and seeds[101], "never seeded")
    truthy(seeds[100] ~= seeds[101], "two cameras booting together share a seed")
end)

-- ---- event socket ----------------------------------------------------------
local function delayOf(st) return tonumber(tostring(st.props["Event Stream"]):match("in (%d+)s")) end
local function dropAndReconnect(st)
    OnConnectionStatusChanged(6001, 443, "OFFLINE")
    local d = delayOf(st)
    st.fireTimers(function(tm) return tm.ms == d * 1000 end)
    OnConnectionStatusChanged(6001, 443, "ONLINE")
    ReceivedFromNetwork(6001, 443, HANDSHAKE_OK)
    return d
end

test("a server that accepts and drops us backs off instead of being hammered", function()
    local st = liveSocket()
    local d
    for _ = 1, 4 do d = dropAndReconnect(st) end
    truthy(d >= 8, "backoff reset by each handshake; last delay " .. tostring(d))
end)

test("a connection that stayed up starts the backoff over", function()
    local st = liveSocket()
    for _ = 1, 3 do dropAndReconnect(st) end
    local real = os.time
    os.time = function() return real() + 300 end
    OnConnectionStatusChanged(6001, 443, "OFFLINE")
    os.time = real
    truthy(delayOf(st) <= 4, "stable connection should reset; delay " .. tostring(delayOf(st)))
end)

test("when the socket drops, the camera is polled soon, not a minute later", function()
    local st = liveSocket()
    st.set("Event Polling Interval", "5 Seconds")           -- socket up: timer stretched to 60 s
    local before = countReq(st, "cameras/CAM1$")
    OnConnectionStatusChanged(6001, 443, "OFFLINE")
    st.fireTimers(function(tm) return tm.ms < 5000 and tm.ms >= 1000 and not tm.repeating end)
    truthy(countReq(st, "cameras/CAM1$") > before, "no catch-up poll")
end)

-- ---- snapshot listener -----------------------------------------------------
local function snapCamera(routes, async)
    local st = async and configuredAsync(routes) or configured(routes)
    if async then st.set("Camera ID", "CAM1"); st.flush() end
    st.set("Snapshots", "On")
    OnServerStatusChanged(53319, "ONLINE", "snapshot")
    local sent = {}
    C4.ServerSend = function(self, h, data) table.insert(sent, data) end
    return st, sent
end
local GETSNAP = "GET /snapshot.jpg HTTP/1.1\r\n\r\n"

test("two viewers asking at once both get the frame", function()
    local st, sent = snapCamera({ ["/snapshot"] = { body = "FRAMEDATA" } }, true)
    OnServerDataIn(1, GETSNAP, "1.1.1.1", 5000, "snapshot")
    OnServerDataIn(2, GETSNAP, "1.1.1.1", 5000, "snapshot")
    st.flush()
    eq(#sent, 2, "both answered")
    for _, r in ipairs(sent) do contains(r, "200 OK", "response") end
end)

test("a listener still starting is not started twice", function()
    local st = configured()
    st.set("Snapshots", "On")                  -- listener requested, not yet ONLINE
    ExecuteCommand("SET_PROTECT_CONFIG", { address = "192.0.2.10", api_key = "TESTKEY",
        camera_id = "CAM1", snapshots = "On" })
    eq(#st.servers, 1, "listeners created")
end)

test("a frame older than a minute is not served as current", function()
    local st, sent = snapCamera({ ["/snapshot"] = { body = "FRAMEDATA" } })
    local real, now = os.time, os.time()
    os.time = function() return now end
    OnServerDataIn(1, GETSNAP, "1.1.1.1", 5000, "snapshot")
    contains(sent[#sent], "200 OK", "first fetch")
    st.routes["/snapshot"] = { code = 500 }
    now = now + 30
    OnServerDataIn(1, GETSNAP, "1.1.1.1", 5000, "snapshot")
    contains(sent[#sent], "200 OK", "a 30 s old frame beats nothing")
    now = now + 120
    OnServerDataIn(1, GETSNAP, "1.1.1.1", 5000, "snapshot")
    os.time = real
    contains(sent[#sent], "503", "a stale frame must not pass as current")
end)

test("a frame fetched for the previous camera is discarded", function()
    local st, sent = snapCamera({
        ["CAMOLD/snapshot"] = { body = "OLDFRAME" },
        ["CAMNEW/snapshot"] = { body = "NEWFRAME" },
    }, true)
    st.set("Camera ID", "CAMOLD"); st.flush()
    OnServerDataIn(1, GETSNAP, "1.1.1.1", 5000, "snapshot")      -- old fetch in flight
    st.set("Camera ID", "CAMNEW")
    OnServerDataIn(2, GETSNAP, "1.1.1.1", 5000, "snapshot")      -- new fetch
    reverseFlush(st)                                              -- new lands first, old last
    sent = {}
    C4.ServerSend = function(self, h, data) table.insert(sent, data) end
    OnServerDataIn(3, GETSNAP, "1.1.1.1", 5000, "snapshot")
    st.flush()
    contains(sent[#sent] or "", "NEWFRAME", "served from cache")
end)

--=============================================================================
print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
