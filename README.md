# timewarrior.nvim

[![CI](https://github.com/aquaherd/timewarrior.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/aquaherd/timewarrior.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Neovim >= 0.9](https://img.shields.io/badge/Neovim-%3E%3D%200.9-green.svg)](https://neovim.io)

**Track time without leaving Neovim.**

A Neovim plugin for [Timewarrior](https://timewarrior.net/) that delegates all data operations to the `timew` CLI.

## Features

- `:TimewarriorStart [tags...]` to start tracking with optional tags.
- `:TimewarriorStartPicker` to pick tags using built-in Neovim UI selectors.
- `:TimewarriorStop` to stop the latest open interval.
- `:TimewarriorToday` to open an editable *today* view.
- Tag autocomplete in the today view via omnifunc (`<C-x><C-o>`).
- All mutations go through `timew` — no direct data file access.
- `require("timewarrior").current_activity()` for status bar integration.

## Requirements

- Neovim >= 0.9
- [Timewarrior](https://timewarrior.net/) (`timew`) in your `PATH`

## Install

Use your preferred plugin manager. Example for `lazy.nvim`:

```lua
{
  "aquaherd/timewarrior.nvim",
}
```

No dependencies are required.

## Configuration

```lua
require("timewarrior").setup({
  cache_ttl = 30,       -- seconds to cache activity/tags (default 30)
  notify_level = vim.log.levels.INFO,  -- minimum level for notifications
  header = {            -- lines shown at the top of the today view
    "# Timewarrior Today",
    "# %A, %B %d %Y",   -- strftime format, evaluated per-day
    "# Edit lines and :write to persist",
    "# Format: HH:MM-HH:MM tag1 tag2  (or HH:MM- for active)",
    "",
  },
})
```

All options are optional. Omitted values keep their defaults.

## Today buffer format

`TimewarriorToday` opens an `acwrite` buffer with lines like:

```text
09:00-11:00 projectA clientX
11:15- admin
```

Then write the buffer (`:write`) to persist changes.

## Tag completion in today view

Inside `:TimewarriorToday`, tag completion is available via omnifunc.

1. Put the cursor at the end of a partial tag (for example: `09:00-10:00 cli`).
2. Press `<C-x><C-o>` in Insert mode.
3. Pick one of the suggested tags collected from existing Timewarrior data files.

This uses Neovim's built-in omni-completion and works without extra dependencies.

The buffer filetype is `timewarrior`, so you can scope completion plugins to that filetype only.

### nvim-cmp

```lua
local cmp = require("cmp")

cmp.setup.filetype("timewarrior", {
  sources = cmp.config.sources({
    { name = "omni" },
    { name = "buffer" },
  }),
})
```

### blink.cmp

```lua
require("blink.cmp").setup({
  sources = {
    per_filetype = {
      timewarrior = { "omni", "buffer" },
    },
  },
})
```

### mini.completion

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "timewarrior",
  callback = function(ev)
    vim.bo[ev.buf].omnifunc = "v:lua.require'timewarrior'.complete_tags"
  end,
})
```

## Notes

- Timestamps are written in Timewarrior UTC format: `YYYYMMDDTHHMMSSZ`.
- `:TimewarriorToday` displays and edits times in your local timezone, then saves back as UTC.
- Header lines support `strftime` format specifiers (via `os.date`), evaluated per-day. Use `%%` for a literal `%`.
- The today view supports both closed (`HH:MM-HH:MM`) and open (`HH:MM-`) intervals.

## Health check

Run `:checkhealth timewarrior` to verify `timew` is installed and report the Neovim version.

## Highlight groups

The plugin defines three highlight groups linked to standard groups by default:

| Group | Default |
|---|---|
| `TimewarriorComment` | `Comment` |
| `TimewarriorTime` | `Number` |
| `TimewarriorTag` | `Keyword` |

Override with `:highlight`:

```vim
:hi TimewarriorTag guifg=#ff9900
```

## Timezone regression checks

Run the timezone harness to validate UTC/local conversions and local-day membership behavior across multiple `TZ` settings:

```bash
bash scripts/run_tz_regression.sh
```

The script runs the checks with `nvim --headless` for:

- `UTC`
- `Europe/Berlin`
- `America/New_York`
- `Asia/Tokyo`
- `Pacific/Auckland`

## Lualine example

You can surface the currently running activity in lualine.

`current_activity()` returns a string like `"projectA clientX"` when tracking, or `"No activity"` when idle. Results are cached (configurable via `cache_ttl`, default 30 s); starting or stopping an interval invalidates the cache immediately.

The plugin ships a lualine component, so you can reference it by name:

```lua
require("lualine").setup({
  sections = {
    lualine_x = { "timewarrior" },
  },
})
```
