# timewarrior.nvim

A pure-Lua Neovim plugin that manipulates Timewarrior data files directly without calling the `timew` binary.

## Features

- `:TimewarriorStart [tags...]` to start tracking with optional tags.
- `:TimewarriorStartPicker` to pick tags using built-in Neovim UI selectors.
- `:TimewarriorStop` to stop the latest open interval.
- `:TimewarriorToday` to open an editable *today* view.
- Tag autocomplete in the today view via omnifunc (`<C-x><C-o>`).
- Writes updates back to Timewarrior `.data` files.
- `require("timewarrior").current_activity()` for status bar integration.

## Data source

The plugin reads/writes:

- `$TIMEWARRIORDB/data/*.data` when `TIMEWARRIORDB` is set.
- `~/.timewarrior/data/*.data` otherwise.

## Install

Use your preferred plugin manager. Example for `lazy.nvim`:

```lua
{
  "yourname/timewarrior.nvim",
}
```

No dependencies are required.

## Today buffer format

`TimewarriorToday` opens an `acwrite` buffer with lines like:

```text
09:00-11:00 projectA clientX
11:15- admin
```

Then write the buffer (`:write`) to persist changes.

## Notes

- Timestamps are written in Timewarrior UTC format: `YYYYMMDDTHHMMSSZ`.
- The plugin currently targets `inc` intervals.

## Lualine example

You can surface the currently running activity in lualine:

```lua
require("lualine").setup({
  sections = {
    lualine_c = {
      {
        function()
          return require("timewarrior").current_activity()
        end,
        cond = function()
          return require("timewarrior").current_activity() ~= ""
        end,
      },
    },
  },
})
```
