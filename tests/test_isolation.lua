-- test_isolation.lua: two hosts on one library. Each has its own tag,
-- handler, switch, size cap and reports; ownership and peers are shared, as
-- the plan says (§2, §3).

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local function setup()
    WoW.reset(); WoW.resetLibStub()
    local lib = loadLibrary()
    local a, b = {}, {}
    local A = newHost(lib, "GlassChat", a)
    local Bh = newHost(lib, "AltStable", b, { maxPayload = 100 })
    login()
    WoW.advance(61)
    local P = Peer.new({})
    A.Rescan()
    P:deliver(P:hello({ key = P.key }))
    return lib, A, Bh, P, a, b
end

-- 1. Handlers and tags.
do
    local lib, A, Bh, P = setup()
    local abox, bbox = inbox(A), inbox(Bh)
    P:send("GlassChat", "to A", { sid = "1760000000001" })
    P:send("AltStable", "to B", { sid = "1760000000002" })
    eq(#abox, 1, "A gets only its tag")
    eq(#bbox, 1, "B gets only its tag")
    eq(abox[1].payload, "to A", "  A's message")
    eq(bbox[1].payload, "to B", "  B's message")
end

-- 2. One host off: the other still sends and receives.
do
    local lib, A, Bh, P, a = setup()
    local abox, bbox = inbox(A), inbox(Bh)
    A.SetEnabled(false)
    eq(A.IsEnabled(), false, "A is off")
    eq(Bh.IsEnabled(), true, "B is still on")
    P:send("GlassChat", "to A", { sid = "1760000000003" })
    P:send("AltStable", "to B", { sid = "1760000000004" })
    eq(#abox, 0, "A, off, receives nothing")
    eq(#bbox, 1, "B still receives")
    local _, why = A.Send("x")
    eq(why, "disabled", "A, off, sends nothing")
    WoW.sent = {}
    eq(Bh.Send("y"), 1, "B still sends")
end

-- 3. Size caps are per host.
do
    local lib, A, Bh = setup()
    local _, why = Bh.Send(string.rep("x", 101))
    eq(why, "too-large", "B's 100-byte cap refuses 101 bytes")
    check(A.Send(string.rep("x", 101)) == 1, "A's default cap takes them")
end

-- 4. A handler's error is reported to its own host only.
do
    local lib, A, Bh, P = setup()
    A.OnMessage(function() error("A broke") end)
    inbox(Bh)
    P:send("GlassChat", "x", { sid = "1760000000005" })
    local inA, inB = false, false
    for _, r in ipairs(reports.GlassChat) do if r.text:find("A broke") then inA = true end end
    for _, r in ipairs(reports.AltStable) do if r.text:find("A broke") then inB = true end end
    check(inA, "A's handler error goes to A's report")
    check(not inB, "  and not to B's")
end

-- 5. A's onResult sees only A's sends.
do
    local lib, A, Bh = setup()
    local aRes, bRes = {}, {}
    A.Send("a", function(s, status) aRes[#aRes + 1] = status end)
    Bh.Send("b", function(s, status) bRes[#bRes + 1] = status end)
    eq(#aRes, 1, "A's callback once")
    eq(#bRes, 1, "B's callback once")
end

done("test_isolation")
