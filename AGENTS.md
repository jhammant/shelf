# Shelf — agent instructions

Portable version of the Claude Code skill in `skills/claude-code/`. Append the relevant
part to your own `AGENTS.md`, `.cursorrules`, or `copilot-instructions.md`.

---

## shelf

The user keeps evaluated tools in `shelf` (`$SHELF_DIR`, default `~/.shelf`) — notes in
`items/*.md`, verdicts of `untried` / `trialling` / `adopted` / `rejected`.

**Before recommending any tool, library, or framework, run `shelf find <topic>` first.**
If it is already shelved, lead with the recorded verdict and reasoning rather than
researching from scratch. A `rejected` verdict is a finding: say what the blocker was and
whether it still holds.

Retrieval is two steps and bounded, because this output lands in your context window:

| Command | Cost @100 items | Scales? | Use |
| --- | --- | --- | --- |
| `shelf find <q>` | ~220 tok | no, capped at 8 | always start here |
| `shelf tags` | ~240 tok | no | when a search misses |
| `shelf show <slug>` | ~530 tok | no | after find, 1–2 max |
| `shelf list` / `print` | 2.5–4k tok | **yes, linear** | human terminal only — not you |
| every note | ~53,000 tok | — | never |

Rules:

1. Always `shelf find` first; never `list`/`print` to answer a question.
2. Never read the shelf's generated `README.md` — it duplicates `find` at many times the cost.
3. `shelf show` at most two notes, only ones `find` ranked highly.
4. Never search or read `repos/` — vendored clones of other people's code, gitignored so
   ripgrep skips them. Don't defeat that with `--no-ignore`.
5. If `find` misses, run `shelf tags` and retry with a real tag.

When shelving something with `shelf add <url> -w "why" -t tags`, always fill in the note
body afterwards: **What it is** (mechanics, concrete), **When I'd reach for it** (name the
project), **Why not now** (the honest blocker — the most valuable section), **If I trial
it** (exact setup, especially where it differs from upstream's README).
