----------------------------------------------------------------------------
-- LibAccountSync Probe: the in-game measurements of docs/PLAN.md section 7,
-- and the in-game check of each release, run with two accounts on the same
-- Battle.net account (and a friend for 7.9). A ForeverProbe module
-- (..\ForeverProbe\docs\GUIDE.md): its lines go to the /fp console and to
-- LibAccountSyncProbeDB.log (written on /reload and on logout), never to
-- chat; Tools/read-wirelog.py prints the log from every account's file.
--
--   /fp las status            the library's Diagnostics (who is ours, and why)
--   /fp las send <bytes>      a payload of that size to every own account (1, 5)
--   /fp las sendto [name]     one payload to one peer, by name or GUID (r4, #14)
--   /fp las kinds             two snapshot kinds, two tags on one store (r5, #17)
--   /fp las messages          four messages on a messages tag (r5, #18)
--   /fp las bytes             all 256 byte values; the receiver checks them (2)
--   /fp las hash              SHA-256 cost for 16 and 32 KB (4)
--   /fp las secrets           which Battle.net fields read as secret (6)
--   /fp las region            project and region, ours and each record's (8)
--   /fp las friends           the friends list's completeness now (7; also
--                             logged at login +5/15/30/60/90 s)
--   /fp las ids               every id's raw record: blank? online? (9)
--   /fp las ping <id>         a raw ping on the probe's own prefix to any id,
--                             e.g. a friend on Appear Offline (9)
--   /fp las presence          BNGetInfo's presenceID vs our bnetAccountID (10)
--   /fp las clear             empty the log
-- Procedures (/fp steps las <name>): check (a release across two own
-- accounts), blank (7.3), relay (7.9). Received messages are checked and
-- logged as they come, with how long since the last send.
----------------------------------------------------------------------------

local ADDON, NS = ...
local MAX_LOG = 3000
local PROBE_PREFIX = "LASProbe"

local Probe = ForeverProbe:Module("LibAccountSyncProbe", { api = 1, cmd = "las" })

local function Where()
    local name = UnitName("player") or "?"
    local realm = GetRealmName() or "?"
    return name .. "-" .. realm
end

-- Is it a secret? Asked before ANY comparison or truth test of a client value.
local function IsS(v) return issecretvalue ~= nil and issecretvalue(v) == true end

local V = Probe.Show   -- a secret reads <secret>, a string is quoted

-- The wall clock and the character stay in the line's text: two accounts'
-- logs are read side by side, and read-wirelog.py's --since filters on it.
local function Log(text)
    Probe:Say(("%s %s %s"):format(date("%H:%M:%S"), Where(), text))
end

local Sync, Kinds, Msgs
local lastSendAt

--------------------------------------------------------------------------------
-- Payloads: a kind's head, then filler the receiver can check byte for byte
--------------------------------------------------------------------------------

local function Filler(n)
    local t = {}
    for i = 1, n do t[i] = string.char((i * 7) % 256) end
    return table.concat(t)
end

-- head .. filler, n bytes in all (the head alone when n is smaller).
local function Padded(head, n)
    return head .. Filler(math.max(0, n - #head))
end

local function Sized(n) return Padded("SIZE|" .. n .. "|", n) end

local function AllBytes()
    local t = {}
    for b = 0, 255 do t[#t + 1] = string.char(b) end
    return "BYTES|" .. table.concat(t) .. table.concat(t)
end

-- What a received payload says it is, and whether every byte is as sent.
local function Verdict(payload)
    if payload == AllBytes() then return "BYTES OK" end
    local head, n = payload:match("^(SIZE|(%d+)|)")
    if not head then head, n = payload:match("^(KIND|(%d+)|%w+|)") end
    if not head then head, n = payload:match("^(MSG|(%d+)|%d+|%d+|%d+|)") end
    if not head then
        local kind = payload:match("^(%u+)|") or "?"
        return kind .. " CORRUPTED"
    end
    local kind = head:match("^%u+")
    local ok = #payload == math.max(#head, tonumber(n)) and payload:sub(#head + 1) == Filler(#payload - #head)
    return kind .. (ok and " OK " or " CORRUPTED ") .. n
end

--------------------------------------------------------------------------------
-- Sending, and what came back
--------------------------------------------------------------------------------

-- ChatThrottleLib's measured rate (#1, PLAN 7.5): about 570 B/s, slower
-- just after login; frame headers and escaping add about a quarter (#25).
local BYTES_PER_SECOND = 570
local function Seconds(bytes) return math.ceil(bytes * 1.25 / BYTES_PER_SECOND) end

-- The latest round, for a procedure's check: what the send call returned
-- (count, why), how many results it waits for, and the onResult tally.
local round = { sent = 0, failed = 0, refused = 0, reasons = {}, bytes = 0, t0 = 0 }
local function NewRound(bytes)
    lastSendAt = debugprofilestop()
    round = { sent = 0, failed = 0, refused = 0, reasons = {}, bytes = bytes or 0, t0 = lastSendAt }
end

-- Results back for the round's destinations. A peer whose nonce we don't
-- hold yet is reported failed/not-ready before Send returns, and isn't one
-- of the destinations Send counts: it's in the tally, never in this (Codex
-- on #26).
local function Answered(r) return r.sent + r.failed - r.refused end

-- "round complete" in the console once every result the round waits for is
-- in: what a results step waits for (#25).
local function Progress(r)
    if not r.expected or r.done then return end
    local back = Answered(r)
    if r.expected == 0 then r.done = true; return end
    if back >= r.expected then
        r.done = true
        Log(("round complete: %d of %d results back after %.1f s"):format(back, r.expected,
            (debugprofilestop() - r.t0) / 1000))
    end
end

-- The send's destinations: the results the round waits for.
local function Expect(n)
    round.expected = n or 0
    Progress(round)
end

local function Returned(count, why)
    round.count, round.why = count, why
    Expect(count)
    return count, why
end

-- Made after NewRound, so a result counts in the round that sent it: a
-- callback ChatThrottleLib delivers late never lands in a later round.
local function OnResult(label)
    local r, t0 = round, lastSendAt
    return function(sender, status, reason)
        if status == "sent" then r.sent = r.sent + 1 else
            r.failed = r.failed + 1
            r.reasons[#r.reasons + 1] = tostring(reason)
            if reason == "not-ready" and r.expected == nil then r.refused = r.refused + 1 end
        end
        Log(("  onResult %s %s: %s %s after %.0f ms"):format(label, V(sender.name), status, tostring(reason),
            debugprofilestop() - t0))
        Progress(r)
    end
end

local function Status()
    Log("== status ==")
    for line in Sync.Diagnostics() do Log("  " .. line) end
    for _, p in ipairs(Sync.Peers()) do
        Log(("  peer %s %s (%s)"):format(V(p.name), V(p.guid), tostring(p.proven)))
    end
end

local function Send(n)
    n = math.min(tonumber(n) or 1000, 32768)
    local payload = Sized(n)
    NewRound(#payload)
    local count, why = Sync.Send(payload, OnResult("send"))
    Log(("send %d bytes -> %s %s"):format(#payload, tostring(count), tostring(why)))
    return Returned(count, why)
end

-- A peer by name (any case, realm optional) or GUID; the first one by default.
local function FindPeer(what)
    local peers = Sync.Peers()
    if what == nil or what == "" then return peers[1] end
    for _, p in ipairs(peers) do
        if p.guid == what or (type(p.name) == "string" and p.name:lower() == what:lower()) then return p end
    end
end

-- SendTo (r4): one payload to one peer, or to a GUID that isn't one.
local function SendTo(what, n, guid)
    local p = guid and { guid = guid, name = "(not a peer)" } or FindPeer(what)
    if not p then Log("sendto: no peer " .. V(what or "") .. " (see /fp las status)"); return nil, "no-peer" end
    if type(Sync.SendTo) ~= "function" then
        Log("sendto: this copy has no SendTo (r4 or newer needed); nothing sent")
        return nil, "no-SendTo"
    end
    local payload = Sized(n or 1000)
    NewRound(#payload)
    local count, why = Sync.SendTo(p.guid, payload, OnResult("sendto"))
    Log(("sendto %s %s, %d bytes -> %s %s"):format(V(p.name), V(p.guid), #payload, tostring(count), tostring(why)))
    return Returned(count, why)
end

-- Two snapshot kinds of one addon (r5, #17): a larger one on tag Probe, then
-- at once a small one on tag ProbeST, on the same store. Both must arrive.
-- Sized for the channel: about 10 s at the measured rate (#25).
local KIND_SIZES = { 4000, 500 }
local function SendKinds()
    NewRound(KIND_SIZES[1] + KIND_SIZES[2])
    local a, whyA = Sync.Send(Padded(("KIND|%d|Probe|"):format(KIND_SIZES[1]), KIND_SIZES[1]), OnResult("kind Probe"))
    local b, whyB = Kinds.Send(Padded(("KIND|%d|ProbeST|"):format(KIND_SIZES[2]), KIND_SIZES[2]), OnResult("kind ProbeST"))
    Log(("kinds: %d bytes on Probe -> %s %s; %d bytes on ProbeST -> %s %s"):format(
        KIND_SIZES[1], tostring(a), tostring(whyA), KIND_SIZES[2], tostring(b), tostring(whyB)))
    round.kinds = { a, b }
    Expect((a or 0) + (b or 0))
    return a, b
end

-- Four messages on the messages tag (r5, #18), back to back and largest
-- first, so the small ones may complete first. Every one must be delivered,
-- once. On a copy without messages mode the tag gets snapshots, said here.
local MESSAGE_SIZES = { 2000, 1000, 400, 100 }   -- about 8 s at the measured rate (#25)
local MESSAGE_BYTES = 3500
local function SendMessages()
    if Msgs.messages ~= true then
        Log("messages: this copy gives ProbeMsg snapshots, not messages (r5 or newer needed)")
    end
    NewRound(MESSAGE_BYTES)
    local batch, counts = time(), {}
    for i, n in ipairs(MESSAGE_SIZES) do
        local head = ("MSG|%d|%d|%d|%d|"):format(n, batch, i, #MESSAGE_SIZES)
        counts[i] = Msgs.Send(Padded(head, n), OnResult("msg " .. i)) or 0
    end
    Log(("messages: batch %d, %d sends -> %s"):format(batch, #MESSAGE_SIZES, table.concat(counts, ",")))
    round.counts = counts
    local n = 0
    for _, c in ipairs(counts) do n = n + c end
    Expect(n)
    return batch, table.concat(counts, ",")
end

local function Bytes()
    NewRound(#AllBytes())
    local count = Sync.Send(AllBytes(), OnResult("bytes"))
    Log(("bytes: all 256 values twice -> %s"):format(tostring(count)))
    Expect(count)
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

-- Messages seen this session, per batch: a second delivery of one is logged.
local seenMsg = {}

local function OnMessageFor(tag)
    return function(payload, sender, sid)
        local verdict = Verdict(payload)
        local batch, i, count = payload:match("^MSG|%d+|(%d+)|(%d+)|(%d+)|")
        if batch then
            local seen = seenMsg[batch] or {}
            seenMsg[batch] = seen
            local dup = seen[i]
            seen[i] = true
            local distinct = 0
            for _ in pairs(seen) do distinct = distinct + 1 end
            verdict = ("%s, message %s of %s in batch %s%s, %d distinct so far"):format(verdict, i, count, batch,
                dup and " DUPLICATE" or "", distinct)
        end
        Log(("received on %s %d bytes from %s (%s, %s) sid %s: %s"):format(tag, #payload, V(sender.name),
            V(sender.guid), tostring(sender.proven), tostring(sid), verdict))
    end
end

--------------------------------------------------------------------------------
-- Measurements (PLAN section 7)
--------------------------------------------------------------------------------

local function Hash()
    local T = LibStub("LibAccountSync-1.0")._test
    for _, kb in ipairs({ 1, 16, 32 }) do
        local s = Filler(kb * 1024)
        local t0 = debugprofilestop()
        T.SHA256(s)
        Log(("hash: SHA-256 of %d KB took %.0f ms on the %s path (threshold 100 ms in one frame)"):format(
            kb, debugprofilestop() - t0, tostring(T.HASH_PATH)))
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

-- A blank WoW presence: online, but no name or no GUID (section 7.3, 7.9).
local function IsBlank(g)
    return type(g) == "table" and not IsS(g.clientProgram) and g.clientProgram == "WoW"
        and not IsS(g.isOnline) and g.isOnline ~= false
        and not IsS(g.characterName) and not IsS(g.playerGuid)
        and (g.characterName == nil or g.characterName == "" or g.playerGuid == nil or g.playerGuid == "")
end

-- Logs every id's record. Returns how many WoW ids are blank.
local function Ids()
    Log("== ids (raw records) ==")
    local blank = 0
    for id = 1, 128 do
        local ok, g = pcall(C_BattleNet.GetGameAccountInfoByID, id)
        if ok and (IsS(g) or type(g) == "table") then
            Record("id " .. id, g)
            if IsBlank(g) then blank = blank + 1 end
        end
    end
    Log(("ids: %d blank WoW presence(s)"):format(blank))
    return blank
end

-- The local id whose record names this GUID, while it still does.
local function IdOf(guid)
    for id = 1, 128 do
        local ok, g = pcall(C_BattleNet.GetGameAccountInfoByID, id)
        if ok and type(g) == "table" and not IsS(g.playerGuid) and g.playerGuid == guid then return id end
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

-- The ping's text is ours (PING|name|time), not something a player typed.
local pingsHeard = 0
local function Ping(id)
    id = tonumber(id)
    if not id then Log("ping: give a game account id (see /fp las ids)"); return end
    local ok, r = pcall(C_BattleNet.SendGameData, id, PROBE_PREFIX, "PING|" .. Where() .. "|" .. time())
    Log(("ping %d -> %s"):format(id, ok and V(r) or ("ERROR " .. tostring(r))))
    return ok
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

Probe:Command("status", function() Status() end, "the library's Diagnostics and peers")
Probe:Command("send", function(arg) Send(arg) end, "<bytes>: a payload of that size to every own account")
Probe:Command("sendto", function(arg) SendTo(arg) end, "[name or GUID]: one payload to one peer (r4)")
Probe:Command("kinds", function() SendKinds() end, "two snapshot kinds on two tags, one store (r5)")
Probe:Command("messages", function() SendMessages() end, "four messages on a messages tag (r5)")
Probe:Command("bytes", function() Bytes() end, "all 256 byte values; the receiver checks them")
Probe:Command("hash", function() Hash() end, "SHA-256 cost for 1, 16 and 32 KB")
Probe:Command("secrets", function() Secrets() end, "which Battle.net fields read as secret")
Probe:Command("region", function() Region() end, "project and region, ours and each record's")
Probe:Command("friends", function() Friends("now") end, "the friends list's completeness now")
Probe:Command("ids", function() Ids() end, "every id's raw record: blank? online?")
Probe:Command("ping", function(arg) Ping(arg) end, "<id>: a raw ping on the probe's own prefix")
Probe:Command("presence", function() Presence() end, "BNGetInfo's presenceID vs our bnetAccountID")
Probe:Command("clear", function() Probe:ClearLog(); Log("log cleared") end, "empty the saved log")

--------------------------------------------------------------------------------
-- Procedures: what needs the owner's hands
--------------------------------------------------------------------------------

local function Minor()
    local _, minor = LibStub:GetLibrary("LibAccountSync-1.0", true)
    return minor
end

-- Results the round still waits for (none when its send went nowhere).
local function Pending()
    return math.max(0, (round.expected or 0) - Answered(round))
end

-- The tally, and what is still on the way.
local function Tally()
    local t = ("%d sent, %d failed %s"):format(round.sent, round.failed, table.concat(round.reasons, ","))
    if Pending() > 0 then
        t = t .. ("; %d still on the way after %.0f s (%d bytes take about %d s)"):format(Pending(),
            (debugprofilestop() - round.t0) / 1000, round.bytes, Seconds(round.bytes))
    end
    return t
end

-- The results come back through ChatThrottleLib at its own pace (a 1000-byte
-- send took 14 s just after login, #25), so the step waits for them: a
-- ForeverProbe wait step (ForeverProbe#14), polled about once a second.
local RESULTS_TIMEOUT = 120
local function ResultsStep(text, expected)
    return { text = text .. " This step goes on by itself once every result is back.",
             wait = function()
                 if Pending() > 0 then return false, Tally() end
                 Log("results: " .. Tally())
                 return true, Tally()
             end,
             timeout = RESULTS_TIMEOUT,
             check = function() return round.sent == expected and round.failed == 0, Tally() end }
end

local steadyText = "Log a character in on your other WoW account (this machine or another) with this probe "
    .. "deployed there too, the same build of it. Once both are in the world, wait a minute for the "
    .. "friends list to settle (sends are slower just after login), then press Next."

Probe:Steps("check", {
    title = "LibAccountSync: a release across two own accounts",
    rev = 3,
    { text = steadyText },
    { text = "Reading the library's state: the release loaded, and the other account as a peer. "
          .. "If the check fails, wait 30 s, press Back, then Next.", auto = true,
      run = function() Status(); return Minor(), #Sync.Peers() end,
      check = function() return #Sync.Peers() >= 1 and (Minor() or 0) >= 5, "r" .. tostring(Minor()),
                                #Sync.Peers() .. " peer(s)" end },
    { text = ("A 1000-byte payload to every own account: about %d s."):format(Seconds(1000)), button = "Send",
      run = function() return Send(1000) end,
      check = function() return round.count == 1 and round.failed == 0, tostring(round.count), tostring(round.why) end },
    ResultsStep("Reading what ChatThrottleLib reported for that send.", 1),
    { text = ("SendTo (r4): the same to the other account alone, about %d s."):format(Seconds(1000)),
      button = "SendTo",
      run = function() return SendTo(nil, 1000) end,
      check = function() return round.count == 1 and round.failed == 0, tostring(round.count), tostring(round.why) end },
    ResultsStep("Reading what came back for the SendTo.", 1),
    { text = "SendTo a GUID that isn't a peer: nothing may be sent.", button = "SendTo nobody",
      run = function() return SendTo(nil, 100, "Player-1-00000000") end,
      check = function()
          return round.count == nil and round.why == "no-peers" and round.sent + round.failed == 0,
                 tostring(round.count), tostring(round.why)
      end },
    { text = ("Two snapshot kinds (r5, #17): %d bytes on tag Probe, then at once %d on ProbeST, about %d s. "
          .. "The other account must get both."):format(KIND_SIZES[1], KIND_SIZES[2],
          Seconds(KIND_SIZES[1] + KIND_SIZES[2])), button = "Send kinds",
      run = function() return SendKinds() end,
      check = function()
          local k = round.kinds or {}
          return k[1] == 1 and k[2] == 1 and round.failed == 0, tostring(k[1]), tostring(k[2])
      end },
    ResultsStep("Reading what came back for the two kinds.", 2),
    { text = ("Messages (r5, #18): four on tag ProbeMsg, back to back, largest first, about %d s. "
          .. "The other account must get all four, once each."):format(Seconds(MESSAGE_BYTES)),
      button = "Send messages",
      run = function() return SendMessages() end,
      check = function()
          local all = true
          for i = 1, #MESSAGE_SIZES do all = all and (round.counts or {})[i] == 1 end
          return Msgs.messages == true and all and round.failed == 0, "messages=" .. tostring(Msgs.messages),
                 table.concat(round.counts or {}, ",")
      end },
    ResultsStep("Reading what came back for the messages.", #MESSAGE_SIZES),
    { text = "On the OTHER account, check its console (/fp) shows the four messages received (\"4 distinct "
          .. "so far\"), then type /reload there, so what it received is on disk. Then press Next here." },
    { text = "Now /reload here too, to save this side.", reload = true },
})

-- 7.3's subject is one account: the other own account, pinned while it is
-- a named peer, with its local id (Battle.net's handle on this client). The
-- blank record, the proof and the delivery must all be that account's, so a
-- blank friend beside a named own account proves nothing (Codex on #24).
local target            -- { guid, name, id }
local function TargetBlank()
    if not target then return false, "no account pinned" end
    local ok, g = pcall(C_BattleNet.GetGameAccountInfoByID, target.id)
    if not ok then return false, "id " .. target.id .. ": " .. tostring(g) end
    return IsBlank(g), "id " .. target.id .. (IsBlank(g) and " blank" or " not blank")
end
local function TargetPeer()
    for _, p in ipairs(Sync.Peers()) do
        if target and p.guid == target.guid then return p end
    end
end
local blankAtSend

Probe:Steps("blank", {
    title = "PLAN 7.3: the handshake with a blank presence",
    rev = 3,
    { text = steadyText },
    { text = "Pinning the other account: its character and its Battle.net id here, while it is named.",
      button = "Pin", run = function()
          target = nil
          local peers = Sync.Peers()
          local p = peers[1]
          local id = p and #peers == 1 and IdOf(p.guid)
          if id then target = { guid = p.guid, name = p.name, id = id } end
          Log(("blank: pinned %s"):format(target and (V(target.name) .. " " .. V(target.guid) .. " id " .. id)
              or ("nothing (" .. #peers .. " peers)")))
          return target and target.id, #peers
      end,
      check = function() return target ~= nil, target and target.id end },
    { text = "On the OTHER account, type /reload. As soon as its loading screen is gone, press Read ids here. "
          .. "If its presence isn't blank, press Back, then Next, and try again: it is rare.", button = "Read ids",
      run = function() Ids(); return TargetBlank() end,
      check = function() return TargetBlank() end },
    { text = "Reading the library's state: the pinned account must be a peer proven by key or proof, "
          .. "not by Battle.net, while its presence is still blank.", button = "Read state",
      run = function() Status(); local p = TargetPeer(); return p and p.proven, TargetBlank() end,
      check = function()
          local p, blank = TargetPeer(), TargetBlank()
          return blank and p ~= nil and (p.proven == "key" or p.proven == "proof"),
                 p and tostring(p.proven) or "not a peer", select(2, TargetBlank())
      end },
    { text = "SendTo the pinned account, 1000 bytes, while it is blank.", button = "Send",
      run = function()
          blankAtSend = TargetBlank()
          if not target then return nil, "no account pinned" end   -- never FindPeer's first peer
          return SendTo(target.guid, 1000)
      end,
      check = function()
          return blankAtSend and round.count == 1 and round.failed == 0, tostring(round.count), tostring(round.why),
                 "blank at send: " .. tostring(blankAtSend)
      end },
    ResultsStep("Reading what came back.", 1),
    { text = "On the OTHER account, type /reload, so what it received is on disk. Then press Next here." },
    { text = "Now /reload here too, to save this side.", reload = true },
})

-- 7.9: the friend is on ANOTHER Battle.net account, so never one of ours:
-- what's logged is whether their presence goes blank and their pings arrive.
-- Pings are counted on the probe's own prefix: an event step would complete
-- on any addon's Battle.net message, the library's own hellos included.
local pingMark = 0
local function PingStep(text)
    return { text = text, button = "Check pings",
             run = function() return pingsHeard - pingMark end,
             check = function() return pingsHeard > pingMark, (pingsHeard - pingMark) .. " ping(s) since the mark" end }
end

Probe:Steps("relay", {
    title = "PLAN 7.9: the relay gate (a friend on another Battle.net account)",
    rev = 1,
    { text = "You need a Battle.net friend online in WoW, with this probe deployed. Ask them to set "
          .. "Appear Offline. Then press Next." },
    { text = "Reading every presence: is the friend's blank?", button = "Read ids",
      run = function() pingMark = pingsHeard; return Ids() end },
    PingStep("Ask the friend to type /fp las ids, find your id there, then /fp las ping <your id>. "
          .. "Give it a few seconds, then press Check pings."),
    { text = "Ask the friend to log out to the character list and back in. While they are on the loading "
          .. "screen, press Read ids.", button = "Read ids",
      run = function() pingMark = pingsHeard; return Ids() end },
    PingStep("Ask the friend to ping you again as soon as they are in, then press Check pings."),
    { text = "Ask the friend to /reload. Then /reload here, to save this side.", reload = true },
})

--------------------------------------------------------------------------------
-- Events and the instances
--------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
Probe:RegisterEvents(frame, { "ADDON_LOADED", "PLAYER_LOGIN", "BN_CHAT_MSG_ADDON" })
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" and ... == ADDON then
        Probe:Ready()                                  -- logs EARLY if the host somehow isn't loaded
        -- rawget: on a first run the saved table is absent, not an error.
        local db = rawget(_G, "LibAccountSyncProbeDB")
        if type(db) ~= "table" then db = {}; LibAccountSyncProbeDB = db end
        if type(db.log) ~= "table" then db.log = {} end
        if type(db.sync) ~= "table" then db.sync = {} end
        Probe:UseLog(db.log, MAX_LOG)                  -- from here on, lines are saved too
        db.loads = (db.loads or 0) + 1
        Log(("loaded (%d loads), LibAccountSync r%s. /fp las for the commands"):format(db.loads, tostring(Minor())))
    elseif event == "PLAYER_LOGIN" then
        C_ChatInfo.RegisterAddonMessagePrefix(PROBE_PREFIX)
        for _, s in ipairs({ 5, 15, 30, 60, 90 }) do
            C_Timer.After(s, function() Friends("+" .. s .. " s") end)
        end
        C_Timer.After(8, Status)
    elseif event == "BN_CHAT_MSG_ADDON" then
        local prefix, text, _, senderID = ...
        if IsS(prefix) or prefix ~= PROBE_PREFIX then return end
        pingsHeard = pingsHeard + 1
        local ok, g = pcall(C_BattleNet.GetGameAccountInfoByID, senderID)
        Log(("PING received from id %s: %s"):format(V(senderID), V(text)))
        Record("  its record", ok and g or nil)
    end
end)

-- One store for the three tags: one household key and trust, as a host with
-- several kinds has it (PLAN section 1, #17).
local function Store()
    local db = rawget(_G, "LibAccountSyncProbeDB")
    return type(db) == "table" and db.sync or nil
end
local function Report(text, kind) Log(("library %s: %s"):format(tostring(kind), text)) end

local LAS = LibStub("LibAccountSync-1.0")
Sync = LAS:New({ addon = "Probe", store = Store, report = Report, maxPayload = 32768 })
Kinds = LAS:New({ addon = "ProbeST", store = Store, report = Report })
Msgs = LAS:New({ addon = "ProbeMsg", store = Store, report = Report, messages = true })
Sync.OnMessage(OnMessageFor("Probe"))
Kinds.OnMessage(OnMessageFor("ProbeST"))
Msgs.OnMessage(OnMessageFor("ProbeMsg"))

NS._test = { Probe = Probe, Sync = Sync, Kinds = Kinds, Msgs = Msgs, Verdict = Verdict, Padded = Padded,
             Sized = Sized, AllBytes = AllBytes, Pings = function() return pingsHeard end,
             Round = function() return round end, Tally = function() return Tally() end }
