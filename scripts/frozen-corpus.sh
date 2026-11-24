#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# frozen-corpus.sh — run the frozen v1beta1 documents through an aggrega binary and
# hold each Release to the outcome recorded for it. --help is the contract.
set -uo pipefail
export LC_ALL=C

PROG="frozen-corpus"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
frozen-corpus.sh — run the frozen v1beta1 documents through an aggrega binary and hold
each Release to the outcome recorded for it.

Usage:
  scripts/frozen-corpus.sh record --bin AGGREGA [--corpus DIR] [--jobs N]
  scripts/frozen-corpus.sh fast   --bin AGGREGA [--corpus DIR] [--jobs N]
  scripts/frozen-corpus.sh live   --bin AGGREGA --catalog DIR [--corpus DIR] [--jobs N]
  scripts/frozen-corpus.sh full   --bin AGGREGA [--corpus DIR] [--jobs N]
  scripts/frozen-corpus.sh --help

  --bin AGGREGA  the aggrega binary to judge (a path; required).
  --corpus DIR   the frozen corpus (default: v1beta1 at the root of the repository
                 holding this script).
  --catalog DIR  live only, and required there: the hub catalog the Releases validate
                 against, such as the aggrega-catalog directory of an aggrega-hub
                 checkout. This repository holds no such catalog of its own.
  --jobs N       how many runs go at once (default 4 for validations and for builds).

  The script's own lines begin with "frozen-corpus: "; what it quotes of a run's output
  follows them.

THE CORPUS

  DIR holds the v1beta1 documents of the first published release carrying v1beta1,
  laid out as their repositories are, so every relative path an example uses inside
  these trees resolves:

    aggrega-docs/language-reference/examples/   the examples
    aggrega-docs/scripts/                       the helper scripts the examples run
    aggrega-hub/aggrega-catalog/                the hub catalog of that release
    SOURCE                                      where each tree and the binary come from
    outcomes.tsv                                each Release's recorded outcome

  A Release is every release.yaml and release-*.yaml under the examples; its workspace
  is the directory holding it, written relative to the examples directory (an example,
  or a workspace nested in one, such as import-compose/reviewed).

  outcomes.tsv is a header line, then one line per Release:

    <workspace> TAB <release file> TAB <validate outcome> TAB <build outcome>

  An outcome is one of
    ok          the run exited 0;
    halt:CODE   the run exited non-zero; CODE is the first diagnostic code it printed;
    registry    (validate column) the Release resolves an entity or plugin that no local
                catalog holds, which only a build's registry pull can reach, so no
                validation judges it;
    check.sh    (build column) the example's own check.sh holds the expectations of
                every Release in it, and that script passed.

  The accepted differences are DIR-accepted.tsv beside DIR (v1beta1-accepted.tsv for
  the default corpus), a header line, then one line per accepted difference:

    <workspace> TAB <release file> TAB <tier> TAB <now> TAB <reason>

  <tier> is fast, live or full; <now> is the outcome that tier now meets, written as the
  tier prints it: ok, halt:CODE, or (full, for a Release recorded check.sh) check.sh
  failed (exit N), N the exit status of its example's check.sh. Every Release of such an
  example is judged, and so listed, on its own. A missing file accepts nothing.

EVERY MODE

  copies DIR into a scratch directory, removed on exit, and runs there: no run writes
  into DIR but record's own outcomes.tsv. Stopped by HUP, INT or TERM, the script sends
  TERM to every process its runs started, the binary included, waits up to ten seconds
  for them to end, removes the scratch directory and ends by that same signal, so its
  caller sees the status the signal gives (129, 130, 143).
  Above the copied trees it writes a .aggrega-config.yaml declaring an empty workspace:
  the workspace root that the examples carrying no configuration of their own find by
  walking up.

THE VALIDATION HARNESS (record's validate column, fast, live)

  Per Release: aggrega validate --no-color --release <file> in its workspace, with
  --catalog catalog-<P>/ exactly where the corpus's own aggrega-docs/scripts/build-release.sh
  passes it. The run goes through that script, with AGGREGA_BIN naming a scratch shim that
  turns the script's `aggrega build` into `aggrega validate`, so the catalog choice has
  one home: the script that release shipped.

  Each run starts from an emptied environment (env -i) and is handed PATH; TMPDIR, HOME,
  the XDG directories and DOCKER_CONFIG inside the scratch directory, so no configuration,
  cache or registry login of the caller is read; HTTP_PROXY, HTTPS_PROXY, http_proxy and
  https_proxy naming http://127.0.0.1:9, a loopback port first confirmed closed, with
  NO_PROXY and no_proxy empty, so every request for another host fails at once; and
  AGGREGA_CATALOG_DIRS naming the frozen catalog (live: the hub catalog).

THE BUILD HARNESS (record's build column, full)

  Over a fresh scratch copy, one example at a time per job, the Releases of one example in
  order (they share its dist/). An example with an executable check.sh runs that script,
  and nothing else, with AGGREGA_BIN set; when it passes, each Release in the example is
  recorded check.sh. When it does not, its output is reported and each of its Releases is
  built as below instead. Every other Release runs the corpus's build-release.sh
  --example <workspace> <release file> -- --auto-pull --no-color, the shared helper each
  example's own build-release.sh calls. The environment is the validation harness's with
  no proxy (a build fetches charts and pulls plugins) and AGGREGA_BIN set; DOCKER_CONFIG is
  empty, so a pull runs with no registry login. These halts come from the network or the
  registry rather than from the binary: E0136 (the network could not be reached), E0380
  (the registry answered with a server error) and E0381 (the transfer from the registry
  broke off). A run halting with one of them runs once more; halting with one of them
  again, its Release is left not judged, named with the second run's code. A check.sh
  whose failing output carries one of them likewise runs once more, and carrying one
  again leaves every Release of its example not judged, even when one Release alone met
  it, rather than built one by one.

  full runs the same harness over its own fresh scratch copy, in record's environment:
  every cache, aggrega's included, is the scratch directory's and goes with it on exit,
  so every run fetches each chart and plugin its builds need, and nothing it fetched is
  kept. What differs is what it runs, which follows the recorded build column rather
  than whether a check.sh passes: an example whose Releases are recorded check.sh runs
  its check.sh and nothing else; every other Release is built as above, its example's
  check.sh not run first. A build or check.sh meeting E0136, E0380 or E0381 on both its
  runs is left not judged (exit 2), never counted as a difference; a registry that
  refuses a request (a plugin it does not serve, a login it wants) gives a halt like any
  other. Each line naming a Release left not judged by those halts ends its reason
  with "(the network could not be reached)", the words a caller reads to tell them from
  every other reason: a tier that left Releases not judged by them alone says nothing
  about the binary and can run again once the network can be reached. A build left not
  judged for any other reason, such as one no outcome could be read from (a binary that
  crashes leaves no diagnostic code), does say something about the binary.

MODES

  record  validates every Release with the frozen catalog, marks registry where the halt
          says an entity or plugin is in no local catalog, builds every Release, checks
          that the frozen catalog validates as a whole, and writes DIR/outcomes.tsv, sorted.
  fast    validates the frozen catalog as a whole (it must pass), then every Release whose
          recorded validate outcome is not registry, against the frozen catalog; compares
          with the validate column and the accepted differences of tier fast.
  live    validates the same Releases against the hub catalog (--catalog); compares with
          the validate column and the accepted differences of tier live.
  full    builds every Release through the build harness (as full runs it, above);
          compares with the build column and the accepted differences of tier full.

THE COMPARISON (fast, live, full)

  A Release recorded ok that now halts is a break, whatever DIR-accepted.tsv lists. A
  Release recorded halt:CODE that now passes or halts with another code, and, in full, a
  Release recorded check.sh whose example's check.sh now fails, is a difference unless an
  accepted entry of the tier names the Release with that outcome as <now> (check.sh
  failed (exit N) for the latter). An accepted entry of the tier that no longer matches
  what the Release does is reported as a difference too, so the file holds only what
  happens, and so is an accepted entry of the tier naming a Release recorded registry,
  which fast and live do not judge. A Release in the corpus with no recorded line, a
  recorded line with no Release, or a Release to judge whose run left no result leaves
  the corpus not judged. In full, a Release halting E0136, E0380 or E0381 on both its
  runs, every Release of an example whose check.sh meets one of them on both its runs
  (all of them, though one Release alone may have met it), and a build no outcome could
  be read from, are each named as not judged, and every other Release is still judged.

WHAT FULL DOES NOT JUDGE

  An example with a check.sh and no Release (policy-in-ci) has no recorded line, and full
  does not run it. An example whose check.sh did not pass with the recording binary is
  recorded Release by Release, and full builds those Releases without running its
  check.sh, so what that script asserts beyond each Release's own exit and first code is
  not held. A Release recorded halting because the registry no longer serves a plugin it
  pins halts so with any binary, and is held only to halting with that code. An outcome
  is an exit status and a first diagnostic code: what a build writes is held only where
  an example's check.sh reads it.

EXIT STATUS

  0  record: outcomes.tsv written and every check.sh passed. fast, live, full: every
     judged outcome matched.
  1  record: outcomes.tsv written, and at least one check.sh did not pass (each named,
     with its output; its Releases are recorded build by build). fast, live, full: at
     least one difference, each named with its recorded and actual outcome and its first
     diagnostic lines; full exits 1 so even when another Release was not judged.
  2  not judged: a usage error, a missing input, the proxy's port listening, a Release to
     judge with no result, a run no outcome could be read from, (record, full) a Release or
     a check.sh meeting E0136, E0380 or E0381 on both its runs, or (record) the frozen
     catalog failing to validate as a whole; record then writes nothing.

HOST LOAD

  Four at a time, the validations of the whole corpus peak at about 5 GB together (one
  at about 2 GB at most) and its builds (record's, full's) at about 7 GB together (one at
  about 2.5 GB at most). The script takes no host guard of its own: a caller that limits
  how much heavy work runs at once on its host runs it under that limit.
EOF
}

say() { printf '%s: %s\n' "$PROG" "$*"; }
not_judged() { printf '%s: not judged: %s\n' "$PROG" "$*" >&2; exit 2; }

# --- diagnostic codes ----------------------------------------------------------------
# diag_re CODE — the extended regular expression of a diagnostic code CODE (itself an
# extended regular expression) as the binary writes one: in brackets, after an optional
# class ([E0099], [DEVELOPER_ERROR E0007]). Every search for a code in a log goes through it.
ANY_CODE='E[0-9]{4}'
diag_re() { printf '\\[([A-Z_]+ )?(%s)\\]' "$1"; }

# first_code LOG [CODES] — the first diagnostic code in LOG, or the first one matching
# CODES (an extended regular expression); nothing when there is none.
first_code() {
  grep -oE "$(diag_re "${2:-$ANY_CODE}")" "$1" | head -n 1 | grep -oE "$ANY_CODE"
}

# NETWORK_HALTS — the halts the network or the registry gives rather than the binary,
# each with the words a not-judged line adds after its code (--help, THE BUILD HARNESS):
# the network unreachable, the registry answering with a server error, the transfer from
# the registry broken off. NETWORK_CODES is the same set as an alternation.
declare -A NETWORK_HALTS=(
  [E0136]=""
  [E0380]=", the registry answering with a server error"
  [E0381]=", the transfer from the registry breaking off"
)
NETWORK_CODES="$(IFS='|'; printf '%s' "${!NETWORK_HALTS[*]}")"

# network_halt OUTCOME — true when OUTCOME is halt:CODE for a CODE of NETWORK_HALTS.
network_halt() { [[ "$1" =~ ^halt:($NETWORK_CODES)$ ]]; }

# say_network_unjudged WS REL CODE CHECK_LOG — names a Release left not judged after
# meeting CODE of NETWORK_HALTS on both runs: its own build when CHECK_LOG is empty (with
# its log's first lines), else its example's check.sh, whose log CHECK_LOG is. The line
# ends its reason with "(the network could not be reached)", the words a caller reads to
# tell a network it could not reach from a verdict on the binary (--help, THE BUILD
# HARNESS).
say_network_unjudged() {
  local ws="$1" rel="$2" code="$3" check_log="$4"
  if [ -z "$check_log" ]; then
    say "not judged: $ws/$rel halted $code twice${NETWORK_HALTS[$code]:-} (the network could not be reached):"
    first_lines "$LOGS/b.$(log_name "$ws" "$rel")"
  else
    say "not judged: $ws/$rel: its example's check.sh met $code twice${NETWORK_HALTS[$code]:-} (the network could not be reached):"
    grep -m 1 -A 1 -E "$(diag_re "$NETWORK_CODES")" "$check_log" | cut -c1-400 | sed 's/^/      /'
  fi
}

# --- arguments ---------------------------------------------------------------------
MODE=""
BIN=""
CORPUS="$REPO_ROOT/v1beta1"
CATALOG=""
JOBS=4
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  record|fast|live|full) MODE="$1"; shift ;;
  '') usage >&2; exit 2 ;;
  *) not_judged "unknown mode '$1' (record, fast, live or full; --help for the contract)" ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin) [ "$#" -ge 2 ] || not_judged "--bin needs a path"; BIN="$2"; shift 2 ;;
    --corpus) [ "$#" -ge 2 ] || not_judged "--corpus needs a directory"; CORPUS="$2"; shift 2 ;;
    --catalog) [ "$#" -ge 2 ] || not_judged "--catalog needs a directory"; CATALOG="$2"; shift 2 ;;
    --jobs) [ "$#" -ge 2 ] || not_judged "--jobs needs a number"; JOBS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) not_judged "unknown argument '$1' (--help for the contract)" ;;
  esac
done
[ -n "$BIN" ] || not_judged "--bin is required"
[ -f "$BIN" ] && [ -x "$BIN" ] || not_judged "--bin $BIN is not an executable file"
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
case "$JOBS" in ''|*[!0-9]*|0) not_judged "--jobs takes a whole number above zero, not '$JOBS'" ;; esac
[ -d "$CORPUS" ] || not_judged "no corpus at $CORPUS"
CORPUS="$(cd "$CORPUS" && pwd)"
for tree in aggrega-docs/language-reference/examples aggrega-docs/scripts aggrega-hub/aggrega-catalog; do
  [ -d "$CORPUS/$tree" ] || not_judged "the corpus $CORPUS has no $tree"
done
OUTCOMES="$CORPUS/outcomes.tsv"
ACCEPTED="$CORPUS-accepted.tsv"
if [ "$MODE" = live ]; then
  [ -n "$CATALOG" ] || not_judged "live needs --catalog DIR, the hub catalog the Releases validate against (the aggrega-catalog directory of an aggrega-hub checkout)"
  [ -d "$CATALOG/component" ] || not_judged "no hub catalog at $CATALOG"
  CATALOG="$(cd "$CATALOG" && pwd)"
elif [ -n "$CATALOG" ]; then
  not_judged "--catalog is read by live only: $MODE reads the corpus's own catalog"
fi
if [ "$MODE" != record ]; then
  [ -f "$OUTCOMES" ] || not_judged "the corpus has no outcomes.tsv; record writes it"
fi

# --- the scratch directory -----------------------------------------------------------
# The closed port, its listen check (check_closed_port) and the emptied environment
# run_env hands every run (env -i with PATH; TMPDIR, HOME, the XDG directories and
# DOCKER_CONFIG inside a scratch directory; and, for a validation, HTTP_PROXY,
# HTTPS_PROXY, http_proxy, https_proxy at that port, NO_PROXY and no_proxy empty) keep
# every run off the caller's configuration, caches and registry login, and a validation
# off the network.
CLOSED_PORT=9
PROXY="http://127.0.0.1:$CLOSED_PORT"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/frozen-corpus-XXXXXX")" || not_judged "cannot create a scratch directory"
trap 'rm -rf "$SCRATCH"' EXIT
# on_signal SIG — HUP, INT or TERM (--help, EVERY MODE). Every process the runs
# started, down to the binary, is sent TERM and given ten seconds to end, so none writes
# into the scratch directory after it is removed; then the script ends by SIG itself.
on_signal() {
  local -a roots pids
  local alive p _
  trap - EXIT HUP INT TERM
  mapfile -t roots < <(jobs -p)
  if [ "${#roots[@]}" -gt 0 ]; then
    mapfile -t pids < <(ps -e -o pid=,ppid= | awk -v roots="${roots[*]}" '
      { parent[$1] = $2 }
      END {
        n = split(roots, r, " "); for (i = 1; i <= n; i++) under[r[i]] = 1
        do { added = 0; for (p in parent) if (!(p in under) && (parent[p] in under)) { under[p] = 1; added = 1 } } while (added)
        for (p in under) print p
      }')
    kill -TERM "${pids[@]}" 2>/dev/null
    wait 2>/dev/null
    for _ in $(seq 1 100); do
      alive=0
      for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && { alive=1; break; }; done
      [ "$alive" = 1 ] || break
      sleep 0.1
    done
  fi
  rm -rf "$SCRATCH"
  kill -s "$1" "$$"
}
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
mkdir -p "$SCRATCH/home" "$SCRATCH/docker" "$SCRATCH/tmp" "$SCRATCH/logs" "$SCRATCH/empty"
LOGS="$SCRATCH/logs"

# copy_corpus NAME — a copy of the corpus trees at $SCRATCH/NAME, with the workspace root
# the examples without a configuration of their own find by walking up.
copy_corpus() {
  mkdir -p "$SCRATCH/$1/aggrega-docs/language-reference" "$SCRATCH/$1/aggrega-hub"
  cp -R "$CORPUS/aggrega-docs/language-reference/examples" "$SCRATCH/$1/aggrega-docs/language-reference/" &&
    cp -R "$CORPUS/aggrega-docs/scripts" "$SCRATCH/$1/aggrega-docs/" &&
    cp -R "$CORPUS/aggrega-hub/aggrega-catalog" "$SCRATCH/$1/aggrega-hub/" &&
    printf 'workspace: {}\n' > "$SCRATCH/$1/.aggrega-config.yaml"
}

# run_env PROXY_ON CATALOG_DIRS AGGREGA_BIN COMMAND... — COMMAND in the emptied
# environment --help describes. An empty CATALOG_DIRS or AGGREGA_BIN is left unset.
run_env() {
  local proxy_on="$1" catalogs="$2" aggbin="$3"
  shift 3
  local -a vars=(
    PATH="$PATH" TMPDIR="$SCRATCH/tmp"
    HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/home/.config" XDG_CACHE_HOME="$SCRATCH/home/.cache"
    XDG_DATA_HOME="$SCRATCH/home/.local/share" XDG_STATE_HOME="$SCRATCH/home/.local/state"
    DOCKER_CONFIG="$SCRATCH/docker"
  )
  if [ "$proxy_on" = 1 ]; then
    vars+=(HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY" http_proxy="$PROXY" https_proxy="$PROXY" NO_PROXY= no_proxy=)
  fi
  [ -z "$catalogs" ] || vars+=(AGGREGA_CATALOG_DIRS="$catalogs")
  [ -z "$aggbin" ] || vars+=(AGGREGA_BIN="$aggbin")
  env -i "${vars[@]}" "$@"
}

# outcome_of RC LOG — ok, halt:CODE, or nothing when a non-zero run printed no
# diagnostic code (the caller then leaves the corpus not judged). The code is the first
# one the log carries (first_code).
outcome_of() {
  local code
  if [ "$1" -eq 0 ]; then printf 'ok'; return; fi
  code="$(first_code "$2")"
  [ -z "$code" ] || printf 'halt:%s' "$code"
}

# first_lines LOG — the run's first diagnostic lines, without the helper's own preamble.
first_lines() {
  grep -vE '^(build-release: |# (example|rule|command) +:|$)' "$1" | head -n 8 | cut -c1-400 | sed 's/^/      /'
}

# log_name WORKSPACE RELEASE — a file name for one run's log.
log_name() { printf '%s__%s' "${1//\//__}" "$2"; }

# releases_in DIR — every Release under the examples of DIR, "<workspace> TAB <file>", sorted.
releases_in() {
  (cd "$1/aggrega-docs/language-reference/examples" &&
    find . -type f \( -name release.yaml -o -name 'release-*.yaml' \) | sed 's|^\./||' | sort) |
    awk '{ n = split($0, p, "/"); ws = p[1]; for (i = 2; i < n; i++) ws = ws "/" p[i]; printf "%s\t%s\n", ws, p[n] }' | sort
}

# wait_for_slot — block until fewer than JOBS background runs are going.
wait_for_slot() {
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done
}

# --- the validation harness ----------------------------------------------------------
# validate_all COPY CATALOG_DIRS LIST OUT — validates every Release of LIST (workspace TAB
# file) in COPY, JOBS at a time; OUT gets "<workspace> TAB <file> TAB <rc>" per Release and
# each run's log is LOGS/v.<log name>.
validate_all() {
  local copy="$1" catalogs="$2" list="$3" out="$4" shim="$SCRATCH/validate-shim" ws rel
  # shellcheck disable=SC2016 # the shim's text is written as it is, expanded when the shim runs
  printf '#!/usr/bin/env bash\n# build-release.sh runs `aggrega build ARGS`; this runs `aggrega validate ARGS`.\n[ "${1:-}" = build ] || { printf "frozen-corpus shim: expected build, got %%s\\n" "${1:-nothing}" >&2; exit 2; }\nshift\nexec %q validate "$@"\n' "$BIN" > "$shim"
  chmod +x "$shim"
  : > "$out"
  while IFS=$'\t' read -r ws rel; do
    wait_for_slot
    (
      rc=0
      run_env 1 "$catalogs" "$shim" bash "$copy/aggrega-docs/scripts/build-release.sh" \
        --example "$copy/aggrega-docs/language-reference/examples/$ws" "$rel" -- --no-color \
        > "$LOGS/v.$(log_name "$ws" "$rel")" 2>&1 || rc=$?
      printf '%s\t%s\t%s\n' "$ws" "$rel" "$rc" >> "$out"
    ) &
  done < "$list"
  wait
  check_result_set "$list" "$out" validation
}

# check_result_set LIST OUT WHAT — every Release of LIST (workspace TAB file) must have
# left exactly one line in OUT: a run whose line was lost (a full disk, a killed
# subshell) would otherwise drop out of judgment unseen. WHAT names the runs.
check_result_set() {
  if ! diff <(sort "$1") <(cut -f1,2 "$2" | sort) > "$SCRATCH/result-set"; then
    say "the ${3}s left a result set that differs from the Releases to judge (< no result, > unexpected or repeated):"
    sed -n 's/^\([<>]\)/      \1/p' "$SCRATCH/result-set"
    not_judged "a Release to judge has no $3 result"
  fi
}

# check_closed_port — the proxy's port must refuse connections, or the runs are not kept
# off the network.
check_closed_port() {
  if (exec 3<>"/dev/tcp/127.0.0.1/$CLOSED_PORT") 2>/dev/null; then
    not_judged "something listens on 127.0.0.1:$CLOSED_PORT, the closed port the validations' proxy names, so they would not be kept off the network"
  fi
}

# whole_catalog_validate CATALOG — aggrega validate --catalog CATALOG outside any
# workspace; prints its log path's verdict line and returns its exit status.
whole_catalog_validate() {
  local rc=0
  (cd "$SCRATCH/empty" && run_env 1 "" "" "$BIN" validate --no-color --catalog "$1") > "$LOGS/catalog" 2>&1 || rc=$?
  return "$rc"
}

# registry_halt LOG — true when the halt says the Release reaches an entity or plugin that
# no local catalog holds, which validate does not pull and a build's --auto-pull tries.
# The first diagnostic decides: its code is one of the conditions below AND the log
# carries that condition's message, the text the error reference registers for the code:
#   E0114  unresolvable-uri              "no entity in the catalog matches this URI"
#   E0103  unsatisfiable-entity-version  "no catalog version satisfies the referenced
#                                         version constraint" (a pinned version no local
#                                         catalog carries)
#   E0137  fetch-not-found               "artifact not found at remote source" (a plugin
#                                         neither a local catalog nor the content cache
#                                         holds)
# Every other halt, the documented refusals included, is recorded as halt:CODE.
registry_halt() {
  local code
  code="$(first_code "$1")"
  case "$code" in
    E0114) grep -q 'no entity in the catalog matches this URI' "$1" ;;
    E0103) grep -q 'no catalog version satisfies the referenced version constraint' "$1" ;;
    E0137) grep -q 'artifact not found at remote source' "$1" ;;
    *) return 1 ;;
  esac
}

# --- the build harness ------------------------------------------------------------------
# build_release COPY WORKSPACE FILE — one build through the shared helper; prints its
# outcome, or "unjudged:CODE" after a halt of NETWORK_HALTS on both tries (CODE the
# second's), or nothing when no outcome could be read. The log is LOGS/b.<log name> (the
# first try's, .1, kept on a rerun).
build_release() {
  local copy="$1" ws="$2" rel="$3" log rc outcome try
  log="$LOGS/b.$(log_name "$ws" "$rel")"
  for try in 1 2; do
    rc=0
    run_env 0 "$copy/aggrega-hub/aggrega-catalog" "$BIN" bash "$copy/aggrega-docs/scripts/build-release.sh" \
      --example "$copy/aggrega-docs/language-reference/examples/$ws" "$rel" -- --auto-pull --no-color \
      > "$log" 2>&1 || rc=$?
    outcome="$(outcome_of "$rc" "$log")"
    network_halt "$outcome" || break
    [ "$try" = 2 ] && { printf 'unjudged:%s' "${outcome#halt:}"; return; }
    mv "$log" "$log.1"
  done
  printf '%s' "$outcome"
}

# build_example COPY EXAMPLE RELEASES OUT CHOICE — every Release of one example
# (RELEASES: workspace TAB file, all inside EXAMPLE), in order; appends "<workspace> TAB
# <file> TAB <outcome>" lines to OUT and, when its check.sh does not pass, writes
# LOGS/check.<example>. CHOICE is how the example is run: record (its check.sh when it
# has one, its Releases one by one when it has none or the check does not pass), check
# (its check.sh and nothing else; a check that does not pass makes each Release's outcome
# "check.sh failed (exit N)") or builds (its Releases one by one, its check.sh not run).
build_example() {
  local copy="$1" ex="$2" list="$3" out="$4" choice="$5" dir rc ws rel try network code
  dir="$copy/aggrega-docs/language-reference/examples/$ex"
  if [ "$choice" != builds ] && [ -x "$dir/check.sh" ]; then
    for try in 1 2; do
      rc=0
      network=0
      (cd "$dir" && run_env 0 "$copy/aggrega-hub/aggrega-catalog" "$BIN" ./check.sh) > "$LOGS/c.$ex" 2>&1 || rc=$?
      [ "$rc" -ne 0 ] && grep -qE "$(diag_re "$NETWORK_CODES")" "$LOGS/c.$ex" && network=1
      [ "$network" = 1 ] && [ "$try" = 1 ] || break
      mv "$LOGS/c.$ex" "$LOGS/c.$ex.1"
    done
    if [ "$rc" -eq 0 ]; then
      while IFS=$'\t' read -r ws rel; do printf '%s\t%s\tcheck.sh\n' "$ws" "$rel"; done < "$list" >> "$out"
      return
    fi
    # Two runs that met a halt of NETWORK_HALTS judge nothing: every Release of the
    # example is left not judged, though one alone may have met it, and none is built one
    # by one as a check that fails on its own is.
    if [ "$network" = 1 ]; then
      code="$(first_code "$LOGS/c.$ex" "$NETWORK_CODES")"
      while IFS=$'\t' read -r ws rel; do printf '%s\t%s\tunjudged:%s\n' "$ws" "$rel" "$code"; done < "$list" >> "$out"
      return
    fi
    printf '%s\n' "$rc" > "$LOGS/check.$ex"
    if [ "$choice" = check ]; then
      while IFS=$'\t' read -r ws rel; do printf '%s\t%s\tcheck.sh failed (exit %s)\n' "$ws" "$rel" "$rc"; done < "$list" >> "$out"
      return
    fi
  fi
  while IFS=$'\t' read -r ws rel; do
    printf '%s\t%s\t%s\n' "$ws" "$rel" "$(build_release "$copy" "$ws" "$rel")" >> "$out"
  done < "$list"
}

# --- record --------------------------------------------------------------------------------
record() {
  local t0 t ws rel rc outcome v b n bad=0 failed_checks=0 ex f col
  check_closed_port
  copy_corpus v || not_judged "cannot copy the corpus into $SCRATCH"
  releases_in "$SCRATCH/v" > "$SCRATCH/releases"
  n="$(wc -l < "$SCRATCH/releases")"
  [ "$n" -gt 0 ] || not_judged "the corpus holds no Release"

  t0=$SECONDS
  if ! whole_catalog_validate "$SCRATCH/v/aggrega-hub/aggrega-catalog"; then
    say "the frozen catalog does not validate as a whole with $BIN:"
    head -n 20 "$LOGS/catalog"
    not_judged "a corpus whose catalog the recording binary refuses cannot be recorded"
  fi
  say "the frozen catalog validates as a whole ($((SECONDS - t0))s)"

  t=$SECONDS
  validate_all "$SCRATCH/v" "$SCRATCH/v/aggrega-hub/aggrega-catalog" "$SCRATCH/releases" "$SCRATCH/validated"
  : > "$SCRATCH/vcol"
  while IFS=$'\t' read -r ws rel rc; do
    outcome="$(outcome_of "$rc" "$LOGS/v.$(log_name "$ws" "$rel")")"
    if [ -z "$outcome" ]; then
      say "validate $ws/$rel exited $rc with no diagnostic code:"; first_lines "$LOGS/v.$(log_name "$ws" "$rel")"
      bad=1; continue
    fi
    if [ "$outcome" != ok ] && registry_halt "$LOGS/v.$(log_name "$ws" "$rel")"; then
      say "registry: $ws/$rel ($outcome):"; first_lines "$LOGS/v.$(log_name "$ws" "$rel")" | head -n 3
      outcome=registry
    fi
    printf '%s\t%s\t%s\n' "$ws" "$rel" "$outcome" >> "$SCRATCH/vcol"
  done < "$SCRATCH/validated"
  [ "$bad" -eq 0 ] || not_judged "a validation's outcome could not be read (above); nothing written"
  say "validated $n Releases, $JOBS at a time ($((SECONDS - t))s)"

  t=$SECONDS
  copy_corpus b || not_judged "cannot copy the corpus into $SCRATCH"
  : > "$SCRATCH/bcol"
  {
    cut -f1 "$SCRATCH/releases" | cut -d/ -f1
    (cd "$SCRATCH/b/aggrega-docs/language-reference/examples" && find . -mindepth 2 -maxdepth 2 -name check.sh | cut -d/ -f2)
  } | sort -u > "$SCRATCH/examples"
  while IFS= read -r ex; do
    awk -F'\t' -v ex="$ex" '$1 == ex || index($1, ex "/") == 1' "$SCRATCH/releases" > "$SCRATCH/releases.$ex"
    wait_for_slot
    build_example "$SCRATCH/b" "$ex" "$SCRATCH/releases.$ex" "$SCRATCH/bcol" record &
  done < "$SCRATCH/examples"
  wait
  say "built $n Releases, $JOBS examples at a time ($((SECONDS - t))s)"

  for f in "$LOGS"/check.*; do
    [ -f "$f" ] || continue
    ex="${f##*/check.}"
    failed_checks=$((failed_checks + 1))
    say "check.sh of $ex exited $(cat "$f") with $BIN; its Releases are recorded build by build. Its output:"
    sed 's/^/      /' "$LOGS/c.$ex" | head -n 60
  done

  sort "$SCRATCH/vcol" > "$SCRATCH/vcol.sorted"
  sort "$SCRATCH/bcol" > "$SCRATCH/bcol.sorted"
  if [ "$(cut -f1,2 "$SCRATCH/vcol.sorted")" != "$(cut -f1,2 "$SCRATCH/bcol.sorted")" ]; then
    not_judged "the build column and the validate column name different Releases; nothing written"
  fi
  bad=0
  while IFS=$'\t' read -r ws rel b; do
    case "$b" in
      unjudged:*)
        if [ -f "$LOGS/b.$(log_name "$ws" "$rel")" ]; then
          say_network_unjudged "$ws" "$rel" "${b#unjudged:}" ""
        else
          say_network_unjudged "$ws" "$rel" "${b#unjudged:}" "$LOGS/c.${ws%%/*}"
        fi
        bad=1 ;;
      '')
        say "not judged: no outcome could be read from the build of $ws/$rel:"
        first_lines "$LOGS/b.$(log_name "$ws" "$rel")"; bad=1 ;;
    esac
  done < "$SCRATCH/bcol.sorted"
  [ "$bad" -eq 0 ] || not_judged "a build was not judged (above); nothing written"

  {
    printf 'workspace\trelease\tvalidate\tbuild\n'
    paste "$SCRATCH/vcol.sorted" <(cut -f3 "$SCRATCH/bcol.sorted")
  } > "$OUTCOMES"
  say "wrote $OUTCOMES: $n Releases"
  for v in validate build; do
    if [ "$v" = validate ]; then col=3; else col=4; fi
    printf '  %s:' "$v"
    tail -n +2 "$OUTCOMES" | cut -f"$col" | sed 's/^halt:.*/halt/' | sort | uniq -c | awk '{ printf " %s %s", $2, $1 } END { printf "\n" }'
  done
  [ "$failed_checks" -eq 0 ] || exit 1
  exit 0
}

# --- fast and live -------------------------------------------------------------------------
# read_outcomes — the recorded lines, checked against the Releases the corpus holds.
read_outcomes() {
  local copy="$1"
  tail -n +2 "$OUTCOMES" > "$SCRATCH/recorded"
  if awk -F'\t' 'NF != 4 || $3 == "" || $4 == "" { bad = 1 } END { exit !bad }' "$SCRATCH/recorded"; then
    not_judged "$OUTCOMES has a line without four fields"
  fi
  releases_in "$copy" > "$SCRATCH/releases"
  if ! diff <(cut -f1,2 "$SCRATCH/recorded" | sort) "$SCRATCH/releases" > "$SCRATCH/set-diff"; then
    say "the Releases of the corpus and the lines of $OUTCOMES differ (< recorded only, > in the corpus only):"
    sed 's/^/      /' "$SCRATCH/set-diff"
    not_judged "outcomes.tsv does not describe the corpus"
  fi
}

# read_accepted TIER — the accepted entries of TIER, "<workspace> TAB <file> TAB <now>".
read_accepted() {
  : > "$SCRATCH/accepted"
  [ -f "$ACCEPTED" ] || { say "no $ACCEPTED: no difference is accepted"; return; }
  if tail -n +2 "$ACCEPTED" | awk -F'\t' 'NF != 5 || $5 == "" || ($3 != "fast" && $3 != "live" && $3 != "full") { bad = 1 } END { exit !bad }'; then
    not_judged "$ACCEPTED has a line that is not <workspace> TAB <release> TAB fast|live|full TAB <now> TAB <reason>"
  fi
  if tail -n +2 "$ACCEPTED" | cut -f1-3 | sort | uniq -d | grep -q .; then
    not_judged "$ACCEPTED lists one Release twice for one tier"
  fi
  tail -n +2 "$ACCEPTED" | awk -F'\t' -v tier="$1" 'BEGIN { OFS = "\t" } $3 == tier { print $1, $2, $4 }' > "$SCRATCH/accepted"
  if [ -s "$SCRATCH/accepted" ] && ! awk -F'\t' 'NR == FNR { r[$1 FS $2] = 1; next } !(($1 FS $2) in r) { bad = 1; print "      " $1 "/" $2 } END { exit bad }' \
    "$SCRATCH/recorded" "$SCRATCH/accepted"; then
    not_judged "$ACCEPTED names a Release (above) that outcomes.tsv does not"
  fi
}

# judge TIER WS REL RECORDED ACTUAL LOG — one Release's comparison, as --help's THE
# COMPARISON states it, against the accepted entries read_accepted wrote: says what it
# finds, with LOG's first diagnostic lines (each log once) for a break or a difference,
# and returns 1 when the Release counts as a difference. VERB names what a Release
# recorded ok did with the recording binary (validated, built).
declare -A EXCERPTED=()
VERB=validated
judge() {
  local tier="$1" ws="$2" rel="$3" recorded="$4" actual="$5" log="$6" now
  now="$(awk -F'\t' -v ws="$ws" -v rel="$rel" '$1 == ws && $2 == rel { print $3 }' "$SCRATCH/accepted")"
  if [ "$actual" = "$recorded" ]; then
    [ -n "$now" ] || return 0
    say "DIFFERENCE $ws/$rel: the accepted difference ($tier: now $now) no longer occurs; it meets its recorded $recorded again. Remove the entry."
    return 1
  fi
  # A Release recorded ok that now halts is the one outcome no entry admits; a recorded
  # halt that now passes or halts otherwise, and a recorded check.sh whose check now fails
  # (actual "check.sh failed (exit N)"), are admitted by an entry naming that outcome.
  if [ "$recorded" = ok ]; then
    say "BREAK $ws/$rel: recorded ok, now $actual${now:+ (an accepted entry cannot admit a Release that $VERB and now halts)}"
    excerpt "$log"
    return 1
  fi
  if [ -n "$now" ] && [ "$now" = "$actual" ]; then
    say "accepted $ws/$rel: recorded $recorded, now $actual ($tier)"
    return 0
  fi
  say "DIFFERENCE $ws/$rel: recorded $recorded, now $actual${now:+ (the accepted entry says $now)}"
  excerpt "$log"
  return 1
}

# excerpt LOG — first_lines of LOG, once per log: the Releases of one check.sh share its.
excerpt() {
  [ -z "${EXCERPTED[$1]:-}" ] || { printf '      (output above)\n'; return; }
  EXCERPTED[$1]=1
  first_lines "$1"
}

compare() {
  local tier="$1" copy="$2" catalogs="$3" t ws rel rc recorded actual now n=0 differ=0 log
  read_outcomes "$copy"
  read_accepted "$tier"
  awk -F'\t' 'BEGIN { OFS = "\t" } $3 != "registry" { print $1, $2 }' "$SCRATCH/recorded" > "$SCRATCH/to-judge"
  say "$tier: validating against the catalog $catalogs"
  t=$SECONDS
  validate_all "$copy" "$catalogs" "$SCRATCH/to-judge" "$SCRATCH/validated"
  sort "$SCRATCH/validated" > "$SCRATCH/validated.sorted"
  while IFS=$'\t' read -r ws rel rc; do
    n=$((n + 1))
    log="$LOGS/v.$(log_name "$ws" "$rel")"
    actual="$(outcome_of "$rc" "$log")"
    if [ -z "$actual" ]; then
      say "validate $ws/$rel exited $rc with no diagnostic code:"; first_lines "$log"
      not_judged "a validation's outcome could not be read"
    fi
    recorded="$(awk -F'\t' -v ws="$ws" -v rel="$rel" '$1 == ws && $2 == rel { print $3 }' "$SCRATCH/recorded")"
    judge "$tier" "$ws" "$rel" "$recorded" "$actual" "$log" || differ=$((differ + 1))
  done < "$SCRATCH/validated.sorted"
  while IFS=$'\t' read -r ws rel now; do
    differ=$((differ + 1))
    say "DIFFERENCE $ws/$rel: an accepted entry ($tier: now $now) names a Release recorded registry, which $tier does not judge. Remove the entry."
  done < <(awk -F'\t' 'BEGIN { OFS = "\t" } NR == FNR { if ($3 == "registry") r[$1 FS $2] = 1; next } ($1 FS $2) in r { print $1, $2, $3 }' \
    "$SCRATCH/recorded" "$SCRATCH/accepted")
  say "$tier: $n Releases validated with $BIN, $JOBS at a time ($((SECONDS - t))s); $(awk -F'\t' '$3 == "registry"' "$SCRATCH/recorded" | wc -l) recorded registry not judged here; $differ difference(s)"
  [ "$differ" -eq 0 ] || exit 1
  exit 0
}

# --- full ------------------------------------------------------------------------------------
# full — every Release through the build harness, as the recorded build column says each
# example was run, compared with that column (--help, MODES and THE COMPARISON).
full() {
  local t ws rel recorded actual log ex choices n=0 differ=0 unjudged=0
  copy_corpus b || not_judged "cannot copy the corpus into $SCRATCH"
  read_outcomes "$SCRATCH/b"
  read_accepted full
  VERB=built
  cut -f1 "$SCRATCH/recorded" | cut -d/ -f1 | sort -u > "$SCRATCH/examples"
  : > "$SCRATCH/runs"
  while IFS= read -r ex; do
    awk -F'\t' -v ex="$ex" '$1 == ex || index($1, ex "/") == 1' "$SCRATCH/releases" > "$SCRATCH/releases.$ex"
    choices="$(awk -F'\t' -v ex="$ex" '$1 == ex || index($1, ex "/") == 1 { print ($4 == "check.sh" ? "check" : "builds") }' "$SCRATCH/recorded" | sort -u)"
    case "$choices" in
      check)
        [ -x "$SCRATCH/b/aggrega-docs/language-reference/examples/$ex/check.sh" ] \
          || not_judged "outcomes.tsv records check.sh for the Releases of $ex, and $ex has no executable check.sh" ;;
      builds) ;;
      *) not_judged "outcomes.tsv records check.sh for some Releases of $ex and not for others" ;;
    esac
    printf '%s\t%s\n' "$ex" "$choices" >> "$SCRATCH/runs"
  done < "$SCRATCH/examples"
  say "full: building $(wc -l < "$SCRATCH/releases") Releases of $(wc -l < "$SCRATCH/runs") examples with $BIN"
  t=$SECONDS
  : > "$SCRATCH/built"
  while IFS=$'\t' read -r ex choices; do
    wait_for_slot
    build_example "$SCRATCH/b" "$ex" "$SCRATCH/releases.$ex" "$SCRATCH/built" "$choices" &
  done < "$SCRATCH/runs"
  wait
  check_result_set "$SCRATCH/releases" "$SCRATCH/built" build
  sort "$SCRATCH/built" > "$SCRATCH/built.sorted"
  while IFS=$'\t' read -r ws rel actual; do
    n=$((n + 1))
    recorded="$(awk -F'\t' -v ws="$ws" -v rel="$rel" '$1 == ws && $2 == rel { print $4 }' "$SCRATCH/recorded")"
    if [ "$recorded" = check.sh ]; then log="$LOGS/c.${ws%%/*}"; else log="$LOGS/b.$(log_name "$ws" "$rel")"; fi
    case "$actual" in
      unjudged:*)
        unjudged=$((unjudged + 1))
        if [ "$recorded" = check.sh ]; then
          say_network_unjudged "$ws" "$rel" "${actual#unjudged:}" "$log"
        else
          say_network_unjudged "$ws" "$rel" "${actual#unjudged:}" ""
        fi
        continue ;;
      '')
        unjudged=$((unjudged + 1))
        say "not judged: no outcome could be read from the build of $ws/$rel:"
        first_lines "$log"
        continue ;;
    esac
    judge full "$ws" "$rel" "$recorded" "$actual" "$log" || differ=$((differ + 1))
  done < "$SCRATCH/built.sorted"
  say "full: $n Releases built with $BIN, $JOBS examples at a time ($((SECONDS - t))s); $differ difference(s), $unjudged not judged"
  [ "$differ" -eq 0 ] || exit 1
  [ "$unjudged" -eq 0 ] || exit 2
  exit 0
}

case "$MODE" in
  record) record ;;
  fast)
    check_closed_port
    copy_corpus c || not_judged "cannot copy the corpus into $SCRATCH"
    t0=$SECONDS
    if ! whole_catalog_validate "$SCRATCH/c/aggrega-hub/aggrega-catalog"; then
      say "BREAK the frozen catalog does not validate as a whole with $BIN:"
      head -n 20 "$LOGS/catalog" | sed 's/^/      /'
      exit 1
    fi
    say "the frozen catalog validates as a whole ($((SECONDS - t0))s)"
    compare fast "$SCRATCH/c" "$SCRATCH/c/aggrega-hub/aggrega-catalog"
    ;;
  live)
    check_closed_port
    copy_corpus c || not_judged "cannot copy the corpus into $SCRATCH"
    compare live "$SCRATCH/c" "$CATALOG"
    ;;
  full) full ;;
esac
