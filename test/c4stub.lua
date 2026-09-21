--[[
    c4stub.lua — a fake Control4 runtime so driver.lua can be exercised offline.

    Records everything the driver does (property writes, proxy notifications,
    variables, events, timers, HTTP) so tests can assert on it.

    Note the colon-call convention: the driver calls C4:Foo(), so every stub
    receives `self` as its first argument.
--]]

local M = {}

function M.new(opts)
    opts = opts or {}
    local st = {
        props      = {},
        lists      = {},
        vars       = {},
        events     = {},
        proxy      = {},   -- {command=, params=}
        timers     = {},
        requests    = {},  -- {method=, url=, body=, headers=}
        now        = 1000000,
        deviceId   = opts.deviceId or 100,
        roomId     = opts.roomId or 7,
        sentToDevice = {},   -- {device=, command=, params=}
        added      = {},      -- {file=, room=, name=, id=}
        renamed    = {},
        persist    = {},
        servers    = {},      -- CreateServer calls
        destroyed  = {},
        existingDevices = opts.existingDevices or {},
        nextDeviceId = 500,
        -- Real C4:url() is asynchronous. With async=true, responses queue up
        -- and are delivered only by st.flush(). The synchronous default hid a
        -- race where status was computed before the HTTP reply arrived.
        async      = opts.async or false,
        pending    = {},
        routes     = opts.routes or {},
        directorVersion = opts.directorVersion or "3.4.3.1",
    }

    local C4 = {}

    function C4:AddVariable(n, v) st.vars[n] = v end
    function C4:SetVariable(n, v) st.vars[n] = v end
    function C4:FireEvent(id) table.insert(st.events, id) end
    function C4:UpdateProperty(n, v) st.props[n] = tostring(v) end
    function C4:UpdatePropertyList(n, list, default)
        st.lists[n] = list
        if default ~= nil then st.props[n] = default end
    end
    function C4:ErrorLog(s) end
    function C4:DebugLog(s) end
    function C4:GetVersionInfo() return { version = st.directorVersion } end
    function C4:GetControllerNetworkAddress() return "192.0.2.50" end

    function C4:SetTimer(ms, fn, repeating)
        local t = { ms = ms, fn = fn, repeating = repeating, cancelled = false }
        t.Cancel = function(self2) t.cancelled = true end
        table.insert(st.timers, t)
        return t
    end

    function C4:SendToProxy(binding, command, params, mtype)
        table.insert(st.proxy, { binding = binding, command = command, params = params })
    end

    function C4:CreateServer(port, delim, udp, id)
        table.insert(st.servers, { port = port, id = id })
        return true
    end
    function C4:DestroyServer(port) table.insert(st.destroyed, port) end
    function C4:GetDeviceID() return st.deviceId end
    function C4:RoomGetId() return st.roomId end
    function C4:SendToDevice(dev, cmd, params)
        table.insert(st.sentToDevice, { device = dev, command = cmd, params = params })
    end
    function C4:AddDevice(file, room, name, cb)
        st.nextDeviceId = st.nextDeviceId + 1
        local id = st.nextDeviceId
        table.insert(st.added, { file = file, room = room, name = name, id = id })
        if cb then cb(id, { [tostring(id + 1000)] = id + 1000 }) end
        return id
    end
    function C4:RenameDevice(id, name) table.insert(st.renamed, { id = id, name = name }) end
    function C4:GetDevicesByC4iName(name) return st.existingDevices end
    function C4:PersistSetValue(k, v) st.persist[k] = v end
    function C4:PersistGetValue(k) return st.persist[k] end
    function C4:ServerSend() end
    function C4:ServerCloseClient() end

    local function respond(method, url, body, headers, onDone, self)
        table.insert(st.requests, {
            method = method, url = url, body = body, headers = headers or {},
        })
        local code, payload = 200, "{}"
        for pattern, r in pairs(st.routes) do
            if url:find(pattern) then
                -- A route may be a function of (method, url) so a test can
                -- model state changes, e.g. RTSP switching on after a POST.
                if type(r) == "function" then
                    local rc, rb = r(method, url)
                    code, payload = rc or 200, rb or "{}"
                else
                    code = r.code or 200
                    payload = r.body or "{}"
                end
            end
        end
        if onDone then
            local deliver = function()
                onDone(self, { { code = code, body = payload, headers = {} } }, 0, "")
            end
            if st.async then table.insert(st.pending, deliver) else deliver() end
        end
    end

    function C4:url()
        local o = {}
        function o:OnDone(fn) self._done = fn; return self end
        function o:SetOption() return self end
        function o:Get(url, headers) respond("GET", url, nil, headers, self._done, self); return self end
        function o:Post(url, body, headers) respond("POST", url, body, headers, self._done, self); return self end
        function o:Patch(url, body, headers) respond("PATCH", url, body, headers, self._done, self); return self end
        return o
    end

    st.C4 = C4
    st.Properties = st.props

    -- Loads the driver against this stub. Globals are set first because
    -- driver.lua reads Properties at load time.
    function st.load(path)
        _G.C4 = C4
        _G.Properties = st.props
        dofile(assert(path, "st.load needs the path to a driver.lua"))
        return st
    end

    -- Simulates a user editing a property in Composer.
    function st.set(name, value)
        st.props[name] = value
        OnPropertyChanged(name)
    end

    -- Applies stored values the way Composer does on load: all at once,
    -- in arbitrary order, then OnDriverLateInit.
    function st.reload(stored)
        for k, v in pairs(stored) do st.props[k] = v end
        OnDriverLateInit()
    end

    -- Deliver queued HTTP replies, including any issued while delivering.
    function st.flush()
        local rounds = 0
        while #st.pending > 0 and rounds < 50 do
            local batch = st.pending
            st.pending = {}
            for _, fn in ipairs(batch) do fn() end
            rounds = rounds + 1
        end
    end

    -- One-shot timers fire once, as on a real controller. Snapshot the list
    -- first: firing may schedule new timers, which belong to the next round.
    function st.fireTimers(filter)
        local due = {}
        for _, t in ipairs(st.timers) do
            if not t.cancelled and not t.fired and (not filter or filter(t)) then
                table.insert(due, t)
            end
        end
        for _, t in ipairs(due) do
            if not t.repeating then t.fired = true end
            t.fn()
        end
    end

    function st.proxyCommands()
        local out = {}
        for _, p in ipairs(st.proxy) do table.insert(out, p.command) end
        return out
    end

    function st.sentTo(command)
        for _, p in ipairs(st.proxy) do
            if p.command == command then return p end
        end
    end

    return st
end

return M
