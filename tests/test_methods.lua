-- test_methods.lua: every widget method the library calls exists on the
-- client for that widget type, in the build tests/kit.pin names (WowTestKit's
-- Kit.checkMethods). The library's one frame is exercised as widely as is
-- cheap: load, login, a handshake, a send each way, switched off and on, and
-- a newer copy loaded over it (the frame is kept, its handlers replaced).
dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local lib, inst = session({})
WoW.fireAllRegistered()
local B = Peer.new({})
inst.Rescan()
WoW.advance(3)
B:deliver(B:hello({ key = B.key }))
inst.Send("methods", function() end)
B:send("GlassChat", "from B", { sid = "1760000000500" })
WoW.advance(12)
inst.SetEnabled(false)
inst.SetEnabled(true)
WoW.advance(70)
loadCopy(synthetic(currentMinor() + 1), "AltStable")
WoW.fireAllRegistered()
WoW.advance(5)

local recorded = Kit.checkMethods()
check(recorded >= 2, "the exercise reached the library's frame (" .. recorded .. " recorded)")

done("test_methods")
