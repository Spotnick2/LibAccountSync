# LibAccountSync-1.0

An embedded LibStub library for World of Warcraft: Forever (Interface 16001) addons: send small
messages to **your own other WoW accounts** on the same Battle.net account, and receive them,
with ownership proven before anything is sent or accepted.

Embedded with LibStub; players don't install it separately.

> **Status:** `r4` released, adding `SendTo` (one peer, #14). `r3`'s two-account pairing and sync
> are validated in game (`r2` by GlassChat's pilot; `r1` was never tagged, #4). Measured in game (#1): delivery across rulesets,
> all byte values, no secret fields. **Open:** the §7.9 relay check and two other measurements that
> need a Battle.net friend (#9). GlassChat is the pilot consumer.

## Using it

```lua
local Sync = LibStub("LibAccountSync-1.0"):New({
    addon = "GlassChat",        -- your wire tag: 1-16 letters or digits, permanent
    -- A getter for an ACCOUNT-WIDE SavedVariables table (nil until it loads).
    -- It holds the household key: keep it out of any profile export.
    store = function() return GlassChatDB and GlassChatDB.accountSync end,
    report = function(text, kind) end,   -- optional
    maxPayload = 16384,                  -- optional, at most 32768 (hashing a full 32 KB send
                                         -- costs about 130 ms in game; 16 KB about 65 ms, #8)
    messages = true,                     -- optional (r5): see "Snapshots or messages" below
})

Sync.OnMessage(function(payload, sender, sid)
    -- payload: the string sent (data only: never run it)
    -- sender: { guid, name, realm, faction, proven = "bnet" | "key" | "proof" },
    --         from Blizzard's sender id, never from the message
    -- sid: grows per sender, to order snapshots (or messages)
end)

local count, why = Sync.Send(payload, function(sender, status, reason)
    -- once per destination: "sent" (handed to the wire) or "failed" + reason
end)
-- why: "disabled", "no-peers", "too-large", "not-ready", "offline", "no-route"

-- r4: one peer, by a GUID from Peers(). Never a broadcast; one result. Detect it
-- when you call it (if Sync.SendTo then ...), not at load: an instance made by an
-- older copy gains it when a newer copy loads.
local n, why = Sync.SendTo(guid, payload, onResult)   -- 1, 0 (not ready), or nil, why

Sync.Peers()  Sync.Rescan()  Sync.SetEnabled(on)  Sync.IsEnabled()
for line in Sync.Diagnostics() do print(line) end
```

Within `LibAccountSync-1.0` this API only grows.

## Snapshots or messages

- **Snapshots (the default):** each send replaces the last. A stream completing after a newer one
  from the same sender and tag is dropped, so an old snapshot never lands over a new one.
- **Messages (`messages = true`, r5):** sends are independent (a request, a reply, a ping). Each
  is delivered once, in the order it completes, even when a small one overtakes a large one;
  order by `sid` yourself if you need to. Check `Sync.messages == true` after `New`: an older copy
  ignores the option and delivers snapshots. Limits: up to 4 streams open at once per sender, and
  a stream overtaken by more than 256 newer ones is refused. Register `OnMessage` right after
  `New`.
- **Two kinds of snapshot in one addon** (lists and settings): make one instance per kind, each
  with its own tag, on the same store getter, e.g. `addon = "GlassChatST"`. Each tag has its own
  ordering, and the instances share the key, peers and handshake; works on every release. The
  on/off switch lives in the store, so flip both together.

## Embedding

`.pkgmeta`:
```yaml
externals:
  Libs/LibAccountSync-1.0:
    url: https://github.com/Spotnick2/LibAccountSync
    tag: r4
ignore:
  # CurseForge's packager doesn't apply an external's own ignore list:
  - Libs/LibAccountSync-1.0/tests
  - Libs/LibAccountSync-1.0/docs
  - Libs/LibAccountSync-1.0/Tools
  - Libs/LibAccountSync-1.0/CLAUDE.md
  - Libs/LibAccountSync-1.0/README.md
```
Don't ignore `ChatThrottleLib/` or `LibStub/`: the XML loads them. The TOC loads
`Libs\LibAccountSync-1.0\LibAccountSync-1.0.xml` before the addon's own files. A dev copy deploys
with `pwsh ..\LibAccountSync\Tools\deploy.ps1 -Addon <YourAddon>`.

## What to know

- One prefix (`LibAcctSync`) and one household key per account, shared by every addon that embeds
  the library: addons in one client share a Lua environment, so a co-hosted addon can read the
  keys. Never copy SavedVariables between people or game flavours.
- Ownership is proven by Battle.net itself when it can say whose account an id is; when a presence
  is blank, by a household key and HMAC-SHA-256 proofs. The accepted limit, from AltStable's
  design: a friend whose friends-list entry is misread as yours and who runs a purpose-built relay
  could relay proofs; the stream MAC keeps such a relay from changing what you send. Details:
  `docs/PLAN.md`.
- `"sent"` means handed to the wire. There is no delivery acknowledgement yet.
- For a blank-presence sender, the proof binds the name lower-cased: compare `sender.name`
  case-insensitively (character names are unique across the region).

## Where it comes from

AltStable's own-account channel (Spotnick2/AltStable #58, `docs/SYNC-DISCOVERY.md`): discovery
over Battle.net, ownership by Battle.net account and BattleTag with a household key and
HMAC-SHA-256 proofs, Battle.net game data in 255-byte messages. Bundled: LibStub and
ChatThrottleLib v32 (both public domain).

## Licence

MIT.
