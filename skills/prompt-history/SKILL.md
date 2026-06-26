---
name: prompt-history
description: Browse the prompt-history diff viewer in neovim — show what code changed for each prompt of a Claude Code session. Use when the user wants to look back at prompt history, see the diff a prompt produced, open/close the history viewer, switch to another session, or list captured sessions. Requires the AIAgent neovim plugin and the prompt_snapshot.sh hooks (see reference/install.md).
---

# Prompt History

Each prompt in a Claude Code session is captured as a pair of git tree SHAs
(before/after the turn) by the `prompt_snapshot.sh` hooks. This skill drives the
**neovim viewer** in the AIAgent plugin so the user can scroll prompts and see a
native before|after diff of the files each prompt changed.

You operate it two ways: a **shell tool** (`prompt_history_inspect.sh`) to
list/inspect sessions from the terminal, and **remote calls into the live
neovim** to open/close/switch the visual viewer. The viewer opens in its own
tabpage and leaves the chat terminal untouched; closing returns to chat.

## Prerequisites (check first, once)

- `$NVIM` must be set — confirms you are running inside the AIAgent neovim
  terminal. If it is empty, the visual viewer is unavailable; you can still use
  the inspect script to read history, but tell the user the viewer needs the
  AIAgent terminal. If the plugin/hooks aren't installed at all, point them at
  `reference/install.md`.
- Resolve the inspect script path once:
  `INSPECT=__AIAGENT_HOOKS_DIR__/prompt_history_inspect.sh`

## Routing on the user's request

**Open the current session's viewer** (default — "show prompt history", "open
the diff viewer", no specific session):

```sh
nvim --server "$NVIM" --remote-expr "luaeval(\"require('aiagent').prompt_history_open()\")"
```

This defaults to the running agent's own session. Note: the *current* turn is
only captured once it finishes (the `Stop` hook writes it), so a brand-new
session with no completed turns yet opens empty — say so rather than reporting a
failure.

**Close the viewer / back to chat** ("close", "go back to chat"):

```sh
nvim --server "$NVIM" --remote-expr "luaeval(\"require('aiagent').prompt_history_close()\")"
```

**List captured sessions** ("what sessions are there", "list history"):

```sh
"$INSPECT"                       # newest-first table: short id, started, turns, first prompt
```

**Open a specific / older session** (user names a session or picks from the
list): the viewer needs the *full* session id. Resolve a partial id from the
list first, then pass the full id via luaeval's `_A` argument (avoids nested
quoting):

```sh
nvim --server "$NVIM" --remote-expr "luaeval(\"require('aiagent').prompt_history_open(_A)\", 'FULL_SESSION_ID')"
```

**Inspect history without the viewer** (when `$NVIM` is unset, or the user just
wants the facts in chat):

```sh
"$INSPECT" <session-id>          # dump a session: each prompt, #files changed, branch
"$INSPECT" <session-id> <n>      # changed files (name-status) for prompt #n
```

## Notes

- A successful remote call prints `vim.NIL` and exits 0 — that's normal, not an
  error.
- Opening when a viewer is already open refreshes it (picks up newly captured
  prompts) — safe to call repeatedly.
- Keys inside the viewer (the user drives these, not you): `q` close → chat,
  `]f`/`[f` cycle changed files, `j`/`k` move through the prompt list.
- The git object store is shared across worktrees, so a session opens correctly
  from any worktree of the same repo.
- Equivalent neovim commands exist if the user prefers typing them in nvim:
  `:AgentDiff [session]` (open) and `:AgentChat` (close).
