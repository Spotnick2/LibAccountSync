----------------------------------------------------------------------------
-- LibAccountSync Probe: the in-game measurements of docs/PLAN.md section 7,
-- run with two accounts on the same Battle.net account (and a friend for 9).
-- Everything goes to a wire log in SavedVariables (written on /reload and on
-- logout); Tools/read-wirelog.py prints it from every account's file.
--
--   /lasprobe status          the library's Diagnostics (who is ours, and why)
--   /lasprobe send <bytes>    a payload of that size to every own account (1, 5)
--   /lasprobe bytes           all 256 byte values; the receiver checks them (2)
--   /lasprobe hash            SHA-256 cost for 16 and 32 KB (4)
--   /lasprobe secrets         which Battle.net fields read as secret (6)
--   /lasprobe region          project and region, ours and each record's (8)
--   /lasprobe friends         the friends list's completeness now (7; also
--                             logged at login +5/15/30/60/90 s)
--   /lasprobe ids             every id's raw record: blank? online? (9)
--   /lasprobe ping <id>       a raw ping on the probe's own prefix to any id,
--                             e.g. a friend on Appear Offline (9)
--   /lasprobe presence        BNGetInfo's presenceID vs our bnetAccountID (10)
--   /lasprobe clear           empty the log
-- Received messages (and how long since the last send) are logged as they come.
----------------------------------------------------------------------------

local PROBE_PREFIX = "LASProbe"
local db

local function Where()
    local name = UnitName("player") or "?"
    local realm = GetRealmName() or "?"
    return name .. "-" .. realm
end

-- Is it a secret? Asked before ANY comparison or truth test of a client value.
local function IsS(v) return issecretvalue ~= nil and issecretvalue(v) == true end

-- A value for the log, never touching a secret.
local function V(v)
    if IsS(v) then return "<secret>" end
    if type(v) == "string" then return ("%q"):format(v) end
    return tostring(v)
end

local function Log(text)
    local line = ("%s %s %s"):format(date("%H:%M:%S"), Where(), text)
    if db then
        db.log = db.log or {}
        table.insert(db.log, line)
        while #db.log > 3000 do table.remove(db.log, 1) end
    end
    print("|cff88ccffLASProbe|r " .. text)
end

local Sync
local lastSendAt

local function Status()
    Log("== status ==")
    for line in Sync.Diagnostics() do Log("  " .. line) end
end

local function Payload(n)
    local t = {}
    for i = 1, n do t[i] = string.char((i * 7) % 256) end
    return table.concat(t)
end

local function Sized(n)
    local head = "SIZE|" .. n .. "|"
    return head .. Payload(math.max(0, n - #head))
end

local function Send(n)
    n = math.min(tonumber(n) or 1000, 32768)
    local payload = Sized(n)
    lastSendAt = debugprofilestop()
    local count, why = Sync.Send(payload, function(sender, status, reason)
        Log(("  onResult %s: %s %s after %.0f ms"):format(V(sender.name), status, tostring(reason),
            debugprofilestop() - lastSendAt))
    end)
    Log(("send %d bytes -> %s %s"):format(#payload, tostring(count), tostring(why)))
end

local function Bytes()
    local t = {}
    for b = 0, 255 do t[#t + 1] = string.char(b) end
    local payload = "BYTES|" .. table.concat(t) .. table.concat(t)
    lastSendAt = debugprofilestop()
    Log(("bytes: all 256 values twice -> %s"):format(tostring((Sync.Send(payload)))))
end

local function OnMessage(payload, sender, sid)
    local kind = payload:match("^(%u+)|") or "?"
    local verdict = ""
    if kind == "BYTES" then
        local t = {}
        for b = 0, 255 do t[#t + 1] = string.char(b) end
        verdict = payload == "BYTES|" .. table.concat(t) .. table.concat(t) and "BYTES OK" or "BYTES CORRUPTED"
    elseif kind == "SIZE" then
        local n = tonumber(payload:match("^SIZE|(%d+)|"))
        verdict = (n and payload == Sized(n)) and ("SIZE OK " .. n) or "SIZE CORRUPTED"
    end
    Log(("received %d bytes from %s (%s, %s) sid %s: %s"):format(#payload, V(sender.name), V(sender.guid),
        sender.proven, tostring(sid), verdict))
end

local function Hash()
    local T = LibStub("LibAccountSync-1.0")._test
    for _, kb in ipairs({ 1, 16, 32 }) do
        local s = Payload(kb * 1024)
        local t0 = debugprofilestop()
        T.SHA256(s)
        Log(("hash: SHA-256 of %d KB took %.0f ms (threshold 100 ms in one frame)"):format(kb, debugprofilestop() - t0))
    end
end

local GAME_FIELDS = { "isOnline", "clientProgram", "isInCurrentRegion", "characterName", "playerGuid",
                      "wowProjectID", "regionID", "factionName", "realmName", "gameAccountID" }

local function Record(label, g)
    if IsS(g) then Log("  " .. label .. ": the record itself is <secret>"); return end
    if type(g) ~= "table" then Log("  " .. label .. ": " .. V(g)); return end
    local parts = {}
    for _, k in ipairs(GAME_FIELDS) do parts[#parts + 1] = k .. "=" .. V(g[k]) end
    Log("  " .. label .. ": " .. table.concat(parts, " "))
end

local function Ids()
    Log("== ids (raw records) ==")
    for id = 1, 128 do
        local ok, g = pcall(C_BattleNet.GetGameAccountInfoByID, id)
        if ok and (IsS(g) or type(g) == "table") then Record("id " .. id, g) end
    end
end

local function Secrets()
    Log("== secrets ==")
    local any = false
    for id = 1, 128 do
        local ok, g = pcall(C_BattleNet.GetGameAccountInfoByID, id)
        if ok and IsS(g) then
            Log("  id " .. id .. ": record is secret"); any = true
        elseif ok and type(g) == "table" then
            for _, k in ipairs(GAME_FIELDS) do
                if IsS(g[k]) then Log(("  id %d: %s is secret"):format(id, k)); any = true end
            end
        end
    end
    local ok, a = pcall(C_BattleNet.GetAccountInfoByGUID, UnitGUID("player"))
    if ok and IsS(a) then
        Log("  own account record is secret"); any = true
    elseif ok and type(a) == "table" then
        for _, k in ipairs({ "bnetAccountID", "battleTag" }) do
            if IsS(a[k]) then Log("  own account " .. k .. " is secret"); any = true end
        end
    end
    local _, presence, tag = pcall(BNGetInfo)
    if IsS(presence) or IsS(tag) then Log("  BNGetInfo returns a secret"); any = true end
    Log(any and "secrets: some fields are secret (see above)" or "secrets: none seen")
end

local function Region()
    Log("== region ==")
    Log("  GetCurrentRegion() -> " .. V(GetCurrentRegion and GetCurrentRegion()))
    Log("  WOW_PROJECT_ID -> " .. V(rawget(_G, "WOW_PROJECT_ID")))
    local ok, a = pcall(C_BattleNet.GetAccountInfoByGUID, UnitGUID("player"))
    Record("own (GetAccountInfoByGUID.gameAccountInfo)", (ok and not IsS(a) and type(a) == "table") and a.gameAccountInfo or a)
    local okG, g = pcall(C_BattleNet.GetGameAccountInfoByGUID, UnitGUID("player"))
    Record("own (GetGameAccountInfoByGUID)", okG and g or nil)
    Ids()
end

local loginAt = GetTime()
local function Friends(label)
    local ok, n = pcall(BNGetNumFriends)
    if not ok or IsS(n) or type(n) ~= "number" then Log("friends " .. label .. ": BNGetNumFriends failed"); return end
    local accounts, missing = 0, 0
    for i = 1, n do
        local okN, m = pcall(C_BattleNet.GetFriendNumGameAccounts, i)
        if okN and not IsS(m) and type(m) == "number" then
            for j = 1, m do
                local okI, gi = pcall(C_BattleNet.GetFriendGameAccountInfo, i, j)
                if okI and not IsS(gi) and type(gi) == "table" and not IsS(gi.gameAccountID)
                    and type(gi.gameAccountID) == "number" then
                    accounts = accounts + 1
                else
                    missing = missing + 1
                end
            end
        else
            missing = missing + 1
        end
    end
    Log(("friends %s (%.0f s after login): %s friends, %d game accounts, %d gaps"):format(label,
        GetTime() - loginAt, tostring(n), accounts, missing))
end

local function Presence()
    local _, presenceID, tag = pcall(BNGetInfo)
    local ok, a = pcall(C_BattleNet.GetAccountInfoByGUID, UnitGUID("player"))
    local id, t = "?", "?"
    if ok and IsS(a) then id, t = "<secret>", "<secret>"
    elseif ok and type(a) == "table" then id, t = V(a.bnetAccountID), V(a.battleTag) end
    Log(("presence: BNGetInfo presenceID=%s tag=%s; GetAccountInfoByGUID bnetAccountID=%s tag=%s"):format(
        V(presenceID), V(tag), id, t))
end

local function Ping(id)
    id = tonumber(id)
    if not id then Log("ping: give a game account id (see /lasprobe ids)"); return end
    local ok, r = pcall(C_BattleNet.SendGameData, id, PROBE_PREFIX, "PING|" .. Where() .. "|" .. time())
    Log(("ping %d -> %s"):format(id, ok and V(r) or ("ERROR " .. tostring(r))))
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("BN_CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" and ... == "LibAccountSyncProbe" then
        LibAccountSyncProbeDB = LibAccountSyncProbeDB or {}
        db = LibAccountSyncProbeDB
        db.sync = db.sync or {}
    elseif event == "PLAYER_LOGIN" then
        C_ChatInfo.RegisterAddonMessagePrefix(PROBE_PREFIX)
        for _, s in ipairs({ 5, 15, 30, 60, 90 }) do
            C_Timer.After(s, function() Friends("+" .. s .. " s") end)
        end
        C_Timer.After(8, Status)
    elseif event == "BN_CHAT_MSG_ADDON" then
        local prefix, text, _, senderID = ...
        if IsS(prefix) or prefix ~= PROBE_PREFIX then return end
        local ok, g = pcall(C_BattleNet.GetGameAccountInfoByID, senderID)
        Log(("PING received from id %s: %s"):format(V(senderID), V(text)))
        Record("  its record", ok and g or nil)
    end
end)

Sync = LibStub("LibAccountSync-1.0"):New({
    addon = "Probe",
    store = function() return LibAccountSyncProbeDB and LibAccountSyncProbeDB.sync end,
    report = function(text, kind) Log(("library %s: %s"):format(tostring(kind), text)) end,
    maxPayload = 32768,
})
Sync.OnMessage(OnMessage)

SLASH_LASPROBE1 = "/lasprobe"
SlashCmdList.LASPROBE = function(msg)
    local cmd, arg = (msg or ""):match("^(%S*)%s*(.-)$")
    if cmd == "status" then Status()
    elseif cmd == "send" then Send(arg)
    elseif cmd == "bytes" then Bytes()
    elseif cmd == "hash" then Hash()
    elseif cmd == "secrets" then Secrets()
    elseif cmd == "region" then Region()
    elseif cmd == "friends" then Friends("now")
    elseif cmd == "ids" then Ids()
    elseif cmd == "ping" then Ping(arg)
    elseif cmd == "presence" then Presence()
    elseif cmd == "clear" then if db then db.log = {} end; Log("log cleared")
    else Log("commands: status, send <bytes>, bytes, hash, secrets, region, friends, ids, ping <id>, presence, clear")
    end
end
