-- mutate.lua: mutation-test the suite (CLAUDE.md: mutation-test new tests;
-- EMBEDDED-LIBRARIES §8). Each mutation breaks one rule in a copy of
-- LibAccountSync.lua; the suite must then go red. A mutation the suite
-- survives is a rule no test enforces.
--
-- Not a test_*.lua file, so CI doesn't run it. From the repo root:
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\mutate.lua [filter]

local LUA = arg[-1]
local filter = arg[1]

local function read(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return (s:gsub("\r\n", "\n"))
end

-- { name, { { from, to }, ... } }: plain-text substitutions, each matching once.
local M = {
    -- Ownership fails closed (§5.1, §5.2)
    { "friends list: no settle wait", { { "if (time() - S.upSince) < FRIENDS_SETTLE then return nil end", "" } } },
    { "friends list: a gap is skipped", {
        { 'if not gi or gi.unknown or type(gi.gameAccountID) ~= "number" then return nil end',
          'if not gi or gi.unknown or type(gi.gameAccountID) ~= "number" then break end' } } },
    { "elimination ignores friends", { { "if not friends or friends[id] then return false end",
                                         "if not friends then return false end" } } },
    { "elimination trusts an unknown record", {
        { "if not g or g.unknown or g.isOnline == false then return false end",
          "if not g or g.isOnline == false then return false end" } } },
    { "region: no fallback check", { { 'elseif g.isInCurrentRegion ~= true then', 'elseif false then' } } },
    { "region: mismatch passes", { { 'if g.regionID ~= me.region then return nil, "another region" end', '' } } },
    { "the key goes to any id", { { 'local key = I.OwnAccountGame(id, me) and K or ""', 'local key = K' } } },
    { "a key or proof is believed from any id", { { "elseif hinted or S.myNonce[id] then", "elseif true then" } } },
    { "anyone's nonce is kept", { { "if fresh and (g or hinted or S.learned[id]) then", "if fresh then" } } },
    { "our own name is accepted", { { "if Short(name) == Short(PlayerName()) then return end", "" } } },
    { "a reflected nonce is accepted", { { "if nonce == S.myNonce[id] then return end                     -- reflection", "" } } },
    { "a hello to every peer every scan", { { "if not known[id] or not S.theirNonce[id] then I.SendHello(id) end",
                                              "I.SendHello(id)" } } },
    { "a stranger's frames are remembered", { { "if not p and not S.myNonce[id] then return end",
                                                "if not p and not S.myNonce[id] then S.refused[key] = time(); return end" } } },
    { "a reloaded learned peer is not answered", {
        { "if hinted or S.learned[id] then I.SendHello(id, \"answer\") end",
          "if hinted then I.SendHello(id, \"answer\") end" } } },
    { "proof checks unbounded", { { "IsGuid(guid)\n            and I.ProofBudget(id) then", "IsGuid(guid) then" } } },
    { "a former hint keeps its nonce", {
        { '(not rec.unknown and type(rec.characterName) == "string" and rec.characterName ~= "")', 'false' } } },
    { "a trusted key can be chosen as ours", { { ' and not trusted[k] then', ' then' } } },
    { "a waiting stream is not rechecked on settle", {
        { "        if I.TryDeliver(key, buf) then return end          -- Battle.net may vouch for it now\n", "" } } },
    { "an inert Peers answers nil", { { 'if name == "Peers" then return {} end', '' } } },
    { "a failed MAC is refused, not waited on", { { "        if not sender then return false end",
        "        if not sender then S.buffers[key], S.refused[key] = nil, time(); return true end" } } },
    { "a key before ours is chosen is trusted", { { "            if not own then\n", "            if false then\n" } } },
    { "an answer counts before it is sent", { { "    if S.answered[id] then S.answered[id].nonce = nil end\n", "" } } },
    { "a hint loses its nonce while the list fails closed", {
        { "            if not rec or rec.isOnline == false\n", "            if true or rec.isOnline == false\n" } } },
    { "the newest stream is refused at the cap", { { "            if oldSid and oldSid < tonumber(sid) then", "            if false then" } } },
    { "chunks keep going after a failure", { { "            if track.done and i < n then break end      -- failed: the rest would go nowhere\n", "" } } },
    { "a scan flag stays set when not ready", {
        { "        S.scanPending = false\n        if not Ready() then return end", "        if not Ready() then return end\n        S.scanPending = false" } } },
    { "the prefix result is ignored", { { "(r == nil or r == true or r == 0)", "true" } } },
    { "a trusted store key is never replaced", { { " or (t.key ~= S.key and union[t.key])", "" } } },
    { "the prefix compared before the secret check", {
        { "if IsSecret(prefix) or IsSecret(text) or IsSecret(senderID) or prefix ~= PREFIX then",
          "if prefix ~= PREFIX or IsSecret(text) or IsSecret(senderID) then" } } },
    { "a changed character's stream is delivered as the new one", {
        { "    if was and was.proven == \"bnet\" and (not now or now.guid == was.guid) then",
          "    if now and now.proven == \"bnet\" then" } } },
    { "a stale hello's nonce is kept", {
        { "    if g and guid ~= g.playerGuid then return end\n", "" } } },
    { "a late store is not synced", { { "    if I.OwnKey() then I.SyncStores() end", "    I.OwnKey()" } } },
    { "the store's switch wins over the session's", { { "    if inst.enabled ~= nil then return inst.enabled end\n", "" } } },
    { "a proven peer passes without a MAC", {
        { "    elseif now and S.myNonce[id] and buf.mac then",
          "    elseif now then\n        sender = now\n    elseif now and S.myNonce[id] and buf.mac then" } } },
    { "a verified sender passes whatever its prior character", {
        { 'elseif now and now.proven == "bnet" and buf.prior == now.guid then',
          'elseif now and now.proven == "bnet" then' } } },
    { "a binding authenticated by data is not recorded", {
        { "        S.learned[id] = nil      -- Battle.net speaks for this id now\n        I.NoteBinding(id, g.playerGuid)\n",
          "        S.learned[id] = nil      -- Battle.net speaks for this id now\n" } } },
    { "a pending unbound stream keeps no identity", {
        { "        if b.id == id and b.prior == nil then b.prior = guid end", "" } } },
    { "a known sender gone blank counts as first contact", {
        { "                prior = (p and p.guid) or S.lastGuid[id] }", "                prior = p and p.guid }" } } },
    { "our hello carries only the first name", {
        { '    if not IsSecret(second) and type(second) == "string" and second ~= "" then\n        return name .. " " .. second\n    end\n', '' } } },
    { "a verified hello matched by name", {
        { "    if g and guid ~= g.playerGuid then return end",
          "    if g and Short(g.characterName) ~= Short(name) then return end" } } },
    { "a verified hello with no GUID passes", {
        { "    if g and guid ~= g.playerGuid then return end", "    if g and guid ~= \"\" and guid ~= g.playerGuid then return end" } } },
    { "the proof name is cut at a hyphen", {
        { "    return name:lower()\n", "    local s = name:match(\"^([^%-]+)\")\n    return s and s:lower() or nil\n" } } },
    { "a whole first return is glued to the second", { { '    if name:find(" ", 1, true) then return name end\n', '' } } },
    { "a secret surname is concatenated", {
        { '    if not IsSecret(second) and type(second) == "string" and second ~= "" then',
          '    if second ~= nil and second ~= "" then' } } },
    { "MINOR not raised over the pilot copy", {
        { 'local MAJOR, MINOR = "LibAccountSync-1.0", 4', 'local MAJOR, MINOR = "LibAccountSync-1.0", 1' } } },
    -- (No "MINOR left at 2" mutation: that is what test_upgrade 4d's freeze
    -- guard catches in a normal run, since r2's manifest no longer matches,
    -- and that guard is off here because every mutant differs from r2.)
    { "the bit path skips the operand check", { { "            if okA and same then", "            if true then" } } },
    { "the bit path skips the digest check", {
        { "                if ok1 and ok2\n", "                if true or ok1 and ok2\n" } } },
    { "a refused bit path is not undone", { { "                    bxor, band = slowXor, slowAnd\n", "" } } },
    { "the stored values are not the fallback", { { "        s.project, s.region = I.SavedSelf()\n        if s.project", "        s.project, s.region = nil, nil\n        if s.project" } } },
    { "the client's constants are never used", { { "        if s.project == nil then s.project, s.region = I.ClientSelf() end\n", "" } } },
    { "the client's constants win over the stored values", {
        { "        s.project, s.region = I.SavedSelf()\n        if s.project == nil then s.project, s.region = I.ClientSelf() end",
          "        s.project, s.region = I.ClientSelf()\n        if s.project == nil then s.project, s.region = I.SavedSelf() end" } } },
    { "a project of 0 is used", { { '    if IsSecret(p) or type(p) ~= "number" or p <= 0 then return nil, nil end', '    if IsSecret(p) or type(p) ~= "number" then return nil, nil end' } } },
    { "a non-number project is used", { { '    if IsSecret(p) or type(p) ~= "number" or p <= 0 then return nil, nil end', '    if IsSecret(p) then return nil, nil end' } } },
    { "a region of 0 is used", { { '    if IsSecret(r) or type(r) ~= "number" or r <= 0 then return nil, nil end', '    if IsSecret(r) or type(r) ~= "number" then return nil, nil end' } } },
    -- (No mutation for IsSecret on the client constants, project or region: a newproxy secret has
    -- type "userdata", so the type check after it hides the difference under
    -- the stubs. In the client a secret keeps its type, hence the check.)
    -- Our own key never counts as trusted (§3)
    { "TrustUnion keeps our own key", { { 'and type(seen) == "number" and k ~= S.key then',
                                          'and type(seen) == "number" then' } } },
    { "no shared-key split", { { "if not mine or not theirGuid or mine >= theirGuid then return end",
                                 "if true then return end" } } },
    -- The proof and the MAC (§5.1, §5.3)
    { "proof without project and region", {
        { '.. "|" .. guid .. "|" .. realm .. "|" .. tostring(project) .. "|" .. tostring(region)):sub(1, 32)',
          '.. "|" .. guid .. "|" .. realm):sub(1, 32)' } } },
    { "MAC without the sender GUID", {
        { 'DATA_DOMAIN .. receiverNonce .. "|" .. senderGuid .. "|" .. tostring(project)',
          'DATA_DOMAIN .. receiverNonce .. "|" .. tostring(project)' } } },
    { "the MAC is not checked", { { "buf.tag, buf.sidText, buf.n, hash) == buf.mac then",
                                    "buf.tag, buf.sidText, buf.n, hash) ~= nil then" } } },
    { "a complete stream is not kept for its hello", {
        { "buf.awaitUntil = time() + AWAIT_HELLO\n        I.ArmSettle(key, buf)", "S.buffers[key] = nil" } } },
    { "no recheck when a hello lands", { { "    I.SendHello(id, \"answer\")\n    I.RecheckAwaiting(id)",
                                           "    I.SendHello(id, \"answer\")" } } },
    -- Stream ids (§5.2)
    { "the sid floor keyed by id", { { 'local floorKey = buf.tag .. "|" .. tostring(sender.guid)',
                                       'local floorKey = buf.tag .. "|" .. tostring(buf.id)' } } },
    { "no sid floor", { { "if S.floors[floorKey] and buf.sid <= S.floors[floorKey] then return true end", "" } } },
    { "lastSid not read back from the store", {
        { 'if type(t.lastSid) == "number" and t.lastSid > lastSid and t.lastSid < 1e13 then lastSid = t.lastSid end', "" } } },
    -- Framing and caps (§2, §5.2)
    { "the data body is split on |", { { '|([^|]*)|([^|]*)|(.*)$")', '|([^|]*)|([^|]*)|([^|]*)")' } } },
    { "no chunk cap", { { "if i < 1 or i > n or n > MAX_CHUNKS then return end", "if i < 1 or i > n then return end" } } },
    { "no per-sender stream cap", { { "if perId >= STREAMS_PER_ID or total >= STREAMS_TOTAL then",
                                      "if total >= STREAMS_TOTAL then" } } },
    { "no maxPayload on receive", { { "if not payload or #payload > inst.maxPayload then", "if not payload then" } } },
    { "an idle stream never settles", { { "local wait = buf.complete and AWAIT_HELLO or STREAM_SETTLE",
                                          "local wait = buf.complete and AWAIT_HELLO or 100000" } } },
    { "send without their nonce", { { "            if S.theirNonce[id] then\n                dests",
                                      "            if true then\n                dests" } } },
    -- SendTo (#14)
    { "a target is a broadcast", { { "if p.guid == target then bound", "if true then bound" } } },
    { "a target gets every id bound to its GUID", { { "if pick then return { pick } end", "if pick then return routed end" } } },
    { "a target's first id is picked without a nonce", { { "if not pick and S.theirNonce[id] then pick = id end",
                                                           "if not pick then pick = id end" } } },
    { "a target's other ids get no hello", { { '    for k = 2, #routed do I.SendHello(routed[k], "soon") end\n', "" } } },
    { "a target without a nonce is no-peers", { { "    return { routed[1] }\n", "    return {}\n" } } },
    { "Send forwards a target", { { "function I.Send(inst, payload, onResult)\n    return I.SendFrames(inst, payload, onResult, nil)",
                                    "function I.Send(inst, payload, onResult, t)\n    return I.SendFrames(inst, payload, onResult, t)" } } },
    { "SendTo takes any target", { { 'if not IsGuid(guid) then error("LibAccountSync: SendTo', 'if false then error("LibAccountSync: SendTo' } } },
    { "no SendTo on an instance", { { '"Send", "SendTo", "OnMessage"', '"Send", "OnMessage"' } } },
    -- Stores (§3)
    { "a store's key is overwritten", {
        { "if S.key and (not ValidKey(t.key) or (t.key ~= S.key and union[t.key])) then", "if S.key then" } } },
    { "a newer store is written", { { "local function Writable(t) return t.v == nil or t.v == STORE_VERSION end",
                                      "local function Writable(t) return true end" } } },
    { "no trust cap", { { "if #keys <= TRUST_CAP then return end", "if true then return end" } } },
    { "the key chosen before every store resolves", { { "if not all or #stores == 0 then return nil end",
                                                         "if #stores == 0 then return nil end" } } },
    -- Upgrade in place (§4)
    { "an instance function captures its implementation", {
        { "        if inst[name] == nil then\n            inst[name] = function(...)",
          "        if inst[name] == nil then\n            local captured = lib.impl[name]\n            inst[name] = function(...)" },
        { "                return lib.impl[name](inst, ...)", "                return captured(inst, ...)" } } },
    { "the frame captures OnEvent", {
        { 'if not lib.frame then\n    lib.frame = CreateFrame("Frame")',
          'local capturedOnEvent = I.OnEvent\nif not lib.frame then\n    lib.frame = CreateFrame("Frame")' },
        { "        return lib.impl.OnEvent(event, ...)", "        return capturedOnEvent(event, ...)" } } },
    { "the ticker captures Tick", {
        { "if not lib.ticker then\n", "local capturedTick = I.Tick\nif not lib.ticker then\n" },
        { "        return lib.impl.Tick()", "        return capturedTick()" } } },
    { "a CTL callback captures OnChunkSent", {
        { "    local tag = inst.addon\n", "    local tag = inst.addon\n    local capturedSent = I.OnChunkSent\n" },
        { "                    return lib.impl.OnChunkSent(arg, didSend, result)",
          "                    return capturedSent(arg, didSend, result)" } } },
    { "migration overwrites instance functions", { { "        if inst[name] == nil then\n            inst[name]",
                                                     "        if true then\n            inst[name]" } } },
    { "the state table is replaced", { { "lib.state = lib.state or {}", "lib.state = {}" } } },
    { "New skips the marker check", {
        { "local ready = lib.ready ~= nil and lib.ready == select(2, LibStub:GetLibrary(MAJOR, true))",
          "local ready = true" } } },
    { "instance functions skip the marker check", {
        { "                if lib.ready == nil or lib.ready ~= select(2, LibStub:GetLibrary(MAJOR, true)) then\n                    if not inst.inertReported",
          "                if false then\n                    if not inst.inertReported" } } },
    { "the frame skips the marker check", {
        { "    lib.frame:SetScript(\"OnEvent\", function(_, event, ...)\n        if lib.ready == nil or lib.ready ~= select(2, LibStub:GetLibrary(MAJOR, true)) then return end",
          "    lib.frame:SetScript(\"OnEvent\", function(_, event, ...)" } } },
    -- Secrets (§5.2)
    { "a secret field is copied as if plain", { { "if IsSecret(v) then r.unknown = true else r[k] = v end",
                                                  "r[k] = v" } } },
    { "a raw read outside the readers", {
        { "    local rec = I.GameRec(id)\n    if not rec or rec.unknown or rec.isOnline == false",
          "    local raw = C_BattleNet.GetGameAccountInfoByID(id)\n    local rec = I.GameRec(id)\n    if not rec or rec.unknown or rec.isOnline == false" } } },
}

local source = read("LibAccountSync.lua")
local tests = {}
for name in io.popen('dir /b tests\\test_*.lua 2>NUL || ls tests/test_*.lua'):lines() do
    tests[#tests + 1] = "tests/" .. name:gsub("^tests[/\\]", "")
end
table.sort(tests)

local mutant = os.tmpname()
if mutant:sub(1, 1) == "\\" then mutant = (os.getenv("TEMP") or ".") .. mutant end
local survived, bad, ran = {}, {}, 0

-- Control: the unmutated source, through the same path, must be green, or a
-- "red" below proves nothing.
do
    local f = assert(io.open(mutant, "wb")); f:write(source); f:close()
    for _, t in ipairs(tests) do
        local rc = os.execute(('set "LIBACCT_MUTANT=%s" && "%s" %s >NUL 2>&1'):format(mutant, LUA, t))
        if rc ~= 0 and rc ~= true then
            io.write("control run FAILED in " .. t .. ": fix the suite before mutating\n")
            os.exit(1)
        end
    end
    io.write("control run: green\n")
end

for _, m in ipairs(M) do
    if not filter or m[1]:find(filter, 1, true) then
        local src, ok = source, true
        for _, r in ipairs(m[2]) do
            local i, j = src:find(r[1], 1, true)
            if not i or src:find(r[1], j + 1, true) then ok = false; break end
            src = src:sub(1, i - 1) .. r[2] .. src:sub(j + 1)
        end
        if not ok then
            bad[#bad + 1] = m[1]
        else
            ran = ran + 1
            local f = assert(io.open(mutant, "wb")); f:write(src); f:close()
            local red
            for _, t in ipairs(tests) do
                local cmd = ('set "LIBACCT_MUTANT=%s" && "%s" %s >NUL 2>&1'):format(mutant, LUA, t)
                local rc = os.execute(cmd)
                if rc ~= 0 and rc ~= true then red = t; break end
            end
            io.write(("%-55s %s\n"):format(m[1], red and ("red (" .. red:match("test_[%w_]+") .. ")") or "SURVIVED"))
            if not red then survived[#survived + 1] = m[1] end
        end
    end
end
os.remove(mutant)
io.write(("\n%d mutations, %d survived, %d did not apply\n"):format(ran, #survived, #bad))
for _, b in ipairs(bad) do io.write("  did not apply (fix the mutation): " .. b .. "\n") end
os.exit((#survived == 0 and #bad == 0) and 0 or 1)
