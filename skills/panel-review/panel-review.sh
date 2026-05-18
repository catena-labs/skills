#!/usr/bin/env bash
# panel-review.sh — fan a code review out to multiple local CLI agents in parallel
#                   and print their raw outputs for the coordinator to synthesize.
#
# Each panelist runs in its own non-interactive subprocess with no shared state.
# Captured outputs land in a tempdir; the path is printed at the end.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Two prompt templates:
#   review.md     - mode-agnostic base prompt for diff-embedded targets
#                   (uncommitted/staged/base/commit). The script appends a
#                   `## Workspace` section that tells the panelist what
#                   tool capabilities they actually have in this run.
#   review-pr.md  - PR-specific instruction prompt; panelists run gh pr view
#                   / gh pr diff / gh api comments themselves rather than
#                   getting an embedded diff. Worktree section is also
#                   appended by the script.
PROMPT_TEMPLATE="$SCRIPT_DIR/prompts/review.md"
PROMPT_TEMPLATE_PR="$SCRIPT_DIR/prompts/review-pr.md"

# ----- Defaults -----
TARGET="uncommitted"           # uncommitted | staged | base:<ref> | commit:<sha> | pr:<ref>
TARGET_EXPLICIT=0              # set to 1 by any --uncommitted/--staged/--base/--commit/--pr flag
FOCUS=""
PANELISTS=()
OUT_DIR=""
TIMEOUT_SECS="${PANEL_REVIEW_TIMEOUT:-600}"
MAX_DIFF_BYTES="${PANEL_REVIEW_MAX_DIFF_BYTES:-200000}"
CHECKOUT_MODE=0
CHECKOUT_REQUESTED=0            # set to 1 by the deprecated --checkout flag, used to
                                # detect --checkout combined with a target that no
                                # longer supports a worktree (uncommitted/staged)
INSTRUCTION_MODE=0             # 1 when target is a PR; panelists fetch via gh themselves

# ----- Per-panelist model overrides (env) -----
CODEX_MODEL="${CODEX_MODEL:-}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
OPENCODE_MODEL="${OPENCODE_MODEL:-}"
OPENCODE_AGENT="${OPENCODE_AGENT:-plan}"
# Opencode has no read-only/write toggle equivalent to codex's --sandbox; the choice
# of agent decides what tools are available. pr/base/commit reviews run worktree-
# isolated with shell access (to run `gh`, tests, grep), so they swap to a writable
# agent. Override OPENCODE_AGENT_DEEP if you have a custom agent for that purpose.
OPENCODE_AGENT_DEEP="${OPENCODE_AGENT_DEEP:-build}"

usage() {
  cat <<EOF
Usage: panel-review.sh [target] [options]

Targets (pick one; default tries to auto-detect a PR for the current branch via
'gh pr view', falling back to --uncommitted):
  --uncommitted           Review staged + unstaged changes
  --staged                Review only staged changes
  --base BRANCH           Review BRANCH...HEAD
  --commit SHA            Review a single commit
  --pr NUMBER             Review a GitHub PR. Panelists fetch the diff and
                          existing review comments themselves via the 'gh' CLI
                          (no embedded diff in the prompt — eliminates stale-base
                          bugs and the MAX_DIFF_BYTES cap).

Options:
  --focus TEXT            Optional focus / context for the reviewers
  --panelist NAME         Add panelist (repeatable). Names: codex, claude, opencode.
                          If not given, auto-detects every supported CLI on PATH.
  --out-dir DIR           Where to write captured outputs (default: mktemp).
  --timeout SECS          Per-panelist timeout (default: \$PANEL_REVIEW_TIMEOUT or 600).
  -h, --help              Show this help.

Behavior by target:
  --uncommitted/--staged  Local diff embedded in prompt; panelists run from your
                          working tree with read-only / plan permissions.
  --pr/--base/--commit    Panelists run worktree-isolated with write/exec perms
                          (one throwaway git-worktree per panelist, pinned to the
                          target ref). They can grep callers, run tests, and
                          investigate downstream effects. The prompt forbids
                          state-changing network actions (push, gh writes,
                          installer side effects); the worktree is the only
                          enforcement layer.

  The legacy --checkout flag is now the default for committed targets and is
  accepted as a deprecated no-op.

Environment:
  CODEX_MODEL, CLAUDE_MODEL, OPENCODE_MODEL
                          Pass through a model name to that panelist.
  OPENCODE_AGENT          opencode agent for --uncommitted/--staged (default: plan,
                          read-only).
  OPENCODE_AGENT_DEEP     opencode agent for --pr/--base/--commit (default: build,
                          full shell access in the per-panelist worktree).
  PANEL_REVIEW_MAX_DIFF_BYTES
                          Cap inline diff size (default 200000). Only applies to
                          diff-embed targets (uncommitted/staged/base/commit). PR
                          mode does not embed the diff and is not subject to this cap.

Exit codes:
  0  every panelist returned successfully
  1  setup error (no diff, no panelists, missing template)
  2  one or more panelists failed; raw outputs still written
EOF
}

die() { echo "panel-review: $*" >&2; exit 1; }

# ----- Parse args -----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uncommitted) TARGET="uncommitted"; TARGET_EXPLICIT=1; shift ;;
    --staged)      TARGET="staged"; TARGET_EXPLICIT=1; shift ;;
    --base)        [[ $# -ge 2 ]] || die "--base needs a branch"; TARGET="base:$2"; TARGET_EXPLICIT=1; shift 2 ;;
    --commit)      [[ $# -ge 2 ]] || die "--commit needs a SHA"; TARGET="commit:$2"; TARGET_EXPLICIT=1; shift 2 ;;
    --pr)          [[ $# -ge 2 ]] || die "--pr needs a number or URL"; TARGET="pr:$2"; TARGET_EXPLICIT=1; shift 2 ;;
    --focus)       [[ $# -ge 2 ]] || die "--focus needs text"; FOCUS="$2"; shift 2 ;;
    --panelist)
      [[ $# -ge 2 ]] || die "--panelist needs a name"
      # Validate against the known set up-front. The panelist name is later
      # interpolated into filesystem paths (worktree-$p, $p.out, $p.rc) and
      # passed to git worktree add — an unsanitized name like '../foo' would
      # escape $OUT_DIR and leave a stale entry in .git/worktrees.
      case "$2" in
        codex|claude|opencode) PANELISTS+=("$2") ;;
        *) die "--panelist: unknown panelist '$2' (allowed: codex, claude, opencode)" ;;
      esac
      shift 2 ;;
    --out-dir)     [[ $# -ge 2 ]] || die "--out-dir needs a path"; OUT_DIR="$2"; shift 2 ;;
    --timeout)     [[ $# -ge 2 ]] || die "--timeout needs seconds"; TIMEOUT_SECS="$2"; shift 2 ;;
    --checkout)
      # Deprecated: PR / --base / --commit reviews now always run worktree-
      # isolated with exec permissions. Accepting the flag as a no-op for those
      # targets so existing scripts / muscle memory don't break; will be removed
      # in a future release. Combined with --uncommitted/--staged the flag is an
      # error (see post-parse check below) — those targets cannot be worktree-
      # isolated, so silently dropping --checkout would give the user a
      # read-only review when they explicitly asked for deep mode.
      CHECKOUT_REQUESTED=1
      shift ;;
    -h|--help)     usage; exit 0 ;;
    *) die "unknown argument: $1 (use -h for help)" ;;
  esac
done

[[ -f "$PROMPT_TEMPLATE" ]] || die "missing prompt template at $PROMPT_TEMPLATE"

# ----- Auto-detect a PR for the current branch (only if no target was explicit) -----
#
# Why: when the user has a stale local main, a default `--base main` (or even
# `--uncommitted`) diff disagrees with what's actually in the PR on GitHub —
# panelists then flag commits that are already on the PR base as if they were
# part of "this change." `gh pr view` (no ref) returns the PR for the current
# branch when one exists, which is the source of truth a human reviewer would
# look at.
#
# Tiebreaker for dirty working trees: if the user has uncommitted changes and a
# PR exists, prefer reviewing the uncommitted work (active edits are usually
# what they want feedback on) and just log the PR's existence with the override
# hint. Clean tree + PR exists → switch to --pr mode silently.
if (( !TARGET_EXPLICIT )) && command -v gh >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # `gh pr view` returns the most-recent PR for the branch regardless of
    # state (open/closed/merged). Without filtering on state we'd silently
    # auto-switch a fresh review to a stale closed/merged PR — confusing
    # and inconsistent with the README/SKILL.md which describe this as
    # detecting an "open PR". Fetch state alongside number and only
    # auto-switch when state is OPEN.
    { read -r auto_pr_state; read -r auto_pr_num; } < <(
      gh pr view --json state,number -q '.state, .number' 2>/dev/null || true
    )
    if [[ "$auto_pr_state" == "OPEN" && -n "$auto_pr_num" ]]; then
      has_uncommitted=0
      if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        has_uncommitted=1
      elif [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        has_uncommitted=1
      fi
      if (( has_uncommitted )); then
        echo "panel-review: detected PR #$auto_pr_num for current branch, but reviewing uncommitted changes (you have local edits). Pass --pr $auto_pr_num to review the PR instead." >&2
      else
        echo "panel-review: detected PR #$auto_pr_num for current branch, using --pr mode. Pass --uncommitted to override." >&2
        TARGET="pr:$auto_pr_num"
      fi
    elif [[ -n "$auto_pr_num" ]]; then
      echo "panel-review: branch has PR #$auto_pr_num (state: $auto_pr_state) — not auto-switching. Pass --pr $auto_pr_num explicitly to review it anyway." >&2
    fi
  fi
fi

# Validate --checkout against the resolved target. For pr/base/commit it's a
# no-op (worktree is already the default). For uncommitted/staged it's an
# error: those targets have no committed ref to materialize a worktree from,
# so the previous behavior of silently dropping the flag would surprise users
# who explicitly requested deep mode. Telling them up-front lets them either
# commit/stash first or drop the flag.
if (( CHECKOUT_REQUESTED )); then
  case "$TARGET" in
    uncommitted|staged)
      die "--checkout cannot be combined with --$TARGET: there is no committed ref to materialize a worktree from. Either drop --checkout (you'll get a local read-only review) or commit/stash your changes first and re-run with --base or --commit."
      ;;
    *)
      echo "panel-review: --checkout is now the default for pr/base/commit targets and is a no-op; the flag will be removed in a future release." >&2
      ;;
  esac
fi

# Mode flags are derived from the resolved target — there is no separate
# user-facing "deep" / "checkout" toggle anymore:
#
#   - INSTRUCTION_MODE: the PR-fetch prompt (panelists run gh themselves
#     instead of getting an embedded diff). PR targets only.
#   - CHECKOUT_MODE: per-panelist throwaway worktree pinned to the target ref,
#     and panelists run with workspace-write / bypass permissions so they can
#     read code, grep callers, and run tests/build commands. Anything with a
#     real ref to materialize: pr / base / commit. uncommitted and staged
#     stay local-only because the changes don't yet exist as a ref.
case "$TARGET" in
  pr:*)            INSTRUCTION_MODE=1; CHECKOUT_MODE=1 ;;
  base:*|commit:*) CHECKOUT_MODE=1 ;;
esac

if (( CHECKOUT_MODE )); then
  command -v git >/dev/null 2>&1 || die "pr/base/commit reviews require git on PATH"
fi

if (( INSTRUCTION_MODE )); then
  [[ -f "$PROMPT_TEMPLATE_PR" ]] || die "missing PR prompt template at $PROMPT_TEMPLATE_PR"
  command -v gh >/dev/null 2>&1 || die "--pr requires the 'gh' CLI on PATH"
fi

# ----- Auto-detect panelists if none specified -----
if [[ ${#PANELISTS[@]} -eq 0 ]]; then
  for tool in codex claude opencode; do
    command -v "$tool" >/dev/null 2>&1 && PANELISTS+=("$tool")
  done
fi
[[ ${#PANELISTS[@]} -gt 0 ]] || die "no panelists found on PATH (looked for codex, claude, opencode)"

# ----- Output dir -----
if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$(mktemp -d -t panel-review-XXXXXX)"
else
  mkdir -p "$OUT_DIR"
fi

# ----- Build the diff (or, for PR targets, just the metadata) -----
DIFF_FILE="$OUT_DIR/diff.patch"
TARGET_LABEL=""
PR_BODY=""
pr_ref=""
pr_num=""
pr_title=""
pr_base=""
pr_repo=""
pr_url=""
case "$TARGET" in
  uncommitted)
    {
      git diff --cached --no-ext-diff
      git diff --no-ext-diff
    } > "$DIFF_FILE" || die "git diff failed"
    TARGET_LABEL="uncommitted changes (staged + unstaged)"
    ;;
  staged)
    git diff --cached --no-ext-diff > "$DIFF_FILE" || die "git diff --cached failed"
    TARGET_LABEL="staged changes"
    ;;
  base:*)
    base="${TARGET#base:}"
    git diff --no-ext-diff "$base"...HEAD > "$DIFF_FILE" || die "git diff $base...HEAD failed"
    TARGET_LABEL="changes vs base branch '$base'"
    ;;
  commit:*)
    sha="${TARGET#commit:}"
    git show --no-ext-diff "$sha" > "$DIFF_FILE" || die "git show $sha failed"
    TARGET_LABEL="commit $sha"
    ;;
  pr:*)
    # Instruction mode: don't pre-build the diff. Just resolve metadata once
    # so the prompt header has a useful title and panelists know exactly which
    # PR to fetch. Each panelist runs `gh pr diff` + comment APIs themselves
    # against GitHub, so they always see the current remote state — no risk of
    # the script's view drifting from what reviewers see in the GitHub UI.
    pr_ref="${TARGET#pr:}"
    gh_err="$OUT_DIR/gh-pr-view.err"
    { read -r pr_num; read -r pr_title; read -r pr_base; read -r pr_url; } < <(
      gh pr view "$pr_ref" \
        --json number,title,baseRefName,url \
        -q '.number, .title, .baseRefName, .url' \
        2>"$gh_err" || true
    )
    if [[ -z "$pr_num" || -z "$pr_url" ]]; then
      msg="--pr: failed to resolve PR metadata via 'gh pr view $pr_ref'"
      [[ -s "$gh_err" ]] && msg+=$'\n  gh stderr: '"$(cat "$gh_err")"
      die "$msg"
    fi
    # gh pr view does not expose baseRepository as a top-level json field;
    # parse owner/repo out of the canonical PR URL instead. Works for github.com
    # and GitHub Enterprise (the host portion is preserved up to `/owner/repo/pull/N`).
    pr_repo="$(echo "$pr_url" | sed -E 's|^https?://[^/]+/||; s|/pull/.*$||')"
    if [[ -z "$pr_repo" || "$pr_repo" == "$pr_url" ]]; then
      die "--pr: could not parse owner/repo from PR url '$pr_url'"
    fi
    PR_BODY="$(gh pr view "$pr_ref" --json body -q .body 2>/dev/null || true)"
    TARGET_LABEL="PR #${pr_num}"
    [[ -n "$pr_title" ]] && TARGET_LABEL+=" — $pr_title"
    [[ -n "$pr_base"  ]] && TARGET_LABEL+=" (base: $pr_base)"
    ;;
esac

# Diff-existence check only applies to embed targets. PR mode has no diff file.
if (( !INSTRUCTION_MODE )); then
  [[ -s "$DIFF_FILE" ]] || die "diff is empty for target: $TARGET"
fi

# ----- Optional: materialize one worktree per panelist for deep-mode -----
#
# Why one worktree per panelist (CI matrix style): in --checkout mode, panelists
# run real test suites and may edit files as part of investigation. Sharing one
# worktree across N parallel panelists invites:
#   - test runners racing on lockfiles / build dirs (target/, node_modules/.cache,
#     .next/, dist/) — flaky failures unrelated to the diff
#   - one panelist's edits leaking into another's review state, breaking the
#     "independent observers" guarantee the skill is built around
#   - one panelist's `pnpm install` corrupting another's run if it dies mid-write
# Disk cost is N × repo, but pnpm/cargo/npm caches are shared at the user level so
# most of the bytes are hardlinks. Cleanup loops in the EXIT trap so nothing leaks
# if the script is killed.
declare -a WORKTREES=()
if (( CHECKOUT_MODE )); then
  echo "panel-review: --checkout: materializing one worktree per panelist under $OUT_DIR" >&2

  # Resolve a single commit SHA every worktree will pin to. One fetch (for --pr),
  # then N cheap local checkouts — avoids gh-pr-checkout's branch-naming conflict
  # when worktree #2 tries to claim the same local branch as worktree #1.
  WORKTREE_REF=""
  case "$TARGET" in
    pr:*)
      [[ -n "${pr_num:-}" ]] || die "--pr --checkout: could not resolve PR number"
      # Resolve everything from pr_ref directly. A bare `gh repo view` would
      # return the cwd's default repo, which can disagree with pr_ref when
      # pr_ref is a URL pointing at a different repo (e.g. running from a fork
      # clone but reviewing an upstream PR). Using gh pr view "$pr_ref" keeps
      # repo context end-to-end. Single call returns three lines via jq's
      # comma operator; bash-3.2-compatible read; read; read consumes them.
      # Capture gh's stderr to a file rather than swallowing it — auth errors,
      # network blips, and missing-headRepository (deleted-fork PRs) all need
      # to surface in the die message instead of collapsing to a generic
      # "failed to resolve" line.
      gh_err="$OUT_DIR/gh-pr-view.err"
      { read -r pr_url; read -r pr_head_sha; read -r pr_head_nwo; } < <(
        gh pr view "$pr_ref" --json url,headRefOid,headRepository \
                  -q '.url, .headRefOid, .headRepository.nameWithOwner' 2>"$gh_err" || true
      )
      # jq prints the literal string "null" (not empty) for missing object
      # fields when used with -q, so an emptiness check alone misses the
      # deleted-fork case. Reject "null" explicitly with a tailored message
      # since the recovery (use --uncommitted) is fork-specific.
      if [[ "$pr_head_nwo" == "null" ]]; then
        die "--pr: PR #${pr_num} head repository has been deleted (likely a deleted fork); cannot create a worktree. Use --uncommitted to review local edits instead, or pass an explicit --commit <sha> if you have the head commit locally."
      fi
      if [[ -z "$pr_url" || -z "$pr_head_sha" || -z "$pr_head_nwo" ]]; then
        msg="--pr --checkout: failed to resolve PR url/SHA/head-repo via gh pr view"
        [[ -s "$gh_err" ]] && msg+=$'\n  gh stderr: '"$(cat "$gh_err")"
        die "$msg"
      fi
      # Mirror origin's URL shape (SSH vs HTTPS) so the fetch uses whatever
      # auth this machine has already set up. Hardcoding HTTPS hangs on a
      # credential prompt for users with SSH-only auth and no HTTPS credential
      # helper. Falls back to HTTPS (host derived from pr_url so GitHub
      # Enterprise works) when origin is missing or in an unrecognized shape.
      pr_host="$(echo "$pr_url" | sed -E 's|^(https?://[^/]+)/.*|\1|')"
      pr_head_https_url="${pr_host}/${pr_head_nwo}.git"
      origin_url="$(git remote get-url origin 2>/dev/null || true)"
      case "$origin_url" in
        ssh://*)
          # ssh://[user@]host[:port]/owner/repo[.git]
          ssh_authority="${origin_url#ssh://}"
          ssh_authority="${ssh_authority%%/*}"
          pr_head_url="ssh://${ssh_authority}/${pr_head_nwo}.git"
          ;;
        *://*)
          # https/http/git/file URL — use HTTPS fallback.
          pr_head_url="$pr_head_https_url"
          ;;
        *:*)
          # SCP-like SSH: [user@]host:path. The bare `host:path` form (no
          # user@) is common with ~/.ssh/config Host aliases like
          # `github-work:owner/repo.git`, so we don't require `@`. The earlier
          # *://* arm has already consumed every URL-form remote, so any colon
          # left here is the SCP separator.
          pr_head_url="${origin_url%%:*}:${pr_head_nwo}.git"
          ;;
        *)
          pr_head_url="$pr_head_https_url"
          ;;
      esac
      git fetch --quiet "$pr_head_url" "$pr_head_sha" >&2 \
        || die "git fetch $pr_head_url $pr_head_sha failed"
      WORKTREE_REF="$pr_head_sha"
      ;;
    base:*)
      WORKTREE_REF="$(git rev-parse HEAD)"
      ;;
    commit:*)
      WORKTREE_REF="${TARGET#commit:}"
      ;;
  esac

  # Register cleanup BEFORE the creation loop. If `git worktree add` fails partway
  # through (disk full, ref doesn't exist after a fetch race, etc.), die() exits
  # immediately — without the trap already in place, any worktrees added before
  # the failure would leak into .git/worktrees. The trap body iterates WORKTREES,
  # which is single-quoted and re-expanded at signal time, so it cleans up exactly
  # the dirs we managed to add (zero or more).
  # `${WORKTREES[@]:-}` would expand to a single empty element on bash 3.2 (the
  # macOS default) and produce a confusing error under `set -u`. Guard the loop
  # with a count check so the trap is a no-op when nothing has been added yet.
  trap '
    if (( ${#WORKTREES[@]} > 0 )); then
      for _wt in "${WORKTREES[@]}"; do
        [[ -n "$_wt" ]] && git worktree remove --force "$_wt" >/dev/null 2>&1 || true
      done
    fi
  ' EXIT

  for p in "${PANELISTS[@]}"; do
    wt="$OUT_DIR/worktree-$p"
    git worktree add --quiet --detach "$wt" "$WORKTREE_REF" >&2 \
      || die "git worktree add $wt $WORKTREE_REF failed"
    WORKTREES+=("$wt")
  done

  echo "panel-review: --checkout: ${#WORKTREES[@]} worktrees ready, panelists will run with WRITE/EXEC permissions in their own isolated checkouts" >&2
fi

# Diff-size cap only applies when we're embedding the diff in the prompt.
# Instruction-mode panelists fetch via gh and don't need the cap.
if (( !INSTRUCTION_MODE )); then
  DIFF_BYTES=$(wc -c < "$DIFF_FILE" | tr -d ' ')
  if (( DIFF_BYTES > MAX_DIFF_BYTES )); then
    die "diff is $DIFF_BYTES bytes, exceeds cap $MAX_DIFF_BYTES.
  Either narrow the scope (e.g. --commit, --staged, or a smaller --base range),
  or raise the cap, e.g.:  PANEL_REVIEW_MAX_DIFF_BYTES=$((DIFF_BYTES * 2)) bash $0 ...
  Caps exist because each panelist embeds the full diff in its prompt; very large
  diffs blow context windows and cost a lot. (PR mode bypasses this — panelists
  fetch the diff via gh themselves and never embed it.)"
  fi
fi

# ----- Compose the per-run prompt -----
#
# Two template paths:
#   - PR target:        prompts/review-pr.md  - instruction-style; panelists
#                                               run gh themselves, no diff embedded.
#   - everything else:  prompts/review.md     - mode-agnostic; the diff is
#                                               embedded and the script-appended
#                                               `## Workspace` section tells the
#                                               panelist what tools they can use.
ACTIVE_TEMPLATE="$PROMPT_TEMPLATE"
(( INSTRUCTION_MODE )) && ACTIVE_TEMPLATE="$PROMPT_TEMPLATE_PR"
PROMPT_FILE="$OUT_DIR/prompt.md"

# Substitute PR placeholders in the template body. We use bash parameter
# expansion rather than sed so values containing slashes (URLs, owner/repo)
# don't need escaping. Substitution happens whether or not the template uses
# the placeholders — non-PR templates just have nothing to replace.
TEMPLATE_BODY="$(cat "$ACTIVE_TEMPLATE")"
if (( INSTRUCTION_MODE )); then
  TEMPLATE_BODY="${TEMPLATE_BODY//\{\{PR_REF\}\}/$pr_ref}"
  TEMPLATE_BODY="${TEMPLATE_BODY//\{\{PR_NUMBER\}\}/$pr_num}"
  TEMPLATE_BODY="${TEMPLATE_BODY//\{\{PR_REPO\}\}/$pr_repo}"
  TEMPLATE_BODY="${TEMPLATE_BODY//\{\{PR_URL\}\}/$pr_url}"
fi

{
  printf '%s\n' "$TEMPLATE_BODY"
  echo
  echo "## Review target"
  echo
  echo "$TARGET_LABEL"
  if (( INSTRUCTION_MODE )); then
    echo
    echo "## PR identifiers (use these in your gh commands)"
    echo
    echo "- PR ref (pass to \`gh pr view\` / \`gh pr diff\`): \`$pr_ref\`"
    echo "- PR number: \`$pr_num\`"
    echo "- Repo (owner/name) for \`gh api\` calls: \`$pr_repo\`"
    [[ -n "$pr_url"  ]] && echo "- URL: $pr_url"
    [[ -n "$pr_base" ]] && echo "- Base branch: \`$pr_base\`"
  fi
  echo
  echo "## Workspace"
  echo
  if (( CHECKOUT_MODE )); then
    echo "You are running inside a dedicated git worktree pinned to this review's target ref"
    echo "— the actual checkout, not a free-floating diff. You may:"
    echo
    echo "- Read any file in the tree."
    echo "- Grep / rg across the tree to find callers of changed symbols."
    echo "- Edit files locally (the worktree is thrown away on exit)."
    echo "- Run build / test / lint commands to investigate downstream effects."
    echo "  Typical commands: \`pnpm test\` / \`npm test\` / \`cargo test\` / \`go test ./...\` /"
    echo "  \`pytest\` / \`bundle exec rspec\`; type checkers like \`tsc --noEmit\`, \`mypy\`,"
    echo "  \`cargo check\`. Check the repo's README / package.json / Makefile for the right one."
    echo "- Install dev dependencies if a test runner needs them; bound test runs to ~3 minutes."
    echo "- A failing test is a high-signal finding; surface it under Evidence."
    echo
    echo "Use that capability when it sharpens a finding. Do NOT do investigation theatre — only"
    echo "run tools when they harden the report. Local writes inside the worktree are fine; the"
    echo "external-network and GitHub-write rules in Hard Constraints still apply."
  else
    echo "You are running in the user's actual working tree with **read-only** access. You may:"
    echo
    echo "- Read any file using your built-in read tools (Read / Glob / Grep)."
    echo "- Reason about the diff and the surrounding code."
    echo
    echo "Do NOT modify files, run tests, install packages, or execute shell commands that"
    echo "change state. The \`Evidence:\` line in the finding shape is not meaningful in this"
    echo "mode — leave it out."
  fi
  if [[ -n "$PR_BODY" ]]; then
    echo
    echo "## PR description"
    echo
    echo "$PR_BODY"
  fi
  if [[ -n "$FOCUS" ]]; then
    echo
    echo "## Reviewer focus"
    echo
    echo "$FOCUS"
  fi
  if (( !INSTRUCTION_MODE )); then
    echo
    echo "## Diff"
    echo
    echo '```diff'
    cat "$DIFF_FILE"
    echo '```'
  fi
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

# Wrapper that prepends a timeout if available. Avoids empty-array expansion under
# bash 3.2 + set -u.
run_panelist() {
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$TIMEOUT_SECS" "$@"
  else
    "$@"
  fi
}

# ----- Build each panelist's argv -----
#
# Two permission tiers, keyed off CHECKOUT_MODE (which is set whenever the
# target is pr/base/commit — i.e., anything with a real ref to materialize):
#
#   Local mode  (uncommitted/staged): read-only / plan. Panelists run from the
#               user's working tree but cannot exec anything that writes.
#   Worktree mode (pr/base/commit):   workspace-write / bypass / build agent.
#               Panelists run inside a throwaway per-panelist worktree pinned
#               to the target ref and can read code, grep callers, run
#               tests/build commands. Network/destructive actions are gated by
#               the prompt only — no sandbox-level guarantee.
build_argv() {
  local name="$1"
  case "$name" in
    codex)
      if (( CHECKOUT_MODE )); then
        argv=(codex exec --skip-git-repo-check --sandbox workspace-write --color=never)
      else
        argv=(codex exec --skip-git-repo-check --sandbox read-only --color=never)
      fi
      [[ -n "$CODEX_MODEL" ]] && argv+=(-m "$CODEX_MODEL")
      argv+=(-- "$PROMPT_CONTENT")
      ;;
    claude)
      if (( CHECKOUT_MODE )); then
        # plan mode blocks Bash; gh / tests / grep need shell access, so we
        # relax to bypassPermissions inside the worktree and rely on the
        # prompt's hard constraints to forbid state-changing actions.
        argv=(claude -p --permission-mode bypassPermissions --output-format text --no-session-persistence)
      else
        argv=(claude -p --permission-mode plan --output-format text --no-session-persistence)
      fi
      [[ -n "$CLAUDE_MODEL" ]] && argv+=(--model "$CLAUDE_MODEL")
      argv+=(-- "$PROMPT_CONTENT")
      ;;
    opencode)
      # `opencode run` takes the message positionally; --prompt is not a flag here
      # and would make opencode dump its --help and exit 1.
      local agent="$OPENCODE_AGENT"
      (( CHECKOUT_MODE )) && agent="$OPENCODE_AGENT_DEEP"
      argv=(opencode run --agent "$agent")
      (( CHECKOUT_MODE )) && argv+=(--dangerously-skip-permissions)
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
echo "panel-review: target=$TARGET_LABEL panelists=${PANELISTS[*]} out=$OUT_DIR" >&2

declare -a PIDS=()
for p in "${PANELISTS[@]}"; do
  out="$OUT_DIR/$p.out"
  err="$OUT_DIR/$p.err"
  rc="$OUT_DIR/$p.rc"

  if ! command -v "$p" >/dev/null 2>&1; then
    echo "panel-review: '$p' not on PATH — skipping" >&2
    : >"$out"
    echo "panelist '$p' not found on PATH" >"$err"
    echo "127" >"$rc"
    continue
  fi

  if ! build_argv "$p"; then
    echo "panel-review: unknown panelist '$p' — skipping" >&2
    : >"$out"
    echo "unknown panelist '$p'" >"$err"
    echo "127" >"$rc"
    continue
  fi

  panel_cwd="$PWD"
  (( CHECKOUT_MODE )) && panel_cwd="$OUT_DIR/worktree-$p"
  ( cd "$panel_cwd" && run_panelist "${argv[@]}" >"$out" 2>"$err"; echo $? >"$rc" ) &
  PIDS+=($!)
  echo "panel-review: ${p} started (pid=$!, cwd=$panel_cwd)" >&2
done

# ----- Stream combined results as each panelist finishes -----
#
# Why streaming: each panelist runs in parallel, but the slowest one (often codex)
# dominates wall clock. Printing sections only after `wait` returns means the
# coordinator (Claude or a human) sees nothing until the slowest finishes. Polling
# the per-panelist .rc files lets us print each section the moment it lands, and
# emit a stderr heartbeat so progress is visible when the script is run as a
# background Bash with BashOutput polling. stderr is unbuffered by libc; stdout
# may block-buffer when piped, so heartbeats go to stderr on purpose.
ANY_FAIL=0
echo "# Panel review"
echo
echo "- Target: $TARGET_LABEL"
echo "- Panelists: ${PANELISTS[*]}"
echo "- Outputs: \`$OUT_DIR\`"
# Surface the PR URL and repo for PR targets so the synthesizer can wrap
# `file:line` findings as tappable links via skills/panel-review/pr-line-url.sh
# without re-parsing the prompt file. Only emitted in PR mode.
[[ -n "$pr_url"  ]] && echo "- PR URL: $pr_url"
[[ -n "$pr_repo" ]] && echo "- PR Repo: $pr_repo"
[[ -n "$FOCUS" ]] && echo "- Focus: $FOCUS"
echo

# Extract the model id from a panelist's stdout. Each prompt instructs the
# panelist to print `Model: <id>` as the very first line of its output, so the
# script can label per-panelist sections / heartbeats with the actual model
# that produced the review (e.g. "## codex / gpt-5.5 (exit 0)") without having
# to introspect each CLI's default-model config.
#
# Falls back to the env var override if the panelist's first line isn't a
# recognisable Model: line, then to a literal "?". `head -n1` so we never scan
# beyond the first line — Model: appearing anywhere later in the output should
# not influence the header.
extract_model_label() {
  local p="$1"
  local fallback="$2"
  local first_line=""
  [[ -s "$OUT_DIR/$p.out" ]] && first_line="$(head -n1 "$OUT_DIR/$p.out" 2>/dev/null || true)"
  case "$first_line" in
    Model:*)
      local label="${first_line#Model:}"
      # Trim leading whitespace (single space is the common case after `Model:`).
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
  echo "panel-review: ${p} (${model_label}) done (exit ${rc_val})" >&2
}

# Track which panelists have already been printed. Bash 3.2 (macOS default) has
# no associative arrays, so we keep a parallel indexed array of names.
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

# Reap any background PIDs that already exited; harmless if all are gone.
[[ ${#PIDS[@]} -gt 0 ]] && wait "${PIDS[@]}" 2>/dev/null || true

exit $(( ANY_FAIL ? 2 : 0 ))
