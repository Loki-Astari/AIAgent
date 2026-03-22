# AIAgent.nvim

A Neovim plugin that opens AI agent CLIs in a right-side terminal split, with a header showing keybind instructions.

## Features

- **Seamless window management** - Your agent opens in a right-side terminal split that stays out of your way
- **Auto-insert mode** - Moving into the agent window automatically enters insert mode, so you can start typing immediately without extra keystrokes
- **Live buffer updates** - When your agent modifies files, Neovim automatically detects the changes and reloads the buffers. You'll always see the latest version of your code without manually running `:e` or `:checktime`
- **Easy navigation** - Press `<C-\><C-n>` to exit terminal mode and jump back to your previous editing window
- **Clean exit handling** - The plugin properly cleans up terminal jobs when closing Neovim, preventing "job still running" warnings
- **Buffer context integration** - Automatically send open buffer file paths to the agent, giving it context about what you're working on
- **Visual selection support** - Select code and send it directly to the agent to ask questions about specific snippets
- **LSP diagnostics integration** - Send compiler errors and warnings from the current file (or a visual selection of lines) to the agent, pre-formatted with file name, language server options, and context text ready for analysis
- **Scroll mode** - Browse agent output history without leaving the window; position is remembered between sessions
- **Git worktree support** - Isolate each agent's work in its own branch and directory, with automatic reconnect across sessions
- **Idle attention alerts** - When a background agent finishes or pauses for input, its tab is highlighted with a `●` indicator so you know to switch back
- **Lualine integration** - Optional helpers for lualine.nvim: shows the active agent name and mode in section A, the worktree branch in section B, and connected MCP servers in section X

## Requirements

- Neovim 0.9+
- An agent CLI installed and available in your PATH (for example, [Claude Code CLI](https://claude.ai/code), [Cursor](https://cursor.com/cli))

Run `:checkhealth aiagent` after installation to verify your setup.

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "Loki-Astari/AIAgent",
  config = function()
    require("aiagent").setup()
  end,
}
```

### [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "Loki-Astari/AIAgent",
  config = function()
    require("aiagent").setup()
  end,
}
```

### [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'Loki-Astari/AIAgent'
```

Then call setup in your init.lua:

```lua
require("aiagent").setup()
```

## Configuration

```lua
require("aiagent").setup({
  width = 0.4,                -- Width as percentage (0-1) or absolute columns (>1)
  default_agent = "claude",   -- Symbolic agent name to use on startup
  auto_send_context = false,  -- Auto-send open buffer paths when entering terminal
  agent_startup_delay = 1500, -- ms to wait before sending /color on agent start
  show_header = true,         -- set to false to hide the keybind instruction header
  scroll_start_line = 9,      -- line to jump to when first entering scroll mode
  idle_timeout_ms = 8000,     -- ms of silence after activity before flagging (0 = disabled)
  idle_notify = false,        -- also fire vim.notify when flagging attention
  mcp_max_width = 35,         -- max statusline columns for MCP display before scrolling
  mcp_scroll = true,          -- scroll MCP display when wider than mcp_max_width
  -- Extend or override the built-in agent → executable mapping
  known_agents = {
    mytool = "my-custom-cli",
  },
})
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:AgentSet {agent}` | Set which agent CLI to use for new agents (e.g. `claude`, `cursor`) |
| `:AgentSetColor {color}` | Change the color of the current agent |
| `:AgentOpen [Name [WTName [directory]]]` | Open an agent terminal (see below for full syntax) |
| `:AgentClose [name]` | Close an agent (defaults to current) |
| `:AgentToggle [name]` | Toggle an agent terminal |
| `:AgentSwitch {name}` | Switch to an existing agent by name |
| `:AgentList` | Show running agents |
| `:AgentCloseAll` | Close all agents |
| `:AgentSendContext` | Send open buffer file paths to the agent |
| `:AgentResetContext` | Reset tracking to re-send all buffer paths |
| `:'<,'>AgentSendSelection` | Send visual selection to the agent |
| `:AgentSendDiagnostics` | Send LSP diagnostics for the current file to the agent |
| `:'<,'>AgentSendDiagnostics` | Send LSP diagnostics for the selected lines only |

### Supported agents

| Name | CLI executable |
|------|---------------|
| `claude` | `claude` (Anthropic Claude Code) |
| `cursor` | `cursor-agent` (Cursor AI) |
| `aider` | `aider` |
| `gemini` | `gemini` (Google Gemini CLI) |
| `codex` | `codex` (OpenAI Codex CLI) |
| `goose` | `goose` (Block's Goose) |
| `plandex` | `plandex` |
| `cody` | `cody` (Sourcegraph Cody) |
| `amp` | `amp` |

Examples:

```
:AgentSet cursor                               " switch to Cursor for new agents
:AgentOpen                                     " opens a Cursor agent named 'AIAgent'
:AgentSet claude                               " switch back to Claude
:AgentOpen Review                              " opens a Claude agent named 'Review'
:AgentOpen Feature -                           " opens a Claude agent in a worktree named 'feature'
:AgentOpen Feature MyWT                        " opens a Claude agent named 'Feature' in a worktree named 'MyWT'
:AgentOpen Feature MyWT ~/trees/myWT           " same, but creates the worktree at a specific directory
:AgentSetColor green                           " change the current agent's color
```

### Keybindings

When in the agent terminal:

| Keybinding | Mode | Description |
|------------|------|-------------|
| `<C-\><C-n>` | terminal | Exit terminal mode and return to your previous window |
| `<C-\><C-s>` | terminal | Enter scroll mode |
| `<C-\><C-a>` | terminal | Cycle to the next agent |
| `<C-\><C-c>` | terminal | Send open buffer file paths as context |
| `<C-\><C-v>` | terminal | Paste the unnamed register `"` into the terminal input |
| `i` | scroll | Exit scroll mode and resume terminal interaction |
| `<C-\><C-n>` | scroll | Exit scroll mode and return to your previous window |

### Scroll mode

Press `<C-\><C-s>` to enter scroll mode, which lets you browse output history using normal-mode motions (`j`/`k`/`G`/`/` etc.) without leaving the agent window.

- **First entry**: jumps to line `scroll_start_line` (default: 9), skipping the agent's startup preamble
- **Re-entry**: restores the cursor position from your last scroll session

Press `i` to return to terminal input, or `<C-\><C-n>` to jump back to your editing window.

### Idle attention alerts

When you start a long-running job in one agent and switch to another, the plugin watches for the first agent to finish or pause. When it detects that a background agent has produced new output and then gone silent, its tab is highlighted and a `●` symbol is appended:

```
[ Review ] [ Feature ● ]   ← Feature needs attention
```

The alert clears automatically when you switch back to that agent. If the agent resumes work (produces more output), the alert is also cleared immediately.

**How detection works:**

- The plugin records the buffer line count each time you visit an agent
- While in the background, the agent's output is tracked — only genuine new lines count (cursor blinks and prompt redraws are ignored)
- Once the output has been silent for `idle_timeout_ms` (default: 8 seconds), the tab is flagged
- Agents that are idle because they haven't been asked anything are never flagged — only agents that were actively producing output and then stopped

**Configuration:**

```lua
require("aiagent").setup({
  idle_timeout_ms = 8000,  -- silence threshold in ms (0 = disable)
  idle_notify     = false, -- also fire vim.notify when flagging
})
```

### Suggested Mappings

```lua
vim.keymap.set("n", "<leader>ao", "<cmd>AgentOpen<cr>",             { desc = "Open agent (default)" })
vim.keymap.set("n", "<leader>ac", "<cmd>AgentOpen Cursor<cr>",      { desc = "Open Cursor agent" })
vim.keymap.set("n", "<leader>ax", "<cmd>AgentClose<cr>",            { desc = "Close current agent" })
vim.keymap.set("n", "<leader>at", "<cmd>AgentToggle<cr>",           { desc = "Toggle current agent" })
vim.keymap.set("v", "<leader>as", "<cmd>AgentSendSelection<cr>",    { desc = "Send selection to agent" })
vim.keymap.set("n", "<leader>ad", "<cmd>AgentSendDiagnostics<cr>",  { desc = "Send LSP diagnostics to agent" })
vim.keymap.set("v", "<leader>ad", "<cmd>AgentSendDiagnostics<cr>",  { desc = "Send LSP diagnostics (selection) to agent" })
```

## Buffer Context Integration

The plugin can send file paths of your open buffers to the AI agent, giving it context about what you're working on. This uses the `@file` syntax that Claude Code understands (Not tested for Cursor yet).

### How it works

1. Open the files you want the agent to have context on
2. Switch to the agent terminal
3. Press `<C-\><C-c>` or run `:AgentSendContext`
4. The plugin types `@file1 @file2 ...` into the terminal
5. Type your question and press Enter

The plugin tracks which files have been sent to each agent, so subsequent calls only send newly opened files. Use `:AgentResetContext` to clear the tracking and re-send all files.

### Auto-send mode

Enable `auto_send_context = true` in your setup to automatically send new buffer paths whenever you enter the agent terminal:

```lua
require("aiagent").setup({
  auto_send_context = true,
})
```

## Visual Selection

Select code in visual mode and send it to the agent to ask questions about specific snippets.

### How it works

1. Select code using visual mode (`v`, `V`, or `<C-v>`)
2. Run `:'<,'>AgentSendSelection` or use your mapped key (e.g., `<leader>as`)
3. The selected code is sent to the agent wrapped in a markdown code block with the filetype
4. The agent terminal is focused so you can type your question

If no agent is running, one will be started automatically.

## LSP Diagnostics

Send compiler errors and warnings from the active LSP directly to the agent, pre-formatted with enough context that the agent can start analysing immediately.

### How it works

1. Open a file that has LSP diagnostics (errors, warnings, etc.)
2. Run `:AgentSendDiagnostics` (or use your mapped key, e.g. `<leader>ad`)
3. The plugin collects diagnostics from the active LSP, formats them, and types the following into the agent's prompt:
   - A brief description asking the agent to analyse and suggest fixes
   - The file path
   - The language server name(s) and their compiler/workspace settings (JSON)
   - All diagnostics wrapped in a fenced ` ```<Errors> ` block, sorted by line and column
4. The agent terminal is focused with the text ready — press Enter to submit

The agent is always left in **insert mode** before the text is typed, so the command works correctly even when the agent uses vim keybindings.

### Limiting to a visual selection

To send only the diagnostics that fall within a specific range of lines, select those lines in visual mode first:

```
" Normal mode — all diagnostics in the file
:AgentSendDiagnostics

" Visual mode — only diagnostics on the selected lines
:'<,'>AgentSendDiagnostics
```

If no agent is running, one will be started automatically.

## Git Worktree Support

When starting a new agent on a separate task it can be useful to isolate it in its own git worktree, so its changes don't interfere with your current working tree.

### AgentOpen syntax

```
:AgentOpen [Name [WTName [directory]]]
```

| Argument | Description |
|----------|-------------|
| `Name` | Agent name shown in the tab (default: `AIAgent`) |
| `WTName` | Worktree name. `-` is shorthand for using the agent `Name`. Determines the branch (`agent/<slug>`). |
| `directory` | Explicit path for a **new** worktree (absolute or relative; `~` is expanded). Error if the worktree already exists. |

### Naming convention

| Item | Pattern |
|------|---------|
| Branch | `agent/{slug}` |
| Default directory | `$TMPDIR/nvim-agent-{repo}-{slug}` |

Where `{slug}` is the `WTName` lowercased with non-alphanumeric characters replaced by `-`, and `{repo}` is the repository directory name (prevents clashes across different repos). If no `directory` is given, the default path under `$TMPDIR` is used.

### Creating a worktree agent

Pass a `WTName` as the second argument. Use `-` as shorthand when you want the worktree named after the agent:

```
:AgentOpen Feature -                    " worktree name = 'Feature' (branch: agent/feature)
:AgentOpen Feature MyWT                 " agent named 'Feature', worktree named 'MyWT'
:AgentOpen Feature - ~/trees/feature    " worktree at an explicit path
:AgentOpen Feature MyWT ~/trees/mywt    " both explicit name and path
```

This will:
1. Create a branch `agent/<slug>` from the current `HEAD` (or reuse it if it already exists)
2. Check it out into `$TMPDIR/nvim-agent-{repo}-{slug}`, or the explicit `directory` if given
3. Start the agent with that directory as its working directory

### Persistent worktrees

Worktrees are **persistent** — they are not removed when you close the agent or exit Neovim. The plugin finds existing worktrees by matching the branch name `agent/{slug}`, so reconnect works reliably even if the worktree directory was moved.

When you reopen an agent by the same `Name`, the plugin automatically detects any existing worktree and reconnects — no need to pass `WTName` again:

```
" Session 1: create the worktree
:AgentOpen Feature -

" Session 2: auto-detected from branch name, no WTName needed
:AgentOpen Feature
```

To permanently remove a worktree when you are done with it:

```bash
git worktree remove $TMPDIR/nvim-agent-myrepo-feature
git branch -d agent/feature
```

### Opening files in the worktree

While a worktree agent is active (i.e. it is the current agent), opening a file with `:e` will automatically redirect to the worktree version of that file. For example, if the worktree is at `$TMPDIR/nvim-agent-myrepo-feature` and you run:

```
:e src/main.cpp
```

The plugin opens `$TMPDIR/nvim-agent-myrepo-feature/src/main.cpp` instead of the working-tree copy. The bufferline tab will be prefixed with the worktree slug (e.g. `feature: main.cpp`) to make it clear which version you are editing.

If the worktree version of the file is already open in another buffer, that buffer is reused rather than opening a duplicate.

Switching to an existing buffer directly (e.g. via bufferline or `<C-^>`) does **not** trigger a redirect — only an explicit `:e` command does.

## Bufferline Integration

To prefix worktree-redirected buffer tabs with the worktree slug, pass the formatter to bufferline's `name_formatter` option:

```lua
require('bufferline').setup({
  options = {
    name_formatter = require('aiagent').bufferline_name_formatter,
  },
})
```

Tabs for worktree files will display as `slug: filename` (e.g. `feature: main.cpp`). Non-worktree buffers are unaffected.

## Lualine Integration

AIAgent provides helpers for [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim) that surface agent state directly in your statusline.

### Section A — Agent mode

Replaces the standard mode indicator with the active agent's type and mode when the agent terminal is focused:

| State | Display | Color |
|-------|---------|-------|
| Normal editing | `NORMAL` / `INSERT` / … | theme default |
| Agent terminal (input) | `Agent: Claude` | cyan |
| Agent terminal (scroll) | `Scroll Mode: Claude` | purple |

```lua
lualine_a = {
  {
    function()
      return require('aiagent').lualine_label()
          or require('lualine.utils.mode').get_mode()
    end,
    color = function() return require('aiagent').lualine_color() end,
  },
},
```

### Section B — Branch

Shows the active agent's worktree branch when the agent terminal is focused, falling back to the normal gitsigns branch elsewhere:

```lua
lualine_b = {
  {
    function()
      return require('aiagent').lualine_branch()
          or vim.b.gitsigns_head
          or ''
    end,
    icon = '\u{E0A0}',
  },
  'diff', 'diagnostics',
},
```

### Section X — MCP server status

Displays connected MCP servers (queried via `claude mcp list`, cached for 30 seconds). Only servers reported as `✓ Connected` are shown; `claude.ai` auto-discovered servers are filtered out.

```lua
lualine_x = {
  {
    function() return require('aiagent').lualine_mcp() end,
    color = function() return require('aiagent').lualine_mcp_color() end,
  },
  'encoding', 'filetype',
},
```

To force a refresh after changing your Claude MCP configuration:

```lua
:lua require('aiagent').mcp_refresh()
```

**Configuration:**

```lua
require('aiagent').setup({
  mcp_max_width = 35,   -- columns before scrolling kicks in
  mcp_scroll    = true, -- set false to show full list without scrolling
})
```

## Health Check

Run `:checkhealth aiagent` to verify:

- Neovim version compatibility
- Which agent CLIs are available in `PATH`
- Optional dependency availability (plenary.nvim)

## License

MIT
