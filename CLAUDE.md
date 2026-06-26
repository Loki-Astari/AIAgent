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

- `plugin/aiagent.lua` - Lua entry point, defines commands (`:AgentOpen`, `:AgentClose`, `:AgentToggle`, `:AgentSendDiagnostics`, `:AgentDiff`, `:AgentChat`, etc.)
- `lua/aiagent/init.lua` - Main Lua module with all plugin logic
- `lua/aiagent/prompthistory.lua` - Prompt-history diff viewer (see [Prompt History](#prompt-history))
- `lua/aiagent/health.lua` - Health check implementation (`:checkhealth aiagent`)
- `hooks/prompt_snapshot.sh` - Claude Code `pre`/`post` hooks that capture per-prompt git tree snapshots
- `hooks/prompt_history_inspect.sh` - Terminal tool to list/dump captured sessions
- `skills/prompt-history/` - Bundled Claude skill, installed into `~/.claude/skills/` by `:AgentInstallSkill`
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

## LSP Diagnostics

`:AgentSendDiagnostics` collects LSP diagnostics for the current buffer via
`vim.diagnostic.get(bufnr)` and sends a pre-formatted prompt to the active agent.

Key implementation details in `M.send_diagnostics(agent_name, line1, line2)`:

- `line1`/`line2` are optional 1-indexed line numbers (from a visual range); when
  provided, diagnostics outside that range are filtered out before sending.
- Active LSP clients are collected via `vim.lsp.get_clients({ bufnr = bufnr })`.
  `client.config.settings` is preferred for compiler options; `client.config.init_options`
  is used as a fallback.
- Before sending the text, `\x1bi` is sent to the terminal to ensure the agent is
  in insert mode (ESC exits any vim mode, `i` enters insert). This is required when
  the agent uses vim keybindings (e.g. Claude's vim mode).
- The message text does **not** end with `\n` — the text is typed into the prompt
  but not submitted, so the user presses Enter to initiate the analysis.
- The command is registered with `{ range = true }` so it can be invoked as
  `:'<,'>AgentSendDiagnostics` from a visual selection.

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

## Prompt History

Captures the code changes produced by each prompt of an agent session and
displays them in a side-by-side diff viewer.

### Capture (`hooks/prompt_snapshot.sh`)

A Claude Code hook wired into user `~/.claude/settings.json`:
`UserPromptSubmit → prompt_snapshot.sh pre`, `Stop → prompt_snapshot.sh post`.

- Records a turn as a pair of git tree SHAs. Trees are built in a **temp index**
  (`read-tree HEAD` + `add -A` excluding `.prompt-history` + `write-tree`), so
  they capture committed + uncommitted + untracked files uniformly, survive
  commits, and never record the history dir itself.
- One JSONL file per session at
  `<repo>/.prompt-history/sessions/<session_id>.jsonl`, anchored on the git
  **common** dir (`git rev-parse --path-format=absolute --git-common-dir`) so all
  worktrees of a repo share one location. Pending turn held in
  `pending-<session>.json`, closed on the next `pre` if interrupted.
- Each record: `session, started, ended, prompt, before_tree, after_tree,
  changed_files, cwd, head, branch`. Zero-change turns are still recorded.
- The hook writes no stdout (it would pollute the prompt context) and always
  exits 0, so capture failures never block a turn.

### Viewer (`lua/aiagent/prompthistory.lua`)

- Opens in a **new tabpage**, leaving the agent terminal in `M.win` untouched.
  Layout: left column (instructions / prompt list / changed-files), right pane
  `before | after` via native `:diffthis`.
- Reconstructs file content with `git show <tree>:<path>` — **never** `git diff`
  for content (a user's external difftool may hijack plain `git diff`; only
  `--no-ext-diff` / `--name-status` / `git show` are safe). `changed_files()`
  parses `git diff --no-ext-diff --name-status -M`.
- `M.state` is `nil` when closed. Opening with no completed turns yet leaves it
  `nil` (nothing to show) — that is expected, not a failure.

### Entry points (`lua/aiagent/init.lua`)

- `current_session()` — resolves the running agent's PID →
  `~/.claude/sessions/<pid>.json` → `{ id, cwd }`.
- `prompt_history_open(session?)` — opens the viewer (default: current session);
  closes any open viewer first to refresh with newly captured prompts.
- `prompt_history_close()` — closes the viewer, back to chat.

Commands `:AgentDiff [session]` / `:AgentChat` are registered in
`plugin/aiagent.lua`. They can also be driven remotely (e.g. from an agent) via
`nvim --server "$NVIM" --remote-expr "luaeval(\"require('aiagent').prompt_history_open()\")"`.

### Bundled skill (`skills/prompt-history/`, `:AgentInstallSkill`)

A `prompt-history` Claude skill ships in `skills/` so it can be distributed with
the plugin. `M.install_skill({ force, dest })` (command `:AgentInstallSkill[!]`)
copies it into `~/.claude/skills/prompt-history/`:

- The plugin root is resolved from the file's own path via
  `debug.getinfo(1, 'S').source` → `:p:h:h:h` (absolute, then up out of
  `lua/aiagent/`). Exposed for tests as `M._plugin_root`.
- The bundled skill uses a `__AIAGENT_HOOKS_DIR__` placeholder for any hook-path
  reference; the installer substitutes this install's real `<root>/hooks` so the
  inspect-script and hook-setup snippets are copy-pasteable for the target user.
  **When editing the bundled skill, never hard-code an absolute hooks path — use
  the placeholder.**
- Refuses to overwrite an existing skill install unless `force` (the command's
  `!`).
- After copying, offers to wire the capture hooks via `M.install_hooks`
  (`opts.hooks`: `nil` = prompt with `vim.fn.confirm`, `true` = wire silently,
  `false` = skip — tests/headless pass `false`).

`M.install_hooks({ settings })` merges the `UserPromptSubmit`/`Stop` entries
into `~/.claude/settings.json`:

- **Uses `jq`, not a Lua JSON round-trip.** Re-encoding the whole file through
  `vim.fn.json_decode`/`json_encode` would coerce any empty `[]` (e.g.
  `permissions.allow`) into `{}` and corrupt unrelated settings — jq preserves
  the rest of the file and the `[]`/`{}` distinction. Writes a `.bak` first.
- **Idempotent.** An event whose hooks already reference `prompt_snapshot.sh` is
  left untouched; only missing entries are appended. Returns `(changes, wrote)`.
- Does not auto-detect jq absence fatally — if `jq` isn't on PATH it returns a
  change note telling the user to wire manually, rather than failing the skill
  copy.

## GitHub MCP Setup

### Overview
The GitHub MCP connector for Claude Code requires a workaround because Claude Code only supports
Dynamic Client Registration (DCR) for OAuth, but GitHub's MCP endpoint does not support DCR.
The fix is to use `mcp-remote` as a proxy with a pre-registered GitHub OAuth App.

### Prerequisites
- A GitHub OAuth App with:
  - **Authorization callback URL**: `http://localhost:3334/oauth/callback`
  - A Client ID and Client Secret

To create/manage the OAuth App: https://github.com/settings/developers

### Configuration
The MCP server is configured in `~/.claude.json` via:

```bash
claude mcp add --transport stdio github -- \
  npx mcp-remote https://api.githubcopilot.com/mcp/ \
  --port 3334 \
  --static-oauth-client-info '{"client_id": "YOUR_CLIENT_ID", "client_secret": "YOUR_CLIENT_SECRET"}'
```

Key details:
- **Correct MCP endpoint**: `https://api.githubcopilot.com/mcp/` (trailing slash required)
- **`--port 3334`** is required to pin the callback port — without it, mcp-remote picks a random port each run, breaking the OAuth callback URL match
- **Transport**: stdio (not http), because the remote HTTP transport returns 404

### Re-authenticating
If the connection breaks, run inside Claude Code:
```
/mcp
```
Select `github` and complete the browser OAuth flow.

### Gotchas
- `https://api.github.com/mcp` (wrong) → 404
- `https://api.githubcopilot.com/mcp/` (correct)
- The GitHub OAuth App callback URL must exactly match the port mcp-remote uses — always use `--port 3334` to keep it stable
- Claude.ai's GitHub connector (at claude.ai/settings/connectors) is a **separate system** from Claude Code's MCP config and they do not share state
