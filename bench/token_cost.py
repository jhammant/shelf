#!/usr/bin/env python3
"""Measure what each shelf command costs in context tokens as the shelf grows.

This is the benchmark behind the cost table in the README. It builds throwaway
shelves of 10 / 100 / 500 items whose notes match the length of real filled-in
ones (~2.5KB), then counts tokens on every command path.

The shelves are deliberately mixed — ~20% `reading` items, and a constraint set
that the generated verdicts cite — so the `find` row is measured on
constraint-bearing, two-vocabulary data rather than the easy case.

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
# Three of these six are now constraints rather than prose — which is the whole
# point of the feature. The blocker text stays for the notes that are not cited.
BLOCKERS = ["Needs Redis and we are deliberately single-node",
            "License flipped to BSL in the last release, so it is out for anything we ship",
            "Last push was 14 months ago with 200 open issues and no triage",
            "Pulls 60MB of transitive deps for a feature we would use 5% of",
            "Only supports Postgres 15+ and we are pinned to 13 until Q3",
            "Maintainer has publicly asked for someone to take it over"]
TOOL_VERDICTS = ["untried", "trialling", "adopted", "rejected"]
READING_VERDICTS = ["unread", "useful", "noise"]
CONSTRAINTS = [("single-node", "no Redis, no Kafka — one box and no cluster ops"),
               ("pg13", "pinned to Postgres 13 until Q3"),
               ("no-bsl", "BSL/SSPL is out for anything we ship"),
               ("arm64", "builds must run on Apple silicon and Graviton"),
               ("py38", "library code has to import on Python 3.8"),
               ("no-jvm", "nothing that needs a JVM on the build boxes"),
               ("one-binary", "operational story has to be one binary and one config file"),
               ("no-k8s", "we do not run Kubernetes and are not going to")]
READING_HOSTS = ["example.com/blog", "arxiv.org/abs", "martinfowler.com/articles"]

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

# The reading counterpart, written the way the README tells you to write one.
READING_BODY = """## What it argues

That {topic} is mostly an organisational problem wearing an engineering costume, and
that the {what} everyone reaches for is treating the symptom. The argument runs through
three case studies and one long postmortem, and the load-bearing claim is that the
coordination cost grows faster than the thing being coordinated.

## What I took from it

The framing that a {topic} system is a queue with opinions, which is a better mental
model than the one I had. Also the observation that {store} is almost always the real
bottleneck and everything upstream of it is theatre — that matches what we saw in the
{proj} project when the hand-rolled version finally fell over.

## What I'd push back on

The case studies are all at a scale we will never see, and the postmortem quietly
assumes a team of eight. At our size the coordination cost the author is worried about
is a Slack message. {blocker} — which the piece never engages with, because at its
scale that constraint does not exist.

## Where I'd apply it

The {proj} project, when we next argue about {topic}. Specifically the queue-with-
opinions framing, which would have saved us a week of design meetings, and the
measurement approach in the appendix, which is cheap enough to just do. Not the
architecture — that is for a team three times our size, and adopting it wholesale is
exactly the mistake the author warns about in the conclusion.
"""


def build(root, n):
    """Create a shelf of n items and return its env."""
    # SHELF_NO_LOG keeps the benchmark hermetic: no usage log, no compaction, and the
    # measured commands stay identical to a clean-room run.
    env = dict(os.environ, SHELF_DIR=root, SHELF_NO_LOG="1")
    run = lambda *a: subprocess.run([SHELF, *a], env=env, check=True, capture_output=True)
    run("init")
    random.seed(7)
    for cid, text in CONSTRAINTS:
        run("constraint", cid, text)
    for i in range(n):
        topic, what = TOPICS[i % len(TOPICS)]
        org = ORGS[i % len(ORGS)]
        reading = i % 5 == 0                      # ~20% of a real shelf is reading
        name = f"{topic.replace('-', '')}{i:03d}"
        why = (f"{what} — {random.choice(['zero deps', 'tiny API', 'benchmarks well', 'good docs'])}"
               f", worth a look for {topic}")
        url = (f"https://{READING_HOSTS[i % len(READING_HOSTS)]}/{name}" if reading
               else f"https://github.com/{org}/{name}")
        run("add", url, "-w", why, "-t", f"{topic},{org}", "-s", name, "--offline")
        verdict = random.choice(READING_VERDICTS if reading else TOOL_VERDICTS)
        # A negative verdict is the one that usually rests on a standing fact.
        because = ([random.choice(CONSTRAINTS)[0]] if verdict in ("rejected", "noise")
                   else [])
        run("verdict", name, verdict, *(["--because", ",".join(because)] if because else []))
        note = pathlib.Path(root) / "items" / f"{name}.md"
        heading = "## What it argues" if reading else "## What it is"
        front, _, _ = note.read_text().partition(heading)
        note.write_text(front + (READING_BODY if reading else BODY).format(
            what=what.capitalize(),
            size=random.choice(["3k lines", "8k lines", "22k lines"]),
            store=random.choice(["SQLite", "Redis", "Postgres", "the filesystem"]),
            proj=random.choice(["billing", "the homelab brain", "quotamax", "ingest"]),
            topic=topic, blocker=random.choice(BLOCKERS)))
    run("index")
    return env


def measure(root, env):
    out = lambda *a, **kw: subprocess.run(
        [SHELF, *a], env=kw.get("env", env), capture_output=True, text=True).stdout
    toks = lambda s: len(ENC.encode(s))
    notes = sorted((pathlib.Path(root) / "items").glob("*.md"))
    find, show = toks(out("find", "rate-limiting")), toks(out("show", notes[0].stem))
    cited = [l.split()[0] for l in out("constraints").splitlines() if "\u00d7" in l]

    # `stats` reports on a usage log, so it needs one. Generate it deliberately with a
    # second env — every other row above is measured with logging off, hermetically.
    logged = {k: v for k, v in env.items() if k != "SHELF_NO_LOG"}
    for note in notes[:20]:
        out("find", note.stem, env=logged)
        out("show", note.stem, env=logged)
    out("find", "kubernetes", env=logged)

    return {
        "constraints": toks(out("constraints")),
        "find <q>": find,
        "revisit <id>": toks(out("revisit", cited[0])) if cited else 0,
        "tags": toks(out("tags")),
        "show <slug>": show,
        "find + show": find + show,
        "list": toks(out("list")),
        "print": toks(out("print")),
        "stats": toks(out("stats", env=logged)),
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
