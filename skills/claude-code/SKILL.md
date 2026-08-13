---
name: shelf
description: Park or retrieve a tool, repo, library, or article that might be useful on a future project. Use when the user says "shelve this", "save this for later", "might be useful someday", "did I look at something for X", or "what did I stash about Y". ALSO check the shelf unprompted before recommending any new tool or library — they may have already evaluated it and recorded a verdict.
---

# Shelf

`shelf` stores tools and reading the user might want on a future project, with the reasoning
attached. Data lives in `$SHELF_DIR` (default `~/.shelf`): notes in `items/*.md`, standing
facts in `constraints.md`, optional shallow clones in `repos/` (gitignored), generated index
in `README.md`.

## Context discipline — read before running anything

Shelf output lands in a context window, so retrieval is **two steps and bounded**, never a
dump. Measured at 100 items:

| Command | Cost | Scales with shelf size? | Use |
| --- | --- | --- | --- |
| `shelf constraints` | ~150 tok | **no** — O(1) | once per session, then keep it |
| `shelf find <q>` | ~210 tok | **no** — capped at 8 hits | entry point, always |
| `shelf revisit <id>` | ~270 tok | **no** — capped at 8 hits | when a constraint changes |
| `shelf tags` | ~250 tok | no | when a search misses |
| `shelf show <slug>` | ~535 tok | no | after find, 1–2 notes max |
| `shelf list` | ~2,400 tok | **yes, linear** | human terminal only |
| `shelf print` | ~3,800 tok | **yes, linear** | human terminal only |
| `shelf stats` | ~275 tok, `--dead` +~18 tok per dead item | **yes** (`--dead`, `--json`) | human terminal only |
| every note | ~51,000 tok | — | never |

Hard rules:

1. **Always `shelf find` first.** Never `shelf list` or `shelf print` to answer a question —
   those are for a human in a terminal and grow without bound.
2. **Run `shelf constraints` once, at session start, and keep it in context.** Never re-run
   it per query: five runs turn a 150-token asset into a 750-token leak.
3. **Never `Read` `constraints.md` or the shelf's `README.md`.** The file's header prose
   costs ~90 tokens the command never prints; the README is a generated human index that
   duplicates `find` at many times the cost.
4. **Never run `shelf stats`, and never read `log.jsonl`.** Not because the report is big —
   it is capped — but because `--dead`/`--json` are linear, the computation reads every item
   plus the whole usage log, and the user's query history is not decision-support for you.
   Leave `SHELF_NO_LOG` unset as well: `find` and `show` each append one line, and it is the
   piped-vs-terminal split in that log that shows the user the shelf is earning its keep.
5. **`shelf show` at most two notes**, and only ones `find` ranked highly.
6. **Never search or read `repos/`.** Those are vendored shallow clones of other people's
   codebases. They are gitignored so ripgrep skips them — don't defeat that with
   `--no-ignore`. If a specific vendored file is needed, open it by exact path.
7. If `find` misses, run `shelf tags` and retry with a real tag before concluding nothing
   is shelved.

## Before recommending any tool

Run `shelf find <topic>` first. If it is already shelved, lead with the recorded verdict
and reasoning rather than researching from scratch. A `rejected` verdict is a finding, not
a dead end — say what the blocker was and whether it still holds. Update the note if the
assessment has changed.

## Kinds and verdicts

| Kind | Verdicts | Means |
| --- | --- | --- |
| `tool` | `untried` → `trialling` → `adopted` / `rejected` | a library, service or binary |
| `reading` | `unread` → `useful` / `noise` | article, paper or talk — consumed for ideas |

The vocabularies share no word, so `[useful]` in `find` output already tells you the item is
reading material and the user got something from it; `[noise]` means "read it, nothing in
it". Set with `shelf verdict <slug> <verdict>` — a cross-kind word is refused. Two kinds is
a deliberate ceiling: a conference talk is `reading`, not a third kind. Always record *why*
in the note when the verdict changes.

## Constraints — the standing facts

`constraints.md` holds short facts about the user's setup that decide things for them
("single-node, no Redis", "pinned to Postgres 13 until Q3"). A `why` line prefixed with an
id (`single-node · Token bucket limiter…`) means that decision rested on that fact — resolve
it against the set you already loaded, don't re-read anything.

```bash
shelf constraints                                    # once per session, ~150 tok
shelf verdict bucketeer rejected --because single-node
shelf revisit single-node                            # every decision resting on it, capped at 8
```

When the user says something that contradicts a live constraint ("we run Redis now"), offer
`shelf constraint <id> --lift` — it marks the fact untrue and lists every decision to redo.
When they state a *new* durable fact ("we're never running Kubernetes"), offer
`shelf constraint no-k8s "we do not run Kubernetes"`; ids are lowercase, ≤24 chars,
`[a-z0-9._-]`. Keep the set small — it is loaded every session, and past 12 live constraints
the command warns on stderr. Constraints are for standing facts, not for notes; anything
that needs a paragraph is an item.

## Shelving something

```bash
shelf add <url> [-k tool|reading] -w "why it caught my eye" -t "tag,tag" [-c]
```

The kind is inferred from the URL and echoed back; override it with `-k`. Then **fill in the
note body** — a bare link is worthless in six months:

- **tool** — *What it is* (mechanics, size, what actually runs it; concrete, not marketing) ·
  *When I'd reach for it* (name the specific project) · *Why not now* (the honest blocker;
  most valuable section) · *If I trial it* (exact setup, especially where it differs from the
  project's own README).
- **reading** — *What it argues* · *What I took from it* · *What I'd push back on* (the
  load-bearing one: a summary with no disagreement in it is indistinguishable from the
  article's own abstract) · *Where I'd apply it* (name the project, or it's just a bookmark).

Date-stamp the assessment and keep the recorded version/stars so staleness is visible.
Changing kind after you have written the body will not re-template it — that is deliberate.

## Commands

```bash
shelf find <query> [-n N] [-k tool|reading]  # ranked: name×10 > tag×6 > why×4 > body×1, capped at 8
shelf constraints                            # the standing facts — load once per session
shelf revisit <id>                           # decisions resting on a constraint, capped at 8
shelf tags                                   # tag vocabulary + counts
shelf show <slug>                            # one full note
shelf add / edit / verdict / kind / constraint / clone / index / path
shelf list / print / stats                   # HUMAN ONLY — unbounded, never in agent context
```

Editing an `items/*.md` file or `constraints.md` by hand is fine — run `shelf index` after.
