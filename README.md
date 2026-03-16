# Eco Scout — BAR Widget

**Author:** goddot  (sau hi in BAR)
**Game:** Beyond All Reason (BAR)  
**File:** `resource_scout.lua`

---

## Installation

1. Copy `resource_scout.lua` into your BAR widgets folder:
   ```
   Beyond All Reason/LuaUI/Widgets/resource_scout.lua
   ```
2. Launch BAR and open the widget list with **F11**.
3. Find **Eco Scout** in the list and enable it.

---

(preview.jpg)

## What it shows

The widget displays a compact overlay with three sections.

### ECO
Real-time economy figures pulled from your team resources.

| Row | Description |
|-----|-------------|
| Metal m/s | Your current metal income and expense per second |
| Energy e/s | Your current energy income and expense per second |
| M storage | Metal storage bar — fill %, current / cap |
| E storage | Energy storage bar — fill %, current / cap |
| Metal net | Net metal per second (income minus expense) |
| Energy net | Net energy per second (income minus expense) |

**Colour coding:**
- Income values are blue (metal) or amber (energy)
- Expense turns **red** when you are stalling (spending more than you make)
- Expense turns **orange** when storage is above 75% full (approaching waste)
- Storage bar turns orange above 75% fill, red above 95% (active waste)
- Net value is green when positive, red when negative
- **STALL** badge appears next to net when expense consistently exceeds income

### POWER
Derived values calculated from your live unit roster, health-weighted so damaged units count proportionally less.

| Row | Description |
|-----|-------------|
| Build power | Sum of `buildSpeed` across all your constructors and factories |
| Army value M | Total metal cost of your mobile combat units, scaled by current HP |
| Defense val M | Total metal cost of your static defense structures, scaled by current HP |

Values above 1000 are shown as `1.2k` etc.

---

## Controls

| Action | Effect |
|--------|--------|
| **Click and drag** | Move the widget anywhere on screen |
| **Scroll wheel** (while hovering) | Cycle through update intervals: 250ms → 0.5s → 1s → 2s → 5s |

The current update interval is shown in the title bar as `upd:0.5s (scroll)`.

---

## Update intervals

Eco stats (income, expense, storage) refresh at the configured interval.  
Unit stats (BP, AV, DV) always refresh at most once per second regardless of the eco interval, since iterating all units is heavier.

| Interval | Use case |
|----------|----------|
| 250ms | Maximum responsiveness, slightly more CPU |
| 0.5s | Default — good balance |
| 1s | Low impact, still useful |
| 2s / 5s | Minimal CPU, for slow machines or large unit counts |

---

## Configuration

Open `resource_scout.lua` in a text editor and find the `CFG` table near the top:

```lua
local CFG = {
    w           = 255,       -- widget width in pixels
    bgAlpha     = 0.82,      -- background opacity (0.0 transparent – 1.0 solid)
    fontSize    = 13,        -- text size
    padding     = 9,         -- inner padding
    rowH        = 20,        -- row height
    intervals   = { 0.25, 0.5, 1.0, 2.0, 5.0 },  -- update interval options
    intervalIdx = 2,         -- default interval index (2 = 0.5s)
}
```

To move the default starting position, find these two lines in `widget:Initialize` and `widget:ViewResize` and adjust the second offset value:

```lua
posY = screenH - boxH() - 60   -- increase to move down, decrease to move up
```

---

## Compatibility

- Requires **BAR** running on the Spring engine with Lua 5.1
- Uses only standard Spring Lua API calls — no external dependencies
- Does not use deprecated fields (`isCommander` is not referenced)
