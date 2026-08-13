---
name: shelf
description: Park or retrieve a tool, repo, library, or article that might be useful on a future project. Use when the user says "shelve this", "save this for later", "might be useful someday", "did I look at something for X", or "what did I stash about Y". ALSO check the shelf unprompted before recommending any new tool or library — they may have already evaluated it and recorded a verdict.
---

# Shelf

`shelf` stores tools the user might want on a future project, with the reasoning attached.
Data lives in `$SHELF_DIR` (default `~/.shelf`): notes in `items/*.md`, optional shallow
clones in `repos/` (gitignored), generated index in `README.md`.

## Context discipline — read before running anything

Shelf output lands in a context window, so retrieval is **two steps and bounded**, never a
dump. Measured at 100 items:

| Command | Cost | Scales with shelf size? | Use |
| --- | --- | --- | --- |
| `shelf find <q>` | ~220 tok | **no** — capped at 8 hits | entry point, always |
| `shelf tags` | ~240 tok | no | when a search misses |
| `shelf show <slug>` | ~530 tok | no | after find, 1–2 notes max |
| `shelf list` | ~2,500 tok | **yes, linear** | human terminal only |
| `shelf print` | ~3,800 tok | **yes, linear** | human terminal only |
| every note | ~53,000 tok | — | never |

Hard rules:

1. **Always `shelf find` first.** Never `shelf list` or `shelf print` to answer a question —
   those are for a human in a terminal and grow without bound.
2. **Never `Read` the shelf's `README.md`.** It is a generated human index that duplicates
   `find` output at many times the cost.
3. **`shelf show` at most two notes**, and only ones `find` ranked highly.
4. **Never search or read `repos/`.** Those are vendored shallow clones of other people's
   codebases. They are gitignored so ripgrep skips them — don't defeat that with
   `--no-ignore`. If a specific vendored file is needed, open it by exact path.
5. If `find` misses, run `shelf tags` and retry with a real tag before concluding nothing
   is shelved.

## Before recommending any tool

Run `shelf find <topic>` first. If it is already shelved, lead with the recorded verdict
and reasoning rather than researching from scratch. A `rejected` verdict is a finding, not
a dead end — say what the blocker was and whether it still holds. Update the note if the
assessment has changed.

## Shelving something

```bash
shelf add <url> -w "why it caught my eye" -t "tag,tag" [-c]   # -c also shallow-clones
```

Then **fill in the note body** — a bare link is worthless in six months:

- **What it is** — mechanics, size, what actually runs it. Concrete, not marketing.
- **When I'd reach for it** — name the specific project it would fit.
- **Why not now** — the honest blocker. Most valuable section; it prevents re-litigating.
- **If I trial it** — exact setup, especially where it differs from the project's own
  README (upstream defaults often clash with the user's existing config and conventions).

Date-stamp the assessment and keep the recorded version/stars so staleness is visible.

## Verdicts

`untried` → `trialling` → `adopted` / `rejected`, set with `shelf verdict <slug> <verdict>`.
Always record *why* in the note when the verdict changes.

## Commands

```bash
shelf find <query> [-n N]  # ranked: name×10 > tag×6 > why×4 > body×1, capped at 8
shelf tags                 # tag vocabulary + counts
shelf show <slug>          # one full note
shelf add / edit / verdict / clone / list / print / index / path
```

Editing an `items/*.md` file by hand is fine — run `shelf index` afterwards.
