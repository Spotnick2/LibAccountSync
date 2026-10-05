-- test_ctl.lua: the REAL vendored ChatThrottleLib v32 carries the library's
-- frames. Every other file uses the stub; this one checks the library's calls
-- against the code that actually paces them in game: the argument order,
-- the queue, the callback (arg, didSend, result), and the 255-byte cap.

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- What v32 needs from the client, beyond the stubs.
local clock = 100
GetTime = function() return clock end
GetFramerate = function() return 60 end
Enum = {}
table.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
function hooksecurefunc(t, name, fn)
    if type(t) == "string" then t, name, fn = _G, t, name end
    local orig = t[name]
    t[name] = function(...)
        local r = { orig(...) }
        fn(...)
        return unpack(r, 1, table.maxn(r))
    end
end
SendChatMessage = function() end
C_ChatInfo.SendAddonMessage = function() return 0 end
C_ChatInfo.SendAddonMessageLogged = function() return 0 end
-- WoW's xpcall passes its extra arguments to the function (v32 relies on it).
do
    local rawXpcall = xpcall
    function xpcall(fn, handler, ...)
        local n, args = select("#", ...), { ... }
        return rawXpcall(function() return fn(unpack(args, 1, n)) end, handler)
    end
end

local function pump(seconds)
    local CTL = ChatThrottleLib
    local onUpdate = CTL.Frame:GetScript("OnUpdate")
    for _ = 1, math.floor(seconds / 0.1) do
        clock = clock + 0.1
        onUpdate(CTL.Frame, 0.1)
    end
end

-- A session whose ChatThrottleLib is the vendored file, not the stub.
local function realSession()
    local lib, inst, store = session(nil, { before = function()
        rawset(_G, "ChatThrottleLib", nil)
    end })
    return lib, inst, store
end

do
    local lib, inst, store = realSession()
    local CTL = ChatThrottleLib
    eq(CTL.version, 32, "the vendored ChatThrottleLib is v32")
    check(type(CTL.BNSendGameData) == "function", "  with BNSendGameData")
    pump(6)                                  -- past its start-up hard throttle
    local B = Peer.new({})
    inst.Rescan()
    pump(2)
    check(B:ourHello() ~= nil, "our hello goes through the real library")
    B:deliver(B:hello({ key = B.key }))
    pump(2)
    WoW.sent = {}
    local got = {}
    local payload = string.rep("snapshot|", 600)
    eq(inst.Send(payload, function(s, status, reason) got[#got + 1] = status end), 1, "Send queues to the peer")
    pump(20)
    local r = B:received("GlassChat", store)
    eq(#r, 1, "one stream arrives")
    eq(r[1] and r[1].payload, payload, "  whole, through the real pacing")
    check(r[1] and r[1].macOk, "  with a good MAC")
    eq(#got, 1, "onResult once")
    eq(got[1], "sent", "  sent")
    local maxLen = 0
    for _, m in ipairs(WoW.sent) do if #m.text > maxLen then maxLen = #m.text end end
    check(maxLen <= 255, "every message within the real 255-byte check")

    -- A refusal that is not the throttle: the callback reports it, once.
    got = {}
    WoW.sendResults = { 12 }
    inst.Send("short", function(s, status, reason) got[#got + 1] = reason end)
    pump(5)
    eq(got[1], "offline", "an offline refusal reaches onResult as offline")
end

done("test_ctl")
