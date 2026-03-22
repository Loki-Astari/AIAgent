# CLAUDE.md

This file provides guidance for AI coding agents (Claude Code, Cursor, etc.) when working with code in this repository.

## Project Overview

This is **AIAgent.nvim**, a Neovim plugin that integrates AI agent CLIs into the editor. It opens an agent CLI in a right-side terminal split with a header showing keybind instructions.

## Development

This is a Neovim plugin with no build step. To apply changes in a running session:
1. Ensure the plugin directory is in your Neovim runtimepath
2. Restart Neovim or run `:lua package.loaded['aiagent'] = nil` followed by `require('aiagent').setup(...)` to reload

All autocmds are registered under the `AIAgent` augroup, so reloading via `setup()` clears and re-registers them cleanly.

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s busted-compatible runner.

**Run all tests (headless):**
```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

**Override the plenary path** (if not at the default lazy.nvim location):
```bash
PLENARY_DIR=~/.local/share/nvim/lazy/plenary.nvim nvim --headless \
  -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

**Run a single spec file:**
```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/aiagent_spec.lua"
```

Test files live in `tests/` and follow the `*_spec.lua` naming convention. The `tests/minimal_init.lua` bootstraps plenary and the plugin runtimepath.

## Architecture

- `plugin/aiagent.lua` - Lua entry point, defines commands (`:AgentOpen`, `:AgentClose`, `:AgentToggle`, etc.)
- `lua/aiagent/init.lua` - Main Lua module with all plugin logic
- `lua/aiagent/health.lua` - Health check implementation (`:checkhealth aiagent`)
- `doc/aiagent.txt` - Vimdoc help file (`:help aiagent`)

The plugin manages state via module-level variables (`M.agents`, `M.current_agent`, `M.win`, `M.header_buf`, `M.header_win`, `M.prev_win`) and uses autocmds for cleanup on QuitPre/VimLeavePre.

Each agent entry in `M.agents[name]` tracks: `buf`, `job_id`, `scroll_mode`, `scroll_pos`, `agent_type`, `command`, `sent_files`, `color`, `worktree` (path or nil), `git_root` (repo root or nil), `slug` (worktree slug or nil).

## Lualine Integration

The following public functions provide lualine.nvim component helpers. All live on the `M` table in `lua/aiagent/init.lua`.

| Function | Returns | Purpose |
|----------|---------|---------|
| `M.lualine_label()` | `string\|nil` | `"Agent: Claude"` or `"Scroll Mode: Claude"` when the agent terminal is focused; `nil` otherwise |
| `M.lualine_color()` | `table\|nil` | `{ bg = '#0891b2' }` (cyan) for input mode, `{ bg = '#7c3aed' }` (purple) for scroll mode; `nil` otherwise |
| `M.lualine_branch()` | `string\|nil` | Actual branch of the agent's worktree (via `git branch --show-current`), or `nil` when not focused on the agent terminal |
| `M.lualine_mcp()` | `string` | Space-separated list of `✓ name` for each connected MCP server |
| `M.lualine_mcp_color()` | `table\|nil` | `{ fg = '#22c55e' }` (green) when results are loaded; grey while pending |
| `M.mcp_refresh()` | — | Clears the MCP cache and triggers an immediate `claude mcp list` refresh |

### MCP status implementation

- `claude mcp list` is run as an async job (`vim.fn.jobstart`) on first use and every 30 seconds thereafter
- Only lines matching `✓ Connected` are kept; `claude.ai` auto-discovered servers are filtered out
- The `claude.ai ` prefix is stripped from display names
- Results are stored in the module-level `_mcp_cache` table (`{ name, connected }` per entry)
- `_mcp_last_read` is set immediately when a refresh starts to prevent concurrent jobs

## Key Patterns

- Use `pcall` for all window/buffer operations that might fail during cleanup
- Terminal jobs require both `chanclose` and `jobstop` for reliable cleanup
- Window options are set via `nvim_set_option_value` with scope parameters

## Git Worktree Support

Worktrees are **persistent** — they are not removed when an agent is closed or Neovim exits.

### Naming convention

| Item | Pattern |
|------|---------|
| Branch | `agent/{slug}` |
| Directory | `$TMPDIR/nvim-agent-{repo}-{slug}` (symlinks resolved via `vim.fn.resolve`) |

Where `{slug}` is the `WTName` lowercased with non-alphanumeric characters replaced by `-`. When no `WTName` is given, the agent `Name` is used as the slug source.

### Command syntax

`:AgentOpen [Name [WTName [directory]]]`

- `Name` — agent name (default: `AIAgent`)
- `WTName` — worktree name; `-` is shorthand for using the agent name. The slug (lowercase, non-alphanumeric → `-`) is derived from this and used for the branch and default directory.
- `directory` — explicit directory for a **new** worktree; error if the worktree already exists

### Auto-reconnect logic

Worktrees are found by matching the branch name `agent/{slug}` via `git worktree list --porcelain`. This is more reliable than path comparison (unaffected by symlinks or directory moves).

On `:AgentOpen Name` (no `WTName`), the plugin:
1. Derives a slug from `Name` and calls `git worktree list --porcelain` to scan for a worktree with branch `refs/heads/agent/{slug}`
2. If found, reconnects silently and sets the agent's `cwd` to the worktree path from the porcelain output
3. If not found, opens with the current directory (no worktree)

On `:AgentOpen Name WTName [directory]`:
1. Derives a slug from `WTName` and scans for a worktree with branch `refs/heads/agent/{slug}`
2. If found and no `directory` given, reconnects; if found and `directory` given, errors
3. If not found, creates a new worktree at `vim.fn.expand(directory)` if given, otherwise at `$TMPDIR/nvim-agent-{repo}-{slug}`
4. Handles the edge case where the branch exists but the worktree directory was manually removed (uses `git worktree add <path> <branch>` without `-b`)

### Worktree file redirect

Two autocmds cooperate to redirect file opens to the active agent's worktree:

- **`BufNew`** — fires when a new buffer is created. If the path is inside the git repo but not already in the worktree, the buffer is renamed to the worktree path and tagged with `vim.b[buf].aiagent_name`.
- **`CmdlineLeave` + `BufEnter`** — handles `:e X` when `X` is already open in a non-worktree buffer. `CmdlineLeave` sets a flag when an `:e`/`:edit` command is detected and **clears it** for any other command (including `<Esc>`), so a cancelled `:e` never leaves a stale flag. `BufEnter` only redirects when that flag is set (clears immediately after). This prevents redirect on passive buffer switches (e.g. `<C-\><C-n>`, bufferline clicks).

### Bufferline integration

`M.bufferline_name_formatter(buf)` is a public function for use as bufferline's `name_formatter` option. It reads `vim.b[buf.bufnr].aiagent_name`, looks up `M.agents[name].slug`, and prefixes the filename: `slug: filename`. Returns `nil` (default name) for non-worktree buffers or when the agent has no slug.

### Scroll mode

Press `<C-\><C-s>` in terminal mode to enter scroll mode (normal mode in the terminal buffer).

- **First entry**: cursor jumps to `scroll_start_line` (config option, default `9`), skipping the agent's startup preamble
- **Re-entry**: cursor is restored to `agent.scroll_pos` (saved as a `{ row, col }` copy when exiting scroll mode)

The `scroll_pos` is stored as `{ pos[1], pos[2] }` (an explicit copy), not a reference, to avoid Lua table aliasing bugs with `nvim_win_get_cursor`.
