# Changelog

Built and tested on game version 2.31 unless a line says otherwise. "Not run in game" means the version was checked by syntax check and mock only.

## 0.5.10 - 2026-11-01
### Added
- Block + attack push launches NPCs with its own "Push Force" (default 60), without a health drop.
### Changed (after release of this version, 2026-11-13)
- The body-slam check runs 10 times per second instead of every frame.

Not run in game.

## 0.5.9 - 2026-11-01
### Added
- With "Heavy punches only" on, the charged punch, body slam and block push shove vehicles.
- At most one shove per vehicle every 0.3 seconds.

Not run in game.

## 0.5.8 - 2026-11-01
### Fixed
- Non-lethal: the non-lethal flag is now set in the game's `PreProcess` damage stage instead of `Process`, so another damage mod that reads the flag early sees it. Knocked-out bodies can be finished again.

Confirmed in game.

## 0.5.7 - 2026-10-31
### Changed
- Non-lethal spares only the first hit; a later punch finishes a downed body.
- Head hits leave a wound instead of removing the head.

## 0.5.6 - 2026-10-30
### Changed
- Ground slam only ragdolls human enemies: no damage, no kill, no limb loss.

## 0.5.5 - 2026-10-30
### Changed
- The punch itself is flagged non-lethal in the damage pipeline (redscript companion file added).

## 0.5.2 - 2026-10-26
### Fixed
- Non-lethal never raises an NPC's health.
- Bosses and elite police units ignore the non-lethal option.
### Changed
- Slider renamed "Drop to health %".

Released on Nexus Mods.

## 0.5.1 - 2026-10-23
### Fixed
- Bodies that died in flight could not be looted: the mod now clears the "not interactable" mark the game leaves on them.
- Downed NPCs no longer get health back from the non-lethal floor.
- Hits within 0.25 seconds are merged (a crash was reported with rapid hits during time dilation).
### Added
- "Heavy punches only", per-target cooldown.
- Experimental options: killing blow only, head option on kill, ground slam, vehicle shove, armor stance.
### Changed
- The arms are detected by item type. Default force 90, vehicle force 12.

Released on Nexus Mods. Launch, force settings and loot fix played in game.

## 0.5.0 - 2026-10-22
- Test build, never released.

## 0.4.0
- Bindable on/off hotkey with a notification.

## 0.3.0
- First release: punches launch NPCs along the aim; force, upward bias, hostility; non-lethal health floor.
