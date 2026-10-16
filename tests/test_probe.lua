-- test_probe.lua: the in-game probe (Tools/LibAccountSyncProbe), a
-- ForeverProbe module. The host is loaded first from its checkout
-- ($FOREVERPROBE, else ../ForeverProbe; GlassChat's loader). ForeverProbe is
-- private and local, so CI sets FOREVERPROBE_OPTIONAL=1 and this file skips
-- (ForeverProbe docs/GUIDE.md section 8). Checked: every command runs on the
-- stubbed client and stays out of chat, its lines land in its saved log, the
-- check procedure passes against a peer, and what it receives is verified.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local PROBE = os.getenv("LIBACCT_PROBE_MUTANT") or "Tools/LibAccountSyncProbe/LibAccountSyncProbe.lua"

-- The host and the probe beyond the shared stub: a Lua builtin in the client
-- (date), and FrameXML's SlashCmdList, which the host's /fp registers in.
rawset(_G, "date", os.date)
rawset(_G, "SlashCmdList", {})
local chat = {}
rawset(_G, "print", function(...) chat[#chat + 1] = table.concat({ ... }, " ") end)

function loadForeverProbe()
    local root = (os.getenv("FOREVERPROBE") or "../ForeverProbe"):gsub("\\", "/"):gsub("/$", "")
    local toc = io.open(root .. "/ForeverProbe.toc", "rb")
    if not toc then
        if os.getenv("FOREVERPROBE_OPTIONAL") == "1" then
            io.write("SKIPPED: ForeverProbe isn't here (private, local only); the probe tests run locally\n")
            os.exit(0)
        end
        error("ForeverProbe checkout not found at " .. root .. ": clone it there or set FOREVERPROBE", 0)
    end
    local files = {}
    for line in toc:read("*a"):gmatch("[^\r\n]+") do
        if line:match("%.lua$") and not line:match("^#") then files[#files + 1] = root .. "/" .. line end
    end
    toc:close()
    for _, file in ipairs(files) do assert(loadfile(file))("ForeverProbe", {}) end
    WoW.fire("ADDON_LOADED", "ForeverProbe")
    return ForeverProbe
end

-- The client's order: the host (a dependency), then the probe's files, the
-- embedded library first (its TOC), then its saved table, then ADDON_LOADED.
local FP = loadForeverProbe()
local toc = readFile("Tools/LibAccountSyncProbe/LibAccountSyncProbe.toc")
check(toc:find("## Dependencies: ForeverProbe", 1, true), "the TOC depends on ForeverProbe")
check(toc:find("\nLibAccountSyncProbe.lua", 1, true), "the TOC loads LibAccountSyncProbe.lua")
loadLibrary("LibAccountSyncProbe")
local ns = {}
assert(loadfile(PROBE))("LibAccountSyncProbe", ns)
local T = ns._test
-- No saved table yet: a first run.
WoW.fire("ADDON_LOADED", "LibAccountSyncProbe")
local DB = LibAccountSyncProbeDB

check(rawget(_G, "LibAccountSyncProbe_test") == nil and rawget(_G, "NS") == nil, "the test seam stays off _G")
check(rawget(SlashCmdList, "LASPROBE") == nil and rawget(_G, "SLASH_LASPROBE1") == nil, "no /lasprobe any more: /fp las")
eq(FP.byCmd.las, T.Probe, "/fp las is LibAccountSyncProbe")
eq(type(DB), "table", "its saved table is made at its own ADDON_LOADED")
check(T.Probe.log == DB.log, "its ForeverProbe log is LibAccountSyncProbeDB.log")
eq(type(DB.sync), "table", "the library's store is in its saved table")
eq(DB.loads, 1, "it counts its loads")
local early = false
for _, l in ipairs(FP.lines) do if l.text:find("EARLY", 1, true) then early = true end end
check(not early, "the host was ready before the probe's ADDON_LOADED")
eq(T.Msgs.messages, true, "ProbeMsg is a messages tag")
eq(T.Kinds.messages, nil, "ProbeST is a snapshot tag")

local function logHas(text)
    for _, l in ipairs(DB.log) do if l:find(text, 1, true) then return true end end
    return false
end
local function las(s) SlashCmdList.FOREVERPROBE("las " .. s) end

-- Every line carries the wall clock and the character (read-wirelog.py's --since).
check(DB.log[1] and DB.log[1]:match("#%d+ %d%d:%d%d:%d%d Malas%-Classic Beta PvE loaded"),
      "a line has the host stamp, then HH:MM:SS Name-Realm: " .. tostring(DB.log[1]))

-- 1. Logged in with the other account as a peer.
login()
WoW.advance(61)
local B = Peer.new({})
T.Sync.Rescan()
B:deliver(B:hello({ key = B.key }))
eq(#T.Sync.Peers(), 1, "the other account is a peer")

-- 2. Every command runs, and nothing reaches chat.
for _, cmd in ipairs({ "", "status", "send 500", "sendto", "sendto karuzo", "sendto Nobody", "kinds", "messages",
                       "bytes", "hash", "secrets", "region", "friends", "ids", "ping", "ping 3", "presence" }) do
    local n = #WoW.errors
    local err = errs(las, cmd)
    check(not err, "/fp las " .. cmd .. " runs: " .. tostring(err))
    eq(#WoW.errors, n, "/fp las " .. cmd .. " reports no error")
end
eq(#chat, 0, "no line went to chat: " .. tostring(chat[1]))
check(logHas("send 500 bytes -> 1 nil"), "send reaches the peer")
check(logHas("sendto \"Karuzo\""), "sendto picks the peer by name, any case")
check(logHas("sendto: no peer \"Nobody\""), "sendto names a missing peer")
check(logHas("kinds: 4000 bytes on Probe -> 1 nil; 500 bytes on ProbeST -> 1 nil"), "kinds sends on both tags")
check(logHas("messages: batch") and logHas("4 sends -> 1,1,1,1"), "messages sends four")
check(logHas("ping 3 -> 0"), "ping sends on the probe's prefix")
check(logHas("onResult send \"Karuzo\": sent nil"), "onResult lines are logged")

-- 2b. A result ChatThrottleLib delivers late counts in the round that sent
-- it, never in a later one's (Codex on #24).
WoW.ctlDefer = true
las("send 300")
local r1 = T.Round()
las("sendto")
local r2 = T.Round()
check(r1 ~= r2, "each send starts its own round")
eq(r2.sent, 0, "nothing is counted before ChatThrottleLib sends")
WoW.ctlDrain()
WoW.ctlDefer = false
eq(r1.sent, 1, "the late Send result counts in the Send's round")
eq(r2.sent, 1, "  and the SendTo's in its own")

-- 3. What reached the other account is what the probe meant to send.
local function receivedOK(tag)
    local all, any = true, false
    for _, r in ipairs(B:received(tag, DB.sync)) do
        any = true
        local v = T.Verdict(r.payload)
        if not (r.macOk and v:find(" OK", 1, true)) then all = false end
    end
    return any and all
end
check(receivedOK("Probe"), "every Probe stream decodes, MACs and verifies")
check(receivedOK("ProbeST"), "the ProbeST stream decodes, MACs and verifies")
eq(#B:received("ProbeMsg", DB.sync), 4, "four messages reached the peer")
check(receivedOK("ProbeMsg"), "every message decodes, MACs and verifies")

-- 3b. Paced for the channel (#25): the round says when it's complete, and a
-- tally read too early says what's still on the way.
local function count(text)
    local n = 0
    for _, l in ipairs(DB.log) do if l:find(text, 1, true) then n = n + 1 end end
    return n
end
WoW.ctlDefer = true
local before = count("round complete: 4 of 4")
las("messages")
eq(count("round complete: 4 of 4"), before, "no round complete while the messages are queued")
check(T.Tally():find("4 still on the way", 1, true), "an early tally names what's pending: " .. T.Tally())
check(T.Tally():find("3500 bytes take about 8 s", 1, true), "  with the time the bytes take: " .. T.Tally())
WoW.ctlDrain()
WoW.ctlDefer = false
eq(count("round complete: 4 of 4"), before + 1, "round complete once all four are back")
check(not T.Tally():find("on the way", 1, true), "a complete tally has nothing pending: " .. T.Tally())
before = count("round complete: 2 of 2")
las("kinds")
eq(count("round complete: 2 of 2"), before + 1, "a round whose results came at once is complete")
T.Sync.SetEnabled(false)                           -- Send returns nil, "disabled": no destinations
las("send 100")
T.Sync.SetEnabled(true)
T.Sync.Rescan()                                    -- switched off, the session was wiped: the peer again
B:deliver(B:hello({ key = B.key }))
eq(#T.Sync.Peers(), 1, "the peer is back after the switch")
check(logHas("send 100 bytes -> nil disabled"), "a send with no destinations is logged")
check(not logHas("round complete: 0 of 0"), "  and its round waits for nothing")
check(not T.Tally():find("on the way", 1, true), "  with nothing pending: " .. T.Tally())

-- 4. The verdicts: a byte changed or a length short is CORRUPTED.
eq(T.Verdict(T.Sized(1000)), "SIZE OK 1000", "a whole SIZE payload is OK")
eq(T.Verdict(T.Sized(3)), "SIZE OK 3", "a payload shorter than its head is OK")
eq(T.Verdict(T.AllBytes()), "BYTES OK", "all 256 bytes are OK")
local s = T.Sized(1000)
check(T.Verdict(s:sub(1, 999)):find("CORRUPTED", 1, true), "a short payload is CORRUPTED")
check(T.Verdict(s:sub(1, 500) .. "x" .. s:sub(502)):find("CORRUPTED", 1, true), "a changed byte is CORRUPTED")
check(T.Verdict(T.AllBytes():sub(1, -2)):find("CORRUPTED", 1, true), "BYTES with one missing is CORRUPTED")
eq(T.Verdict("hello"), "? CORRUPTED", "an unknown payload is CORRUPTED")

-- 5. Receiving: messages are told apart and counted; the tag is logged.
local function msg(batch, i, n) return T.Padded(("MSG|%d|%d|%d|4|"):format(n, batch, i), n) end
B:send("ProbeMsg", msg(77, 1, 300), { sid = "1760000000101" })
B:send("ProbeMsg", msg(77, 2, 900), { sid = "1760000000102" })
check(logHas("received on ProbeMsg 300 bytes from \"Karuzo\""), "a message is logged with its tag and sender")
check(logHas("MSG OK 300, message 1 of 4 in batch 77, 1 distinct so far"), "the first message is verified and counted")
check(logHas("MSG OK 900, message 2 of 4 in batch 77, 2 distinct so far"), "the second is counted apart")
B:send("ProbeST", T.Padded("KIND|500|ProbeST|", 500), { sid = "1760000000103" })
check(logHas("received on ProbeST 500 bytes") and logHas("KIND OK 500"), "a kind is verified on its own tag")
B:send("Probe", T.AllBytes(), { sid = "1760000000104" })
check(logHas("BYTES OK"), "all 256 byte values are verified")
check(not logHas("DUPLICATE"), "no message was delivered twice")
B:send("ProbeMsg", msg(77, 2, 900), { sid = "1760000000105" })   -- the same message again, a new sid
check(logHas("message 2 of 4 in batch 77 DUPLICATE, 2 distinct so far"), "a message seen twice is flagged")

-- 6. A probe ping is logged, and counted for the relay procedure.
local pings = T.Pings()
WoW.fire("BN_CHAT_MSG_ADDON", "LASProbe", "PING|Friend-Realm|1760000000", "WHISPER", 3)
eq(T.Pings(), pings + 1, "a ping on the probe's prefix is counted")
WoW.fire("BN_CHAT_MSG_ADDON", PREFIX, "H1|junk", "WHISPER", 3)
eq(T.Pings(), pings + 1, "the library's own frames are not pings")
check(logHas("PING received from id 3"), "the ping is logged")

-- 7. Secrets: every Battle.net field secret, nothing throws, and none is logged as text.
WoW.bn.secret = { characterName = true, playerGuid = true, isOnline = true, clientProgram = true, battleTag = true }
for _, cmd in ipairs({ "ids", "secrets", "region", "presence", "friends", "status" }) do
    check(not errs(las, cmd), "/fp las " .. cmd .. " survives secret fields")
end
check(logHas("characterName=<secret>"), "a secret field reads <secret>")
check(logHas("id 3: characterName is secret"), "secrets names the secret field")
WoW.bn.secret = {}

-- 8. The check procedure (r4/r5), end to end against the peer. Its sends
-- complete at once with the ChatThrottleLib stub.
local S = FP.Steps
local names = {}
for k in pairs(FP.procedures) do names[#names + 1] = k end
table.sort(names)
eq(table.concat(names, ","), "LibAccountSyncProbe/blank,LibAccountSyncProbe/check,LibAccountSyncProbe/relay",
   "the three procedures are defined")
T.Probe:StartSteps("check")
local rec = FP.db.steps.records["LibAccountSyncProbe/check"]
local nSteps = #FP.procedures["LibAccountSyncProbe/check"].steps
S.Next()                                           -- 1: the other account is in
-- 2 ran on arrival (auto); every step after it with a run is pressed, and a
-- wait step is polled (the host's OnUpdate does that in game).
local waits = 0
for i = 3, nSteps - 2 do
    local step = FP.procedures["LibAccountSyncProbe/check"].steps[i]
    if step.wait then waits = waits + 1; S.Poll() elseif step.run then S.Run() else S.Next() end
end
eq(waits, 4, "each results step is a wait step")
S.Next()                                           -- the other account's /reload
for i = 2, nSteps - 2 do
    local r = rec.results[i]
    if FP.procedures["LibAccountSyncProbe/check"].steps[i].check then
        eq(r and r.check, "PASS", "check step " .. i .. " passes: " .. tostring(r and r.checkDetail))
    end
end
eq(rec.at, nSteps, "the procedure waits at its /reload step")

-- 8b. A results step waits while ChatThrottleLib holds the send, goes on by
-- itself once the result is back, and fails when it never comes (#25).
WoW.ctlDefer = true
T.Probe:StartSteps("check")
rec = FP.db.steps.records["LibAccountSyncProbe/check"]
S.Next()                                           -- 2 runs on arrival
S.Run()                                            -- 3: send, held
S.Poll()
eq(rec.at, 4, "the results step waits while the send is held")
WoW.ctlDrain()
S.Poll()
eq(rec.at, 5, "it goes on by itself once the result is back")
eq(rec.results[4] and rec.results[4].check, "PASS", "and passes: " .. tostring(rec.results[4] and rec.results[4].checkDetail))
S.Run()                                            -- 5: SendTo, held
WoW.advance(121)
S.Poll()
eq(rec.results[6] and rec.results[6].status, "timeout", "a result that never comes times the step out")
eq(rec.results[6] and rec.results[6].check, "FAIL", "  as a FAIL")
check(tostring(rec.results[6] and rec.results[6].detail):find("1 still on the way", 1, true),
      "  saying what was pending: " .. tostring(rec.results[6] and rec.results[6].detail))
S.Stop()
WoW.ctlDrain()
WoW.ctlDefer = false

-- 9. The check procedure fails where a release would: no peer.
WoW.bn.accounts[3].isOnline = false
WoW.advance(70)
T.Probe:StartSteps("check")
rec = FP.db.steps.records["LibAccountSyncProbe/check"]
S.Next()
eq(rec.results[2] and rec.results[2].check, "FAIL", "the state check fails with no peer")
S.Run()
eq(rec.results[3] and rec.results[3].check, "FAIL", "the send check fails with no peer")
S.Poll()
eq(rec.at, 5, "a round that sent nothing waits for nothing")
eq(rec.results[4] and rec.results[4].check, "FAIL", "the results check fails with nothing sent")
S.Stop()
WoW.bn.accounts[3].isOnline = true

-- 10. The blank procedure (7.3) is about one account: the other own account,
-- pinned while named, then blank, proven by key or proof, and sent to while
-- still blank. A blank friend beside a named own account proves nothing.
T.Sync.Rescan()
B:deliver(B:hello({ key = B.key }))
eq(#T.Sync.Peers(), 1, "the other account is a peer again")
Peer.new({ id = 5, name = "Friend", guid = "Player-1-0000000F", bnet = 9, blank = true })
WoW.bn.friends = { { 5 } }
T.Probe:StartSteps("blank")
rec = FP.db.steps.records["LibAccountSyncProbe/blank"]
local function outcome(i) return rec.results[i] and rec.results[i].check end
local function detail(i) return tostring(rec.results[i] and rec.results[i].checkDetail) end
S.Next()
S.Run()                                            -- 2: pin
eq(outcome(2), "PASS", "the other account is pinned: " .. detail(2))
S.Run()                                            -- 3: the friend is blank, ours is named
eq(outcome(3), "FAIL", "a blank friend beside a named own account is not 7.3: " .. detail(3))
S.Run()                                            -- 4
eq(outcome(4), "FAIL", "a peer proven by Battle.net is not 7.3: " .. detail(4))
S.Back(); S.Back()
B:setBlank(true)
S.Run()
eq(outcome(3), "PASS", "the pinned account's presence is blank: " .. detail(3))
-- Blank, but no hello since: the binding Battle.net made before is all there is.
local bound = T.Sync.Peers()[1]
eq(bound and bound.proven, "bnet", "before its hello, the peer is still the Battle.net binding")
S.Run()
eq(outcome(4), "FAIL", "a blank presence still bound by Battle.net is not 7.3: " .. detail(4))
S.Back()
B:deliver(B:hello({ key = B.key }))                -- its hello after the reload, presence blank
S.Run()
eq(outcome(4), "PASS", "it is a peer by key or proof while blank: " .. detail(4))
B:setBlank(false)                                  -- filled in before the send
S.Run()
eq(outcome(5), "FAIL", "a send after the presence filled in is not 7.3: " .. detail(5))
S.Back()
B:setBlank(true)
S.Run()
eq(outcome(5), "PASS", "SendTo reaches the pinned account while blank: " .. detail(5))
check(logHas("sendto \"Karuzo\" \"Player-1-0000000B\""), "  the pinned account, not the first peer")
S.Poll()
eq(outcome(6), "PASS", "its result came back: " .. detail(6))
S.Stop()
B:setBlank(false)
WoW.bn.accounts[5], WoW.bn.friends = nil, {}

-- 11. The relay procedure counts pings since its mark.
T.Probe:StartSteps("relay")
rec = FP.db.steps.records["LibAccountSyncProbe/relay"]
S.Next()
S.Run()                                            -- 2: read ids, set the mark
S.Run()                                            -- 3: no ping yet
eq(rec.results[3] and rec.results[3].check, "FAIL", "no ping since the mark: FAIL")
S.Back()
WoW.fire("BN_CHAT_MSG_ADDON", "LASProbe", "PING|Friend-Realm|1760000001", "WHISPER", 3)
S.Run()
eq(rec.results[3] and rec.results[3].check, "PASS", "a ping since the mark: PASS")
S.Stop()

-- 12. Clearing empties the bound log in place; the next line lands in both.
local log = DB.log
las("clear")
check(DB.log == log and T.Probe.log == log, "clear keeps the bound table")
eq(#DB.log, 1, "only the clear line is left")
check(DB.log[1]:find("log cleared", 1, true), "the clear line is saved")
local inConsole = false
for _, l in ipairs(FP.lines) do if l.m == "LibAccountSyncProbe" and l.text:find("log cleared", 1, true) then inConsole = true end end
check(inConsole, "and is in the console")
eq(#chat, 0, "still nothing in chat")

done("test_probe")
