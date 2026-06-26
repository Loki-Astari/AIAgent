# Installing prompt-history

The system has three pieces: **capture** (Claude Code hooks), **viewer**
(AIAgent neovim plugin), and **this skill** (driving the viewer). The skill and
viewer are useless without capture, so set up capture first.

## 1. The AIAgent plugin (viewer)

The viewer lives in the AIAgent neovim plugin (`Loki-Astari/AIAgent`), branch
`prompt-history`. Install with your plugin manager. lazy.nvim spec:

```lua
{ "Loki-Astari/AIAgent", branch = "prompt-history" }
```

It provides `lua/aiagent/prompthistory.lua` plus these entry points on the
`aiagent` module: `prompt_history_open(session?)`, `prompt_history_close()`,
`current_session()`, and the `:AgentDiff [session]` / `:AgentChat` commands.
Claude Code must be run from inside the plugin's agent terminal so `$NVIM` is
set and the running session resolves.

You install *this skill* with `:AgentInstallSkill`, which copies it into
`~/.claude/skills/prompt-history/` with the hook paths below already filled in.

## 2. Capture hooks (Claude Code settings)

Wire `prompt_snapshot.sh` into **user** `~/.claude/settings.json` so it captures
across every repo:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command",
        "command": "__AIAGENT_HOOKS_DIR__/prompt_snapshot.sh pre" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command",
        "command": "__AIAGENT_HOOKS_DIR__/prompt_snapshot.sh post" } ] }
    ]
  }
}
```

`pre` records the tree at prompt submit; `post` records the tree after the turn
and appends the record. The hook writes no stdout (it would pollute prompt
context) and always exits 0, so a capture failure never blocks a turn.

## 3. What gets stored

One JSONL file per session at `<repo>/.prompt-history/sessions/<session_id>.jsonl`,
anchored on the git **common** dir so all worktrees of a repo share one
location. Each line: `session, started, ended, prompt, before_tree, after_tree,
changed_files, cwd, head, branch`. Trees are built in a temp index
(`read-tree HEAD` + `add -A` excluding `.prompt-history` + `write-tree`) so they
capture committed + uncommitted + untracked files uniformly, survive commits,
and never record the history dir itself — works with or without gitignoring it.

Add `.prompt-history/` to the repo's `.gitignore` (or global gitignore) to keep
it out of commits.

## Requirements

- `git`, `jq`, and a POSIX `sh` on PATH (the hooks and inspect script use them).
- neovim with the AIAgent plugin for the visual viewer; the inspect script
  (`__AIAGENT_HOOKS_DIR__/prompt_history_inspect.sh`) works standalone from any
  terminal.
