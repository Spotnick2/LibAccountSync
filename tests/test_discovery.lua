-- test_discovery.lua: who counts as ours, and when we look (§5.1, §5.2).
-- The friend/offline/game/region exclusions and the friends-list cases are in
-- test_handshake; this file covers the rest of OwnAccountGame and the scan.

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function names(inst)
    local out = {}
    for _, p in ipairs(inst.Peers()) do out[#out + 1] = p.name end
    return table.concat(out, ",")
end

-- 1. A record with no regionID: Battle.net's own "same region" flag decides,
--    and only a definite yes counts (§5.2).
do
    local lib, inst = session()
    local B = Peer.new({})
    B.record.regionID = nil
    inst.Rescan()
    eq(names(inst), "Karuzo", "no regionID, isInCurrentRegion true: ours")
    B.record.isInCurrentRegion = nil
    inst.Rescan()
    eq(names(inst), "", "no regionID and no region flag: not ours")
end

-- 2. Our region unknown: fail closed, even with our game known.
do
    local store = { selfProject = 18, selfAt = 1 }
    local lib, inst = session(store, { before = function() WoW.bn.blank = true end })
    Peer.new({})
    inst.Rescan()
    eq(names(inst), "", "our region unknown: nobody is ours")
    eq(#sentTo(3), 0, "  and the key goes nowhere")
end

-- 3. This character is never a peer, by GUID.
do
    local lib, inst = session()
    Peer.new({ id = 5, name = "Malas", guid = WoW.player.guid })
    inst.Rescan()
    eq(names(inst), "", "our own character is not a peer")
end

-- 4. A malformed GUID is no GUID.
do
    local lib, inst = session()
    Peer.new({ guid = "Creature-0-1-2" })
    inst.Rescan()
    eq(names(inst), "", "a record whose GUID is not a player's is not ours")
end

-- 5. While our presence is blank and our game unknown, the scan looks again
--    every 10 s, so a presence that fills in is used within seconds.
do
    local lib, inst = session(nil, { before = function() WoW.bn.blank = true end })
    Peer.new({})
    inst.Rescan()
    eq(#sentTo(3), 0, "nothing while we don't know our game")
    WoW.bn.blank = false
    WoW.advance(11)
    eq(#sentTo(3, "H1|"), 1, "within 10 s of our presence filling in, the hello goes")
end

-- 6. A binding that changes (another character on that game account) drops
--    the old one's nonces: whoever is there now proves itself afresh.
do
    local lib, inst = session()
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    check(lib.state.theirNonce[3] ~= nil, "its nonce is held")
    B.record.characterName, B.record.playerGuid = "Alt", "Player-1-000000C1"
    inst.Rescan()
    eq(names(inst), "Alt", "the new character is the peer")
    eq(lib.state.theirNonce[3], nil, "  and the old character's nonce is gone")
end

-- 7. The key goes only to a verified id: a hint's hello never carries it.
do
    local store = { key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", keyAt = 1, selfProject = 18, selfRegion = 90, selfAt = 1 }
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    local V = Peer.new({ id = 4, name = "Visible", guid = "Player-1-00000004" })
    inst.Rescan()
    eq(B:ourHello().key, "", "a blank id ours by elimination gets no key")
    eq(V:ourHello().key, store.key, "a verified id gets it")
end

-- 8. A hinted id whose presence fills in as a friend's loses our nonce, and
--    with it the right to have frames buffered.
do
    local store = { key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", keyAt = 1, selfProject = 18, selfRegion = 90, selfAt = 1 }
    local lib, inst = session(store)
    local F = Peer.new({ id = 9, name = "Friend", guid = "Player-1-0000000F", blank = true, bnet = 77 })
    inst.Rescan()
    check(lib.state.myNonce[9] ~= nil, "a blank id ours by elimination is given a nonce")
    F:setBlank(false)                       -- it was a friend logging in
    inst.Rescan()
    eq(lib.state.myNonce[9], nil, "once it shows as a friend's, the nonce goes")
    F:send("GlassChat", "x")
    eq(next(lib.state.buffers), nil, "  and its frames are not buffered")
end

done("test_discovery")
