--[[
    UniFi Protect Camera (Standalone) — Control4 DriverWorks driver
    One instance per camera. No hub.

    Architecture notes for whoever maintains this:
      * Streaming uses the Dynamic Streams API (GET_STREAM_URLS / GET_SNAPSHOT_URLS),
        documented in DriverWorks Fundamentals -> "Camera Proxy and Dynamic Streams".
        Do not reintroduce GET_STREAM_URL / GET_SNAPSHOT_URL — those do not exist.
      * Events are polled. DriverWorks has no WebSocket client, and Protect's event
        socket needs either a TLS websocket or zlib inflate, neither of which is
        available in this sandbox. Expect 1-2s latency.
      * Lines marked [VERIFY] depend on behaviour not confirmed on real hardware.
--]]

-- Must equal <version> in driver.xml; the build refuses to package otherwise.
local DRIVER_VERSION = "46"
local CAMERA_BINDING = 5001

--=============================================================================
-- State
--=============================================================================
local g = {
    address        = "",
    apiKey         = "",
    cameraId       = "",
    aliases        = { Low = "", Medium = "", High = "" },
    preferred      = "Low",
    initializing   = false,  -- true while LateInit replays stored properties
    pollInterval   = 0,
    holdTime       = 5,
    detect         = { person = true, vehicle = true, animal = false, package = false },
    logMode        = "Off",
    logLevel       = 2,
    online         = false,   -- camera connection state, from polling
    pollTimer      = nil,
    pollBusy       = false,
    adaptive       = true,
    burstSeconds   = 30,
    fastUntil      = 0,
    debugTimer     = nil,
    holdTimers     = {},    -- one per event type; a shared timer would clobber state
    lastSeen       = {},    -- event type -> last timestamp seen from Protect
    streamKey      = 0,
    rtspPort       = 7447,
    parentId       = nil,
    portCorrections = 0,
    portWarned     = false,
    aliasState     = "idle",   -- idle | pending | enabling | none | limited | ok
    autoEnableRtsp = true,
    rtspEnableTried = false,
    protectVersion = nil,
    authFailed     = false,
    unreachable    = false,
    connError      = nil,
    cameraOffline  = false,
    fatal          = nil,
    lastStatus     = nil,
    rateLimited    = false,
    snapshots      = false,
    serverPort     = nil,
    controllerIp   = nil,
    snapData       = nil,
    snapTime       = nil,
    snapFetching   = false,
    snapState      = nil,
    lastServe      = nil,
    reaperTimer    = nil,
    httpPort       = 443,
    cameraMap      = {},   -- display name -> Protect camera id
}

local QUALITY_ORDER = { "Low", "Medium", "High" }
local RESOLUTION_HINT = { Low = "640x360", Medium = "1280x720", High = "1920x1080" }
local FPS_HINT        = { Low = 15, Medium = 15, High = 30 }

local POLL_MS = {
    ["Off"] = 0,
    ["1 Second"] = 1000,  ["2 Seconds"] = 2000,  ["5 Seconds"] = 5000,
    ["10 Seconds"] = 10000, ["15 Seconds"] = 15000,
    ["30 Seconds"] = 30000, ["60 Seconds"] = 60000,
}

--=============================================================================
-- Logging
--=============================================================================
local LVL = { FATAL = 0, ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5 }

local function scrub(s)
    if type(s) ~= "string" then return tostring(s) end
    s = s:gsub("(apiKey=)[^&%s]+", "%1***")
    s = s:gsub("(X%-API%-KEY[\"']?%s*[:=]%s*)[^,%s\"']+", "%1***")
    return s
end

local function log(level, fmt, ...)
    if g.logMode == "Off" then return end
    if level > g.logLevel then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    if g.logLevel < LVL.TRACE then msg = scrub(msg) end
    local line = string.format("[UniFiProtect] %s", msg)
    if g.logMode == "Print" or g.logMode == "Print and Log" then print(line) end
    if g.logMode == "Log" or g.logMode == "Print and Log" then
        if level <= LVL.ERROR then C4:ErrorLog(line) else C4:DebugLog(line) end
    end
end

--=============================================================================
-- Minimal JSON decode (objects, arrays, strings, numbers, bool, null)
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
-- HTTP
--=============================================================================
local function basePath()
    return "/proxy/protect/integration/v1"
end

local function authHeaders(withBody)
    local h = { ["Accept"] = "application/json" }
    -- Without this Protect cannot parse a POST body and reports every field
    -- as missing (AJV_PARSE_ERROR).
    if withBody then h["Content-Type"] = "application/json" end
    -- The integration API authenticates with the API key as a header. It is
    -- refused as a URL parameter, which is why snapshots are proxied.
    if g.apiKey and g.apiKey ~= "" then h["X-API-KEY"] = g.apiKey end
    return h
end

-- cb(ok, decodedBody, httpCode, rawBody)
local MAX_ATTEMPTS = 5

local function retryDelay(attempt, resp)
    -- Honour Retry-After when Protect sends one; otherwise back off
    -- exponentially with jitter so eight cameras don't retry in lockstep.
    local hdrs = resp and resp.headers or {}
    local ra = tonumber(hdrs["Retry-After"] or hdrs["retry-after"] or "")
    if ra and ra > 0 and ra < 120 then return ra * 1000 end
    local base = math.min(2 ^ attempt, 30) * 1000
    return base + math.random(0, 1500)
end

local function request(method, path, body, cb, quiet, attempt)
    attempt = attempt or 1
    if g.address == "" then
        if cb then cb(false, nil, 0, "no address") end
        return
    end
    local url = string.format("https://%s%s", g.address, path)
    if not quiet then
        log(LVL.DEBUG, "%s %s", method, url)
        if body and body ~= "" then log(LVL.DEBUG, "    body: %s", body) end
    end

    local req = C4:url()
        :OnDone(function(transfer, responses, errCode, errMsg)
            local resp = responses and responses[#responses]
            local code = resp and resp.code or 0
            local raw  = resp and resp.body or ""

            -- curl 22 = HTTP_RETURNED_ERROR. With fail_on_error off this should
            -- not appear, but if it does we still have the status code below.
            if errCode ~= 0 and code == 0 then
                log(LVL.ERROR, "Transport error on %s: [%s] %s",
                    path, tostring(errCode), tostring(errMsg))
                g.unreachable = true
                computeStatus()
                if cb then cb(false, nil, 0, errMsg) end
                return
            end

            if code == 429 then
                if attempt < MAX_ATTEMPTS then
                    local wait = retryDelay(attempt, resp)
                    log(LVL.INFO, "Protect rate-limited %s; retry %d in %.1fs",
                        path, attempt, wait / 1000)
                    g.rateLimited = true
                    computeStatus()
                    C4:SetTimer(wait, function()
                        request(method, path, body, cb, quiet, attempt + 1)
                    end)
                    return
                end
                log(LVL.ERROR, "Still rate-limited after %d attempts on %s", attempt, path)
                g.rateLimited = false
                computeStatus()
                -- The caller decides what a 429 means for its own state.
                if cb then cb(false, nil, code, raw) end
                return
            end
            if g.rateLimited then
                g.rateLimited = false
                computeStatus()
            end

            if code == 401 or code == 403 then
                -- quiet callers (the event poll) own their
                -- own status reporting; a 401 there says nothing about the API key.
                if quiet then
                    log(LVL.DEBUG, "HTTP %d on %s", code, path)
                else
                    log(LVL.ERROR, "HTTP %d on %s - credentials rejected", code, path)
                    log(LVL.DEBUG, "Body: %s", tostring(raw):sub(1, 300))
                    g.authFailed = true
                    computeStatus()
                end
                if cb then cb(false, nil, code, raw) end
                return
            end

            if code == 404 then
                log(LVL.ERROR, "HTTP 404 on %s", path)
                -- Only a 404 on /meta/info means the API itself is missing. A 404
                -- on rtsps-stream just means RTSP is off for that camera.
                if path:find("/meta/info", 1, true) then
                    log(LVL.ERROR, "The Protect Integration API is not present on this console. " ..
                        "It requires Protect 6.x or later.")
                    g.connError = "Integration API not found - Protect 6.x or later required"
                    computeStatus()
                end
                if cb then cb(false, nil, code, raw) end
                return
            end

            if code < 200 or code >= 300 then
                log(LVL.WARN, "HTTP %d on %s", code, path)
                log(LVL.DEBUG, "Body: %s", tostring(raw):sub(1, 300))
                if cb then cb(false, nil, code, raw) end
                return
            end

            log(LVL.TRACE, "HTTP %d body: %s", code, tostring(raw):sub(1, 500))
            if cb then cb(true, Json.decode(raw), code, raw) end
        end)
        -- Protect uses a self-signed certificate.
        :SetOption("ssl_verify_peer", false)
        :SetOption("ssl_verify_host", false)
        -- Without this, curl aborts with error 22 on any 4xx/5xx and the status
        -- code never reaches OnDone, which makes every failure look identical.
        :SetOption("fail_on_error", false)
        :SetOption("timeout", 10)

    if method == "POST" then
        req:Post(url, body or "", authHeaders(true))
    elseif method == "PATCH" then
        req:Patch(url, body or "", authHeaders(true))
    else
        req:Get(url, authHeaders(false))
    end
end

--=============================================================================
-- Session
--=============================================================================
-- API-key auth is stateless, so there is no session to establish. Kept as a
-- single seam in case a future auth mode needs one.
local function ensureSession(cb)
    cb(true)
end

--=============================================================================
-- URL construction
--=============================================================================
local function aliasFor(quality)
    local a = g.aliases[quality]
    if a and a ~= "" then return a, quality end
    -- Fall back to any enabled channel rather than publishing a dead URL.
    for _, q in ipairs(QUALITY_ORDER) do
        if g.aliases[q] and g.aliases[q] ~= "" then return g.aliases[q], q end
    end
    return nil, nil
end

-- Driver Status is DERIVED from state, never written directly by async
-- callbacks. Previously sixteen places set it as their own replies landed, so
-- whichever finished last won - e.g. "No RTSP alias" stuck after the aliases
-- had in fact loaded. Set a flag, then call computeStatus().
function computeStatus()
    -- Ordered by dependency: nothing below can work until everything above
    -- does. Connection problems outrank camera selection (discovery needs a
    -- working connection), which outranks streams (they need a camera).
    local s
    if g.fatal then
        s = g.fatal
    elseif g.address == "" then
        s = "Not Configured - enter NVR Address"
    elseif g.apiKey == "" then
        s = "Not Configured - enter API Key"
    elseif g.authFailed then
        s = "Auth Failed - check API Key"
    elseif g.unreachable then
        s = "Unreachable - check NVR Address"
    elseif g.connError then
        s = g.connError
    elseif g.cameraId == "" then
        s = "Not Configured - choose a camera"
    elseif g.rateLimited then
        s = "Protect is busy - retrying"
    elseif g.aliasState == "pending" then
        s = "Fetching streams..."
    elseif g.aliasState == "enabling" then
        s = "Enabling RTSP in Protect..."
    elseif g.aliasState == "limited" then
        s = "Protect was too busy - run Fetch Stream Aliases in a minute"
    elseif g.aliasState == "none" then
        s = "RTSP is off for this camera in Protect - run Enable RTSP Streams"
    elseif not aliasFor(g.preferred) then
        s = "No RTSP alias - run Fetch Stream Aliases"
    elseif g.cameraOffline then
        s = "Camera Offline"
    elseif g.protectVersion then
        s = "Online - Protect " .. g.protectVersion
    else
        s = "Configured"
    end
    if s ~= g.lastStatus then
        g.lastStatus = s
        C4:UpdateProperty("Driver Status", s)
    end
    return s
end

local function rtspUrl(alias)
    -- Plain RTSP on 7447. RTSPS (7441) is SRTP behind a self-signed cert that
    -- Control4 will not validate; 7447 needs no cert and no credentials.
    return string.format("rtsp://%s:%d/%s", g.address, g.rtspPort, alias)
end

--=============================================================================
-- Dynamic Streams
--=============================================================================
-- Clients express what they want differently per command: the dynamic path
-- sends RESOLUTION ("1280x720"), the legacy path sends SIZE_X / SIZE_Y.
-- Honour whichever arrives, else fall back to the configured preference.
local function pickQuality(tParams)
    local w
    if type(tParams) == "table" then
        if tParams.RESOLUTION then
            w = tonumber(tostring(tParams.RESOLUTION):match("^(%d+)"))
        end
        w = w or tonumber(tParams.SIZE_X)
    elseif type(tParams) == "string" then
        w = tonumber(tParams:match("^(%d+)"))
    end
    if not w then return g.preferred end
    if w <= 640 then return "Low" end
    if w <= 1280 then return "Medium" end
    return "High"
end

local function xmlAttr(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    s = s:gsub('"', "&quot;")
    s = s:gsub("'", "&apos;")
    return s
end

local function buildStreamsXml(tParams, key)
    local requested = pickQuality(tParams)

    local order, seen = {}, {}
    local function push(q)
        if q and not seen[q] and g.aliases[q] and g.aliases[q] ~= "" then
            seen[q] = true
            order[#order + 1] = q
        end
    end
    push(requested)
    for _, q in ipairs({ "Low", "Medium", "High" }) do push(q) end

    if #order == 0 then
        log(LVL.WARN, "No RTSP alias configured - returning empty stream list. " ..
            "Run Fetch Stream Aliases, or Enable RTSP Streams if none are on in Protect.")
        return "<streams></streams>"
    end

    -- camera_address appears in the documented STREAM_URLS_READY examples; it
    -- tells the client which host the streams belong to.
    local head = "<streams"
    if key then head = head .. string.format(' key="%d"', key) end
    head = head .. string.format(' camera_address="%s">', xmlAttr(g.address))

    local parts = { head }
    for _, q in ipairs(order) do
        local attrs = string.format('url="%s" codec="h264" resolution="%s" fps="%d"',
            xmlAttr(rtspUrl(g.aliases[q])), RESOLUTION_HINT[q], FPS_HINT[q])
        -- Self-closing, always. Snap One's examples show unclosed <stream>
        -- tags; that is a documentation error. Emitting them produces invalid
        -- XML which breaks the camera list parse for EVERY camera in the
        -- project, not just this one. Verified in the field, twice.
        parts[#parts + 1] = "<stream " .. attrs .. "/>"
    end
    parts[#parts + 1] = "</streams>"

    local xml = table.concat(parts)
    log(LVL.INFO, "GET_STREAM_URLS -> %s", xml)
    return xml
end

-- Point the proxy at the console. Until this runs it still holds 127.0.0.1:80
-- from the defaults, and anything the proxy builds itself goes nowhere.
-- Dynamic Camera Streams arrived in OS 3.3.2. On anything older the
-- requires_dynamic_stream_urls capability is ignored outright and the proxy
-- never calls GET_STREAM_URLS, which looks exactly like a broken driver.
local function checkDirectorVersion()
    local ok, tVers = pcall(function() return C4:GetVersionInfo() end)
    if not ok or type(tVers) ~= "table" then
        log(LVL.WARN, "Could not read Director version")
        return
    end
    local strVers = tostring(tVers["version"] or "")
    local major, minor, rev = strVers:match("(%d+)%.(%d+)%.(%d+)")
    major, minor, rev = tonumber(major), tonumber(minor), tonumber(rev)
    log(LVL.INFO, "Director version %s", strVers)

    if not major then return end
    local tooOld = (major < 3)
        or (major == 3 and minor and minor < 3)
        or (major == 3 and minor == 3 and rev and rev < 2)
    if tooOld then
        local msg = "OS " .. strVers .. " predates 3.3.2 - dynamic camera streams unsupported"
        log(LVL.FATAL, "%s. The camera proxy will never request stream URLs from this " ..
            "driver on this controller. Upgrade to OS 3.3.2 or later.", msg)
        g.fatal = msg
        computeStatus()
        print("[UniFiProtect] *** " .. msg .. " ***")
    end
end

local function pushPortsToProxy()
    -- Sent unconditionally. The proxy's RTSP Port field is read-only in
    -- Composer, and a value persisted from an earlier install (554) otherwise
    -- survives forever and every stream request goes to the wrong port.
    C4:SendToProxy(CAMERA_BINDING, "RTSP_PORT_CHANGED", { PORT = tostring(g.rtspPort) })
    C4:SendToProxy(CAMERA_BINDING, "DEFAULT_RTSP_PORT_CHANGED", { PORT = tostring(g.rtspPort) })
    C4:SendToProxy(CAMERA_BINDING, "HTTP_PORT_CHANGED", { PORT = tostring(g.httpPort) })
    C4:SendToProxy(CAMERA_BINDING, "DEFAULT_HTTP_PORT_CHANGED", { PORT = tostring(g.httpPort) })
    C4:SendToProxy(CAMERA_BINDING, "AUTHENTICATION_REQUIRED_CHANGED", { REQUIRED = "False" })
    C4:SendToProxy(CAMERA_BINDING, "DEFAULT_AUTHENTICATION_REQUIRED_CHANGED", { REQUIRED = "False" })
    log(LVL.INFO, "Pushed ports to proxy: rtsp=%d http=%d", g.rtspPort, g.httpPort)
end

local MAX_PORT_CORRECTIONS = 5

function correctProxyPort()
    g.portCorrections = (g.portCorrections or 0) + 1
    if g.portCorrections > MAX_PORT_CORRECTIONS then
        if not g.portWarned then
            g.portWarned = true
            log(LVL.ERROR, "The camera proxy keeps reverting its RTSP port. Set RTSP Port to %d " ..
                "on the Camera Properties tab by hand.", g.rtspPort)
            g.fatal = "Set RTSP Port to " .. g.rtspPort .. " by hand on the Camera Properties tab"
            computeStatus()
        end
        return
    end
    -- Deferred: the proxy is mid-update when it tells us its port, and a
    -- reply sent inside that exchange can be overwritten.
    C4:SetTimer(1000, function() pushPortsToProxy() end)
end

local function pushAddressToProxy()
    pushPortsToProxy()
    if g.address == "" then return end
    C4:SendToProxy(CAMERA_BINDING, "ADDRESS_CHANGED", { ADDRESS = g.address })
    C4:SendToProxy(CAMERA_BINDING, "HTTP_PORT_CHANGED", { PORT = tostring(g.httpPort) })
    C4:SendToProxy(CAMERA_BINDING, "RTSP_PORT_CHANGED", { PORT = tostring(g.rtspPort) })
    C4:SendToProxy(CAMERA_BINDING, "DEFAULT_HTTP_PORT_CHANGED", { PORT = tostring(g.httpPort) })
    C4:SendToProxy(CAMERA_BINDING, "DEFAULT_RTSP_PORT_CHANGED", { PORT = tostring(g.rtspPort) })
    C4:SendToProxy(CAMERA_BINDING, "AUTHENTICATION_REQUIRED_CHANGED", { REQUIRED = "False" })
    C4:SendToProxy(CAMERA_BINDING, "DEFAULT_AUTHENTICATION_REQUIRED_CHANGED", { REQUIRED = "False" })
    C4:SendToProxy(CAMERA_BINDING, "HTTPS_PORT_CHANGED", { PORT = "443" })
    C4:SendToProxy(CAMERA_BINDING, "USE_HTTPS_CHANGED", { ["USE HTTPS"] = "True" })
    C4:SendToProxy(CAMERA_BINDING, "STREAM_URLS_READY", {})
    log(LVL.INFO, "Pushed address %s (https/443) to the camera proxy", g.address)
end

-- The docs give inconsistent parameter names for the SET_ commands (and spell
-- SET_RTSP_PORT as SET_RSTP_PORT), so pull the first usable value out rather
-- than trusting a key name.
local function firstNumber(tParams)
    for _, v in pairs(tParams or {}) do
        local n = tonumber(v)
        if n and n > 0 and n < 65536 then return n end
    end
end

local function firstString(tParams)
    for _, v in pairs(tParams or {}) do
        if type(v) == "string" and v ~= "" and not tonumber(v) then return v end
    end
end

-- ReceivedFromProxy documents "Returns: None" - a value returned from it never
-- reaches the proxy. XML blocks go back via the raw-string form of
-- SendToProxy, as in the documented DISPLAY_TEXT example. The return value is
-- kept as well: harmless, and it keeps the offline test harness meaningful.
local function replyToProxy(sCommand, xml)
    log(LVL.DEBUG, "reply %s: %s", tostring(sCommand), xml)
    C4:SendToProxy(CAMERA_BINDING, sCommand, xml)
    return xml
end

function ReceivedFromProxy(idBinding, sCommand, tParams)
    if idBinding ~= CAMERA_BINDING then return end
    tParams = tParams or {}

    -- Logged at Info deliberately. When streaming fails the first question is
    -- always "did the proxy ask us anything at all", and that must be visible
    -- without switching to Debug.
    log(LVL.INFO, "Proxy -> %s", tostring(sCommand))
    if g.logLevel >= LVL.DEBUG then
        for k, v in pairs(tParams) do
            log(LVL.DEBUG, "    %s = %s", tostring(k), tostring(v))
        end
    end

    if sCommand == "GET_STREAM_URLS" then
        return replyToProxy("GET_STREAM_URLS", buildStreamsXml(tParams))

    elseif sCommand == "GET_SNAPSHOT_QUERY_STRING" then
        return replyToProxy(sCommand, "<snapshot_query_string></snapshot_query_string>")

    elseif sCommand == "GET_SNAPSHOT_URLS" then
        return replyToProxy(sCommand, "<snapshots></snapshots>")

    elseif sCommand == "GET_RTSP_H264_QUERY_STRING" or sCommand == "GET_RTSP_H264_QUERY" then
        -- Answered in UIRequest; this handler's return value is discarded.
        return

    elseif sCommand == "GET_MJPEG_QUERY" or sCommand == "GET_MJPEG_QUERY_STRING" then
        -- Protect exposes no MJPEG endpoint.
        return replyToProxy(sCommand, "<mjpeg_query_string></mjpeg_query_string>")

    elseif sCommand == "SET_RTSP_PORT" or sCommand == "SET_RSTP_PORT" then
        -- The proxy reports its STORED port on load (554 on a fresh device),
        -- which is not what Protect uses. Adopting it silently broke video on
        -- every new camera. The driver's RTSP Port property is the source of
        -- truth: correct the proxy rather than follow it.
        local port = firstNumber(tParams)
        if port and port ~= g.rtspPort then
            log(LVL.INFO, "Proxy reported RTSP port %d; correcting it to %d", port, g.rtspPort)
            correctProxyPort()
        end
        return

    elseif sCommand == "SET_HTTP_PORT" then
        local port = firstNumber(tParams)
        if port then
            g.httpPort = port
            log(LVL.INFO, "Proxy set HTTP port to %d", port)
        end
        return

    elseif sCommand == "SET_ADDRESS" then
        local addr = firstString(tParams)
        if addr and addr ~= "" and addr ~= "127.0.0.1" then
            log(LVL.INFO, "Proxy set address to %s", addr)
            if g.address == "" then
                -- Adopt it so the driver and the proxy agree.
                g.address = addr
                C4:UpdateProperty("NVR Address", addr)
            elseif addr ~= g.address then
                log(LVL.WARN, "Proxy address (%s) differs from NVR Address (%s). " ..
                    "The proxy's value is what builds the stream URL.", addr, g.address)
            end
        end
        return

    elseif sCommand == "SET_PUBLICLY_ACCESSIBLE" then
        log(LVL.INFO, "Publicly accessible: %s", tostring(firstString(tParams) or
            (next(tParams) and select(2, next(tParams))) or "?"))
        return

    elseif sCommand == "USE_DEFAULTS" then
        g.rtspPort = tonumber(Properties["RTSP Port"]) or 7447
        g.httpPort = 443
        log(LVL.INFO, "Proxy reset to defaults; ports back to %d/443", g.rtspPort)
        correctProxyPort()
        return

    elseif sCommand == "SET_USERNAME" or sCommand == "SET_PASSWORD"
        or sCommand == "SET_AUTHENTICATION_REQUIRED"
        or sCommand == "SET_AUTHENTICATION_TYPE" then
        -- Protect's 7447 streams need no credentials; the token is the secret.
        log(LVL.DEBUG, "Ignoring %s - Protect RTSP needs no credentials", tostring(sCommand))
        return

    elseif sCommand == "CHECK_URL" or sCommand == "CHECK_ADDRESS_PORT" then
        -- Logged loudly: these carry the URL Control4 composed, which is the
        -- one thing the driver cannot otherwise see.
        print("[UniFiProtect] === Camera Test: " .. tostring(sCommand) .. " ===")
        for k, v in pairs(tParams) do
            print(string.format("[UniFiProtect]     %s = %s", tostring(k), tostring(v)))
        end
        return

    elseif sCommand == "GET_PROPERTIES" or sCommand == "CAMERA_ON"
        or sCommand == "CAMERA_OFF"
        or sCommand == "SET_PUBLICLY_ACCESSIBLE" or sCommand == "USE_DEFAULTS" then
        return

    else
        log(LVL.WARN, "Unhandled proxy command: %s", tostring(sCommand))
        return
    end
end

--=============================================================================
-- Snapshot proxy
--
-- Protect refuses credentials in a URL (verified: HTTP 401 with the key as a
-- query parameter, 200 with it as a header), and Navigator can only fetch
-- URLs. So the driver fetches the frame itself, caches it, and serves it from
-- a small HTTP listener on the controller. Navigator fetches an
-- unauthenticated LAN URL and the API key never leaves the controller.
--
-- Snapshots use GET_SNAPSHOT_URLS (a complete URL) because the query-string
-- path appends to the proxy's own address, which must stay on the NVR for RTSP.
--=============================================================================
local SNAP_FRESH_SEC  = 5          -- serve from cache below this age
local SNAP_IDLE_SEC   = 120        -- release the cached frame after this quiet
local MAX_SNAP_BYTES  = 4 * 1024 * 1024

local function snapshotReady()
    return g.snapshots and g.serverPort and g.controllerIp and g.controllerIp ~= ""
end

local function snapshotUrl()
    if not snapshotReady() then return nil end
    return string.format("http://%s:%d/snapshot.jpg", g.controllerIp, g.serverPort)
end

local function refreshSnapshot(cb)
    if g.cameraId == "" or g.address == "" or g.apiKey == "" then
        if cb then cb(false) end
        return
    end
    if g.snapFetching then if cb then cb(false) end return end
    g.snapFetching = true

    -- Only highQuality is supported here. Adding w= returns HTTP 400.
    local path = string.format("/proxy/protect/integration/v1/cameras/%s/snapshot?highQuality=false",
        g.cameraId)
    local fullUrl = "https://" .. g.address .. path
    -- Safe to log in full: the API key travels as a header, not in the URL.
    log(LVL.INFO, "Snapshot fetch: %s", fullUrl)
    C4:url()
        :OnDone(function(transfer, responses, errCode, errMsg)
            g.snapFetching = false
            local resp = responses and responses[#responses]
            local code = resp and resp.code or 0
            local body = resp and resp.body or ""
            if errCode == 0 and code == 200 and #body > 0 and #body <= MAX_SNAP_BYTES then
                g.snapData, g.snapTime = body, os.time()
                if g.snapState ~= "ok" then
                    g.snapState = "ok"
                    C4:UpdateProperty("Snapshot Status", "Active on port " .. tostring(g.serverPort))
                    log(LVL.INFO, "Snapshot OK: %d bytes from %s", #body, fullUrl)
                end
                if cb then cb(true) end
            else
                if g.snapState ~= "fail" then
                    g.snapState = "fail"
                    C4:UpdateProperty("Snapshot Status", "Fetch failed (HTTP " .. tostring(code) .. ")")
                    log(LVL.WARN, "Snapshot fetch FAILED")
                    log(LVL.WARN, "  url:      %s", fullUrl)
                    log(LVL.WARN, "  status:   HTTP %s   (%d bytes)", tostring(code), #body)
                    if errCode ~= 0 then
                        log(LVL.WARN, "  transport: [%s] %s", tostring(errCode), tostring(errMsg))
                    end
                    if #body > 0 then
                        log(LVL.WARN, "  response: %s", tostring(body):sub(1, 500))
                    end
                    log(LVL.WARN, "  camera id: %s", g.cameraId)
                end
                if cb then cb(false) end
            end
        end)
        :SetOption("ssl_verify_peer", false)
        :SetOption("ssl_verify_host", false)
        :SetOption("fail_on_error", false)
        :SetOption("timeout", 10)
        :Get(fullUrl, { ["X-API-KEY"] = g.apiKey, ["Accept"] = "image/jpeg" })
end

local function httpReply(handle, status, ctype, body)
    C4:ServerSend(handle, string.format(
        "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n" ..
        "Cache-Control: no-store\r\nConnection: close\r\n\r\n%s",
        status, ctype, #body, body))
    C4:ServerCloseClient(handle)
end

function OnServerStatusChanged(port, status, identifier)
    if status ~= "ONLINE" then
        g.serverPort = nil
        return
    end
    g.serverPort = port
    local override = Properties["Controller Address"]
    if override and override ~= "" then
        g.controllerIp = override
    else
        local ok, addr = pcall(function() return C4:GetControllerNetworkAddress() end)
        g.controllerIp = (ok and type(addr) == "string" and addr ~= "") and addr or nil
    end
    if not g.controllerIp then
        log(LVL.ERROR, "Controller address unknown - set Controller Address by hand.")
        C4:UpdateProperty("Snapshot Status", "Set Controller Address")
        return
    end
    log(LVL.INFO, "Snapshot server on %s:%d", g.controllerIp, port)
    C4:UpdateProperty("Snapshot Status", "Serving on port " .. tostring(port))
    C4:SendToProxy(CAMERA_BINDING, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY")
    -- No fetch here. A 4K frame is ~1 MB and Protect re-encodes it; fetching
    -- eight of them the moment settings are pushed is load nobody asked for.
    -- The first Navigator request pulls the first frame.
end

function OnServerConnectionStatusChanged(handle, port, status, address, identifier) end

function OnServerDataIn(handle, data, address, port, identifier)
    if not tostring(data):match("^GET") then
        httpReply(handle, "405 Method Not Allowed", "text/plain", "GET only")
        return
    end
    g.lastServe = os.time()
    local age = g.snapTime and (os.time() - g.snapTime) or nil

    if g.snapData and age and age < SNAP_FRESH_SEC then
        httpReply(handle, "200 OK", "image/jpeg", g.snapData)
        return
    end
    refreshSnapshot(function()
        if g.snapData then
            httpReply(handle, "200 OK", "image/jpeg", g.snapData)   -- stale beats blank
        else
            httpReply(handle, "503 Service Unavailable", "text/plain", "no snapshot")
        end
    end)
end

local function ensureSnapshotServer()
    if not g.snapshots then
        if g.serverPort then startSnapshotServer() end   -- tears it down
        return
    end
    if g.serverPort then
        -- Same listener, same port: just discard the frame from the old camera.
        -- The next request fetches from the new one.
        g.snapData, g.snapTime, g.snapState = nil, nil, nil
    else
        startSnapshotServer()
    end
end

function startSnapshotServer()
    if g.serverPort then C4:DestroyServer(g.serverPort); g.serverPort = nil end
    if g.reaperTimer then g.reaperTimer:Cancel(); g.reaperTimer = nil end
    g.snapData, g.snapTime, g.snapState = nil, nil, nil

    if not g.snapshots then
        C4:UpdateProperty("Snapshot Status", "Off")
        C4:SendToProxy(CAMERA_BINDING, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY")
        return
    end
    -- Port 0: let the OS choose. A hardcoded port collides with other drivers.
    local ok = C4:CreateServer(0, "", false, "snapshot")
    if not ok then
        log(LVL.ERROR, "Could not start the snapshot server")
        C4:UpdateProperty("Snapshot Status", "Listener failed")
        return
    end
    -- Release the cached frame for a camera nobody is looking at.
    g.reaperTimer = C4:SetTimer(60000, function()
        if g.snapData and g.lastServe and (os.time() - g.lastServe) > SNAP_IDLE_SEC then
            log(LVL.DEBUG, "Snapshot cache idle - releasing %d bytes", #g.snapData)
            g.snapData, g.snapTime = nil, nil
        end
    end, true)
end

--=============================================================================
-- UIRequest — the camera proxy calls THIS for commands that return XML.
-- ReceivedFromProxy also sees them, but its return value is discarded
-- (documented: "Returns: None"), which is why replies never arrived.
--=============================================================================
function UIRequest(sCommand, tParams)
    tParams = tParams or {}
    log(LVL.INFO, "UIRequest -> %s", tostring(sCommand))

    if sCommand == "GET_STREAM_URLS" then
        local xml = buildStreamsXml(tParams)
        log(LVL.INFO, "    %s", xml)
        return xml

    elseif sCommand == "GET_RTSP_H264_QUERY_STRING" then
        local quality = pickQuality(tParams)
        local alias, actual = aliasFor(quality)
        if not alias then
            log(LVL.WARN, "    no RTSP alias available")
            return "<rtsp_h264_query_string></rtsp_h264_query_string>"
        end
        log(LVL.INFO, "    [%s] -> %s", tostring(actual or quality), alias)
        return "<rtsp_h264_query_string>" .. xmlAttr(alias) .. "</rtsp_h264_query_string>"

    elseif sCommand == "GET_MJPEG_QUERY_STRING" or sCommand == "GET_MJPEG_QUERY" then
        return "<mjpeg_query_string></mjpeg_query_string>"   -- Protect has no MJPEG

    elseif sCommand == "GET_SNAPSHOT_QUERY_STRING" then
        -- Snapshots are not offered, but the proxy still asks. It needs a
        -- well-formed empty document; a bare "" stalls the camera view.
        return "<snapshot_query_string></snapshot_query_string>"

    elseif sCommand == "GET_SNAPSHOT_URLS" then
        local url = snapshotUrl()
        if not url then return "<snapshots></snapshots>" end
        log(LVL.INFO, "    snapshot -> %s", url)
        return "<snapshots><snapshot url=\"" .. xmlAttr(url) ..
               "\" resolution=\"640x360\"/></snapshots>"

    end

    log(LVL.DEBUG, "UIRequest: no handler for %s", tostring(sCommand))
    return ""
end

--=============================================================================
-- Events
--=============================================================================
local EVENT_MAP = {
    motion   = { var = "MOTION_DETECTED",   event = 1, endEvent = 2 },
    person   = { var = "PERSON_DETECTED",   event = 3 },
    vehicle  = { var = "VEHICLE_DETECTED",  event = 4 },
    animal   = { var = "ANIMAL_DETECTED",   event = 5 },
    package  = { var = "PACKAGE_DETECTED",  event = 6 },
    doorbell = { var = "DOORBELL_RING",     event = 7 },
}

local function clearEvent(kind)
    local m = EVENT_MAP[kind]
    if not m then return end
    C4:SetVariable(m.var, "false")
    if m.endEvent then C4:FireEvent(m.endEvent) end
    if g.holdTimers[kind] then
        g.holdTimers[kind] = nil
    end
    log(LVL.DEBUG, "Cleared %s", kind)
end

local function fireEvent(kind)
    local m = EVENT_MAP[kind]
    if not m then
        log(LVL.TRACE, "Ignoring unknown event type '%s'", tostring(kind))
        return
    end
    log(LVL.INFO, "Event: %s", kind)
    -- Activity rarely arrives alone: poll quickly for a short window so the
    -- follow-up detections and the end-of-event are caught promptly.
    if g.adaptive then g.fastUntil = os.time() + g.burstSeconds end
    C4:SetVariable(m.var, "true")
    C4:FireEvent(m.event)

    -- Per-event watchdog. A shared timer would clear unrelated state.
    if g.holdTimers[kind] then g.holdTimers[kind]:Cancel() end
    g.holdTimers[kind] = C4:SetTimer(g.holdTime * 1000, function()
        clearEvent(kind)
    end)
end

local function handleCameraState(cam)
    if type(cam) ~= "table" then return end

    if cam.name and cam.name ~= "" then
        C4:UpdateProperty("Camera Name", cam.name)
    end

    local isOnline = (cam.state == "CONNECTED") or (cam.isConnected == true)
    if isOnline ~= g.online then
        g.online = isOnline
        C4:FireEvent(isOnline and 9 or 8)
        g.cameraOffline = not isOnline
        computeStatus()
        log(LVL.INFO, "Camera %s", isOnline and "online" or "offline")
    end

    -- Timestamps are epoch milliseconds. Fire only when they advance.
    local function checkStamp(key, kind, enabled)
        local ts = cam[key]
        if type(ts) ~= "number" or ts == 0 then return end
        if enabled == false then return end
        if g.lastSeen[kind] and ts <= g.lastSeen[kind] then return end
        local first = (g.lastSeen[kind] == nil)
        g.lastSeen[kind] = ts
        -- Don't replay history on the first poll after a driver restart.
        if not first then fireEvent(kind) end
    end

    checkStamp("lastMotion", "motion", true)
    checkStamp("lastRing", "doorbell", true)

    -- Smart detections. Only fire a class Protect actually names: guessing
    -- "person" for every smart detect would fire false person events for a
    -- passing car, which is worse than firing nothing.
    -- [VERIFY] field shape differs between the Integration API and the legacy
    -- bootstrap; unrecognised shapes are logged at Trace and ignored.
    local ts = cam.lastSmartDetect or cam.lastSmartDetectAt
    local types = cam.lastSmartDetectTypes or cam.smartDetectTypes
    if type(ts) == "number" and ts > 0 and type(types) == "table" then
        local advanced = not (g.lastSeen.smart and ts <= g.lastSeen.smart)
        local first = (g.lastSeen.smart == nil)
        g.lastSeen.smart = ts
        if advanced and not first then
            for _, t in ipairs(types) do
                local kind = tostring(t):lower()
                if kind == "person" and g.detect.person then fireEvent("person")
                elseif kind == "vehicle" and g.detect.vehicle then fireEvent("vehicle")
                elseif kind == "animal" and g.detect.animal then fireEvent("animal")
                elseif kind == "package" and g.detect.package then fireEvent("package")
                else log(LVL.TRACE, "Smart detect class not handled: %s", kind) end
            end
        end
    elseif type(ts) == "number" and ts > 0 and g.lastSeen.smart == nil then
        log(LVL.WARN, "Smart detections present but no type list found - " ..
            "person/vehicle/animal/package events will not fire. Raise Log Level to Trace and report the payload shape.")
        g.lastSeen.smart = ts
    end
end

-- Self-scheduling poll. A repeating timer can stack requests if the console
-- is slow to answer; this chains one-shot timers and skips a tick while a
-- request is still in flight.
local function schedulePoll()
    if g.pollTimer then g.pollTimer:Cancel(); g.pollTimer = nil end
    if g.pollInterval == 0 then return end

    local delay = g.pollInterval
    if g.adaptive and g.fastUntil and os.time() < g.fastUntil then
        delay = 1000
    end

    g.pollTimer = C4:SetTimer(delay, function()
        g.pollTimer = nil
        pcall(poll)
    end)
end

function poll()
    if g.cameraId == "" or g.address == "" then
        schedulePoll()
        return
    end
    if g.pollBusy then
        log(LVL.TRACE, "Previous poll still in flight; skipping this tick")
        schedulePoll()
        return
    end
    g.pollBusy = true

    ensureSession(function(ok)
        if not ok then
            g.pollBusy = false
            schedulePoll()
            return
        end
        request("GET", basePath() .. "/cameras/" .. g.cameraId, nil,
            function(success, data, code)
                g.pollBusy = false
                if success then
                    handleCameraState(data)
                elseif code == 401 then
                end
                schedulePoll()
            end, true)   -- quiet: this runs continuously
    end)
end

local function startPolling()
    if g.pollTimer then g.pollTimer:Cancel(); g.pollTimer = nil end
    if g.pollInterval == 0 then
        log(LVL.INFO, "Event polling disabled - this driver will make no periodic API calls")
        C4:UpdateProperty("API Call Rate", "0 per hour (polling off)")
        return
    end

    local perHour = math.floor(3600 / (g.pollInterval / 1000))
    local note = string.format("%d per hour", perHour)
    if g.adaptive then note = note .. " (bursts to 3600 briefly after an event)" end
    C4:UpdateProperty("API Call Rate", note)
    log(LVL.INFO, "Polling every %dms - about %s", g.pollInterval, note)
    schedulePoll()
end

--=============================================================================
-- Actions
--=============================================================================
local function testConnection()
    g.connError = nil
    ensureSession(function(ok)
        if not ok then return end
        local path = basePath() .. "/meta/info"
        request("GET", path, nil, function(success, data, code, raw)
            if success then
                local ver = (data and (data.applicationVersion or data.version)) or "unknown"
                g.protectVersion = tostring(ver)
                g.authFailed, g.unreachable, g.connError = false, false, nil
                computeStatus()
                log(LVL.INFO, "Connected. Protect version %s", tostring(ver))
            elseif code == 401 or code == 403 then
                -- request() already set the precise reason; do not overwrite it
                -- with something vaguer.
                log(LVL.ERROR, "Test Connection: credentials rejected")
            else
                -- Keep a more precise reason if request() already recorded one.
                if code == 429 then
                    g.connError = "Protect was too busy - try again in a minute"
                else
                    g.connError = g.connError or ("Connection failed (HTTP " .. tostring(code) .. ")")
                end
                computeStatus()
            end
        end)
    end)
end

local NO_CAMERA = "<none> - run Discover Cameras"

-- Display names go into a comma-delimited list, so commas in a camera name
-- would split it into two entries. Duplicates get a short ID suffix so two
-- cameras named "Front Door" stay distinguishable.
local function buildCameraList(cams)
    local seen, entries = {}, {}
    g.cameraMap = {}
    for _, cam in ipairs(cams) do
        local name = tostring(cam.name or "Unnamed"):gsub(",", " ")
        name = name:gsub("^%s*(.-)%s*$", "%1")
        if name == "" then name = "Unnamed" end
        if seen[name] then
            name = string.format("%s (%s)", name, tostring(cam.id):sub(-6))
        end
        seen[name] = true
        g.cameraMap[name] = cam.id
        entries[#entries + 1] = name
    end
    table.sort(entries)
    return entries
end

local function applyCameraList(cams)
    local entries = buildCameraList(cams)
    if #entries == 0 then
        C4:UpdatePropertyList("Camera", NO_CAMERA, NO_CAMERA)
        return 0
    end

    -- Keep the current selection selected if it still exists, so a refresh
    -- doesn't silently repoint the driver at a different camera.
    local current = Properties["Camera"]
    local keep = nil
    for _, e in ipairs(entries) do
        if e == current then keep = e break end
    end
    if not keep and g.cameraId ~= "" then
        for name, id in pairs(g.cameraMap) do
            if id == g.cameraId then keep = name break end
        end
    end

    local listStr = table.concat(entries, ",")
    if keep then
        C4:UpdatePropertyList("Camera", listStr, keep)
    else
        C4:UpdatePropertyList("Camera", NO_CAMERA .. "," .. listStr, NO_CAMERA)
    end
    return #entries
end

local function discoverCameras(silent)
    ensureSession(function(ok)
        if not ok then return end
        request("GET", basePath() .. "/cameras", nil, function(success, data)
            if not success or type(data) ~= "table" then
                log(LVL.ERROR, "Discovery failed")
                return
            end
            local list = data.cameras or data
            local cams = {}
            for _, cam in ipairs(list) do
                if type(cam) == "table" and cam.id then
                    cams[#cams + 1] = cam
                    if not silent then
                        print(string.format("[UniFiProtect] %-28s %s", tostring(cam.name), tostring(cam.id)))
                    end
                end
            end
            local n = applyCameraList(cams)
            log(LVL.INFO, "Discovered %d cameras", n)
            if n == 0 and not silent then print("[UniFiProtect] No cameras returned.") end
        end)
    end)
end

-- Pull the stream token out of either URL form Protect returns.
local function tokenFromUrl(u)
    if type(u) ~= "string" then return nil end
    local t = u:match("^rtsps?://[^/]+/([^?%s]+)")
    return (t ~= "" ) and t or nil
end

local function applyAlias(slot, alias)
    if not alias or alias == "" then return false end
    g.aliases[slot] = alias
    C4:UpdateProperty("RTSP Alias - " .. slot, alias)
    return true
end

-- Integration API: GET /cameras/{id}/rtsps-stream returns a map of quality ->
-- rtsps:// URL. Qualities that are not enabled are absent or null.
local enableRtspStreams   -- forward declaration; defined below

-- Runs once the stream question has a final answer. Sequenced after it, not
-- alongside, to keep each camera to one request at a time. It also tells a
-- missing Integration API (every endpoint 404s) apart from RTSP simply being
-- off, which look identical from the stream endpoint alone.
local function afterStreams()
    if not g.protectVersion then testConnection() end
end

-- No quality has RTSP enabled. Turn it on once if allowed, else say so.
local function noStreamsFound()
    if g.autoEnableRtsp and not g.rtspEnableTried then
        g.rtspEnableTried = true
        log(LVL.INFO, "No RTSP stream is enabled for this camera - enabling it in Protect")
        enableRtspStreams()
        return
    end
    log(LVL.ERROR, "RTSP is off for this camera. Run 'Enable RTSP Streams' or turn it on in Protect.")
    g.aliasState = "none"
    computeStatus()
    afterStreams()
end

-- Integration API: GET /cameras/{id}/rtsps-stream returns quality -> rtsps://
-- URL. Qualities that are not enabled are absent or null.
local function fetchAliasesIntegration()
    g.aliasState = "pending"
    computeStatus()
    request("GET", basePath() .. "/cameras/" .. g.cameraId .. "/rtsps-stream", nil,
        function(success, data, code, raw)
            if not success then
                if code == 404 then
                    noStreamsFound()           -- RTSP off, or the API is missing
                elseif code == 429 then
                    -- Retries exhausted. Do NOT follow up with another request
                    -- to a console that is already refusing them.
                    g.aliasState = "limited"
                    computeStatus()
                else
                    g.aliasState = "idle"
                    computeStatus()
                    afterStreams()
                end
                return
            end
            if type(data) ~= "table" then
                log(LVL.ERROR, "Unexpected rtsps-stream response: %s", tostring(raw):sub(1, 200))
                g.aliasState = "idle"
                computeStatus()
                afterStreams()
                return
            end

            local map = { high = "High", medium = "Medium", low = "Low" }
            local found = 0
            for key, slot in pairs(map) do
                local alias = tokenFromUrl(data[key])
                if alias then
                    if applyAlias(slot, alias) then found = found + 1 end
                elseif g.aliases[slot] ~= "" then
                    -- A tier switched off in Protect must not keep serving a
                    -- token that no longer plays.
                    g.aliases[slot] = ""
                    C4:UpdateProperty("RTSP Alias - " .. slot, "")
                    log(LVL.INFO, "%s quality is off in Protect; cleared its token", slot)
                end
            end

            if found == 0 then
                noStreamsFound()
            else
                -- This branch used to leave the status untouched, so an earlier
                -- "No RTSP alias" outlived the aliases arriving.
                g.aliasState = "ok"
                log(LVL.INFO, "Populated %d stream alias(es)", found)
                C4:SendToProxy(CAMERA_BINDING, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY")
                computeStatus()
                afterStreams()
            end
        end)
end

function fetchAliases()
    if g.cameraId == "" then
        log(LVL.ERROR, "Select a camera before fetching aliases")
        return
    end
    ensureSession(function(ok)
        if not ok then return end
        fetchAliasesIntegration()
    end)
end

-- Fetch a URL with no driver-supplied auth headers: exactly what Navigator or
-- Director does when it uses the URL the proxy composed. If this fails, no
-- amount of driver-side correctness will make a tile appear.
local function rawGet(url, headers, cb)
    C4:url()
        :OnDone(function(transfer, responses, errCode, errMsg)
            local resp = responses and responses[#responses]
            local code = resp and resp.code or 0
            local body = resp and resp.body or ""
            local ctype = ""
            if resp and resp.headers then
                ctype = resp.headers["Content-Type"] or resp.headers["content-type"] or ""
            end
            cb(code, #body, ctype, errCode, errMsg)
        end)
        :SetOption("ssl_verify_peer", false)
        :SetOption("ssl_verify_host", false)
        :SetOption("fail_on_error", false)
        :SetOption("timeout", 10)
        :Get(url, headers or {})
end

local function runDiagnostics()
    local P = function(t) print("[UniFiProtect] " .. t) end
    P("================ DIAGNOSTICS ================")
    P("Driver " .. DRIVER_VERSION .. "   camera=" .. (g.cameraId ~= "" and g.cameraId or "(none)"))
    P("Aliases: Low=" .. (g.aliases.Low ~= "" and g.aliases.Low or "-") ..
      "  Medium=" .. (g.aliases.Medium ~= "" and g.aliases.Medium or "-") ..
      "  High=" .. (g.aliases.High ~= "" and g.aliases.High or "-"))
    P("Stream URL: rtsp://" .. g.address .. ":" .. g.rtspPort .. "/<token>")
    if g.rtspPort ~= 7447 then
        P("    ^^ WRONG PORT. Protect serves RTSP on 7447; fix it on the Camera Properties tab.")
    end
    if g.cameraId == "" then P("No camera selected."); P("====="); return end

    P("--- comparing stored tokens against Protect ---")
    request("GET", basePath() .. "/cameras/" .. g.cameraId .. "/rtsps-stream", nil,
        function(ok, data)
            if not ok or type(data) ~= "table" then
                P("    Could not read streams.")
                P("=============================================")
                return
            end
            local map = { low = "Low", medium = "Medium", high = "High" }
            local stale = false
            for key, slot in pairs(map) do
                local live = tokenFromUrl(data[key])
                local held = g.aliases[slot]
                if live and held ~= "" and live ~= held then
                    P(string.format("    %s: STALE (have %s, Protect says %s)", slot, held, live))
                    stale = true
                elseif live and held == "" then
                    P(string.format("    %s: available but not stored (%s)", slot, live))
                elseif live then
                    P(string.format("    %s: current", slot))
                else
                    P(string.format("    %s: RTSP not enabled in Protect", slot))
                end
            end
            if stale then P("    => Run Fetch Stream Aliases.") end
            P("=============================================")
        end)
end

-- Asks Protect to turn RTSP on for all three qualities, then re-reads them.
function enableRtspStreams()
    if g.cameraId == "" then
        log(LVL.ERROR, "Select a camera first")
        return
    end
    ensureSession(function(ok)
        if not ok then return end
        g.aliasState = "enabling"
        computeStatus()
        local body = '{"qualities":["high","medium","low"]}'
        request("POST", basePath() .. "/cameras/" .. g.cameraId .. "/rtsps-stream", body,
            function(success, data, code, raw)
                if not success then
                    log(LVL.ERROR, "Could not enable RTSP (HTTP %s): %s",
                        tostring(code), tostring(raw):sub(1, 200))
                    return
                end
                log(LVL.INFO, "RTSP enable requested; re-reading streams")
                fetchAliasesIntegration()
            end)
    end)
end

local validate   -- forward declaration; defined further down

--=============================================================================
-- Configuration pushed by the UniFi Protect Setup driver
--
-- Applied INLINE. C4:UpdateProperty only refreshes what Composer displays; it
-- never fires OnPropertyChanged, so relying on that callback would leave the
-- driver's internal state unchanged.
--=============================================================================
local function applyConfig(t)
    if type(t) ~= "table" then return end
    local changed = {}

    local function setStr(key, prop, field)
        local v = t[key]
        if v == nil then return end
        v = tostring(v)
        if g[field] ~= v then
            g[field] = v
            changed[prop] = true
        end
        C4:UpdateProperty(prop, prop == "API Key" and v or v)
    end

    setStr("address",   "NVR Address", "address")
    setStr("api_key",   "API Key",     "apiKey")

    local newCam = t.camera_id and tostring(t.camera_id) or nil
    if newCam and newCam ~= g.cameraId then
        g.cameraId = newCam
        g.rtspEnableTried = false
        g.lastSeen = {}
        g.aliases = { Low = "", Medium = "", High = "" }
        for _, q in ipairs({ "Low", "Medium", "High" }) do
            C4:UpdateProperty("RTSP Alias - " .. q, "")
        end
        changed["Camera ID"] = true
    end
    if newCam then C4:UpdateProperty("Camera ID", newCam) end

    if t.camera_name and t.camera_name ~= "" then
        C4:UpdateProperty("Camera Name", tostring(t.camera_name))
        -- Keep the dropdown showing the right camera.
        g.cameraMap[tostring(t.camera_name)] = g.cameraId
        C4:UpdatePropertyList("Camera", tostring(t.camera_name), tostring(t.camera_name))
    end

    if t.snapshots ~= nil then
        local want = (tostring(t.snapshots) == "On")
        if want ~= g.snapshots then changed["Snapshots"] = true end
        g.snapshots = want
        C4:UpdateProperty("Snapshots", want and "On" or "Off")
    end

    if t.enable_rtsp ~= nil then
        g.autoEnableRtsp = (tostring(t.enable_rtsp) == "Yes")
        C4:UpdateProperty("Enable RTSP Automatically", g.autoEnableRtsp and "Yes" or "No")
    end
    if t.parent_id then g.parentId = tonumber(t.parent_id) end

    log(LVL.INFO, "Configuration received from setup driver (camera %s)", g.cameraId)

    -- Follow-on work, in dependency order.
    if changed["NVR Address"] then pushAddressToProxy() end
    if g.cameraId ~= "" and (changed["Camera ID"] or changed["NVR Address"] or changed["API Key"]
                             or g.aliases.Low == "") then
        fetchAliases()
    end
    -- The snapshot server reads g.address / g.apiKey / g.cameraId at fetch
    -- time, so it must run after those are set. It keeps its port.
    ensureSnapshotServer()
    -- No separate connection test here. The stream fetch above already
    -- proves the console answers; firing both at once, on every camera at
    -- once, is what tripped Protect's rate limit (HTTP 429). The version for
    -- the status line is fetched after the streams, in sequence.
    computeStatus()

    if g.parentId then
        C4:SendToDevice(g.parentId, "CONFIG_APPLIED", {
            device_id = tostring(C4:GetDeviceID()),
            camera_id = g.cameraId,
        })
    end
end

function ExecuteCommand(sCommand, tParams)
    tParams = tParams or {}

    -- Composer delivers every driver action as LUA_ACTION, with the <command>
    -- value in tParams.ACTION. Unwrap it before dispatching.
    if sCommand == "LUA_ACTION" then
        local resolved = tParams.ACTION or tParams.Action or tParams.action
        if not resolved then
            -- Some Composer builds use a different key; take the first value
            -- that matches a command we know.
            for k, v in pairs(tParams) do
                log(LVL.TRACE, "LUA_ACTION param %s = %s", tostring(k), tostring(v))
                if type(v) == "string" and v ~= "" then resolved = resolved or v end
            end
        end
        if not resolved then
            log(LVL.WARN, "LUA_ACTION received with no action name")
            return
        end
        sCommand = resolved
    end

    log(LVL.DEBUG, "Action: %s", tostring(sCommand))

    -- Messages from the UniFi Protect Setup driver (C4:SendToDevice).
    if sCommand == "SET_PROTECT_CONFIG" then
        applyConfig(tParams)
        return
    elseif sCommand == "IDENTIFY_CAMERA" then
        -- The setup driver is looking for camera drivers it did not create.
        local parent = tonumber(tParams.parent_device_id)
        if parent then
            g.parentId = parent
            C4:SendToDevice(parent, "ADOPT_RESPONSE", {
                device_id = tostring(C4:GetDeviceID()),
                camera_id = g.cameraId or "",
            })
        end
        return
    end

    if sCommand == "TestConnection" then testConnection()
    elseif sCommand == "DiscoverCameras" then discoverCameras(false)
    elseif sCommand == "FetchAliases" then fetchAliases()
    elseif sCommand == "EnableRtsp" then enableRtspStreams()
    elseif sCommand == "Diagnostics" then runDiagnostics()
    elseif sCommand == "ShowUrls" then
        print("[UniFiProtect] --- what the proxy receives ---")
        print("[UniFiProtect] streams:   " .. buildStreamsXml({}))
        print("[UniFiProtect] legacy rtsp qs: " .. tostring(ReceivedFromProxy(5001,"GET_RTSP_H264_QUERY_STRING",{})))
        print("[UniFiProtect] Legacy mode: the proxy builds URLs as scheme://<Hostname>:<Port>/ + the")
        print("[UniFiProtect]   strings above. Director tunnels them for remote clients (http_tunnel).")
        print("[UniFiProtect] IMPORTANT: on the proxy's Camera Properties tab, Hostname/IP must be")
        print("[UniFiProtect]   " .. (g.address ~= "" and g.address or "<your NVR>") .. " and RTSP Port must be 7447.")
        print("[UniFiProtect]   If it still reads 127.0.0.1 / 554, set it there by hand - the legacy")
        print("[UniFiProtect]   stream path is built from those fields, not from this driver.")
        print("[UniFiProtect] Paste the rtsp:// URL into VLC to confirm it plays.")
    elseif sCommand == "SimulateMotion" then fireEvent("motion")
    elseif sCommand == "SimulatePerson" then fireEvent("person")
    elseif sCommand == "SimulateDoorbell" then fireEvent("doorbell")
    else
        log(LVL.WARN, "Unhandled action: %s", tostring(sCommand))
    end
end

--=============================================================================
-- Properties
--=============================================================================
function validate()
    computeStatus()
    return g.address ~= "" and g.apiKey ~= "" and g.cameraId ~= ""
       and aliasFor(g.preferred) ~= nil
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1"))
end

-- Accepts a bare token or a full rtsps:// URL pasted from the Protect UI.
local function cleanAlias(v)
    v = trim(v)
    v = v:gsub("^rtsps?://[^/]+/", "")
    v = v:gsub("%?.*$", "")
    return v
end

function OnPropertyChanged(name)
    local v = Properties[name]
    if v == nil then return end

    if name == "NVR Address" then
        g.address = trim(v)
        pushAddressToProxy()
    elseif name == "API Key" then
        g.apiKey = trim(v)
    elseif name == "Camera" then
        if g.initializing then return end   -- the map is not built yet
        local id = g.cameraMap[v]
        if id and id ~= g.cameraId then
            log(LVL.INFO, "Camera selected: %s (%s)", tostring(v), tostring(id))
            -- UpdateProperty does not re-enter OnPropertyChanged (documented),
            -- so apply the change here rather than relying on a callback.
            g.cameraId = id
            g.rtspEnableTried = false
            g.lastSeen = {}
            g.aliases = { Low = "", Medium = "", High = "" }
            C4:UpdateProperty("Camera ID", id)
            fetchAliases()
        elseif not id and v ~= NO_CAMERA then
            log(LVL.WARN, "'%s' is not in the discovered list - run Discover Cameras", tostring(v))
        end
    elseif name == "Camera ID" then
        local newId = trim(v)
        if g.initializing then
            -- Restoring a stored value, not a user edit. Clearing the alias
            -- table here would discard the aliases loaded moments earlier,
            -- and Properties is walked in undefined order.
            g.cameraId = newId
        elseif newId ~= g.cameraId then
            g.cameraId = newId
            g.lastSeen = {}
            g.aliases = { Low = "", Medium = "", High = "" }
            if g.cameraId ~= "" then fetchAliases() end
        end
    elseif name == "RTSP Alias - Low" then
        g.aliases.Low = cleanAlias(v)
    elseif name == "RTSP Alias - Medium" then
        g.aliases.Medium = cleanAlias(v)
    elseif name == "RTSP Alias - High" then
        g.aliases.High = cleanAlias(v)
    elseif name == "Snapshots" then
        g.snapshots = (v ~= "Off")
        if not g.initializing then startSnapshotServer() end
    elseif name == "Controller Address" then
        if not g.initializing and g.snapshots then startSnapshotServer() end
    elseif name == "Enable RTSP Automatically" then
        g.autoEnableRtsp = (v == "Yes")
    elseif name == "RTSP Port" then
        local p = tonumber(v)
        if p and p > 0 and p < 65536 then
            g.rtspPort = p
            g.portCorrections, g.portWarned = 0, false
            if not g.initializing then pushPortsToProxy() end
        end
    elseif name == "Preferred Quality" then
        g.preferred = v
    elseif name == "Event Polling Interval" then
        g.pollInterval = POLL_MS[v] or 0
        if not g.initializing then startPolling() end
    elseif name == "Adaptive Polling" then
        g.adaptive = (v == "Yes")
        if not g.initializing then startPolling() end
    elseif name == "Adaptive Burst" then
        g.burstSeconds = tonumber(v) or 30
    elseif name == "Detect Person" then
        g.detect.person = (v == "Yes")
    elseif name == "Detect Vehicle" then
        g.detect.vehicle = (v == "Yes")
    elseif name == "Detect Animal" then
        g.detect.animal = (v == "Yes")
    elseif name == "Detect Package" then
        g.detect.package = (v == "Yes")
    elseif name == "Event Hold Time" then
        g.holdTime = tonumber(v) or 5
    elseif name == "Log Mode" then
        g.logMode = v
    elseif name == "Log Level" then
        g.logLevel = tonumber(tostring(v):sub(1, 1)) or 2
        if g.debugTimer then g.debugTimer:Cancel(); g.debugTimer = nil end
        if g.logLevel >= LVL.DEBUG then
            g.debugTimer = C4:SetTimer(8 * 60 * 60 * 1000, function()
                C4:UpdateProperty("Log Level", "2 - Warning")
                g.logLevel = LVL.WARN
                g.debugTimer = nil
                log(LVL.INFO, "Debug logging auto-disabled after 8 hours")
            end)
        end
    end

    -- Stream URLs may have changed; tell navigators to drop cached ones.
    if name:find("RTSP Alias") or name == "NVR Address" or name == "Preferred Quality" then
        C4:SendToProxy(CAMERA_BINDING, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY")
    end

    computeStatus()
end

--=============================================================================
-- Lifecycle
--=============================================================================
function OnDriverInit()
    C4:AddVariable("MOTION_DETECTED",  "false", "BOOL", true)
    C4:AddVariable("PERSON_DETECTED",  "false", "BOOL", true)
    C4:AddVariable("VEHICLE_DETECTED", "false", "BOOL", true)
    C4:AddVariable("ANIMAL_DETECTED",  "false", "BOOL", true)
    C4:AddVariable("PACKAGE_DETECTED", "false", "BOOL", true)
    C4:AddVariable("DOORBELL_RING",    "false", "BOOL", true)
end

function OnDriverLateInit()
    -- Explicit order: logging first so startup is visible, then connection
    -- settings, then the camera, then its aliases. pairs() order is undefined
    -- and a bad order silently discards stored aliases.
    local ORDER = {
        "Log Mode", "Log Level",
        "NVR Address", "API Key",
        "Camera ID",
        "RTSP Alias - Low", "RTSP Alias - Medium", "RTSP Alias - High",
        "RTSP Port", "Enable RTSP Automatically", "Preferred Quality", "Snapshots", "Controller Address",
        "Detect Person", "Detect Vehicle", "Detect Animal", "Detect Package",
        "Event Hold Time",
        "Event Polling Interval", "Adaptive Polling", "Adaptive Burst",
    }

    g.initializing = true
    local done = {}
    for _, name in ipairs(ORDER) do
        if Properties[name] ~= nil then
            done[name] = true
            pcall(OnPropertyChanged, name)
        end
    end
    for name, _ in pairs(Properties) do
        if not done[name] then pcall(OnPropertyChanged, name) end
    end
    -- Polling starts last, once everything is loaded.
    g.initializing = false

    local haveAlias = (g.aliases.Low ~= "" or g.aliases.Medium ~= "" or g.aliases.High ~= "")
    log(LVL.INFO, "Loaded: camera=%s aliases=%s",
        g.cameraId ~= "" and g.cameraId or "(none)",
        haveAlias and "yes" or "NONE")
    C4:UpdateProperty("Driver Version", DRIVER_VERSION)
    log(LVL.INFO, "UniFi Protect Camera driver %s started", DRIVER_VERSION)
    checkDirectorVersion()
    -- Ports first, always: a fresh instance has no address yet but must still
    -- be told 7447, or it inherits 554 and nothing ever streams. Repeated
    -- after a delay because a brand-new device's proxy may not be listening yet.
    pushPortsToProxy()
    C4:SetTimer(5000,  function() pushPortsToProxy() end)
    C4:SetTimer(30000, function() pushPortsToProxy() end)
    if g.address ~= "" then
        pushAddressToProxy()
        -- Repopulate the dropdown; the list itself does not persist across restarts.
        discoverCameras(true)
    end
    if g.cameraId ~= "" and not haveAlias then
        log(LVL.INFO, "No stored aliases - fetching from Protect")
        fetchAliases()
    end
    startSnapshotServer()
    if validate() then
        testConnection()
        startPolling()
    end
end

function OnDriverDestroyed()
    if g.pollTimer then g.pollTimer:Cancel() end
    if g.reaperTimer then g.reaperTimer:Cancel() end
    if g.serverPort then C4:DestroyServer(g.serverPort) end
    g.snapData = nil
    if g.debugTimer then g.debugTimer:Cancel() end
    for _, t in pairs(g.holdTimers) do
        if t then t:Cancel() end
    end
end
