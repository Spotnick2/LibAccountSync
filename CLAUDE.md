# CLAUDE.md

LibAccountSync-1.0: an embedded LibStub library for **WoW: Forever 1.60.1** (Interface `16001`,
Lua 5.1). It lets an addon send small messages to the player's own other WoW accounts on the same
Battle.net account, and receive them, with ownership proven first. Single owner (Spotnick).

**Status: planning.** Start from this repo's first issue, which holds the plan and the research
behind it. The plan is written to `docs/PLAN.md` and reviewed adversarially (Codex, launched by
the owner) **before any code**, because this is security code: a mistake hands a stranger the
player's lists.

## Read first

- `C:\Projects\References\EMBEDDED-LIBRARIES.md`: how an embedded library is built, versioned,
  upgraded in place, packaged and tested here. Follow it: one runtime file, version guard,
  completion marker, upgrade and isolation tests.
- `C:\Projects\AltStable\docs\SYNC-DISCOVERY.md`: the design this library starts from, with
  measured behaviour and three adversarial review rounds. Its closed routes stay closed.
- `C:\Projects\AltStable\Core.lua`: the code to seed from (line ranges in the first issue).
  **Never edit AltStable from this repo's sessions.** It keeps its own channel until it migrates
  in its own session.
- `C:\Projects\LibGlass` (one runtime file, instances, upgrade tests) and
  `C:\Projects\LibGroupBuffs` (consumers, version fixtures): the templates.
- `C:\Projects\References\PORTING-TBC-TO-FOREVER.md` and
  `C:\Projects\References\forever-api-1.60.1.70205.md`: client facts and the API dump.

## Conventions (sibling addons')

- Issue → branch → PR (`Closes #N`) → review (owner-launched) → the owner merges.
- Lua 5.1 toolchain at `C:\Program Files (x86)\Lua\5.1\`. Plain-Lua tests with strict-globals
  stubs; secrets are `newproxy` values that throw; mutation-test new tests.
- Every client value that can be a secret is checked with `issecretvalue` before any use.
- Right-size for a single maintainer.
