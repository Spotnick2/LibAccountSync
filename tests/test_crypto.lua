-- test_crypto.lua: SHA-256 and HMAC-SHA-256 against the published vectors,
-- and the \0 codec over every byte value (§2).

dofile("tests/wow_stubs.lua")
dofile("tests/harness.lua")

local lib = loadLibrary()
local T = lib._test

-- FIPS 180-2 (as AltStable's tests/test_comm.lua checks them).
eq(T.SHA256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256 of the empty string")
eq(T.SHA256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of abc")
eq(T.SHA256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
   "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "SHA-256, two blocks")
eq(T.SHA256(string.rep("a", 1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
   "SHA-256 of 1000 a's")

-- RFC 4231, test cases 1, 2 and 6 (a key longer than the block).
eq(T.HMAC256(string.rep("\011", 20), "Hi There"),
   "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "HMAC-SHA-256, RFC 4231 case 1")
eq(T.HMAC256("Jefe", "what do ya want for nothing?"),
   "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "HMAC-SHA-256, RFC 4231 case 2")
eq(T.HMAC256(string.rep("\170", 131), "Test Using Larger Than Block-Size Key - Hash Key First"),
   "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "HMAC-SHA-256, RFC 4231 case 6")

-- The codec: every byte value survives, \0 never appears on the wire, and a
-- broken escape is refused rather than guessed.
local all = {}
for b = 0, 255 do all[#all + 1] = string.char(b) end
all = table.concat(all) .. "\0\1\0\1\1\0"
local enc = T.Encode(all)
check(not enc:find("%z"), "no \\0 survives encoding")
eq(T.Decode(enc), all, "every byte value round-trips")
eq(T.Decode(T.Encode("")), "", "the empty payload round-trips")
eq(T.Decode("a\001"), nil, "a dangling escape is refused")
eq(T.Decode("a\001\003"), nil, "an unknown escape is refused")
eq(T.Decode(T.Encode("a|b||c|")), "a|b||c|", "pipes travel unescaped")

-- The client's bit library (#8). Desktop Lua has none, so stubs model it: one
-- that returns SIGNED 32-bit results (the worst case for sign handling) must
-- be used and give the same digests; a broken one must be refused, falling
-- back to the pure-Lua path with the same digests.
local function nibble(a, b, f)
    local r, m = 0, 1
    a, b = a % 4294967296, b % 4294967296
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if f(x, y) then r = r + m end
        a, b, m = (a - x) / 2, (b - y) / 2, m * 2
    end
    return r
end
local function signed(v) v = v % 4294967296; if v >= 2147483648 then return v - 4294967296 end return v end
local SIGNED_BIT = {
    bxor = function(a, b) return signed(nibble(a, b, function(x, y) return x ~= y end)) end,
    band = function(a, b) return signed(nibble(a, b, function(x, y) return x == 1 and y == 1 end)) end,
    bor = function(a, b) return signed(nibble(a, b, function(x, y) return x == 1 or y == 1 end)) end,
    rshift = function(a, n) return signed(math.floor((a % 4294967296) / 2 ^ n)) end,
    lshift = function(a, n) return signed((a % 4294967296) * 2 ^ n) end,
}
local VECTORS = {
    { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
    { string.rep("a", 1000), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3" },
}
local function withBit(b)
    WoW.reset(); WoW.resetLibStub()
    rawset(_G, "bit", b)
    local l = loadLibrary()
    rawset(_G, "bit", nil)
    return l._test
end
do
    eq(T.HASH_PATH, "lua", "without a bit library, the pure-Lua path")
    local F = withBit(SIGNED_BIT)
    eq(F.HASH_PATH, "bit", "a bit library with signed results passes the check and is used")
    for _, v in ipairs(VECTORS) do eq(F.SHA256(v[1]), v[2], "  and gives the FIPS digest") end
    eq(F.HMAC256("Jefe", "what do ya want for nothing?"),
       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "  and the RFC 4231 HMAC")
    local broken = {}
    for k, f in pairs(SIGNED_BIT) do broken[k] = f end
    broken.bxor = function(a, b) return SIGNED_BIT.bxor(a, b) + 1 end
    local G = withBit(broken)
    eq(G.HASH_PATH, "lua", "a bit library that gets the digest wrong is refused")
    for _, v in ipairs(VECTORS) do eq(G.SHA256(v[1]), v[2], "  and the pure-Lua path still gives the FIPS digest") end
    local throws = {}
    for k, f in pairs(SIGNED_BIT) do throws[k] = f end
    throws.bxor = function() error("bit: out of range") end
    eq(withBit(throws).HASH_PATH, "lua", "a bit library that throws is refused")
    -- Wrong only at one edge operand (0x80000000), which short digests may
    -- never meet: the operand check refuses it.
    local edge = {}
    for k, f in pairs(SIGNED_BIT) do edge[k] = f end
    edge.band = function(a, b)
        if a % 4294967296 == 2147483648 and b % 4294967296 == 2147483648 then return 0 end
        return SIGNED_BIT.band(a, b)
    end
    eq(withBit(edge).HASH_PATH, "lua", "a bit library wrong at one edge operand is refused")
    -- Wrong only for an operand outside the sampled ones but inside SHA-256's
    -- first round (0x6a09e667, the first initial hash word): the digest check
    -- refuses it, and the pure-Lua path still gives the right digests.
    local deep = {}
    for k, f in pairs(SIGNED_BIT) do deep[k] = f end
    deep.band = function(a, b)
        if a % 4294967296 == 0x6a09e667 then return 0 end
        return SIGNED_BIT.band(a, b)
    end
    local Dp = withBit(deep)
    eq(Dp.HASH_PATH, "lua", "a bit library wrong past the operand sample is refused by the digest check")
    for _, v in ipairs(VECTORS) do eq(Dp.SHA256(v[1]), v[2], "  and the pure-Lua path is restored") end
end

done("test_crypto")
