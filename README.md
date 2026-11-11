# xsec GitHub Action

Scan every pull request's **preview deployment** for the
[OWASP Top 10 (2025)](https://owasp.org/Top10/) with
[xsec](https://github.com/xtruct-col/xsec-action), **review the code** the
pull request adds for security mistakes, explain each problem in plain words
right on the line, and fail the check when something is at or above a
severity.

What a run does:

1. downloads the `xsec` CLI for the runner (Linux x86_64 or aarch64) from this
   repository's releases and checks its sha256 against the release's
   `checksums.txt`;
2. if `base-url` is set, scans production the same way: that is the baseline;
3. if `url` is set, scans it (the preview). With a baseline, findings are
   split into **New**, **Still open** and **Fixed**, and only new ones can
   fail the check;
4. on a pull request, reviews the code it adds ([below](#code-review));
5. if `xsec-token` is set, uploads the scan's report to the xsec dashboard,
   and sends what the code review and the dependency check found, on pull
   requests and pushes (each finding's analysis and the few redacted lines
   it is about; [below](#what-is-sent-to-xsec-and-when));
6. writes both to the job summary, keeps one sticky comment on the pull
   request (edited on each run, not duplicated) and posts the code review's
   comments on the lines they are about;
7. exits `0` passed, `2` if the scan (new findings at or above `fail-on`) or
   the review (at or above `review-fail-on`) fails, `1` if either could not
   run.

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
| `url` | | The preview to scan. Empty: no scan, only the code review. |
| `review` | `auto` | `auto`: review the code on `pull_request` events when the checkout has the base commit; `true`: always (needs a git checkout); `false`: never. |
| `review-fail-on` | `high` | `never`, `low`, `medium`, `high` or `critical`, for the code review. Guesses and AI findings never fail the check. |
| `deps` | `auto` | `auto`, `true` or `false`: check the checkout's lockfiles against recent advisories (`auto`: on `pull_request` events when there is a lockfile). |
| `deps-fail-on` | `critical` | Fail on a dependency named by an advisory at or above this severity (`never` to only report). |
| `review-base` | | What to compare with. Default: the pull request's base commit (on other events, the merge base with `origin/main`). |
| `base-url` | | Production, scanned with the same options as the baseline. Without it every finding counts as new. |
| `fail-on` | `high` | `never`, `low`, `medium`, `high` or `critical`. |
| `passive` | `true` | See above. |
| `headers` | | Extra request headers, one `Name: value` per line, sent only to the scanned site's own origin (never to a CDN or another site it links to). Values are masked in the log and never stored in the report. |
| `seeds` | | Extra paths or URLs on the same host, one per line (pages only reachable by navigating a single-page app). |
| `comment` | `true` | Keep a sticky PR comment and post the code review's line comments. Needs `pull-requests: write`. |
| `github-token` | `github.token` | Token for the comments. |
| `xsec-token` | | A per-site CI token from the dashboard (`xsec_ci_…`): uploads the scan's report and the review's and dependency check's results, and adds an AI review to the code review. |
| `upload` | `true` | With `xsec-token`: send the scan's report and the review's and dependency check's results to the dashboard. `false`: the token is used for the AI review only. |
| `xsec-api` | `https://xsec-api.91.107.213.88.sslip.io` | Where the report is uploaded and the AI review runs. |
| `version` | `latest` | The CLI version, e.g. `0.2.0`. Pin it for reproducible runs. |
| `args` | | Advanced: more CLI flags, space-separated (e.g. `--max-pages 50`). |

Outputs: `exit-code`, `new-findings`, `report-json`, `report-markdown`,
`diff-json` (with a baseline), `dashboard-url` (after an upload),
`ci-run-url` (where the dashboard shows this run's review and dependency
results), and for the
code review `review-exit-code`, `review-findings`, `review-markdown` and
`review-json`, and for the dependency check `deps-exit-code`,
`deps-findings`, `deps-markdown` and `deps-json`.

## Dependencies with known problems

On a pull request whose checkout has a lockfile, the action also runs
`xsec deps`: it compares the lockfiles (npm, pnpm, yarn, bun, pip
requirements, poetry, uv, Pipfile, bundler, composer, go.sum, Cargo.lock,
NuGet `packages.lock.json`, `gradle.lockfile`, Maven `pom.xml`, Swift
`Package.resolved`, `pubspec.lock`, `mix.lock`, `.nvmrc`)
with xsec's short list of recent, serious advisories and hijacked releases,
built into the CLI, and adds the result to the comment: what is installed,
why it matters and the version to move to. Nothing leaves the runner. It
fails the check only on **critical** problems by default (`deps-fail-on`),
because they are usually older than the pull request. `deps: false` turns
it off; `deps: true` runs it on any event. The list is public at
<https://security.xtruct.net/advisories>, and `advisories.json` in this
repository is its current version (`xsec deps --update` reads it).

## Code review

On a pull request, xsec reads the lines it **adds** and comments on the ones
that are insecure, each with what is wrong, how to fix it and why it
matters, in words for people who build with AI and are not security experts.
It looks for what gets shipped most: API keys and `.env` files committed,
server secrets in `NEXT_PUBLIC_` / `VITE_` / `REACT_APP_` variables, the
Supabase `service_role` key in browser code, row level security turned off
or opened with `using (true)`, Firebase rules open to everyone, SQL built
from strings, `eval` and shell commands built from variables, raw HTML from
variables, certificate checks turned off, CORS that lets any site use your
users' logins, JWTs read without checking their signature, passwords hashed
with MD5 or SHA-1, `Math.random()` for tokens, routes and server actions that
write without a visible login check, AI output run as code, SQL, shell or
HTML, user input in a system prompt, open redirects, and passwords or tokens
in logs. Lockfiles, vendored, generated, minified and binary files are
skipped.

The review needs the base commit, so check out with **`fetch-depth: 0`**,
and posting comments needs **`pull-requests: write`**:

```yaml
# .github/workflows/xsec-review.yml
name: xsec review
on: pull_request

permissions:
  contents: read
  pull-requests: write   # the review's line comments and the sticky comment

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0       # the base commit, to compare with
      - uses: xtruct-col/xsec-action@v1
        with:
          review-fail-on: high
          xsec-token: ${{ secrets.XSEC_CI_TOKEN }}   # optional: adds the AI review
```

Without `url` it only reviews code; add `url` (and `base-url`) to scan the
preview in the same run. With Vercel's `deployment_status` events (no
pull request in the event), keep the scan in its own workflow as shown
below and the review in this one.

Each run posts **one** review (as a comment: it never approves or blocks a
merge by itself; the check's status does that). Each line comment carries a
hidden marker, so a re-run does not post the same comment twice, even if the
line moved. Findings marked *inferred* are educated guesses and never fail
the check.

### What is sent to xsec, and when

Without `xsec-token`, nothing: the rules run inside your runner.

With `xsec-token`, the code review also asks xsec's AI review, and sends:
the **changed lines of the pull request with a few lines of context around
them** (not whole files, not removed lines), each file's path and language,
and the rules' findings. **Secrets are redacted before sending**: every key,
token, password or database URL the rules can recognise, and every value in
a `.env` file, is replaced by `[redacted]`. xsec does **not store** what
it sends for the AI review; it passes it to **OpenAI** for the review and
returns the findings. (What the dashboard keeps, each finding's few
redacted lines, is described under "On the dashboard" below.) At most
50 files and 200 KB per run (the review says when it had to leave files
out; the rules still check all of them). Each review counts against your
plan's monthly AI review quota; when it is used up, or the AI review is
unavailable, the run warns and the rules' findings stand. AI findings are
kept only on lines the pull request adds, and never fail the check.

**On the dashboard.** With `xsec-token` (and `upload` left on), after the
review and the dependency check the action sends their results to xsec, so
the company page lists each run, pull requests and pushes to `main` alike.
For each code review finding: the file path, the line, the rule (or `ai`),
severity, confidence, OWASP category, CWE, its title, explanation and fix,
and **only the code it is about**: the flagged line and up to 3 lines on
each side, as the diff shows them, **with secrets redacted** the same way
as for the AI review (and again by xsec). Never whole files or the diff.
For each dependency: the package, the installed version, the advisory,
the version to move to and the lockfile it is in. Plus the repository,
commit, branch, event, pull request and run links, and whether each check
failed at its threshold. At most 200 findings of each kind per run; the
rest are counted. **xsec stores these** with your company; only its
members see them. `upload: false` sends none of it, nor the scan's report.

How findings match across hosts: by check, parameter and URL, where a URL on
the scanned site counts by its path and query, so `/search` on the preview
matches `/search` in production. URLs on other hosts (a CDN script) match as
they are.

## Direct pushes to the default branch

A push straight to `main` skips the pull request, and with it the review.
Review what each push adds, from the commit the branch was at before it:

```yaml
on:
  push:
    branches: [main]

jobs:
  review-main:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read   # the action looks up the commit's pull request
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: xtruct-col/xsec-action@v1
        with:
          review: true
          review-base: ${{ github.event.before }}
          deps: true
          comment: false     # a push has no pull request to comment on
          xsec-token: ${{ secrets.XSEC_CI_TOKEN }}
```

This flags a push after it lands; it cannot stop it. To require a reviewed
pull request with this check green, protect the branch in GitHub (Settings →
Branches or Rules). After a force-push the previous commit may be gone and
the review cannot run (exit 1).

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
    # Only Vercel's previews: other deployments (a release, Production) send this event too.
    if: github.event.deployment_status.state == 'success' && github.event.deployment.creator.login == 'vercel[bot]' && startsWith(github.event.deployment.environment, 'Preview')
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

## Permissions

Give each job only what it needs (job-level `permissions` replace the
workflow's, so list `contents: read` too):

| Job | Needs |
|---|---|
| Any | `contents: read` |
| Comments on the pull request (`comment: true`, the default) | `pull-requests: write` |
| `push` or `deployment_status` events with `comment: false` | `pull-requests: read`: the action finds the commit's pull request |

Without access to pull requests the action carries on without one.

## Uploading to the dashboard

With `xsec-token` (a CI token a company admin creates for one site in the
xsec dashboard), the action posts the JSON report with the repository, PR
number, commit and a link to the PR or run. The token is masked in the log
and sent in a header file, never on a command line. An upload that fails
(a rejected token, a report too large, the monthly cap) is a warning; it
never changes the check's verdict.

The code review's and the dependency check's results are sent too, with
each finding's redacted excerpt ([what is sent](#what-is-sent-to-xsec-and-when)):
the company page lists each pull request's and push's run, with a link back
to it. `upload: false`
sends neither; the token then only adds the AI review.

## License

The files in this repository are MIT-licensed. The `xsec` binary in the
releases is not open source; see [LICENSE](LICENSE).
