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

done("test_crypto")
