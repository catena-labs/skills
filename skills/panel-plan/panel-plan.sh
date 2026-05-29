#!/usr/bin/env bash
# panel-plan.sh — fan a *plan* review out to multiple local CLI agents in parallel
#                 and print their raw outputs for the coordinator to synthesize.
#
# The planning-time analog of panel-review.sh. Instead of a code diff, the
# payload is a plan markdown file: its full contents (with line numbers) are
# embedded in the prompt so panelists can cite `<plan>:LINE`. Each panelist runs
# read-only against the user's working tree, so it can check the plan's claims
# against the real codebase but cannot mutate anything.
#
# Each panelist runs in its own non-interactive subprocess with no shared state.
# Captured outputs land in a tempdir; the path is printed at the end.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_TEMPLATE="$SCRIPT_DIR/prompts/plan-review.md"

# ----- Defaults -----
PLAN_FILE=""
FOCUS=""
PANELISTS=()
OUT_DIR=""
TIMEOUT_SECS="${PANEL_PLAN_TIMEOUT:-600}"

# ----- Per-panelist model overrides (env) -----
CODEX_MODEL="${CODEX_MODEL:-}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
OPENCODE_MODEL="${OPENCODE_MODEL:-}"
# Plan review is read-only: panelists read the plan + the repo it targets, but
# never edit or exec. opencode's read-only posture is the `plan` agent.
OPENCODE_AGENT="${OPENCODE_AGENT:-plan}"

usage() {
  cat <<EOF
Usage: panel-plan.sh --plan FILE [options]

Reviews a plan markdown file with a panel of independent local CLI agents. Each
panelist reads the plan (embedded with line numbers) and may read the repo it
targets, then reports structured findings + open questions for the coordinator
to synthesize. Read-only: no diff, no git worktrees, no gh.

Required:
  --plan FILE             Path to the plan markdown file to review.

Options:
  --focus TEXT            Optional focus / context for the reviewers.
  --panelist NAME         Add panelist (repeatable). Names: codex, claude, opencode.
                          If not given, auto-detects every supported CLI on PATH.
  --out-dir DIR           Where to write captured outputs (default: mktemp).
  --timeout SECS          Per-panelist timeout (default: \$PANEL_PLAN_TIMEOUT or 600).
  -h, --help              Show this help.

Environment:
  CODEX_MODEL, CLAUDE_MODEL, OPENCODE_MODEL
                          Pass through a model name to that panelist.
  OPENCODE_AGENT          opencode agent to run (default: plan, read-only).

Exit codes:
  0  every panelist returned successfully
  1  setup error (no plan, no panelists, missing template)
  2  one or more panelists failed; raw outputs still written
EOF
}

die() { echo "panel-plan: $*" >&2; exit 1; }

# ----- Parse args -----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)        [[ $# -ge 2 ]] || die "--plan needs a file path"; PLAN_FILE="$2"; shift 2 ;;
    --focus)       [[ $# -ge 2 ]] || die "--focus needs text"; FOCUS="$2"; shift 2 ;;
    --panelist)
      [[ $# -ge 2 ]] || die "--panelist needs a name"
      # Validate against the known set up-front — the name is later interpolated
      # into filesystem paths ($p.out, $p.rc), so reject anything unexpected.
      case "$2" in
        codex|claude|opencode) PANELISTS+=("$2") ;;
        *) die "--panelist: unknown panelist '$2' (allowed: codex, claude, opencode)" ;;
      esac
      shift 2 ;;
    --out-dir)     [[ $# -ge 2 ]] || die "--out-dir needs a path"; OUT_DIR="$2"; shift 2 ;;
    --timeout)     [[ $# -ge 2 ]] || die "--timeout needs seconds"; TIMEOUT_SECS="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) die "unknown argument: $1 (use -h for help)" ;;
  esac
done

[[ -f "$PROMPT_TEMPLATE" ]] || die "missing prompt template at $PROMPT_TEMPLATE"
[[ -n "$PLAN_FILE" ]] || die "no plan file given (use --plan FILE)"
[[ -f "$PLAN_FILE" ]] || die "plan file not found: $PLAN_FILE"
[[ -s "$PLAN_FILE" ]] || die "plan file is empty: $PLAN_FILE"

# A stable, human-meaningful name panelists use when citing locations
# (e.g. `auth-design.md:42`). Use the basename so findings read cleanly
# regardless of how deep the path is.
PLAN_LABEL="$(basename "$PLAN_FILE")"

# ----- Auto-detect panelists if none specified -----
if [[ ${#PANELISTS[@]} -eq 0 ]]; then
  for tool in codex claude opencode; do
    command -v "$tool" >/dev/null 2>&1 && PANELISTS+=("$tool")
  done
fi
[[ ${#PANELISTS[@]} -gt 0 ]] || die "no panelists found on PATH (looked for codex, claude, opencode)"

# ----- Output dir -----
if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$(mktemp -d -t panel-plan-XXXXXX)"
else
  mkdir -p "$OUT_DIR"
fi

# ----- Compose the per-run prompt -----
#
# The plan is embedded with line numbers so panelists can cite `<plan>:LINE`.
# `nl -ba` numbers every line (including blanks) with a 1-based counter, matching
# how an editor reports line numbers. We keep the numbering inside a fenced block
# so the markdown structure of the plan doesn't bleed into the prompt's own
# headings.
PROMPT_FILE="$OUT_DIR/prompt.md"
{
  cat "$PROMPT_TEMPLATE"
  echo
  echo "## Plan under review"
  echo
  echo "The plan file is \`$PLAN_LABEL\`. Cite locations as \`$PLAN_LABEL:LINE\`"
  echo "(line numbers are shown in the left gutter below)."
  if [[ -n "$FOCUS" ]]; then
    echo
    echo "## Reviewer focus"
    echo
    echo "$FOCUS"
  fi
  echo
  echo "## Workspace"
  echo
  echo "You are running in the user's actual working tree with **read-only** access. You may:"
  echo
  echo "- Read any file using your built-in read tools (Read / Glob / Grep)."
  echo "- Inspect the codebase this plan targets to check the plan's assumptions"
  echo "  against reality (does the file/function/table it references actually exist?"
  echo "  is the proposed step feasible given the current code?)."
  echo
  echo "Do NOT modify files, run tests, install packages, or execute shell commands that"
  echo "change state."
  echo
  echo "## Plan contents (\`$PLAN_LABEL\`)"
  echo
  echo '```'
  nl -ba "$PLAN_FILE"
  echo '```'
} > "$PROMPT_FILE"

# Read prompt once into memory so each child reads from there.
PROMPT_CONTENT="$(cat "$PROMPT_FILE")"

# ----- Resolve a portable timeout binary (gtimeout on macOS via coreutils) -----
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"
fi

run_panelist() {
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$TIMEOUT_SECS" "$@"
  else
    "$@"
  fi
}

# ----- Build each panelist's argv -----
#
# Read-only across the board — plan review never needs to write or exec. codex
# uses --sandbox read-only, claude uses --permission-mode plan, opencode uses the
# read-only `plan` agent (OPENCODE_AGENT).
build_argv() {
  local name="$1"
  case "$name" in
    codex)
      argv=(codex exec --skip-git-repo-check --sandbox read-only --color=never)
      [[ -n "$CODEX_MODEL" ]] && argv+=(-m "$CODEX_MODEL")
      argv+=(-- "$PROMPT_CONTENT")
      ;;
    claude)
      argv=(claude -p --permission-mode plan --output-format text --no-session-persistence)
      [[ -n "$CLAUDE_MODEL" ]] && argv+=(--model "$CLAUDE_MODEL")
      argv+=(-- "$PROMPT_CONTENT")
      ;;
    opencode)
      # `opencode run` takes the message positionally; --prompt is not a flag here.
      argv=(opencode run --agent "$OPENCODE_AGENT")
      [[ -n "$OPENCODE_MODEL" ]] && argv+=(--model "$OPENCODE_MODEL")
      argv+=(-- "$PROMPT_CONTENT")
      ;;
    *)
      argv=()
      return 1
      ;;
  esac
  return 0
}

# ----- Fan out -----
echo "panel-plan: plan=$PLAN_LABEL panelists=${PANELISTS[*]} out=$OUT_DIR" >&2

declare -a PIDS=()
for p in "${PANELISTS[@]}"; do
  out="$OUT_DIR/$p.out"
  err="$OUT_DIR/$p.err"
  rc="$OUT_DIR/$p.rc"

  if ! command -v "$p" >/dev/null 2>&1; then
    echo "panel-plan: '$p' not on PATH — skipping" >&2
    : >"$out"
    echo "panelist '$p' not found on PATH" >"$err"
    echo "127" >"$rc"
    continue
  fi

  if ! build_argv "$p"; then
    echo "panel-plan: unknown panelist '$p' — skipping" >&2
    : >"$out"
    echo "unknown panelist '$p'" >"$err"
    echo "127" >"$rc"
    continue
  fi

  ( run_panelist "${argv[@]}" >"$out" 2>"$err"; echo $? >"$rc" ) &
  PIDS+=($!)
  echo "panel-plan: ${p} started (pid=$!)" >&2
done

# ----- Stream combined results as each panelist finishes -----
ANY_FAIL=0
echo "# Panel plan review"
echo
echo "- Plan: $PLAN_LABEL"
echo "- Panelists: ${PANELISTS[*]}"
echo "- Outputs: \`$OUT_DIR\`"
[[ -n "$FOCUS" ]] && echo "- Focus: $FOCUS"
echo

# Extract the model id from a panelist's stdout (the prompt instructs panelists
# to print `Model: <id>` as their very first line).
extract_model_label() {
  local p="$1"
  local fallback="$2"
  local first_line=""
  [[ -s "$OUT_DIR/$p.out" ]] && first_line="$(head -n1 "$OUT_DIR/$p.out" 2>/dev/null || true)"
  case "$first_line" in
    Model:*)
      local label="${first_line#Model:}"
      label="${label# }"
      label="${label#"${label%%[![:space:]]*}"}"
      [[ -n "$label" ]] && { echo "$label"; return; }
      ;;
  esac
  if [[ -n "$fallback" ]]; then
    echo "$fallback"
  else
    echo "?"
  fi
}

print_section() {
  local p="$1"
  local rc_val
  rc_val="$(cat "$OUT_DIR/$p.rc" 2>/dev/null || echo "?")"
  local fallback_model=""
  case "$p" in
    codex)    fallback_model="$CODEX_MODEL" ;;
    claude)   fallback_model="$CLAUDE_MODEL" ;;
    opencode) fallback_model="$OPENCODE_MODEL" ;;
  esac
  local model_label
  model_label="$(extract_model_label "$p" "$fallback_model")"
  echo "## ${p} / ${model_label} (exit ${rc_val})"
  echo
  if [[ -s "$OUT_DIR/$p.out" ]]; then
    cat "$OUT_DIR/$p.out"
  else
    echo "_(no stdout)_"
  fi
  if [[ "$rc_val" != "0" ]]; then
    ANY_FAIL=1
    if [[ -s "$OUT_DIR/$p.err" ]]; then
      echo
      echo "<details><summary>stderr</summary>"
      echo
      echo '```'
      cat "$OUT_DIR/$p.err"
      echo '```'
      echo
      echo "</details>"
    fi
  fi
  echo
  echo "panel-plan: ${p} (${model_label}) done (exit ${rc_val})" >&2
}

# Track which panelists have already been printed (bash 3.2 has no assoc arrays).
PRINTED=()
TOTAL=${#PANELISTS[@]}
DONE_COUNT=0
while (( DONE_COUNT < TOTAL )); do
  for p in "${PANELISTS[@]}"; do
    is_printed=0
    if [[ ${#PRINTED[@]} -gt 0 ]]; then
      for x in "${PRINTED[@]}"; do
        if [[ "$x" == "$p" ]]; then is_printed=1; break; fi
      done
    fi
    (( is_printed )) && continue
    [[ -s "$OUT_DIR/$p.rc" ]] || continue
    print_section "$p"
    PRINTED+=("$p")
    DONE_COUNT=$((DONE_COUNT + 1))
  done
  (( DONE_COUNT < TOTAL )) && sleep 1
done

[[ ${#PIDS[@]} -gt 0 ]] && wait "${PIDS[@]}" 2>/dev/null || true

exit $(( ANY_FAIL ? 2 : 0 ))
