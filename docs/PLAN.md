# LibAccountSync-1.0: the plan

Plan for #1, written 2026-10-04. **No code exists yet.** This is security code: a mistake hands a
stranger the player's lists. So this plan goes through an adversarial review (Codex, launched by
the owner) before r1 is written. Two internal rounds have already been folded in (§10), so Codex's
pass is round 3.

## Context

GlassChat's Spam & Ignore wants the same ignore and mute lists on every WoW account under one
Battle.net account (GlassChat#33, S3). AltStable already has a proven own-account channel
(AltStable#58, `docs/SYNC-DISCOVERY.md`).

Two other ways to get the channel were ruled out:
- A public API on AltStable would make GlassChat depend on AltStable being installed.
- Copying the code into GlassChat would leave two drifting copies of an ownership proof.

So the channel becomes an embedded LibStub library, following
`C:\Projects\References\EMBEDDED-LIBRARIES.md`.

- **GlassChat is the pilot.** It sends a whole snapshot that the receiver applies wholesale,
  removals included (GlassChat `docs/PLAN-SPAM.md` S3). The snapshot also carries the "own
  characters" list.
- **AltStable is not touched.** It keeps its own prefix, its own `HI8` hello and its own key
  store, and migrates later, in its own session.
- **The library is seeded from AltStable's `Core.lua`.** Its discovery and ownership proof are
  ported. Its transport is rewritten for small payloads, because the receive side there is
  interleaved with AltStable's own sync.

**Owner decisions (2026-10-04):**
- **AltStable parity.** A peer whose Battle.net presence is blank, proven by the nonce/HMAC
  handshake, also receives. A presence was measured staying blank for 16+ minutes after a
  `/reload`, on both sides (SYNC-DISCOVERY.md:27). Before #58 handled this, players saw "try again
  later".
- **Hardening only where it is nearly free or fixes a real bug.** Everything else waits for a
  measured case (§5.4). This is the AltStable session's advice: a cold reviewer adding rigor
  makes the protocol and its tests bigger without a failure behind it.
- **ChatThrottleLib v32 is vendored** in the library (§6).

Every `Core.lua` line reference below is to AltStable at the commit read on 2026-10-04.

---

## 1. The API

Frozen within MAJOR: it only grows (EMBEDDED-LIBRARIES §4).

```lua
local Sync = LibStub("LibAccountSync-1.0"):New({
  addon  = "GlassChat",                            -- wire tag: 1-16 alphanumerics, permanent
  store  = function() return GlassChatDB and GlassChatDB.accountSync end, -- a getter
  report = function(text, kind) end,               -- optional
  maxPayload = 16384,                              -- optional; at most the wire ceiling, 32768
})

Sync.Send(payload [, onResult])  -- returns the destination count, or nil, reason
Sync.SendTo(guid, payload [, onResult])  -- MINOR 4: one peer; returns 1, 0, or nil, reason
Sync.OnMessage(fn)               -- fn(payload, sender, sid)
Sync.Peers()                     -- array of fresh {guid, name, realm, faction, proven}
Sync.Rescan()
Sync.SetEnabled(on)  Sync.IsEnabled()
Sync.Diagnostics()               -- iterator of lines: the /alts bnet readout
```

### `New`
- **Colon-called.** A dot call errors (EMBEDDED-LIBRARIES §6), and so does each of these:
  - a tag that isn't 1-16 alphanumerics;
  - a store that isn't a function;
  - a tag already registered this session;
  - a `maxPayload` outside 1..32768.
- **The tag is wire-visible and permanent.** Changing it later orphans every peer running the old
  one. Two addons choosing the same tag collide; the second errors at load.
- **Not ready means inert, not a throw.** When the library isn't ready (a newer copy threw while
  loading, §4), `New` returns an **inert instance**: every call returns `nil, "not-ready"`, and
  the first call reports once. If it threw instead, the host addon would fail to load because of
  someone else's broken copy.
- **One mechanism for instance functions.** Every instance function is a thin closure,
  `function(...) return lib.impl.Send(inst, ...) end`, so an instance made by an older copy runs
  the newest code (§4).

### `store`
- **A getter, called on every access**, returning the host's table, or nil while its
  SavedVariables aren't loaded yet. A plain table was rejected: a host that captures
  `GlassChatDB.accountSync` before its SavedVariables load hands the library an orphan table. The
  library would then write a new key into it every session, and blank-presence proofs would
  never work, with no error anywhere.
- **The table must be account-wide.** A per-character table means a key per character.
- **Hosts keep it out of any profile export.** It holds the household key.

### `Send(payload, onResult)`
- `payload` is a string of at most `maxPayload` bytes.
- **Destinations** are the peers that are bound right now (§5.1) and whose current nonce we hold
  (§5.3).
  - A bound peer whose nonce we don't hold yet gets `onResult(peer, "failed", "not-ready")`, and
    we send it a hello. The host retries later; the library keeps no pending queue.
- **Returns** the number of destinations, or `nil, reason`.
- **`onResult(sender, status, reason)`** fires **once per destination**:
  - `"sent"` when ChatThrottleLib has handed off the last chunk;
  - `"failed"` with a reason as soon as any chunk fails.

  `"sent"` means handed to the wire, never "delivered". There is no acknowledgement in r1.
- **Reasons, a frozen enum:** `disabled`, `no-peers`, `too-large`, `not-ready`, `offline`,
  `no-route`.

### `SendTo(guid, payload, onResult)` (MINOR 4, #14)
Send to **one** peer, for a host whose replies differ per peer (AltStable's request/response
sync).
- **`guid`** is a peer's GUID, as `Peers()` returns it. Not a name: hellos are matched by GUID,
  and names are case-folded and realm-ambiguous. A `guid` that isn't a player GUID string is an
  error, like a non-string payload.
- **A new function, not a third argument on `Send`.** Every older copy's `Send` drops an extra
  argument, so a host that missed a MINOR check would silently broadcast. `SendTo` is
  feature-detectable (`inst.SendTo ~= nil`; §4's migration adds it to instances made by an older
  copy), and on a copy without it the call fails instead of broadcasting. `Send` itself still
  ignores extra arguments: it never takes a target.
  - **Detect it at call time, not at load.** An instance made by an older copy gains `SendTo`
    only when a newer copy loads, which can be after the host's own main chunk. A host that
    cached "no `SendTo`" at load would broadcast for the whole session.
- **Never a broadcast.** Destinations are only the ids bound to that GUID right now (§5.1).
- **One destination.** One GUID can be bound to two ids (a blank second presence, #4). `SendTo`
  sends to one id that routes and holds our nonce, and reports once. Sending to both would be
  safe (the per-GUID sid floor refuses the duplicate, §5.2), but the host wants one result.
  - **No fallback to the other id.** If the chosen id's send fails, the host gets
    `failed`/`offline` and retries; the next scan has dropped the stale binding. Route was
    checked within 2 s of the send, so this is rare, and a fallback would need state that
    outlives the call.
- **Results and reasons are `Send`'s; the enum doesn't grow.** The `guid` is checked before the
  switch and session checks, so a wrong argument raises in every state the library is live in
  (an inert instance checks nothing, in any copy).
  - A GUID that isn't a current peer: `nil, "no-peers"` before anything is sent, with no
    `onResult`. The library keeps no memory of departed GUIDs, so there's no `"offline"` here;
    `"offline"` stays the asynchronous send failure.
  - A bound target whose nonce we don't hold: one `onResult(peer, "failed", "not-ready")`, a
    hello to each of its ids, and `0`.
  - The other refusals (`disabled`, `too-large`, `not-ready`, `no-route`) as `Send`.
- **Same stream as `Send`:** the MAC is per destination already (§5.3), and the sid comes from
  the one counter, so a receiver sees sids that rise with gaps (§5.2).

### `OnMessage(fn)`
- One handler per instance. It is called as `fn(payload, sender, sid)`.
- **`sender` comes only from Blizzard's `senderID`**, resolved through the Battle.net record or
  through a proven hello (§5). It is **never taken from a field inside the data frame**.
  - It is captured when the stream is admitted, so a sender who sends and logs out straight away
    still gets delivered.
  - Each call gets a fresh table, so a host can't change library state through it.
  - `sender.proven` says how ownership was established:
    - `"bnet"`: Battle.net shows the id as ours;
    - `"key"`: its hello carried a trusted household key;
    - `"proof"`: an HMAC proof between blank presences.
- **`sid`** is monotonic per sender (§5.2). It lets a host order snapshots that arrive from
  different accounts.
- **The payload is data, never code.** The library never `loadstring`s anything. The handler
  runs under `xpcall`, and an error is reported through that host's `report`. One host's error
  stops neither another host's delivery nor the library.

### `Diagnostics()`
It returns the per-id "why or why not" lines AltStable prints for `/alts bnet` (`Core.lua`
4346-4391), plus a state summary:
- self;
- whether the friends list has settled;
- the trusted-key count;
- each peer's binding and proof path.

It never prints a key, and prints nonces truncated to 4 characters.

## 2. The prefix model, and versioning the wire

### One prefix, a tag per frame
The library registers **one** addon-message prefix, `"LibAcctSync"`. Every data frame carries the
host's tag.

The alternative, a prefix per addon, would mean one discovery pass, one hello and one key per
addon. Each addon would prove ownership separately, and the keys would drift apart. Ownership is
a fact about the **account**, not about the addon reading it, so it belongs to the library once.

A data frame whose tag has no enabled local instance is dropped.

### The wire is versioned on its own
Frames start with a type letter and the wire version: `H1` and `D1`. The wire version is
**independent of the library's MINOR and of any host's protocol**. AltStable ties `HI8` to its
sync version (`Core.lua` 679); that coupling is not repeated here.

Because the newest copy any addon ships is the one that runs, an older host can run a newer copy,
and two accounts can run different copies. So:
- **A copy never changes what wire 1 means.** A later wire is added *alongside*, and a newer copy
  keeps speaking wire 1. This is LibGlass's "the API only grows" rule, applied to the wire.
- **Hello parsers ignore extra trailing fields**, so the hello can grow without a new wire.
  **Data frames can't grow that way**: their body is the whole rest of the frame (§2, Frames). A
  data frame that needs more fields becomes a new frame type.
- **Unknown frame types are ignored**, so a new frame type (an acknowledgement, a tag list) needs
  no new wire.
- **The hello carries `maxWire`.** The `min(ours, theirs)` negotiation is written when wire 2
  exists, not before.
- **The domain strings of the proof and the MAC include the wire version**, so a proof can't be
  carried from one version to another.

### Coexisting with AltStable
- Old AltStable clients (v0.10, `HI8|…`, protocol `"8"`) **never see this traffic**. It travels
  under another prefix, which they ignore cleanly.
- When AltStable migrates, it keeps speaking `HI8` on its own prefix during the transition
  (EMBEDDED-LIBRARIES §4, lazy adoption).
- Importing AltStable's existing `bnetKey` and `bnetTrusted` into the library's store would let
  blank-presence proofs work on day one. That belongs to AltStable's migration session. It must
  give the imported key the **oldest** `keyAt`, or the oldest-wins rule (§3) drops it.

### Frames
**Hello:** `H1|maxWire|name|guid|faction|realm|key|nonce|proof`
- `key` is filled only when Battle.net shows the target as ours (§5.1). Otherwise it is empty.
- `proof` answers the receiver's latest nonce (§5.1). It is empty when we hold none.
- The worst case is about 205 bytes with UTF-8 names. The length is asserted to be at most 255
  before sending, because ChatThrottleLib errors past that.

**Data:** `D1|tag|sid|i|n|mac|body`
- **The body is everything after the sixth `|`**, to the end of the message. The codec doesn't
  escape `|`, so the body may contain any number of them, and nothing may follow it. A parser
  splits off exactly six header fields and never splits the body. Splitting it and keeping only
  "the seventh field" would truncate a payload containing `|` (Codex round 3).
- `mac` (32 hex, §5.3) rides on chunk 1. Other chunks carry `-`.
- **Header budget, worst case:**
  - chunk 1: `D1|` (3) + tag (16) + `|` + sid (13) + `|` + i (3) + `|` + n (3) + `|` + mac (32) +
    `|` = 75 bytes, leaving **180 bytes of body**;
  - other chunks: 44 bytes, leaving **211**.
- **Escape first, then slice.** The whole payload is escaped before slicing (`\0` and the escape
  byte itself), and decoded after reassembly. This needs about ten lines of codec; LibDeflate's
  `EncodeForWoWAddonChannel` does the same job.
- **No DONE frame.** Every chunk carries `i` and `n`, and a stream completes when all `n` chunks
  are present. AltStable's `DONE8` existed to carry the checksum and a total; here the MAC binds
  `n` and the payload hash.
  - Battle.net delivery is unordered (ChatThrottleLib v32, `BNSendGameData` comment), so any
    chunk may come first.
  - A stream with no new chunk for 6 s is dropped: AltStable's Battle.net settle time, `Core.lua`
    117.
- Data goes out at ChatThrottleLib priority `NORMAL`, so other addons' `BULK` traffic can't stall
  a stream past the settle.

**Frozen in wire 1:**
- the payload ceiling, **32768 bytes**. `n` is checked against `ceil(2 * 32768 / 180)` at the
  first frame, and the instance's own `maxPayload` against the decoded size. Fixing the ceiling in
  the wire stops a newer copy from out-capping an older one silently.
- the field shapes. They are checked in plain Lua with a length test and a character class,
  because Lua patterns have no `{n}`:
  - nonce: 16 hex;
  - key: 32 hex;
  - GUID: `Player-%d+-%x+`;
  - sid: 1-13 digits;
  - tag: 1-16 alphanumerics.

  Anything else drops the frame before any HMAC is computed.

**No compression in r1.** GlassChat's snapshot is a few KB. A later wire can add compression if
payloads grow.

## 3. Key stores across hosts

An embedded library can't declare SavedVariables, so each host passes a store getter (§1). With
two hosts there are two stores, which can hold different things.

**Store shape:**
`{ v = 1, key, keyAt, trusted = { [key] = lastSeen }, selfProject, selfRegion, selfAt, lastSid, enabled }`

`lastSid` is the last stream id this account issued (§5.2). It is written to every writable store
on each `Send`, and read as the maximum across stores.

### Our own key is chosen lazily and never overwrites another
- **When:** at first need (the first hello, from login + 5 s), and only once **every** registered
  getter returns a table. Until then, nothing is chosen and no hello carries a key, so it fails
  closed.
- **Which:** the oldest `keyAt` wins, and on a tie the lowest key string. If no store has a key, a
  new one is made from the entropy pool (§5.2).
- **Frozen for the session.** A host registered later, load-on-demand included, adopts it.
- **Written only into stores with no key**, together with its `keyAt`. A store's existing key is
  never overwritten. Next session, oldest-wins converges every store on one key, without anything
  drifting within a session.

### Trust is merged
- `trusted` is a union across stores, keeping the newest `lastSeen`, and written back to every
  writable store.
  - Trust is a fact about the household, and every host speaks through the same prefix and hello,
    so keeping it per host would make no sense.
- Capped at **16** keys, evicting the least recently seen.
- `lastSeen` is refreshed whenever a key is used successfully: received from a verified id, or
  checked in a proof or a MAC.

### Our own key never counts as trusted
- Verification rejects our own key. Otherwise a relay could reflect our own proof or MAC back to
  us and have it verify.
- **One exception: a shared key.** A player who copies one WTF folder onto their other account
  gives both accounts the same key, and each would reject the other's as its own. AltStable
  accepts its own key (`TrustKey`, `Core.lua` 899), so that case works there, and it must not
  regress.
  - When a Battle.net-verified id sends us **our own** key, the side with the lower GUID makes a
    new key and writes it to every writable store. This is the one time a key is overwritten.
  - It reports once and sends a fresh hello.

### Other fields
- `selfProject` and `selfRegion` (our game and region, as last known) are taken from the store
  with the newest `selfAt`. Since MINOR 3 (#7), when our own presence can't say AND nothing is
  stored (a first run), the client's own `WOW_PROJECT_ID` and `GetCurrentRegion()` stand in,
  measured equal to Battle.net's values (§7.8). They are never saved: `WOW_PROJECT_ID` is a global
  another addon could overwrite, so it must not replace a value learned from a live presence.
- `enabled` is per host. The library is active while any instance is enabled. When none is, its
  session state is wiped and nothing is sent.

### Forward compatibility
The store is the only structure that outlives a version on disk. An older copy may run alone in a
later session, against a store a newer copy wrote. So:
- unknown fields are never deleted;
- a store whose `v` is higher than this copy knows is **read-only** for this copy;
- every later `v` keeps `key`, `keyAt` and `trusted` with their meaning, so an older copy never
  regenerates a key.

### Documented limits
- **Any co-hosted addon can read every store**, and so the keys. Addons in one client share one
  Lua environment; nothing in the library changes that.
- **Never copy SavedVariables between people or game flavours.** A copied store carries the key
  and trust with it. The project and region in proofs (§5.2) blunt the flavour case.
- **No revocation in r1** (§5.4).

## 4. Upgrading in place

The rules are EMBEDDED-LIBRARIES §5, applied to one runtime file.

### State on the lib table
- All session state lives in `lib.state = lib.state or {}`: peers, presence, learned names, our
  nonces and theirs, hello stamps, buffers, finished and refused streams, sid floors,
  `bnetUpSince`.
- `lib.instances`, `lib.stores` and `lib.impl` keep their identity across upgrades.

### One frame, one ticker
- `lib.frame = lib.frame or CreateFrame("Frame")`, and `lib.ticker` (60 s) is created once.
  Neither is recreated on upgrade.
- Events are registered idempotently.

### Everything dispatches at call time
These are all `function(...) return lib.impl.X(...) end`:
- `OnEvent`;
- the ticker;
- every `C_Timer` callback;
- every ChatThrottleLib callback this copy queues;
- every instance function.

Nothing keeps `local impl = lib.impl` beyond load.

One documented exception: callbacks an **older** copy already queued in ChatThrottleLib run that
copy's code. They only touch `lib.state`, so they are harmless.

### Completion marker
- `lib.ready = MINOR` is the last line of the file.
- **Every entry point** checks `lib.ready == select(2, LibStub:GetLibrary(MAJOR))`:
  - `New` (an inert instance, §1);
  - instance calls;
  - `OnEvent`;
  - the ticker;
  - timers;
  - ChatThrottleLib callbacks.

  A copy that threw partway leaves the library **inert and reported**, never half-running crypto.

### Narrow migration
An upgrade fills missing keys in `lib.state` and in each instance, and adds new functions. It
never rebuilds or clears.

### Semantics belong to the wire, not to MINOR
An older host can run a newer copy, so a hello, proof or MAC never changes meaning silently. Their
meaning is fixed by the wire version (§2).

## 5. Security

### 5.1 The parity core
This is SYNC-DISCOVERY's design, reviewed in three Codex rounds, ported.

**Who is us.** `SelfBNet` (`Core.lua` 569-610) gives our Battle.net account, BattleTag, game
account id, project and region. Project and region fall back to the last values seen (now the
merged store, §3).

**One eligibility test.** `OwnAccountGame` (`Core.lua` 628-659) is the only way an id counts as
ours by Battle.net. The id must be:
- online;
- running WoW;
- on the same `wowProjectID` (failing closed while ours is unknown);
- in the same region (§5.2);
- on our Battle.net account (§5.2);
- not our own GUID.

**The friends list fails closed.** `FriendGameIDs` (`Core.lua` 682-710) gives nil for 60 s after
Battle.net comes up, and on any read failure. A list still loading answers "zero friends" and
looks complete; Codex round 2 reproduced exactly that, a friend being sent a chunk.

**Elimination is a hint only.** `OwnByElimination` (`Core.lua` 712-726) says that a blank id
belongs to no friend. It is only a **hint** of where to send a keyless hello, never trust and
never data.

**The household key:**
- It is sent **only** to an id `OwnAccountGame` verifies.
- It is adopted only from a hello by such an id whose `guid` matches Battle.net's `playerGuid`.
  AltStable matched by name (`Core.lua` 3484-3489); the library matches by GUID, because names
  differ in format between `UnitName` and Battle.net (the surname, #4) and the GUID does not.

**Blank presences:**
- A hello from a blank id is believed only if it carries a trusted key, or a valid proof.
- The proof, written by role:
  ```
  HMAC256(K_sender, "LibAccountSync-1.0|hello|1|" .. receiverNonce .. "|" .. senderNonce .. "|"
          .. lower(senderName) .. "|" .. senderGuid .. "|" .. senderRealm .. "|"
          .. project .. "|" .. region)
  ```
  cut to 32 hex. The receiver fills in **its own** project and region, so any mismatch fails.
- Compared with AltStable's `"AltStable#58|" .. nonce .. "|" .. name` (`Core.lua` 912-914), it
  binds:
  - the library's domain;
  - the wire version;
  - both nonces;
  - the GUID and realm (AltStable's hello carried them unproven);
  - project and region.

**Nonces:**
- Ours is fixed per id for the session, and cleared when that id goes offline or its binding
  drops (`Core.lua` 975-979).
- A new nonce is answered at once, but only to an id that is verified or ours by elimination.
  Otherwise there is one hello per 60 s per id, and no ping-pong, because our nonce is stable.

**Identity is always Blizzard's `senderID`:**
- A binding is re-checked right before each send, with a 2 s cache (`BNetRoute`, `Core.lua`
  1840-1855).
- `TargetOffline` or `TargetRequired` drops the binding and triggers a rescan.
- A learned name is forgotten when its id goes offline, when its binding drops, or when Battle.net
  contradicts it.
- A binding change wipes that id's buffers, nonces and learned name.

**Accepted limit, kept as SYNC-DISCOVERY.md:48-50 states it.** A friend whose friends-list entry
we misread as ours, **and** who runs a purpose-built relay, can relay proofs between our accounts
and be bound as one of our characters.

### 5.2 Hardening kept: each nearly free, or fixing a real bug

| Change | Why |
|---|---|
| **Secrets.** Every Battle.net field is read through one accessor that returns an `UNKNOWN` sentinel for a value `issecretvalue` reports. `UNKNOWN` fails every predicate, the elimination hint included. A test greps the runtime and fails on any direct field read | CLAUDE.md requires it, and the channel has none today. A secret `characterName` would otherwise read as "blank" and send the id down the elimination path. Lua 5.1 can't make `==` or a truth test throw on a stub, so the grep enforces what the stubs can't |
| **Region fails closed**, like project. If §7.8 finds peer records carry no `regionID`, it falls back to `isInCurrentRegion == true` | `Core.lua` 651 skips the check when either side is nil |
| **Ownership by BattleTag.** The account-id match is used only when both values come from `GetAccountInfoByGUID` | `BNGetInfo`'s `presenceID` (the `SelfBNet` fallback) may be a different id namespace. A friend whose id is numerically equal would get the key |
| **A key or proof is believed only from an id that is verified, ours by elimination, or already sent our nonce** | AltStable believes a trusted key from any id (`Core.lua` 3490). If our key ever leaked, any friend could be believed and could rewrite the lists, with no relay needed |
| **`theirNonce` is stored only for an id that is verified, ours by elimination, or proven this session** | AltStable stores it before any check (`Core.lua` 3483). "Proven this session" keeps a reloaded peer working while the friends list is failing closed |
| **Project and region are in the proof and the MAC** | A beta key copied to live can't prove there |
| **Monotonic sid:** `sid = max(GetServerTime() * 1000, lastSid + 1)`, with `lastSid` kept in the store (§3), so it survives a `/reload` in the same second and has no counter to exhaust: past 1000 sends in a second it runs ahead of the clock and stays monotonic. One counter serves every tag. Documented limit: after a client **crash** SavedVariables aren't written, so a send in the same second can repeat or fall below an old sid and is refused until the clock passes it. The receiver keeps a floor per **(tag, sender GUID)** for the session, raised only after an authenticated completion, and accepts only higher sids | GlassChat applies a snapshot wholesale. Two genuine sends arriving out of order, or a relay replaying an old genuine stream under its own id, would otherwise roll the lists back. Keying by GUID, which the proof binds, rather than by the session id handle, covers the replay |
| **Caps:** the 32 KB ceiling and the `n` cap (§2); 2 concurrent streams per sender id and 8 in total; at most 128 KB buffered; the 6 s settle and the 60 s sweep; a refused stream stays refused; every message at most 255 bytes | AltStable has no limit on streams, `total` or size, and `StreamReady` loops to an unchecked `buf.total`: a freeze a peer can trigger |
| **Reset `bnetUpSince` on `BN_DISCONNECTED`** too, not only on `PLAYER_LOGIN` and `BN_CONNECTED` | A reconnecting friends list is loading again |
| **Entropy.** One SHA-256 over AltStable's sources (`Core.lua` 877-884) plus `GetServerTime()` and `fastrandom()`. It makes the key (once ever) and the nonces | The client has no cryptographic random source, so a key made once from many sources is the best available |

### 5.3 The stream MAC: one non-trivial item, flagged for review

```
HMAC256(K_sender, "LibAccountSync-1.0|data|1|" .. receiverNonce .. "|" .. senderGuid .. "|"
        .. project .. "|" .. region .. "|" .. tag .. "|" .. sid .. "|" .. n .. "|"
        .. SHA256(decodedPayload))
```
cut to 32 hex, on chunk 1.

- **`senderGuid` binds the stream to its author.** The sender puts in its own GUID. The receiver
  puts in the GUID **authenticated for that id's binding** (from Battle.net, or from the proven
  hello), never a value from the frame.
  - Without it, a relay could present a genuine proven hello for character C and attach a
    genuine stream captured from character A. A's stream would then be delivered as C's, and an
    old snapshot of A's could be replayed under C's fresh sid floor (Codex round 3, P1).

- **The sender always includes it.** Every destination is a peer whose nonce we hold (§1).
  `SHA256(payload)` is computed once per `Send`, then one short HMAC per peer.
  - Only the receiver knows whether it sees the sender as verified. A sender that left the MAC
    out "because it saw the receiver as verified" would have its streams dropped silently
    whenever the two presences differ (found in round 2).
- **The receiver decides at completion, not at the first frame:**
  - a sender **verified by Battle.net** is accepted with the MAC unchecked only if it is **the same
    character** throughout (r1, after Codex's PR #3 rounds):
    - each id remembers every character authenticated for it this session, however it was
      authenticated (`NoteBinding`);
    - a stream records the character bound when it began, or else the first one authenticated
      after;
    - it passes without the MAC when that character is the one Battle.net verified then and is
      still there (or has logged out since: send-then-logout still delivers, as §1 promises), or
      is the one Battle.net verifies now;
    - after any change of character on that account, the MAC decides, bound to the GUID shown
      now, so an older character's stream can't slip under a new one's sid floor;
    - **stated limit:** a stream begun while its sender was blank and never identified is credited
      to the first character authenticated for that id after it. Ownership holds (Battle.net
      verifies the game account as ours), and an unidentified sender had no floor to bypass;
  - any other sender is delivered only if it has a **proven hello at completion** and the MAC
    verifies under a trusted key with **our current nonce for that id**;
  - a sender that isn't verified may fill a buffer only if we have sent that id our nonce. The
    caps bound the memory;
  - **a complete stream whose sender isn't proven yet is kept, not dropped.** It waits as
    "awaiting hello" for up to 10 s, within the same caps, and is re-checked whenever a hello from
    that id is believed. It is delivered if the check passes, and dropped at the timeout or when
    the binding changes (Codex round 3).

  Together these let a blank-presence peer's data land however it interleaves with the last
  hello of the handshake: some chunks before the hello, or every chunk before it (Battle.net is
  unordered). Only Battle.net can make an id verified, so nobody can exploit the timing.
- **Why it stays:** AltStable merges a peer's character records last-write-wins. GlassChat applies
  a **wholesale** snapshot, with removals and the "own characters" list. Without the MAC, the
  accepted relay of §5.1 could rewrite the lists, not only read them. With it, the limit is back
  to what SYNC-DISCOVERY accepted.
- **What it costs:** one pure-Lua SHA-256 per `Send` and per received stream (§7.4), about thirty
  lines, and their tests.
- **If the owner or Codex judge it unneeded, it is the first thing to cut.**

### 5.4 Deferred until a measured case
The internal review proposed these. Each makes the protocol and its tests bigger without a
measured failure behind it, so none ships in r1. The scenarios are in §10.

- one binding per GUID, and reporting a "possible relay" on a conflict;
- a full 1-128 walk before sending to a proof-only peer;
- pinning each id to the key that verified it;
- stamping the store with its owner (a hash of the BattleTag) to reject a copied store;
- revocation (`ResetKeys`);
- a "reply now" hello flag;
- resending when a peer's nonce changes;
- a GUID fallback for game account ids above 128 (AltStable reads its own database for that,
  `Core.lua` 2623-2635);
- a warning for per-character stores;
- coroutine hashing.

Measurement §7.9 is the trigger for the relay items, and §7.4 for coroutine hashing.

## 6. Dependencies

- **ChatThrottleLib v32 is vendored** at `ChatThrottleLib/ChatThrottleLib.lua` and loaded by the
  library's XML before the runtime file.
  - CTL is public domain.
  - It manages its own copies (newest wins, `ChatThrottleLib.lua` 26-31), derives no paths, and
    shares one bandwidth budget with every other addon. That is the same reasoning as bundling
    LibStub.
  - EMBEDDED-LIBRARIES §7's side-by-side rule exists for libraries that derive paths, or that
    have externals of their own. Neither applies. That section needs a matching exception, to be
    edited in a References session, not here.
  - v32 is the first version with `BNSendGameData`. If it is absent at call time, the library
    **fails closed** and reports. There is no hand-rolled pacer: it would be untested code once
    CTL ships with the library.
- **Consumers:**
  - must **not** ignore `Libs/LibAccountSync-1.0/ChatThrottleLib`;
  - **must** ignore `Libs/LibAccountSync-1.0/Tools` (the probe), alongside the usual repeated list
    (EMBEDDED-LIBRARIES §3).
- **LibDeflate is dropped.** A few KB doesn't need compression, and the escape codec (§2)
  replaces its channel encoding.
- **SHA-256 and HMAC-SHA-256** are copied from `Core.lua` 728-849. They are pure Lua with no
  `bit` library, so the game and the tests run the same code.

## 7. Measurement

To re-measure in game with two accounts on the same Battle.net account. The probe is
`Tools/LibAccountSyncProbe/`, modelled on AltStable's `Tools/AltStableProbe/BNet.lua`, with a
wire log and a Python reader like `read-wirelog.py`.

1. The prefix registers, and data is delivered **both ways, across rulesets and across
   factions**.
2. **Byte values 1-255** arrive intact in a 255-byte message, `|` and `\1` included, and `\0`
   needs the escape.
3. **Blank presence after `/reload`:**
   - the handshake completes;
   - the time to discover is logged;
   - a **one-sided** blank presence delivers both ways.
4. **SHA-256 cost** for 16 and 32 KB, timed with `debugprofilestop`. **Threshold: more than
   100 ms in one frame** brings back a faster hash (and, if needed, coroutine hashing). (Lowering
   the default `maxPayload` was the original alternative; see below.) Measured 2026-10-05: 249 ms for 16 KB, over the threshold (#8). A lower default would break the
   contract within MAJOR, so MINOR 3 uses the client's `bit` library instead, kept only if it
   reproduces the FIPS digests at load, with the pure-Lua path as the fallback. `/lasprobe hash`
   reports which path ran; hashing across frames is the next step only if `bit` is still over.
5. **ChatThrottleLib throughput** for 16 and 32 KB, plus any loss or reordering.
6. **Which Battle.net fields are secret**, if any, logged through `issecretvalue`.
7. **When the friends list becomes complete** after login, to check the 60 s wait.
8. **Project and region on live Forever** (the beta measured `wowProjectID` 18, `regionID` 90),
   and whether **peer records** carry `regionID` at all (§5.2).
9. **The relay precondition:**
   - does a friend set to **Appear Offline**, or one in the middle of logging into a game, look
     blank (or `isOnline` nil) to us?
   - can that friend still send game data?

   If yes, a friend can make themselves look like ours by elimination whenever they like, and the
   deferred relay items (§5.4) come back **before r1 is tagged**.

   **Owner decision, 2026-10-05 (#1):** `r2`, the first tag, was released before §7 was
   measured; the probe had not been deployed. §7.9 is still owed, and a positive result brings the
   deferred relay items into the next MINOR rather than blocking a tag that already exists.
10. Does `BNGetInfo`'s `presenceID` equal our `bnetAccountID`? Recorded for completeness;
    ownership is matched by BattleTag anyway (§5.2).

## 8. Repo layout

Copied from LibGlass:

```
LibAccountSync-1.0.xml        LibStub\LibStub.lua, ChatThrottleLib\ChatThrottleLib.lua, LibAccountSync.lua
LibAccountSync.lua            the one runtime file
LibStub/LibStub.lua
ChatThrottleLib/ChatThrottleLib.lua   (v32, vendored)
LICENSE  README.md  CLAUDE.md
.pkgmeta                      package-as LibAccountSync-1.0, enable-nolib-creation: no, LibGlass's ignore list
.github/workflows/check.yml   luac -p and the tests (LibGlass's)
Tools/deploy.ps1              LibGlass's, with the file list read from the XML
Tools/LibAccountSyncProbe/    the probe of §7
tests/run.ps1  harness.lua  wow_stubs.lua
tests/test_crypto.lua  test_discovery.lua  test_handshake.lua  test_transport.lua  test_api.lua
tests/test_stores.lua  test_upgrade.lua  test_isolation.lua  test_ctl.lua  test_secrets_grep.lua
```

### Test harness
- Plain Lua 5.1 with LibGlass's harness: strict globals, loading through the XML with
  `(host, ns)`, and `newproxy` secrets that throw.
- The simulated Battle.net (`WoW.bn`) and the ChatThrottleLib stub, with its 255-byte check, are
  ported from AltStable's `tests/wow_stubs.lua` (1407-1494 and 1617-1684).
- `test_ctl` runs the real vendored CTL against the stubs, as AltStable's does.

### Ported from AltStable's #58 block (`tests/test_comm.lua` 3272-4362)
- only our own other account counts: friends, offline accounts and missing ids are excluded;
- two failed lookups are not "the same account";
- a friend's game data is dropped unread;
- a friends list still loading, or with a gap, is never "ours";
- a friend's blank account gets no proof;
- a blank name with a GUID: the GUID decides;
- the key is learned only from a verified id;
- another region is not ours;
- bad proofs; a replay to another id; a hello with our own name, or contradicting Battle.net;
- the both-blank handshake, with no ping-pong;
- a learned name doesn't outlive its account;
- `TargetOffline`, and a late callback for an old binding;
- unordered reassembly;
- every message at most 255 bytes;
- Battle.net going away clears state;
- the FIPS 180-2 and RFC 4231 vectors.

### New
- one test per §5.2 row;
- MAC:
  - relay injection fails;
  - a one-sided blank presence delivers;
  - data that overtakes the last hello delivers, both with some chunks before the hello and with
    every chunk before it, including a single-chunk payload;
  - a relay pairing C's valid hello with A's valid stream fails, even with A's floor higher
    (the GUID binding);
  - a payload containing `|`, including a trailing one, round-trips;
  - a reflected own MAC is rejected;
- a leaked key presented from a stranger's id is not believed;
- stores:
  - a nil getter at login;
  - a later host's older key is not overwritten;
  - the shared-key split;
  - a newer store stays read-only;
- sid:
  - a reload within the same second (persisted `lastSid`);
  - more than 1000 sends in one second;
  - an old stream replayed under another id;
- an inert `New`;
- tag routing;
- one host's handler error isolated from another's.

### Upgrade and isolation
- **Upgrade (EMBEDDED-LIBRARIES §8):** a synthetic newer copy, since r1 has no predecessor. It
  checks that:
  - the frame and ticker are reused;
  - every closure and callback runs the new code exactly once;
  - state and public tables keep their identity;
  - an equal or older copy loading second does nothing;
  - a copy that throws mid-load leaves every entry point inert.
- **Isolation:** two hosts' instances, handlers and enabled switches never touch each other.

### Mutation testing
Every security, upgrade and isolation test is mutation-tested. Each of these must turn a test
red:
- drop a fail-closed branch;
- accept our own key;
- skip the MAC;
- key the sid floor by id;
- drop the sender GUID from the MAC;
- drop a complete stream instead of keeping it awaiting its hello;
- split the data body on `|`;
- capture `lib.impl`;
- drop the marker check.

## 9. After the plan

1. Implement r1 with the tests above.
2. GlassChat embeds it, pinned by `commit:`, and builds `/gchat ignore send`. The receiver applies
   the whole snapshot, removals included, with no merge.
3. Run the two-account in-game check, §7 including the §7.9 gate. Then tag `r1`. (As released:
   MINOR 1 failed the pilot, #4; `r2` was tagged after the pilot's two-account check passed, with
   §7 deferred by the owner's decision of 2026-10-05, #1.)
   (EMBEDDED-LIBRARIES §9).

## 10. Review log

### Round 1: internal, on the first draft (2026-10-04)
No P0; 10 P1s. Where each landed:

| # | Finding | Verdict |
|---|---|---|
| 1 | A copied SavedVariables folder (a friend's, or a profile import) installs a foreign key and trust | Deferred (owner stamp, §5.4); documented as a limit (§3) |
| 2 | Beta to live: a shared key proves across flavours, and the region check fails open | **Kept**: project and region in proof and MAC; region fails closed (§5.2) |
| 3 | A relay binding can replace the genuine binding (peers keyed by name) | Deferred (one binding per GUID); the GUID-keyed sid floor covers its replay half (§5.2) |
| 4 | Appear Offline may let a friend trigger elimination on demand | **Measurement gate §7.9**; the relay items return if it is confirmed |
| 5 | Snapshot replay or rollback within a session | **Kept**: monotonic sid (§5.2) |
| 6 | A store passed before SavedVariables load | **Kept**: getter-only store, lazy key choice (§1, §3) |
| 7 | `BNGetInfo`'s presenceID may be another id namespace | **Kept**: ownership by BattleTag (§5.2) |
| 8 | A secret value reads as "blank", and stubs can't catch `==` | **Kept**: the `UNKNOWN` accessor and the grep test (§5.2) |
| 9 | Liveness: data before hello, a lost nonce, a mid-flight reload | Partly kept (decision at completion, §5.3); the rest deferred (§5.4) |
| 10 | An older copy damaging a newer store | **Kept**: forward compatibility (§3) |
| 11-25 | Retired keys apart from trust; key pinning; `ResetKeys`; header arithmetic; marker gating every entry point; caps in the wire; key flip-flop between hosts; GUID fallback; SHA cost; CTL decision; per-character stores; field shapes; hello length; tag permanence; a reserved target argument | Header arithmetic, marker gating, wire caps, field shapes, hello length, tag permanence and CTL: **kept**. Key pinning, `ResetKeys`, GUID fallback, per-character warning: **deferred**. Retired keys: replaced by "never overwrite, oldest wins" (§3). Target argument: cut; the API can grow it later |

The cuts round 1 itself suggested were taken: no `min()` negotiation yet, no entropy-jitter pool,
no fallback pacer, and no `sendTo` option.

Between the rounds, the owner chose **AltStable parity**, and adopted the AltStable session's
advice to ship parity plus only nearly-free hardening.

### Round 2: internal, on the parity version (2026-10-04)
No P0; 3 P1s and 8 P2s. Every fix is cheap, and all are in:

| # | Finding | Fix |
|---|---|---|
| 1 (P1) | Only the receiver knew whether a MAC was needed, so a one-sided blank presence dropped streams silently while the sender reported "sent" | The sender always includes the MAC, and a destination needs a held nonce (§1, §5.3) |
| 2 (P1) | Writing the login-chosen key to every store overwrote existing keys whenever a store resolved late | Lazy choice once every store resolves; written only into stores with no key (§3) |
| 3 (P1) | Rejecting our own key broke accounts sharing one key through a copied WTF folder, which AltStable handles | Shared-key split: the lower GUID makes a new key (§3) |
| 4 | Deciding admission at the first frame lost a stream that overtook the last hello | Decide at completion for a sender that isn't verified (§5.3) |
| 5 | Sid counter unspecified; a per-id floor misses a relay's replay under another id | Counter defined; floor per (tag, sender GUID), raised after authentication; `sid` passed to `OnMessage` (§1, §5.2) |
| 6 | Contradictions: proof fields, instance dispatch, `New` throwing, sender capture, `onResult` timing | All specified (§1, §4, §5.1) |
| 7 | A trusted key in a hello is believed from any id (parity) | Believed only from a verified id, an elimination id, or one that holds our nonce (§5.2) |
| 8 | The `theirNonce` rule locked out a peer proven this session while the friends list fails closed | "Or proven this session" (§5.2) |
| 9 | Region failing closed rests on peer records carrying `regionID`, which is unmeasured | Gated on §7.8, with an `isInCurrentRegion` fallback (§5.2) |
| 10 | The hello can't grow if parsers anchor the field count | Parsers ignore extra trailing fields (§2); narrowed to the hello in round 3 |
| 11 | Hashing every Send could stall a frame | Threshold in §7.4; data at `NORMAL` priority (§2) |
| P3 | `{n}` isn't a Lua pattern; copy `keyAt` with the key; `lastSeen` refreshed on use; the buffer cap starved a second stream; an imported AltStable key needs the oldest `keyAt`; later store versions keep `key` | All taken (§2, §3, §5.2) |

### What neither round could break
- **Domain separation and nonce order:** a proof is never valid as a MAC, and the two directions
  can't be confused.
- **The MAC on chunk 1 binds every chunk:** `tag`, `sid`, `n` and the hash of the decoded payload
  are in it.
- **Verified status comes only from Battle.net**, so no stranger can choose the MAC-free path.
- **Reflection** of a hello or a stream is stopped by the own-name check and own-key rejection.
- **Identity from `senderID`:** a stranger can't inject into another id's stream.
- **Arithmetic:** the 75/44-byte headers, the `n` cap, about 205 bytes of hello.
- **Wire growth:** unknown frame types are ignored, and the domain strings carry the wire
  version.
- **Upgrade:** `lib.impl` dispatch and the completion marker.
- **The `\0` codec:** AltStable already sends arbitrary bytes over Battle.net.

### Round 3: Codex (gpt, owner-launched), at `d2013ff` (2026-10-04)
One P1 and three P2s, all fixed. Codex's verdict on §5.3: **keep the stream MAC**, with the
sender binding below.

| # | Finding | Fix |
|---|---|---|
| 1 (P1) | A relay could pair C's valid proven hello with A's valid stream, delivering A's data as C and replaying an old A snapshot under C's fresh floor | The sender GUID is in the MAC, checked against the binding's authenticated GUID (§5.3) |
| 2 | Every chunk arriving before the authenticating hello completed a stream that could never be delivered | A complete stream "awaiting hello" is kept for 10 s and re-checked when a hello is believed (§5.3) |
| 3 | A per-second counter restarts on a same-second `/reload`, so new sids fell below the floor; the 999 cap was undefined | `sid = max(GetServerTime()*1000, lastSid + 1)`, with `lastSid` persisted in the store and no cap (§3, §5.2) |
| 4 | "Ignore trailing fields" conflicts with a body that may contain `\|` | The body is everything after the sixth `\|`; trailing-field growth applies to the hello only (§2) |

Each fix has its acceptance case in §8.

### MINOR 4: `SendTo` (#14, 2026-10-06)
Asked for by AltStable (AltStable#198), settled on the issue with its session.
- Shape changed from the asked-for `Send(payload, onResult, target)` to `SendTo`: an older copy
  would have ignored the target and broadcast (§1).
- Wire, store and the reasons enum unchanged. The change narrows the destination set of an
  existing send; nothing new is believed or accepted.
- AltStable's key import writes its own store before first use; the library's existing rules
  (32-hex `ValidKey`, the trust cap, own key never trusted, oldest `keyAt` wins, §3) apply, so
  no `ImportKeys` call. AltStable confirmed its `bnetTrusted` only gained keys from
  Battle.net-verified ids (AltStable `Core.lua` 3486-3489), and tests the "imported oldest key
  wins" case with its import.
- Review: `/code-review high` on PR #15 (owner-launched). Taken: target selection moved out of
  the broadcast loop into `I.TargetIds`, which left a branch no test reached; detect `SendTo` at
  call time; `SendTo`'s payload error names `SendTo`; the pilot copy's instance gains `SendTo`; one
  shared, message-checking `errs`. Recorded, not changed: no fallback to a GUID's second id when
  the first fails, and the `guid` checked before the switch (both in §1).
- Codex (owner-launched) at `bc5fbf5`, the merged head: no actionable findings. It confirmed the
  destination set only narrows, at most one destination, and wire, MAC, store and ownership
  unchanged. Tagged `r4` on `830017a`.
