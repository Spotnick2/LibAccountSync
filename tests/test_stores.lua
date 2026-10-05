-- test_stores.lua: one household across hosts (§3): the key chosen lazily and
-- never overwritten, trust merged, forward compatibility, per-host switches.

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local K1 = "11111111111111111111111111111111"
local K2 = "22222222222222222222222222222222"

-- 1. A getter that returns nil at login (SavedVariables not loaded): no key is
--    chosen and nothing is sent, until it resolves.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local db = nil
    local inst = lib:New({ addon = "GlassChat", store = function() return db end })
    Peer.new({})
    login()
    WoW.advance(61)
    eq(lib.state.key, nil, "no key while a store getter answers nil")
    eq(#sentTo(3), 0, "  and no hello")
    db = {}
    inst.Rescan()
    check(type(db.key) == "string" and #db.key == 32, "the key is made once the store resolves")
    check(type(db.keyAt) == "number", "  stamped with when")
    eq(db.v, 1, "  and the store with its version")
    eq(#sentTo(3, "H1|"), 1, "  and the hello goes")
end

-- 1b. Two hosts, one store resolved and one not: still no key, because the
--     unresolved one may hold an older key that must win.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local late = nil
    newHost(lib, "GlassChat", {})
    lib:New({ addon = "AltStable", store = function() return late end })
    login()
    WoW.advance(61)
    Peer.new({})
    lib.byTag.GlassChat.Rescan()
    eq(lib.state.key, nil, "no key while any registered store is unresolved")
    late = { key = K2, keyAt = 5 }
    lib.byTag.GlassChat.Rescan()
    eq(lib.state.key, K2, "once it resolves, its older key wins")
end

-- 2. A later host's older key is not overwritten this session; next session
--    the oldest key wins everywhere it is missing, and nothing is overwritten.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local a, b = { key = K1, keyAt = 100 }, { key = K2, keyAt = 50 }
    newHost(lib, "GlassChat", a)
    login()
    WoW.advance(61)
    Peer.new({})
    lib.byTag.GlassChat.Rescan()
    eq(lib.state.key, K1, "the only store's key is ours")
    newHost(lib, "AltStable", b)   -- load-on-demand, with an older key
    eq(lib.state.key, K1, "a later host does not switch the key mid-session")
    eq(b.key, K2, "  and its own key is not overwritten")
    -- Next session, both registered before login.
    WoW.reset(); WoW.resetLibStub()
    lib = loadLibrary()
    newHost(lib, "GlassChat", a)
    newHost(lib, "AltStable", b)
    login()
    WoW.advance(61)
    Peer.new({})
    lib.byTag.GlassChat.Rescan()
    eq(lib.state.key, K2, "next session the oldest key wins")
    eq(a.key, K1, "  and a store's existing key is still never overwritten")
end

-- 2b. A host whose getter resolves after the key was chosen (it registered
--     while nil) gets the key on the next scan, with no send needed.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local a = { key = K1, keyAt = 10 }
    newHost(lib, "GlassChat", a)
    login()
    WoW.advance(61)
    Peer.new({})
    lib.byTag.GlassChat.Rescan()
    eq(lib.state.key, K1, "the key is chosen")
    local late = nil
    lib:New({ addon = "AltStable", store = function() return late end })
    late = {}
    lib.byTag.GlassChat.Rescan()
    eq(late.key, K1, "a store that resolves later gets the household key")
    eq(late.keyAt, 10, "  with its keyAt")
end

-- 3. A store with no key gets the frozen key, with its keyAt.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local a, b = { key = K1, keyAt = 100 }, {}
    newHost(lib, "GlassChat", a)
    newHost(lib, "AltStable", b)
    login()
    WoW.advance(61)
    Peer.new({})
    lib.byTag.GlassChat.Rescan()
    eq(b.key, K1, "a keyless store gets the household key")
    eq(b.keyAt, 100, "  with its keyAt, so the next merge agrees")
end

-- 4. Equal keyAt: the lowest key string wins.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    newHost(lib, "GlassChat", { key = K2, keyAt = 100 })
    newHost(lib, "AltStable", { key = K1, keyAt = 100 })
    login()
    WoW.advance(61)
    Peer.new({})
    lib.byTag.GlassChat.Rescan()
    eq(lib.state.key, K1, "a tie goes to the lowest key")
end

-- 5. Trust is a union across stores, written back, and capped at 16.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local a = { key = K1, keyAt = 1, trusted = { ["33333333333333333333333333333333"] = 10 } }
    local b = { trusted = { ["44444444444444444444444444444444"] = 20,
                            ["33333333333333333333333333333333"] = 30 } }
    newHost(lib, "GlassChat", a)
    newHost(lib, "AltStable", b)
    login()
    WoW.advance(61)
    Peer.new({})
    lib.byTag.GlassChat.Rescan()
    eq(a.trusted["44444444444444444444444444444444"], 20, "a key trusted in one store reaches the other")
    eq(a.trusted["33333333333333333333333333333333"], 30, "  with the newest lastSeen")
    for i = 1, 20 do b.trusted[("%032x"):format(1000 + i)] = 100 + i end
    lib.impl.SyncStores()
    local n = 0
    for _ in pairs(a.trusted) do n = n + 1 end
    eq(n, 16, "trust is capped at 16 keys")
    check(a.trusted[("%032x"):format(1020)] ~= nil, "  the most recently seen kept")
    check(a.trusted["44444444444444444444444444444444"] == nil, "  the least recently seen evicted")
end

-- 6. Our own key never counts as trusted, even if a store lists it later.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local a = { key = K1, keyAt = 1 }
    newHost(lib, "GlassChat", a)
    login()
    WoW.advance(61)
    Peer.new({})
    lib.byTag.GlassChat.Rescan()
    eq(lib.state.key, K1, "the store's key is ours")
    a.trusted = { [K1] = 5 }
    eq(lib.impl.KeyTrusted(K1), false, "our own key is not trusted")
    eq(lib.impl.TrustUnion()[K1], nil, "  nor in the trusted set")
end

-- 6b. A key a store trusts is another account's: never chosen as ours. After
--     a shared-key split, a read-only store still holding the old key must
--     not bring it back next session (the split would repeat forever).
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local writable = { key = K2, keyAt = 100, trusted = { [K1] = 10 } }
    local readonly = { v = 2, key = K1, keyAt = 50 }
    newHost(lib, "GlassChat", writable)
    newHost(lib, "AltStable", readonly)
    login()
    WoW.advance(61)
    Peer.new({})
    lib.byTag.GlassChat.Rescan()
    eq(lib.state.key, K2, "an older key we trust is not chosen as ours")
end

-- 6c. A verified account sends OUR key before our key is chosen (a store
--     still loading): it waits, then splits once the key is known.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local a, b = { key = OTHER_KEY, keyAt = 50 }, nil
    newHost(lib, "GlassChat", a)
    lib:New({ addon = "AltStable", store = function() return b end })
    login()
    WoW.advance(61)
    local B = Peer.new({})
    B:deliver(B:hello({ key = OTHER_KEY }))
    check(not (a.trusted and a.trusted[OTHER_KEY]), "our own key is not trusted while ours is undecided")
    b = {}
    lib.byTag.GlassChat.Rescan()
    check(a.key ~= OTHER_KEY and a.key == lib.state.key, "once decided, the shared key splits")
    eq(b.key, lib.state.key, "  and every store gets the new key")
end

-- 6d. Every store's key is another account's: a new key is made AND saved.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local a, b = { key = K1, keyAt = 1 }, { trusted = { [K1] = 5 } }
    newHost(lib, "GlassChat", a)
    newHost(lib, "AltStable", b)
    login()
    WoW.advance(61)
    Peer.new({})
    lib.byTag.GlassChat.Rescan()
    check(lib.state.key ~= K1, "a key we trust is not ours")
    eq(a.key, lib.state.key, "the new key replaces another account's key in the store")
    eq(b.key, lib.state.key, "  and is saved in the keyless store")
end

-- 7. Forward compatibility: unknown fields survive; a newer store is read-only.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local a = { key = K1, keyAt = 1, future = { x = 1 }, trusted = { notakey = "kept" } }
    local newer = { v = 2, key = K2, keyAt = 500, somethingNew = true }
    newHost(lib, "GlassChat", a)
    newHost(lib, "AltStable", newer)
    login()
    WoW.advance(61)
    local B = Peer.new({})
    lib.byTag.GlassChat.Rescan()
    B:deliver(B:hello({ key = OTHER_KEY }))
    eq(a.future and a.future.x, 1, "an unknown field is never deleted")
    eq(a.trusted.notakey, "kept", "  nor an entry we don't recognise")
    eq(newer.trusted, nil, "a store from a newer format is not written")
    eq(newer.key, K2, "  its key untouched")
    eq(newer.somethingNew, true, "  its fields untouched")
    eq(newer.v, 2, "  and its version kept")
end

-- 8. Switches are per host, and persist.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local a, b = {}, {}
    local A = newHost(lib, "GlassChat", a)
    local Bh = newHost(lib, "AltStable", b)
    A.SetEnabled(false)
    eq(a.enabled, false, "a host's switch is written to its own store")
    eq(A.IsEnabled(), false, "  and read back")
    eq(Bh.IsEnabled(), true, "  the other host is unaffected")
    WoW.reset(); WoW.resetLibStub()
    lib = loadLibrary()
    A = newHost(lib, "GlassChat", a)
    eq(A.IsEnabled(), false, "the switch holds next session")
end

-- 8b. A switch flipped this session wins over a read-only newer store.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local newer = { v = 2, enabled = true }
    local A = newHost(lib, "GlassChat", newer)
    A.SetEnabled(false)
    eq(A.IsEnabled(), false, "SetEnabled(false) holds even when the store can't be written")
    eq(newer.enabled, true, "  and the newer store is untouched")
    local older = { v = 2, enabled = false }
    local Bh = newHost(lib, "AltStable", older)
    Bh.SetEnabled(true)
    eq(Bh.IsEnabled(), true, "SetEnabled(true) holds over a newer store's false")
end

-- 9. Our game and region as last known come from the newest store.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    newHost(lib, "GlassChat", { selfProject = 18, selfRegion = 90, selfAt = 100 })
    newHost(lib, "AltStable", { selfProject = 18, selfRegion = 91, selfAt = 200 })
    local project, region = lib.impl.SavedSelf()
    eq(region, 91, "the newest selfAt wins")
end

-- 10. Every host disabled: nothing runs, session state is wiped.
do
    local lib, inst, store = session()
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    eq(#inst.Peers(), 1, "a peer while enabled")
    inst.SetEnabled(false)
    eq(#inst.Peers(), 0, "no peers once every host is off")
    WoW.sent = {}
    inst.Rescan()
    WoW.advance(120)
    eq(#WoW.sent, 0, "  and nothing is sent")
end

done("test_stores")
