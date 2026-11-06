# xsec GitHub Action

Scan every pull request's **preview deployment** for the
[OWASP Top 10 (2025)](https://owasp.org/Top10/) with
[xsec](https://github.com/xtruct-col/xsec-action), comment on the PR with what
the PR **adds** compared with production, and fail the check when a new
finding is at or above a severity.

What a run does:

1. downloads the `xsec` CLI for the runner (Linux x86_64 or aarch64) from this
   repository's releases and checks its sha256 against the release's
   `checksums.txt`;
2. if `base-url` is set, scans production the same way: that is the baseline;
3. scans `url` (the preview). With a baseline, findings are split into
   **New**, **Still open** and **Fixed**, and only new ones can fail the check;
4. if `xsec-token` is set, uploads the report to the xsec dashboard;
5. writes the report to the job summary and keeps one sticky comment on the
   pull request (edited on each run, not duplicated);
6. exits like the CLI: `0` passed, `2` new findings at or above `fail-on`,
   `1` the scan could not run.

## Passive by default: scan only what you own

Preview scans are **passive** unless you set `passive: false`: the scanner
sends only what a visitor's browser would (headers, TLS, cookies, CORS, the
page markup and the scripts it loads). No payloads, no guessed paths.

`passive: false` runs every check, including injection payloads and
requests for exposed files. It is still non-destructive (GET/HEAD/OPTIONS
only, no form is submitted, no credentials are guessed), but **run full scans
only against environments you own or are authorized in writing to test**.
Each report records that the repository's CI ran it
(`--authorized-by "<owner/repo> CI (the repository owner scans its own deployment)"`);
xsec does not verify ownership from CI.

## Inputs

| Input | Default | What |
|---|---|---|
| `url` | (required) | The preview to scan. |
| `base-url` | | Production, scanned with the same options as the baseline. Without it every finding counts as new. |
| `fail-on` | `high` | `never`, `low`, `medium`, `high` or `critical`. |
| `passive` | `true` | See above. |
| `headers` | | Extra request headers, one `Name: value` per line, sent only to the scanned site's own origin (never to a CDN or another site it links to). Values are masked in the log and never stored in the report. |
| `seeds` | | Extra paths or URLs on the same host, one per line (pages only reachable by navigating a single-page app). |
| `comment` | `true` | Keep a sticky PR comment. Needs `pull-requests: write`. |
| `github-token` | `github.token` | Token for the comment. |
| `xsec-token` | | A per-site CI token from the dashboard (`xsec_ci_…`): uploads the report. |
| `xsec-api` | `https://xsec-api.91.107.213.88.sslip.io` | Where the report is uploaded. |
| `version` | `latest` | The CLI version, e.g. `0.2.0`. Pin it for reproducible runs. |
| `args` | | Advanced: more CLI flags, space-separated (e.g. `--max-pages 50`). |

Outputs: `exit-code`, `new-findings`, `report-json`, `report-markdown`,
`diff-json` (with a baseline) and `dashboard-url` (after an upload).

How findings match across hosts: by check, parameter and URL, where a URL on
the scanned site counts by its path and query, so `/search` on the preview
matches `/search` in production. URLs on other hosts (a CDN script) match as
they are.

## Vercel

Vercel reports each preview as a deployment; scan it when it is ready.

```yaml
# .github/workflows/xsec.yml
name: xsec
on: deployment_status

permissions:
  contents: read
  pull-requests: write   # the sticky comment

jobs:
  scan:
    if: github.event.deployment_status.state == 'success' && github.event.deployment.environment != 'Production'
    runs-on: ubuntu-latest
    steps:
      - uses: xtruct-col/xsec-action@v1
        with:
          url: ${{ github.event.deployment_status.target_url }}
          base-url: https://www.example.com
          fail-on: high
          xsec-token: ${{ secrets.XSEC_CI_TOKEN }}   # optional: upload to the dashboard
```

A `deployment_status` event carries no PR number: the action finds the open
pull request for the deployed commit.

### Protected previews (Vercel Deployment Protection)

If previews need a login, create a *Protection Bypass for Automation* secret
in the Vercel project (Settings → Deployment Protection), store it as a
repository secret, and pass it as a header:

```yaml
      - uses: xtruct-col/xsec-action@v1
        with:
          url: ${{ github.event.deployment_status.target_url }}
          base-url: https://www.example.com
          headers: |
            x-vercel-protection-bypass: ${{ secrets.VERCEL_AUTOMATION_BYPASS_SECRET }}
```

The header goes to the scanned origins only (the preview, and production
when `base-url` is set), never to third-party hosts the pages link to. The
same works for a session cookie (`Cookie: session=…`) to scan behind a login.

## Netlify

Netlify's deploy previews also arrive as `deployment_status` events when the
Netlify GitHub app is installed; `target_url` is the preview:

```yaml
on: deployment_status
permissions:
  contents: read
  pull-requests: write
jobs:
  scan:
    if: github.event.deployment_status.state == 'success'
    runs-on: ubuntu-latest
    steps:
      - uses: xtruct-col/xsec-action@v1
        with:
          url: ${{ github.event.deployment_status.target_url }}
          base-url: https://example.netlify.app
```

Without deployment events, Netlify previews follow a fixed pattern:

```yaml
on: pull_request
jobs:
  scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      # Wait for the preview with your own step first (e.g. poll until it answers 200).
      - uses: xtruct-col/xsec-action@v1
        with:
          url: https://deploy-preview-${{ github.event.pull_request.number }}--example.netlify.app
          base-url: https://example.netlify.app
```

## A plain URL

```yaml
on: workflow_dispatch
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: xtruct-col/xsec-action@v1
        with:
          url: https://staging.example.com
          comment: false
          fail-on: medium
```

## Uploading to the dashboard

With `xsec-token` (a CI token a company admin creates for one site in the
xsec dashboard), the action posts the JSON report with the repository, PR
number, commit and a link to the PR or run. The token is masked in the log
and sent in a header file, never on a command line. An upload that fails
(a rejected token, a report too large, the monthly cap) is a warning; the
check's verdict is always the scan's.

## License

The files in this repository are MIT-licensed. The `xsec` binary in the
releases is not open source; see [LICENSE](LICENSE).
