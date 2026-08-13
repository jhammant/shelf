#!/usr/bin/env python3
"""Measure what each shelf command costs in context tokens as the shelf grows.

This is the benchmark behind the cost table in the README. It builds throwaway
shelves of 10 / 100 / 500 items whose notes match the length of real filled-in
ones (~2.5KB), then counts tokens on every command path.

    pip install tiktoken
    ./bench/token_cost.py

Not part of the tool — `shelf` itself is stdlib-only and has no dependencies.
"""
import os
import pathlib
import random
import shutil
import subprocess
import sys
import tempfile

try:
    import tiktoken
except ImportError:
    sys.exit("needs tiktoken:  pip install tiktoken")

SHELF = str(pathlib.Path(__file__).resolve().parent.parent / "shelf")
SIZES = (10, 100, 500)
ENC = tiktoken.get_encoding("o200k_base")

ORGS = ["awslabs", "vercel", "temporalio", "grafana", "hashicorp", "pola-rs", "duckdb",
        "encode", "pydantic", "astral-sh", "cloudflare", "supabase", "modal-labs",
        "dagster-io", "prefecthq", "ray-project", "bytewax", "questdb", "risingwavelabs",
        "openobserve"]
TOPICS = [("rate-limiting", "token bucket limiter"), ("workflow", "durable execution engine"),
          ("observability", "trace collector"), ("dataframes", "columnar query engine"),
          ("auth", "session and token issuer"), ("queues", "durable job queue"),
          ("caching", "in-process cache with TTL"), ("search", "embedded full-text index"),
          ("agents", "structured agent workflow"), ("testing", "property-based test runner"),
          ("deploy", "container build and ship tool"), ("secrets", "envelope-encrypted store"),
          ("streaming", "stateful stream processor"), ("cli", "terminal UI toolkit"),
          ("db", "embedded analytical database"), ("http", "async http framework"),
          ("validation", "schema and coercion layer"), ("scheduling", "cron with backfill"),
          ("metrics", "cardinality-bounded metrics"), ("logs", "structured log shipper")]
BLOCKERS = ["Needs Redis and we are deliberately single-node",
            "License flipped to BSL in the last release, so it is out for anything we ship",
            "Last push was 14 months ago with 200 open issues and no triage",
            "Pulls 60MB of transitive deps for a feature we would use 5% of",
            "Only supports Postgres 15+ and we are pinned to 13 until Q3",
            "Maintainer has publicly asked for someone to take it over"]
VERDICTS = ["untried", "trialling", "adopted", "rejected"]

# A note written the way the README tells you to write one.
BODY = """## What it is

{what}, about {size} of Go behind a single static binary. State lives in {store};
there is no control plane and no sidecar. Configuration is one TOML file, and the
whole surface is six subcommands plus an HTTP admin port you can turn off. The
scheduler is a plain work-stealing pool — no external broker, which is the reason
it stays a single binary at all. Throughput on a laptop was roughly 40k ops/sec
before the {store} write path became the ceiling, well past anything we would ask.

## When I'd reach for it

The {proj} project. It already needs {topic}, and the hand-rolled version in there
is ~400 lines nobody has touched in a year and nobody wants to own. This would
delete all of it, and the operational story matches what we already run: one
binary, one config file, logs to stdout.

## Why not now

{blocker}. That is the whole blocker — the tool is good and I would use it tomorrow
otherwise. Worth revisiting if that constraint moves, or if we end up running
{store} for another reason and the marginal cost drops to zero.

## If I trial it

Do not follow the upstream quickstart; it assumes docker-compose and a Postgres you
do not need for a single-node trial. Instead: `make build`, drop the binary in
`./bin`, and run with `--store=memory` first to check the API shape. Two defaults
are wrong for us — retention is 7 days (we want 90) and the admin port binds
0.0.0.0 (bind loopback). Both are one-liners in the TOML.

The migration path off it is worth writing down while it is fresh: state is a single
{store} table with an obvious schema, so exporting to CSV and replaying into whatever
replaces it is an afternoon rather than a project. That is most of why I am
comfortable trialling it — the exit is cheap and legible, and the failure mode if the
project goes unmaintained is that we keep running the last good binary rather than
scrambling to replace it.
"""


def build(root, n):
    """Create a shelf of n items and return its env."""
    env = dict(os.environ, SHELF_DIR=root)
    run = lambda *a: subprocess.run([SHELF, *a], env=env, check=True, capture_output=True)
    run("init")
    random.seed(7)
    for i in range(n):
        topic, what = TOPICS[i % len(TOPICS)]
        org = ORGS[i % len(ORGS)]
        name = f"{topic.replace('-', '')}{i:03d}"
        why = (f"{what} — {random.choice(['zero deps', 'tiny API', 'benchmarks well', 'good docs'])}"
               f", worth a look for {topic}")
        run("add", f"https://github.com/{org}/{name}", "-w", why, "-t", f"{topic},{org}", "--offline")
        run("verdict", name, random.choice(VERDICTS))
        note = pathlib.Path(root) / "items" / f"{name}.md"
        front, _, _ = note.read_text().partition("## What it is")
        note.write_text(front + BODY.format(
            what=what.capitalize(),
            size=random.choice(["3k lines", "8k lines", "22k lines"]),
            store=random.choice(["SQLite", "Redis", "Postgres", "the filesystem"]),
            proj=random.choice(["billing", "the homelab brain", "quotamax", "ingest"]),
            topic=topic, blocker=random.choice(BLOCKERS)))
    run("index")
    return env


def measure(root, env):
    out = lambda *a: subprocess.run([SHELF, *a], env=env, capture_output=True, text=True).stdout
    toks = lambda s: len(ENC.encode(s))
    notes = sorted((pathlib.Path(root) / "items").glob("*.md"))
    find, show = toks(out("find", "rate-limiting")), toks(out("show", notes[0].stem))
    return {
        "find <q>": find,
        "tags": toks(out("tags")),
        "show <slug>": show,
        "find + show": find + show,
        "list": toks(out("list")),
        "print": toks(out("print")),
        "every note": sum(toks(p.read_text()) for p in notes),
    }


def main():
    results = []
    for n in SIZES:
        root = tempfile.mkdtemp(prefix=f"shelfbench{n}-")
        try:
            print(f"building {n:>3} items…", file=sys.stderr)
            results.append(measure(root, build(root, n)))
        finally:
            shutil.rmtree(root, ignore_errors=True)

    # The shelf itself grew this much; a path that grew as fast is linear in
    # shelf size, one that plateaued well short of it is bounded.
    linear = SIZES[-1] / SIZES[0]
    print(f"\nshelf grew {linear:.0f}x ({SIZES[0]} → {SIZES[-1]} items)\n")
    print(f"{'path':<14}" + "".join(f"{'@' + str(n):>10}" for n in SIZES) +
          f"{'growth':>10}  {'vs linear':>10}")
    print("-" * 64)
    for key in results[0]:
        vals = [r[key] for r in results]
        growth = vals[-1] / vals[0]
        frac = growth / linear
        verdict = "bounded" if frac < 0.25 else "linear"
        print(f"{key:<14}" + "".join(f"{v:>10,}" for v in vals) +
              f"{growth:>9.1f}x  {frac:>6.0%} {verdict}")


if __name__ == "__main__":
    main()
