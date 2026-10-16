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

-- { name, { { from, to }, ... }, file? }: plain-text substitutions, each
-- matching once, in the runtime, or in the probe (PROBE) or its log reader
-- (WIRELOG) when file names one.
local PROBE = "Tools/LibAccountSyncProbe/LibAccountSyncProbe.lua"
local WIRELOG = "Tools/read-wirelog.py"
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
        { "        I.RecheckAwaiting(buf.id)\n        if S.buffers[key] ~= buf then return end\n", "" } } },
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
        { 'local MAJOR, MINOR = "LibAccountSync-1.0", 5', 'local MAJOR, MINOR = "LibAccountSync-1.0", 1' } } },
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
        { "    if S.buffers[key] == buf then I.ArmSettle(key, buf) end\n", "    S.buffers[key] = nil\n" } } },
    { "a completed stream delivered ahead of waiting ones", {
        { "    I.RecheckAwaiting(buf.id)\n    if S.buffers[key] == buf then I.ArmSettle(key, buf) end",
          "    if not I.TryDeliver(key, buf) then I.ArmSettle(key, buf) end" } } },
    { "no recheck when a hello lands", { { "    I.SendHello(id, \"answer\")\n    I.RecheckAwaiting(id)",
                                           "    I.SendHello(id, \"answer\")" } } },
    -- Stream ids (§5.2)
    { "the sid floor keyed by id", { { 'local floorKey = buf.tag .. "|" .. tostring(sender.guid)',
                                       'local floorKey = buf.tag .. "|" .. tostring(buf.id)' } } },
    { "no sid floor", { { "if S.floors[floorKey] and buf.sid <= S.floors[floorKey] then return true end", "" } } },
    -- Messages mode (#18) and independent tags (#17)
    { "messages mode ignored on receive", { { "if inst and inst.messages == true then", "if false then" } } },
    { "every instance in messages mode", { { "if opts.messages then inst.messages = true end", "inst.messages = true" } } },
    { "messages: a sid delivered twice", { { "        if sids[at - 1] == sid then return false end\n", "" } } },
    { "messages: no floor below the window", { { "    if sid <= rec.below then return false end\n", "" } } },
    { "messages: the window never forgets", { { "if #sids > MESSAGE_WINDOW then", "if false then" } } },
    { "messages: the window out of order", { { "while at > 1 and sids[at - 1] >= sid do", "while false do" } } },
    { "messages: the record keyed by id", { { "if not I.FirstDelivery(floorKey, buf.sid) then return true end",
                                              'if not I.FirstDelivery(buf.tag .. "|" .. buf.id, buf.sid) then return true end' } } },
    { "waiting streams released in table order", {
        { "    table.sort(waiting, function(a, b) return (a.buf.seq or 0) < (b.buf.seq or 0) end)\n", "" } } },
    { "a settle timer delivers only its own stream", {
        { "        I.RecheckAwaiting(buf.id)\n        if S.buffers[key] ~= buf then return end",
          "        if I.TryDeliver(key, buf) then return end" } } },
    { "the cap evicts a message", { { "if perId >= cap and inst.messages ~= true then",
                                      "if perId >= cap then" } } },
    { "the cap counted across tags", { { "if b.id == id and b.tag == tag then perId = perId + 1 end",
                                         "if b.id == id then perId = perId + 1 end" } } },
    { "messages get the snapshot cap", { { "local cap = inst.messages == true and STREAMS_PER_ID_MESSAGES or STREAMS_PER_ID",
                                           "local cap = STREAMS_PER_ID" } } },
    { "the sid floor not keyed by tag", { { 'local floorKey = buf.tag .. "|" .. tostring(sender.guid)',
                                            'local floorKey = tostring(sender.guid)' } } },
    { "migration sets messages on an older instance", {
        { "    if inst.maxPayload == nil then inst.maxPayload = 16384 end\n",
          "    if inst.maxPayload == nil then inst.maxPayload = 16384 end\n    inst.messages = true\n" } } },
    { "the cap evicts another tag's stream", { { "if b.id == id and b.tag == tag and (not oldSid",
                                                 "if b.id == id and (not oldSid" } } },
    { "messages not a boolean is accepted", { { 'if opts.messages ~= nil and type(opts.messages) ~= "boolean" then',
                                                "if false then" } } },
    { "lastSid not read back from the store", {
        { 'if type(t.lastSid) == "number" and t.lastSid > lastSid and t.lastSid < 1e13 then lastSid = t.lastSid end', "" } } },
    -- Framing and caps (§2, §5.2)
    { "the data body is split on |", { { '|([^|]*)|([^|]*)|(.*)$")', '|([^|]*)|([^|]*)|([^|]*)")' } } },
    { "no chunk cap", { { "if i < 1 or i > n or n > MAX_CHUNKS then return end", "if i < 1 or i > n then return end" } } },
    { "no per-sender stream cap", { { "if perId >= cap or total >= STREAMS_TOTAL then",
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

    -- The probe (test_probe; it skips, so it is never red, without ..\ForeverProbe)
    { "probe: lines go to chat", { { '    Probe:Say(("%s %s %s"):format(date("%H:%M:%S"), Where(), text))',
        '    Probe:Say(("%s %s %s"):format(date("%H:%M:%S"), Where(), text)); print(text)' } }, PROBE },
    { "probe: the log isn't bound", { { "        Probe:UseLog(db.log, MAX_LOG)", "" } }, PROBE },
    { "probe: clear replaces the log", { { 'function() Probe:ClearLog(); Log("log cleared") end',
        'function() LibAccountSyncProbeDB.log = {}; Log("log cleared") end' } }, PROBE },
    { "probe: the filler isn't checked", { { " and payload:sub(#head + 1) == Filler(#payload - #head)", "" } }, PROBE },
    { "probe: a duplicate isn't flagged", { { "local dup = seen[i]", "local dup = false" } }, PROBE },
    { "probe: any Battle.net message is a ping", { { "if IsS(prefix) or prefix ~= PROBE_PREFIX then return end",
        "if IsS(prefix) then return end" } }, PROBE },
    { "probe: ProbeMsg gets snapshots", { { ", report = Report, messages = true })", ", report = Report })" } }, PROBE },
    { "probe: sendto broadcasts", { { 'Sync.SendTo(p.guid, payload, OnResult("sendto"))',
        'Sync.Send(payload, OnResult("sendto"))' } }, PROBE },
    { "probe: results pass on anything", { { "check = function() return round.sent == expected and round.failed == 0, Tally() end",
        "check = function() return true, Tally() end" } }, PROBE },
    { "probe: a named presence is blank", {
        { '\n        and (g.characterName == nil or g.characterName == "" or g.playerGuid == nil or g.playerGuid == "")', "" } }, PROBE },
    { "probe: pings before the mark count", { { "check = function() return pingsHeard > pingMark,",
        "check = function() return pingsHeard >= pingMark," } }, PROBE },
    { "probe: a late result lands in the latest round", { { '        if status == "sent" then r.sent = r.sent + 1 else',
        '        r = round\n        if status == "sent" then r.sent = r.sent + 1 else' } }, PROBE },
    { "probe: 7.3 takes any blank presence", { { "check = function() return TargetBlank() end },",
        "check = function() return Ids() >= 1 end }," } }, PROBE },
    { "probe: 7.3 takes a Battle.net peer", { { '(p.proven == "key" or p.proven == "proof")', "true" } }, PROBE },
    { "probe: 7.3 sends without checking blank", { { "return blankAtSend and round.count == 1", "return round.count == 1" } }, PROBE },
    { "probe: a round never says complete", { { "    if back >= r.expected then", "    if false then" } }, PROBE },
    { "probe: a round says complete one early", { { "    if back >= r.expected then", "    if back + 1 >= r.expected then" } }, PROBE },
    { "probe: an early tally hides what's pending", { { "    if Pending() > 0 then\n        t = t", "    if false then\n        t = t" } }, PROBE },
    { "probe: a results step doesn't wait", { { "                 if Pending() > 0 then return false, Tally() end\n", "" } }, PROBE },
    { "probe: a not-ready refusal counts as an answer", {
        { '            if reason == "not-ready" and r.expected == nil then r.refused = r.refused + 1 end\n', "" } }, PROBE },
    { "probe: a results step never times out", { { "             timeout = RESULTS_TIMEOUT,\n", "" } }, PROBE },
    { "probe: a send to nobody waits", { { "    if r.expected == 0 then r.done = true; return end\n", "" } }, PROBE },

    -- The log reader (test_wirelog)
    { "wirelog: a line without a clock is dropped", { { "if c is None or c[:len(since)] >= since]",
        "if c is not None and c[:len(since)] >= since]" } }, WIRELOG },
    { "wirelog: no clock from the uptime", { { "        if secs is None and up is not None and run in offsets:",
        "        if False:" } }, WIRELOG },
    { "wirelog: the clock is searched for anywhere", { { 'CLOCK = re.compile(r"^(?:\\d+(?:\\.\\d+)?(?: C)? #\\d+ )?(\\d\\d):(\\d\\d):(\\d\\d) ")',
        'CLOCK = re.compile(r"()(\\d\\d):(\\d\\d):(\\d\\d)")' }, { "s, c = STAMP.match(line), CLOCK.match(line)",
        "s, c = STAMP.match(line), CLOCK.search(line)" }, { "int(c.group(1)) * 3600 + int(c.group(2)) * 60 + int(c.group(3))",
        "int(c.group(2)) * 3600 + int(c.group(3)) * 60 + int(c.group(4))" } }, WIRELOG },
    { "wirelog: the offset is not per run", { { "offsets[run] = secs - up", "offsets.setdefault(None, secs - up); offsets[run] = offsets[None]" } }, WIRELOG },
}

local sources = { runtime = read("LibAccountSync.lua"), [PROBE] = read(PROBE), [WIRELOG] = read(WIRELOG) }
local ENV = { runtime = "LIBACCT_MUTANT", [PROBE] = "LIBACCT_PROBE_MUTANT", [WIRELOG] = "LIBACCT_WIRELOG_MUTANT" }
local tests = {}
for _, ext in ipairs({ "lua", "py" }) do
    for name in io.popen(('dir /b tests\\test_*.%s 2>NUL || ls tests/test_*.%s'):format(ext, ext)):lines() do
        tests[#tests + 1] = "tests/" .. name:gsub("^tests[/\\]", "")
    end
end
table.sort(tests)

-- A test file's command line: Lua 5.1, or Python (isolated) for the log reader's test.
local function run(t) return t:match("%.py$") and ("python -I " .. t) or ('"' .. LUA .. '" ' .. t) end

local mutant = os.tmpname()
if mutant:sub(1, 1) == "\\" then mutant = (os.getenv("TEMP") or ".") .. mutant end
local survived, bad, ran = {}, {}, 0

-- Control: the unmutated source, through the same path, must be green, or a
-- "red" below proves nothing.
do
    local f = assert(io.open(mutant, "wb")); f:write(sources.runtime); f:close()
    for _, t in ipairs(tests) do
        local rc = os.execute(('set "LIBACCT_MUTANT=%s" && %s >NUL 2>&1'):format(mutant, run(t)))
        if rc ~= 0 and rc ~= true then
            io.write("control run FAILED in " .. t .. ": fix the suite before mutating\n")
            os.exit(1)
        end
    end
    io.write("control run: green\n")
end

for _, m in ipairs(M) do
    if not filter or m[1]:find(filter, 1, true) then
        local target = m[3] or "runtime"
        local src, ok = sources[target], true
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
                local cmd = ('set "%s=%s" && %s >NUL 2>&1'):format(ENV[target], mutant, run(t))
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
