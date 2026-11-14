-- wow_stubs.lua: the client APIs LibAccountSync reads, over WowTestKit's core.
-- dofile("tests/wow_stubs.lua") FIRST in every test; drive it via the WoW table.
--
-- The mechanics are WowTestKit's (tests/kit.lua loads the commit and the build
-- tests/kit.pin names): strict globals, secrets (WoW.Secret, newproxy values
-- that throw; a pcall that swallows a touch is counted and fails done()),
-- frames that record every method called, event names checked against the
-- build, timers, check / eq / done. This file adds, each confirmed in the
-- build's API dump:
-- - BATTLE.NET as measured on 70124 (AltStable #58, docs/SYNC-DISCOVERY.md),
--   ported from AltStable's tests/wow_stubs.lua 1407-1494: game account ids
--   are handles local to this client, an unknown id is TargetRequired (6),
--   an offline one TargetOffline (12), BN_CHAT_MSG_ADDON delivers
--   (prefix, text, "WHISPER", senderID).
-- - A CLOCK the tests move: time(), GetServerTime(), GetTime() and every
--   C_Timer callback follow WoW.advance(seconds).
-- - CHATTHROTTLELIB as a stub (version 10000, so the vendored v32 file loads
--   and steps aside), with v32's checks: a known priority, chat type WHISPER,
--   at most 255 bytes, and the callback (arg, didSend, result).

dofile("tests/kit.lua")

--------------------------------------------------------------------------------
-- Clock
--------------------------------------------------------------------------------
-- WoW.now is the epoch (time() and GetServerTime() read it). GetTime() is the
-- client's uptime, as on the client (the probe logs read 374632.4), not the
-- core's WoW.now: the library hashes it into its entropy, and an epoch there
-- would change every nonce the tests compare.

function time() return WoW.now end
function GetServerTime() return WoW.now end
function GetTime() return WoW.now - 1759990000 end
function debugprofilestop() return (WoW.now - 1759990000) * 1000 end
function fastrandom(a, b) return math.random(a, b) end

-- A second at a time, as the core's notes ask of a clock whose timers start
-- more timers: one scheduled inside a callback counts from that second, not
-- from the end of the whole advance.
local coreAdvance = WoW.advance
function WoW.advance(seconds)
    for _ = 1, seconds do coreAdvance(1) end
end

--------------------------------------------------------------------------------
-- The player
--------------------------------------------------------------------------------

function UnitGUID(unit) if unit == "player" then return WoW.player.guid end end
-- On Forever the player's surname is UnitName's SECOND return (AltStable
-- #56); Battle.net's characterName is the whole "Name Surname".
function UnitName(unit) if unit == "player" then return WoW.player.name, WoW.player.surname end end
function UnitFactionGroup(unit) if unit == "player" then return WoW.player.faction, WoW.player.faction end end
function GetRealmName() return WoW.player.realm end
function IsLoggedIn() return WoW.loggedIn == true end
-- The client's own region (in the dump) and project (a runtime global, not in
-- the dump): measured equal to Battle.net's regionID and wowProjectID (#7).
-- WoW.clientRegion = nil / rawset(_G, "WOW_PROJECT_ID", nil) model their absence.
function GetCurrentRegion() return WoW.clientRegion end

--------------------------------------------------------------------------------
-- Chat
--------------------------------------------------------------------------------

C_ChatInfo = {}
function C_ChatInfo.RegisterAddonMessagePrefix(prefix)
    if WoW.prefixResult and WoW.prefixResult ~= 0 then return WoW.prefixResult end
    WoW.prefixes[prefix] = true
    return 0
end

function geterrorhandler() return function(err) table.insert(WoW.errors, err) end end
function securecallfunction(fn, ...)
    local r = { pcall(fn, ...) }
    if not r[1] then geterrorhandler()(r[2]); return end
    return unpack(r, 2, table.maxn(r))
end

--------------------------------------------------------------------------------
-- Battle.net
--------------------------------------------------------------------------------
-- WoW.bn.accounts[id] = { characterName, playerGuid, isOnline, clientProgram,
--   wowProjectID, regionID, isInCurrentRegion, factionName, realmName,
--   bnetAccountID } declares an account this client can see.
-- WoW.bn.blank = true: our own presence right after a login (measured): no
--   account record, our own game account with no character.
-- WoW.bn.friends = { { 9, 10 }, ... }: each friend's online game account ids.
-- WoW.bn.secret = { field = true }: those fields read as secrets everywhere.

C_BattleNet = {}

local function maybeSecret(t)
    if not t then return nil end
    for k in pairs(WoW.bn.secret) do t[k] = WoW.Secret(k) end
    return t
end

local function bnSelf()
    if WoW.bn.blank then
        return { gameAccountID = WoW.bn.myId, isOnline = true, clientProgram = "WoW", isInCurrentRegion = true }
    end
    -- Battle.net's whole name, by the same rule the library reads UnitName.
    local whole = WoW.player.name
    if not whole:find(" ", 1, true) and type(WoW.player.surname) == "string" then
        whole = whole .. " " .. WoW.player.surname
    end
    return { gameAccountID = WoW.bn.myId, characterName = whole, playerGuid = WoW.player.guid,
             isOnline = true, clientProgram = "WoW", wowProjectID = WoW.bn.project, regionID = WoW.bn.region,
             isInCurrentRegion = true, factionName = WoW.player.faction, realmName = WoW.player.realm }
end

local function bnCopy(t, id)
    if not t then return nil end
    local c = {}
    for k, v in pairs(t) do if k ~= "bnetAccountID" and k ~= "battleTag" then c[k] = v end end
    c.gameAccountID = id
    return maybeSecret(c)
end

function C_BattleNet.GetGameAccountInfoByID(id)
    if id == WoW.bn.myId then return bnSelf() end
    return bnCopy(WoW.bn.accounts[id], id)
end

function C_BattleNet.GetGameAccountInfoByGUID(guid)
    if guid == WoW.player.guid then
        if WoW.bn.blank then return nil end
        return bnSelf()
    end
    for id, a in pairs(WoW.bn.accounts) do
        if a.playerGuid == guid then return bnCopy(a, id) end
    end
end

function C_BattleNet.GetAccountInfoByGUID(guid)
    if guid == WoW.player.guid then
        if WoW.bn.me == nil or WoW.bn.blank then return nil end
        return { bnetAccountID = WoW.bn.me, battleTag = WoW.bn.tag, gameAccountInfo = bnSelf() }
    end
    for id, a in pairs(WoW.bn.accounts) do
        if a.playerGuid == guid then
            local tag = a.battleTag
            if tag == nil and a.bnetAccountID ~= nil then
                tag = (a.bnetAccountID == WoW.bn.me) and WoW.bn.tag or ("Other#" .. a.bnetAccountID)
            end
            if WoW.bn.secret.battleTag then tag = WoW.Secret("battleTag") end
            return { bnetAccountID = a.bnetAccountID, battleTag = tag, gameAccountInfo = bnCopy(a, id) }
        end
    end
end

-- A result queued in WoW.sendResults decides first; then an unknown id is
-- TargetRequired and an offline one TargetOffline, as measured.
function C_BattleNet.SendGameData(id, prefix, text)
    local result = table.remove(WoW.sendResults, 1)
    if result == nil then
        local a = (id == WoW.bn.myId) and bnSelf() or WoW.bn.accounts[id]
        result = (a == nil) and 6 or (a.isOnline and 0 or 12)
    end
    if result ~= 0 then return result end
    table.insert(WoW.sent, { prefix = prefix, text = text, target = id, prio = WoW.pendingPrio,
                             queue = WoW.pendingQueue })
    return 0
end

function BNFeaturesEnabledAndConnected() return WoW.bn.connected ~= false end
function BNGetNumFriends() return #WoW.bn.friends, #WoW.bn.friends end
function C_BattleNet.GetFriendNumGameAccounts(i) return #(WoW.bn.friends[i] or {}) end
-- WoW.bn.friendInfoNil: the API answers nil for a friend's game account, as
-- its declaration allows: a gap the elimination must not trust.
function C_BattleNet.GetFriendGameAccountInfo(i, j)
    local id = (WoW.bn.friends[i] or {})[j]
    if not id or WoW.bn.friendInfoNil then return nil end
    return C_BattleNet.GetGameAccountInfoByID(id) or { gameAccountID = id }
end
-- A friend's account: its BattleTag, from its first game account's record
-- (as GetAccountInfoByGUID derives it), or WoW.bn.friendTags[i].
function C_BattleNet.GetFriendAccountInfo(i)
    local ids = WoW.bn.friends[i]
    if not ids then return nil end
    local a = WoW.bn.accounts[ids[1]] or {}
    local tag = (WoW.bn.friendTags or {})[i] or a.battleTag
    if tag == nil and a.bnetAccountID ~= nil then tag = "Other#" .. a.bnetAccountID end
    if WoW.bn.secret.battleTag then tag = WoW.Secret("battleTag") end
    return { bnetAccountID = a.bnetAccountID, battleTag = tag, isFriend = true }
end
-- presenceID, battleTag: available even while our presence is blank.
-- WoW.bn.presenceID models a presence id from ANOTHER namespace.
function BNGetInfo()
    return WoW.bn.presenceID or WoW.bn.me, WoW.bn.secretSelfTag and WoW.Secret("own battleTag") or WoW.bn.tag
end

--------------------------------------------------------------------------------
-- ChatThrottleLib (stub; test_ctl runs the real vendored v32)
--------------------------------------------------------------------------------

local CTL_PRIORITIES = { BULK = true, NORMAL = true, ALERT = true }
ChatThrottleLib = {
    version = 10000,
    BNSendGameData = function(self, prio, prefix, text, chattype, gameAccountID, q, callbackFn, callbackArg)
        if not CTL_PRIORITIES[prio] or not gameAccountID or chattype ~= "WHISPER" then
            error("ChatThrottleLib:BNSendGameData(): bad arguments", 2)
        end
        if #text > 255 then error("ChatThrottleLib:BNSendGameData(): message length cannot exceed 255 bytes", 2) end
        local function attempt()
            WoW.pendingPrio, WoW.pendingQueue = prio, q
            local ok, r = pcall(C_BattleNet.SendGameData, gameAccountID, prefix, text)
            WoW.pendingPrio, WoW.pendingQueue = nil, nil
            if not ok then geterrorhandler()(r); r = 9 end
            if callbackFn then securecallfunction(callbackFn, callbackArg, r == 0, r) end
        end
        if WoW.ctlDefer then table.insert(WoW.ctlQueue, attempt) else attempt() end
    end,
}
local ctlStub = ChatThrottleLib

-- Run every send ChatThrottleLib is holding (WoW.ctlDefer = true holds them).
function WoW.ctlDrain(order)
    local q = WoW.ctlQueue
    WoW.ctlQueue = {}
    if order == "reverse" then
        for i = #q, 1, -1 do q[i]() end
    else
        for _, f in ipairs(q) do f() end
    end
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

table.insert(WoW.onReset, function()
    WoW.now = 1760000000
    WoW.prefixes = {}
    WoW.sent = {}
    WoW.sendResults = {}
    WoW.errors = {}
    WoW.ctlDefer = false
    WoW.ctlQueue = {}
    WoW.loggedIn = false
    WoW.clientRegion = 90
    rawset(_G, "WOW_PROJECT_ID", 18)
    WoW.player = { name = "Malas", guid = "Player-1-0000000A", realm = "Classic Beta PvE", faction = "Alliance" }
    WoW.bn = { me = 1, myId = 2, project = 18, region = 90, tag = "Owner#1", connected = true,
               accounts = {}, friends = {}, secret = {} }
    rawset(_G, "ChatThrottleLib", ctlStub)
end)

-- A client that can't tell its own game or region (the r2 behaviour when our
-- presence is blank and nothing is stored).
function WoW.noClientConstants()
    WoW.clientRegion = nil
    rawset(_G, "WOW_PROJECT_ID", nil)
end

-- A fresh client: no LibStub, so the next load starts the library from scratch.
function WoW.resetLibStub()
    rawset(_G, "LibStub", nil)
end

WoW.reset()

-- The two bundled files' own globals may read nil: each checks for an earlier copy.
Kit.strict({ LibStub = true, ChatThrottleLib = true })
