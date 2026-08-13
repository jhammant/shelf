# shelf

[![test](https://github.com/jhammant/shelf/actions/workflows/test.yml/badge.svg)](https://github.com/jhammant/shelf/actions/workflows/test.yml)

**A virtual shelf for remembering the things you might need — and the things you looked at
and decided not to use.**

Your coding agent keeps recommending tools you already evaluated and rejected.

You looked at that library six months ago and decided against it. You had good reasons.
Those reasons are gone — buried in a chat log, a closed tab, a starred repo you'll never
open again. So you research it from scratch, or worse, your agent does and reaches the
opposite conclusion.

`shelf` is a store for tools you might use on a *future* project, designed so an AI agent
can search it without eating your context window.

```bash
$ shelf find rate-limiting
bucketeer  [rejected]  https://github.com/someorg/bucketeer
    Token bucket limiter — dropped it, needs Redis and we're single-node
slowdown  [adopted]  https://github.com/someorg/slowdown
    In-process limiter, zero deps — shipped in the billing service
→ `shelf show <name>` for the full note
```

That's the whole idea. The verdict and the reasoning come back before you re-litigate the
decision.

## The context problem

A "just put it all in a markdown file" bookmark store breaks the moment an agent reads it.
At 100 items the full set of notes is ~53,000 tokens — a quarter of a context window spent
on 99 things you didn't ask about. At 500 it's 267,000, and there is no context window that
saves you.

So `shelf` splits its commands into a **bounded agent path** and **unbounded human views**,
and the agent instructions forbid the expensive ones:

| Command | @10 | @100 | @500 | Bounded? | For |
| --- | --- | --- | --- | --- | --- |
| `shelf find <q>` | 54 | 219 | **358** | **yes** — 8-hit cap | agents, always start here |
| `shelf tags` | 124 | 244 | 244 | yes — tag vocabulary | recovering from a missed search |
| `shelf show <slug>` | 532 | 532 | 532 | yes — one note | after `find`, for the hit that matters |
| `shelf list` | 243 | 2,450 | 12,219 | no, linear | humans, in a terminal |
| `shelf print` | 441 | 3,773 | 18,592 | no, linear | humans, in a terminal |
| reading every note | 5,303 | 53,343 | 266,663 | no, linear | never |

**`find` → `show` grows 1.5× between a 10-item shelf and a 500-item one — 586 to 890 tokens.
The shelf grew 50×, and so did reading everything.** The agent path has a ceiling; that's
the design, not a side effect. The cap is what buys it: past 8 matches `find` stops printing
and tells you to narrow the query.

Numbers are `o200k_base` tokens over a synthetic shelf whose notes match the length of real
filled-in ones (~2.5KB). Re-run it yourself with [`bench/token_cost.py`](bench/token_cost.py).

```mermaid
flowchart LR
    Q["agent needs a tool<br/>for some job"] --> F["shelf find<br/>≤360 tok, capped at 8"]
    F -->|hit| S["shelf show &lt;slug&gt;<br/>~530 tok, one note"]
    F -->|miss| T["shelf tags<br/>~250 tok"]
    T --> F
    S --> D{"verdict?"}
    D -->|adopted / rejected| R["answer from the note —<br/>no re-research"]
    D -->|untried| N["research, then<br/>shelf verdict &lt;slug&gt;"]
    N --> R

    L["shelf list / print<br/>grows without bound"] -.->|humans only,<br/>never in agent context| R

    style F fill:#d97757,color:#fff
    style S fill:#d97757,color:#fff
    style L stroke-dasharray: 4 4
```

## Install

One file, no dependencies, Python 3.8+:

```bash
curl -fsSL https://raw.githubusercontent.com/jhammant/shelf/main/shelf -o ~/.local/bin/shelf
chmod +x ~/.local/bin/shelf
shelf init
```

Or clone and symlink:

```bash
git clone https://github.com/jhammant/shelf.git
ln -s "$PWD/shelf/shelf" ~/.local/bin/shelf
shelf init
```

Data lives in `~/.shelf` by default — set `SHELF_DIR` to put it somewhere else (a dotfiles
repo, a synced folder, alongside your projects).

## Use

```bash
# shelve something, with the reason you cared
shelf add https://github.com/awslabs/aidlc-workflows \
  -w "structured agent workflow — governance + artifact trail" \
  -t agents,process -c          # -c also shallow-clones it

shelf edit aidlc-workflows      # fill in the note (see below)
shelf verdict aidlc-workflows rejected

shelf find agents               # ranked, capped
shelf tags                      # tag vocabulary + counts
shelf print                     # browsable, grouped by verdict
```

GitHub URLs are enriched automatically with stars, license and last-push date, so staleness
is visible later. `--offline` skips the lookup.

## Write the note, not just the link

A bare bookmark is worthless in six months. `shelf add` scaffolds four headings, and the
third is the one that earns its keep:

```markdown
## What it is
Mechanics, size, what actually runs it. Concrete, not marketing copy.

## When I'd reach for it
Name the specific project it would fit.

## Why not now
The honest blocker. This is what stops you re-litigating the decision next year.

## If I trial it
The exact setup — especially where it differs from the project's own README.
```

Verdicts move `untried → trialling → adopted / rejected`. **A `rejected` with reasoning is
the most valuable entry in the shelf**, and the one a starred-repos list can never give you.

## Wiring it to your agent

`skills/claude-code/` is a [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills)
that teaches the agent the retrieval path and the context budget — including the rule to
check the shelf *before* recommending anything new:

```bash
ln -s "$PWD/skills/claude-code" ~/.claude/skills/shelf
```

For Codex, Cursor, Copilot and friends, `AGENTS.md` carries the same rules in a portable
form — append it to your own.

The payoff isn't the storage. It's that "should I use X?" gets answered with *your own prior
verdict* instead of a fresh opinion.

## Design notes

- **Plain markdown, one file per item.** Greppable, diffable, git-friendly, readable without
  this tool. If `shelf` disappears your notes are still notes.
- **Ranked search**: name ×10 > tag ×6 > why ×4 > body ×1, so precision holds as the shelf
  grows instead of matching everything that says "python".
- **Clones are gitignored**, so `rg` skips them by default and a vendored 16MB repo can't
  pollute a search across your projects.
- **Colour only on a TTY** — piped or captured output spends no tokens on ANSI codes.
- **Stdlib only.** Network calls are best-effort; the shelf works offline.

## Tests

```bash
./tests/test_shelf.sh
```

36 end-to-end assertions against a throwaway `SHELF_DIR`, hermetic (no network). CI runs
them on Linux and macOS.

The cost table above is reproducible — it builds real shelves at three sizes and counts
tokens on every command path:

```bash
pip install tiktoken
./bench/token_cost.py
```

## Licence

MIT — see [LICENSE](LICENSE).
