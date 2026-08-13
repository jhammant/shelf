#!/usr/bin/env bash
# End-to-end tests. Runs against a throwaway SHELF_DIR — never touches a real shelf.
# Network-dependent behaviour is exercised with --offline so the suite is hermetic.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SHELF_BIN="$REPO/shelf"
export SHELF_DIR
SHELF_DIR="$(mktemp -d)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SHELF_DIR" "$SCRATCH"' EXIT

pass=0; fail=0
# Substring tests use bash pattern matching, not `printf | grep -qF`. With a large
# haystack (a whole README) grep -q exits on the first match while printf is still
# writing, printf takes SIGPIPE, and `set -o pipefail` then fails the pipeline even
# though the substring WAS found — a race that only shows up on big inputs. Quoting
# "$2" inside the pattern keeps it literal, so glob metacharacters are safe.
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

check() { # check <name> <expected-substring> <actual>
  if contains "$2" "$3"; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want substring: %s\n       got: %s\n' "$1" "$2" "$3"
  fi
}
check_not() {
  if contains "$2" "$3"; then
    fail=$((fail + 1)); printf '  FAIL %s\n       unwanted substring present: %s\n' "$1" "$2"
  else
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  fi
}
check_same() { # check_same <name> <expected> <actual> — exact string equality
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"
  fi
}
shelves=0
fresh() { # fresh <label> — point SHELF_DIR at a brand new initialised shelf
  shelves=$((shelves + 1))
  SHELF_DIR="$SCRATCH/$shelves-$1"
  mkdir -p "$SHELF_DIR"
  "$SHELF_BIN" init >/dev/null
}

echo "shelf tests  (SHELF_DIR=$SHELF_DIR)"

# --- guards before init
check "errors before init" "run \`shelf init\`" "$("$SHELF_BIN" list 2>&1)"

# --- init
check "init creates the shelf" "shelf ready" "$("$SHELF_BIN" init)"
[ -d "$SHELF_DIR/items" ] && check "items/ exists" "items" "items" || check "items/ exists" "items" "missing"
check "repos/ is gitignored" "repos/" "$(cat "$SHELF_DIR/.gitignore")"

# --- add
out=$("$SHELF_BIN" add https://github.com/someorg/widget -w "does widgets for pipelines" -t "cli,python" --offline)
check "add reports the path" "shelved →" "$out"
check "slug derived from url" "widget.md" "$out"
check "frontmatter has url" "url: https://github.com/someorg/widget" "$(cat "$SHELF_DIR/items/widget.md")"
check "defaults to untried" "verdict: untried" "$(cat "$SHELF_DIR/items/widget.md")"
check "duplicate add refuses" "already shelved" "$("$SHELF_BIN" add https://github.com/someorg/widget --offline 2>&1)"

"$SHELF_BIN" add https://example.com/blog/some-post -w "good writeup on caching" -t docs -s caching-post --offline >/dev/null
check "explicit slug honoured" "caching-post" "$("$SHELF_BIN" list)"

# --- unicode + quoting survive the round trip
"$SHELF_BIN" add https://github.com/someorg/uni -w 'em — dash, "quotes" and | pipe' -t misc --offline >/dev/null
check "unicode survives" "em — dash" "$("$SHELF_BIN" find uni)"
check "pipe escaped in index" '\|' "$(cat "$SHELF_DIR/README.md")"

# --- find
check "find matches on why" "widget" "$("$SHELF_BIN" find widgets)"
check "find matches on tag" "widget" "$("$SHELF_BIN" find python)"
check "find miss is graceful" "nothing shelved matches" "$("$SHELF_BIN" find kubernetes)"
check "find miss suggests tags" "shelf tags" "$("$SHELF_BIN" find kubernetes)"

# --- find is capped: the whole point of the tool
for n in $(seq 1 20); do
  "$SHELF_BIN" add "https://github.com/bulk/tool-$n" -w "bulk caching item" -t bulk --offline >/dev/null
done
hits=$("$SHELF_BIN" find caching | grep -c "^bulk\|^tool-" || true)
check "find caps at 8 hits" "8" "$(printf '%s' "$("$SHELF_BIN" find bulk | grep -c 'https://github.com/bulk')")"
check "find reports the overflow" "more — narrow the query" "$("$SHELF_BIN" find bulk)"
check "-n raises the cap" "20" "$(printf '%s' "$("$SHELF_BIN" find bulk -n 50 | grep -c 'https://github.com/bulk')")"

# --- ranking: name beats body
"$SHELF_BIN" add https://github.com/someorg/ranking -w "unrelated" -t misc --offline >/dev/null
first=$("$SHELF_BIN" find ranking | head -1)
check "name match ranks first" "ranking" "$first"

# --- verdicts
check "verdict set" "adopted" "$("$SHELF_BIN" verdict widget adopted)"
check "verdict persisted" "verdict: adopted" "$(cat "$SHELF_DIR/items/widget.md")"
check "verdict shown in find" "[adopted]" "$("$SHELF_BIN" find widgets)"
check "bad verdict rejected" "invalid choice" "$("$SHELF_BIN" verdict widget banana 2>&1)"

# --- views
check "tags counts items" "items" "$("$SHELF_BIN" tags)"
check "tags lists a tag" "python" "$("$SHELF_BIN" tags)"
check "list filters by tag" "caching-post" "$("$SHELF_BIN" list docs)"
check_not "list tag filter excludes others" "widget" "$("$SHELF_BIN" list docs)"
check "print groups by verdict" "ADOPTED" "$("$SHELF_BIN" print)"
check_not "no ANSI when piped" $'\033[' "$("$SHELF_BIN" print)"

# --- index
check "index regenerates" "README.md regenerated" "$("$SHELF_BIN" index)"
check "index links notes" "items/widget.md" "$(cat "$SHELF_DIR/README.md")"

# --- show / errors
check "show prints the note" "## What it is" "$("$SHELF_BIN" show widget)"
check "show on missing item" "no such item" "$("$SHELF_BIN" show nope 2>&1)"
check "clone rejects non-git url" "not a git url" "$("$SHELF_BIN" clone caching-post 2>&1)"
check "path prints shelf dir" "$SHELF_DIR" "$("$SHELF_BIN" path)"

# ==================================================================== kind: tool | reading

fresh kinds

# --- the invariant every zero-cost claim rests on
check "verdict vocabularies are disjoint" "disjoint" "$(python3 - "$SHELF_BIN" <<'PY'
import runpy, sys
g = runpy.run_path(sys.argv[1])
print("disjoint" if not set(g["TOOL_VERDICTS"]) & set(g["READING_VERDICTS"]) else "OVERLAP")
PY
)"
check "log verdict codes are bijective" "bijective" "$(python3 - "$SHELF_BIN" <<'PY'
import runpy, sys
g = runpy.run_path(sys.argv[1])
code, verdicts = g["VERDICT_CODE"], g["VERDICTS"]
ok = set(code) == set(verdicts) and len(set(code.values())) == len(verdicts)
print("bijective" if ok else "COLLISION")
PY
)"

# --- inference, one assertion per url
while IFS='|' read -r url want got; do
  check "infer $url → $want" "$want" "$got"
done < <(python3 - "$SHELF_BIN" <<'PY'
import runpy, sys
g = runpy.run_path(sys.argv[1])
rows = [("https://github.com/someorg/widget", "tool"),
        ("https://github.com/simonw/blog-engine", "tool"),
        ("https://github.com/foo/awesome-rust", "tool"),
        ("https://pypi.org/project/httpx", "tool"),
        ("https://example.com/blog/post", "reading"),
        ("https://arxiv.org/abs/1706.03762", "reading"),
        ("https://blog.cloudflare.com/x", "reading"),
        ("https://martinfowler.com/articles/x.html", "reading"),
        ("https://foo.com/papers/raft.pdf", "reading"),
        ("https://en.wikipedia.org/wiki/Raft", "reading"),
        ("https://youtu.be/abc", "reading"),
        ("https://docs.temporal.io/workflows", "tool"),
        ("https://danluu.com/", "tool"),
        ("https://totally-unknown-host.example/x", "tool")]
for url, want in rows:
    print("%s|%s|%s" % (url, want, g["infer_kind"](url)))
PY
)

# --- add materialises the kind it chose
out=$("$SHELF_BIN" add https://github.com/someorg/widget -w "does widgets" -t cli --offline)
check "github add is a tool" "(tool)" "$out"
check "tool kind materialised" "kind: tool" "$(cat "$SHELF_DIR/items/widget.md")"
check "tool defaults to untried" "verdict: untried" "$(cat "$SHELF_DIR/items/widget.md")"
check "tool scaffold" "## What it is" "$(cat "$SHELF_DIR/items/widget.md")"

out=$("$SHELF_BIN" add https://example.com/blog/local-first -w "the Ink & Switch essay" -t arch --offline)
check "add echoes the inferred kind" "(reading)" "$out"
check "reading kind materialised" "kind: reading" "$(cat "$SHELF_DIR/items/local-first.md")"
check "reading defaults to unread" "verdict: unread" "$(cat "$SHELF_DIR/items/local-first.md")"
check "reading scaffold argues" "## What it argues" "$(cat "$SHELF_DIR/items/local-first.md")"
check "reading scaffold pushes back" "## What I'd push back on" "$(cat "$SHELF_DIR/items/local-first.md")"
check_not "reading scaffold has no trial section" "## If I trial it" "$(cat "$SHELF_DIR/items/local-first.md")"

"$SHELF_BIN" add https://example.com/blog/override -k tool -s ovr-tool --offline >/dev/null
check "-k tool overrides inference" "kind: tool" "$(cat "$SHELF_DIR/items/ovr-tool.md")"
check "-k tool picks the tool scaffold" "## What it is" "$(cat "$SHELF_DIR/items/ovr-tool.md")"
"$SHELF_BIN" add https://github.com/karpathy/nn-zero-to-hero -k reading --offline >/dev/null
check "-k reading overrides inference" "kind: reading" "$(cat "$SHELF_DIR/items/nn-zero-to-hero.md")"

# --- verdicts are validated against the item's own kind
check "reading verdict accepted" "local-first → useful" "$("$SHELF_BIN" verdict local-first useful)"
check "reading verdict persisted" "verdict: useful" "$(cat "$SHELF_DIR/items/local-first.md")"
check "reading noise accepted" "→ noise" "$("$SHELF_BIN" verdict nn-zero-to-hero noise)"
before=$(cat "$SHELF_DIR/items/local-first.md")
check "tool verdict on reading refused" "is a tool verdict" "$("$SHELF_BIN" verdict local-first adopted 2>&1)"
check "refusal names the legal set" "unread · useful · noise" "$("$SHELF_BIN" verdict local-first adopted 2>&1)"
check_same "refused verdict leaves the file alone" "$before" "$(cat "$SHELF_DIR/items/local-first.md")"
check "reading verdict on tool refused" "is a reading verdict" "$("$SHELF_BIN" verdict widget useful 2>&1)"
check "unknown verdict still invalid choice" "invalid choice" "$("$SHELF_BIN" verdict widget banana 2>&1)"

# --- find carries the kind for free, and says nothing about it
"$SHELF_BIN" verdict widget adopted >/dev/null
hit=$("$SHELF_BIN" find local-first | head -1)
check_same "find schema unchanged for reading" \
  "local-first  [useful]  https://example.com/blog/local-first" "$hit"
out=$("$SHELF_BIN" find local-first)
check_not "find never prints the word kind" "kind" "$out"
check_not "find never prints the word reading" "reading" "$out"
check_not "find never prints the word tool" "tool" "$out"

# --- -k narrows before the cap
check "find -k reading keeps reading" "local-first" "$("$SHELF_BIN" find local-first -k reading)"
check "find -k tool drops reading" "nothing shelved matches" "$("$SHELF_BIN" find local-first -k tool)"

fresh readingcap
for n in $(seq 1 20); do
  "$SHELF_BIN" add "https://example.com/blog/essay-$n" -w "bulk reading item" -t bulk --offline >/dev/null
done
check "find caps at 8 with reading items" "8" \
  "$(printf '%s' "$("$SHELF_BIN" find essay | grep -c 'https://example.com/blog')")"
check "reading overflow line" "more — narrow the query" "$("$SHELF_BIN" find essay)"
"$SHELF_BIN" add https://github.com/bulk/essay-tool -w "bulk reading item" -t bulk --offline >/dev/null
both=$("$SHELF_BIN" find bulk -n 50 | grep -c 'https://' )
only_r=$("$SHELF_BIN" find bulk -n 50 -k reading | grep -c 'https://')
only_t=$("$SHELF_BIN" find bulk -n 50 -k tool | grep -c 'https://')
check "-k partitions the result set" "$both" "$((only_r + only_t))"

# --- human views split by kind, but only when both kinds exist
fresh views
"$SHELF_BIN" add https://github.com/someorg/widget -w "does widgets" -t cli --offline >/dev/null
"$SHELF_BIN" verdict widget adopted >/dev/null
out=$("$SHELF_BIN" print)
check_not "tool-only print has no TOOLS header" "TOOLS" "$out"
check_not "tool-only print has no READING header" "READING" "$out"
check "tool-only print still groups by verdict" "ADOPTED" "$out"
check_not "tool-only index has no Reading heading" "## Reading" "$(cat "$SHELF_DIR/README.md")"
check_not "tool-only index has no Tools heading" "## Tools" "$(cat "$SHELF_DIR/README.md")"
check_same "tool-only tags trailer is the legacy string" "1 items" "$("$SHELF_BIN" tags | tail -1)"

"$SHELF_BIN" add 'https://example.com/blog/ten-tips' -w 'listicle | nothing in it' -t arch \
  -s ten-tips --offline >/dev/null
"$SHELF_BIN" verdict ten-tips useful >/dev/null
out=$("$SHELF_BIN" print)
check "mixed print has TOOLS" "TOOLS" "$out"
check "mixed print has READING" "READING" "$out"
check "mixed print files reading under USEFUL" "USEFUL" "$out"
check_not "mixed print pipes clean" $'\033[' "$out"
check "mixed tags trailer splits by kind" "2 items (1 tools, 1 reading)" "$("$SHELF_BIN" tags)"
"$SHELF_BIN" index >/dev/null
check "mixed index has Tools" "## Tools" "$(cat "$SHELF_DIR/README.md")"
check "mixed index has Reading" "## Reading" "$(cat "$SHELF_DIR/README.md")"
check "reading table escapes pipes" 'listicle \| nothing' "$(cat "$SHELF_DIR/README.md")"
check "list -k reading filters" "ten-tips" "$("$SHELF_BIN" list -k reading)"
check_not "list -k reading excludes tools" "widget" "$("$SHELF_BIN" list -k reading)"

# --- shelf kind
fresh kindcmd
"$SHELF_BIN" add https://github.com/someorg/course -w "a course, not a library" -t ml --offline >/dev/null
before=$(cat "$SHELF_DIR/items/course.md")
check_same "kind with no argument reads" "tool" "$("$SHELF_BIN" kind course)"
check_same "kind read writes nothing" "$before" "$(cat "$SHELF_DIR/items/course.md")"
out=$("$SHELF_BIN" kind course reading)
check "kind change reported" "course → reading" "$out"
check "pristine scaffold swapped" "scaffold swapped" "$out"
check "default verdict migrated" "verdict untried → unread" "$out"
check "new scaffold on disk" "## What it argues" "$(cat "$SHELF_DIR/items/course.md")"
check_not "old scaffold gone" "## What it is" "$(cat "$SHELF_DIR/items/course.md")"
check "migrated verdict on disk" "verdict: unread" "$(cat "$SHELF_DIR/items/course.md")"

"$SHELF_BIN" add https://github.com/someorg/written -w "has writing in it" -t x --offline >/dev/null
printf 'my own sentence about this tool.\n' >> "$SHELF_DIR/items/written.md"
"$SHELF_BIN" verdict written rejected >/dev/null
out=$("$SHELF_BIN" kind written reading)
rc=$?
check "edited body kept" "note body kept" "$out"
check "the user's sentence survives" "my own sentence about this tool." "$(cat "$SHELF_DIR/items/written.md")"
check "real judgement is not remapped" "verdict: rejected" "$(cat "$SHELF_DIR/items/written.md")"
check "cross-kind verdict warned" "is not a reading verdict" "$out"
check "cross-kind warning names the set" "unread · useful · noise" "$out"
check_same "kind change on a judged item exits zero" "0" "$rc"

# --- legacy and hand-edited notes
fresh legacy
printf -- '---\nname: oldtool\nurl: https://github.com/old/oldtool\ntags: [legacy]\nadded: 2026-01-01\nverdict: adopted\nwhy: "pre-kind note"\n---\n\n## What it is\nlegacy\n' > "$SHELF_DIR/items/oldtool.md"
printf -- '---\nname: bare\nurl: https://github.com/old/bare\ntags: [legacy]\nadded: 2026-01-01\nwhy: "no verdict at all"\n---\n\n## What it is\n' > "$SHELF_DIR/items/bare.md"
printf -- '---\nname: crossed\nkind: reading\nurl: https://example.com/blog/crossed\ntags: [legacy]\nadded: 2026-01-01\nverdict: adopted\nwhy: "hand-edited cross-kind"\n---\n\n## What it argues\n' > "$SHELF_DIR/items/crossed.md"
printf -- '---\nname: garbage\nkind: banana\nurl: https://example.com/blog/garbage\ntags: [legacy]\nadded: 2026-01-01\nverdict: trialling\nwhy: "unrecognised kind value"\n---\n\n## What it is\n' > "$SHELF_DIR/items/garbage.md"
check "legacy note keeps its verdict in find" "[adopted]" "$("$SHELF_BIN" find oldtool)"
check "legacy note lists" "oldtool" "$("$SHELF_BIN" list)"
check_same "legacy note reports as a tool" "tool" "$("$SHELF_BIN" kind oldtool)"
check "legacy note with no verdict is untried" "[untried]" "$("$SHELF_BIN" find bare)"
check_not "legacy note with no verdict is not unread" "[unread]" "$("$SHELF_BIN" find bare)"
check_same "garbage kind falls back to tool" "tool" "$("$SHELF_BIN" kind garbage)"
"$SHELF_BIN" find crossed >/dev/null 2>&1; a=$?
"$SHELF_BIN" list >/dev/null 2>&1; b=$?
"$SHELF_BIN" print >/dev/null 2>&1; c=$?
"$SHELF_BIN" tags >/dev/null 2>&1; d=$?
"$SHELF_BIN" index >/dev/null 2>&1; e=$?
check_same "cross-kind and garbage notes are inert" "0 0 0 0 0" "$a $b $c $d $e"
check "cross-kind item filed under its own verdict" "ADOPTED" "$("$SHELF_BIN" print)"
check "legacy print shows TOOLS and READING" "READING" "$("$SHELF_BIN" print)"

# ==================================================================== constraints

fresh constraints
check "constraints on a fresh shelf" "no constraints yet" "$("$SHELF_BIN" constraints)"
check "empty constraints suggests an add" "shelf constraint single-node" "$("$SHELF_BIN" constraints)"
"$SHELF_BIN" constraints >/dev/null 2>&1
check_same "empty constraints exits zero" "0" "$?"
check "init seeds the constraints header" "# Constraints" "$(cat "$SHELF_DIR/constraints.md")"
check_same "init seeds zero constraint bullets" "0" \
  "$(grep -c '^- `' "$SHELF_DIR/constraints.md")"

# --- upgrade path: a v0.1 shelf has no constraints.md at all
rm -f "$SHELF_DIR/constraints.md"
check "v0.1 shelf lists no constraints" "no constraints yet" "$("$SHELF_BIN" constraints)"
check_same "v0.1 shelf is not given a constraints.md" "absent" \
  "$([ -e "$SHELF_DIR/constraints.md" ] && echo present || echo absent)"

check "constraint add reports it" "added \`single-node\`" \
  "$("$SHELF_BIN" constraint single-node 'no Redis, no Kafka — one box and "no" cluster ops')"
check "constraint bullet written" '- `single-node`:' "$(cat "$SHELF_DIR/constraints.md")"
check "constraint stamped with since" "(since " "$(cat "$SHELF_DIR/constraints.md")"
check "constraints lists the text" "no Redis, no Kafka" "$("$SHELF_BIN" constraints)"
check "em dash survives the round trip" "— one box" "$("$SHELF_BIN" constraints)"
check "quotes survive the round trip" '"no" cluster' "$("$SHELF_BIN" constraints)"
check_not "constraints pipes clean" $'\033[' "$("$SHELF_BIN" constraints)"

# --- update matches on id, never duplicates, and keeps the original since
"$SHELF_BIN" constraint single-node "no Redis, one box" >/dev/null
"$SHELF_BIN" constraint single-node "no Redis, no Kafka, one box" >/dev/null
check_same "update never duplicates the line" "1" "$(grep -c 'single-node' "$SHELF_DIR/constraints.md")"
check "update keeps the original since" "(since $(date +%Y-%m-%d))" "$(cat "$SHELF_DIR/constraints.md")"
check "update changes the text" "no Kafka, one box" "$("$SHELF_BIN" constraints)"

# --- hand-written lines: forgiving on read, never back-stamped
printf -- '\nsome prose a human typed.\n- pg13: pinned to 13\n- arm64: builds must run on Apple silicon (until Q3)\n' \
  >> "$SHELF_DIR/constraints.md"
check "hand-written line is listed" "pinned to 13" "$("$SHELF_BIN" constraints)"
"$SHELF_BIN" constraint py38 "library code has to import on Python 3.8" >/dev/null
check_not "hand-written line is not back-stamped" "pinned to 13  (since" "$(cat "$SHELF_DIR/constraints.md")"
check "non-metadata parenthetical is kept" "(until Q3)" "$("$SHELF_BIN" constraints)"
check "prose survives a write" "some prose a human typed." "$(cat "$SHELF_DIR/constraints.md")"
check "header survives a write" "# Constraints" "$(cat "$SHELF_DIR/constraints.md")"

# --- constraint round-trips exactly
check "constraint parse/format round-trips" "round-trip ok" "$(python3 - "$SHELF_BIN" <<'PY'
import runpy, sys
g = runpy.run_path(sys.argv[1])
lines = ["- `single-node`: no Redis, no Kafka — one box  (since 2026-01-14)",
         "- `java8`: no JVM 11+ on the build boxes  (since 2025-06-02, lifted 2026-08-13)",
         "- `pg13`: pinned to Postgres 13 (until Q3)",
         "- pg13: pinned to 13"]
bad = [l for l in lines if g["fmt_constraint"](g["parse_constraint"](l)) not in (l, "- `%s`: %s" % (
    g["parse_constraint"](l)["id"], g["parse_constraint"](l)["text"]))]
print("round-trip ok" if not bad and g["parse_constraint"]("- not-an-id!!: nope") is None else "BROKEN %s" % bad)
PY
)"

# --- bad ids are refused before anything is written
check "spacey id refused" "bad constraint id" "$("$SHELF_BIN" constraint 'Not An Id' 'nope' 2>&1)"
check "overlong id refused" "bad constraint id" \
  "$("$SHELF_BIN" constraint aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 'nope' 2>&1)"
check_not "bad id wrote nothing" "Not An Id" "$(cat "$SHELF_DIR/constraints.md")"

# --- --because links a decision to a constraint
"$SHELF_BIN" add https://github.com/someorg/bucketeer \
  -w "Token bucket limiter with a leaky-bucket fallback, dropped it because it wants its own Redis cluster" \
  -t rate-limiting --offline >/dev/null
"$SHELF_BIN" add https://github.com/someorg/slowdown \
  -w "In-process limiter, zero deps — shipped in the billing service" -t rate-limiting --offline >/dev/null
"$SHELF_BIN" add https://github.com/someorg/silent -t rate-limiting --offline >/dev/null
out=$("$SHELF_BIN" verdict bucketeer rejected --because nope 2>&1); rc=$?
check "unknown constraint refused" "unknown constraint: nope" "$out"
check "unknown constraint lists the known set" "single-node" "$out"
check "unknown constraint hands you the fix" "shelf constraint nope" "$out"
check_same "unknown constraint exits non-zero" "1" "$rc"

check "because reported" "because single-node" "$("$SHELF_BIN" verdict bucketeer rejected --because single-node)"
check "because written as a list" "because: [single-node]" "$(cat "$SHELF_DIR/items/bucketeer.md")"
check "because sits right after verdict" "verdict: rejected
because: [single-node]" "$(cat "$SHELF_DIR/items/bucketeer.md")"
"$SHELF_BIN" verdict slowdown adopted --because single-node >/dev/null
"$SHELF_BIN" verdict silent rejected --because single-node >/dev/null

# --- find renders the citation inside the existing budget
out=$("$SHELF_BIN" find bucketeer)
check "citation heads the why line" "    single-node · Token bucket" "$out"
check "verdict bracket untouched" "[rejected]" "$out"
check "citation stays inside WHY_CAP" "within-cap" "$(printf '%s' "$out" | python3 -c "
import sys
worst = max((len(l[4:]) for l in sys.stdin.read().splitlines() if l.startswith('    ')), default=0)
print('within-cap' if worst <= 110 else 'over-cap by %d' % (worst - 110))")"
check "empty why still shows the citation" "    single-node" "$("$SHELF_BIN" find silent)"

# REGRESSION GUARD: an uncited item must render exactly as it did in v0.1
"$SHELF_BIN" add https://github.com/someorg/plainone -w "no constraint on this one" \
  -t rate-limiting --offline >/dev/null
"$SHELF_BIN" verdict plainone adopted >/dev/null
out=$("$SHELF_BIN" find plainone)
check_same "uncited item keeps the v0.1 hit line" \
  "plainone  [adopted]  https://github.com/someorg/plainone" "$(printf '%s' "$out" | sed -n 1p)"
check_same "uncited why line has no separator artefact" \
  "    no constraint on this one" "$(printf '%s' "$out" | sed -n 2p)"

# --- revisit
out=$("$SHELF_BIN" revisit single-node)
check "revisit counts the decisions" "3 decisions rest on \`single-node\`" "$out"
check "revisit shows the constraint text" "no Redis, no Kafka" "$out"
check "revisit lists the cited item" "bucketeer" "$out"
check_not "revisit does not repeat the id per line" "    single-node ·" "$out"
check "revisit orders rejected before adopted" "bucketeer" \
  "$(printf '%s' "$out" | grep 'https://' | head -1)"
check "revisit closes with the show hint" "before re-deciding" "$out"
"$SHELF_BIN" constraint pg13 "pinned to Postgres 13 until Q3" >/dev/null
check "revisit with no citations" "nothing cites \`pg13\` yet" "$("$SHELF_BIN" revisit pg13)"
check "revisit with no citations shows the text" "Postgres 13" "$("$SHELF_BIN" revisit pg13)"
"$SHELF_BIN" revisit pg13 >/dev/null 2>&1
check_same "revisit with no citations exits zero" "0" "$?"
out=$("$SHELF_BIN" revisit nope 2>&1); rc=$?
check "revisit on an unknown id" "unknown constraint" "$out"
check_same "revisit on an unknown id exits non-zero" "1" "$rc"

# --- revisit is capped exactly like find
for n in $(seq 1 20); do
  printf -- '---\nname: rest-%s\nkind: tool\nurl: https://github.com/bulk/rest-%s\ntags: [bulk]\nadded: 2026-01-01\nverdict: rejected\nbecause: [pg13]\nwhy: "bulk citing item"\n---\n\n## What it is\n' \
    "$n" "$n" > "$SHELF_DIR/items/rest-$n.md"
done
check "revisit caps at 8" "8" "$(printf '%s' "$("$SHELF_BIN" revisit pg13 | grep -c 'github.com/bulk')")"
check "revisit reports the overflow" "12 more" "$("$SHELF_BIN" revisit pg13 | grep 'more —')"
check "revisit -n raises the cap" "20" \
  "$(printf '%s' "$("$SHELF_BIN" revisit pg13 -n 50 | grep -c 'github.com/bulk')")"

# --- counts
out=$("$SHELF_BIN" constraints)
check "constraints counts citations" "single-node    ×3  no Redis" "$out"
check "constraints counts the bulk citations" "pg13           ×20 pinned" "$out"
check_not "uncited constraint shows no count" "py38           ×" "$out"

# --- lifting is the payoff moment
out=$("$SHELF_BIN" constraint single-node --lift)
check "lift is reported" "lifted \`single-node\`" "$out"
check "lift counts what rested on it" "3 decisions rested on it" "$out"
check "lift prints hits in find format" "bucketeer  [rejected]  https://github.com/someorg/bucketeer" "$out"
check "lift closes with the re-decide hint" "re-decide with" "$out"
check "lift stamped in the file" "lifted $(date +%Y-%m-%d)" "$(cat "$SHELF_DIR/constraints.md")"
check "lifted constraint still listed while cited" "single-node" "$("$SHELF_BIN" constraints)"
check "lifted footer nudges revisit" "shelf revisit single-node" "$("$SHELF_BIN" constraints)"
err=$("$SHELF_BIN" verdict bucketeer rejected --because single-node 2>&1 >/dev/null)
check "citing a lifted constraint warns on stderr" "was lifted" "$err"
check "citing a lifted constraint still writes" "because: [single-node]" "$(cat "$SHELF_DIR/items/bucketeer.md")"

# --- --because is tri-state: omitted preserves, "" clears
"$SHELF_BIN" verdict bucketeer trialling >/dev/null
check "omitting --because preserves it" "because: [single-node]" "$(cat "$SHELF_DIR/items/bucketeer.md")"
for slug in bucketeer slowdown silent; do "$SHELF_BIN" verdict "$slug" rejected --because "" >/dev/null; done
check_not "--because '' removes the line" "because:" "$(cat "$SHELF_DIR/items/bucketeer.md")"
check_same "--because '' leaves no blank residue" "clean" "$(python3 -c "
head = open('$SHELF_DIR/items/bucketeer.md').read().split('\n---', 1)[0]
print('clean' if all(l.strip() for l in head.split('\n')) else 'blank-line')")"
check_not "self-cleaning: uncited lifted constraint disappears" "single-node" "$("$SHELF_BIN" constraints)"
check "lifted constraint stays in the file" "single-node" "$(cat "$SHELF_DIR/constraints.md")"

# --- dropping
out=$("$SHELF_BIN" constraint pg13 --drop 2>&1); rc=$?
check "drop refuses while cited" "refusing: 20 items cite" "$out"
check "drop suggests lifting" "lift it instead" "$out"
check_same "refused drop exits non-zero" "1" "$rc"
check "drop is still in the file" "pg13" "$(cat "$SHELF_DIR/constraints.md")"
"$SHELF_BIN" constraint pg13 --drop --force >/dev/null
check_not "forced drop removes the line" 'pg13`:' "$(cat "$SHELF_DIR/constraints.md")"
err=$("$SHELF_BIN" constraints 2>&1 >/dev/null)
check "orphaned citations warn on stderr" "cite unknown constraints: pg13" "$err"
check_not "orphan warning stays off stdout" "unknown constraints" "$("$SHELF_BIN" constraints 2>/dev/null)"

# --- the decoy body, which upsert_field must never touch
printf -- '---\nname: decoy\nkind: tool\nurl: https://github.com/x/decoy\ntags: [x]\nadded: 2026-01-01\nverdict: untried\nwhy: "has decoys in the body"\n---\n\n## What it is\nverdict: banana\nbecause: [not-a-real-id]\n' > "$SHELF_DIR/items/decoy.md"
"$SHELF_BIN" verdict decoy rejected --because py38 >/dev/null
check "frontmatter verdict updated" "verdict: rejected" "$(cat "$SHELF_DIR/items/decoy.md")"
check "body decoy verdict untouched" "verdict: banana" "$(cat "$SHELF_DIR/items/decoy.md")"
check "body decoy because untouched" "because: [not-a-real-id]" "$(cat "$SHELF_DIR/items/decoy.md")"
check_same "exactly one frontmatter verdict line" "2" "$(grep -c '^verdict:' "$SHELF_DIR/items/decoy.md")"

# --- the generated index
"$SHELF_BIN" constraint no-bsl 'BSL/SSPL is out for | anything we ship' >/dev/null
"$SHELF_BIN" index >/dev/null
check "index renders a constraints section" "## Constraints" "$(cat "$SHELF_DIR/README.md")"
check "index lists a constraint" '`py38`' "$(cat "$SHELF_DIR/README.md")"
check "index escapes pipes in constraints" 'out for \| anything' "$(cat "$SHELF_DIR/README.md")"
check "index suffixes the verdict cell" "rejected (py38)" "$(cat "$SHELF_DIR/README.md")"

# --- reading one constraint, and the soft cap on the always-loaded set
fresh softmax
"$SHELF_BIN" constraint pg13 "pinned to Postgres 13 until Q3" >/dev/null
check "constraint read shows id, text and since" "pg13" "$("$SHELF_BIN" constraint pg13)"
check "constraint read shows the since date" "(since $(date +%Y-%m-%d))" "$("$SHELF_BIN" constraint pg13)"
check_same "constraint read is one line" "1" "$("$SHELF_BIN" constraint pg13 | wc -l | tr -d ' ')"
for n in $(seq 1 13); do "$SHELF_BIN" constraint "c$n" "standing fact number $n" >/dev/null; done
err=$("$SHELF_BIN" constraints 2>&1 >/dev/null)
check "soft cap warns on stderr" "live constraints" "$err"
check_not "soft cap warning stays off stdout" "live constraints —" "$("$SHELF_BIN" constraints 2>/dev/null)"

# --- constraint / constraints do not collide
fresh collide
check_same "constraints is the plural command" "no constraints yet" \
  "$("$SHELF_BIN" constraints | sed -n 1p)"
check "constraint is the singular command" "unknown constraint: pg13" "$("$SHELF_BIN" constraint pg13 2>&1)"
check "an abbreviation is an error, not a guess" "invalid choice" "$("$SHELF_BIN" constr 2>&1)"

# ==================================================================== telemetry

fresh telemetry
"$SHELF_BIN" add https://github.com/someorg/widget -w "does widgets for pipelines" -t cli --offline >/dev/null
"$SHELF_BIN" verdict widget adopted >/dev/null

# --- the assertion that guards the thesis
check_same "find output unchanged by logging" \
  "$("$SHELF_BIN" find widgets)" "$(SHELF_NO_LOG=1 "$SHELF_BIN" find widgets)"
check_same "find miss unchanged by logging" \
  "$("$SHELF_BIN" find kubernetes)" "$(SHELF_NO_LOG=1 "$SHELF_BIN" find kubernetes)"
check_same "show output unchanged by logging" \
  "$("$SHELF_BIN" show widget)" "$(SHELF_NO_LOG=1 "$SHELF_BIN" show widget)"
check_same "logging writes nothing to stderr" "" "$("$SHELF_BIN" find widgets 2>&1 >/dev/null)"

# --- the record itself
check "log records the find" '"op":"find"' "$(cat "$SHELF_DIR/log.jsonl")"
check "log records the surfaced verdict" 'widget:a' "$(cat "$SHELF_DIR/log.jsonl")"
check "log records the show" '"op":"show"' "$(cat "$SHELF_DIR/log.jsonl")"
check "log is gitignored" "log.*" "$(cat "$SHELF_DIR/.gitignore")"
# GNU stat first: on Linux `stat -f` means *filesystem* status, so it exits 0 with
# the wrong answer and a BSD-first `||` chain never falls through. BSD stat has no
# -c and exits 1, so this order is the only one that works on both.
check_same "log is 0600" "600" \
  "$(stat -c '%a' "$SHELF_DIR/log.jsonl" 2>/dev/null || stat -f '%Lp' "$SHELF_DIR/log.jsonl")"

# --- a shelf whose .gitignore predates the feature gets the entry on first write
printf 'repos/\n' > "$SHELF_DIR/.gitignore"
rm -f "$SHELF_DIR/log.jsonl"
"$SHELF_BIN" find widgets >/dev/null
check "gitignore back-filled for an old shelf" "log.*" "$(cat "$SHELF_DIR/.gitignore")"
# the compaction scratch file holds the same verbatim query text as the log itself
if command -v git >/dev/null 2>&1 && git -C "$SHELF_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$SHELF_DIR" check-ignore -q log.tmp
  check_same "git ignores the compaction scratch file" "0" "$?"
  git -C "$SHELF_DIR" check-ignore -q log.jsonl
  check_same "git ignores the log itself" "0" "$?"
fi

# --- misses are the gap analysis
"$SHELF_BIN" find kubernetes >/dev/null
check "stats lists the gap" "kubernetes" "$("$SHELF_BIN" stats)"
check "stats reports the hit rate" "searches" "$("$SHELF_BIN" stats)"
check "stats splits agent from human" "piped (an agent, most likely)" "$("$SHELF_BIN" stats)"
check "stats reports re-research" "re-research" "$("$SHELF_BIN" stats)"
check_not "a fresh item is not called dead weight" "never retrieved" "$("$SHELF_BIN" stats)"

# --- a corrupt tail must not break the report
printf '{"op":"find","q":"trunc' >> "$SHELF_DIR/log.jsonl"
printf '\nnot json at all\n' >> "$SHELF_DIR/log.jsonl"
check "corrupt lines are skipped" "searches" "$("$SHELF_BIN" stats)"

# --- compaction: the file is capped and the lifetime counters survive it
line=$(grep '"op":"find"' "$SHELF_DIR/log.jsonl" | head -1)
: > "$SHELF_DIR/log.jsonl"
for n in $(seq 1 4000); do printf '%s\n' "$line"; done >> "$SHELF_DIR/log.jsonl"
before=$(wc -c < "$SHELF_DIR/log.jsonl")
"$SHELF_BIN" find widgets >/dev/null
after=$(wc -c < "$SHELF_DIR/log.jsonl")
check "compaction writes a rollup first" '"op":"rollup"' "$(head -1 "$SHELF_DIR/log.jsonl")"
check_same "compaction shrinks the log" "smaller" \
  "$([ "$after" -lt "$before" ] && echo smaller || echo "bigger ($before → $after)")"
check "compaction preserves lifetime counters" '"finds": 4001' "$("$SHELF_BIN" stats --json)"
check "json dump is machine-readable" '"misses"' "$("$SHELF_BIN" stats --json)"

# --- compaction prunes items that no longer exist
check "rollup remembers the item" "widget" "$(head -1 "$SHELF_DIR/log.jsonl")"
rm -f "$SHELF_DIR/items/widget.md"
for n in $(seq 1 4000); do printf '%s\n' "$line"; done >> "$SHELF_DIR/log.jsonl"
"$SHELF_BIN" find widgets >/dev/null
check_not "compaction prunes a deleted item" "widget" "$(head -1 "$SHELF_DIR/log.jsonl")"
check_same "compaction leaves no scratch file" "absent" \
  "$([ -e "$SHELF_DIR/log.tmp" ] && echo present || echo absent)"

# --- the rollup is capped too: it must not grow with the shelf, or the 256 KiB
#     trigger fires forever on a log compaction can no longer shrink
fresh rollupcap
map='"hot":[99,0]'
printf -- '---\nname: hot\nkind: tool\nurl: https://github.com/o/hot\ntags: [bulk]\nadded: 2025-01-01\nverdict: untried\nwhy: "hot"\n---\n\n## What it is\n' > "$SHELF_DIR/items/hot.md"
for n in $(seq 100 549); do
  printf -- '---\nname: bulk%s\nkind: tool\nurl: https://github.com/o/bulk%s\ntags: [bulk]\nadded: 2025-01-01\nverdict: untried\nwhy: "bulk"\n---\n\n## What it is\n' "$n" "$n" > "$SHELF_DIR/items/bulk$n.md"
  map="$map,\"bulk$n\":[1,0]"
done
printf '%s\n' "{\"op\":\"rollup\",\"since\":\"2025-01-01T00:00:00\",\"to\":\"2025-01-02T00:00:00\",\"finds\":451,\"misses\":0,\"shows\":0,\"piped\":451,\"missed\":{},\"surfaced\":{},\"opened\":{},\"items\":{$map}}" > "$SHELF_DIR/log.jsonl"
line='{"t":"2026-01-01T00:00:00","op":"find","q":"bulk","n":1,"tty":0,"hits":["bulk100:u"]}'
for n in $(seq 1 4000); do printf '%s\n' "$line"; done >> "$SHELF_DIR/log.jsonl"
"$SHELF_BIN" find bulk >/dev/null
rollup=$(head -1 "$SHELF_DIR/log.jsonl")
check_same "rollup item map is capped" "400" "$(printf '%s' "$rollup" | tr ',' '\n' | grep -c '"\(hot\|bulk[0-9]*\)":\[')"
check "the most-retrieved item survives the cap" '"hot":[' "$rollup"
check_same "a capped rollup stays well under the trigger" "under" \
  "$([ "$(printf '%s' "$rollup" | wc -c)" -lt 65536 ] && echo under || echo over)"

# --- a hostile log costs you stats, never a search (works as root, unlike chmod)
fresh hostile
"$SHELF_BIN" add https://github.com/someorg/widget -w "does widgets" -t cli --offline >/dev/null
rm -f "$SHELF_DIR/log.jsonl"
mkdir "$SHELF_DIR/log.jsonl"
out=$("$SHELF_BIN" find widgets); rc=$?
check "find survives an unwritable log" "widget" "$out"
check_same "find still exits zero" "0" "$rc"
"$SHELF_BIN" stats >/dev/null 2>&1
check_same "stats survives an unwritable log" "0" "$?"
check "stats says so politely" "nothing retrieved yet" "$("$SHELF_BIN" stats)"
rmdir "$SHELF_DIR/log.jsonl"

# --- opt out, and back in
fresh optout
"$SHELF_BIN" add https://github.com/someorg/widget -w "does widgets" -t cli --offline >/dev/null
check "stats on an empty log" "nothing retrieved yet" "$("$SHELF_BIN" stats)"
check "opt-out deletes the log" "usage logging off" "$("$SHELF_BIN" stats --off)"
"$SHELF_BIN" find widgets >/dev/null; "$SHELF_BIN" show widget >/dev/null
check_same "opted out, nothing is written" "absent" \
  "$([ -e "$SHELF_DIR/log.jsonl" ] && echo present || echo absent)"
check "stats says logging is off" "logging is off" "$("$SHELF_BIN" stats)"
"$SHELF_BIN" stats --on >/dev/null
"$SHELF_BIN" find widgets >/dev/null
check_same "opting back in resumes logging" "present" \
  "$([ -e "$SHELF_DIR/log.jsonl" ] && echo present || echo absent)"

# --- dead weight only after a fair chance
printf -- '---\nname: dusty\nkind: tool\nurl: https://github.com/old/dusty\ntags: [old]\nadded: 2025-01-01\nverdict: untried\nwhy: "shelved and forgotten"\n---\n\n## What it is\n' > "$SHELF_DIR/items/dusty.md"
printf '%s\n' '{"op":"rollup","since":"2025-01-01T00:00:00","to":"2025-01-02T00:00:00","finds":1,"misses":0,"shows":0,"piped":1,"missed":{},"surfaced":{},"opened":{},"items":{}}' >> "$SHELF_DIR/log.jsonl"
check "an old never-surfaced item is dead weight" "dusty" "$("$SHELF_BIN" stats)"
check "dead weight is named as such" "never retrieved" "$("$SHELF_BIN" stats)"
check "--dead lists them all" "dusty" "$("$SHELF_BIN" stats --dead)"

# ============================================================ python 3.8 floor
# argparse <=3.8 runs _check_value on a *string* default for a nargs='?' positional,
# so `default=""` next to `choices=` exits 2 on the oldest supported interpreter.
# The suite itself runs on whatever `python3` is, so this one is checked statically.
check_same "no nargs='?' choices default that breaks python 3.8" "" \
  "$(grep -n 'nargs="?"' "$SHELF_BIN" | grep 'choices=' | grep -v 'default=None')"

# ==================================================================== docs
# Three surfaces state the vocabulary verbatim; if one drifts an agent emits words
# the CLI rejects.
for doc in README.md AGENTS.md skills/claude-code/SKILL.md; do
  for word in unread useful noise "shelf constraints"; do
    check "$doc carries \`$word\`" "$word" "$(cat "$REPO/$doc")"
  done
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
