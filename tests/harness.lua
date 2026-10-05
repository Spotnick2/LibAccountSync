-- harness.lua: assertions, the library loader, and the other account.
-- dofile it after wow_stubs.lua. Run from the repo root so the paths resolve.

local passed, failed = 0, 0

function check(cond, msg)
    if cond then passed = passed + 1 else
        failed = failed + 1
        io.write("  FAIL: " .. tostring(msg) .. "\n")
    end
end

function eq(actual, expected, msg)
    check(actual == expected, string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
end

function done(name)
    io.write(string.format("%s: %d passed, %d failed\n", name, passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

function readFile(path)
    local f = assert(io.open(path, "rb"), "cannot open " .. path)
    local s = f:read("*a")
    f:close()
    return s
end

-- The runtime's source, LF. tests/mutate.lua points LIBACCT_MUTANT at a
-- mutated copy, and every test then loads and greps that instead.
function runtimeSource()
    return (readFile(os.getenv("LIBACCT_MUTANT") or "LibAccountSync.lua"):gsub("\r\n", "\n"))
end

-- The Lua files LibAccountSync-1.0.xml loads, in order, read from the XML so
-- the tests load exactly what the client loads.
function xmlScripts()
    local xml = readFile("LibAccountSync-1.0.xml"):gsub("<!%-%-.-%-%->", "")
    local files = {}
    for file in xml:gmatch('<Script%s+file="([^"]+)"') do files[#files + 1] = (file:gsub("\\", "/")) end
    return files
end

-- One copy of the library: every file the XML lists. `edit(file, src)` may
-- rewrite a file's source (synthetic copies). Sources are LF whatever the
-- checkout has (a Windows clone with core.autocrlf gets CRLF).
function copyOf(edit)
    local copy = {}
    for _, file in ipairs(xmlScripts()) do
        local src = file == "LibAccountSync.lua" and runtimeSource() or readFile(file):gsub("\r\n", "\n")
        if edit then src = edit(file, src) end
        copy[#copy + 1] = { name = file, src = src }
    end
    return copy
end

-- Load a copy as the client loads an embedded library: each file in order,
-- called with (host addon name, namespace).
function loadCopy(copy, host)
    local ns = {}
    for _, file in ipairs(copy) do
        local chunk = assert(loadstring(file.src, "=" .. file.name .. " (" .. tostring(host) .. ")"))
        chunk(host, ns)
    end
    return LibStub("LibAccountSync-1.0")
end

function loadLibrary(host)
    return loadCopy(copyOf(), host or "GlassChat")
end

-- An older copy: this checkout with its runtime replaced by a frozen one
-- from tests/fixtures/ (EMBEDDED-LIBRARIES §8: never "the current source with
-- a lower number").
function fixtureCopy(name)
    return copyOf(function(file, src)
        if file ~= "LibAccountSync.lua" then return src end
        return (readFile("tests/fixtures/" .. name):gsub("\r\n", "\n"))
    end)
end

local MINOR_LINE = 'local MAJOR, MINOR = "LibAccountSync%-1%.0", (%d+)'
function currentMinor()
    return tonumber(runtimeSource():match(MINOR_LINE))
end

-- This checkout with another MINOR, `replace` plain-text substitutions (each
-- must match once) and `extra` Lua run just before the completion marker.
function synthetic(minor, extra, replace)
    return copyOf(function(file, src)
        if file ~= "LibAccountSync.lua" then return src end
        local n
        src, n = src:gsub(MINOR_LINE, 'local MAJOR, MINOR = "LibAccountSync-1.0", ' .. minor)
        assert(n == 1, "synthetic: MINOR line not found")
        for _, r in ipairs(replace or {}) do
            local i, j = src:find(r[1], 1, true)
            assert(i and not src:find(r[1], j + 1, true), "synthetic: must match once: " .. r[1])
            src = src:sub(1, i - 1) .. r[2] .. src:sub(j + 1)
        end
        if extra then
            local i = src:find("\nlib.ready = MINOR%s*$")
            assert(i, "synthetic: the completion marker is not the last line")
            src = src:sub(1, i) .. extra .. "\n" .. src:sub(i + 1)
        end
        return src
    end)
end

--------------------------------------------------------------------------------
-- A session: fresh client, library loaded, one host registered, logged in.
--------------------------------------------------------------------------------

PREFIX = "LibAcctSync"
OTHER_KEY = "0123456789abcdef0123456789abcdef"   -- the other account's household key

-- Reports collected per host: reports[tag] = { {text, kind}, ... }.
reports = {}
function newHost(lib, tag, store, opts)
    reports[tag] = {}
    local o = { addon = tag, store = function() return store end,
                report = function(text, kind) table.insert(reports[tag], { text = text, kind = kind }) end }
    for k, v in pairs(opts or {}) do o[k] = v end
    return lib:New(o)
end

function login()
    WoW.loggedIn = true
    WoW.fire("PLAYER_LOGIN")
end

-- Fresh client, library, one host "GlassChat" with `store`, logged in, and the
-- friends list settled (60 s after Battle.net came up) unless told otherwise.
function session(store, opts)
    opts = opts or {}
    WoW.reset(); WoW.resetLibStub()
    if opts.before then opts.before() end
    local lib = loadLibrary()
    store = store or {}
    local inst = newHost(lib, "GlassChat", store, opts.host)
    login()
    if not opts.unsettled then WoW.advance(61) end
    return lib, inst, store
end

-- Every frame we sent to `id` (or all), optionally only those starting with `kind`.
function sentTo(id, kind)
    local out = {}
    for _, m in ipairs(WoW.sent) do
        if (id == nil or m.target == id) and (kind == nil or m.text:sub(1, #kind) == kind) then
            out[#out + 1] = m
        end
    end
    return out
end

local function split(text, max)
    local out, pos = {}, 1
    while #out < max do
        local i = text:find("|", pos, true)
        if not i then out[#out + 1] = text:sub(pos); break end
        out[#out + 1] = text:sub(pos, i - 1)
        pos = i + 1
    end
    return out
end

-- The proof and MAC written out independently of the library, from the plan
-- (§5.1, §5.3), so a test checks the formula, not the library against itself.
function proofFor(key, receiverNonce, senderNonce, name, guid, realm, project, region)
    local H = LibStub("LibAccountSync-1.0")._test.HMAC256
    return H(key, "LibAccountSync-1.0|hello|1|" .. receiverNonce .. "|" .. senderNonce .. "|" .. name:lower()
        .. "|" .. guid .. "|" .. realm .. "|" .. project .. "|" .. region):sub(1, 32)
end

function macFor(key, receiverNonce, senderGuid, project, region, tag, sid, n, payload)
    local T = LibStub("LibAccountSync-1.0")._test
    return T.HMAC256(key, "LibAccountSync-1.0|data|1|" .. receiverNonce .. "|" .. senderGuid .. "|" .. project
        .. "|" .. region .. "|" .. tag .. "|" .. sid .. "|" .. n .. "|" .. T.SHA256(payload)):sub(1, 32)
end

--------------------------------------------------------------------------------
-- The other account, as this client sees it
--------------------------------------------------------------------------------

Peer = {}
Peer.__index = Peer

-- o: id (as this client sees it), name, guid, realm, faction, key, nonce,
-- bnet (its Battle.net account id; ours by default), blank (presence blank to
-- us), project, region.
function Peer.new(o)
    local p = setmetatable({
        id = o.id or 3, name = o.name or "Karuzo", guid = o.guid or "Player-1-0000000B",
        realm = o.realm or "Classic Beta PvE", faction = o.faction or "Alliance",
        key = o.key or OTHER_KEY, nonce = o.nonce or "fedcba9876543210",
        project = o.project or 18, region = o.region or 90,
    }, Peer)
    p.record = { characterName = p.name, playerGuid = p.guid, isOnline = true, clientProgram = "WoW",
                 wowProjectID = p.project, regionID = p.region, isInCurrentRegion = true,
                 factionName = p.faction, realmName = p.realm, bnetAccountID = o.bnet or WoW.bn.me }
    if o.blank then p:setBlank(true) end
    WoW.bn.accounts[p.id] = p.record
    return p
end

-- Presence blank as we see it: online, WoW, no name, no GUID.
function Peer:setBlank(on)
    if on then
        self.record.characterName, self.record.playerGuid = nil, nil
        self.record.wowProjectID, self.record.regionID = nil, nil
    else
        self.record.characterName, self.record.playerGuid = self.name, self.guid
        self.record.wowProjectID, self.record.regionID = self.project, self.region
    end
end

-- The last hello we sent this account, parsed.
function Peer:ourHello()
    local hs = sentTo(self.id, "H1|")
    local m = hs[#hs]
    if not m then return nil end
    local f = split(m.text, 9)
    return { maxWire = f[2], name = f[3], guid = f[4], faction = f[5], realm = f[6], key = f[7],
             nonce = f[8], proof = f[9], text = m.text }
end

-- Its hello to us. o.key: "" (default) or a key; o.proof: a proof, or
-- computed over our latest nonce when we have sent one; o.nonce, o.name,
-- o.guid, o.realm override.
function Peer:hello(o)
    o = o or {}
    local name, guid, realm = o.name or self.name, o.guid or self.guid, o.realm or self.realm
    local nonce = o.nonce or self.nonce
    local proof = o.proof
    if proof == nil then
        local ours = self:ourHello()
        proof = ours and proofFor(o.proofKey or self.key, ours.nonce, nonce, name, guid, realm,
                                  o.project or self.project, o.region or self.region) or ""
    end
    return table.concat({ "H1", "1", name, guid, o.faction or self.faction, realm, o.key or "", nonce, proof }, "|")
end

function Peer:deliver(text, id)
    WoW.fire("BN_CHAT_MSG_ADDON", PREFIX, text, "WHISPER", id or self.id)
end

-- Its data frames to us, MAC'd over our nonce for its id. o.sid (string),
-- o.mac, o.guid, o.key, o.nonce override.
function Peer:frames(tag, payload, o)
    o = o or {}
    local T = LibStub("LibAccountSync-1.0")._test
    local enc = T.Encode(payload)
    local bodies = { enc:sub(1, T.BODY_FIRST) }
    local pos = T.BODY_FIRST + 1
    while pos <= #enc do
        bodies[#bodies + 1] = enc:sub(pos, pos + T.BODY_REST - 1)
        pos = pos + T.BODY_REST
    end
    local n = #bodies
    local sid = o.sid or "1760000000001"
    local ours = self:ourHello()
    local mac = o.mac or macFor(o.key or self.key, o.nonce or (ours and ours.nonce or "0000000000000000"),
                                o.guid or self.guid, self.project, self.region, tag, sid, n, payload)
    local frames = {}
    for i = 1, n do
        frames[i] = table.concat({ "D1", tag, sid, tostring(i), tostring(n), i == 1 and mac or "-", bodies[i] }, "|")
    end
    return frames
end

function Peer:send(tag, payload, o)
    for _, f in ipairs(self:frames(tag, payload, o)) do self:deliver(f, o and o.id) end
end

-- What we sent this account under `tag`, reassembled, with the MAC checked
-- against our key (from `ourStore`) and its nonce. Returns payload, sid, mac-ok.
function Peer:received(tag, ourStore)
    local T = LibStub("LibAccountSync-1.0")._test
    local streams = {}
    for _, m in ipairs(sentTo(self.id, "D1|")) do
        local t, sid, i, n, mac, body = m.text:match("^D1|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
        if t == tag then
            streams[sid] = streams[sid] or { n = tonumber(n), chunks = {} }
            streams[sid].chunks[tonumber(i)] = body
            if i == "1" then streams[sid].mac = mac end
        end
    end
    local out = {}
    for sid, s in pairs(streams) do
        local payload = T.Decode(table.concat(s.chunks, "", 1, s.n))
        local ok = payload and s.mac == macFor(ourStore.key, self.nonce, WoW.player.guid, WoW.bn.project,
                                               WoW.bn.region, tag, sid, s.n, payload)
        out[#out + 1] = { payload = payload, sid = sid, macOk = ok, n = s.n }
    end
    table.sort(out, function(a, b) return a.sid < b.sid end)
    return out
end

-- Collects what a host's OnMessage receives.
function inbox(inst)
    local box = {}
    inst.OnMessage(function(payload, sender, sid) box[#box + 1] = { payload = payload, sender = sender, sid = sid } end)
    return box
end
