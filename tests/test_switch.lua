-- test_switch.lua: no delivery without its MAC (MINOR 7, #37). A character
-- switch the Battle.net record hasn't caught up with (AltStable measured 13 s
-- on 70938) must never credit the new character's stream to the old one,
-- and an old character's last stream stays its own. PLAN's "Proposed for
-- MINOR 7" section has the design and the Codex review it went through.
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local G1, G2 = "Player-1-0000000B", "Player-1-000000B2"

-- A Battle.net-verified other account at id 3, character G1 ("Karuzo"), its
-- key trusted; a messages host when asked.
local function verified(opts)
    local lib, inst, store = session(nil, opts)
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    return lib, inst, store, B
end

-- The account now plays G2 ("Bravo"); our record follows only when `caught`.
local function switch(B, caught)
    B.guid, B.name = G2, "Bravo"
    if caught then B.record.playerGuid, B.record.characterName = G2, "Bravo" end
end

local function senders(box)
    local t = {}
    for _, m in ipairs(box) do t[#t + 1] = m.payload .. "@" .. tostring(m.sender.guid) end
    return table.concat(t, ",")
end

-- 1. The bug: the record still names G1 while G2 sends. Not delivered as G1;
--    delivered as G2 once a scan sees the record name G2 (pinned at the
--    forget, delivered on the next frame).
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    switch(B, false)
    B:deliver(B:hello({ key = B.key }))                 -- G2's hello: contradicts the record, dropped
    B:send("GlassChat", "from G2", { sid = "1760000000300" })
    eq(#box, 0, "a stream MAC'd for G2 is not delivered while the record still names G1")
    WoW.advance(3)
    eq(#box, 0, "  nor later, while the record lags")
    B.record.playerGuid, B.record.characterName = G2, "Bravo"
    inst.Rescan()
    eq(#box, 0, "  the scan only pins it: no handler runs mid-transition")
    WoW.advance(1)
    eq(senders(box), "from G2@" .. G2, "delivered as G2 on the next frame, once the record names it")
    eq(box[1] and box[1].sender.name, "Bravo", "  with the record's name for G2")
    eq(box[1] and box[1].sender.proven, "bnet", "  and Battle.net's proven")
end

-- 2. The second branch: admitted while the record was blank (G1 the last
--    binding), completed while the stale record names G1 again.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    B:setBlank(true)
    switch(B, false)
    local fr = B:frames("GlassChat", string.rep("x", 600), { sid = "1760000000301" })
    B:deliver(fr[1])
    B:setBlank(false)                                   -- the record comes back, still G1
    B.record.playerGuid, B.record.characterName = G1, "Karuzo"
    for i = 2, #fr do B:deliver(fr[i]) end
    WoW.advance(2)
    eq(#box, 0, "a stream admitted while blank is not credited to the stale G1")
end

-- 3. G1's own last stream, completed after the record names G2: the
--    admission binding verifies it, so it stays G1's.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    local fr = B:frames("GlassChat", string.rep("o", 600), { sid = "1760000000302" })
    B:deliver(fr[1])                                    -- G1 starts sending
    switch(B, true)                                     -- the record names G2 now
    for i = 2, #fr do B:deliver(fr[i]) end
    eq(senders(box), string.rep("o", 600) .. "@" .. G1, "G1's last stream is delivered as G1")
end

-- 4. Route forgets with the binding it just read (Codex round 3): a send
--    finds G2, and G2's waiting stream is pinned to it.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    switch(B, false)
    B:send("GlassChat", "via route", { sid = "1760000000303" })
    B.record.playerGuid, B.record.characterName = G2, "Bravo"
    lib.state.routeChecked[3] = nil                     -- the route cache has expired
    inst.Send("ping")
    WoW.advance(1)
    eq(senders(box), "via route@" .. G2, "a route check that finds G2 delivers G2's stream as G2")
end

-- 5. Handlers run after the transition, in completion order: one that sends
--    doesn't drop the next; one that switches the library off stops the rest
--    and the scan doesn't undo its wipe.
do
    local lib, inst, store, B = verified({ host = { messages = true } })
    local box = {}
    inst.OnMessage(function(payload, sender)
        box[#box + 1] = payload .. "@" .. tostring(sender.guid)
        inst.Send("reply")
    end)
    switch(B, false)
    B:send("GlassChat", "m1", { sid = "1760000000310" })
    B:send("GlassChat", "m2", { sid = "1760000000311" })
    B.record.playerGuid, B.record.characterName = G2, "Bravo"
    inst.Rescan()
    WoW.advance(1)
    eq(table.concat(box, ","), "m1@" .. G2 .. ",m2@" .. G2, "both delivered as G2, in order, though m1's handler sends")
end
do
    local lib, inst, store, B = verified({ host = { messages = true } })
    local box = {}
    inst.OnMessage(function(payload)
        box[#box + 1] = payload
        inst.SetEnabled(false)
    end)
    switch(B, false)
    B:send("GlassChat", "m1", { sid = "1760000000312" })
    B:send("GlassChat", "m2", { sid = "1760000000313" })
    B.record.playerGuid, B.record.characterName = G2, "Bravo"
    inst.Rescan()
    WoW.advance(1)
    eq(table.concat(box, ","), "m1", "a handler that switches the library off stops the next delivery")
    eq(next(lib.state.peers), nil, "  and its wipe holds: no peer rebuilt behind it")
end

-- 6. A pinned stream survives a second forget (its nonce is gone, so it is
--    never re-verified) and is delivered once.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    switch(B, false)
    B:send("GlassChat", "twice forgotten", { sid = "1760000000304" })
    B.record.playerGuid, B.record.characterName = G2, "Bravo"
    -- Two forgets back to back, as a scan can do (its learned cleanup, then its
    -- changed-binding loop): the second finds no nonce left.
    lib.impl.ForgetId(3, lib.impl.GameFor(3))           -- pinned to G2
    eq(lib.state.myNonce[3], nil, "the first forget took the nonce")
    lib.impl.ForgetId(3)                                -- forgotten again before the drain
    WoW.advance(2)
    eq(senders(box), "twice forgotten@" .. G2, "a second forget keeps the pin; delivered once")
end

-- 7. A pin made inside GameFor, during the stream's own delivery: the learned
--    binding goes (the record went offline) as the last chunk lands, and the
--    stream is delivered at once as its own character.
do
    local store = { v = 1, key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", keyAt = 100,
                    trusted = { [OTHER_KEY] = 100 }, selfProject = 18, selfRegion = 90, selfAt = 100 }
    local lib, inst = session(store)
    local box = inbox(inst)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    B:deliver(B:hello())                                -- proven by its proof: learned as G1
    local fr = B:frames("GlassChat", string.rep("l", 600), { sid = "1760000000305" })
    for i = 1, #fr - 1 do B:deliver(fr[i]) end
    B.record.isOnline = false                           -- logged out, its last chunk in flight
    B:deliver(fr[#fr])
    eq(senders(box), string.rep("l", 600) .. "@" .. G1, "delivered at once as G1, pinned inside GameFor")
end

-- 8. A new completion of G2 before the next-frame drain doesn't overtake the
--    pinned one (messages mode, one ordered drain).
do
    local lib, inst, store, B = verified({ host = { messages = true } })
    local box = inbox(inst)
    switch(B, false)
    B:send("GlassChat", "first", { sid = "1760000000320" })
    B.record.playerGuid, B.record.characterName = G2, "Bravo"
    inst.Rescan()                                       -- "first" pinned; our new hello goes to G2
    B:deliver(B:hello({ key = B.key }))
    B:send("GlassChat", "second", { sid = "1760000000321" })   -- under our new nonce, before the drain
    WoW.advance(1)
    eq(senders(box), "first@" .. G2 .. ",second@" .. G2, "the pinned stream is delivered before a later completion")
end

-- 9. Our previous nonce: a stream MAC'd under it, after our session was
--    wiped, is not delivered (a stated loss of MINOR 7).
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    local stale = B:frames("GlassChat", "under the old nonce", { sid = "1760000000306" })
    inst.SetEnabled(false)
    inst.SetEnabled(true)
    inst.Rescan()                                       -- a new nonce goes out
    for _, f in ipairs(stale) do B:deliver(f) end
    WoW.advance(31)
    eq(#box, 0, "a stream MAC'd under our previous nonce is dropped")
    B:send("GlassChat", "under the new one", { sid = "1760000000307" })
    eq(senders(box), "under the new one@" .. G1, "  the next one, under our new nonce, is delivered")
end

-- 10. A stream an older copy left waiting is delivered by this one only if
--     its MAC verifies.
do
    WoW.reset(); WoW.resetLibStub()
    local old = loadCopy(fixtureCopy("LibAccountSync-r6.lua"), "GlassChat")
    local store = { v = 1, key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", keyAt = 100,
                    trusted = { [OTHER_KEY] = 100 }, selfProject = 18, selfRegion = 90, selfAt = 100 }
    local inst = newHost(old, "GlassChat", store)
    login()
    WoW.advance(61)
    local box = inbox(inst)
    local B = Peer.new({ blank = true })
    inst.Rescan()                                       -- hinted: our nonce goes to B
    B:send("GlassChat", "good", { sid = "1760000000330" })
    B:send("GlassChat", "forged", { sid = "1760000000331", mac = string.rep("1", 32) })
    eq(#box, 0, "r6 holds both, waiting for the hello")
    loadLibrary("AltStable")                            -- this copy takes over
    B:deliver(B:hello())
    eq(table.concat((function() local t = {} for _, m in ipairs(box) do t[#t + 1] = m.payload end return t end)(), ","),
       "good", "this copy delivers the one whose MAC verifies, never the other")
end

--------------------------------------------------------------------------------
-- MINOR 8 (#38): a frame admitted while Battle.net's record has nothing (at a
-- logout its offline reaches us before the last frame, measured 2026-11-17)
-- takes the binding the library holds as its admission binding. The MAC
-- still decides; nothing else changes (Codex round 2 on the logout loss).
--------------------------------------------------------------------------------

-- The record as measured at a logout to the character list: offline, no GUID.
local function offline(B)
    B.record.isOnline, B.record.playerGuid, B.record.characterName = false, nil, nil
end
local function heldBuffer(lib)
    for _, b in pairs(lib.state.buffers) do return b end
end

-- 11. The measured sequence: one-frame bye from G1 after its record went
--     offline, then the scan. Delivered at once as G1, Battle.net's binding.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    offline(B)
    B:send("GlassChat", "bye", { sid = "1760000000400" })
    eq(senders(box), "bye@" .. G1, "a bye landing after the record went offline is delivered as G1")
    eq(box[1] and box[1].sender.proven, "bnet", "  proven as the binding it verified against was")
    inst.Rescan()
    WoW.advance(31)
    eq(#box, 1, "  once: the scan's forget finds nothing left")
    eq(lib.state.myNonce[3], nil, "  and the id is forgotten, its nonce with it")
end

-- 12. A stream admitted offline holds a copy of the binding, not Battle.net's
--     word: not `verified` (no room made at the caps), not the live table.
--     Completed before the forget: delivered as G1.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    offline(B)
    local fr = B:frames("GlassChat", string.rep("g", 600), { sid = "1760000000401" })
    B:deliver(fr[1])
    local buf = heldBuffer(lib)
    check(buf and buf.peer and buf.peer.guid == G1, "admitted offline with the held binding, G1")
    eq(buf and buf.verified, false, "  not verified: Battle.net doesn't vouch now")
    check(buf and buf.peer ~= lib.state.peers[3], "  a copy, not the live binding")
    lib.state.peers[3].guid = G2                        -- the live table changes under it
    eq(buf and buf.peer.guid, G1, "  which a later change to the live binding doesn't rewrite")
    lib.state.peers[3].guid = G1
    for i = 2, #fr do B:deliver(fr[i]) end
    eq(senders(box), string.rep("g", 600) .. "@" .. G1, "completed before the forget: delivered as G1")
end

-- 13. Still incomplete at the forget: dropped, and its later chunks find no
--     nonce (a stated loss).
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    offline(B)
    local fr = B:frames("GlassChat", string.rep("i", 600), { sid = "1760000000402" })
    B:deliver(fr[1])
    inst.Rescan()
    eq(heldBuffer(lib), nil, "an incomplete stream goes with the forget")
    for i = 2, #fr do B:deliver(fr[i]) end
    WoW.advance(31)
    eq(#box, 0, "  and its later chunks are refused: no nonce left")
end

-- 14. G2 sends while the record is offline and the library still holds G1:
--     never delivered as G1; delivered as G2 once the record names G2.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    offline(B)
    switch(B, false)
    B:send("GlassChat", "from G2", { sid = "1760000000403" })
    WoW.advance(2)
    eq(#box, 0, "G2's stream, admitted on the held G1, is not delivered as G1")
    B.record.isOnline, B.record.playerGuid, B.record.characterName = true, G2, "Bravo"
    inst.Rescan()
    WoW.advance(1)
    eq(senders(box), "from G2@" .. G2, "  delivered as G2 once the record names it")
end

-- 15. Admitted offline (held G1), the record names G2 before completion: a
--     G1 stream stays G1's, a G2 stream is G2's.
do
    local lib, inst, store, B = verified({ host = { messages = true } })
    local box = inbox(inst)
    offline(B)
    local f1 = B:frames("GlassChat", string.rep("1", 600), { sid = "1760000000404" })
    switch(B, false)
    local f2 = B:frames("GlassChat", string.rep("2", 600), { sid = "1760000000405" })
    B:deliver(f1[1]); B:deliver(f2[1])
    B.record.isOnline, B.record.playerGuid, B.record.characterName = true, G2, "Bravo"
    for i = 2, #f1 do B:deliver(f1[i]) end
    for i = 2, #f2 do B:deliver(f2[i]) end
    eq(senders(box), string.rep("1", 600) .. "@" .. G1 .. "," .. string.rep("2", 600) .. "@" .. G2,
       "each stream is delivered as the character its MAC binds")
end

-- 16. The held binding is a candidate, never a pass: a wrong MAC, or one
--     made under a key we don't trust, is not delivered.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    offline(B)
    B:send("GlassChat", "forged", { sid = "1760000000406", mac = string.rep("1", 32) })
    B:send("GlassChat", "untrusted", { sid = "1760000000407", key = string.rep("c", 32) })
    WoW.advance(31)
    eq(#box, 0, "a wrong MAC or an untrusted key is refused under the held binding")
end

-- 17. A blank peer, bound by its proof, whose record goes offline before its
--     first frame: GameFor forgets the id at admission (a stated loss).
do
    local store = { v = 1, key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", keyAt = 100,
                    trusted = { [OTHER_KEY] = 100 }, selfProject = 18, selfRegion = 90, selfAt = 100 }
    local lib, inst = session(store)
    local box = inbox(inst)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    B:deliver(B:hello())                                -- proven: learned as G1
    check(lib.state.peers[3] and lib.state.peers[3].guid == G1, "(a blank peer bound by its proof)")
    B.record.isOnline = false
    B:send("GlassChat", "too late", { sid = "1760000000409" })
    eq(#box, 0, "its first frame after the record went offline is not delivered")
    eq(lib.state.myNonce[3], nil, "  the id was forgotten at admission")
    eq(heldBuffer(lib), nil, "  and nothing is held")
end

-- 18. A stream r7 admitted with no binding is not given one by this copy
--     (no backfill of admission history; Codex round 2 on the logout loss).
do
    WoW.reset(); WoW.resetLibStub()
    local old = loadCopy(fixtureCopy("LibAccountSync-r7.lua"), "GlassChat")
    local store = { v = 1, key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", keyAt = 100,
                    trusted = { [OTHER_KEY] = 100 }, selfProject = 18, selfRegion = 90, selfAt = 100 }
    local inst = newHost(old, "GlassChat", store)
    login()
    WoW.advance(61)
    local box = inbox(inst)
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    offline(B)
    B:send("GlassChat", "r7's bye", { sid = "1760000000410" })
    local buf = heldBuffer(old)
    check(buf and buf.complete and buf.peer == nil, "r7 holds the bye, admitted with no binding")
    loadLibrary("AltStable")                            -- this copy takes over
    inst.Rescan()
    WoW.advance(31)
    eq(#box, 0, "this copy doesn't backfill its binding: lost, as under r7")
end

done("test_switch")
