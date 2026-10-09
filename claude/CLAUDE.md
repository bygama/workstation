# Global instructions

<!-- Canonical: workstation/claude/CLAUDE.md — applied to ~/.claude/CLAUDE.md by claude/install.ps1. -->

## Language

- Reply in each prompt's language: Spanish → rioplatense Spanish, English → English. Communication
  only — never the artifact rules.
- All technical artifacts in English: code, comments, docs, commits, branches, PR titles/bodies,
  context files.
- User-facing product content (site copy, UI text, SEO metadata) in Spanish, unless the project's
  context says otherwise.

## Safety

- Never expose or commit credentials, tokens, private keys, or populated `.env` files.
- Resolve exact targets before destructive filesystem or git operations.
- Never claim success without running the relevant verification.

## Working style

- A repo's `CONTRIBUTING.md` binds and outranks this file: run every gate it names before a PR,
  show their output, and name any that cannot run.
- Make the smallest coherent change — smallest in scope, not provisional: no speculative generality,
  no stopgaps meant to be replaced later.
- Prefer evidence (code, command output, primary docs) over assumptions.
- Preserve unrelated changes in a dirty worktree.
- Project specifics live in each repo's CLAUDE.md; procedural workflows in skills; session-learned
  facts in auto-memory — never in this file.

## Orca agent spawns

- A spawn inherits THIS session's account: `--command "pegasuz"` when `CLAUDE_CONFIG_DIR` points at
  `.claude-pegasuz`, else `--command "claude"`; children detect their own env and repeat the rule.
- Never start bare `claude.exe` from an Orca terminal — it resolves to the machine's ambient default
  (pegasuz), not to this session's account.
- Never run a long-lived process as a background shell in an agent session — blocks working→idle,
  dies with it. Dev servers: own Orca terminal tab (`orca terminal create --command "npm run dev"`);
  browsers: Orca's embedded one — other MCPs only for lacked capabilities, not a child.
- Subagent seats run on the model their task needs, per AE `reference/runners.md`: Haiku 5.5
  (`claude-haiku-5-5`) for bounded seats — rechecks of named findings, extraction, searches, web
  lookups, an extra lens; Sonnet for review lenses and S/M work; Opus for design, synthesis and
  high-risk review; Fable only when the owner says so in words. Always pass `model`.
- A subagent (Agent tool) does not end when it reports: it stays listed as an idle agent under this
  terminal until stopped. Stop every reviewer/helper seat with TaskStop as soon as its result is
  recorded; keep one alive only while a follow-up message to it is coming. Check with ListAgents
  before ending a turn — zero teammates is the resting state.
