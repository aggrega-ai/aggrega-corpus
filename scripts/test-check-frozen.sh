#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# scripts/test-check-frozen.sh — plants one fault at a time in a throwaway repository
# and shows that scripts/check-frozen.sh refuses each, naming the path, and passes the
# clean state. It fails whenever an expected refusal is not reported. Hermetic:
# everything lives under one mktemp directory, removed on exit.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="${CHECK_FROZEN_CORPUS:-$SCRIPT_DIR/check-frozen.sh}"
TREES=frozen-trees

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# Cases run in subshells, so a failure is recorded as a line in a file.
failed="$WORK/failed"
: > "$failed"
fail() { echo "FAIL: $*" >&2; echo x >> "$failed"; }

# base: a repository whose v1beta1/ is committed and recorded, the corpus carrying a
# .gitignore of its own that ignores *.ignored, beside a scripts/ directory that is not
# frozen. A copy of the record kept outside the repository (the --trees file) holds the
# same line.
base="$WORK/base"
git init -q "$base"
(
  cd "$base" || exit 1
  mkdir -p v1beta1/sub scripts
  echo one > v1beta1/a.txt
  echo two > v1beta1/sub/b.txt
  echo '*.ignored' > v1beta1/.gitignore
  echo 'echo run' > scripts/run.sh
  git add -A && git commit -q -m corpus
  printf '# comment line\nv1beta1 %s\n' "$(git rev-parse HEAD:v1beta1)" > "$TREES"
  git add -A && git commit -q -m record
) || { echo "FAIL: cannot build the base repository" >&2; exit 1; }
outside="$WORK/outside-trees"
cp "$base/$TREES" "$outside"

# fresh: copy the base into a new repository and print its path.
fresh() { local d; d="$(mktemp -d "$WORK/r.XXXXXX")" && cp -R "$base/." "$d" && echo "$d"; }

# expect NAME WANT_EXIT NEEDLE ARGS... — runs the check in the current directory.
expect() {
  local name="$1" want="$2" needle="$3" out rc=0
  shift 3
  out="$(bash "$CHECK" "$@" 2>&1)" || rc=$?
  if [ "$rc" != "$want" ]; then
    fail "$name: exit $rc, want $want: $out"
  elif [ -n "$needle" ] && ! grep -qF -- "$needle" <<< "$out"; then
    fail "$name: output does not name $needle: $out"
  fi
}

commit_all() { git add -A && git commit -q -m change; }

# --- clean ---------------------------------------------------------------
( cd "$(fresh)" && expect "rev clean" 0 "" --rev HEAD )
( cd "$(fresh)" && expect "staged clean" 0 "" --staged )

# --- one fault each, in --rev mode: committed ----------------------------
( cd "$(fresh)" && echo x >> v1beta1/a.txt && commit_all \
    && expect "rev committed modified" 1 "v1beta1/a.txt" --rev HEAD )
( cd "$(fresh)" && git rm -q v1beta1/sub/b.txt && git commit -q -m change \
    && expect "rev committed deleted" 1 "v1beta1/sub/b.txt" --rev HEAD )
( cd "$(fresh)" && echo x > v1beta1/c.txt && commit_all \
    && expect "rev committed added" 1 "v1beta1/c.txt" --rev HEAD )
( cd "$(fresh)" && git rm -rq v1beta1 && git commit -q -m change \
    && expect "rev committed directory removed" 1 "v1beta1/a.txt" --rev HEAD )

# --- one fault each, in --rev mode: working tree only --------------------
( cd "$(fresh)" && echo x >> v1beta1/a.txt \
    && expect "rev worktree modified" 1 "v1beta1/a.txt" --rev HEAD )
( cd "$(fresh)" && rm v1beta1/a.txt \
    && expect "rev worktree deleted" 1 "v1beta1/a.txt" --rev HEAD )
( cd "$(fresh)" && echo x > v1beta1/untracked.txt \
    && expect "rev worktree untracked" 1 "v1beta1/untracked.txt" --rev HEAD )
( cd "$(fresh)" && echo x > v1beta1/hidden.ignored \
    && expect "rev worktree ignored by the corpus' own .gitignore" 1 "v1beta1/hidden.ignored" --rev HEAD )
( cd "$(fresh)" && mkdir v1beta1/sub/dist && echo x > v1beta1/sub/dist/out.ignored \
    && expect "rev worktree ignored in a subdirectory" 1 "v1beta1/sub/dist/out.ignored" --rev HEAD )

# --- one fault each, in --staged mode ------------------------------------
( cd "$(fresh)" && echo x >> v1beta1/a.txt && git add v1beta1 \
    && expect "staged modified" 1 "v1beta1/a.txt" --staged )
( cd "$(fresh)" && git rm -q v1beta1/sub/b.txt \
    && expect "staged deleted" 1 "v1beta1/sub/b.txt" --staged )
( cd "$(fresh)" && echo x > v1beta1/c.txt && git add v1beta1 \
    && expect "staged added" 1 "v1beta1/c.txt" --staged )
( cd "$(fresh)" && echo x > v1beta1/forced.ignored && git add -f v1beta1 \
    && expect "staged added past the corpus' own .gitignore" 1 "v1beta1/forced.ignored" --staged )
( cd "$(fresh)" && git rm -rq v1beta1 \
    && expect "staged directory removed" 1 "v1beta1/a.txt" --staged )
# A change that is not staged is not part of the commit: --staged judges the index.
( cd "$(fresh)" && echo x >> v1beta1/a.txt \
    && expect "staged ignores an unstaged edit" 0 "" --staged )
# The refusal says where a new version goes.
( cd "$(fresh)" && echo x >> v1beta1/a.txt && git add v1beta1 \
    && expect "staged refusal teaches" 1 "a new frozen version goes into a new directory" --staged )

# The commit that adds a frozen directory passes when it records that directory's id.
(
  cd "$(fresh)" || exit 1
  mkdir v1beta2 && echo n > v1beta2/d.txt && git add v1beta2
  expect "staged new directory without a recorded id" 2 "v1beta2" --staged
  printf 'v1beta2 %s\n' "$(git write-tree --prefix=v1beta2/)" >> "$TREES"
  git add "$TREES"
  expect "staged new directory with its id recorded in the same change" 0 "" --staged
)
( cd "$(fresh)" && mkdir v1beta2 && echo n > v1beta2/d.txt && commit_all \
    && expect "rev new directory without a recorded id" 2 "v1beta2 has no recorded tree id" --rev HEAD )

# An index that cannot be written as a tree is not judged, and is not reported as a difference.
(
  cd "$(fresh)" || exit 1
  git checkout -q -b side && echo s > v1beta1/a.txt && commit_all
  git checkout -q - && echo m > v1beta1/a.txt && commit_all
  git merge -q side >/dev/null 2>&1
  expect "staged unmerged index" 2 "cannot judge" --staged
)

# A change outside the frozen directories is not the check's to judge.
( cd "$(fresh)" && echo 'echo other' > scripts/run.sh && commit_all \
    && expect "rev change outside the frozen directories" 0 "" --rev HEAD )
( cd "$(fresh)" && echo 'echo other' > scripts/run.sh && git add scripts \
    && expect "staged change outside the frozen directories" 0 "" --staged )

# --- the record read from a file outside the repository (--trees) -------
( cd "$(fresh)" && expect "rev clean, trees from outside" 0 "" --rev HEAD --trees "$outside" )
( cd "$(fresh)" && expect "staged clean, trees from outside" 0 "" --staged --trees "$outside" )
# A change to the corpus and to its in-repository record together passes a check that
# reads that record, and is refused by one that reads the copy kept outside.
(
  cd "$(fresh)" || exit 1
  echo x >> v1beta1/a.txt && git add v1beta1
  printf 'v1beta1 %s\n' "$(git write-tree --prefix=v1beta1/)" > "$TREES" && git add "$TREES"
  expect "staged corpus and record changed together" 0 "" --staged
  expect "staged corpus and record changed together, trees from outside" 1 "v1beta1/a.txt" --staged --trees "$outside"
  git commit -q -m change
  expect "rev corpus and record changed together" 0 "" --rev HEAD
  expect "rev corpus and record changed together, trees from outside" 1 "v1beta1/a.txt" --rev HEAD --trees "$outside"
)
# A frozen directory the outside copy does not record is not judged, though the
# in-repository record names it.
(
  cd "$(fresh)" || exit 1
  mkdir v1beta2 && echo n > v1beta2/d.txt && git add v1beta2
  printf 'v1beta2 %s\n' "$(git write-tree --prefix=v1beta2/)" >> "$TREES" && git add "$TREES"
  expect "staged new directory recorded in the repository only, trees from outside" 2 "v1beta2 has no recorded tree id" --staged --trees "$outside"
)
( cd "$(fresh)" && expect "trees file missing" 2 "no readable trees file" --rev HEAD --trees "$WORK/no-such-file" )
( cd "$(fresh)" && expect "trees without a file" 2 "usage" --rev HEAD --trees )

# --- cannot judge ---------------------------------------------------------
( cd "$(fresh)" && git rm -q "$TREES" \
    && expect "staged without a trees file" 2 "$TREES" --staged )
( cd "$(fresh)" && git rm -q "$TREES" && git commit -q -m change \
    && expect "rev without a trees file" 2 "$TREES" --rev HEAD )
( cd "$(fresh)" && expect "rev unknown revision" 2 "no-such-revision" --rev no-such-revision )
( cd "$WORK" && mkdir -p plain && cd plain && expect "not a git checkout" 2 "git checkout" --staged )

failures="$(wc -l < "$failed")"
if [ "$failures" -gt 0 ]; then
  echo "test-check-frozen: $failures failure(s)" >&2
  exit 1
fi
echo "test-check-frozen: ok"
