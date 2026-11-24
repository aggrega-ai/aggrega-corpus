#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# scripts/test-frozen-corpus.sh — plants one fault at a time in a tiny scratch corpus and
# shows that scripts/frozen-corpus.sh (fast, live and full) refuses each with its exit
# status and names the Release, and passes the clean case. It fails whenever an expected
# refusal is not reported. Hermetic and offline: the binary is a stub that halts, loses its
# result or meets a network or registry halt on a marker in the Release file, the corpus's
# build-release.sh is a stub that hands the binary what it was given, and HOME is a scratch
# directory, so a cache written outside a run's own scratch directory would be seen;
# everything lives under one mktemp directory, removed on exit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="${FROZEN_CORPUS_SCRIPT:-$SCRIPT_DIR/frozen-corpus.sh}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

failed="$WORK/failed"
: > "$failed"
fail() { echo "FAIL: $*" >&2; echo x >> "$failed"; }

# The stub binary: `validate --catalog DIR` passes; `validate --release FILE` and
# `build --release FILE` halt with [E0001] when FILE carries the word HALT, kill the
# frozen-corpus.sh subshell that would record the result when FILE carries LOSE, halt with
# [E0136] when FILE carries NETDOWN, or the first time when it carries NETONCE, with
# [E0380] (the registry's server error) when it carries SERVERERR, or the first time when it
# carries SERVERONCE, with [E0381] (a transfer broken off) when it carries BROKEOFF, exit 1
# printing nothing when it carries NOCODE, leave the file sleeping beside it, sleep a second
# and then write under its working directory, by its full path, when it carries SLEEP, and
# pass otherwise. A build also records the XDG_CACHE_HOME it was handed in cache-homes
# beside it.
STUB="$WORK/aggrega-stub"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
case "${1:-}" in
  validate) ;;
  build) printf '%s\n' "${XDG_CACHE_HOME:-}" >> "$(dirname "$0")/cache-homes" ;;
  *) exit 2 ;;
esac
shift
rel=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --catalog) exit 0 ;;
    --release) rel="$2"; shift ;;
  esac
  shift
done
if grep -q HALT "$rel"; then echo "[E0001] planted halt"; exit 1; fi
if grep -q NETDOWN "$rel"; then echo "[E0136] planted network unreachable"; exit 1; fi
if grep -q SERVERERR "$rel"; then echo "[E0380] planted registry server error"; exit 1; fi
if grep -q BROKEOFF "$rel"; then echo "[E0381] planted transfer broken off"; exit 1; fi
if grep -q NOCODE "$rel"; then exit 1; fi
if grep -q SLEEP "$rel"; then : > "$(dirname "$0")/sleeping"; sleep 1; mkdir -p "$PWD/late-write"; exit 0; fi
if grep -q NETONCE "$rel" && [ ! -e "$rel.net" ]; then
  : > "$rel.net"; echo "[E0136] planted network unreachable"; exit 1
fi
if grep -q SERVERONCE "$rel" && [ ! -e "$rel.net" ]; then
  : > "$rel.net"; echo "[E0380] planted registry server error"; exit 1
fi
if grep -q LOSE "$rel"; then
  pid=$$
  while [ "$pid" -gt 1 ]; do
    pid="$(awk '{ print $4 }' "/proc/$pid/stat")"
    if tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qF scripts/frozen-corpus.sh; then kill -9 "$pid"; exit 0; fi
  done
fi
exit 0
STUBEOF
chmod +x "$STUB"

# mkcorpus NAME — a corpus at $WORK/NAME with three Releases: a/release.yaml recorded ok
# (validate and build), b/release.yaml recorded halt:E0001, whose files are clean and HALT
# as recorded, and c/release.yaml recorded ok and check.sh, whose example's check.sh builds
# it; prints the path.
mkcorpus() {
  local c="$WORK/$1"
  mkdir -p "$c/aggrega-docs/language-reference/examples/a" "$c/aggrega-docs/language-reference/examples/b" \
    "$c/aggrega-docs/language-reference/examples/c" "$c/aggrega-docs/scripts" "$c/aggrega-hub/aggrega-catalog/component"
  echo 'kind: Release' > "$c/aggrega-docs/language-reference/examples/a/release.yaml"
  echo 'kind: Release HALT' > "$c/aggrega-docs/language-reference/examples/b/release.yaml"
  echo 'kind: Release' > "$c/aggrega-docs/language-reference/examples/c/release.yaml"
  # shellcheck disable=SC2016 # the check's text is written as it is, expanded when it runs
  printf '#!/usr/bin/env bash\nexec "$AGGREGA_BIN" build --release release.yaml\n' > "$c/aggrega-docs/language-reference/examples/c/check.sh"
  chmod +x "$c/aggrega-docs/language-reference/examples/c/check.sh"
  cat > "$c/aggrega-docs/scripts/build-release.sh" <<'BRSH'
#!/usr/bin/env bash
# stub of the corpus's helper: build-release.sh --example DIR FILE -- ARGS...
dir="$2"; file="$3"; shift 4
cd "$dir" && exec "$AGGREGA_BIN" build --release "$file" "$@"
BRSH
  printf 'workspace\trelease\tvalidate\tbuild\na\trelease.yaml\tok\tok\nb\trelease.yaml\thalt:E0001\thalt:E0001\nc\trelease.yaml\tok\tcheck.sh\n' > "$c/outcomes.tsv"
  printf 'workspace\trelease\ttier\tnow\treason\n' > "$c-accepted.tsv"
  echo "$c"
}

# accept CORPUS LINE — append an accepted entry.
accept() { printf '%s\n' "$2" >> "$1-accepted.tsv"; }

# expect NAME WANT_EXIT NEEDLE ARGS... — runs frozen-corpus.sh with the stub binary.
expect() {
  local name="$1" want="$2" needle="$3" out rc=0
  shift 3
  out="$(bash "$RUN" "$@" --bin "$STUB" 2>&1)" || rc=$?
  if [ "$rc" != "$want" ]; then
    fail "$name: exit $rc, want $want: $out"
  elif [ -n "$needle" ] && ! grep -qF -- "$needle" <<< "$out"; then
    fail "$name: output does not name $needle: $out"
  fi
}

for tier in fast live; do
  cat_arg=()
  [ "$tier" = live ] && cat_arg=(--catalog "$WORK/hub-$tier") && mkdir -p "$WORK/hub-$tier/component"

  # clean
  c="$(mkcorpus "$tier-clean")"
  expect "$tier clean" 0 "0 difference(s)" "$tier" --corpus "$c" "${cat_arg[@]}"

  # a Release recorded ok now halts: a break
  c="$(mkcorpus "$tier-break")"
  echo 'kind: Release HALT' > "$c/aggrega-docs/language-reference/examples/a/release.yaml"
  expect "$tier recorded ok now halts" 1 "BREAK a/release.yaml: recorded ok, now halt:E0001" "$tier" --corpus "$c" "${cat_arg[@]}"

  # ... and an accepted entry cannot admit it
  accept "$c" "$(printf 'a\trelease.yaml\t%s\thalt:E0001\tplanted' "$tier")"
  expect "$tier recorded ok now halts, accepted" 1 "an accepted entry cannot admit" "$tier" --corpus "$c" "${cat_arg[@]}"

  # a recorded halt now passes, nothing accepts it
  c="$(mkcorpus "$tier-passes")"
  echo 'kind: Release' > "$c/aggrega-docs/language-reference/examples/b/release.yaml"
  expect "$tier recorded halt now passes" 1 "DIFFERENCE b/release.yaml: recorded halt:E0001, now ok" "$tier" --corpus "$c" "${cat_arg[@]}"

  # ... an accepted entry of another tier does not admit it
  other=live; [ "$tier" = live ] && other=fast
  accept "$c" "$(printf 'b\trelease.yaml\t%s\tok\tplanted' "$other")"
  expect "$tier recorded halt now passes, other tier accepted" 1 "DIFFERENCE b/release.yaml" "$tier" --corpus "$c" "${cat_arg[@]}"

  # ... an accepted entry of this tier admits it
  c="$(mkcorpus "$tier-accepted")"
  echo 'kind: Release' > "$c/aggrega-docs/language-reference/examples/b/release.yaml"
  accept "$c" "$(printf 'b\trelease.yaml\t%s\tok\tplanted' "$tier")"
  expect "$tier recorded halt now passes, accepted" 0 "accepted b/release.yaml" "$tier" --corpus "$c" "${cat_arg[@]}"

  # an accepted entry that matches nothing
  c="$(mkcorpus "$tier-stale")"
  accept "$c" "$(printf 'b\trelease.yaml\t%s\tok\tplanted' "$tier")"
  expect "$tier accepted entry matches nothing" 1 "no longer occurs" "$tier" --corpus "$c" "${cat_arg[@]}"

  # a lost result
  c="$(mkcorpus "$tier-lost")"
  echo 'kind: Release LOSE' > "$c/aggrega-docs/language-reference/examples/a/release.yaml"
  expect "$tier lost result" 2 "a Release to judge has no validation result" "$tier" --corpus "$c" "${cat_arg[@]}"
done

# live names its catalog: the repository holds none to default to.
c="$(mkcorpus live-no-catalog)"
expect "live without --catalog" 2 "live needs --catalog DIR" live --corpus "$c"
# ... and the other modes read the corpus's own catalog, so they refuse one.
expect "fast with --catalog" 2 "--catalog is read by live only" fast --corpus "$c" --catalog "$WORK/hub-live"

# full: HOME is a scratch directory, so a cache kept under it would be seen.
fhome="$WORK/home"
mkdir -p "$fhome"
ex="aggrega-docs/language-reference/examples"

c="$(mkcorpus full-clean)"
HOME="$fhome" expect "full clean" 0 "0 difference(s), 0 not judged" full --corpus "$c"
# every build was handed a cache inside the run's scratch directory, which goes with it
[ -s "$WORK/cache-homes" ] || fail "full clean: no build recorded the XDG_CACHE_HOME it was handed"
if grep -vqE '/frozen-corpus-[^/]+/home/\.cache$' "$WORK/cache-homes"; then
  fail "full clean: a build was handed a cache outside the run's scratch directory: $(sort -u "$WORK/cache-homes" | tr '\n' ' ')"
fi
[ ! -e "$fhome/.cache" ] || fail "full clean: something was written under HOME ($fhome/.cache)"

# a Release recorded ok now halts: a break, which an accepted entry cannot admit
c="$(mkcorpus full-break)"
echo 'kind: Release HALT' > "$c/$ex/a/release.yaml"
HOME="$fhome" expect "full recorded ok now halts" 1 "BREAK a/release.yaml: recorded ok, now halt:E0001" full --corpus "$c"
accept "$c" "$(printf 'a\trelease.yaml\tfull\thalt:E0001\tplanted')"
HOME="$fhome" expect "full recorded ok now halts, accepted" 1 "an accepted entry cannot admit" full --corpus "$c"

# a Release recorded check.sh whose example's check.sh now fails: a difference
c="$(mkcorpus full-check-fails)"
echo 'kind: Release HALT' > "$c/$ex/c/release.yaml"
HOME="$fhome" expect "full recorded check.sh, check now fails" 1 "DIFFERENCE c/release.yaml: recorded check.sh, now check.sh failed (exit 1)" full --corpus "$c"

# ... an accepted entry of another tier does not admit it
accept "$c" "$(printf 'c\trelease.yaml\tlive\tcheck.sh failed (exit 1)\tplanted')"
HOME="$fhome" expect "full recorded check.sh, check now fails, other tier accepted" 1 "DIFFERENCE c/release.yaml: recorded check.sh, now check.sh failed (exit 1)" full --corpus "$c"

# ... nor does an entry of tier full naming another outcome
c="$(mkcorpus full-check-fails-other-now)"
echo 'kind: Release HALT' > "$c/$ex/c/release.yaml"
accept "$c" "$(printf 'c\trelease.yaml\tfull\tcheck.sh failed (exit 2)\tplanted')"
HOME="$fhome" expect "full recorded check.sh, check now fails, other outcome accepted" 1 "(the accepted entry says check.sh failed (exit 2))" full --corpus "$c"

# ... an accepted entry of tier full naming that outcome admits it
c="$(mkcorpus full-check-fails-accepted)"
echo 'kind: Release HALT' > "$c/$ex/c/release.yaml"
accept "$c" "$(printf 'c\trelease.yaml\tfull\tcheck.sh failed (exit 1)\tplanted')"
HOME="$fhome" expect "full recorded check.sh, check now fails, accepted" 0 "accepted c/release.yaml: recorded check.sh, now check.sh failed (exit 1) (full)" full --corpus "$c"

# a recorded halt now passes, admitted by an accepted entry of tier full
c="$(mkcorpus full-accepted)"
echo 'kind: Release' > "$c/$ex/b/release.yaml"
accept "$c" "$(printf 'b\trelease.yaml\tfull\tok\tplanted')"
HOME="$fhome" expect "full recorded halt now passes, accepted" 0 "accepted b/release.yaml" full --corpus "$c"

# E0136 twice: not judged, with the words a release's refusal reads
c="$(mkcorpus full-network)"
echo 'kind: Release NETDOWN' > "$c/$ex/a/release.yaml"
HOME="$fhome" expect "full E0136 twice" 2 "not judged: a/release.yaml halted E0136 twice (the network could not be reached)" full --corpus "$c"

# a check.sh meeting E0136 twice: its Releases not judged
c="$(mkcorpus full-check-network)"
echo 'kind: Release NETDOWN' > "$c/$ex/c/release.yaml"
HOME="$fhome" expect "full check.sh E0136 twice" 2 "not judged: c/release.yaml: its example's check.sh met E0136 twice (the network could not be reached)" full --corpus "$c"

# E0136 once: run again, and judged by the second run
c="$(mkcorpus full-network-once)"
echo 'kind: Release NETONCE' > "$c/$ex/a/release.yaml"
HOME="$fhome" expect "full E0136 once" 0 "0 difference(s), 0 not judged" full --corpus "$c"

# the registry's server error (E0380) twice: not judged, as E0136 is
c="$(mkcorpus full-server-error)"
echo 'kind: Release SERVERERR' > "$c/$ex/a/release.yaml"
HOME="$fhome" expect "full E0380 twice" 2 "not judged: a/release.yaml halted E0380 twice, the registry answering with a server error (the network could not be reached)" full --corpus "$c"

# a transfer broken off (E0381) twice: not judged, as E0136 is
c="$(mkcorpus full-broke-off)"
echo 'kind: Release BROKEOFF' > "$c/$ex/a/release.yaml"
HOME="$fhome" expect "full E0381 twice" 2 "not judged: a/release.yaml halted E0381 twice, the transfer from the registry breaking off (the network could not be reached)" full --corpus "$c"

# a check.sh meeting E0381 twice: its Releases not judged
c="$(mkcorpus full-check-broke-off)"
echo 'kind: Release BROKEOFF' > "$c/$ex/c/release.yaml"
HOME="$fhome" expect "full check.sh E0381 twice" 2 "not judged: c/release.yaml: its example's check.sh met E0381 twice, the transfer from the registry breaking off (the network could not be reached)" full --corpus "$c"

# E0380 once: run again, and judged by the second run
c="$(mkcorpus full-server-error-once)"
echo 'kind: Release SERVERONCE' > "$c/$ex/a/release.yaml"
HOME="$fhome" expect "full E0380 once" 0 "0 difference(s), 0 not judged" full --corpus "$c"

# a difference and a Release not judged: the difference decides the exit
c="$(mkcorpus full-break-and-network)"
echo 'kind: Release HALT' > "$c/$ex/a/release.yaml"
echo 'kind: Release NETDOWN' > "$c/$ex/c/release.yaml"
HOME="$fhome" expect "full break beside a Release not judged" 1 "1 difference(s), 1 not judged" full --corpus "$c"

# the build column says check.sh, and the example has no executable check.sh
c="$(mkcorpus full-no-check)"
rm "$c/$ex/c/check.sh"
HOME="$fhome" expect "full check.sh recorded, none there" 2 "outcomes.tsv records check.sh for the Releases of c, and c has no executable check.sh" full --corpus "$c"

# an example whose build column mixes check.sh with other outcomes
c="$(mkcorpus full-mixed)"
echo 'kind: Release' > "$c/$ex/c/release-2.yaml"
printf 'c\trelease-2.yaml\tok\tok\n' >> "$c/outcomes.tsv"
HOME="$fhome" expect "full mixed build column" 2 "outcomes.tsv records check.sh for some Releases of c and not for others" full --corpus "$c"

# a build that exits non-zero printing no diagnostic code
c="$(mkcorpus full-no-code)"
echo 'kind: Release NOCODE' > "$c/$ex/a/release.yaml"
HOME="$fhome" expect "full outcome cannot be read" 2 "not judged: no outcome could be read from the build of a/release.yaml" full --corpus "$c"

# stopped by TERM mid-build: the build is stopped too, so nothing writes into the scratch
# directory after it goes, and the exit is the signal's
c="$(mkcorpus full-term)"
echo 'kind: Release SLEEP' > "$c/$ex/a/release.yaml"
mkdir -p "$WORK/sigtmp"
HOME="$fhome" TMPDIR="$WORK/sigtmp" bash "$RUN" full --corpus "$c" --bin "$STUB" > "$WORK/term.out" 2>&1 &
pid=$!
for _ in $(seq 1 100); do [ -e "$WORK/sleeping" ] && break; sleep 0.1; done
if [ ! -e "$WORK/sleeping" ]; then
  fail "full stopped by TERM: the planted build never started: $(cat "$WORK/term.out")"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
else
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "$rc" = 143 ] || fail "full stopped by TERM: exit $rc, want 143: $(cat "$WORK/term.out")"
  sleep 1.5
  left="$(find "$WORK/sigtmp" -mindepth 1 -maxdepth 1 -name 'frozen-corpus-*')"
  [ -z "$left" ] || fail "full stopped by TERM: its scratch directory was left behind: $left"
fi

if [ -s "$failed" ]; then
  echo "test-frozen-corpus: FAILED" >&2
  exit 1
fi
echo "test-frozen-corpus: ok"
