# ForeverXP v0.5.4

## Layout changes

- **New row above the bar**: "Time this level" (left) and "Time this session" (right) now have their own dedicated line above the XP bar, instead of being squeezed onto it.
- **Next LVL ETA moved off the bar**: previously appended next to "Level" on the bar itself, it now sits under the bar, right after the XP/Hour text, in a smaller font.
- **Completed / Rested moved**: previously centered under the bar, it's now under the bar on the right.
- **XP / Max XP is bigger by default** (15pt vs the old fixed 13pt) and is now resizable like every other element, instead of being a fixed size.
- Final layout:
  - **Above bar:** Time this level (left) · Time this session (right)
  - **On bar:** Level (left) · XP / Max XP (center) · % (right)
  - **Under bar:** XP/Hour + Next LVL ETA (left) · Completed / Rested (right)

## Rested segment redesigned

- Rested XP is no longer a solid mint block. It's now a translucent overlay using the bar's own fill gradient (instead of a fixed color), sitting right after the current progress — a "ghost" preview of how far rested XP extends.
- Automatically follows whichever color preset or class color is active.
- Removed the old glow/soft-glass edge effect around the bar for a flatter, cleaner edge.
- Background is more transparent (opacity reduced).

## Per-element text visibility

- Every text element can now be individually shown or hidden — 8 total, up from 4. Newly toggleable: Level, XP / Max XP, %, and "Time this level."
- Fixed a bug where hiding XP/Hour also silently hid "Time this level," with no way to separate them — each now has its own independent toggle.
- New slash commands: `/fxp leveltext`, `/fxp xptext`, `/fxp pcttext`, `/fxp leveltime` (on/off).

## Independent text sizing

- Every text element now resizes independently (8 sliders total, up from 2 shared sizes: one "main" size for the on-bar/under-bar-left/right text, and one "bottom" size for the center text).
- New slash commands: `/fxp centersize <n>` (XP / Max XP), `/fxp etasize <n>` (Next LVL ETA). `/fxp fontsize <n>` now sets Level, %, both above-bar texts, and XP/Hour together; `/fxp bottomsize <n>` sets Completed/Rested.
- Old settings are migrated automatically on upgrade — existing custom sizes carry over instead of resetting to default.

## Settings panel restructuring

- **Adjust tab** split into three sub-tabs (Bar Size / On-Bar Text / Off-Bar Text) to fit all 8 size sliders.
- **Options tab** split into two sub-tabs (Bar Text / Bar) to fit all 8 visibility toggles alongside the general bar settings.

## Wording cleanup

- "Completed Quests" → "Completed", "Rested XP" → "Rested", "XP/h" → "XP/Hour" for consistency.
- Separator between Completed/Rested changed from "-" to "•".


## 0.5.3

**New**
- Colors tab with 8 built-in presets — Aurora, Fire, Ocean, Emerald, Royal, Crimson, Gold, Ice — pick one from a swatch grid to recolor the bar's fill and border.
- Use My Class Color option: builds the bar's gradient from your actual class color instead of a preset.
- Show Border toggle (Options → Bar), **off by default** — the outline is now opt-in.
- Show Bar toggle (Options → Bar): hide or show the entire bar. The minimap button and settings panel keep working while the bar is hidden.
- New `/fxp` shortcut — every command works with `/fxp` as well as `/foreverxp` (e.g. `/fxp menu`, `/fxp width 300`).
- New commands: `/fxp show`, `/fxp hide` and `/fxp toggle` to show or hide the bar.

**Changed**
- Settings panel is slightly taller to fit the new option.
- Info tab and in-game command help now list `/fxp`.

**Fixed**
- Class color wasn't being detected due to a Lua expression bug (`X and X(...)` truncates multi-return values) — class color now reads correctly every time.

**Notes**
- Preset and class-color choices persist the same way as your other settings.
- Selecting a preset turns off Class Color automatically, and vice versa.
- Existing users: your saved settings are kept and the bar stays visible after updating.
- `/foreverxp` still works as before.

What's new in 0.5.2
Layout Adjustments: Redesigned text positioning to prevent UI collisions when scaling. The center text (Current/Max XP) is now locked to a highly visible, shadow-backed size. The "Next LVL" estimation has been moved inside the bar, seamlessly appended next to your current level.
Custom Text Coloring & Scaling: The "Completed Quests" and "Rested XP" values under the bar are now distinctly color-coded (Yellow and Blue) for immediate visual feedback. You can now resize this specific text independently from the rest of the bar using the new "Bottom Quests/Rested Size" slider in the Adjust tab.
New Feature: Auto Questing. Added a toggle to automatically accept and turn in quests to accelerate leveling. Hold Shift while interacting with an NPC to temporarily pause the automation if you want to read the lore.
Fix: Persistent UI Hiding. The "Hide Default Experience Bar" option now hooks aggressively into the Blizzard UI frame manager, ensuring the default bar stays hidden even after completely exiting and relaunching the game.

# ForeverXP 0.5.1

Fix: Settings saving issues. Addressed a problem where settings (such as hiding the default Blizzard XP bar) were lost after quitting the game to the desktop or typing /reload. The addon now correctly re-applies these settings upon logging back in.
New Feature: Auto Accept/Turn-in Quests. Added an option to automatically accept and turn in quests to speed up leveling. If you want to read the quest text, simply hold down Shift while interacting with the NPC to temporarily pause the automation.

## Install

Copy the `XPBar` folder into:

```
World of Warcraft/_classic_beta_/Interface/AddOns/XPBar/
```

`/reload` or relog. Upgrading from 0.4.0: the color palette is reset once and
the removed Played Time option is dropped; everything else is kept.

## What's new in 0.5.1

- **Fix: settings lost on `/reload` (most visible on the Adjust sliders).**
  0.5.0 adopted the saved table on ADDON_LOADED, but this beta client can
  inject `ForeverXPDB` later or swap it mid-session - writes then landed in
  a table the game never serializes. The DB now re-syncs with the game's
  table once a second: live edits are moved into whatever table the game
  actually saves, or ours is published if none arrives. Test: drag a slider,
  `/reload`, value should stick.

## What was new in 0.5.0

- **Settings now persist** across `/reload` and relog (SavedVariables are now
  attached on `ADDON_LOADED`; the old code wrote into a table the game threw
  away). Note the game writes them on `/reload` or a clean logout/exit - not
  if the client crashes or is killed.
- **XP/hour no longer shows `--` until reload.** Time spent on the current
  level is tracked locally (saved per character); `/played` only corrects it.
  After a level-up the previous speed is kept until the new level has data.
- **Settings panel is solid and ElvUI-styled** (flat dark boxes, 1px borders,
  value-color accents; picks up ElvUI's colors/font when ElvUI is loaded).
  ESC closes it.
- **XP minimap icon**, left-click opens settings. Works with square (ElvUI)
  minimaps.
- **Played Time removed** from the bar and from the settings.
- **Session Time restarts from 0:00:00 on every login.** It survives `/reload`
  and zoning.
- **Time to next level** under the bar, on the left:
  `Next level: ~1h 24m  (15.2k XP left of 28.0k)`, computed as
  XP left / XP-per-hour.
- **Text Size (8-24) and Normal/Bold** in the Adjust tab. Bold uses a thick
  outline (the game has no bold variant of the font). Applies to every bar text.

## Minimap button

| Input | Effect |
|---|---|
| Left-click | Open/close the settings |
| Right-click | Lock/unlock the bar |
| Left-drag | Move the button around the minimap |

## Bar text layout

| Slot | Content | Toggle (default) |
|---|---|---|
| Left | `45.2k XP/h` | XP / Hour (on) |
| Center | `Completed: 12.0% - Rested: 8.0%` | Completed & Rested (on) |
| Right | `Session: 0:14:32` | Session Time (on) |
| Under bar, left | `Next level: ~1h 24m (15.2k XP left of 28.0k)` | Time to Next Level (on) |

## Settings tabs

- **Options** - text toggles, quest/rested segments, show at max level, hide
  default XP bar, lock.
- **Adjust** - Bar Width (60-600), Bar Height (8-60), Text Size (8-24),
  Text Style (Normal / Bold). Mouse wheel on a slider fine-tunes (Shift = x10).
- **Info** - command list.

## Slash commands

| Command | Effect |
|---|---|
| `/xpbar menu` | Open the settings |
| `/xpbar lock` / `unlock` | Allow/stop dragging |
| `/xpbar quest` / `rested` / `text` / `leveling` / `session` / `timeleft` `on/off` | Toggles |
| `/xpbar maxlevel on/off` | Show bar at max level |
| `/xpbar hideblizzard on/off` | Hide default XP bar |
| `/xpbar width <n>` / `height <n>` | Bar size |
| `/xpbar fontsize <n>` / `bold on/off` | Text size / style |
| `/xpbar reset` | Reset position and size |

## Known gaps

- Hide Default Experience Bar covers the usual frame names; if Forever renamed
  its XP bar the toggle silently does nothing.
- Quest XP uses `C_QuestLog` + `GetQuestLogRewardXP`, `pcall`-wrapped; a
  permanently-0 amber segment means the API names changed.
- The time-to-level estimate uses your average speed on the current level
  (idle time in town lowers it). It is an estimate, not a promise.
- Big text on a narrow bar can make the left/center/right slots overlap; widen
  the bar or lower the text size.
