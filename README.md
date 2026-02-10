# VisiHub Verify Action

Publish a dataset snapshot to VisiHub and verify its structural integrity. Get diffs, checks, and cryptographically signed proofs — directly in your CI pipeline.

## Quick Start

```yaml
- uses: visihub/verify-action@v1
  with:
    api_key: ${{ secrets.VISIHUB_API_KEY }}
    repo: acme/payments
    file_path: ./exports/ap_payments.csv
```

## What it does

1. Uploads the file to VisiHub as a new dataset revision
2. Waits for the snapshot integrity check to complete
3. Returns verification status, diff summary, and proof URL
4. Fails the workflow if the check fails (configurable)

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `api_key` | Yes | | VisiHub API token |
| `repo` | Yes | | Repository in `owner/slug` format |
| `file_path` | Yes | | Path to file (CSV, TSV) |
| `dataset_path` | No | file basename | Dataset path in VisiHub |
| `message` | No | | Revision message |
| `fail_on_check_failure` | No | `true` | Fail action if checks fail |
| `api_base` | No | `https://api.visihub.app` | API base URL |

## Outputs

| Output | Description |
|--------|-------------|
| `verification_status` | `PASS` or `FAIL` |
| `check_status` | `pass`, `fail`, or `none` |
| `diff_summary` | JSON string with row/col changes |
| `run_id` | VisiHub revision ID |
| `proof_url` | URL to download signed proof |
| `version` | Dataset version number |

## Examples

### Nightly financial data verification

```yaml
name: Verify financial exports
on:
  schedule:
    - cron: '0 6 * * *'  # 6 AM UTC daily

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Export data
        run: ./scripts/export-quickbooks.sh

      - name: Verify snapshot
        id: verify
        uses: visihub/verify-action@v1
        with:
          api_key: ${{ secrets.VISIHUB_API_KEY }}
          repo: acme/payments
          file_path: ./exports/ap_payments.csv
          message: "nightly export ${{ github.run_id }}"

      - name: Post to Slack on failure
        if: failure()
        run: |
          curl -X POST "${{ secrets.SLACK_WEBHOOK }}" \
            -d "{\"text\":\"Snapshot integrity check failed for ap_payments.csv v${{ steps.verify.outputs.version }}\"}"
```

### Verify on pull request

```yaml
name: Verify data changes
on:
  pull_request:
    paths:
      - 'data/**'

jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Verify changed datasets
        id: verify
        uses: visihub/verify-action@v1
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
            let body = `### VisiHub Verification: ${status}\n\n`;
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

### dbt post-hook verification

```yaml
name: Verify dbt snapshots
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

      - name: Extract snapshot
        run: |
          pip install dbt-snowflake
          dbt run-operation export_snapshot --args '{"table": "analytics.monthly_close"}'

      - name: Verify
        uses: visihub/verify-action@v1
        with:
          api_key: ${{ secrets.VISIHUB_API_KEY }}
          repo: acme/analytics
          file_path: ./exports/monthly_close.csv
          message: "dbt run ${{ github.event.workflow_run.id }}"
```

## Setup

1. Create a VisiHub account and repository at [app.visihub.app](https://app.visihub.app)
2. Generate an API token in Settings > Tokens
3. Add the token as a GitHub secret: `VISIHUB_API_KEY`
4. Add the action to your workflow

## Requirements

- `curl` and `jq` (pre-installed on GitHub-hosted runners)
- Optional: `b3sum` for BLAKE3 content hashing (falls back to SHA256)
