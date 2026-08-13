# Shelf — agent instructions

Portable version of the Claude Code skill in `skills/claude-code/`. Append the relevant
part to your own `AGENTS.md`, `.cursorrules`, or `copilot-instructions.md`.

---

## shelf

The user keeps evaluated tools and reading in `shelf` (`$SHELF_DIR`, default `~/.shelf`) —
notes in `items/*.md`, standing facts in `constraints.md`.

| Kind | Verdicts | Means |
| --- | --- | --- |
| `tool` | `untried` → `trialling` → `adopted` / `rejected` | a library, service or binary |
| `reading` | `unread` → `useful` / `noise` | an article, paper or talk — consumed for ideas |

The two sets share no word, so the verdict in `find` output tells you the kind for free.
`noise` means "read it, nothing in it".

**Before recommending any tool, library, or framework, run `shelf find <topic>` first.**
If it is already shelved, lead with the recorded verdict and reasoning rather than
researching from scratch. A `rejected` verdict is a finding: say what the blocker was and
whether it still holds.

Retrieval is two steps and bounded, because this output lands in your context window:

| Command | Cost @100 items | Scales? | Use |
| --- | --- | --- | --- |
| `shelf constraints` | ~150 tok | no, O(1) | **once per session**, then keep it |
| `shelf find <q>` | ~210 tok | no, capped at 8 | always start here |
| `shelf revisit <id>` | ~270 tok | no, capped at 8 | when a constraint changes |
| `shelf tags` | ~250 tok | no | when a search misses |
| `shelf show <slug>` | ~535 tok | no | after find, 1–2 max |
| `shelf list` / `print` / `stats` | 0.3–4k tok | **yes, linear** | human terminal only — not you |
| every note | ~51,000 tok | — | never |

Rules:

1. Always `shelf find` first; never `list`/`print` to answer a question.
2. Run `shelf constraints` **once at session start** and keep it in context. Never re-run it
   per query — five runs turn a 150-token asset into a 750-token leak.
3. Never read `constraints.md` or the shelf's generated `README.md` directly. `constraints.md`
   carries ~90 tokens of header prose that `shelf constraints` never prints; the README is a
   generated human index that duplicates `find` at many times the cost.
4. Never run `shelf stats` and never read `log.jsonl`. The report is small but `--dead` and
   `--json` are linear, the computation reads every item plus the whole usage log, and the
   user's query history is not your business. Leave `SHELF_NO_LOG` unset too: `find` and
   `show` log one line each, and your piped calls are how the user sees the shelf working.
5. `shelf show` at most two notes, only ones `find` ranked highly.
6. Never search or read `repos/` — vendored clones of other people's code, gitignored so
   ripgrep skips them. Don't defeat that with `--no-ignore`.
7. If `find` misses, run `shelf tags` and retry with a real tag.
8. When the user says something that contradicts a live constraint ("we run Redis now"),
   offer `shelf constraint <id> --lift` — it finds every decision that rested on it. When
   they state a new durable fact, offer `shelf constraint no-k8s "we do not run Kubernetes"`
   (ids lowercase, ≤24 chars, `[a-z0-9._-]`). Keep the set under ~12 — it is loaded every
   session.

A `why` line prefixed with a constraint id (`single-node · Token bucket limiter…`) means the
decision rested on that standing fact. Resolve the id against the constraint set you already
loaded; do not re-read anything.

When shelving with `shelf add <url> [-k tool|reading] -w "why" -t tags`, the kind is inferred
from the URL — override it with `-k`, or correct it later with `shelf kind <slug> reading`.
Always fill in the note body afterwards:

- **tool**: What it is (mechanics, concrete) · When I'd reach for it (name the project) ·
  Why not now (the honest blocker — the most valuable section) · If I trial it (exact setup).
- **reading**: What it argues · What I took from it · What I'd push back on (the load-bearing
  one — a summary with no disagreement is just the abstract) · Where I'd apply it.

Link a decision to the fact that caused it with
`shelf verdict <slug> rejected --because single-node`.
