# LibAccountSync-1.0

An embedded LibStub library for World of Warcraft: Forever (Interface 16001) addons: send small
messages to **your own other WoW accounts** on the same Battle.net account, and receive them,
with ownership proven before anything is sent or accepted.

Embedded with LibStub; players don't install it separately.

> **Status:** `r3` released, its two-account pairing and sync validated in game (`r2` by
> GlassChat's pilot; `r1` was never tagged, #4). Measured in game (#1): delivery across rulesets,
> all byte values, no secret fields. **Open:** the §7.9 relay check and two other measurements that
> need a Battle.net friend (#9); the `bit`-backed hash's speed in game (#8). GlassChat is the pilot
> consumer.

## Using it

```lua
local Sync = LibStub("LibAccountSync-1.0"):New({
    addon = "GlassChat",        -- your wire tag: 1-16 letters or digits, permanent
    -- A getter for an ACCOUNT-WIDE SavedVariables table (nil until it loads).
    -- It holds the household key: keep it out of any profile export.
    store = function() return GlassChatDB and GlassChatDB.accountSync end,
    report = function(text, kind) end,   -- optional
    maxPayload = 16384,                  -- optional, at most 32768
})

Sync.OnMessage(function(payload, sender, sid)
    -- payload: the string sent (data only: never run it)
    -- sender: { guid, name, realm, faction, proven = "bnet" | "key" | "proof" },
    --         from Blizzard's sender id, never from the message
    -- sid: grows per sender, to order snapshots
end)

local count, why = Sync.Send(payload, function(sender, status, reason)
    -- once per destination: "sent" (handed to the wire) or "failed" + reason
end)
-- why: "disabled", "no-peers", "too-large", "not-ready", "offline", "no-route"

Sync.Peers()  Sync.Rescan()  Sync.SetEnabled(on)  Sync.IsEnabled()
for line in Sync.Diagnostics() do print(line) end
```

Within `LibAccountSync-1.0` this API only grows.

## Embedding

`.pkgmeta`:
```yaml
externals:
  Libs/LibAccountSync-1.0:
    url: https://github.com/Spotnick2/LibAccountSync
    tag: r3
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
