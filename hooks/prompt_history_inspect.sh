#!/bin/sh
# prompt_history_inspect.sh — inspect the prompt->change history captured by
# prompt_snapshot.sh. A dev/verification tool (the neovim viewer is the real
# UI); also handy for the skill's "list sessions" step.
#
# Usage:
#   prompt_history_inspect.sh                 # list sessions for this repo
#   prompt_history_inspect.sh <session-id>    # dump one session's prompts
#   prompt_history_inspect.sh <session-id> <n>  # show changed files for prompt n
#
# Run from anywhere inside the repo (or a worktree of it).

set -u

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not in a git work tree" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
HIST_DIR="$(dirname "$COMMON")/.prompt-history"
SESS_DIR="$HIST_DIR/sessions"

[ -d "$SESS_DIR" ] || { echo "no history yet ($SESS_DIR)"; exit 0; }

short() { printf '%.8s' "$1"; }
truncate_prompt() { tr '\n' ' ' | cut -c1-70; }

SESSION="${1:-}"

# ---- list mode -----------------------------------------------------------
if [ -z "$SESSION" ]; then
  printf '%-10s  %-20s  %5s  %s\n' "SESSION" "STARTED" "TURNS" "FIRST PROMPT"
  printf '%-10s  %-20s  %5s  %s\n' "----------" "--------------------" "-----" "------------"
  # newest first by file mtime
  ls -t "$SESS_DIR"/*.jsonl 2>/dev/null | while IFS= read -r f; do
    id="$(basename "$f" .jsonl)"
    turns="$(grep -c '^' "$f" 2>/dev/null || echo 0)"
    started="$(head -n1 "$f" 2>/dev/null | jq -r '.started // "?"' 2>/dev/null)"
    first="$(head -n1 "$f" 2>/dev/null | jq -r '.prompt // ""' 2>/dev/null | truncate_prompt)"
    printf '%-10s  %-20s  %5s  %s\n' "$(short "$id")" "$started" "$turns" "$first"
  done
  echo
  echo "Dump a session:  $(basename "$0") <session-id>"
  exit 0
fi

# Resolve a (possibly shortened) session id to its log file.
LOG=""
for f in "$SESS_DIR"/*.jsonl; do
  [ -e "$f" ] || continue
  base="$(basename "$f" .jsonl)"
  case "$base" in "$SESSION"*) LOG="$f"; SESSION="$base"; break ;; esac
done
[ -n "$LOG" ] || { echo "no session matching '$SESSION'"; exit 1; }

PROMPT_N="${2:-}"

# ---- show changed files for one prompt -----------------------------------
if [ -n "$PROMPT_N" ]; then
  rec="$(sed -n "${PROMPT_N}p" "$LOG")"
  [ -n "$rec" ] || { echo "no prompt #$PROMPT_N in session"; exit 1; }
  before="$(printf '%s' "$rec" | jq -r '.before_tree')"
  after="$(printf '%s' "$rec" | jq -r '.after_tree')"
  printf '%s' "$rec" | jq -r '"prompt #'"$PROMPT_N"': " + .prompt'
  echo "--- changed files (before $before .. after $after) ---"
  git diff --name-status "$before" "$after"
  exit 0
fi

# ---- dump a session ------------------------------------------------------
echo "session $SESSION  ($LOG)"
echo
n=0
while IFS= read -r rec; do
  n=$((n + 1))
  prompt="$(printf '%s' "$rec" | jq -r '.prompt' | truncate_prompt)"
  changed="$(printf '%s' "$rec" | jq -r '.changed_files')"
  branch="$(printf '%s' "$rec" | jq -r '.branch')"
  printf '%3d. [%2s files] (%s) %s\n' "$n" "$changed" "$branch" "$prompt"
done <"$LOG"
echo
echo "Changed files for a prompt:  $(basename "$0") $(short "$SESSION") <n>"
