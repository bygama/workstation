# Skills

User skills come from the repos listed in `$skillSources` in `claude/install.ps1` —
`repos\pegasuz\agent-engineering\skills\` (the standard's tooling, cloned by the Pegasuz
workspace's bootstrap) and
`repos\mine\skills\skills\` (the personal library) — junction-linked into
`~/.claude/skills/`. This repo carries no skill content and no skill list — the link step
is declarative over whatever those repos contain, one junction per skill name with the
later source winning on collisions.

| Location | Policy |
| --- | --- |
| `~/.claude/skills/` | Junctions into the source repos; load normally (auto-trigger by description) |
| Installed Claude plugin skills | Unchanged |

No `skillOverrides` are generated anymore. The previous `user-invocable-only` policy
existed to keep ~37 OMC skills out of the automatic listing; the current skills are few and
written for automatic triggering, so hiding them would defeat their design.

Use `/context` in Claude Code to inspect the actual context cost when the skill set grows.
