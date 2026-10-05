-- test_secrets.lua: a secret Battle.net value fails closed and never throws
-- (§5.2, CLAUDE.md: every client value that can be a secret is checked with
-- issecretvalue before any use).
--
-- Lua 5.1 cannot make == or a truth test throw on a newproxy secret, so the
-- stubs alone can't catch a comparison on a raw field. The grep at the end
-- enforces the structure instead: raw Battle.net values are read only by the
-- readers, which copy plain fields and mark a record holding a secret
-- "unknown".

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

-- 1. A secret in the other account's record: not ours, no hint, no throw.
for _, field in ipairs({ "characterName", "playerGuid", "isOnline", "wowProjectID", "regionID",
                         "clientProgram", "isInCurrentRegion" }) do
    local lib, inst = session()
    WoW.bn.secret = { [field] = true }
    Peer.new({})
    Peer.new({ id = 4, name = "Blank", guid = "Player-1-00000004", blank = true })
    local ok, err = pcall(inst.Rescan)
    check(ok, "a secret " .. field .. " does not throw (" .. tostring(err) .. ")")
    eq(#inst.Peers(), 0, "  a secret " .. field .. ": no peer")
    eq(#sentTo(3) + #sentTo(4), 0, "  a secret " .. field .. ": nothing sent, not even a hint's hello")
end

-- 2. A secret name on a blank-looking record must not read as "blank": the
--    elimination hint must not fire on it.
do
    local lib, inst = session()
    local B = Peer.new({ blank = true })
    WoW.bn.secret = { characterName = true }
    inst.Rescan()
    eq(#sentTo(3), 0, "a secret name is unknown, never blank")
end

-- 3. A secret BattleTag on the account record: not ours.
do
    local lib, inst = session()
    WoW.bn.secret = { battleTag = true }
    Peer.new({})
    local ok = pcall(inst.Rescan)
    check(ok, "a secret BattleTag does not throw")
    eq(#inst.Peers(), 0, "  and makes nobody ours")
end

-- 4. Our own BattleTag secret while our presence is blank: we don't know who
--    we are, so nothing is sent.
do
    local store = { selfProject = 18, selfRegion = 90, selfAt = 1 }
    local lib, inst = session(store, { before = function() WoW.bn.blank = true; WoW.bn.secretSelfTag = true end })
    WoW.bn.me = nil
    Peer.new({})
    local ok = pcall(inst.Rescan)
    check(ok, "a secret own BattleTag does not throw")
    eq(#sentTo(3), 0, "  and nothing is sent")
end

-- 5. A secret in a friend's record makes the friends list unknown: no hint.
do
    local lib, inst = session()
    WoW.bn.friends = { { 9 } }
    Peer.new({ id = 9, name = "Friend", guid = "Player-1-0000000F", bnet = 77 })
    local B = Peer.new({ blank = true })
    WoW.bn.secret = { gameAccountID = true }
    eq(lib.impl.FriendGameIDs(), nil, "a secret in a friend's record: the friends list is unknown")
end

-- 6. A secret message or sender id is ignored.
do
    local lib, inst = session()
    local ok = pcall(WoW.fire, "BN_CHAT_MSG_ADDON", PREFIX, WoW.Secret("text"), "WHISPER", 3)
    check(ok, "a secret message text is ignored without a throw")
    ok = pcall(WoW.fire, "BN_CHAT_MSG_ADDON", PREFIX, "H1|1|x", "WHISPER", WoW.Secret("id"))
    check(ok, "a secret sender id is ignored without a throw")
end

-- 7. The structure: raw Battle.net values only in the readers.
do
    local src = runtimeSource()
    local readers = { Copy = true, GameRec = true, GameRecByGuid = true, AcctRec = true, FriendGameIDs = true }
    local current
    local stray, rawStray, unchecked = {}, {}, {}
    local n = 0
    local lines = {}
    for line in (src .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
    for i, line in ipairs(lines) do
        local name = line:match("^function I%.([%w_]+)") or line:match("^local function ([%w_]+)")
            or line:match("^function ([%w_:]+)")
        if name then current = name elseif line:match("^end") then current = nil end
        local code = line:gsub("%-%-.*$", "")
        -- A Battle.net call (not a mere existence check) outside a reader.
        if code:find("pcall%(C_BattleNet%.") and not readers[current] then
            stray[#stray + 1] = i .. " (" .. tostring(current) .. ")"
        end
        if code:find("%f[%w_]raw%f[^%w_]") and not readers[current] then
            rawStray[#rawStray + 1] = i .. " (" .. tostring(current) .. ")"
        end
        -- The BN* calls that return plain values: tested with IsSecret on
        -- the same line or the next.
        if code:find("pcall%(BNGetInfo") or code:find("pcall%(BNGetNumFriends")
            or code:find("pcall%(C_BattleNet%.GetFriendNumGameAccounts") then
            n = n + 1
            local nxt = (lines[i + 1] or ""):gsub("%-%-.*$", "")
            if not (code:find("IsSecret") or nxt:find("IsSecret")) then unchecked[#unchecked + 1] = i end
        end
    end
    eq(#stray, 0, "every C_BattleNet call is inside a reader: " .. table.concat(stray, ", "))
    eq(#rawStray, 0, "raw records stay inside the readers: " .. table.concat(rawStray, ", "))
    eq(n, 3, "the three plain-value BN calls are found")
    eq(#unchecked, 0, "each is tested with IsSecret: " .. table.concat(unchecked, ", "))
    check(src:find("issecretvalue%(v%) == true") ~= nil, "IsSecret asks issecretvalue")
    check(src:find("if IsSecret%(prefix%) or IsSecret%(text%) or IsSecret%(senderID%) or prefix ~= PREFIX") ~= nil,
          "the event's arguments are secret-checked before the prefix is compared")
end

done("test_secrets")
