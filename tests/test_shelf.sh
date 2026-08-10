#!/usr/bin/env bash
# End-to-end tests. Runs against a throwaway SHELF_DIR — never touches a real shelf.
# Network-dependent behaviour is exercised with --offline so the suite is hermetic.
set -uo pipefail

SHELF_BIN="$(cd "$(dirname "$0")/.." && pwd)/shelf"
export SHELF_DIR
SHELF_DIR="$(mktemp -d)"
trap 'rm -rf "$SHELF_DIR"' EXIT

pass=0; fail=0
check() { # check <name> <expected-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want substring: %s\n       got: %s\n' "$1" "$2" "$3"
  fi
}
check_not() {
  if printf '%s' "$3" | grep -qF -- "$2"; then
    fail=$((fail + 1)); printf '  FAIL %s\n       unwanted substring present: %s\n' "$1" "$2"
  else
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  fi
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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
