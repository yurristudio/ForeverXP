## What's new in 0.5.2

- **Layout Adjustments:** Redesigned text positioning to prevent UI collisions when scaling. The center text (Current/Max XP) is now locked to a highly visible, shadow-backed size. The "Next LVL" estimation has been moved inside the bar, seamlessly appended next to your current level.
- **Custom Text Coloring & Scaling:** The "Completed Quests" and "Rested XP" values under the bar are now distinctly color-coded (Yellow and Blue) for immediate visual feedback. You can now resize this specific text independently from the rest of the bar using the new "Bottom Quests/Rested Size" slider in the Adjust tab.
- **New Feature: Auto Questing.** Added a toggle to automatically accept and turn in quests to accelerate leveling. Hold **Shift** while interacting with an NPC to temporarily pause the automation if you want to read the lore.
- **Fix: Persistent UI Hiding.** The "Hide Default Experience Bar" option now hooks aggressively into the Blizzard UI frame manager, ensuring the default bar stays hidden even after completely exiting and relaunching the game.

# ForeverXP 0.5.1

Visual XP bar for World of Warcraft: Forever with an "aurora" look:
teal-to-violet gradient fill, amber segment for quest XP sitting unclaimed in
your log, mint segment for banked rested bonus, soft glow and a glass edge.
Settings live in an ElvUI-style panel opened from the XP minimap button.

## Install

Copy the `XPBar` folder into:

```
World of Warcraft/_classic_beta_/Interface/AddOns/XPBar/
```

`/reload` or relog. Upgrading from 0.4.0: the color palette is reset once and
the removed Played Time option is dropped; everything else is kept.

## What's new in 0.5.1

- **Fix: Settings saving issues.** Addressed a problem where settings (such as hiding the default Blizzard XP bar) were lost after quitting the game to the desktop or typing `/reload`. The addon now correctly re-applies these settings upon logging back in.
- **New Feature: Auto Accept/Turn-in Quests.** Added an option to automatically accept and turn in quests to speed up leveling. If you want to read the quest text, simply hold down **Shift** while interacting with the NPC to temporarily pause the automation.
  
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
