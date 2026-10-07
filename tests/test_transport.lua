-- test_transport.lua: Send, reassembly, the stream MAC, caps and stream ids
-- (§1, §2, §5.2, §5.3).

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function seasoned()
    return { v = 1, key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", keyAt = 100,
             trusted = { [OTHER_KEY] = 100 }, selfProject = 18, selfRegion = 90, selfAt = 100 }
end

-- A verified peer (both presences full) that has said hello with its key.
local function verified(store)
    local lib, inst, st = session(store)
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    return lib, inst, st, B
end

-- A peer proven by HMAC (both presences blank).
local function proven()
    local store = seasoned()
    local lib, inst = session(store, { before = function() WoW.bn.blank = true end })
    local B = Peer.new({ blank = true })
    inst.Rescan()
    B:deliver(B:hello())
    return lib, inst, store, B
end

local function results(list)
    return function(sender, status, reason)
        list[#list + 1] = { name = sender.name, status = status, reason = reason }
    end
end

-- 1. Sending to a verified peer: framed, paced, MAC'd, reported once.
do
    local lib, inst, store, B = verified()
    WoW.sent = {}
    local got = {}
    local payload = string.rep("ignore:Spammer|", 400) .. "\0\1end|"
    eq(inst.Send(payload, results(got)), 1, "Send reaches the one peer")
    local frames = sentTo(3, "D1|")
    check(#frames > 1, "a 6 KB payload goes in several frames")
    local maxLen, prios = 0, true
    for _, m in ipairs(frames) do
        if #m.text > maxLen then maxLen = #m.text end
        if m.prio ~= "NORMAL" then prios = false end
    end
    check(maxLen <= 255, "every frame is at most 255 bytes (" .. maxLen .. ")")
    check(prios, "data goes at NORMAL priority")
    local r = B:received("GlassChat", store)
    eq(#r, 1, "one stream")
    eq(r[1].payload, payload, "  reassembles to the payload, \\0 and pipes included")
    check(r[1].macOk, "  with a MAC over its nonce, our GUID, project, region, tag, sid, n and hash")
    eq(#got, 1, "onResult fires once for the destination")
    eq(got[1].status, "sent", "  as sent")
end

-- 2. A peer whose nonce we don't hold yet: not a destination; told, and helloed.
do
    local lib, inst, store = session()
    local B = Peer.new({})
    inst.Rescan()                       -- our hello went; its answer has not come
    local got = {}
    WoW.advance(6)
    local before = #sentTo(3, "H1|")
    eq(inst.Send("x", results(got)), 0, "no destination yet")
    eq(got[1] and got[1].reason, "not-ready", "  the peer is reported not-ready")
    eq(#sentTo(3, "H1|"), before + 1, "  and gets a hello")
end

-- 3. The refusals.
do
    local lib, inst = session()
    local n, why = inst.Send("x")
    eq(why, "no-peers", "no peer online: no-peers")
    n, why = inst.Send(string.rep("x", 16385))
    eq(why, "too-large", "beyond maxPayload: too-large")
    inst.SetEnabled(false)
    n, why = inst.Send("x")
    eq(why, "disabled", "switched off: disabled")
end

-- 4. Receiving from a verified peer: the sender is Battle.net's, never the frame's.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    B:send("GlassChat", "snapshot-1")
    eq(#box, 1, "a verified peer's stream is delivered")
    eq(box[1].payload, "snapshot-1", "  intact")
    eq(box[1].sender.name, "Karuzo", "  from the name Battle.net gives")
    eq(box[1].sender.guid, "Player-1-0000000B", "  and its GUID")
    eq(box[1].sender.proven, "bnet", "  proven by Battle.net")
    eq(box[1].sid, 1760000000001, "  with its sid")
end

-- 5. Receiving from a proof-proven peer: the MAC decides.
do
    local lib, inst, store, B = proven()
    local box = inbox(inst)
    B:send("GlassChat", "from-blank")
    eq(#box, 1, "a proven peer's stream with a good MAC is delivered")
    eq(box[1] and box[1].sender.proven, "proof", "  proven by proof")
    -- A relay's injection: a MAC it cannot make.
    B:send("GlassChat", "injected", { sid = "1760000000002", key = "dddddddddddddddddddddddddddddddd" })
    eq(#box, 1, "a stream MAC'd under an untrusted key is not delivered")
    B:send("GlassChat", "tampered", { sid = "1760000000003", mac = string.rep("0", 32) })
    eq(#box, 1, "a stream with a wrong MAC is not delivered")
    -- Round 3: A's genuine stream presented under C's binding. The MAC binds
    -- the GUID the hello proved, so a stream MAC'd for another GUID fails.
    B:send("GlassChat", "someone else's", { sid = "1760000000004", guid = "Player-1-000000AA" })
    eq(#box, 1, "a stream MAC'd for another character's GUID is not delivered")
end

-- 6. Unordered delivery: chunks reversed still assemble.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    local payload = string.rep("0123456789", 100)
    local frames = B:frames("GlassChat", payload)
    for i = #frames, 1, -1 do B:deliver(frames[i]) end
    eq(box[1] and box[1].payload, payload, "chunks in reverse order assemble")
end

-- 7. Data that overtakes the last hello of a blank handshake (round 2 and 3):
--    some chunks before the hello, every chunk before it, a single chunk.
for _, case in ipairs({ { "every chunk before the hello", 1000, "all" },
                        { "a single-chunk payload before the hello", 20, "all" },
                        { "some chunks before the hello", 1000, "some" } }) do
    local store = seasoned()
    local lib, inst = session(store, { before = function() WoW.bn.blank = true end })
    local box = inbox(inst)
    local B = Peer.new({ blank = true })
    inst.Rescan()                       -- our nonce has gone to B
    local payload = string.rep("y", case[2])
    local frames = B:frames("GlassChat", payload)
    local cut = case[3] == "all" and #frames or 1
    for i = 1, cut do B:deliver(frames[i]) end
    eq(#box, 0, case[1] .. ": nothing yet")
    B:deliver(B:hello())
    for i = cut + 1, #frames do B:deliver(frames[i]) end
    eq(box[1] and box[1].payload, payload, case[1] .. ": delivered once the hello lands")
end

-- 7b. A complete stream waiting for its hello is delivered if Battle.net
--     starts vouching for the sender meanwhile (its presence fills in).
do
    local store = seasoned()
    local lib, inst = session(store)
    local box = inbox(inst)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    B:send("GlassChat", "waited")
    eq(#box, 0, "nothing while the sender is unproven")
    B:setBlank(false)
    WoW.advance(10)
    eq(box[1] and box[1].payload, "waited", "delivered once Battle.net verifies the sender")
end

-- 7b'. The same on first contact: no key learned yet, so no MAC can be
--      checked, and Battle.net's word alone delivers it (Codex, r1 round 3).
do
    local lib, inst, store = session()
    local box = inbox(inst)
    local B = Peer.new({ blank = true })
    inst.Rescan()                            -- a hint: our nonce goes to B
    B:send("GlassChat", "first contact")
    eq(#box, 0, "nothing while the sender is blank and unproven")
    B:setBlank(false)
    WoW.advance(11)
    eq(box[1] and box[1].payload, "first contact", "delivered once Battle.net verifies the sender, with no key trusted")
    eq(box[1] and box[1].sender.proven, "bnet", "  as verified by Battle.net")
end

-- 7b''. A known sender whose presence goes blank: its older stream, admitted
--       while blank, is not delivered as the character that replaces it
--       (Codex, r1 round 4). First contact (7b') still delivers.
do
    local lib, inst, store, A = verified()
    local box = inbox(inst)
    A:send("GlassChat", "A newer", { sid = "1760000000002" })
    eq(#box, 1, "A's newer snapshot lands")
    A:setBlank(true)
    local old = A:frames("GlassChat", string.rep("o", 400), { sid = "1760000000001" })
    for _, f in ipairs(old) do A:deliver(f) end
    local Bc = Peer.new({ id = 3, name = "Bravo", guid = "Player-1-000000B2", nonce = "b2b2b2b2b2b2b2b2" })
    Bc:deliver(Bc:hello({ key = OTHER_KEY }))
    WoW.advance(11)
    eq(#box, 1, "A's older stream is not delivered as B")
end

-- 7e. Binding history from every path (Codex, r1 round 5):
--        (a) A authenticated only by its data, then blank, then B;
--        (b) A's stream admitted before A was known, A then proven, B next.
do
    local lib, inst, store, A = verified()
    local box = inbox(inst)
    lib.state.lastGuid[3] = nil               -- A known through data alone
    A:send("GlassChat", "A newer", { sid = "1760000000002" })
    eq(#box, 1, "(a) A's newer snapshot lands")
    A:setBlank(true)
    for _, f in ipairs(A:frames("GlassChat", string.rep("o", 400), { sid = "1760000000001" })) do A:deliver(f) end
    local Bc = Peer.new({ id = 3, name = "Bravo", guid = "Player-1-000000B2", nonce = "b2b2b2b2b2b2b2b2" })
    Bc:deliver(Bc:hello({ key = OTHER_KEY }))
    WoW.advance(11)
    eq(#box, 1, "(a) A's older stream is not delivered as B")
end
do
    local lib, inst, store = session()
    local box = inbox(inst)
    local A = Peer.new({ blank = true })
    inst.Rescan()                             -- a hint: our nonce goes to A
    local old = A:frames("GlassChat", string.rep("o", 400), { sid = "1760000000001" })
    A:deliver(old[1])                         -- admitted while A is unknown
    A:setBlank(false)
    A:deliver(A:hello({ key = A.key }))
    A:send("GlassChat", "A newer", { sid = "1760000000002" })
    eq(#box, 1, "(b) A's newer snapshot lands")
    local Bc = Peer.new({ id = 3, name = "Bravo", guid = "Player-1-000000B2", nonce = "b2b2b2b2b2b2b2b2" })
    Bc:deliver(Bc:hello({ key = OTHER_KEY }))
    for i = 2, #old do A:deliver(old[i]) end
    WoW.advance(11)
    eq(#box, 1, "(b) A's older stream is not delivered as B")
end

-- 7c. A new character on a blank account we had learned: its stream fails the
--     MAC against the stale binding and waits for its hello, not refused.
do
    local lib, inst, store, B = proven()
    local box = inbox(inst)
    local C2 = Peer.new({ id = 3, name = "Second", guid = "Player-1-000000C2", blank = true })
    C2:send("GlassChat", "from the new character", { sid = "1760000000200" })
    eq(#box, 0, "nothing while the binding is the old character's")
    C2:deliver(C2:hello({ nonce = "c2c2c2c2c2c2c2c2" }))
    eq(box[1] and box[1].payload, "from the new character", "delivered once its hello lands")
    eq(box[1] and box[1].sender.name, "Second", "  as the new character")
end

-- 7d. A verified character's older stream still in flight when the account
--     switches character is never delivered as the new character, and so
--     can't slip under the new character's sid floor (Codex, r1 round 2).
do
    local lib, inst, store, A = verified()
    local box = inbox(inst)
    local old = A:frames("GlassChat", string.rep("o", 400), { sid = "1760000000001" })
    A:deliver(old[1])                        -- A's older snapshot starts
    A:send("GlassChat", "A newer", { sid = "1760000000002" })
    eq(#box, 1, "A's newer snapshot lands")
    -- The account now plays character B; B says hello.
    local Bc = Peer.new({ id = 3, name = "Bravo", guid = "Player-1-000000B2", nonce = "b2b2b2b2b2b2b2b2" })
    Bc:deliver(Bc:hello({ key = OTHER_KEY }))
    for i = 2, #old do A:deliver(old[i]) end
    WoW.advance(11)
    eq(#box, 1, "A's older stream is not delivered, as B or as anyone")
    -- B's own stream on that account is delivered as B.
    Bc:send("GlassChat", "from Bravo", { sid = "1760000000003" })
    eq(box[2] and box[2].sender.name, "Bravo", "the new character's own stream is delivered as it")
end

-- 8. A complete stream whose hello never comes is dropped after 10 s.
do
    local store = seasoned()
    local lib, inst = session(store, { before = function() WoW.bn.blank = true end })
    local box = inbox(inst)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    B:send("GlassChat", "late")
    WoW.advance(11)
    B:deliver(B:hello())
    eq(#box, 0, "a stream that waited past 10 s for its hello is gone")
end

-- 9. Pipes, trailing pipes and empty payloads round-trip both ways.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    for k, p in ipairs({ "a|b", "|", "trailing|", "", string.rep("|", 500) }) do
        B:send("GlassChat", p, { sid = tostring(1760000000010 + k) })
        eq(box[k] and box[k].payload, p, ("received %q intact"):format(p:sub(1, 12)))
    end
    WoW.sent = {}
    inst.Send("x|y|")
    eq(B:received("GlassChat", store)[1].payload, "x|y|", "a payload with pipes is sent intact")
end

-- 10. Caps: too many chunks, too many streams, too large decoded.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    B:deliver("D1|GlassChat|1760000000001|1|366|" .. string.rep("0", 32) .. "|x")
    eq(next(lib.state.buffers), nil, "n beyond the wire cap (365) is refused at the first frame")
    for s = 1, 3 do B:deliver("D1|GlassChat|17600000000" .. (20 + s) .. "|1|2|" .. string.rep("0", 32) .. "|x") end
    local count = 0
    for _ in pairs(lib.state.buffers) do count = count + 1 end
    eq(count, 2, "at most 2 open streams per sender")
    local sids = {}
    for _, b in pairs(lib.state.buffers) do sids[#sids + 1] = b.sidText end
    table.sort(sids)
    eq(table.concat(sids, ","), "1760000000022,1760000000023", "  the newest two: a newer stream evicts the oldest")
    B:deliver("D1|GlassChat|1760000000020|1|2|" .. string.rep("0", 32) .. "|x")
    count = 0
    for _ in pairs(lib.state.buffers) do count = count + 1 end
    eq(count, 2, "  and a stream older than both is refused")
end
do
    local lib, inst, store, B = verified()   -- no open streams in the way
    local small = newHost(lib, "Small", {}, { maxPayload = 10 })
    local sbox = inbox(small)
    B:send("Small", string.rep("z", 10), { sid = "1760000000030" })
    eq(#sbox, 1, "a stream at the host's maxPayload is delivered")
    B:send("Small", string.rep("z", 11), { sid = "1760000000031" })
    eq(#sbox, 1, "a stream over the host's maxPayload is refused")
end

-- 11. A stream with no chunk for 6 s is dropped.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    local frames = B:frames("GlassChat", string.rep("w", 500))
    B:deliver(frames[1])
    WoW.advance(7)
    eq(next(lib.state.buffers), nil, "an idle stream is dropped after 6 s")
    for i = 2, #frames do B:deliver(frames[i]) end
    eq(#box, 0, "and its late chunks never deliver it")
end

-- 12. Monotonic sids: an older snapshot never lands after a newer one, nor
--     the same one twice, nor under another id (§5.2).
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    B:send("GlassChat", "newer", { sid = "1760000000005" })
    B:send("GlassChat", "older", { sid = "1760000000004" })
    B:send("GlassChat", "newer", { sid = "1760000000005" })
    eq(#box, 1, "an older sid and a replayed sid are both refused")
    eq(box[1].payload, "newer", "  the newer one stands")
end
do
    -- B proven at id 3 accepted sid 5; an old genuine stream of B's replayed
    -- through another id whose hello proved B's GUID.
    local lib, inst, store, B = proven()
    local box = inbox(inst)
    B:send("GlassChat", "newer", { sid = "1760000000005" })
    local R = Peer.new({ id = 4, name = "Karuzo", guid = B.guid, blank = true })
    inst.Rescan()
    R:deliver(R:hello())
    R:send("GlassChat", "older", { sid = "1760000000004" })
    eq(#box, 1, "an older stream replayed under another id is refused (floor per sender GUID)")
end

-- 13. Stream ids survive a same-second /reload, and never repeat.
do
    local store = {}
    local lib, inst, st, B = verified(store)
    WoW.sent = {}
    inst.Send("one")
    local first = tonumber(B:received("GlassChat", store)[1].sid)
    local now = WoW.now
    -- /reload in the same second: a new client, the same SavedVariables.
    lib, inst, st, B = verified(store)
    WoW.now = now
    WoW.sent = {}
    inst.Send("two")
    local second = tonumber(B:received("GlassChat", store)[1].sid)
    check(second > first, "a sid after a same-second reload is higher (" .. first .. " -> " .. second .. ")")
    local last, increasing = 0, true
    for _ = 1, 1500 do
        local sid = lib.impl.NextSid()
        if sid <= last then increasing = false end
        last = sid
    end
    check(increasing, "1500 sids in one second keep increasing")
end

-- 14. Tag routing: a frame for a tag nobody here runs is dropped; two hosts
--     each get only their own.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    local other = newHost(lib, "AltStable", {})
    local obox = inbox(other)
    B:send("Nobody", "lost", { sid = "1760000000040" })
    B:send("AltStable", "for altstable", { sid = "1760000000041" })
    B:send("GlassChat", "for glasschat", { sid = "1760000000042" })
    eq(#box, 1, "GlassChat gets one message")
    eq(box[1].payload, "for glasschat", "  its own")
    eq(#obox, 1, "AltStable gets one message")
    eq(obox[1].payload, "for altstable", "  its own")
end

-- 15. A handler that throws is reported; delivery goes on.
do
    local lib, inst, store, B = verified()
    local calls = 0
    inst.OnMessage(function(p) calls = calls + 1; if p == "bad" then error("boom") end end)
    B:send("GlassChat", "bad", { sid = "1760000000050" })
    B:send("GlassChat", "good", { sid = "1760000000051" })
    eq(calls, 2, "a throwing handler does not stop the next message")
    local reported = false
    for _, r in ipairs(reports.GlassChat) do if r.text:find("boom") then reported = true end end
    check(reported, "  and its error is reported to its host")
end

-- 16. TargetOffline: reported as offline, the binding dropped.
do
    local lib, inst, store, B = verified()
    local got = {}
    WoW.sendResults = { 12 }
    inst.Send("x", results(got))
    eq(got[1] and got[1].reason, "offline", "a send refused as offline is reported so")
    eq(#inst.Peers(), 0, "  and the binding goes")
end

-- 17. A friend's game data is dropped unread.
do
    local lib, inst = session()
    local box = inbox(inst)
    local F = Peer.new({ id = 9, name = "Friend", guid = "Player-1-0000000F", bnet = 77 })
    F:send("GlassChat", "not yours")
    eq(#box, 0, "a friend's stream is not delivered")
    eq(next(lib.state.buffers), nil, "  nor buffered")
    for k = 1, 50 do F:send("GlassChat", "flood", { sid = tostring(1760000000100 + k) }) end
    eq(next(lib.state.refused), nil, "  nor remembered: a stranger's flood grows nothing")
end

-- 17b. A host's onResult that rescans mid-Send: every peer still reported once.
do
    local lib, inst, store, B = verified()
    Peer.new({ id = 4, name = "Two", guid = "Player-1-00000004" })
    Peer.new({ id = 5, name = "Three", guid = "Player-1-00000005" })
    inst.Rescan()                            -- 4 and 5 bound, no nonce yet
    local seen = {}
    inst.Send("x", function(sender) seen[#seen + 1] = sender.name; inst.Rescan() end)
    table.sort(seen)
    eq(table.concat(seen, ","), "Karuzo,Three,Two", "each peer reported exactly once")
end

-- 17c. A host's onResult that switches sync off mid-Send doesn't make Send throw.
do
    local lib, inst, store, B = verified()
    Peer.new({ id = 4, name = "Two", guid = "Player-1-00000004" })
    inst.Rescan()
    local ok = pcall(inst.Send, "x", function() inst.SetEnabled(false) end)
    check(ok, "Send survives its own callback wiping the session")
end

-- 17d. A destination whose first chunk fails gets no more chunks.
do
    local lib, inst, store, B = verified()
    local calls = 0
    local real = C_BattleNet.SendGameData
    C_BattleNet.SendGameData = function(...) calls = calls + 1; return real(...) end
    WoW.sendResults = { 12 }
    inst.Send(string.rep("q", 3000))
    C_BattleNet.SendGameData = real
    eq(calls, 1, "after an offline refusal, the other chunks are not queued")
end

-- 18. Waiting sends: ChatThrottleLib holding frames, reported only when the
--     last one goes; a failure on any chunk reports failed once.
do
    local lib, inst, store, B = verified()
    local got = {}
    WoW.ctlDefer = true
    inst.Send(string.rep("q", 1000), results(got))
    eq(#got, 0, "nothing reported while the frames wait")
    WoW.ctlDrain()
    eq(#got, 1, "one report when they have gone")
    eq(got[1].status, "sent", "  sent")
    got = {}
    WoW.ctlDefer = true
    inst.Send(string.rep("q", 1000), results(got))
    WoW.sendResults = { 0, 9 }
    WoW.ctlDrain()
    eq(#got, 1, "a failed chunk is reported once")
    eq(got[1].status, "failed", "  as failed")
end

-- 19. SendTo: one peer by GUID; the others get nothing (#14).
do
    local lib, inst, store, B = verified()
    local C = Peer.new({ id = 4, name = "Two", guid = "Player-1-00000004" })
    inst.Rescan()
    C:deliver(C:hello({ key = C.key }))
    eq(#inst.Peers(), 2, "two peers")
    WoW.sent = {}
    local got = {}
    eq(inst.SendTo(C.guid, "for Two only", results(got)), 1, "SendTo reaches one peer")
    eq(#sentTo(3, "D1|"), 0, "  the other peer gets no frame")
    local r = C:received("GlassChat", store)
    eq(r[1] and r[1].payload, "for Two only", "  the target gets the payload")
    check(r[1] and r[1].macOk, "  MAC'd over its own nonce")
    eq(#got, 1, "  one result")
    eq(got[1] and got[1].name, "Two", "  for the target")
    eq(got[1] and got[1].status, "sent", "  as sent")
    WoW.sent = {}
    eq(inst.Send("x", nil, C.guid), 2, "Send ignores a third argument: still every peer")
end

-- 19b. A target that isn't a current peer: refused before sending, no
--      result, never a broadcast; a target that isn't a GUID is an error.
do
    local lib, inst, store, B = verified()
    WoW.sent = {}
    local got = {}
    local n, why = inst.SendTo("Player-1-000000FF", "x", results(got))
    eq(n, nil, "a GUID that isn't a peer: nothing sent")
    eq(why, "no-peers", "  no-peers")
    eq(#sentTo(nil, "D1|"), 0, "  not a frame to anyone")
    eq(#got, 0, "  and no onResult")
    n, why = inst.SendTo(WoW.player.guid, "x")
    eq(why, "no-peers", "our own GUID isn't a peer")
    local function says(e, text) return e ~= nil and e:find(text, 1, true) ~= nil end
    check(says(errs(inst.SendTo, "Karuzo", "x"), "SendTo(guid, payload): guid must be"), "SendTo with a name is an error")
    check(says(errs(inst.SendTo, nil, "x"), "guid must be a player GUID"), "SendTo with no target is an error")
    check(says(errs(inst.SendTo, B.guid, 42), "SendTo(guid, payload): payload must be"),
          "SendTo with a non-string payload is an error, naming SendTo")
    check(says(errs(inst.Send, 42), "Send(payload): payload must be"), "  and Send's names Send")
    eq(select(2, inst.SendTo(B.guid, string.rep("x", 16385))), "too-large", "SendTo keeps Send's refusals")
end

-- 19c. A target whose nonce we don't hold: told once, helloed, no frames.
do
    local lib, inst, store, B = verified()
    local C = Peer.new({ id = 4, name = "Two", guid = "Player-1-00000004" })
    inst.Rescan()
    WoW.advance(6)
    WoW.sent = {}
    local got = {}
    eq(inst.SendTo(C.guid, "x", results(got)), 0, "no destination yet")
    eq(#got, 1, "  one result")
    eq(got[1] and got[1].reason, "not-ready", "  not-ready")
    eq(got[1] and got[1].name, "Two", "  for the target")
    eq(#sentTo(4, "H1|"), 1, "  and it gets a hello")
    eq(#sentTo(nil, "D1|"), 0, "  and nobody gets a frame")
end

-- 19d. One GUID bound to two ids (#4): one destination, an id holding a
--      nonce, and one result; with no nonce on either, one not-ready.
do
    local lib, inst, store, B = verified()
    local B2 = Peer.new({ id = 6, name = B.name, guid = B.guid })
    inst.Rescan()
    WoW.advance(6)
    WoW.sent = {}
    local got = {}
    eq(inst.SendTo(B.guid, "x", results(got)), 1, "two ids, one GUID: one destination")
    eq(#sentTo(3, "D1|"), 1, "  the id holding a nonce")
    eq(#sentTo(6, "D1|"), 0, "  and not the other")
    eq(#got, 1, "  one result")
    B2:deliver(B2:hello({ key = B2.key }))
    WoW.sent, got = {}, {}
    eq(inst.SendTo(B.guid, "x", results(got)), 1, "both ids holding a nonce: still one destination")
    eq(#sentTo(3, "D1|") + #sentTo(6, "D1|"), 1, "  one stream")
    eq(#got, 1, "  one result")
end
-- The id holding the nonce is not the first one seen: still one send, one result.
do
    local lib, inst = session()
    local B = Peer.new({})
    local B2 = Peer.new({ id = 6, name = B.name, guid = B.guid })
    inst.Rescan()
    B2:deliver(B2:hello({ key = B2.key }))
    eq(lib.state.theirNonce[3], nil, "  (id 3, seen first, holds no nonce)")
    WoW.sent = {}
    local got = {}
    eq(inst.SendTo(B.guid, "x", results(got)), 1, "the id with the nonce gets the send")
    eq(#sentTo(6, "D1|"), 1, "  to id 6")
    eq(#got, 1, "  one result")
    eq(got[1] and got[1].status, "sent", "  sent, with no not-ready before it")
end
do
    local lib, inst = session()
    local B = Peer.new({})
    Peer.new({ id = 6, name = B.name, guid = B.guid })
    inst.Rescan()
    WoW.advance(6)
    local got = {}
    local h3, h6 = #sentTo(3, "H1|"), #sentTo(6, "H1|")
    eq(inst.SendTo(B.guid, "x", results(got)), 0, "two ids, no nonce: no destination")
    eq(#got, 1, "  one not-ready result, not one per id")
    eq(#sentTo(3, "H1|") - h3, 1, "  a hello to id 3")
    eq(#sentTo(6, "H1|") - h6, 1, "  and to id 6")
end

done("test_transport")
