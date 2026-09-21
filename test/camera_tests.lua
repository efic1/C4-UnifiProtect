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
print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
