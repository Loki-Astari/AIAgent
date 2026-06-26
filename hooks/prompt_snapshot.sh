#!/bin/sh
# prompt_snapshot.sh — capture prompt -> code-change history for Claude Code.
#
# Wired into Claude Code as two hooks (see the prompt-history skill / README):
#   UserPromptSubmit -> prompt_snapshot.sh pre
#   Stop             -> prompt_snapshot.sh post
#
# It reads the hook JSON payload on stdin and records, per prompt, a pair of
# git tree SHAs bracketing the turn. The diff between them is exactly what
# changed because of that prompt -- including Bash/codegen edits, and whether
# or not the changes were committed (a tree captures committed + uncommitted +
# untracked state uniformly).
#
# Design notes:
#   * Never writes to stdout. UserPromptSubmit stdout is injected into the
#     model's context, so any stray output would pollute the prompt.
#   * Always exits 0. A capture failure must never block the user's turn.
#   * One log file per session under <repo>/.prompt-history/sessions/<id>.jsonl
#     so concurrent agents never interleave writes into a shared file.
#   * The log dir is anchored on the shared git dir, so every worktree of a
#     repo writes into the same place.

set -u
MODE="${1:-}"

# Prompts the plugin builds from the capture log (AgentSessions!) carry this
# token on their first line. Submitting such a prompt is replaying history, so
# we must NOT record it again. KEEP IN SYNC with M.PRIMER_MARKER in
# lua/aiagent/prompthistory.lua.
PRIMER_MARKER='AIAGENT_PROMPT_HISTORY_PRIMER'

# --- read the hook payload once -------------------------------------------
PAYLOAD="$(cat)"

field() { printf '%s' "$PAYLOAD" | jq -r "$1 // empty" 2>/dev/null; }

# jq is required to parse the payload; bail quietly if it's missing.
command -v jq >/dev/null 2>&1 || exit 0

CWD="$(field '.cwd')"
[ -n "$CWD" ] || CWD="$PWD"
cd "$CWD" 2>/dev/null || exit 0

# Must be inside a git work tree.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Shared history dir: anchor on the common git dir so all worktrees of this
# repo write to one location. The common dir is normally <main-root>/.git.
COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
[ -n "$COMMON" ] || exit 0
MAIN_ROOT="$(dirname "$COMMON")"
HIST_DIR="$MAIN_ROOT/.prompt-history"
SESS_DIR="$HIST_DIR/sessions"
mkdir -p "$SESS_DIR" 2>/dev/null || exit 0
DIAG="$HIST_DIR/diagnostics.log"

SESSION="$(field '.session_id')"
[ -n "$SESSION" ] || { printf '%s no session_id (%s)\n' "$(date -u +%FT%TZ)" "$MODE" >>"$DIAG" 2>/dev/null; exit 0; }
# Allow the user to override the session via a picker (AgentSessions).
ACTIVE_FILE="$HIST_DIR/active-session"
if [ -f "$ACTIVE_FILE" ]; then
  OVERRIDE="$(cat "$ACTIVE_FILE" 2>/dev/null)"
  [ -n "$OVERRIDE" ] && SESSION="$OVERRIDE"
fi

LOG="$SESS_DIR/$SESSION.jsonl"
PENDING="$HIST_DIR/pending-$SESSION.json"

# --- snapshot: print a tree SHA for the entire current working tree --------
# Seeds the temp index from HEAD (fast: only changed files are re-hashed),
# then stages all working changes. Honors .gitignore. Handles an unborn HEAD
# (fresh repo with no commits) by starting from an empty index.
snapshot() {
  idx="$(mktemp)" || return 1
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    GIT_INDEX_FILE="$idx" git read-tree HEAD 2>/dev/null
  fi
  # Exclude our own state dir so the capture never records itself. Two steps,
  # because .prompt-history can reach the tree two ways: as a new working-tree
  # file (skipped by the exclude pathspec on add) or already committed into
  # HEAD and seeded by read-tree (removed from the index below). This keeps
  # capture correct even if .gitignore lacks the entry or the dir was once
  # committed by accident.
  GIT_INDEX_FILE="$idx" git add -A -- ':(exclude,top).prompt-history' 2>/dev/null
  GIT_INDEX_FILE="$idx" git rm -r --cached --ignore-unmatch -q -- ':(top).prompt-history' 2>/dev/null
  tree="$(GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null)"
  rm -f "$idx"
  printf '%s' "$tree"
}

# --- close out a pending turn by appending a full record -------------------
# $1 = after_tree SHA. No-op if there is no pending record for this session.
write_record() {
  [ -f "$PENDING" ] || return 0
  after="$1"
  [ -n "$after" ] || { rm -f "$PENDING"; return 0; }

  prompt="$(jq -r '.prompt'      "$PENDING" 2>/dev/null)"
  before="$(jq -r '.before_tree' "$PENDING" 2>/dev/null)"
  started="$(jq -r '.started'    "$PENDING" 2>/dev/null)"
  head_sha="$(git rev-parse HEAD 2>/dev/null)"
  branch="$(git branch --show-current 2>/dev/null)"
  changed="$(git diff --no-ext-diff --name-only "$before" "$after" 2>/dev/null | wc -l | tr -d ' ')"
  [ -n "$changed" ] || changed=0

  jq -n -c \
    --arg session "$SESSION" \
    --arg started "$started" \
    --arg ended   "$(date -u +%FT%TZ)" \
    --arg prompt  "$prompt" \
    --arg before  "$before" \
    --arg after   "$after" \
    --arg cwd     "$CWD" \
    --arg head    "$head_sha" \
    --arg branch  "$branch" \
    --argjson changed "${changed:-0}" \
    '{session:$session, started:$started, ended:$ended, prompt:$prompt,
      before_tree:$before, after_tree:$after, changed_files:$changed,
      cwd:$cwd, head:$head, branch:$branch}' \
    >>"$LOG" 2>/dev/null

  rm -f "$PENDING"
}

case "$MODE" in
  pre)
    NOW="$(snapshot)"
    [ -n "$NOW" ] || exit 0
    # If a previous turn never closed (e.g. interrupted before Stop), close it
    # out now using the current state as its after-tree, then start fresh.
    write_record "$NOW"
    # A primer rebuilt from this log (AgentSessions!) re-records history we
    # already have. Close the prior turn above, but open no turn for the primer.
    case "$(field '.prompt')" in
      *"$PRIMER_MARKER"*) exit 0 ;;
    esac
    jq -n -c \
      --arg prompt  "$(field '.prompt')" \
      --arg before  "$NOW" \
      --arg started "$(date -u +%FT%TZ)" \
      '{prompt:$prompt, before_tree:$before, started:$started}' \
      >"$PENDING" 2>/dev/null
    ;;
  post)
    write_record "$(snapshot)"
    ;;
  *)
    printf '%s unknown mode %s\n' "$(date -u +%FT%TZ)" "$MODE" >>"$DIAG" 2>/dev/null
    ;;
esac

exit 0
