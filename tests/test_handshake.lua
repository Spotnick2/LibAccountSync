-- test_handshake.lua: the household key, the hello and the proof (§5.1, §5.2),
-- ported from AltStable's #58 block (tests/test_comm.lua 3272-4362) plus the
-- cases the plan's review rounds added.

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function names(inst)
    local out = {}
    for _, p in ipairs(inst.Peers()) do out[#out + 1] = p.name .. ":" .. p.proven end
    return table.concat(out, ",")
end

-- A store that has seen the other account before: our key, its key trusted,
-- our game and region known. Needed whenever OUR presence is blank.
local function seasoned()
    return { v = 1, key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", keyAt = 100,
             trusted = { [OTHER_KEY] = 100 }, selfProject = 18, selfRegion = 90, selfAt = 100 }
end

-- 1. Both presences full: the key travels, and is trusted.
do
    local lib, inst, store = session()
    local B = Peer.new({})
    inst.Rescan()
    local ours = B:ourHello()
    check(ours ~= nil, "a verified own account gets a hello")
    eq(ours.key, store.key, "  carrying our household key")
    check(#ours.nonce == 16 and not ours.nonce:find("[^0-9a-f]"), "  and a 16-hex nonce")
    eq(ours.proof, "", "  and no proof before we hold its nonce")
    check(type(store.key) == "string" and #store.key == 32, "our key was made and stored")
    B:deliver(B:hello({ key = B.key }))
    check(store.trusted and store.trusted[OTHER_KEY], "a key from a verified account is trusted")
    eq(names(inst), "Karuzo:bnet", "the account is a peer, proven by Battle.net")
    local answer = B:ourHello()
    eq(answer.proof, proofFor(store.key, B.nonce, answer.nonce, "Malas", WoW.player.guid, WoW.player.realm, 18, 90),
       "our answer proves our key over its nonce, by the plan's formula")
end

-- 1b. Names with surnames, as on Forever (#4): UnitName gives the surname
--     apart, Battle.net gives "Name Surname". Our hello carries the whole
--     name, and a verified account's whole-name hello is matched.
do
    local lib, inst, store = session(nil, { before = function() WoW.player.surname = "Belgarden" end })
    local B = Peer.new({ name = "Karuzo Test" })
    inst.Rescan()
    eq(B:ourHello().name, "Malas Belgarden", "our hello carries our whole name")
    B:deliver(B:hello({ key = B.key }))
    eq(names(inst), "Karuzo Test:bnet", "a verified account's whole-name hello is matched")
    eq(lib.state.theirNonce[3], B.nonce, "  and its nonce is held, so Send has a destination")
    local answer = B:ourHello()
    eq(answer.proof, proofFor(store.key, B.nonce, answer.nonce, "Malas Belgarden", WoW.player.guid,
       WoW.player.realm, 18, 90), "  our proof binds the whole name")
    B:deliver(B:hello({ key = B.key, name = "Karuzo", nonce = "0f0f0f0f0f0f0f0f" }))
    eq(lib.state.theirNonce[3], B.nonce, "a first-name-only hello (a cc92deb copy) is still refused")
end
do
    local lib, inst = session(nil, { before = function()
        WoW.player.name, WoW.player.surname = "Malas Belgarden", "Classic Beta PvE"
    end })
    local B = Peer.new({})
    inst.Rescan()
    eq(B:ourHello().name, "Malas Belgarden", "a first return that is already whole is not glued to the second")
end

-- 2. A verified id whose hello names someone else: dropped, nothing trusted.
do
    local lib, inst, store = session()
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key, name = "Impostor" }))
    check(not (store.trusted and store.trusted[OTHER_KEY]), "a hello contradicting Battle.net is not trusted")
    B:deliver(B:hello({ key = B.key, guid = "Player-1-000000EE" }))
    check(not (store.trusted and store.trusted[OTHER_KEY]), "  nor one whose GUID disagrees with Battle.net's")
end

-- 3. Only our own other account counts: friends, offline accounts, another
--    game, another region, a failed lookup.
do
    local lib, inst, store = session()
    local F = Peer.new({ id = 9, name = "Friend", guid = "Player-1-0000000F", bnet = 77 })
    local Off = Peer.new({ id = 4, name = "Asleep", guid = "Player-1-00000004" })
    Off.record.isOnline = false
    local Ptr = Peer.new({ id = 5, name = "Ptr", guid = "Player-1-00000005", project = 19 })
    local Eu = Peer.new({ id = 6, name = "Eu", guid = "Player-1-00000006", region = 91 })
    inst.Rescan()
    eq(names(inst), "", "no peer among a friend, an offline account, another game, another region")
    eq(#sentTo(9), 0, "  nothing sent to the friend")
    eq(#sentTo(4) + #sentTo(5) + #sentTo(6), 0, "  nor to the others")
end

-- 4. Ownership is by BattleTag; a BNGetInfo presenceID from another namespace
--    that equals a friend's account id does not make the friend ours.
do
    local lib, inst, store = session()
    WoW.bn.blank = true                      -- our record gone: BNGetInfo is the fallback
    WoW.bn.presenceID = 77
    store.selfProject, store.selfRegion, store.selfAt = 18, 90, 100
    local F = Peer.new({ id = 9, name = "Friend", guid = "Player-1-0000000F", bnet = 77 })
    F.record.battleTag = "Friend#77"
    inst.Rescan()
    eq(names(inst), "", "a numerically equal presence id does not make a friend ours")
    eq(#sentTo(9), 0, "  and the friend gets nothing, the key least of all")
end

-- 5. Both presences blank: nonce, proof, proof (AltStable Codex round 3).
do
    local store = seasoned()
    local lib, inst = session(store)
    WoW.bn.blank = true
    local B = Peer.new({ blank = true })
    inst.Rescan()
    local first = B:ourHello()
    check(first ~= nil, "a blank id that is ours by elimination gets a hello")
    eq(first.key, "", "  without the key")
    B:deliver(B:hello())                     -- answers our nonce with its proof
    eq(names(inst), "Karuzo:proof", "its proof over our nonce, under a trusted key, makes it a peer")
    local answer = B:ourHello()
    eq(answer.proof, proofFor(store.key, B.nonce, answer.nonce, "Malas", WoW.player.guid, WoW.player.realm, 18, 90),
       "  and we prove ourselves over its nonce")
end

-- 6. A trusted key in a blank id's hello: believed ("key").
do
    local store = seasoned()
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    B:deliver(B:hello({ key = OTHER_KEY, proof = "" }))
    eq(names(inst), "Karuzo:key", "a blank id whose hello carries a trusted key is a peer")
end

-- 7. Bad proofs, replays and reflections are not believed.
do
    local store = seasoned()
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    local C = Peer.new({ id = 4, name = "Other", guid = "Player-1-00000004", blank = true })
    inst.Rescan()
    B:deliver(B:hello({ proof = string.rep("0", 32) }))
    eq(names(inst), "", "a wrong proof is not believed")
    B:deliver(B:hello({ proofKey = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", nonce = "1111111111111111" }))
    eq(names(inst), "", "a proof under an untrusted key is not believed")
    -- B's valid proof over OUR nonce for id 3, replayed from id 4.
    C:deliver(B:hello({ nonce = "2222222222222222" }), 4)
    eq(names(inst), "", "a proof replayed to another id is not believed")
    -- A hello with our own nonce for that id, i.e. our own words reflected back.
    local ours = B:ourHello()
    B:deliver(B:hello({ nonce = ours.nonce }))
    eq(names(inst), "", "a hello reflecting our own nonce is dropped")
    -- A hello in our own name.
    B:deliver(B:hello({ name = "Malas", nonce = "3333333333333333" }))
    eq(names(inst), "", "a hello in our own name is dropped")
    -- A proof made with OUR key: our own key never counts as trusted.
    store.trusted[store.key] = 200
    B:deliver(B:hello({ proofKey = store.key, nonce = "4444444444444444" }))
    eq(names(inst), "", "a proof under our own key is not believed")
end

-- 8. A leaked key from an id we have no reason to talk to (a friend's blank
--    account): not believed. Parity believed it from any id (§5.2).
do
    local store = seasoned()
    local lib, inst = session(store)
    WoW.bn.friends = { { 9 } }
    local F = Peer.new({ id = 9, name = "Friend", guid = "Player-1-0000000F", blank = true, bnet = 77 })
    inst.Rescan()
    eq(#sentTo(9), 0, "a friend's blank account gets no hello and no proof")
    F:deliver(F:hello({ key = OTHER_KEY, proof = "" }))
    eq(names(inst), "", "a trusted key from a friend's id is not believed")
    eq(lib.state.theirNonce[9], nil, "  and its nonce is not kept")
end

-- 9. The friends list fails closed: still loading, or with a gap.
do
    local store = seasoned()
    local lib, inst = session(store, { unsettled = true })
    WoW.advance(10)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    eq(#sentTo(3), 0, "a friends list still loading (first minute) makes no id ours by elimination")
    WoW.bn.friends = { { 9 } }
    WoW.bn.friendInfoNil = true
    WoW.advance(60)
    inst.Rescan()
    eq(#sentTo(3), 0, "a gap in the friends list is unknown, never ours")
    WoW.bn.friendInfoNil = false
    inst.Rescan()
    eq(#sentTo(3, "H1|"), 1, "a settled, complete list: the hint holds")
    WoW.fire("BN_DISCONNECTED")
    WoW.fire("BN_CONNECTED")
    WoW.sent = {}
    WoW.advance(3)
    eq(#sentTo(3), 0, "after a reconnect the list is loading again: no hint")
end

-- 10. An untrusted key from a blank id is never adopted: keys are learned only
--     from a verified account.
do
    local store = seasoned()
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    B:deliver(B:hello({ key = "cccccccccccccccccccccccccccccccc", proof = "" }))
    check(store.trusted["cccccccccccccccccccccccccccccccc"] == nil, "a key from a blank id is not trusted")
end

-- 11. No ping-pong: the same nonce again gets no forced answer.
do
    local lib, inst, store = session()
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    local n = #sentTo(3, "H1|")
    for _ = 1, 5 do B:deliver(B:hello({ key = B.key })) end
    eq(#sentTo(3, "H1|"), n, "repeating a nonce gets no more hellos")
    B:deliver(B:hello({ key = B.key, nonce = "9999999999999999" }))
    eq(#sentTo(3, "H1|"), n + 1, "a new nonce is answered at once")
    for i = 1, 20 do B:deliver(B:hello({ key = B.key, nonce = ("%016d"):format(i) })) end
    check(#sentTo(3, "H1|") <= n + 6, "a flood of new nonces is answered at most 6 times a minute")
end

-- 11b. A known peer whose nonce we hold gets no hello every minute.
do
    local lib, inst = session()
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    local n = #sentTo(3, "H1|")
    WoW.advance(300)
    eq(#sentTo(3, "H1|"), n, "five minutes of scans send a known peer no more hellos")
end

-- 11c. A delayed hello from the character that was there before is
--      rejected without touching the current character's nonce.
do
    local lib, inst = session()
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    local C = Peer.new({ id = 3, name = "Charlie", guid = "Player-1-000000C3", nonce = "c3c3c3c3c3c3c3c3" })
    C:deliver(C:hello({ key = C.key }))
    eq(lib.state.theirNonce[3], "c3c3c3c3c3c3c3c3", "the new character's nonce is held")
    B:deliver(B:hello({ key = B.key, nonce = "0b0b0b0b0b0b0b0b" }))
    eq(lib.state.theirNonce[3], "c3c3c3c3c3c3c3c3", "a delayed hello from the old character leaves it alone")
end

-- 12. A shared key (a settings folder copied between our accounts): the lower
--     GUID makes a new key; the higher keeps its own (§3, round 2).
do
    local store = { key = OTHER_KEY, keyAt = 50 }
    local lib, inst = session(store)
    local B = Peer.new({})             -- B's GUID ...0B is higher than ours ...0A
    inst.Rescan()
    B:deliver(B:hello({ key = OTHER_KEY }))
    check(store.key ~= OTHER_KEY and #store.key == 32, "the lower GUID makes a new key")
    check(store.trusted[OTHER_KEY] ~= nil, "  and trusts the old one, now the other account's alone")
    local warned = false
    for _, r in ipairs(reports.GlassChat) do if r.kind == "warning" then warned = true end end
    check(warned, "  and says so once")
    eq(B:ourHello().key, store.key, "  and tells the other account its new key")
end
do
    local store = { key = OTHER_KEY, keyAt = 50 }
    local lib, inst = session(store)
    WoW.player.guid = "Player-1-0000000C"   -- higher than B's
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = OTHER_KEY }))
    eq(store.key, OTHER_KEY, "the higher GUID keeps its key")
    check(not (store.trusted and store.trusted[OTHER_KEY]), "  and never trusts its own key")
end

-- 13. Battle.net going away clears what was found.
do
    local lib, inst = session()
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    eq(#inst.Peers(), 1, "a peer before")
    WoW.fire("BN_DISCONNECTED")
    eq(#inst.Peers(), 0, "none after Battle.net disconnects")
end

-- 14. A learned peer does not outlive its account: offline, it is forgotten.
do
    local store = seasoned()
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    B:deliver(B:hello())
    eq(names(inst), "Karuzo:proof", "proven while blank")
    B.record.isOnline = false
    inst.Rescan()
    eq(names(inst), "", "forgotten once its account goes offline")
end

-- 14b. A peer proven earlier this session that reloads (a new nonce, no
--      proof yet) is answered, even while our friends list fails closed: it
--      needs our nonce and proof back to believe us again.
do
    local store = seasoned()
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    B:deliver(B:hello())
    eq(names(inst), "Karuzo:proof", "proven while blank")
    WoW.bn.friends = { { 9 } }
    WoW.bn.friendInfoNil = true             -- the list now fails closed: no hints
    WoW.advance(120)
    B.nonce = "abababababababab"            -- B reloaded
    local n = #sentTo(3, "H1|")
    B:deliver(B:hello({ proof = "" }))
    eq(#sentTo(3, "H1|"), n + 1, "the reloaded peer is answered")
    local ours = B:ourHello()
    eq(ours.proof, proofFor(store.key, B.nonce, ours.nonce, "Malas", WoW.player.guid, WoW.player.realm, 18, 90),
       "  with our proof over its new nonce")
end

-- 14c. Proof checks are bounded per id (each costs up to 16 HMACs).
do
    local store = seasoned()
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    for i = 1, 30 do B:deliver(B:hello({ proof = ("%032x"):format(i), nonce = ("%016x"):format(i) })) end
    eq(lib.state.proofChecks[3].count, 12, "at most 12 proof checks a minute per id")
end

-- 14d. An answer that fails to send is not counted: the same nonce again is
--      answered.
do
    local store = seasoned()
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    WoW.advance(6)
    local n = #sentTo(3, "H1|")
    WoW.sendResults = { 9 }
    B:deliver(B:hello({ proof = "", nonce = "1212121212121212" }))
    eq(#sentTo(3, "H1|"), n, "the answer failed")
    B:deliver(B:hello({ proof = "", nonce = "1212121212121212" }))
    eq(#sentTo(3, "H1|"), n + 1, "the same nonce is answered again")
end

-- 14e. A hint's nonce is kept while the friends list fails closed: that
--      proves nothing about the id.
do
    local store = seasoned()
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    check(lib.state.myNonce[3] ~= nil, "a hint has our nonce")
    WoW.bn.friends = { { 9 } }
    WoW.bn.friendInfoNil = true
    inst.Rescan()
    check(lib.state.myNonce[3] ~= nil, "  and keeps it while the list fails closed")
end

-- 14f. A hello whose name carries a "-suffix" is refused: names are bare.
do
    local store = seasoned()
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    -- The genuine proof for "karuzo" (the proof binds the bare, lower-cased
    -- name), presented under an altered display name.
    local ours = B:ourHello()
    local proof = proofFor(B.key, ours.nonce, B.nonce, "Karuzo", B.guid, B.realm, 18, 90)
    B:deliver(B:hello({ name = "Karuzo-Elsewhere", proof = proof }))
    eq(names(inst), "", "a name with a suffix is not believed, even with the bare name's proof")
end

-- 15. Our presence blank and our game never seen: fail closed, no hellos.
do
    local lib, inst, store = session(nil, { before = function() WoW.bn.blank = true end })
    local B = Peer.new({ blank = true })
    inst.Rescan()
    eq(#sentTo(3), 0, "with our game unknown, nothing is sent")
end

done("test_handshake")
