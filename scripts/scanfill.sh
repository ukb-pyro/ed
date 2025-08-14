#!/usr/bin/env bash
set -euo pipefail

# scanfill.sh — scan a directory with optional maxdepth/exclusions,
# and (by default) fill truly empty text files with a placeholder for Git pushes.

show_help() {
  cat <<'EOF'
Usage:
  ./scanfill.sh [-d DIR] [-m MAXDEPTH] [--blank] [--dry-run]
                [--exec "CMD {}"] [--text-ext "ext1,ext2,..."]
                [--exclude-name "pattern"]... [--prune "pathpattern"]...

Options:
  -d DIR               Root directory to scan (default: .)
  -m MAXDEPTH          find -maxdepth value (omit to search all subdirs)
  --blank              Treat whitespace-only files as empty too
  --dry-run            Show what would happen without changing files
  --exec "CMD {}"      Run a command per matched file (use {} for the filepath)
  --text-ext "CSV"     Comma list of extensions to include (no dots).
                       Default: md,txt,py,sh,html,css,js,json,yml,yaml,csv,ts,ipynb
  --exclude-name P     Exclude files by -name pattern (repeatable)
  --prune P            Prune paths by -path pattern (repeatable), e.g. "*/node_modules/*"
  -h, --help           Show this help

Default behavior (no --exec given):
  - Finds empty text files and writes a placeholder header with path + timestamp.
  - Skips non-text files unless you extend --text-ext accordingly.

Examples:
  # Fill 0-byte text files anywhere under the repo
  ./scanfill.sh

  # Limit depth to current dir + one level, and prune node_modules
  ./scanfill.sh -m 2 --prune "*/node_modules/*"

  # Exclude README.md and any file named .DS_Store
  ./scanfill.sh --exclude-name "README.md" --exclude-name ".DS_Store"

  # Also treat whitespace-only files as empty
  ./scanfill.sh --blank

  # Just print what would happen
  ./scanfill.sh --dry-run

  # Run a custom command on each matched file (e.g., stage them)
  ./scanfill.sh --exec "git add {}"

  # Custom extension set
  ./scanfill.sh --text-ext "md,txt,py,sh,html"
EOF
}

DIR="."
MAXDEPTH=""
BLANK=false
DRY_RUN=false
EXEC_CMD=""
TEXT_EXT="md,txt,py,sh,html,css,js,json,yml,yaml,csv,ts,ipynb"
EXCLUDE_NAMES=()
PRUNE_PATHS=()

# Simple arg parser (POSIX-ish)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DIR="${2:-}"; shift 2 ;;
    -m) MAXDEPTH="${2:-}"; shift 2 ;;
    --blank) BLANK=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --exec) EXEC_CMD="${2:-}"; shift 2 ;;
    --text-ext) TEXT_EXT="${2:-}"; shift 2 ;;
    --exclude-name) EXCLUDE_NAMES+=("${2:-}"); shift 2 ;;
    --prune) PRUNE_PATHS+=("${2:-}"); shift 2 ;;
    -h|--help) show_help; exit 0 ;;
    *) echo "Unknown option: $1"; echo; show_help; exit 1 ;;
  esac
done

# Build extension regex for find -regex (POSIX ERE)
# From "md,txt,py" -> '\.(md|txt|py)$'
IFS=',' read -r -a EXT_ARR <<< "$TEXT_EXT"
EXT_RE='\.('"${EXT_ARR[0]}"
for ((i=1; i<${#EXT_ARR[@]}; i++)); do
  EXT_RE+="|${EXT_ARR[i]}"
done
EXT_RE+=")$"

# Build find command pieces
FIND_ARGS=()
FIND_ARGS+=("$DIR" -type f)

# Prunes: (-path P -prune -o ...)
for P in "${PRUNE_PATHS[@]}"; do
  FIND_ARGS+=(-path "$P" -prune -o)
done

# If maxdepth provided apply it *after* DIR and before tests
if [[ -n "$MAXDEPTH" ]]; then
  # Insert -maxdepth right after DIR
  # We'll rebuild to ensure correct ordering with prunes already added.
  # Simpler approach: evaluate via an array rebuild
  NEW_ARGS=()
  NEW_ARGS+=("$DIR")
  NEW_ARGS+=(-maxdepth "$MAXDEPTH")
  NEW_ARGS+=(-type f)
  # re-append prunes
  if [[ ${#PRUNE_PATHS[@]} -gt 0 ]]; then
    NEW_ARGS=("$DIR" -maxdepth "$MAXDEPTH")
    for P in "${PRUNE_PATHS[@]}"; do
      NEW_ARGS+=(-path "$P" -prune -o)
    done
    NEW_ARGS+=(-type f)
  fi
  FIND_ARGS=("${NEW_ARGS[@]}")
fi

# Name excludes
for N in "${EXCLUDE_NAMES[@]}"; do
  FIND_ARGS+=(! -name "$N")
done

# Only texty extensions (by regex)
FIND_ARGS+=(-regex ".*${EXT_RE}")

# Empty criteria
if $BLANK; then
  # blank = 0-byte OR only whitespace
  # We can't express "only whitespace" in pure find portably, so do a small bash check in -exec
  FIND_ARGS+=(
    \( -size 0c -o -exec bash -c '
      f="$1"
      # Return true (exit 0) if file has no non-whitespace characters
      # shellcheck disable=SC2013
      if [[ -s "$f" ]]; then
        if LC_ALL=C grep -q '[^[:space:]]' "$f"; then
          exit 1
        else
          exit 0
        fi
      else
        # zero-byte already covered; treat as blank too
        exit 0
      fi
    ' _ {} \; \)
  )
else
  FIND_ARGS+=(-size 0c)
fi

# If exec is provided, run it; otherwise fill placeholder
PLACEHOLDER() {
  local file="$1"
  local ts path rel
  ts="$(date -Is)"
  # Make path relative to DIR for readability
  rel="$(python3 - <<PY
import os, sys
d = os.path.abspath("${DIR}")
f = os.path.abspath("$file")
try:
    print(os.path.relpath(f, d))
except ValueError:
    print(f)
PY
)"
  # Choose a comment prefix by extension
  case "$file" in
    *.py|*.sh|*.js|*.ts) c="#" ;;
    *.css) c="/*" ;;
    *.html) c="<!--" ;;
    *.md|*.txt|*.json|*.yml|*.yaml|*.csv|*.ipynb) c="##" ;;
    *) c="##" ;;
  esac

  if [[ "$c" == "/*" ]]; then
    header="/* TODO: replace with real content
   Path: ${rel}
   Created: ${ts}
*/"
  elif [[ "$c" == "<!--" ]]; then
    header="<!-- TODO: replace with real content
Path: ${rel}
Created: ${ts}
-->"
  else
    header="${c} TODO: replace with real content
${c} Path: ${rel}
${c} Created: ${ts}"
  fi

  if $DRY_RUN; then
    echo "[dry-run] would write placeholder to: $file"
  else
    printf '%s\n\n' "$header" > "$file"
    echo "wrote placeholder -> $file"
  fi
}

run_exec() {
  local file="$1"
  if $DRY_RUN; then
    echo "[dry-run] would run: ${EXEC_CMD//\{\}/$file}"
  else
    # replace {} with the file path safely
    local cmd="${EXEC_CMD//\{\}/"$file"}"
    bash -lc "$cmd"
  fi
}

# Execute the find
export -f PLACEHOLDER run_exec
# Export variables for subshells (macOS/BSD find uses sh for -exec bash -c)
export DIR DRY_RUN EXEC_CMD

# Collect results into a null-delimited stream to handle weird filenames
if [[ -n "$EXEC_CMD" ]]; then
  # Use while-read loop to avoid too many processes
  while IFS= read -r -d '' f; do
    run_exec "$f"
  done < <(find "${FIND_ARGS[@]}" -print0)
else
  while IFS= read -r -d '' f; do
    PLACEHOLDER "$f"
  done < <(find "${FIND_ARGS[@]}" -print0)
fi

