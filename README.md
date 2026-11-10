# ferrograph PR report

Runs [`ferrograph pr`](https://github.com/GarthDB/ferrograph) on pull requests: reports newly dead functions and blast radius as a sticky PR comment (and optionally SARIF). Advisory by default. Composite action: no Node or Docker.

> **Recommended: advisory mode.** ferrograph's dead-code and blast-radius results are static and name-based, with known false positives and false negatives, so start without thresholds (`fail-on-new-dead`, `max-new-dead`, `max-blast`) and adopt them only after the comments have held up on your own repo. See ferrograph's [Accuracy and limitations](https://github.com/GarthDB/ferrograph#accuracy-and-limitations).

Requires a ferrograph release that includes the `pr` command (v4.0.0 or later). Runners: linux x64, linux arm64, macOS arm64.

## Quick start

```yaml
name: ferrograph
on: pull_request
permissions:
  contents: read
  pull-requests: write   # sticky comment
  # security-events: write   # only with `sarif: true`
jobs:
  ferrograph:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0   # required: the base ref and merge base must exist
      - uses: GarthDB/ferrograph-action@v1
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `version` | `latest` | Release to install: `latest`, `v4.0.0` or `4.0.0`. |
| `base` | `origin/<PR base ref>` | Base ref to diff against. |
| `fail-on-new-dead` | `false` | Fail if any function is newly dead. |
| `max-new-dead` | | Fail if more than N functions are newly dead. |
| `max-blast` | | Fail if the combined blast radius exceeds N nodes. |
| `entry` | | Extra entry points (glob or attribute), one per line. |
| `ignore` | | File globs never reported, one per line. |
| `strict` | `false` | Ambiguous call edges do not keep functions alive. |
| `comment` | `true` | Post/update the sticky comment. |
| `sarif` | `false` | Upload SARIF to code scanning. |
| `working-directory` | `.` | Checked-out repo directory to analyse. |
| `db` | | Prebuilt base graph (`--base-db`). |
| `github-token` | `${{ github.token }}` | Token for release download, comments, SARIF. |

## Outputs

`new-dead-count`, `blast-count`, `exit-code` (0/1/2), `report-path` (Markdown report).

## Behaviour

- **Exit codes:** `0` ok. `1` threshold exceeded: the step fails only if `fail-on-new-dead`, `max-new-dead` or `max-blast` is set, and the comment is posted first. `2` error: always fails, with ferrograph's message.
- **Comment:** one comment per PR, found by the hidden `<!-- ferrograph -->` marker and updated in place. Needs `pull-requests: write`.
- **Fork PRs / read-only tokens / non-PR events:** no comment; the same Markdown goes to the job summary. Commenting never fails the job.
- **SARIF:** `sarif: true` uploads via `github/codeql-action/upload-sarif`; needs `security-events: write`.
- **Install:** the tarball is checked against the release `SHA256SUMS`; a mismatch fails the job. Binaries are cached per version and target (`latest` is re-resolved every run).
- Note: ferrograph is run once per output format, so HEAD and base are indexed more than once.

## Pinning

Use `@v1` for fixes, or pin a full commit SHA (`uses: GarthDB/ferrograph-action@<sha> # v1.x.y`) and a fixed `version: v4.0.0` for reproducible runs.

## Troubleshooting

- `Base ref 'origin/main' not found` or `No merge base`: the clone is shallow. Set `fetch-depth: 0` on `actions/checkout`.
- `Unsupported runner`: Windows and macOS x64 have no release binary.
- Comment missing on a fork PR: expected; see the job summary.

## Releasing (maintainers)

Tag `v1.0.0` after the dogfood workflow passes on all three runners, then move the floating `v1` tag to each new `v1.x.y`. Marketplace publishing is a manual release-page step.
