# Research notes for optimize-agents-md

_Last verified: 2026-05-11._

Background findings that inform the skill. Bullets are facts, not advice — the SKILL.md is where advice lives. Sources are linked inline. Community sources (Medium, Substack, Dev.to) vary in rigor; weight Anthropic docs and GitHub issues above them.

## Instruction budget

- **Frontier LLMs reliably follow ~150–200 instructions per session.** Claude Code's system prompt already consumes ~50 of those slots. Every line you add dilutes compliance across _all_ rules uniformly, not just new ones. (source: [HumanLayer](https://www.humanlayer.dev/blog/writing-a-good-claude-md))
- **CLAUDE.md is wrapped in a `<system-reminder>` tag** that explicitly tells Claude the content "may or may not be relevant" and to ignore anything not relevant to the current task. Non-universal instructions get actively skipped. (source: [HumanLayer](https://www.humanlayer.dev/blog/writing-a-good-claude-md))
- **Litmus test for every line:** "Would removing this line cause Claude to make a mistake?" If no, cut it. (source: [Anthropic best practices](https://code.claude.com/docs/en/best-practices))
- **Tool-specific instructions are followed 160x more often.** Mentioning a specific tool like `uv` causes agents to use it 160x more than naming none. Highest-leverage line type. (source: [ETH Zurich AGENTbench via Thomas Wiegold](https://thomas-wiegold.com/blog/claude-md-helpful-or-expensive-noise/))
- **Human-written context files improve task success ~4%; LLM-generated ones decrease it.** ETH Zurich AGENTbench, Feb 2026. (source: [InfoQ](https://www.infoq.com/news/2026/03/agents-context-file-value-review/))
- **TechLoom benchmark of 1,188 runs:** quality spread between best and worst CLAUDE.md profiles was only 0.6 points; choosing the right model mattered 4x more. (source: [TechLoom](https://techloom.it/blog/claudemd-benchmark-results.html))
- **28.7% of lines in cursor rules are duplicates** of information already accessible to the AI through other documentation. Study of 2,303 real context files across 1,925 repos. (source: [arXiv 2512.18925](https://arxiv.org/pdf/2512.18925))
- **CLAUDE.md files grow continuously (~57 words/commit median) but deletions are negligible** — creates "context debt" analogous to technical debt. (source: [arXiv 2511.12884](https://arxiv.org/html/2511.12884v1))
- **Compliance decay over long conversations:** 95%+ at messages 1–2, dropping to 20–60% by messages 6–10. Hooks don't suffer this decay. (source: [Thomas Wiegold](https://thomas-wiegold.com/blog/claude-md-helpful-or-expensive-noise/))

## Structure and formatting

- **Average real CLAUDE.md has 16 headings, depth 2.6.** Effective files maintain breadth without unnecessary depth — H2 for sections, H3 for subsections, rarely H4, never deeper. (source: [EmergentMind](https://www.emergentmind.com/topics/claude-md-manifests))
- **Primacy/recency anchoring:** put the 3 most-violated rules in the first 5 lines _and_ the last 5 lines, with intentional duplication. Less critical rules go in the middle. (source: [DEV Community / docat0209](https://dev.to/docat0209/5-patterns-that-make-claude-code-actually-follow-your-rules-44dh))
- **Prohibitions need rationale.** "Never force push — rewrites shared history, unrecoverable for collaborators" lets Claude generalize the principle to related situations. (source: [DEV Community / cleverhoods](https://dev.to/cleverhoods/-claudemd-best-practices-7-formatting-rules-for-the-machine-3d3l))
- **Commands in code fences (`pytest`) get followed; commands in prose ("run pytest") get buried.** (source: [DEV Community / cleverhoods](https://dev.to/cleverhoods/-claudemd-best-practices-7-formatting-rules-for-the-machine-3d3l))
- **One instruction per bullet.** Combining multiple rules in a single line reduces compliance with all of them. (source: [DEV Community / cleverhoods](https://dev.to/cleverhoods/-claudemd-best-practices-7-formatting-rules-for-the-machine-3d3l))
- **Stripping markdown decoration hurts performance,** especially on smaller models like Haiku, where headers and bold text serve as parsing landmarks. (source: [TechLoom](https://techloom.it/blog/claudemd-benchmark-results.html))

## Tone

- **Imperative for behaviors, declarative for facts.** "Use named exports" is a rule; "this repo uses bun test" is project info. Imperative-style facts ("YOU MUST use bun") can trip prompt-injection defenses, causing Claude to surface the text to the user instead of treating it as context. Refines the older "always be imperative" guidance. (source: [Anthropic hooks docs](https://code.claude.com/docs/en/hooks), [rahuulmiishra/Medium](https://rahuulmiishra.medium.com/your-claude-md-is-doing-too-much-heres-how-to-fix-it-2cc495ed3599))
- **Positive framing outperforms negative framing.** One practitioner reported flipping 10 negative rules to positive equivalents cut violations by ~half. "Do NOT use semicolons" activates the concept then tries to negate it. Rewrite as "Use semicolons sparingly; prefer ASI." (source: [DEV Community / docat0209](https://dev.to/docat0209/5-patterns-that-make-claude-code-actually-follow-your-rules-44dh))
- **Specific negative instructions still work for failure-mode inoculation.** "Don't add JS event handlers when the framework already handles reactivity" is specific and failure-driven. Vague negatives ("don't be sloppy") are useless. (source: [TechTwitter](https://www.techtwitter.com/articles/the-breakdown-of-a-claude-code-prompt))
- **MUST and IMPORTANT increase compliance** but dilute if overused. Reserve for the 3–5 rules that truly cannot be broken. (source: [Anthropic best practices](https://code.claude.com/docs/en/best-practices))
- **Always pair prohibitions with alternatives.** "Never use `--foo`; prefer `--baz`" gives Claude a path forward. (source: [rosmur best practices](https://rosmur.github.io/claudecode-best-practices/))

## Memory file hierarchy

- **Five-layer hierarchy, broadest to narrowest:** managed policy (`/Library/Application Support/ClaudeCode/CLAUDE.md`) → user (`~/.claude/CLAUDE.md`) → project root → subdirectory → local (`CLAUDE.local.md`, gitignored). (source: [Anthropic memory docs](https://docs.anthropic.com/en/docs/claude-code/memory))
- **All discovered files are concatenated, not overridden.** Later-loaded (more specific) files get more attention via recency bias. (source: [Anthropic memory docs](https://docs.anthropic.com/en/docs/claude-code/memory))
- **Subdirectory CLAUDE.md files load lazily** — only when Claude touches files in that subtree. Sibling directories never cross-contaminate. (source: [Anthropic best practices](https://code.claude.com/docs/en/best-practices))
- **`claudeMdExcludes` setting** lets you skip irrelevant ancestor files: `{ "claudeMdExcludes": ["**/monorepo/other-team/.claude/rules/**"] }`. (source: [Anthropic memory docs](https://docs.anthropic.com/en/docs/claude-code/memory))
- **Monorepo root CLAUDE.md should contain only conventions used by 30%+ of engineers;** service-specific guidance goes in subdirectory files. (source: [stepfun-ai cookbook](https://github.com/stepfun-ai/Step-3.5-Flash/blob/main/cookbooks/claude-code-best-practices/README.en.md))

## `.claude/rules/` and on-demand loading

- **Canonical 2026 split:** lean CLAUDE.md (≤200 lines) for universal context + path-scoped rule files in `.claude/rules/` for domain-specific guidance. (source: [rahuulmiishra/Medium](https://rahuulmiishra.medium.com/your-claude-md-is-doing-too-much-heres-how-to-fix-it-2cc495ed3599), [obviousworks](https://www.obviousworks.ch/en/designing-claude-md-right-the-2026-architecture-that-finally-makes-claude-code-work/))
- **Rules files with `paths:` frontmatter load on-demand** only when Claude touches matching files; without it, they load at startup at the same priority as CLAUDE.md. Optional `priority: high|low` nudges load ordering. (source: [Anthropic memory docs](https://docs.anthropic.com/en/docs/claude-code/memory))
- **Known bug (gh #21858):** user-level rules in `~/.claude/rules/` with `paths:` frontmatter silently never fire. Workaround: keep path-scoped rules at the project level only. (source: [github.com/anthropics/claude-code#21858](https://github.com/anthropics/claude-code/issues/21858))
- **No hard cap on rules files per project.** Earlier reports of a 20-file cap did not survive verification. What exists is soft compliance degradation past ~200 instructions. (source: [rahuulmiishra/Medium](https://rahuulmiishra.medium.com/your-claude-md-is-doing-too-much-heres-how-to-fix-it-2cc495ed3599))
- **15,000-character budget for skill descriptions** loaded into context (configurable via `SLASH_COMMAND_TOOL_CHAR_BUDGET`). This one is real and enforced. (source: [shanraisshan/claude-code-best-practice](https://github.com/shanraisshan/claude-code-best-practice/blob/main/reports/claude-skills-for-larger-mono-repos.md))

## Progressive disclosure

- **Treat CLAUDE.md as an index, not an encyclopedia.** Move detail into well-organized docs and reference them. (source: [joseparreogarcia/Substack](https://joseparreogarcia.substack.com/p/claude-code-memory-explained))
- **Use prose references (`see docs/file.md`), not `@-imports` (`@docs/file.md`).** `@` expands the file at session start regardless of relevance; prose references let Claude pull on demand. (source: [rosmur best practices](https://rosmur.github.io/claudecode-best-practices/), [Anthropic memory docs](https://docs.anthropic.com/en/docs/claude-code/memory))
- **Skills load conditionally** based on description match, unlike CLAUDE.md which loads every session. Move specialized domain knowledge — deployment procedures, niche API patterns, migration guides — into skills. (source: [Anthropic best practices](https://code.claude.com/docs/en/best-practices))

## Four-layer mental model

- **Four-layer split (Boris Cherny, canonical 2026):** CLAUDE.md = always-loaded universal context, Skills = conditionally-loaded task playbooks, Hooks = deterministic enforcement, Subagents = isolated workers with own context. (source: [obviousworks](https://www.obviousworks.ch/en/designing-claude-md-right-the-2026-architecture-that-finally-makes-claude-code-work/), [becoming-for-better/Medium](https://medium.com/becoming-for-better/taming-claude-code-a-guide-to-claude-md-and-hooks-ed059879991c))
- **Decision tree:** suggestion → CLAUDE.md, requirement → hook, reusable workflow → skill, heavy/isolated work → subagent, external service → MCP. (source: [obviousworks](https://www.obviousworks.ch/en/designing-claude-md-right-the-2026-architecture-that-finally-makes-claude-code-work/), [LevelUp/12 patterns](https://levelup.gitconnected.com/claude-code-best-practices-12-patterns-agentic-engineers-use-65264e3eb919))

## Hooks

- **"CLAUDE.md rules are requests. Hooks are laws."** If a rule has been violated 3+ times despite being in CLAUDE.md, graduate it to a hook. (source: [Thomas Wiegold](https://thomas-wiegold.com/blog/claude-md-helpful-or-expensive-noise/))
- **Hook surface expanded from 14 to 21 events by April 2026.** New events: `InstructionsLoaded`, `ConfigChange`, `WorktreeCreate`, `WorktreeRemove`, `PostToolBatch`, `PostToolUseFailure` (split from `PostToolUse`), `PreCompact`, `PostCompact`, `Elicitation`, `ElicitationResult`. (source: [Anthropic hooks docs](https://code.claude.com/docs/en/hooks), [smartscope hooks guide](https://smartscope.blog/en/generative-ai/claude/claude-code-hooks-guide/), [pixelmojo](https://www.pixelmojo.io/blogs/claude-code-hooks-production-quality-ci-cd-patterns))
- **Two new handler types:** HTTP hooks that POST to a webhook URL, and async hooks (`async: true`) that fire-and-forget without blocking the next tool call. (source: [claudefa.st hooks guide](https://claudefa.st/blog/tools/hooks/hooks-guide), [smartscope hooks guide](https://smartscope.blog/en/generative-ai/claude/claude-code-hooks-guide/))
- **`InstructionsLoaded` hook (v2.1.69)** is the first observability primitive for the rules system. Receives `load_reason`: `session_start | nested_traversal | path_glob_match | include | compact`. Use to debug which rules fire, prune rules that never load, or fire notifications when nested context activates. Async, observability-only. (source: [Anthropic hooks docs](https://code.claude.com/docs/en/hooks), [rahuulmiishra/Medium](https://rahuulmiishra.medium.com/your-claude-md-is-doing-too-much-heres-how-to-fix-it-2cc495ed3599))
- **`InstructionsLoaded` doesn't fire on `/clear`** even though instructions reload from disk. (source: [github.com/anthropics/claude-code#31017](https://github.com/anthropics/claude-code/issues/31017))
- **Dynamic CLAUDE.md loading feature request open** at gh #34941; Codex's parity tracker references the hook as the missing piece. (source: [github.com/anthropics/claude-code#34941](https://github.com/anthropics/claude-code/issues/34941), [github.com/openai/codex#21675](https://github.com/openai/codex/issues/21675))
- **Use `settings.json` for configuration, not guidance.** Setting `attribution.commit: ""` deterministically prevents Co-Authored-By lines; writing "NEVER add Co-Authored-By" in CLAUDE.md is a probabilistic request that degrades. (source: [shanraisshan/claude-code-best-practice](https://github.com/shanraisshan/claude-code-best-practice))
- **Decision rule:** preference → CLAUDE.md, requirement → hook, behavior → settings. (source: [DEV Community / docat0209](https://dev.to/docat0209/5-patterns-that-make-claude-code-actually-follow-your-rules-44dh))

## Subagents

- **Subagent frontmatter is the new home for behavioral rules.** Schema includes `tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`, `skills`, `mcpServers`, `hooks`, `memory`, `background`. Rules like "use plan mode for `src/billing/`" or "always run review on Haiku" belong here, not in CLAUDE.md prose. (source: [obviousworks](https://www.obviousworks.ch/en/designing-claude-md-right-the-2026-architecture-that-finally-makes-claude-code-work/), [LevelUp/12 patterns](https://levelup.gitconnected.com/claude-code-best-practices-12-patterns-agentic-engineers-use-65264e3eb919), [the-ai-corner](https://www.the-ai-corner.com/p/claude-best-practices-power-user-guide-2026))
- **Anthropic recommends delegating research to subagents** for investigate-style work so exploration tokens don't bloat the parent conversation. (source: [Anthropic best practices](https://code.claude.com/docs/en/best-practices))

## Skills

- **Two-Claude development loop is the recommended skill-authoring workflow.** Claude A drafts/refines SKILL.md; Claude B uses it on real tasks; observations from B feed back to A. (source: [Anthropic skill best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices))
- **Skill description matters more than body.** At session start, Claude reads only descriptions to decide which skills load. Specific descriptions trigger; generic ones never do. (source: [Anthropic skill best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices))
- **Skill bodies compete for the same instruction budget as CLAUDE.md** once loaded. Apply the same curation rules. (source: [Anthropic skill best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices))
- **Scope skills deliberately:** project-specific in `.claude/skills/`, user-global in `~/.claude/skills/`. Mixing blurs ownership. (source: [Anthropic skill best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices), [maa1/Medium](https://maa1.medium.com/adding-agentic-skills-to-claude-code-54a2c1d42fd1))

## Cross-tool / AGENTS.md

- **AGENTS.md became an open standard in December 2025,** donated to the Linux Foundation's Agentic AI Foundation by OpenAI. Read natively by Claude Code, Codex CLI, Cursor, GitHub Copilot, Gemini CLI, Windsurf. OpenAI's main repo contains 88 AGENTS.md files. (source: [Augment Code AGENTS.md guide](https://www.augmentcode.com/guides/how-to-build-agents-md), [Factory.ai AGENTS.md docs](https://docs.factory.ai/cli/configuration/agents-md))
- **Anthropic's official cross-tool pattern:** create a CLAUDE.md that imports AGENTS.md (`@AGENTS.md`) plus Claude-specific additions. Avoids duplicate content. (source: [thepromptshelf](https://thepromptshelf.dev/blog/agents-md-vs-claude-md/), [Anthropic memory docs](https://docs.anthropic.com/en/docs/claude-code/memory))
- **Symlinks (`ln -s AGENTS.md CLAUDE.md`) work** when the content is genuinely identical. (source: [Cursor forum](https://forum.cursor.com/t/show-me-your-agents-md-rules-system/132323))
- **Cursor's `.cursor/rules/*.mdc` files** add glob-based auto-attachment and activation modes — finer control than AGENTS.md alone. (source: [Apidog](https://apidog.com/blog/awesome-cursor-rules/))

## Compaction and session commands

- **Compaction-survival instruction is now official.** Add to CLAUDE.md: "When compacting, always preserve the full list of modified files and any test commands." CLAUDE.md itself fully survives compaction since it's re-read from disk. (source: [the-ai-corner](https://www.the-ai-corner.com/p/claude-best-practices-power-user-guide-2026), [Anthropic memory docs](https://docs.anthropic.com/en/docs/claude-code/memory))
- **`/compact <instructions>`** runs a one-off guided compaction. (source: [the-ai-corner](https://www.the-ai-corner.com/p/claude-best-practices-power-user-guide-2026))
- **`/btw`** lets you ask a sidebar question that doesn't enter conversation history. (source: [the-ai-corner](https://www.the-ai-corner.com/p/claude-best-practices-power-user-guide-2026))
- **`Esc+Esc` (or `/rewind`)** does a partial compaction from a checkpoint. (source: [the-ai-corner](https://www.the-ai-corner.com/p/claude-best-practices-power-user-guide-2026))

## Patterns

- **Canary pattern.** Include a trivial instruction ("always call me Mr. Tinkleberry") as a compliance detector. When Claude stops following it, attention has drifted — time to `/clear`. (source: [HN comment](https://news.ycombinator.com/item?id=45983698))
- **Failure-driven iteration.** Don't pre-write rules. Wait for failure, add a targeted rule, revert the bad changes, re-run, verify the rule fixed it. Remove rules that address learned behaviors. (source: [HN comment](https://news.ycombinator.com/item?id=47034087), [satnammca/Medium](https://medium.com/@satnammca/claude-md-best-practices-building-a-smarter-ai-assisted-workflow-with-node-js-angular-c0a6a0c4cad7))
- **Compounding engineering (Boris Cherny).** Tag teammate PRs with `@.claude` to auto-feed code-review lessons back into CLAUDE.md. Operationalizes failure-driven iteration on real reviews instead of anticipated ones. (source: [becoming-for-better/Medium](https://medium.com/becoming-for-better/taming-claude-code-a-guide-to-claude-md-and-hooks-ed059879991c))
- **`backbone.yml` pattern.** A single source of truth for project topology referenced from CLAUDE.md: "Before running find/grep/ls/glob, read backbone.yml first." Prevents expensive exploratory commands. (source: [DEV Community / cleverhoods backbone.yml](https://dev.to/cleverhoods/claudemd-best-practices-the-backboneyml-pattern-30fi))
- **HTML comments for maintainer notes.** `<!-- ... -->` blocks are stripped before injection into Claude's context. Use them for human-readable notes about why a rule exists, without spending tokens. (source: [Anthropic memory docs](https://docs.anthropic.com/en/docs/claude-code/memory))
- **Document concepts, not file paths.** Paths change. "Auth logic lives in `src/auth/handlers.ts`" breaks on refactor. "Authentication uses session-based tokens with Redis-backed storage" describes a stable concept Claude can locate via search. (source: [AI Hero](https://www.aihero.dev/a-complete-guide-to-agents-md))

## Cost / rate limits

- **Spring 2026 made CLAUDE.md token cost a hard ceiling, not just a quality concern.** Anthropic tightened peak-hour limits, and Max-plan users started reporting 5-hour caps in ~20 minutes. (source: [DevOps.com](https://devops.com/claude-code-quota-limits-usage-problems/), [nicholasrhodes/Substack](https://nicholasrhodes.substack.com/p/claude-usage-limits-fix))
- **Opus 4.7 (April 16) shipped with a new tokenizer producing up to 35% more tokens for identical input.** Same CLAUDE.md costs more than it did a quarter ago. (source: [DevOps.com](https://devops.com/claude-code-quota-limits-usage-problems/), [MindStudio compute shortage](https://www.mindstudio.ai/blog/anthropic-compute-shortage-claude-limits))
- **May 6 2026: Anthropic doubled 5-hour limits via a SpaceX compute deal.** Squeeze isn't gone, just less acute. (source: [letsdatascience](https://letsdatascience.com/news/anthropic-increases-claude-code-and-api-usage-limits-735fd0ac))
- **Cache-expiry analyses suggest long-lived sessions burn through limits faster** when context gets evicted and re-loaded mid-conversation, compounding the cost of bloated always-loaded context. (source: [samarthgupta1911/Medium](https://medium.com/@samarthgupta1911/anthropic-isnt-the-only-reason-you-re-hitting-claude-code-limits-8de8d07d3c7b), [DeepWiki claude-agent-rs](<https://deepwiki.com/junyeong-ai/claude-agent-rs/4.2-memory-loading-(claude.md)>))
- **Engineering-leader framing of the squeeze:** every line of CLAUDE.md now has measurable dollar and minutes-of-session cost. Bloat shortens the working session before rate limits kick in. (source: [Faros AI](https://www.faros.ai/blog/claude-code-token-limits), [Sitepoint rate limits](https://www.sitepoint.com/claude-code-rate-limits-explained/))

## Walk-backs from earlier research

- **No verified hard cap on rules files per project.** The "20-file cap" claim circulated in late 2025 didn't survive verification. Only the 15k-char `SLASH_COMMAND_TOOL_CHAR_BUDGET` for skill descriptions and the soft 200-instruction degradation are real. (source: [rahuulmiishra/Medium](https://rahuulmiishra.medium.com/your-claude-md-is-doing-too-much-heres-how-to-fix-it-2cc495ed3599); the original cap claim came from [WebProNews](https://www.webpronews.com/anthropic-quietly-caps-claude-codes-rule-files-and-developers-are-furious/))
- **"Always be imperative" was an oversimplification.** The refinement (facts → declarative, behaviors → imperative) is necessary because system-command-styled facts can trip prompt-injection defenses. (source: [Anthropic hooks docs](https://code.claude.com/docs/en/hooks))
