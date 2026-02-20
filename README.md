# VisiHub Verify Action

Publish a dataset snapshot to VisiHub. Get integrity checks, structural diffs, and a cryptographically signed proof — directly in your CI pipeline.

## Quick Start

```yaml
- uses: VisiGrid/verify-action@v1
  with:
    api_key: ${{ secrets.VISIHUB_API_KEY }}
    repo: acme/payments
    file_path: ./exports/ap_payments.csv
```

## What happens

1. **Upload** — The file is published to VisiHub as a new dataset revision. Content hash is computed and recorded.
2. **Check** — VisiHub runs a snapshot integrity check: row count, column names, schema structure, content hash. Compared against the previous revision.
3. **Diff** — A structural diff is computed: rows added/removed, columns added/removed/type-changed.
4. **Verdict** — Results appear in the GitHub Actions summary. If the check fails, the action fails your pipeline. A signed proof is available for download.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Integrity check passed (or `fail_on_check_failure` is `false`) |
| `1` | Integrity check failed — schema drift, row count change, or column mutation detected |

The action **always exits 0** on the first revision of a dataset (baseline — nothing to compare against). Subsequent revisions are compared against the previous version.

Set `fail_on_check_failure: false` to record results without blocking the pipeline.

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api_key` | Yes | | VisiHub API token |
| `repo` | Yes | | Repository in `owner/slug` format |
| `file_path` | Yes | | Path to file (CSV, TSV) |
| `dataset_path` | No | file basename | Dataset path in VisiHub |
| `message` | No | | Revision message (e.g. commit SHA, run ID) |
| `source_type` | No | | Source system identifier (e.g. `dbt`, `qbo`, `snowflake`, `manual`) |
| `source_identity` | No | | Source-specific identity (e.g. warehouse table, realm ID) |
| `fail_on_check_failure` | No | `true` | Fail action if integrity checks fail |
| `api_base` | No | `https://api.visihub.app` | API base URL |

## Outputs

| Output | Description |
|--------|-------------|
| `verification_status` | `PASS` or `FAIL` |
| `check_status` | `pass`, `fail`, or `none` |
| `diff_summary` | JSON string with row/col changes |
| `run_id` | VisiHub revision ID |
| `proof_url` | URL to download the signed proof |
| `version` | Dataset version number |

## Examples

### dbt post-hook — verify every model run

After `dbt run` completes, export the output table and verify it. If schema drifts or row counts change unexpectedly, the pipeline fails before the dashboard updates.

```yaml
name: Verify dbt models
on:
  workflow_run:
    workflows: ["dbt nightly"]
    types: [completed]

jobs:
  verify:
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Export snapshot
        run: |
          pip install dbt-snowflake
          dbt run-operation export_snapshot \
            --args '{"table": "analytics.monthly_close"}'

      - name: Verify
        uses: VisiGrid/verify-action@v1
        with:
          api_key: ${{ secrets.VISIHUB_API_KEY }}
          repo: acme/analytics
          file_path: ./exports/monthly_close.csv
          source_type: dbt
          source_identity: analytics.monthly_close
          message: "dbt run ${{ github.event.workflow_run.id }}"
```

### Nightly financial export with Slack alerts

```yaml
name: Verify financial exports
on:
  schedule:
    - cron: '0 6 * * *'

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Export data
        run: ./scripts/export-quickbooks.sh

      - name: Verify snapshot
        id: verify
        uses: VisiGrid/verify-action@v1
        with:
          api_key: ${{ secrets.VISIHUB_API_KEY }}
          repo: acme/payments
          file_path: ./exports/ap_payments.csv
          source_type: qbo
          message: "nightly export ${{ github.run_id }}"

      - name: Alert on failure
        if: failure()
        run: |
          curl -X POST "${{ secrets.SLACK_WEBHOOK }}" \
            -d "{\"text\":\"Integrity check failed for ap_payments.csv v${{ steps.verify.outputs.version }}\"}"
```

### Verify data changes on pull request

```yaml
name: Verify data changes
on:
  pull_request:
    paths: ['data/**']

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Verify
        id: verify
        uses: VisiGrid/verify-action@v1
        with:
          api_key: ${{ secrets.VISIHUB_API_KEY }}
          repo: acme/monthly-close
          file_path: ./data/trial_balance.csv
          fail_on_check_failure: false

      - name: Comment diff on PR
        uses: actions/github-script@v7
        with:
          script: |
            const diff = JSON.parse('${{ steps.verify.outputs.diff_summary }}');
            const status = '${{ steps.verify.outputs.verification_status }}';
            const version = '${{ steps.verify.outputs.version }}';
            let body = `### VisiHub Verify: ${status}\n\n`;
            body += `**Version:** v${version}\n`;
            if (diff) {
              body += `**Rows:** ${diff.row_count_change >= 0 ? '+' : ''}${diff.row_count_change}\n`;
              body += `**Cols:** ${diff.col_count_change >= 0 ? '+' : ''}${diff.col_count_change}\n`;
            }
            body += `\n[View proof](${{ steps.verify.outputs.proof_url }})`;
            github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body
            });
```

## GitHub Actions summary

The action writes a rich summary to the GitHub Actions UI:

- Dataset name, version, row/column counts
- Content hash
- Structural diff (what changed from the previous version)
- Link to download the signed proof

On failure, the summary includes specific bullets explaining what changed.

## Setup

1. Create a VisiHub account and repository at [visihub.app](https://visihub.app)
2. Generate an API token in **Settings > Tokens**
3. Add the token as a GitHub secret: `VISIHUB_API_KEY`
4. Add the action to your workflow

## Requirements

- `curl` and `jq` (pre-installed on GitHub-hosted runners)
- Optional: `b3sum` for BLAKE3 content hashing (falls back to SHA256)

## How verification works

VisiHub uploads the file to immutable storage, then runs a **Snapshot Integrity Check** comparing the current revision against the previous one:

| Assertion | Fails when |
|-----------|-----------|
| Row count | Rows added or removed unexpectedly |
| Column names | Columns renamed, added, or removed |
| Schema structure | Column types changed |
| Content hash | File fingerprint recorded for audit trail |

The first revision of a dataset is a **baseline** — all assertions pass. Subsequent revisions are compared against the baseline.

Every check produces a **cryptographically signed proof** (Ed25519) that can be verified independently via the [public verification endpoint](https://visihub.app/proof).
