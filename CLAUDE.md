# CLAUDE.md

LibAccountSync-1.0: an embedded LibStub library for **WoW: Forever 1.60.1** (Interface `16001`,
Lua 5.1). It lets an addon send small messages to the player's own other WoW accounts on the same
Battle.net account, and receive them, with ownership proven first. Single owner (Spotnick).

**Status: `r5` released** (tag on `76fedef`, MINOR 5: #18 `messages = true` delivery for
independent messages, #17 one tag per snapshot kind on a shared store, the stream cap per
(sender, tag); Codex-reviewed, not yet run in game). `r4` (`830017a`, #14 `SendTo`, not yet run in
game either). `r3` (`6c888c5`, #7 client
project/region on a blank first run, #8 `bit`-backed SHA-256) was validated by the two-account probe
check; `r2` (`fdd4a72`) by GlassChat's pilot (#4). MINOR 1 was never tagged: its pilot copy,
`cc92deb`, failed the first in-game check (#4). All five are frozen in `tests/fixtures/` (r2-r5 with
manifests).
Seven of the ten `docs/PLAN.md` §7 measurements are done (#1). **Still owed (#9):** the §7.9 relay
gate (needs a Battle.net friend as the test subject; a positive result brings the deferred relay
protections into the next MINOR), §7.3 and §7.7. #8 measured: the `bit` path hashes 16 KB in 65 ms and 32 KB
in 129 ms in game. Scope (owner, 2026-10-05): same-Battle.net-account sync only. `docs/PLAN.md` is the reviewed design (two internal rounds plus
Codex round 3); **this is security code: a mistake hands a stranger the player's lists**, so any
change to ownership, the proof, the MAC, the stores or the wire goes back through the plan and an
adversarial review first.

## Read first

- `docs/PLAN.md`: the design, every decision and why, and the review log. Section numbers (§n)
  in the code refer to it.
- `C:\Projects\References\EMBEDDED-LIBRARIES.md`: how an embedded library is built, versioned,
  upgraded in place, packaged and tested here.
- `C:\Projects\AltStable\docs\SYNC-DISCOVERY.md`: the design this library starts from, with
  measured behaviour and three adversarial review rounds. Its closed routes stay closed.
  **Never edit AltStable from this repo's sessions.** It keeps its own channel until it migrates
  in its own session.
- `C:\Projects\LibGlass` (one runtime file, instances, upgrade tests) and
  `C:\Projects\LibGroupBuffs` (consumers, version fixtures): the templates.
- `C:\Projects\References\PORTING-TBC-TO-FOREVER.md` and
  `C:\Projects\References\forever-api-1.60.1.70235.md`: client facts and the API dump (70235: the
  documented surface is identical to 70205's).

## Layout

- **No TOC.** Entry point `LibAccountSync-1.0.xml`: `LibStub\LibStub.lua`,
  `ChatThrottleLib\ChatThrottleLib.lua` (v32, vendored, public domain), `LibAccountSync.lua`.
- **`LibAccountSync.lua`**: the one runtime file. `MAJOR, MINOR = "LibAccountSync-1.0", N`;
  `lib.ready = MINOR` is its last line.
- **`Tools\deploy.ps1`**: copies this checkout into `AddOns\<Addon>\Libs\LibAccountSync-1.0`.
  **`Tools\LibAccountSyncProbe\`**, `Tools\deploy-probe.ps1`, `Tools\read-wirelog.py`: the
  in-game measurement probe (`/lasprobe`) and its log reader. Never shipped.
- **`tests\`**: see Testing.

## The contract (frozen within MAJOR; it only grows)

- `LibStub("LibAccountSync-1.0"):New({ addon, store, report?, maxPayload?, messages? })`, colon-called;
  instance functions dot-called: `Send(payload, onResult?)`,
  `SendTo(guid, payload, onResult?)` (MINOR 4), `OnMessage(fn)`, `Peers()`, `Rescan()`,
  `SetEnabled(on)`, `IsEnabled()`, `Diagnostics()`. The reason strings (`lib.REASONS`) are a
  frozen enum. `New` on a half-loaded library returns an inert instance. `messages = true`
  (MINOR 5) is detected by `inst.messages == true`, set only by a copy that honours it and never
  changed after `New`.
- **Wire 1** (`H1`, `D1`, prefix `LibAcctSync`, the domain strings, the 32 KB ceiling, field
  shapes) is frozen independently of MINOR: a change is a new wire added alongside, never an edit.
  Hello parsers ignore extra trailing fields; a data body is everything after the sixth `|`;
  unknown frame types are ignored.
- **The store** is the one structure that crosses versions on disk: never delete unknown fields;
  a later store version keeps `key`, `keyAt`, `trusted`, `lastSid` with their meaning.

## Upgrade rules (several addons ship copies; the newest one wins, and it may not be yours)

EMBEDDED-LIBRARIES §5, as applied here (§4 of the plan):
- Everything installed once (instance functions, the frame's `OnEvent`, the ticker, `C_Timer`
  callbacks, ChatThrottleLib callbacks) checks the completion marker inline and calls
  `lib.impl.X` when it runs. Never capture an implementation function past load. Holding the
  `lib.impl`/`lib.state` tables is fine: they never change identity.
- State lives in `lib.state`, filled only where missing. One frame and one ticker, never
  recreated.
- `lib.ready = MINOR` last; every entry point refuses a half-loaded copy.

## Security rules (the plan's §5; each has a test and a mutation)

- `I.OwnAccountGame` is the only way an id is ours by Battle.net; it fails closed on an unknown
  game or region. Ownership by BattleTag (account id only when both ids come from
  `GetAccountInfoByGUID`).
- Elimination is a hint for a keyless hello, never trust or data. The friends list fails closed.
- The household key goes only to a verified id; a key or proof is believed only from an id that
  is verified, ours by elimination, or holds our nonce. Our own key never counts as trusted.
- Every Battle.net value is read through `I.GameRec`/`I.GameRecByGuid`/`I.AcctRec`/
  `I.FriendGameIDs`, which copy plain fields and mark a record holding a secret `unknown`;
  `test_secrets` greps that nothing else touches a raw record.
- A sender is always Blizzard's `senderID`; a stream from a non-verified sender needs the MAC
  (bound to our nonce and the proven GUID); sids are monotonic per (tag, sender GUID) for a
  snapshot tag, and delivered at most once per (tag, sender GUID) for a messages tag (a 256-sid
  window, older refused).

## Testing

```
pwsh tests/run.ps1                                       # luac -p + every tests/test_*.lua
& 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\mutate.lua [filter]   # mutation run (~1 min)
```
- Plain Lua 5.1 (`C:\Program Files (x86)\Lua\5.1\`), LibGlass's harness: strict globals (each
  stub confirmed in the API dump), loading through the XML with `(host, ns)`, secrets as
  `newproxy` values that throw.
- `tests/wow_stubs.lua` simulates Battle.net (ported from AltStable's), a clock (`WoW.advance`),
  and a ChatThrottleLib stub; `test_ctl` runs the real vendored v32. `tests/harness.lua` has
  `session()` and `Peer`, the other account, which builds hellos, proofs and MACs from the plan's
  formulas independently of the library.
- **Every new test is mutation-tested**: add its mutation to `tests/mutate.lua` and see it red.
  The control run must be green; a mutation that no longer applies must be fixed, not dropped.
- Upgrade tests use a synthetic newer copy, plus the frozen `cc92deb` pilot copy (MINOR 1) loaded
  before the current one. **Each release** adds `tests/fixtures/LibAccountSync-rN.lua` and
  `LibAccountSync-rN.manifest` (SHA-256 of every shipped file, LF-normalised) and appends N to
  `RELEASED` in `test_upgrade.lua` 4d, which loads every release under the current copy and fails
  if a released MINOR's files change (EMBEDDED-LIBRARIES §8, §9).

## Conventions (sibling addons')

- Issue → branch → PR (`Closes #N`) → review (owner-launched) → the owner merges.
- Every client value that can be a secret is checked with `issecretvalue` before any use
  (compare, truth-test, concatenate): Battle.net records through the readers, everything else
  (event arguments, BNGetInfo, prefix results) with `IsSecret` first.
- Raise MINOR for every behaviour change, in the same PR; tag the merge commit `rN`.
- Right-size for a single maintainer.
