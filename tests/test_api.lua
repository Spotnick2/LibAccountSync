-- test_api.lua: the contract a host sees (§1): New's checks, the instance
-- functions, what they return, Diagnostics.

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function errs(f, ...) local ok, e = pcall(f, ...) return not ok and tostring(e) or nil end
local store = function() return {} end

-- 1. New's checks.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    check(errs(lib.New, { addon = "X", store = store }), "a dot call is an error")
    check(errs(function() return lib:New() end), "no opts is an error")
    check(errs(function() return lib:New({ addon = "Glass-Chat", store = store }) end), "a tag with a symbol is an error")
    check(errs(function() return lib:New({ addon = string.rep("a", 17), store = store }) end), "a 17-character tag is an error")
    check(errs(function() return lib:New({ addon = "X", store = {} }) end), "a store that isn't a function is an error")
    check(errs(function() return lib:New({ addon = "X", store = store, report = "no" }) end), "a report that isn't a function is an error")
    for _, bad in ipairs({ 0, 32769, 1.5, "1" }) do
        check(errs(function() return lib:New({ addon = "X", store = store, maxPayload = bad }) end),
              "maxPayload " .. tostring(bad) .. " is an error")
    end
    local inst = lib:New({ addon = "GlassChat", store = store })
    check(errs(function() return lib:New({ addon = "GlassChat", store = store }) end), "a duplicate tag is an error")
    for _, name in ipairs({ "Send", "OnMessage", "Peers", "Rescan", "SetEnabled", "IsEnabled", "Diagnostics" }) do
        eq(type(inst[name]), "function", "the instance has " .. name)
    end
    eq(inst.maxPayload, 16384, "maxPayload defaults to 16384")
    check(errs(inst.OnMessage, "nope"), "OnMessage with a non-function is an error")
    check(not errs(inst.OnMessage, nil), "OnMessage(nil) clears the handler")
    eq(lib:New({ addon = "Big", store = store, maxPayload = 32768 }).maxPayload, 32768, "the wire ceiling is allowed")
end

-- 2. A host loaded after login (load-on-demand) still starts.
do
    WoW.reset(); WoW.resetLibStub()
    WoW.loggedIn = true
    local lib = loadLibrary()
    local db = {}
    local inst = newHost(lib, "GlassChat", db)
    Peer.new({})
    WoW.advance(6)
    eq(#sentTo(3, "H1|"), 1, "a host created after login scans without PLAYER_LOGIN")
end

-- 3. Peers returns copies; Send refuses a non-string.
do
    local lib, inst = session()
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    local p = inst.Peers()[1]
    eq(p.name, "Karuzo", "Peers lists the peer")
    eq(p.proven, "bnet", "  with how it was proven")
    eq(p.id, nil, "  and no session handle")
    p.name = "Changed"
    eq(inst.Peers()[1].name, "Karuzo", "a host can't change a peer through the copy")
    check(errs(inst.Send, 42), "Send with a non-string is an error")
end

-- 4. Diagnostics: the state and each id, never a key.
do
    local lib, inst, st = session()
    local B = Peer.new({})
    Peer.new({ id = 9, name = "Friend", guid = "Player-1-0000000F", bnet = 77 })
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    local text = {}
    for line in inst.Diagnostics() do text[#text + 1] = line end
    text = table.concat(text, "\n")
    check(text:find("Karuzo %(bnet%)") ~= nil, "Diagnostics shows the peer and how it is proven")
    check(text:find("someone else's Battle.net account") ~= nil, "  and why the friend is not ours")
    check(not text:find(st.key, 1, true), "  and never our key")
    check(not text:find(OTHER_KEY, 1, true), "  nor a trusted one")
end

-- 5. The reason strings are the frozen enum.
do
    local lib = session()
    local want = { "disabled", "no-peers", "too-large", "not-ready", "offline", "no-route" }
    local n = 0
    for _ in pairs(lib.REASONS) do n = n + 1 end
    eq(n, #want, "six reasons")
    for _, r in ipairs(want) do check(lib.REASONS[r], "reason " .. r) end
end

-- 6. The prefix is registered once, the events once.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    check(WoW.prefixes[PREFIX], "the prefix is registered")
    for _, e in ipairs({ "PLAYER_LOGIN", "BN_CHAT_MSG_ADDON", "BN_CONNECTED", "BN_DISCONNECTED", "BN_INFO_CHANGED" }) do
        check(lib.frame:IsEventRegistered(e), e .. " is registered")
    end
end

-- 7. Unknown frame types and a hello's extra trailing fields are ignored.
--    A blank peer, so only its hello can make it a peer.
do
    local store = { key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", keyAt = 1, trusted = { [OTHER_KEY] = 1 },
                    selfProject = 18, selfRegion = 90, selfAt = 1 }
    local lib, inst = session(store)
    local B = Peer.new({ blank = true })
    inst.Rescan()
    local ok = pcall(B.deliver, B, "Z1|whatever|comes|next")
    check(ok, "an unknown frame type is ignored")
    eq(#inst.Peers(), 0, "no peer before its hello")
    B:deliver(B:hello() .. "|a-future-field|another")
    eq(#inst.Peers(), 1, "a hello with extra trailing fields is still read")
end

done("test_api")
