-- test_upgrade.lua: upgrading in place (§4, EMBEDDED-LIBRARIES §5 and §8).
-- Three kinds of older/newer copy:
-- - a SYNTHETIC newer copy (this source with MINOR+1, a new function, and every
--   lib.impl function wrapped in a call counter) over the current one (2, 4);
-- - the pilot copy cc92deb (MINOR 1, never released) under the current one (4c);
-- - each RELEASED copy, frozen in tests/fixtures/LibAccountSync-rN.lua with a
--   manifest of every file it shipped, under the current one (4d). A new
--   release adds its fixture and manifest to RELEASED below.

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local MAJOR = "LibAccountSync-1.0"
local MINOR = currentMinor()

local NEWER = synthetic(MINOR + 1, [[
lib.impl.Probe = function() return "newer" end
LIBACCT_MARK = {}
for name, f in pairs(lib.impl) do
    if type(f) == "function" then
        lib.impl[name] = function(...)
            LIBACCT_MARK[name] = (LIBACCT_MARK[name] or 0) + 1
            return f(...)
        end
    end
end]])

local function verified()
    local lib, inst, store = session()
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    return lib, inst, store, B
end

-- 1. An equal copy loading second changes nothing.
do
    local lib, inst, store, B = verified()
    local impl, state, frame, ticker = lib.impl, lib.state, lib.frame, lib.ticker
    local send, implSend = inst.Send, lib.impl.Send
    local frames = #WoW.frames
    loadLibrary("AltStable")
    eq(LibStub(MAJOR), lib, "equal-after-equal keeps the library table")
    eq(lib.impl, impl, "  and lib.impl")
    eq(lib.impl.Send, implSend, "  and its functions")
    eq(inst.Send, send, "  and the instance's")
    eq(lib.state, state, "  and the state")
    eq(lib.frame, frame, "  and the frame")
    eq(lib.ticker, ticker, "  and the ticker")
    eq(#WoW.frames, frames, "  and makes no new frame")
    eq(#lib.instances, 1, "  and no instance added or lost")
end

-- 2. A newer copy over the current one: everything the old copy installed
--    runs the new code, and nothing live is lost.
do
    local lib, inst, store, B = verified()
    local state, peers, frame, ticker = lib.state, lib.state.peers, lib.frame, lib.ticker
    local send = inst.Send
    local box = inbox(inst)
    -- Queued by the old copy before the upgrade: a CTL callback and a timer.
    WoW.ctlDefer = true
    inst.Send("queued before the upgrade")
    lib.state.answered = nil            -- a state table this copy "doesn't know yet"
    local frames = #WoW.frames
    loadCopy(NEWER, "AltStable")
    eq(LibStub(MAJOR), lib, "the newer copy fills the same table")
    eq(select(2, LibStub:GetLibrary(MAJOR)), MINOR + 1, "  at the newer MINOR")
    eq(lib.ready, MINOR + 1, "  and marks itself complete")
    eq(lib.state, state, "the state keeps its identity")
    eq(lib.state.peers, peers, "  and the peers table")
    eq(#inst.Peers(), 1, "  and the live peer")
    check(type(lib.state.answered) == "table", "a missing state table is filled")
    eq(lib.frame, frame, "the frame is reused")
    eq(lib.ticker, ticker, "the ticker is reused")
    eq(#WoW.frames, frames, "  no frame added")
    eq(inst.Send, send, "the instance keeps its functions")
    eq(lib.impl.Probe(), "newer", "the new function is there")

    LIBACCT_MARK = {}
    inst.Peers()
    eq(LIBACCT_MARK.Peers, 1, "an old instance's function runs the new code, once")
    LIBACCT_MARK = {}
    WoW.ctlDrain()
    check((LIBACCT_MARK.OnChunkSent or 0) >= 1, "a CTL callback the old copy queued runs the new code")
    LIBACCT_MARK = {}
    B:deliver(B:hello({ key = B.key, nonce = "5555555555555555" }))
    eq(LIBACCT_MARK.OnEvent, 1, "the old frame's script runs the new OnEvent, once")
    LIBACCT_MARK = {}
    WoW.advance(60)
    check((LIBACCT_MARK.Tick or 0) >= 1, "the old ticker runs the new Tick")
    B:send("GlassChat", "after the upgrade", { sid = "1760000000099" })
    eq(box[#box] and box[#box].payload, "after the upgrade", "messages still arrive at the old host's handler")
    local inst2 = newHost(lib, "AltStable", {})
    check(inst2.Send ~= nil, "a host after the upgrade gets an instance")
end

-- 3. An older copy loading after a newer one does nothing.
do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadCopy(NEWER, "AltStable")
    local impl = {}
    for k, v in pairs(lib.impl) do impl[k] = v end
    loadLibrary("GlassChat")
    eq(lib.ready, MINOR + 1, "an older copy after a newer one leaves the marker")
    local same = true
    for k, v in pairs(lib.impl) do if impl[k] ~= v then same = false end end
    check(same, "  and every function")
end

-- 4. A newer copy that throws partway: the library goes inert everywhere,
--    and New still answers (with an inert instance) instead of throwing.
do
    local lib, inst, store, B = verified()
    local box = inbox(inst)
    local BROKEN = synthetic(MINOR + 1, [[error("a newer copy broke while loading")]])
    local ok = pcall(loadCopy, BROKEN, "AltStable")
    check(not ok, "the broken copy throws")
    eq(select(2, LibStub:GetLibrary(MAJOR)), MINOR + 1, "LibStub has already counted its MINOR")
    eq(lib.ready, MINOR, "but the marker is the old one")
    local n, why = inst.Send("x")
    eq(why, "not-ready", "an existing instance answers not-ready")
    local inertNoted = 0
    for _, r in ipairs(reports.GlassChat) do if r.text:find("did not finish loading") then inertNoted = inertNoted + 1 end end
    eq(inertNoted, 1, "  and says so once")
    inst.Send("x")
    local okNew, late = pcall(lib.New, lib, { addon = "Late", store = function() return {} end })
    check(okNew, "New does not throw on a half-loaded library")
    local _, lateWhy = late.Send("x")
    eq(lateWhy, "not-ready", "  it hands out an inert instance")
    eq(lib.byTag.Late, nil, "  which is not registered")
    eq(type(inst.Peers()), "table", "an inert Peers is still a table")
    local okIter = pcall(function() for _ in inst.Diagnostics() do end end)
    check(okIter, "  and an inert Diagnostics still an iterator")
    eq(type(late.Peers()), "table", "  for an inert New's instance too")
    eq(#lib.instances, 1, "  nor counted among the instances")
    local sent = #WoW.sent
    B:send("GlassChat", "while inert", { sid = "1760000000098" })
    eq(#box, 0, "events are gated: nothing is delivered")
    WoW.advance(120)
    eq(#WoW.sent, sent, "  and the ticker sends nothing")
end

-- 4b. A scan timer that fires while the library is not ready doesn't leave
--     its pending flag set (rescans would stay off once it is ready again).
do
    local lib, inst = session()
    lib.impl.RequestScan()
    local ready = lib.ready
    lib.ready = ready - 1                    -- a half-loaded moment
    WoW.advance(3)
    lib.ready = ready
    eq(lib.state.scanPending, false, "the pending flag is cleared")
end

-- 4c. The copy GlassChat's pilot embeds (cc92deb, MINOR 1, frozen in
--     tests/fixtures/) loads FIRST, and a host makes its instance from it.
--     The fixed copy loading second must win, and the old instance must run
--     the fix: our hello carries the whole name, and an older peer's
--     first-name hello is matched by GUID (#4; Codex on PR #5).
do
    WoW.reset(); WoW.resetLibStub()
    WoW.player.surname = "Belgarden"
    local lib = loadCopy(fixtureCopy("LibAccountSync-cc92deb.lua"), "GlassChat")
    eq(select(2, LibStub:GetLibrary(MAJOR)), 1, "the pilot copy loads first, at MINOR 1")
    local inst = newHost(lib, "GlassChat", {})
    login()
    WoW.advance(61)
    loadLibrary("LibAccountSyncProbe")
    eq(select(2, LibStub:GetLibrary(MAJOR)), MINOR, "the fixed copy wins")
    eq(lib.ready, MINOR, "  and is complete")
    local B = Peer.new({ name = "Karuzo Test" })
    inst.Rescan()
    eq(B:ourHello() and B:ourHello().name, "Malas Belgarden", "the pilot's instance sends our whole name")
    B:deliver(B:hello({ key = B.key, name = "Karuzo" }))
    eq(lib.state.theirNonce[3], B.nonce, "  and matches an older peer's first-name hello by GUID")
end

-- 4d. Released copies (EMBEDDED-LIBRARIES §8, §9.4).
local RELEASED = { 2 }                      -- every tagged rN, oldest first

-- (a) A released MINOR is frozen: if a manifest exists for the current MINOR,
--     every file the release shipped must still hash the same. A behaviour
--     change raises MINOR first (CLAUDE.md, EMBEDDED-LIBRARIES §4).
local function manifestOf(minor)
    local f = io.open("tests/fixtures/LibAccountSync-r" .. minor .. ".manifest", "rb")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local m = {}
    for hash, path in text:gmatch("(%x+)  ([^\r\n]+)") do m[#m + 1] = { hash = hash, path = path } end
    return m
end
local function drift(manifest, read)
    local T = LibStub("LibAccountSync-1.0")._test
    local out = {}
    for _, e in ipairs(manifest) do
        if T.SHA256(read(e.path)) ~= e.hash then out[#out + 1] = e.path end
    end
    return out
end
do
    WoW.reset(); WoW.resetLibStub()
    loadLibrary()
    local m = manifestOf(MINOR)
    local function current(path)
        if path == "LibAccountSync.lua" then return runtimeSource() end
        return (readFile(path):gsub("\r\n", "\n"))
    end
    if m then
        check(#m >= 5, "the r" .. MINOR .. " manifest lists every shipped file")
        -- Under tests/mutate.lua every mutant differs from the release, which
        -- would turn each one red here and hide the mutations nothing else
        -- catches; the guard itself is exercised just below instead.
        if not os.getenv("LIBACCT_MUTANT") then
            local changed = drift(m, current)
            eq(#changed, 0, "MINOR " .. MINOR .. " is the released r" .. MINOR .. ": changed " .. table.concat(changed, ", ")
               .. " (raise MINOR to change a release)")
        end
        -- The guard catches a change in the runtime and in a bundled file.
        local function edited(target)
            return function(path)
                local s = current(path)
                if path == target then s = s .. "\n-- edited" end
                return s
            end
        end
        eq(drift(m, edited("LibAccountSync.lua"))[1], "LibAccountSync.lua", "the guard sees a runtime edit")
        eq(drift(m, edited("ChatThrottleLib/ChatThrottleLib.lua"))[1], "ChatThrottleLib/ChatThrottleLib.lua",
           "  and an edit to a bundled file")
    end
end

-- (b) Every released copy loads FIRST, a host makes its instance from it, and
--     the current copy loads over it: an equal copy changes nothing, a newer
--     one must take over the old instance, and either way the instance pairs
--     and syncs.
for _, r in ipairs(RELEASED) do
    WoW.reset(); WoW.resetLibStub()
    local lib = loadCopy(fixtureCopy("LibAccountSync-r" .. r .. ".lua"), "GlassChat")
    eq(select(2, LibStub:GetLibrary(MAJOR)), r, "r" .. r .. " loads first, at MINOR " .. r)
    local impl = {}
    for k, v in pairs(lib.impl) do impl[k] = v end
    local store = {}
    local inst = newHost(lib, "GlassChat", store)
    login()
    WoW.advance(61)
    loadLibrary("LibAccountSyncProbe")
    eq(select(2, LibStub:GetLibrary(MAJOR)), math.max(r, MINOR), "  the newer of r" .. r .. " and the current copy wins")
    eq(lib.ready, math.max(r, MINOR), "  complete")
    if r == MINOR then
        local same = true
        for k, v in pairs(lib.impl) do if impl[k] ~= v then same = false end end
        check(same, "  an equal current copy changes nothing")
    end
    local box = inbox(inst)
    local B = Peer.new({})
    inst.Rescan()
    B:deliver(B:hello({ key = B.key }))
    eq(inst.Peers()[1] and inst.Peers()[1].proven, "bnet", "  r" .. r .. "'s instance pairs")
    B:send("GlassChat", "after loading over r" .. r)
    eq(box[1] and box[1].payload, "after loading over r" .. r, "  and receives")
    WoW.sent = {}
    eq(inst.Send("x"), 1, "  and sends")
end

-- 5. The completion marker is the last line, and MINOR is written once.
do
    local src = runtimeSource()
    check(src:find("\nlib%.ready = MINOR%s*$") ~= nil, "lib.ready = MINOR is the last line")
    local _, count = src:gsub('"LibAccountSync%-1%.0", %d+', "")
    eq(count, 1, "the MINOR literal appears once")
end

done("test_upgrade")
