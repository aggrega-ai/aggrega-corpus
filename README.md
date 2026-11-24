# aggrega-corpus

The frozen corpus of Aggrega: the documents of a published release, kept exactly as that release shipped
them, with the outcome each Release met when that release's own binary built it. A later `aggrega` binary is
run over the same documents and held to those outcomes, so a release that still carries an API version still
reads what authors wrote against it.

`v1beta1/` holds the documents of the first published release carrying the `aggrega.ai/v1beta1` API version:
aggrega-cli `v0.9.0-rc.2`, whose binary pins aggrega-schemas `v0.13.0`, the first schemas release with
v1beta1 schema files.

## What is in it

```
v1beta1/                 the frozen v1beta1 documents, never edited
  SOURCE                 where each tree and the recording binary come from
  outcomes.tsv           each Release's recorded validate and build outcome
  aggrega-docs/          language-reference/examples/ and scripts/ of aggrega-docs
  aggrega-hub/           aggrega-catalog/ of aggrega-hub
v1beta1-accepted.tsv     the differences a later binary is allowed, per tier (header only: none)
frozen-trees             the git tree id of each frozen directory
scripts/run.sh           runs the corpus through a binary: record, fast, live, full
scripts/check-frozen.sh  refuses any change to a frozen directory
scripts/test-run.sh, scripts/test-check-frozen.sh   self-tests of the two scripts
.github/workflows/       the checks this repository runs
```

The trees are laid out as their repositories are, so every relative path an example uses resolves inside
them.

## Where each tree comes from

Each tree is `git archive` of a public repository at the revision named, byte for byte: what was committed,
nothing a build wrote. `v1beta1/SOURCE` states the same, with the binary's version line.

| Tree | Repository | Revision |
|---|---|---|
| `v1beta1/aggrega-docs/language-reference/examples/` | [aggrega-ai/aggrega-docs](https://github.com/aggrega-ai/aggrega-docs) | tag `v0.9.0-rc.2`, `d1c5b87cf1217b218d8bc5f7c4418fb99d584a85`, path `language-reference/examples` |
| `v1beta1/aggrega-docs/scripts/` | [aggrega-ai/aggrega-docs](https://github.com/aggrega-ai/aggrega-docs) | tag `v0.9.0-rc.2`, `d1c5b87cf1217b218d8bc5f7c4418fb99d584a85`, path `scripts` |
| `v1beta1/aggrega-hub/aggrega-catalog/` | [aggrega-ai/aggrega-hub](https://github.com/aggrega-ai/aggrega-hub) | `2e90f55fc584e20c08473b0a7c7d6b0fb4dd5f29` on `main`, path `aggrega-catalog`: the catalog the hub published for that release |
| `v1beta1/outcomes.tsv` | recorded by `scripts/run.sh record` with the asset `aggrega-0.9.0-rc.2-linux-amd64` of the [GitHub release `v0.9.0-rc.2`](https://github.com/aggrega-ai/aggrega-cli/releases/tag/v0.9.0-rc.2) of aggrega-cli | SHA-256 `267c2edebf9c637b787a66a5983c643fb0800b08286a191a6083c372e249ee76`, checked against that release's `SHA256SUMS` |

`v1beta1-accepted.tsv` and `frozen-trees` are data written for this corpus. Everything here is licensed
Apache-2.0, as both source repositories are.

## Running it

Every mode takes the binary to judge with `--bin`. The script copies the corpus into a scratch directory,
removed on exit, and runs there, so no mode but `record` writes into the corpus. Each run starts from an
emptied environment: no configuration, cache or registry login of the caller is read. `scripts/run.sh --help`
is the full contract: the harnesses, the comparison, what a tier does not judge, and the exit statuses.

It needs bash, git and the usual POSIX tools. It limits nothing on the host itself: run four at a time (the
default `--jobs 4`), the validations peak at about 5 GB of memory together and the builds at about 7 GB.

```sh
# fast: the frozen catalog validates as a whole, then every Release validates against it
# as recorded. No network: every run goes through a proxy at a closed loopback port.
scripts/run.sh fast --bin /path/to/aggrega

# live: the same Releases against today's hub catalog, from a checkout of aggrega-hub.
git clone --depth 1 https://github.com/aggrega-ai/aggrega-hub.git /tmp/aggrega-hub
scripts/run.sh live --bin /path/to/aggrega --catalog /tmp/aggrega-hub/aggrega-catalog

# full: every Release built as recorded, with the network open and no registry login.
# Each build fetches the charts and plugins it needs and keeps none of them.
scripts/run.sh full --bin /path/to/aggrega
```

The exit status is `0` when every judged outcome matched, `1` when at least one differs (each named with its
recorded and actual outcome), and `2` when the corpus could not be judged. A Release recorded `ok` that now
halts is a break, and no accepted difference admits it. A Release recorded as a halt that now passes or
halts with another code is a difference unless `v1beta1-accepted.tsv` lists it for that tier with that
outcome. In `full`, three halts come from the network or the registry rather than the binary (E0136, E0380,
E0381); a build meeting one twice is named as not judged, its line ending with "(the network could not be
reached)".

`record` writes `outcomes.tsv` for a new frozen directory; the outcomes of `v1beta1/` are recorded and stay
as they are.

## Keeping the corpus unchanged

`frozen-trees` records the git tree id of each frozen directory:

```
v1beta1 11a8d3dd51ab024a32ddc606a1caf97930208492
```

`scripts/check-frozen.sh --rev HEAD` holds each frozen directory of a commit, and the working tree under it,
to that id; `--staged` holds the index to it, for a pre-commit check. A difference is refused with every
differing path named. A frozen directory is never edited: the documents of a later API version go into a
new directory with a line of its own. A consumer that must notice a change made to a directory and to
`frozen-trees` together keeps its own copy of the ids and passes it with `--trees FILE`.

## Self-tests

```sh
scripts/test-run.sh            # plants each fault in a tiny scratch corpus with a stub binary; offline
scripts/test-check-frozen.sh   # plants each fault in a throwaway repository
```

Each prints its name and `ok` and exits 0, or names every expected refusal it did not see and exits 1.

## Checks this repository runs

- **Guard** (`.github/workflows/guard.yml`), on every push to `main` and every pull request:
  `scripts/check-frozen.sh --rev HEAD` and both self-tests.
- **Corpus** (`.github/workflows/corpus.yml`), nightly when aggrega-cli's `main` has moved since its last
  green run, and on demand: builds `aggrega` from aggrega-cli's `main` once, then runs `fast`, `live`
  (against aggrega-hub's `main`) and `full` as parallel jobs over that binary.

## License

Apache License 2.0; see [LICENSE](LICENSE).
