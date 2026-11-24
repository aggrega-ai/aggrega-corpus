#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# check-frozen-corpus.sh — refuse any change to a frozen directory of this repository.
#
# A frozen directory holds the documents of a past release exactly as that release
# shipped them (v1beta1/ holds the v1beta1 documents), copied once and never edited.
# Git names the content of a directory by one tree id, so "unchanged" is one
# comparison: the tree id of the directory in the judged state against the id recorded
# for it in frozen-trees, one `<directory> <tree id>` line per frozen directory. A new
# frozen version goes into a new directory with its own line.
#
# The contract — modes, exit codes — is --help, printed from usage() below.
set -uo pipefail

PROG="check-frozen-corpus"
TREES_FILE="frozen-trees"

usage() {
  cat <<'USAGE'
usage: scripts/check-frozen-corpus.sh (--staged | --rev REV) [--trees FILE]

Refuses a change to a frozen directory, naming each path that differs. A frozen
directory is a directory at the root of the repository whose name is an API version:
v followed by a digit, as in v1beta1. Run it from inside the repository to judge; it
reads the recorded tree ids from frozen-trees at the root there, one
`<directory> <tree id>` line each (a line starting with # is a comment).

MODES
  --staged   The index: the tree id of each frozen directory as the next commit
             would hold it (git write-tree --prefix) against the recorded id. The
             recorded ids are read from the index too, so the commit that adds a
             frozen directory passes when it records that directory's id.
  --rev REV  The revision REV: the tree id of each frozen directory in REV against the
             id recorded in REV, and the working tree under each frozen directory
             must print nothing for
             git status --porcelain --ignored --untracked-files=all
             (--ignored because a frozen tree carries .gitignore files of its own,
             under which an added file would otherwise stay invisible).

  --trees FILE  Reads the recorded ids from FILE, a path on disk, instead of from
             frozen-trees in the judged state. FILE has frozen-trees' form. A change
             made to a frozen directory and to frozen-trees together passes a check
             that reads frozen-trees; a consumer that must notice it keeps its own copy
             of the ids and names it here.

A frozen directory present in the judged state with no recorded id is not judged.

EXIT STATUS
  0  every frozen directory equals its recorded tree id
  1  a frozen directory differs; each differing path is named
  2  the judgement could not be made (no trees file, no recorded id for a frozen
     directory, not a git checkout, unknown revision, bad usage)
USAGE
}

die_unjudged() {
  echo "$PROG: cannot judge: $*" >&2
  exit 2
}

mode=""
rev=""
trees_from=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --staged) mode=staged; shift ;;
    --rev)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      mode=rev; rev="$2"; shift 2 ;;
    --trees)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      trees_from="$2"; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ -n "$mode" ] || { usage >&2; exit 2; }
if [ -n "$trees_from" ]; then
  [ -f "$trees_from" ] && [ -r "$trees_from" ] || die_unjudged "no readable trees file at $trees_from"
  trees_from="$(cd "$(dirname "$trees_from")" && pwd)/$(basename "$trees_from")"
fi

top="$(git rev-parse --show-toplevel 2>/dev/null)" || die_unjudged "not inside a git checkout"
cd "$top" || die_unjudged "cannot enter $top"

if [ "$mode" = rev ]; then
  git rev-parse --verify -q "$rev^{commit}" >/dev/null || die_unjudged "unknown revision $rev"
fi
if [ -n "$trees_from" ]; then
  TREES_FILE="$trees_from"
  trees="$(cat "$trees_from")" || die_unjudged "cannot read $trees_from"
elif [ "$mode" = rev ]; then
  trees="$(git show "$rev:$TREES_FILE" 2>/dev/null)" || die_unjudged "$rev has no $TREES_FILE"
else
  trees="$(git show ":$TREES_FILE" 2>/dev/null)" || die_unjudged "the index has no $TREES_FILE"
fi

declare -A recorded=()
while read -r dir id extra; do
  [ -n "$dir" ] || continue
  case "$dir" in \#*) continue ;; esac
  [ -n "$id" ] && [ -z "$extra" ] || die_unjudged "malformed line in $TREES_FILE: $dir $id $extra"
  recorded["${dir%/}"]="$id"
done <<< "$trees"
[ "${#recorded[@]}" -gt 0 ] || die_unjudged "$TREES_FILE records no frozen directory"

# The frozen directories present in the judged state, so one with no recorded id is
# noticed rather than passed over.
if [ "$mode" = rev ]; then
  present="$(git -c core.quotepath=off ls-tree -d --name-only "$rev" 2>/dev/null | grep -E '^v[0-9]')"
else
  present="$(git -c core.quotepath=off ls-files --cached | awk -F/ 'NF >= 2 && $1 ~ /^v[0-9]/ { print $1 }' | sort -u)"
fi
while read -r dir; do
  [ -n "$dir" ] || continue
  [ -n "${recorded[$dir]+x}" ] || die_unjudged "$dir has no recorded tree id in $TREES_FILE"
done <<< "$present"

empty_tree="$(git hash-object -t tree /dev/null)"
refused=0
for dir in "${!recorded[@]}"; do
  want="${recorded[$dir]}"
  git cat-file -e "$want^{tree}" 2>/dev/null || die_unjudged "the recorded tree $want of $dir is not in this repository"
  if [ "$mode" = rev ]; then
    got="$(git rev-parse --verify -q "$rev:$dir" 2>/dev/null)" || got="$empty_tree"
  else
    if ! got="$(git write-tree --prefix="$dir/" 2>/dev/null)"; then
      # write-tree refuses a prefix the index holds nothing under, which is a removed
      # directory; any other refusal (an unmerged index, say) leaves nothing judged.
      [ -z "$(git ls-files --cached --unmerged -- "$dir")" ] || die_unjudged "the index cannot be written as a tree (unmerged paths under $dir?)"
      got="$empty_tree"
    fi
  fi
  if [ "$got" != "$want" ]; then
    refused=1
    echo "$PROG: $dir differs from the recorded tree $want:"
    git -c core.quotepath=off diff --no-renames --name-status "$want" "$got" | sed "s#\t#\t$dir/#; s/^/  /"
  fi
  if [ "$mode" = rev ]; then
    dirty="$(git status --porcelain --ignored --untracked-files=all -- "$dir")"
    if [ -n "$dirty" ]; then
      refused=1
      echo "$PROG: the working tree under $dir differs from $rev:"
      echo "$dirty" | sed 's/^/  /'
    fi
  fi
done

if [ "$refused" = 1 ]; then
  echo "A frozen directory is never edited: a new frozen version goes into a new directory."
  exit 1
fi
exit 0
