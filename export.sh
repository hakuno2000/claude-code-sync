#!/usr/bin/env bash
# claude-push.sh — find Claude Code .jsonl conversation logs and commit
# a selected one to a Git repo (optionally push).
#
# Claude Code stores conversation logs as JSONL files under
#   ~/.claude/projects/<encoded-project-path>/<session-id>.jsonl

set -euo pipefail

# ---------- defaults ----------
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude/projects}"
TARGET_DIR="$(pwd)"
SUBDIR="claude-logs"
COMMIT_MSG=""
DO_PUSH=0

# ---------- colors ----------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'
  BLU=$'\033[0;34m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; BLU=""; DIM=""; NC=""
fi
err()  { printf '%s[err]%s  %s\n' "$RED" "$NC" "$*" >&2; }
info() { printf '%s[..]%s   %s\n'  "$BLU" "$NC" "$*"; }
ok()   { printf '%s[ok]%s   %s\n'  "$GRN" "$NC" "$*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Pick a Claude Code conversation (.jsonl) and commit it to a git repo.

Options:
  -d, --dir DIR       Claude projects directory  (default: \$HOME/.claude/projects)
  -t, --target DIR    Target git repo or subdir  (default: current directory)
  -s, --subdir NAME   Folder inside repo for log (default: claude-logs)
  -m, --message MSG   Commit message             (default: auto-generated)
  -p, --push          git push after commit
  -h, --help          Show this help

Examples:
  $(basename "$0")                       # pick & commit in current repo
  $(basename "$0") -p                    # pick, commit, push
  $(basename "$0") -t ~/notes -s logs -p
EOF
}

# ---------- arg parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)     CLAUDE_DIR="$2"; shift 2 ;;
    -t|--target)  TARGET_DIR="$2"; shift 2 ;;
    -s|--subdir)  SUBDIR="$2";     shift 2 ;;
    -m|--message) COMMIT_MSG="$2"; shift 2 ;;
    -p|--push)    DO_PUSH=1;       shift   ;;
    -h|--help)    usage; exit 0 ;;
    *) err "unknown option: $1"; usage; exit 1 ;;
  esac
done

# ---------- find .jsonl files ----------
[[ -d "$CLAUDE_DIR" ]] || { err "no such directory: $CLAUDE_DIR"; exit 1; }

mapfile -t FILES < <(
  find "$CLAUDE_DIR" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | cut -d' ' -f2-
)
(( ${#FILES[@]} )) || { err "no .jsonl files under $CLAUDE_DIR"; exit 1; }

# ---------- helper: extract first user-typed message (pure shell) ----------
# Walks the JSONL line-by-line, skips assistant lines and any user line that
# is a tool_result / tool_use frame, and pulls the first textual user message.
# Handles both Claude Code shapes:
#   "message":{"role":"user","content":"..."}
#   "message":{"role":"user","content":[{"type":"text","text":"..."}, ...]}
# This is best-effort regex parsing — it's only used for a preview line.
extract_first_user() {
  local file="$1" line txt
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      *'"type":"user"'*) ;;
      *) continue ;;
    esac
    case "$line" in
      *'"tool_result"'*|*'"tool_use"'*) continue ;;
    esac
    # form A: string content
    txt=$(printf '%s' "$line" \
          | sed -nE 's/.*"role":"user","content":"([^"\\]*(\\.[^"\\]*)*)".*/\1/p')
    # form B: content array with a {"type":"text","text":"..."} entry
    if [[ -z "$txt" ]]; then
      txt=$(printf '%s' "$line" \
            | sed -nE 's/.*\{"type":"text","text":"([^"\\]*(\\.[^"\\]*)*)".*/\1/p')
    fi
    if [[ -n "$txt" ]]; then
      # unescape common JSON escapes, collapse whitespace, truncate
      printf '%s' "$txt" \
        | sed 's/\\n/ /g; s/\\r/ /g; s/\\t/ /g; s/\\"/"/g; s|\\/|/|g; s/\\\\/\\/g' \
        | tr -s ' ' | cut -c1-80
      return 0
    fi
  done < "$file"
  return 0
}

# ---------- helper: pretty row for a file ----------
# columns: index | date | size | project | first user message
preview_row() {
  local idx="$1" file="$2"
  local size mtime project first
  size=$(du -h "$file" 2>/dev/null | cut -f1)
  mtime=$(date -r "$file" '+%Y-%m-%d %H:%M' 2>/dev/null \
        || stat -c '%y' "$file" 2>/dev/null | cut -d. -f1)
  # decode the project dir name (Claude encodes / as -)
  project=$(basename "$(dirname "$file")" | sed 's|^-||; s|-|/|g')
  # first user-typed message (pure shell — no python/jq required)
  first=$(extract_first_user "$file" 2>/dev/null || true)
  printf '%s%3d)%s  %s  %6s  %s[%s]%s  %s%s%s\n' \
    "$YLW" "$idx" "$NC" "$mtime" "$size" \
    "$DIM" "$project" "$NC" "$DIM" "$first" "$NC"
}

# ---------- selection ----------
echo
info "found ${#FILES[@]} conversation file(s) under $CLAUDE_DIR"
echo

for i in "${!FILES[@]}"; do
  preview_row "$((i+1))" "${FILES[$i]}"
done

echo
read -rp "Select a conversation (1-${#FILES[@]}, q to quit): " choice
[[ "$choice" == "q" || "$choice" == "Q" ]] && { info "cancelled"; exit 0; }
[[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#FILES[@]} )) \
  || { err "invalid selection"; exit 1; }

SELECTED="${FILES[$((choice-1))]}"
ok "selected: $SELECTED"

# ---------- verify git repo ----------
cd "$TARGET_DIR"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { err "$TARGET_DIR is not inside a git repository"; exit 1; }
REPO_ROOT=$(git rev-parse --show-toplevel)

DEST_DIR="$REPO_ROOT/$SUBDIR"
mkdir -p "$DEST_DIR"

# include project tag so files from different projects don't collide
PROJECT_TAG=$(basename "$(dirname "$SELECTED")")
DEST="$DEST_DIR/${PROJECT_TAG}__$(basename "$SELECTED")"

cp "$SELECTED" "$DEST"
ok "copied to $DEST"

# ---------- commit ----------
if [[ -z "$COMMIT_MSG" ]]; then
  short_proj=$(echo "$PROJECT_TAG" | sed 's|^-||; s|-|/|g' | awk -F/ '{print $NF}')
  COMMIT_MSG="add Claude conversation log from ${short_proj:-claude}"
fi

cd "$REPO_ROOT"
git add -- "$DEST"
if git diff --cached --quiet; then
  info "nothing to commit (file already in repo and unchanged)"
  exit 0
fi
git commit -m "$COMMIT_MSG"
ok "committed: $COMMIT_MSG"

# ---------- push ----------
if (( DO_PUSH )); then
  branch=$(git rev-parse --abbrev-ref HEAD)
  info "pushing $branch ..."
  git push origin "$branch"
  ok "pushed"
else
  info "skipped push (run with -p, or: git push)"
fi
