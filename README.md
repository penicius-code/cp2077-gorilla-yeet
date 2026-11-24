# Gorilla Yeet

Gorilla Arms punches launch the target as a ragdoll along your aim, for Cyberpunk 2077. Single-player only.
Version 0.5.10 | Built and tested on game version 2.31; see Status for what was tested | Status: 0.5.2 released and in use, 0.5.9 and 0.5.10 not yet play-tested

> This is an unofficial fan work and is not approved/endorsed by CD PROJEKT RED. No game files are included.

Published on Nexus Mods as "Ragdoll Physics for Gorilla Arms Cyberware" (version 0.5.2 there): <https://www.nexusmods.com/cyberpunk2077/mods/29014>

## The problem

Gorilla Arms are the heavy-hitting arm cyberware, but a punch only staggers the target. There is no sense of weight. Mods that add ragdoll forces existed, but a body that died in flight could not be looted, and a "knock out instead of kill" option was undone by the game's own ragdoll impact rules: anyone hitting a wall above 41 km/h dies.

## What I built

A Cyber Engine Tweaks script (690 lines of Lua) with a small redscript companion (417 lines). It changes: the impulse applied to an NPC or vehicle hit by a Gorilla Arms punch, how wall and ground impacts of launched NPCs are graded, whether a launched body stays lootable, and, optionally, whether punches knock out instead of kill.

## How it works

- The Lua script observes hits on NPCs and vehicles. If the attacker is the player and the weapon type is the Gorilla Arms, it applies a ragdoll impulse along the camera direction with a configurable force and upward bias.
- Hits arriving within 0.25 seconds of each other are merged, so fast multi-hits do not stack impulses.
- Loot fix: the game marks a ragdolling NPC as not interactable and clears that mark only when the ragdoll behaviour ends. An NPC that dies in flight never reaches that point. The script clears the mark itself.
- The redscript file wraps the game's damage functions (`@wrapMethod` only, nothing is replaced). It grades the impact of a launched NPC by speed and fall height: bruised below 41 km/h, knocked out from 41 km/h, killed from 90 km/h or a 12 m fall. With "Non-lethal" on, the punch itself is flagged non-lethal for ordinary human enemies; bosses and elite police units are excluded.
- Settings are stored in `config.json` next to the script and edited in an overlay window.

```text
package/
  bin/x64/plugins/cyber_engine_tweaks/mods/gorillayeet/
    init.lua       the mod
    json.lua       JSON library by rxi (MIT), see THIRD_PARTY_LICENSES.md
  r6/scripts/PushPullNonLethal/
    PushPullNonLethal.reds   impact grading and non-lethal rules
```

## Requirements

| Requirement | Tested with | Link |
|---|---|---|
| Cyberpunk 2077 | 2.31 | |
| Cyber Engine Tweaks | 1.37.1 | [Nexus Mods, mod 107](https://www.nexusmods.com/cyberpunk2077/mods/107) |
| redscript | 0.5.31 | [Nexus Mods, mod 1511](https://www.nexusmods.com/cyberpunk2077/mods/1511) |

Requirements are not bundled. Install them first from their own pages. The redscript file compiles on its own against the unmodified game scripts.

## Install

1. Install the requirements above.
2. Copy the contents of `package/` into the game folder, so that `bin\x64\plugins\cyber_engine_tweaks\mods\gorillayeet\init.lua` and `r6\scripts\PushPullNonLethal\PushPullNonLethal.reds` exist.
3. Start the game, equip Gorilla Arms and land a heavy punch. Open the CET overlay to find the "Gorilla Yeet" window.

Upgrading: copy over the previous version. `config.json` is kept.

## Uninstall / roll back

1. Close the game.
2. Delete the folder `bin\x64\plugins\cyber_engine_tweaks\mods\gorillayeet`.
3. Delete the folder `r6\scripts\PushPullNonLethal`.
4. Saves are not affected: the mod stores nothing in them. Requirements are left alone.

## Configuration

CET overlay window "Gorilla Yeet". Defaults in brackets.

| Option | Meaning |
|---|---|
| Enabled (on) | Master switch |
| Heavy punches only (on) | Light jabs behave as in the base game |
| Yeet Force (90), Upward Bias (30) | Strength and arc of the launch |
| Push launches NPCs (on), Push Force (60) | Block + attack push also launches |
| Grade wall hits (on) | Knocked out from 41 km/h, killed from 90 km/h or a 12 m fall |
| Non-lethal (off), Drop to health % (40) | Punches knock out ordinary human enemies |
| Make targets hostile (on) | |
| Cooldown (0 s) | 0 to 15 seconds between launches |
| Make yeeted bodies lootable (on) | The loot fix |
| Killing blow only (off), head option on kill (off), Ground slam also yeets (on), Punches shove vehicles (on, force 12 x mass), Armor stance (on) | Experimental group |
| Debug logging (off) | Lines prefixed `[GorillaYeet]` in the CET console |

Two hotkeys can be bound in CET's Bindings tab, both unbound by default: "Toggle Gorilla Yeet on off" and "Toggle Non-lethal".

## Status

| Version | Result |
|---|---|
| 0.5.1 | Released. Launch, force settings and loot fix played in game on 2.31 (2026-10-22 and 2026-10-23). |
| 0.5.2 | Released on Nexus Mods. |
| 0.5.8 | Non-lethal flag fix confirmed in game on 2.31 (2026-11-01). |
| 0.5.9, 0.5.10 | Not run in game. Checked by LuaJIT syntax check and a mock of the NPC and vehicle hooks. |
| Game 2.5 | Not play-tested. All 6 redscript wrap targets and the 3 Lua hook targets exist in the 2.5 game scripts with the same signatures. |

## Compatibility

| Item | Status | Notes |
|---|---|---|
| Ped Damage Overhaul 2077 | works with one setting | Its "Enable for Non-Lethals" option must stay off while Non-lethal is used here. |
| Other mods that wrap the same damage functions | should coexist | Only wraps are used; nothing is replaced. |

## Known issues

- A fully charged punch shoves cars but plays the vanilla hit on NPCs.
- Bosses and scripted NPCs may ignore ragdoll impulses.
- Very high force values can throw NPCs out of the loaded area.

## Engineering notes

**Symptom.** With Non-lethal on, a knocked-out body could not be finished by later punches, and another installed damage mod still treated the knockout punch as lethal.

**Diagnosis.** A hit logger showed no "damage dealt" rows for punches on downed bodies, while the mod's own hit log showed 14 punches landing. So the hits arrived but were zeroed. Reading the game's damage pipeline gave the cause: the other mod reads the non-lethal flag during the game's `PreProcess` stage, and this mod added its flag one stage later, in `Process`. The other mod therefore started its "dying" state on every knockout and kept the body invulnerable.

**Fix.** Version 0.5.8 moved the flag into a `PreProcess` wrap. Confirmed in game the same day.

**Second case: bodies that could not be looted.** The game marks a ragdolling NPC as not interactable and removes the mark when the ragdoll behaviour ends. An NPC that dies mid-flight never ends that behaviour. Version 0.5.1 clears the mark itself.

**Rollback.** Each version was installed with a backup of the previous script, so a bad build could be swapped back by copying one file. For a user: delete two folders.

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Latest: 0.5.10 (2026-11-01): block + attack push launches NPCs with its own force.

## Credits and licence

`json.lua` is by rxi, MIT licence: see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). Runs on Cyber Engine Tweaks and redscript, which are not included here.

MIT, see [LICENSE](LICENSE). The licence covers my code only. Game names and trademarks belong to their owners.

Built with AI assistance (Claude); designed, tested and maintained by me.
