# LibAccountSync-1.0

An embedded LibStub library for World of Warcraft: Forever (Interface 16001) addons: send small
messages to **your own other WoW accounts** on the same Battle.net account, and receive them,
with ownership proven before anything is sent or accepted.

Embedded with LibStub; players don't install it separately.

> **Status:** planning. Nothing is implemented yet. See the first issue for the plan.

## Where it comes from

AltStable's own-account channel (Spotnick2/AltStable #58, `docs/SYNC-DISCOVERY.md`):
- discovery of your other online accounts over Battle.net;
- ownership by Battle.net account and BattleTag, with a household key and HMAC-SHA-256 proofs
  when a presence is blank;
- Battle.net game data in 255-byte chunks.

It moves into a library so more than one addon can use it without copying it.

## First consumers

- **GlassChat**, its pilot: Spam & Ignore copies its ignore and mute lists to your other accounts
  (Spotnick2/GlassChat #33).
- **AltStable**, later, in its own time.

## Licence

MIT.
