# CLAUDE.md

This file provides guidance for AI coding agents (Claude Code, Cursor, etc.) when working with code in this repository.

## Project Overview

This is **AIAgent.nvim**, a Neovim plugin that integrates AI agent CLIs into the editor. It opens an agent CLI in a right-side terminal split with a header showing keybind instructions.

## Development

This is a Neovim plugin with no build step. To test changes:
1. Ensure the plugin directory is in your Neovim runtimepath
2. Restart Neovim or run `:lua package.loaded['aiagent'] = nil` to reload

No test framework is currently configured.

## Architecture

- `plugin/aiagent.vim` - VimScript entry point, defines commands (`:AgentOpen`, `:AgentClose`, `:AgentToggle`, etc.)
- `lua/aiagent/init.lua` - Main Lua module with all plugin logic

The plugin manages state via module-level variables (`M.agents`, `M.current_agent`, `M.win`, `M.header_buf`, `M.header_win`, `M.prev_win`) and uses autocmds for cleanup on QuitPre/VimLeavePre.

Each agent entry in `M.agents[name]` tracks: `buf`, `job_id`, `worktree` (path or nil), `git_root` (repo root or nil).

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
| Directory | `$TMPDIR/nvim-agent-{slug}` (symlinks resolved via `vim.fn.resolve`) |

Where `{slug}` is the `WTName` lowercased with non-alphanumeric characters replaced by `-`. When no `WTName` is given, the agent `Name` is used as the slug source.

### Command syntax

`:AgentOpen [Name [WTName [directory]]]`

- `Name` — agent name (default: `AIAgent`)
- `WTName` — worktree name; `-` is shorthand for using the agent name. The slug (lowercase, non-alphanumeric → `-`) is derived from this and used for the branch and default directory.
- `directory` — explicit directory for a **new** worktree; error if the worktree already exists

### Auto-reconnect logic

On `:AgentOpen Name` (no `WTName`), the plugin:
1. Derives a slug from `Name` and calls `git worktree list --porcelain` to scan for the expected path
2. If found, reconnects silently and sets the agent's `cwd` to the worktree
3. If not found, opens with the current directory (no worktree)

On `:AgentOpen Name WTName [directory]`:
1. Derives a slug from `WTName` and scans for an existing worktree
2. If found and no `directory` given, reconnects; if found and `directory` given, errors
3. If not found, creates a new worktree at `directory` (or the auto-generated path)
4. Handles the edge case where the branch exists but the worktree directory was manually removed (uses `git worktree add <path> <branch>` without `-b`)

Path comparison resolves symlinks on both sides to handle the macOS `/var` → `/private/var` symlink.

### Worktree file redirect

Two autocmds cooperate to redirect file opens to the active agent's worktree:

- **`BufNew`** — fires when a new buffer is created. If the path is inside the git repo but not already in the worktree, the buffer is renamed to the worktree path and tagged with `vim.b[buf].aiagent_name`.
- **`CmdlineLeave` + `BufEnter`** — handles `:e X` when `X` is already open in a non-worktree buffer. `CmdlineLeave` sets a flag when an `:e`/`:edit` command is detected; `BufEnter` only redirects when that flag is set (clears immediately after). This prevents redirect on passive buffer switches (e.g. `<C-\><C-n>`, bufferline clicks).

### Bufferline integration

`M.bufferline_name_formatter(buf)` is a public function for use as bufferline's `name_formatter` option. It reads `vim.b[buf.bufnr].aiagent_name` and prefixes the filename: `AgentName: filename`. Returns `nil` (default name) for non-worktree buffers.
