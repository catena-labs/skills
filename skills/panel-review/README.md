# panel-review

Fan a code review out to multiple local CLI coding agents (codex, claude, opencode) running in parallel, then synthesize their findings into one report. In deep mode, each agent gets its own isolated git worktree so they can run tests and chase downstream effects in parallel without stepping on each other.

## Install

```
npx skills add catena-labs/skills --skill panel-review
```

## How to use it

Just ask Claude Code in plain English — the skill picks up the target and panelists from your phrasing:

- "panel review my latest changes on this branch"
- "panel review my staged changes"
- "panel review PR 27"
- "panel review this branch against main"
- "deep panel review PR 27" / "really dig into PR 27 and run the tests" (spins up worktrees so panelists can actually execute tests and grep callers)
- "panel review the auth changes, focus on session handling"
- "panel review with just codex and claude"

## What it does

- Builds a unified diff from whatever target you named (uncommitted work, staged changes, a branch comparison, a specific commit, or a PR).
- Spawns each panelist as a fresh, non-interactive subprocess with no shared conversation state — the whole point is independent second opinions.
- Streams each panelist's section back as it lands, then groups results into consensus / unique findings / disagreements.
- Deep mode spins up **a dedicated, throwaway git worktree per panelist**, all pinned to the same commit. Agents can run tests, install deps, and grep callers in parallel without racing each other's `node_modules/` / `target/` / `.next/`. One network fetch up front, then local-only worktree creation; everything is torn down on exit.

## Gotchas

- **Background Bash + `BashOutput` polling is required.** Codex dominates wall clock, so foreground calls block silently for minutes. Do not launch via the `Agent` tool / subagents — there's no streaming-output API for in-flight subagents and the heartbeats become invisible.
- **Deep mode is strictly less safe than the default.** It gives panelists write/exec access in the worktree and shares your parent repo's `.git` objects, so a stray `git push` from a panelist would publish from your machine. The prompt forbids it, but the prompt is a firewall, not a sandbox.
- **Each panelist embeds the full diff in its prompt.** Big rename / refactor PRs blow past the 200KB cap — bump `PANEL_REVIEW_MAX_DIFF_BYTES` rather than trimming the diff.
- Panelists pick up the project's `AGENTS.md` / `CLAUDE.md` — that's intentional, but worth knowing if the file biases their review.
