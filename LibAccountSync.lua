-- LibAccountSync-1.0: send small messages to the player's OWN other WoW
-- accounts on the same Battle.net account, and receive them, with ownership
-- proven first. An embedded LibStub library for WoW: Forever (Lua 5.1).
--
-- Seeded from AltStable's own-account channel (AltStable #58, its
-- docs/SYNC-DISCOVERY.md and Core.lua); the design, its review rounds and
-- every "why" are in docs/PLAN.md. Section numbers below (§n) refer to it.
--
--   local Sync = LibStub("LibAccountSync-1.0"):New({
--       addon = "GlassChat",                                   -- wire tag
--       store = function() return GlassChatDB and GlassChatDB.accountSync end,
--       report = function(text, kind) end,                    -- optional
--       maxPayload = 16384,                                    -- optional
--   })
--   Sync.OnMessage(function(payload, sender, sid) end)
--   Sync.Send(payload, function(sender, status, reason) end)
--
-- Several addons embed copies and the newest one loaded wins (LibStub), so an
-- instance or a frame an older copy made must run this copy's code:
-- - Everything installed once (instance functions, the event frame's script,
--   the ticker, timers, ChatThrottleLib callbacks) is a thin closure that
--   checks the completion marker and looks up lib.impl.<name> WHEN IT RUNS.
-- - lib.impl, lib.state, lib.instances and lib.byTag keep their identity
--   across upgrades (X = X or {}); an upgrade only fills missing keys.
-- - Protocol meaning belongs to the WIRE version below, never to MINOR: an
--   older host can run a newer copy, and two accounts can run different ones.
-- - lib.ready = MINOR is the last line: a copy that threw partway leaves every
--   entry point inert.

local MAJOR, MINOR = "LibAccountSync-1.0", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end   -- an equal or newer copy is already loaded

lib.impl = lib.impl or {}
lib.instances = lib.instances or {}   -- every instance, in creation order
lib.byTag = lib.byTag or {}           -- tag -> instance
lib.state = lib.state or {}           -- all session state (§4)

-- The table is shared by every copy and never replaced, so holding it is
-- safe; holding one of its FUNCTIONS past load is not (it would run this
-- copy's code forever). Bodies call I.X at run time.
local I = lib.impl
local S = lib.state

--------------------------------------------------------------------------------
-- Wire 1 (§2). Frozen: a later wire is added alongside, never instead.
--------------------------------------------------------------------------------

local PREFIX = "LibAcctSync"
local WIRE = 1                         -- the newest wire this copy speaks
local HELLO_DOMAIN = "LibAccountSync-1.0|hello|1|"
local DATA_DOMAIN = "LibAccountSync-1.0|data|1|"
local MAX_PAYLOAD = 32768              -- the wire ceiling, decoded bytes
local BODY_FIRST, BODY_REST = 180, 211 -- worst-case header budget (§2)
local MAX_CHUNKS = 365                 -- ceil(2 * 32768 / 180): escaping can double
local MAX_MESSAGE = 255

-- Behaviour, not wire: a newer copy may tune these.
local MAX_ID = 128                     -- the local game account id walk
local HELLO_EVERY, HELLO_FLOOR = 60, 5 -- seconds between hellos to one id
local ANSWERS_PER_MINUTE = 6           -- answers to new nonces, per id
local PROOF_CHECKS_PER_MINUTE = 12     -- proof verifications (up to 16 HMACs each), per id
local FRIENDS_SETTLE = 60              -- seconds after Battle.net comes up
local SETTLING_EVERY, SETTLING_TRIES = 10, 30
local STREAM_SETTLE = 6                -- seconds with no chunk drops a stream
local AWAIT_HELLO = 10                 -- a complete stream waits this long for its hello
local STREAMS_PER_ID, STREAMS_TOTAL = 2, 8
local BUFFER_BYTES = 131072
local ROUTE_CACHE = 2
local TRUST_CAP = 16
local STORE_VERSION = 1

local REASONS = { disabled = true, ["no-peers"] = true, ["too-large"] = true,
                  ["not-ready"] = true, offline = true, ["no-route"] = true }
lib.REASONS = lib.REASONS or {}
for k in pairs(REASONS) do lib.REASONS[k] = true end

local FUNCTIONS = { "Send", "OnMessage", "Peers", "Rescan", "SetEnabled", "IsEnabled", "Diagnostics" }

--------------------------------------------------------------------------------
-- State (§4): filled only where missing, so an upgrade keeps what is live.
--------------------------------------------------------------------------------

local STATE_TABLES = { "peers", "learned", "myNonce", "theirNonce", "helloSent", "answered", "buffers",
                       "finished", "refused", "floors", "routeChecked", "reported", "proofChecks", "pendingKeys" }
for _, k in ipairs(STATE_TABLES) do
    if S[k] == nil then S[k] = {} end
end
if S.upSince == nil then S.upSince = 0 end
if S.settleTries == nil then S.settleTries = 0 end
if S.entropy == nil then S.entropy = 0 end
if S.lastSid == nil then S.lastSid = 0 end

local function wipe(t) for k in pairs(t) do t[k] = nil end return t end

local function Ready()
    return lib.ready ~= nil and lib.ready == select(2, LibStub:GetLibrary(MAJOR, true))
end
lib.IsReady = Ready

--------------------------------------------------------------------------------
-- SHA-256 and HMAC-SHA-256, pure Lua 5.1 (from AltStable Core.lua 728-849)
--------------------------------------------------------------------------------
-- The client offers addons no hash, and LibDeflate's checksums are linear.
-- Arithmetic only, no `bit` library, so the game and the tests run the same
-- code. Checked against the FIPS 180-2 and RFC 4231 vectors (test_crypto).
local SHA256, HMAC256
do
    local TWO32 = 4294967296
    local XOR4, AND4 = {}, {}
    for x = 0, 15 do
        XOR4[x], AND4[x] = {}, {}
        for y = 0, 15 do
            local rx, ra, bv, xx, yy = 0, 0, 1, x, y
            for _ = 1, 4 do
                local xb, yb = xx % 2, yy % 2
                if xb ~= yb then rx = rx + bv end
                if xb == 1 and yb == 1 then ra = ra + bv end
                xx, yy, bv = (xx - xb) / 2, (yy - yb) / 2, bv * 2
            end
            XOR4[x][y], AND4[x][y] = rx, ra
        end
    end
    local function nib(op, a, b)
        local r, m = 0, 1
        for _ = 1, 8 do
            local na, nb = a % 16, b % 16
            r = r + op[na][nb] * m
            a, b, m = (a - na) / 16, (b - nb) / 16, m * 16
        end
        return r
    end
    local function bxor(a, b) return nib(XOR4, a, b) end
    local function band(a, b) return nib(AND4, a, b) end
    local function bnot(a) return 4294967295 - a end
    local function shr(a, n) return math.floor(a / 2 ^ n) end
    local function ror(a, n)
        local lo = a % 2 ^ n
        return (a - lo) / 2 ^ n + lo * 2 ^ (32 - n)
    end

    local K = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }

    local function digest(msg)
        local len = #msg
        msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
        local bits = len * 8
        local tail = {}
        for i = 8, 1, -1 do
            tail[i] = string.char(bits % 256)
            bits = math.floor(bits / 256)
        end
        msg = msg .. table.concat(tail)
        local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
        local w = {}
        for chunk = 1, #msg, 64 do
            for i = 0, 15 do
                local b1, b2, b3, b4 = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
                w[i] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
            end
            for i = 16, 63 do
                local x, y = w[i - 15], w[i - 2]
                local s0 = bxor(bxor(ror(x, 7), ror(x, 18)), shr(x, 3))
                local s1 = bxor(bxor(ror(y, 17), ror(y, 19)), shr(y, 10))
                w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % TWO32
            end
            local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
            for i = 0, 63 do
                local S1 = bxor(bxor(ror(e, 6), ror(e, 11)), ror(e, 25))
                local ch = bxor(band(e, f), band(bnot(e), g))
                local t1 = (h + S1 + ch + K[i + 1] + w[i]) % TWO32
                local S0 = bxor(bxor(ror(a, 2), ror(a, 13)), ror(a, 22))
                local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
                local t2 = (S0 + maj) % TWO32
                h, g, f, e = g, f, e, (d + t1) % TWO32
                d, c, b, a = c, b, a, (t1 + t2) % TWO32
            end
            H[1], H[2], H[3], H[4] = (H[1] + a) % TWO32, (H[2] + b) % TWO32, (H[3] + c) % TWO32, (H[4] + d) % TWO32
            H[5], H[6], H[7], H[8] = (H[5] + e) % TWO32, (H[6] + f) % TWO32, (H[7] + g) % TWO32, (H[8] + h) % TWO32
        end
        local out = {}
        for i = 1, 8 do
            local v = H[i]
            out[i] = string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256,
                                 math.floor(v / 256) % 256, v % 256)
        end
        return table.concat(out)
    end

    local function hex(s)
        return (s:gsub(".", function(ch) return ("%02x"):format(ch:byte()) end))
    end

    function SHA256(msg) return hex(digest(msg)) end

    function HMAC256(key, msg)
        if #key > 64 then key = digest(key) end
        key = key .. string.rep("\0", 64 - #key)
        local ipad, opad = {}, {}
        for i = 1, 64 do
            local k = key:byte(i)
            ipad[i] = string.char(bxor(k, 0x36))
            opad[i] = string.char(bxor(k, 0x5c))
        end
        return hex(digest(table.concat(opad) .. digest(table.concat(ipad) .. msg)))
    end
end

--------------------------------------------------------------------------------
-- Shapes and the codec (§2)
--------------------------------------------------------------------------------

-- Lua patterns have no {n}: a length test plus a character class.
local function IsHex(s, n) return type(s) == "string" and #s == n and not s:find("[^0-9a-f]") end
local function IsDigits(s, max) return type(s) == "string" and #s >= 1 and #s <= max and not s:find("%D") end
local function IsTag(s) return type(s) == "string" and #s >= 1 and #s <= 16 and not s:find("[^%w]") end
local function IsGuid(s) return type(s) == "string" and #s <= 64 and s:find("^Player%-%d+%-%x+$") ~= nil end
-- A name or realm as the hello carries it: present, no delimiter, bounded.
local function IsField(s, max) return type(s) == "string" and #s <= max and not s:find("[|%z]") end

-- Short name: lower-cased, any "-Realm" suffix dropped (names are unique
-- across the region on Forever, SYNC-DISCOVERY "Names are unique").
local function Short(name)
    if type(name) ~= "string" then return nil end
    local s = name:match("^([^%-]+)")
    return s and s:lower() or nil
end

-- \0 cannot travel; the escape byte must escape itself. Applied to the whole
-- payload before slicing, undone after reassembly.
local ESC = "\001"
local ENC = { ["\000"] = "\001\002", ["\001"] = "\001\001" }
local function Encode(s) return (s:gsub("[%z\001]", ENC)) end
local function Decode(s)
    local bad = false
    local out = s:gsub("\001(.?)", function(c)
        if c == "\002" then return "\000" elseif c == "\001" then return "\001" end
        bad = true
        return ""
    end)
    if bad then return nil end
    return out
end

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

function I.Report(text, kind, inst)
    local targets = inst and { inst } or lib.instances
    for _, it in ipairs(targets) do
        if type(it.report) == "function" then pcall(it.report, text, kind or "info") end
    end
end

-- Once per session per key: a fail-closed state must say why, but not every scan.
function I.ReportOnce(key, text, kind)
    if S.reported[key] then return end
    S.reported[key] = true
    I.Report(text, kind)
end

--------------------------------------------------------------------------------
-- Battle.net reads (§5.2): every field through one accessor
--------------------------------------------------------------------------------
-- A secret value throws when compared or truth-tested, and Lua 5.1 stubs can't
-- make that throw in tests, so NOTHING outside these two readers touches a
-- Battle.net record (test_secrets_grep enforces it). A secret field makes the
-- whole record "unknown", and unknown fails every predicate, the elimination
-- hint included: a secret name must never read as "blank".

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

local GAME_FIELDS = { "isOnline", "clientProgram", "isInCurrentRegion", "characterName", "playerGuid",
                      "wowProjectID", "regionID", "factionName", "realmName", "realmDisplayName",
                      "gameAccountID" }
local ACCT_FIELDS = { "bnetAccountID", "battleTag" }

local function Copy(raw, fields)
    if IsSecret(raw) then return { unknown = true } end
    if type(raw) ~= "table" then return nil end
    local r = {}
    for _, k in ipairs(fields) do
        local v = raw[k]
        if IsSecret(v) then r.unknown = true else r[k] = v end
    end
    return r
end

-- A game account record by id or GUID, as a plain table, or nil.
function I.GameRec(id)
    local ok, raw = pcall(C_BattleNet.GetGameAccountInfoByID, id)
    if not ok then return nil end
    return Copy(raw, GAME_FIELDS)
end

function I.GameRecByGuid(guid)
    if not C_BattleNet.GetGameAccountInfoByGUID then return nil end
    local ok, raw = pcall(C_BattleNet.GetGameAccountInfoByGUID, guid)
    if not ok then return nil end
    return Copy(raw, GAME_FIELDS)
end

-- An account record by character GUID, with its game account copied too.
function I.AcctRec(guid)
    local ok, raw = pcall(C_BattleNet.GetAccountInfoByGUID, guid)
    if not ok then return nil end
    local r = Copy(raw, ACCT_FIELDS)
    if r and not r.unknown and type(raw) == "table" then
        local g = raw.gameAccountInfo
        if IsSecret(g) then r.unknown = true
        elseif type(g) == "table" then
            r.game = Copy(g, GAME_FIELDS)
            if r.game.unknown then r.unknown = true end
        end
    end
    return r
end

-- A plain value from a client call, or nil if it is secret.
local function Plain(v) if IsSecret(v) then return nil end return v end

local function PlayerGuid() return Plain(UnitGUID("player")) end
local function PlayerName() return Plain((UnitName("player"))) end

--------------------------------------------------------------------------------
-- Stores (§3)
--------------------------------------------------------------------------------

-- The tables every registered host hands over right now. `all` is false while
-- any getter still returns nil (its SavedVariables not loaded yet).
function I.Stores()
    local list, all = {}, true
    for _, inst in ipairs(lib.instances) do
        local ok, t = pcall(inst.getStore)
        if ok and type(t) == "table" then
            list[#list + 1] = t
        else
            all = false
        end
    end
    return list, all
end

-- A store written by a newer format is read-only for this copy (§3).
local function Writable(t) return t.v == nil or t.v == STORE_VERSION end
local function Stamp(t) if t.v == nil then t.v = STORE_VERSION end end

local function ValidKey(k) return IsHex(k, 32) end

-- Our own household key: chosen once a session, lazily, never overwriting
-- another store's key. nil until every store resolves (fail closed).
function I.OwnKey()
    if S.key then return S.key end
    if not S.loggedIn then return nil end
    local stores, all = I.Stores()
    if not all or #stores == 0 then return nil end
    local best, bestAt
    local trusted = I.TrustUnion(stores)
    for _, t in ipairs(stores) do
        local k, at = t.key, t.keyAt
        -- A key we trust is another account's (a shared-key split moved it
        -- there): never ours again, even where a read-only store keeps it.
        if ValidKey(k) and type(at) == "number" and not trusted[k] then
            if not best or at < bestAt or (at == bestAt and k < best) then best, bestAt = k, at end
        end
    end
    if not best then
        best, bestAt = I.Entropy("key"):sub(1, 32), GetServerTime()
    end
    S.key, S.keyAt = best, bestAt
    I.SyncStores()
    -- Keys verified accounts sent before our own was chosen.
    for id, pk in pairs(S.pendingKeys) do
        S.pendingKeys[id] = nil
        if pk.key == best then I.SplitSharedKey(id, pk.guid) else I.Trust(pk.key) end
    end
    return S.key
end

-- Bring every writable store in line: the frozen key into stores that have
-- none, trust as a union (newest lastSeen), the cap, and the last stream id.
function I.SyncStores()
    local stores = I.Stores()
    local union = I.TrustUnion(stores)
    local lastSid = S.lastSid
    for _, t in ipairs(stores) do
        -- 13 digits at most: a corrupt value must not push frames past the wire shape.
        if type(t.lastSid) == "number" and t.lastSid > lastSid and t.lastSid < 1e13 then lastSid = t.lastSid end
    end
    S.lastSid = lastSid
    for _, t in ipairs(stores) do
        if Writable(t) then
            Stamp(t)
            if S.key and (not ValidKey(t.key) or (t.key ~= S.key and union[t.key])) then
                t.key, t.keyAt = S.key, S.keyAt                 -- none, or another account's
            end
            if type(t.trusted) ~= "table" then t.trusted = {} end
            for k, seen in pairs(union) do
                local mine = t.trusted[k]
                if type(mine) ~= "number" or mine < seen then t.trusted[k] = seen end
            end
            I.CapTrust(t.trusted)
            if lastSid > 0 then t.lastSid = lastSid end
        end
    end
end

-- Every trusted key across stores, newest lastSeen. Never our own key.
function I.TrustUnion(stores)
    local union = {}
    for _, t in ipairs(stores or I.Stores()) do
        if type(t.trusted) == "table" then
            for k, seen in pairs(t.trusted) do
                if ValidKey(k) and type(seen) == "number" and k ~= S.key then
                    if not union[k] or union[k] < seen then union[k] = seen end
                end
            end
        end
    end
    return union
end

-- Least recently seen valid keys beyond the cap are evicted; anything we
-- don't recognise is left alone (a newer copy may have written it).
function I.CapTrust(trusted)
    local keys = {}
    for k, seen in pairs(trusted) do
        if ValidKey(k) and type(seen) == "number" then keys[#keys + 1] = k end
    end
    if #keys <= TRUST_CAP then return end
    table.sort(keys, function(a, b)
        if trusted[a] ~= trusted[b] then return trusted[a] > trusted[b] end
        return a < b
    end)
    for i = TRUST_CAP + 1, #keys do trusted[keys[i]] = nil end
end

-- The union never holds our own key (TrustUnion), so neither does this.
function I.KeyTrusted(k)
    if not ValidKey(k) then return false end
    I.OwnKey()                                    -- freeze it first, so the union can exclude it
    return I.TrustUnion()[k] ~= nil
end

-- Record a key as trusted (or refresh its lastSeen) in every writable store.
function I.Trust(k)
    if not ValidKey(k) or k == S.key then return end
    local now = time()
    for _, t in ipairs((I.Stores())) do
        if Writable(t) then
            Stamp(t)
            if type(t.trusted) ~= "table" then t.trusted = {} end
            t.trusted[k] = now
            I.CapTrust(t.trusted)
        end
    end
end

-- A verified account sent us OUR key: one WTF folder was copied onto the
-- other account. The lower GUID makes a new key; the other side keeps its own
-- and learns ours from the next hello (§3, round 2).
function I.SplitSharedKey(id, theirGuid)
    local mine = PlayerGuid()
    if not mine or not theirGuid or mine >= theirGuid then return end
    local old = S.key
    S.key, S.keyAt = I.Entropy("split"):sub(1, 32), GetServerTime()
    for _, t in ipairs((I.Stores())) do
        if Writable(t) then
            Stamp(t)
            t.key, t.keyAt = S.key, S.keyAt
        end
    end
    I.Trust(old)   -- now theirs alone
    I.Report("Your accounts shared one household key (a copied settings folder); this one made a new key.",
             "warning")
    I.SendHello(id, "now")
end

-- Our game and region as last known: from the store with the newest selfAt.
function I.SavedSelf()
    local project, region, at
    for _, t in ipairs((I.Stores())) do
        if type(t.selfAt) == "number" and (not at or t.selfAt > at)
            and type(t.selfProject) == "number" and type(t.selfRegion) == "number" then
            project, region, at = t.selfProject, t.selfRegion, t.selfAt
        end
    end
    return project, region
end

function I.SaveSelf(project, region)
    local now = time()
    for _, t in ipairs((I.Stores())) do
        if Writable(t) and (t.selfProject ~= project or t.selfRegion ~= region) then
            Stamp(t)
            t.selfProject, t.selfRegion, t.selfAt = project, region, now
        end
    end
end

-- Monotonic stream ids, kept in the store so a same-second /reload can't go
-- back (§5.2, round 3). No counter to exhaust: past 1000 sends a second the id
-- runs ahead of the clock and stays monotonic.
function I.NextSid()
    I.SyncStores()
    local sid = math.max(GetServerTime() * 1000, S.lastSid + 1)
    S.lastSid = sid
    for _, t in ipairs((I.Stores())) do
        if Writable(t) then Stamp(t); t.lastSid = sid end
    end
    return sid
end

--------------------------------------------------------------------------------
-- Entropy (§5.2)
--------------------------------------------------------------------------------

function I.Entropy(extra)
    S.entropy = S.entropy + 1
    return SHA256(table.concat({ tostring(extra or ""), S.entropy, time(), GetServerTime(),
        tostring(GetTime()), tostring(debugprofilestop()), tostring(PlayerGuid() or ""),
        math.random(0, 65535), math.random(0, 65535), fastrandom(0, 65535), fastrandom(0, 65535),
        tostring({}) }, "|"))
end

--------------------------------------------------------------------------------
-- Who is ours (§5.1, §5.2)
--------------------------------------------------------------------------------

-- Usable at all: the APIs exist, Battle.net is up, some host is enabled.
function I.Active()
    if not (C_BattleNet and C_BattleNet.GetGameAccountInfoByID and C_BattleNet.GetAccountInfoByGUID) then
        return false
    end
    local ok, up = pcall(BNFeaturesEnabledAndConnected)
    if not ok or IsSecret(up) or not up then return false end
    for _, inst in ipairs(lib.instances) do
        if I.IsEnabled(inst) then return true end
    end
    return false
end

-- Who we are: { tag, account (only from GetAccountInfoByGUID), game, project,
-- region }, or nil. Our presence can be blank for a long time; the BattleTag
-- also comes from BNGetInfo, and game and region from the store (§5.1).
function I.Self()
    local s = {}
    local guid = PlayerGuid()
    local acct = guid and I.AcctRec(guid)
    if acct and not acct.unknown then
        s.tag, s.account = acct.battleTag, acct.bnetAccountID
        local g = acct.game or {}
        s.game, s.project, s.region = g.gameAccountID, g.wowProjectID, g.regionID
    end
    if s.tag == nil then
        local ok, _, tag = pcall(BNGetInfo)
        if ok and not IsSecret(tag) and type(tag) == "string" and tag ~= "" then s.tag = tag end
    end
    if s.project == nil and guid then
        local g = I.GameRecByGuid(guid)
        if g and not g.unknown then
            s.project, s.region = g.wowProjectID, s.region or g.regionID
            s.game = s.game or g.gameAccountID
        end
    end
    if type(s.project) == "number" and type(s.region) == "number" then
        I.SaveSelf(s.project, s.region)
    else
        s.project, s.region = I.SavedSelf()
    end
    if type(s.tag) ~= "string" or s.tag == "" then s.tag = nil end
    if s.tag == nil and s.account == nil then return nil end
    return s
end

-- Ownership by BattleTag; by account id only when both ids came from
-- GetAccountInfoByGUID (BNGetInfo's presenceID may be another namespace).
local function IsOurs(acct, me)
    if not acct or acct.unknown or not me then return false end
    if me.tag ~= nil and acct.battleTag == me.tag then return true end
    if me.account ~= nil and acct.bnetAccountID ~= nil and acct.bnetAccountID == me.account then return true end
    return false
end

-- THE eligibility test (AltStable Core.lua 628-659): the game record behind
-- `id` when it is a character of this game, online, in this region, on our
-- own Battle.net account, and not us. Else nil and why (for Diagnostics).
function I.OwnAccountGame(id, me)
    if type(id) ~= "number" then return nil, "no id" end
    if not I.Active() then return nil, "off, or Battle.net not connected" end
    local g = I.GameRec(id)
    if not g then return nil, "unknown id" end
    if g.unknown then return nil, "a field is secret (unknown)" end
    if not g.isOnline then return nil, "offline" end
    if g.clientProgram ~= "WoW" then return nil, "not WoW" end
    if g.isInCurrentRegion == false then return nil, "another region" end
    if type(g.characterName) ~= "string" or g.characterName == "" then return nil, "no character name" end
    if not IsGuid(g.playerGuid) then return nil, "no character GUID" end
    if g.playerGuid == PlayerGuid() then return nil, "this character" end
    me = me or I.Self()
    if not me then return nil, "our Battle.net identity is not known yet" end
    if me.project == nil or me.region == nil then
        return nil, "our own game or region is not known yet (our presence is blank)"
    end
    if g.wowProjectID ~= me.project then return nil, "another game" end
    -- Region fails closed (AltStable skipped it on nil). A record without a
    -- regionID falls back to Battle.net's own "same region" flag (§5.2).
    if g.regionID ~= nil then
        if g.regionID ~= me.region then return nil, "another region" end
    elseif g.isInCurrentRegion ~= true then
        return nil, "region not known"
    end
    if not IsOurs(I.AcctRec(g.playerGuid), me) then return nil, "someone else's Battle.net account" end
    return g
end

-- Every friend's game account id, or nil when that cannot be known in full.
-- Fail closed (AltStable Core.lua 682-710): a gap would make a friend "ours".
function I.FriendGameIDs()
    if not (BNGetNumFriends and C_BattleNet.GetFriendNumGameAccounts and C_BattleNet.GetFriendGameAccountInfo) then
        return nil
    end
    if (time() - S.upSince) < FRIENDS_SETTLE then return nil end
    local ok, n = pcall(BNGetNumFriends)
    if not ok or IsSecret(n) or type(n) ~= "number" then return nil end
    local ids = {}
    for i = 1, n do
        local okN, m = pcall(C_BattleNet.GetFriendNumGameAccounts, i)
        if not okN or IsSecret(m) or type(m) ~= "number" then return nil end
        for j = 1, m do
            local okG, raw = pcall(C_BattleNet.GetFriendGameAccountInfo, i, j)
            local gi = okG and Copy(raw, GAME_FIELDS)
            if not gi or gi.unknown or type(gi.gameAccountID) ~= "number" then return nil end
            ids[gi.gameAccountID] = true
        end
    end
    return ids
end

-- A HINT only (AltStable Core.lua 712-726): an online id with a blank
-- presence that is in no friend's list. Where a keyless hello may go; never
-- trust, never data.
function I.OwnByElimination(id, me, friends)
    if type(id) ~= "number" or not I.Active() then return false end
    local g = I.GameRec(id)
    if not g or g.unknown or g.isOnline == false then return false end
    if type(g.characterName) == "string" and g.characterName ~= "" then return false end
    if g.playerGuid ~= nil and g.playerGuid ~= "" then return false end
    if g.clientProgram ~= nil and g.clientProgram ~= "WoW" then return false end
    me = me or I.Self()
    if me and me.game == id then return false end
    friends = friends or I.FriendGameIDs()
    if not friends or friends[id] then return false end
    return true
end

-- The sender record a host sees, from a verified record.
local function PeerFromGame(id, g)
    return { id = id, guid = g.playerGuid, name = g.characterName,
             realm = g.realmName or g.realmDisplayName, faction = g.factionName, proven = "bnet" }
end

-- The binding for an id right now: Battle.net's word, or a hello proven this
-- session while that id is still online and still blank. Else nil.
function I.GameFor(id, me, friends)
    local g = I.OwnAccountGame(id, me)
    if g then
        S.learned[id] = nil      -- Battle.net speaks for this id now
        return PeerFromGame(id, g)
    end
    local l = S.learned[id]
    if not l then return nil end
    local rec = I.GameRec(id)
    if not rec or rec.unknown or rec.isOnline == false
        or (type(rec.characterName) == "string" and rec.characterName ~= "") then
        I.ForgetId(id)           -- gone, or no longer blank: Battle.net decides now
        return nil
    end
    return { id = id, guid = l.guid, name = l.name, realm = l.realm, faction = l.faction, proven = l.proven }
end

-- Forget everything an id told us: it went offline, its binding changed, or
-- Battle.net contradicts it. Whoever comes back proves itself afresh.
function I.ForgetId(id)
    S.learned[id], S.helloSent[id], S.myNonce[id], S.theirNonce[id] = nil, nil, nil, nil
    S.answered[id], S.proofChecks[id], S.pendingKeys[id] = nil, nil, nil
    S.routeChecked[id] = nil
    for key, buf in pairs(S.buffers) do
        if buf.id == id then S.buffers[key] = nil end
    end
end

function I.WipeSession()
    for _, k in ipairs({ "peers", "learned", "myNonce", "theirNonce", "helloSent", "answered", "buffers",
                         "routeChecked", "proofChecks", "pendingKeys" }) do
        wipe(S[k])
    end
end

--------------------------------------------------------------------------------
-- Hello and proof (§5.1)
--------------------------------------------------------------------------------

function I.NonceFor(id)
    if not S.myNonce[id] then S.myNonce[id] = I.Entropy("nonce|" .. id):sub(1, 16) end
    return S.myNonce[id]
end

-- Written by role: the SENDER's key, name, GUID and realm, answering the
-- RECEIVER's nonce. The receiver fills in its own project and region.
function I.Proof(key, receiverNonce, senderNonce, name, guid, realm, project, region)
    return HMAC256(key, HELLO_DOMAIN .. receiverNonce .. "|" .. senderNonce .. "|" .. (Short(name) or "")
        .. "|" .. guid .. "|" .. realm .. "|" .. tostring(project) .. "|" .. tostring(region)):sub(1, 32)
end

function I.Mac(key, receiverNonce, senderGuid, project, region, tag, sid, n, hash)
    return HMAC256(key, DATA_DOMAIN .. receiverNonce .. "|" .. senderGuid .. "|" .. tostring(project) .. "|"
        .. tostring(region) .. "|" .. tag .. "|" .. sid .. "|" .. tostring(n) .. "|" .. hash):sub(1, 32)
end

-- ChatThrottleLib's Battle.net path, or nil: without it we fail closed (§6).
local function CTL()
    local ctl = ChatThrottleLib
    if type(ctl) == "table" and type(ctl.BNSendGameData) == "function" then return ctl end
    I.ReportOnce("noctl", "ChatThrottleLib v32 or newer is missing: LibAccountSync sends nothing.", "error")
    return nil
end

-- Tell an id who we are. `how`:
--   nil       at most once a minute per id (scans);
--   "soon"    at most once per HELLO_FLOOR seconds (a Send that needs a nonce);
--   "answer"  at once, the first time we answer THIS nonce of theirs, within a
--             per-id budget: the handshake needs our proof straight back, and
--             our nonce is stable, so two answers can't ping-pong;
--   "now"     at once (our key changed).
function I.SendHello(id, how)
    local now = time()
    local last = S.helloSent[id]
    local a
    if how == "answer" then
        a = S.answered[id]
        if a and a.nonce == S.theirNonce[id] then return end
        if a and (now - a.since) < 60 and a.count >= ANSWERS_PER_MINUTE then return end
        if not a or (now - a.since) >= 60 then a = { since = now, count = 0 } end
    elseif how ~= "now" then
        if last and (now - last) < (how == "soon" and HELLO_FLOOR or HELLO_EVERY) then return end
    end
    local K = I.OwnKey()
    local me = I.Self()
    local name, guid = PlayerName(), PlayerGuid()
    if not K or not me or me.project == nil or me.region == nil or not name or not IsGuid(guid) then return end
    local ctl = CTL()
    if not ctl then return end
    local realm = Plain(GetRealmName()) or ""
    local faction = Plain((UnitFactionGroup("player"))) or ""
    if not IsField(name, 48) or not IsField(realm, 64) or not IsField(faction, 16) then return end
    -- The household key goes only to an id Battle.net verifies as ours.
    local key = I.OwnAccountGame(id, me) and K or ""
    local nonce = I.NonceFor(id)
    local theirs = S.theirNonce[id]
    local proof = theirs and I.Proof(K, theirs, nonce, name, guid, realm, me.project, me.region) or ""
    local msg = table.concat({ "H" .. WIRE, tostring(WIRE), name, guid, faction, realm, key, nonce, proof }, "|")
    if #msg > MAX_MESSAGE then
        I.ReportOnce("hellolen", "LibAccountSync: hello too long, not sent.", "error")
        return
    end
    -- Counted as sent (and as this nonce's answer) only once it is queued;
    -- a send that fails undoes both, so the next hello is answered again.
    S.helloSent[id] = now
    if a then
        a.count, a.nonce = a.count + 1, theirs
        S.answered[id] = a
    end
    local ok = pcall(ctl.BNSendGameData, ctl, "ALERT", PREFIX, msg, "WHISPER", id, PREFIX .. id,
        function(_, didSend)
            if not Ready() then return end
            return lib.impl.OnHelloSent(id, now, didSend)
        end)
    if not ok then I.OnHelloSent(id, now, false) end
end

function I.OnHelloSent(id, stamp, didSend)
    if didSend ~= false or S.helloSent[id] ~= stamp then return end
    S.helloSent[id] = nil
    if S.answered[id] then S.answered[id].nonce = nil end
end

-- Split a frame on "|", at most `max` fields; extra trailing fields of a
-- hello are ignored, so a hello can grow without a new wire (§2).
local function Fields(text, max)
    local out, pos = {}, 1
    while #out < max do
        local i = text:find("|", pos, true)
        if not i then out[#out + 1] = text:sub(pos); break end
        out[#out + 1] = text:sub(pos, i - 1)
        pos = i + 1
    end
    return out
end

-- Each proof check costs up to TRUST_CAP HMACs: bounded per id, as answers are.
function I.ProofBudget(id)
    local now = time()
    local b = S.proofChecks[id]
    if not b or (now - b.since) >= 60 then b = { since = now, count = 0 }; S.proofChecks[id] = b end
    if b.count >= PROOF_CHECKS_PER_MINUTE then return false end
    b.count = b.count + 1
    return true
end

function I.OnHello(id, text)
    local f = Fields(text, 9)
    local name, guid, faction, realm, key, nonce, proof = f[3], f[4], f[5], f[6], f[7], f[8], f[9]
    if not IsDigits(f[2], 3) then return end
    if not IsField(name, 48) or name == "" or name:find("-", 1, true)
        or not IsField(faction or "", 16) or not IsField(realm or "", 64) then
        return
    end
    guid, faction, realm = guid or "", faction or "", realm or ""
    key, proof = key or "", proof or ""
    if not IsHex(nonce, 16) then return end
    if key ~= "" and not ValidKey(key) then return end
    if proof ~= "" and not IsHex(proof, 32) then return end
    if guid ~= "" and not IsGuid(guid) then return end
    if Short(name) == Short(PlayerName()) then return end         -- our own name
    if nonce == S.myNonce[id] then return end                     -- reflection
    local me = I.Self()
    local g = I.OwnAccountGame(id, me)
    -- Battle.net knows them: the hello must agree with it, checked BEFORE
    -- anything is kept (a delayed hello from the character that was there
    -- before must not replace the current one's nonce, Codex round 2 of r1).
    if g and (Short(g.characterName) ~= Short(name) or (guid ~= "" and guid ~= g.playerGuid)) then return end
    local friends = not g and I.FriendGameIDs() or nil
    local hinted = not g and I.OwnByElimination(id, me, friends)
    -- Their nonce is kept only from an id that is ours, a hint, or proven
    -- this session (AltStable stored it from anyone, Core.lua 3483).
    local fresh = nonce ~= S.theirNonce[id]
    if fresh and (g or hinted or S.learned[id]) then S.theirNonce[id] = nonce end
    local peer
    if g then
        if S.peers[id] and S.peers[id].guid ~= g.playerGuid then S.routeChecked[id] = nil end
        if key ~= "" then
            local own = I.OwnKey()
            if not own then
                -- Our key isn't chosen yet (a store still loading): it might
                -- BE this key (a shared one). Decide once it is chosen.
                S.pendingKeys[id] = { key = key, guid = g.playerGuid }
            elseif key == own then
                I.SplitSharedKey(id, g.playerGuid)
            else
                I.Trust(key)
            end
        end
        peer = PeerFromGame(id, g)
    elseif hinted or S.myNonce[id] then
        -- Presence blank: believed only on a trusted key or a proof, and only
        -- from an id we have a reason to talk to (§5.2): never from any id.
        local via, how
        if key ~= "" and I.KeyTrusted(key) then
            via, how = key, "key"
        elseif proof ~= "" and S.myNonce[id] and me and me.project and me.region and IsGuid(guid)
            and I.ProofBudget(id) then
            for k in pairs(I.TrustUnion()) do
                if I.Proof(k, S.myNonce[id], nonce, name, guid, realm, me.project, me.region) == proof then
                    via, how = k, "proof"
                    break
                end
            end
        end
        if via and IsGuid(guid) and guid ~= PlayerGuid() then
            -- Another character on this account replaces the learned one.
            -- Its buffers stay: they may be the new character's own stream,
            -- and the MAC binds the GUID this hello proves.
            I.Trust(via)                                           -- refresh lastSeen
            S.theirNonce[id] = nonce
            S.learned[id] = { name = name, guid = guid, faction = faction ~= "" and faction or nil,
                              realm = realm ~= "" and realm or nil, proven = how }
            peer = I.GameFor(id, me, friends)
        end
    end
    if not peer then
        -- Not proven yet. A hint: answer its nonce; our proof is what lets it
        -- believe us, and its next hello answers ours.
        -- A peer proven earlier this session that reloaded is answered too,
        -- or it never gets our nonce while the friends list fails closed.
        -- "answer" itself skips a nonce already answered (and sent).
        if hinted or S.learned[id] then I.SendHello(id, "answer") end
        return
    end
    S.peers[id] = peer
    -- Answered even for a peer we know: it may have reloaded and forgotten us.
    I.SendHello(id, "answer")
    I.RecheckAwaiting(id)
end

--------------------------------------------------------------------------------
-- Discovery (AltStable Core.lua 2565-2665)
--------------------------------------------------------------------------------

function I.ScanAgainSoon()
    if S.settlePending or S.settleTries >= SETTLING_TRIES then return end
    S.settlePending = true
    S.settleTries = S.settleTries + 1
    C_Timer.After(SETTLING_EVERY, function()
        S.settlePending = false
        if not Ready() then return end
        return lib.impl.Scan()
    end)
end

function I.RequestScan()
    if S.scanPending then return end
    S.scanPending = true
    C_Timer.After(2, function()
        S.scanPending = false
        if not Ready() then return end
        return lib.impl.Scan()
    end)
end

function I.Scan()
    S.lastScan = time()
    if not S.loggedIn then return end
    if not I.RegisterPrefix() then
        I.ReportOnce("prefix", "LibAccountSync: the addon-message prefix could not be registered; nothing arrives.", "error")
    end
    if not I.Active() then I.WipeSession(); return end
    -- Settles the key (and any keys waiting on it) once every store resolves,
    -- and brings a store that resolved later (load-on-demand) in line.
    if I.OwnKey() then I.SyncStores() end
    for id in pairs(S.learned) do
        local g = I.GameRec(id)
        if not g or g.unknown or g.isOnline == false then I.ForgetId(id) end
    end
    local me = I.Self()
    local settling = not me or me.project == nil or me.region == nil
    local friends = I.FriendGameIDs()
    local fresh, hinted = {}, {}
    for id = 1, MAX_ID do
        local p = I.GameFor(id, me, friends)
        if p then
            fresh[id] = p
        elseif I.OwnByElimination(id, me, friends) then
            hinted[id] = true
            I.SendHello(id)
            settling = true
        elseif not settling then
            local rec = I.GameRec(id)
            if rec and not rec.unknown and rec.clientProgram == "WoW" and rec.isOnline ~= false
                and (type(rec.characterName) ~= "string" or rec.characterName == "") then
                settling = true                -- still logging in
            end
        end
    end
    -- Learned beyond the walk, while it still checks out.
    for id in pairs(S.peers) do
        if not fresh[id] and id > MAX_ID then
            local p = I.GameFor(id, me, friends)
            if p then fresh[id] = p end
        end
    end
    -- A binding that changed or went: its buffers and nonces go with it.
    local known = {}
    for id, old in pairs(S.peers) do
        local now = fresh[id]
        if not now or now.guid ~= old.guid then I.ForgetId(id) else known[id] = true end
    end
    wipe(S.peers)
    for id, p in pairs(fresh) do
        S.peers[id] = p
        -- A hello to a new binding, or one whose nonce we still lack (as
        -- AltStable's OnNewPresence): not to every peer every minute.
        if not known[id] or not S.theirNonce[id] then I.SendHello(id) end
    end
    -- A nonce we gave an id that is positively not ours now (offline, or a
    -- presence that filled in as someone else's) goes, and with it the right
    -- to buffer. A friends list failing closed proves nothing: kept.
    for id in pairs(S.myNonce) do
        if not fresh[id] then
            local rec = I.GameRec(id)
            if not rec or rec.isOnline == false
                or (not rec.unknown and type(rec.characterName) == "string" and rec.characterName ~= "") then
                I.ForgetId(id)
            end
        end
    end
    if settling then I.ScanAgainSoon() else S.settleTries = 0 end
end

-- Right before a send: the binding still holds (2 s cache, as AltStable's
-- BNetRoute). If not, it is dropped and a rescan asked for.
function I.Route(id)
    local p = S.peers[id]
    if not p then return nil end
    local now = time()
    if S.routeChecked[id] and (now - S.routeChecked[id]) <= ROUTE_CACHE then return p end
    local g = I.GameFor(id)
    if not g or g.guid ~= p.guid then
        S.peers[id] = nil
        I.ForgetId(id)
        I.RequestScan()
        return nil
    end
    S.peers[id] = g
    S.routeChecked[id] = now
    return g
end

--------------------------------------------------------------------------------
-- Sending (§1, §2, §5.3)
--------------------------------------------------------------------------------

local function SenderCopy(p)
    return { guid = p.guid, name = p.name, realm = p.realm, faction = p.faction, proven = p.proven }
end

function I.Result(inst, onResult, p, status, reason)
    if type(onResult) ~= "function" then return end
    local ok, err = pcall(onResult, SenderCopy(p), status, reason)
    if not ok then I.Report("LibAccountSync: onResult error: " .. tostring(err), "error", inst) end
end

function I.Send(inst, payload, onResult)
    if not I.IsEnabled(inst) or not I.Active() or not S.loggedIn then return nil, "disabled" end
    if type(payload) ~= "string" then error("LibAccountSync: Send(payload): payload must be a string", 2) end
    if #payload > inst.maxPayload then return nil, "too-large" end
    local ctl = CTL()
    if not ctl then return nil, "no-route" end
    local K = I.OwnKey()
    local me = I.Self()
    local guid = PlayerGuid()
    if not K or not me or me.project == nil or me.region == nil or not IsGuid(guid) then return nil, "not-ready" end
    local dests, waiting = {}, 0
    -- A snapshot: onResult below is host code, and may rescan.
    local ids = {}
    for id in pairs(S.peers) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do
        local p = I.Route(id)
        if p then
            if S.theirNonce[id] then
                dests[#dests + 1] = { peer = p, nonce = S.theirNonce[id] }
            else
                waiting = waiting + 1
                I.Result(inst, onResult, p, "failed", "not-ready")
                I.SendHello(id, "soon")
            end
        end
    end
    if #dests == 0 and waiting == 0 then return nil, "no-peers" end
    if #dests == 0 then return 0 end

    local enc = Encode(payload)
    local bodies = { enc:sub(1, BODY_FIRST) }
    local pos = BODY_FIRST + 1
    while pos <= #enc do
        bodies[#bodies + 1] = enc:sub(pos, pos + BODY_REST - 1)
        pos = pos + BODY_REST
    end
    local n = #bodies
    local hash = SHA256(payload)
    -- One text form on both sides of the MAC: 13 digits, never "1.7e+12".
    local sid = ("%.0f"):format(I.NextSid())
    local tag = inst.addon
    for _, d in ipairs(dests) do
        local p, id = d.peer, d.peer.id
        local mac = I.Mac(K, d.nonce, guid, me.project, me.region, tag, sid, n, hash)
        local track = { inst = inst, onResult = onResult, peer = p, remaining = n }
        for i = 1, n do
            local frame = table.concat({ "D" .. WIRE, tag, sid, tostring(i), tostring(n),
                                         i == 1 and mac or "-", bodies[i] }, "|")
            local ok = pcall(ctl.BNSendGameData, ctl, "NORMAL", PREFIX, frame, "WHISPER", id, PREFIX .. id,
                function(arg, didSend, result)
                    if not Ready() then return end
                    return lib.impl.OnChunkSent(arg, didSend, result)
                end, track)
            if not ok then I.OnChunkSent(track, false, nil) end
            if track.done and i < n then break end      -- failed: the rest would go nowhere
        end
    end
    return #dests
end

local RESULT_OFFLINE, RESULT_TARGET_REQUIRED = 12, 6

function I.OnChunkSent(track, didSend, result)
    if track.done then return end
    if didSend == false then
        track.done = true
        local reason = "no-route"
        if result == RESULT_OFFLINE or result == RESULT_TARGET_REQUIRED then
            reason = "offline"
            local id = track.peer.id
            if S.peers[id] and S.peers[id].guid == track.peer.guid then
                S.peers[id] = nil
                I.ForgetId(id)
            end
            I.RequestScan()
        end
        I.Result(track.inst, track.onResult, track.peer, "failed", reason)
        return
    end
    track.remaining = track.remaining - 1
    if track.remaining <= 0 then
        track.done = true
        I.Result(track.inst, track.onResult, track.peer, "sent")
    end
end

--------------------------------------------------------------------------------
-- Receiving (§2, §5.3)
--------------------------------------------------------------------------------

function I.OnData(id, text)
    -- The body is everything after the sixth "|": never split it (round 3).
    local tag, sid, i, n, mac, body = text:match("^D1|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if not tag or not IsTag(tag) or not IsDigits(sid, 13) or not IsDigits(i, 3) or not IsDigits(n, 3) then return end
    i, n = tonumber(i), tonumber(n)
    if i < 1 or i > n or n > MAX_CHUNKS then return end
    if i == 1 and not IsHex(mac, 32) then return end
    local inst = lib.byTag[tag]
    if not inst or not I.IsEnabled(inst) then return end
    local key = id .. "|" .. tag .. "|" .. sid
    if S.finished[key] or S.refused[key] then return end
    local buf = S.buffers[key]
    if not buf then
        -- Admission: a binding we hold, or an id we have sent our nonce to
        -- (a blank peer whose last hello is still on its way).
        local p = I.GameFor(id)
        -- Not admitted: dropped, not remembered, so a stranger's flood can't
        -- grow the refused table.
        if not p and not S.myNonce[id] then return end
        local perId, total, bytes = 0, 0, 0
        for _, b in pairs(S.buffers) do
            total = total + 1
            bytes = bytes + b.bytes
            if b.id == id then perId = perId + 1 end
        end
        if perId >= STREAMS_PER_ID then
            -- Snapshots are wholesale and sids monotonic: a newer stream
            -- supersedes the sender's oldest, never the other way round.
            local oldKey, oldSid
            for k, b in pairs(S.buffers) do
                if b.id == id and (not oldSid or b.sid < oldSid) then oldKey, oldSid = k, b.sid end
            end
            if oldSid and oldSid < tonumber(sid) then
                S.buffers[oldKey] = nil
                total, perId = total - 1, perId - 1
            end
        end
        if perId >= STREAMS_PER_ID or total >= STREAMS_TOTAL then S.refused[key] = time(); return end
        buf = { id = id, tag = tag, sid = tonumber(sid), sidText = sid, n = n, chunks = {}, have = 0,
                bytes = 0, last = time(), verified = p and p.proven == "bnet", peer = p }
        S.buffers[key] = buf
        I.ArmSettle(key, buf)
    end
    if buf.complete or buf.n ~= n or buf.chunks[i] then return end
    local bytes = 0
    for _, b in pairs(S.buffers) do bytes = bytes + b.bytes end
    if bytes + #body > BUFFER_BYTES then
        S.buffers[key] = nil
        S.refused[key] = time()
        return
    end
    buf.chunks[i] = body
    buf.have, buf.bytes, buf.last = buf.have + 1, buf.bytes + #body, time()
    if i == 1 then buf.mac = mac end
    if buf.have == buf.n then I.Complete(key, buf) end
end

-- A stream with no chunk for STREAM_SETTLE seconds is dropped; one complete
-- and awaiting its hello is dropped after AWAIT_HELLO (§5.3).
function I.ArmSettle(key, buf)
    local wait = buf.complete and AWAIT_HELLO or STREAM_SETTLE
    C_Timer.After(wait, function()
        if not Ready() then return end
        return lib.impl.Settle(key, buf)
    end)
end

function I.Settle(key, buf)
    if S.buffers[key] ~= buf then return end
    local now = time()
    if buf.complete then
        if I.TryDeliver(key, buf) then return end          -- Battle.net may vouch for it now
        if now >= buf.awaitUntil then S.buffers[key] = nil else I.ArmSettle(key, buf) end
        return
    end
    if (now - buf.last) >= STREAM_SETTLE then S.buffers[key] = nil else I.ArmSettle(key, buf) end
end

function I.Complete(key, buf)
    local inst = lib.byTag[buf.tag]
    if not inst then S.buffers[key] = nil; return end
    local payload = Decode(table.concat(buf.chunks, "", 1, buf.n))
    if not payload or #payload > inst.maxPayload then
        S.buffers[key], S.refused[key] = nil, time()
        return
    end
    buf.payload, buf.chunks, buf.complete = payload, {}, true
    if not I.TryDeliver(key, buf) then
        buf.awaitUntil = time() + AWAIT_HELLO
        I.ArmSettle(key, buf)
    end
end

-- A sender verified by Battle.net (at admission or now) is believed as is.
-- Anyone else needs a proven hello now AND a MAC under a trusted key with our
-- current nonce and the GUID that hello proved (§5.3, round 3).
function I.TryDeliver(key, buf)
    local id = buf.id
    local now = I.GameFor(id)
    local was = buf.peer                  -- the binding when the stream was admitted
    local sender
    if was and was.proven == "bnet" and (not now or now.guid == was.guid) then
        -- Battle.net vouched for this character when its stream began, and
        -- it is still the one there (or has logged out since: send, then log
        -- out, still delivers).
        sender = now or was
    elseif now and now.proven == "bnet" and (not was or was.guid == now.guid) then
        -- Verified now, and either unbound when the stream began (a blank
        -- first contact: no earlier character's floor to slip under) or
        -- guessed then as this same character (§5.3, Codex r1 round 3).
        sender = now
    elseif now and S.myNonce[id] and buf.mac then
        -- Anything else (a character change on that account since the stream
        -- began, a binding we only guessed) is decided by the MAC, bound to the
        -- character the account shows NOW: an older character's stream can't
        -- be passed off as the new one's (Codex round 2 of r1).
        local me = I.Self()
        if not me or me.project == nil or me.region == nil then return false end
        local hash = SHA256(buf.payload)
        for k in pairs(I.TrustUnion()) do
            if I.Mac(k, S.myNonce[id], now.guid, me.project, me.region, buf.tag, buf.sidText, buf.n, hash) == buf.mac then
                I.Trust(k)
                sender = now
                break
            end
        end
        -- A MAC that fails may mean a stale binding (another character on
        -- that account, its hello still on the way): wait for the hello,
        -- dropped when the wait runs out.
        if not sender then return false end
    else
        return false
    end
    S.buffers[key] = nil
    S.finished[key] = time()
    -- Monotonic per (tag, sender GUID): an older snapshot never lands after a
    -- newer one, reordered or replayed under another id (§5.2).
    local floorKey = buf.tag .. "|" .. tostring(sender.guid)
    if S.floors[floorKey] and buf.sid <= S.floors[floorKey] then return true end
    S.floors[floorKey] = buf.sid
    local inst = lib.byTag[buf.tag]
    if inst and type(inst.handler) == "function" and I.IsEnabled(inst) then
        local ok, err = pcall(inst.handler, buf.payload, SenderCopy(sender), buf.sid)
        if not ok then I.Report("LibAccountSync: message handler error: " .. tostring(err), "error", inst) end
    end
    return true
end

function I.RecheckAwaiting(id)
    for key, buf in pairs(S.buffers) do
        if buf.id == id and buf.complete then I.TryDeliver(key, buf) end
    end
end

function I.Sweep()
    local now = time()
    for key, buf in pairs(S.buffers) do
        if (now - buf.last) > 120 then S.buffers[key] = nil end
    end
    for key, at in pairs(S.finished) do if (now - at) > 30 then S.finished[key] = nil end end
    for key, at in pairs(S.refused) do if (now - at) > 120 then S.refused[key] = nil end end
end

--------------------------------------------------------------------------------
-- Events and the ticker
--------------------------------------------------------------------------------

function I.Login()
    if S.loggedIn then return end
    S.loggedIn = true
    S.upSince = time()
    C_Timer.After(5, function()
        if not Ready() then return end
        return lib.impl.Scan()
    end)
end

function I.OnEvent(event, ...)
    if event == "BN_CHAT_MSG_ADDON" then
        local prefix, text, _, senderID = ...
        if IsSecret(prefix) or IsSecret(text) or IsSecret(senderID) or prefix ~= PREFIX then return end
        if type(text) ~= "string" or type(senderID) ~= "number" or not S.loggedIn or not I.Active() then return end
        local kind = text:sub(1, 3)
        if kind == "H1|" then return I.OnHello(senderID, text) end
        if kind == "D1|" then return I.OnData(senderID, text) end
        return                                 -- unknown frame types are ignored (§2)
    elseif event == "PLAYER_LOGIN" then
        I.Login()
    elseif event == "BN_DISCONNECTED" then
        I.WipeSession()
        S.upSince = time()                     -- the friends list reloads (§5.2)
    elseif event == "BN_CONNECTED" then
        S.upSince = time()
        I.RequestScan()
    elseif event == "BN_INFO_CHANGED" then
        I.RequestScan()
    end
end

function I.Tick()
    I.Sweep()
    if S.loggedIn then I.Scan() end
end

-- One frame and one ticker for the library's life; never recreated, and their
-- closures dispatch at call time (§4).
if not lib.frame then
    lib.frame = CreateFrame("Frame")
    lib.frame:SetScript("OnEvent", function(_, event, ...)
        if lib.ready == nil or lib.ready ~= select(2, LibStub:GetLibrary(MAJOR, true)) then return end
        return lib.impl.OnEvent(event, ...)
    end)
end
for _, event in ipairs({ "PLAYER_LOGIN", "BN_CHAT_MSG_ADDON", "BN_CONNECTED", "BN_DISCONNECTED",
                         "BN_INFO_CHANGED" }) do
    pcall(lib.frame.RegisterEvent, lib.frame, event)
end
if not lib.ticker then
    lib.ticker = C_Timer.NewTicker(60, function()
        if lib.ready == nil or lib.ready ~= select(2, LibStub:GetLibrary(MAJOR, true)) then return end
        return lib.impl.Tick()
    end)
end
-- RegisterAddonMessagePrefix answers an enum (0 = Success) rather than
-- throwing; a refusal is retried on every scan and reported once.
function I.RegisterPrefix()
    if lib.prefixRegistered then return true end
    local ok, r = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    if ok and not IsSecret(r) and (r == nil or r == true or r == 0) then lib.prefixRegistered = true end
    return lib.prefixRegistered
end
I.RegisterPrefix()

--------------------------------------------------------------------------------
-- Instances (§1)
--------------------------------------------------------------------------------

function I.OnMessage(inst, fn)
    if fn ~= nil and type(fn) ~= "function" then error("LibAccountSync: OnMessage(fn): fn must be a function", 2) end
    inst.handler = fn
end

function I.Peers()
    local out = {}
    for _, p in pairs(S.peers) do out[#out + 1] = SenderCopy(p) end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

function I.Rescan()
    if S.loggedIn then I.Scan() end
end

-- A switch flipped this session wins (a newer store may be read-only); else
-- the host's store; else on.
function I.IsEnabled(inst)
    if inst.enabled ~= nil then return inst.enabled end
    local ok, t = pcall(inst.getStore)
    if ok and type(t) == "table" and t.enabled ~= nil then return t.enabled ~= false end
    return true
end

function I.SetEnabled(inst, on)
    on = on and true or false
    inst.enabled = on
    local ok, t = pcall(inst.getStore)
    if ok and type(t) == "table" and Writable(t) then Stamp(t); t.enabled = on end
    if not I.Active() then I.WipeSession() elseif on then I.RequestScan() end
end

-- What /alts bnet showed: the state and each id's why or why not. Never a
-- key; nonces cut to 4 characters.
function I.Diagnostics(inst)
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    local me = I.Self()
    add(("LibAccountSync-1.0 r%d, wire %d; this host %s, %s"):format(MINOR, WIRE, inst.addon,
        I.IsEnabled(inst) and "enabled" or "disabled"))
    add("Battle.net: " .. (I.Active() and "usable" or "not usable (off, or not connected)"))
    if me then
        add(("us: %s, project %s, region %s"):format(me.tag or "?", tostring(me.project), tostring(me.region)))
    else
        add("us: not known yet")
    end
    add("friends list: " .. (I.FriendGameIDs() and "settled" or "not settled (fails closed)"))
    local trusted = 0
    for _ in pairs(I.TrustUnion()) do trusted = trusted + 1 end
    add(("household key: %s; %d trusted"):format(S.key and "chosen" or "not chosen yet", trusted))
    for id = 1, MAX_ID do
        local rec = I.GameRec(id)
        if rec and (rec.unknown or rec.clientProgram == "WoW") then
            local p = I.GameFor(id, me)
            local _, why = I.OwnAccountGame(id, me)
            local state
            if p then
                state = ("%s (%s)%s"):format(tostring(p.name), p.proven,
                    S.theirNonce[id] and "" or ", no nonce yet")
            elseif I.OwnByElimination(id, me) then
                state = "blank, ours by elimination (a hint): hello sent"
            else
                state = "not ours: " .. tostring(why)
            end
            local n = S.myNonce[id]
            add(("  id %d: %s%s"):format(id, state, n and (" [nonce " .. n:sub(1, 4) .. "]") or ""))
        end
    end
    local k = 0
    return function()
        k = k + 1
        return lines[k]
    end
end

-- What an inert instance answers (§1): still the right shape for the calls a
-- host iterates or measures (Peers a table, Diagnostics an iterator), so
-- someone else's broken copy can't throw inside the host.
function lib.Inert(name)
    if name == "Peers" then return {} end
    if name == "Diagnostics" then
        local done = false
        return function()
            if done then return nil end
            done = true
            return "LibAccountSync-1.0 did not finish loading: sync is off this session."
        end
    end
    return nil, "not-ready"
end

-- Thin closures that check readiness and dispatch at call time. An inert
-- instance (the library half-loaded) answers through lib.Inert.
function I.Migrate(inst)
    for _, name in ipairs(FUNCTIONS) do
        if inst[name] == nil then
            inst[name] = function(...)
                if lib.ready == nil or lib.ready ~= select(2, LibStub:GetLibrary(MAJOR, true)) then
                    if not inst.inertReported and type(inst.report) == "function" then
                        inst.inertReported = true
                        pcall(inst.report, "LibAccountSync-1.0 did not finish loading: sync is off this session.",
                              "error")
                    end
                    return lib.Inert(name)
                end
                return lib.impl[name](inst, ...)
            end
        end
    end
    if inst.maxPayload == nil then inst.maxPayload = 16384 end
end

-- Kept free of lib.impl so an older copy's New still answers when a newer
-- copy threw partway: it then hands out an inert instance.
function lib:New(opts)
    if self ~= lib then error("LibAccountSync-1.0: call New with a colon: LibStub(\"LibAccountSync-1.0\"):New(opts)", 2) end
    if type(opts) ~= "table" then error("LibAccountSync-1.0: New(opts): opts must be a table", 2) end
    if not IsTag(opts.addon) then error("LibAccountSync-1.0: New: addon must be 1-16 letters or digits", 2) end
    if type(opts.store) ~= "function" then error("LibAccountSync-1.0: New: store must be a function", 2) end
    if opts.report ~= nil and type(opts.report) ~= "function" then error("LibAccountSync-1.0: New: report must be a function", 2) end
    local maxPayload = opts.maxPayload or 16384
    if type(maxPayload) ~= "number" or maxPayload < 1 or maxPayload > MAX_PAYLOAD or maxPayload % 1 ~= 0 then
        error("LibAccountSync-1.0: New: maxPayload must be a whole number from 1 to " .. MAX_PAYLOAD, 2)
    end
    if lib.byTag[opts.addon] then error("LibAccountSync-1.0: New: addon tag '" .. opts.addon .. "' is already registered", 2) end
    local inst = { addon = opts.addon, getStore = opts.store, report = opts.report, maxPayload = maxPayload }
    local ready = lib.ready ~= nil and lib.ready == select(2, LibStub:GetLibrary(MAJOR, true))
    if not ready then
        -- Inert: not registered, every function answers nil, "not-ready".
        for _, name in ipairs(FUNCTIONS) do
            inst[name] = function()
                if not inst.inertReported and type(inst.report) == "function" then
                    inst.inertReported = true
                    pcall(inst.report, "LibAccountSync-1.0 did not finish loading: sync is off this session.", "error")
                end
                return lib.Inert(name)
            end
        end
        return inst
    end
    lib.byTag[opts.addon] = inst
    lib.instances[#lib.instances + 1] = inst
    I.Migrate(inst)
    if S.key then I.SyncStores() end
    -- A host loaded after login (load-on-demand) never sees PLAYER_LOGIN.
    if not S.loggedIn and IsLoggedIn() then I.Login() end
    return inst
end

-- On upgrade: every existing instance gets this copy's missing functions.
for _, inst in ipairs(lib.instances) do I.Migrate(inst) end

-- The test seam: the crypto and codec, for building the other side's frames.
lib._test = { SHA256 = SHA256, HMAC256 = HMAC256, Encode = Encode, Decode = Decode, PREFIX = PREFIX,
              BODY_FIRST = BODY_FIRST, BODY_REST = BODY_REST, MAX_CHUNKS = MAX_CHUNKS }

lib.ready = MINOR
