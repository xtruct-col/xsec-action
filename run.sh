#!/usr/bin/env bash
# The xsec Action's logic (action.yml only passes its inputs here as
# INPUT_* variables). Steps:
#   1. get the xsec CLI for this runner and check its sha256;
#   2. scan base-url (production) to JSON, if given: the baseline;
#   3. scan url (the preview) once, if given: Markdown, JSON and the diff;
#   4. review the code the pull request adds (`xsec review`), if it runs;
#   4b. check the checkout's lockfiles against recent advisories (`xsec deps`),
#      if it runs;
#   5. upload the scan's JSON to the xsec dashboard, if a token is given;
#   6. write the job summary and a sticky pull-request comment, and post the
#      review's inline comments (one GitHub review, comments not repeated);
#   7. exit 0 ok, 2 if the scan, the review or the dependency check found
#      something at or above its threshold, 1 if one could not run.
#
# Overrides for tests and self-hosted runners: XSEC_BIN (use this binary,
# skip the download), XSEC_RELEASE_BASE (where releases live),
# XSEC_TARGET_TRIPLE (skip uname), XSEC_OUT_DIR (where reports go).
#
# Written for bash 3.2 too (macOS), so: no mapfile, no ${x,,}, guarded arrays.

set -euo pipefail

log() { printf 'xsec-action: %s\n' "$*" >&2; }
fail() { printf '::error::xsec-action: %s\n' "$*"; exit 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
output() { printf '%s=%s\n' "$1" "$2" >> "${GITHUB_OUTPUT:-/dev/null}"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
bool() {
  case "$(lower "$2")" in
    true | yes | 1) echo true ;;
    false | no | 0 | "") echo false ;;
    *) fail "input $1 must be true or false" ;;
  esac
}

URL="$(trim "${INPUT_URL:-}")"
BASE_URL="$(trim "${INPUT_BASE_URL:-}")"
FAIL_ON="$(trim "${INPUT_FAIL_ON:-high}")"
PASSIVE="$(bool passive "${INPUT_PASSIVE:-true}")"
COMMENT="$(bool comment "${INPUT_COMMENT:-true}")"
REVIEW="$(lower "$(trim "${INPUT_REVIEW:-auto}")")"
REVIEW_FAIL_ON="$(trim "${INPUT_REVIEW_FAIL_ON:-high}")"
REVIEW_BASE="$(trim "${INPUT_REVIEW_BASE:-}")"
DEPS="$(lower "$(trim "${INPUT_DEPS:-auto}")")"
DEPS_FAIL_ON="$(trim "${INPUT_DEPS_FAIL_ON:-critical}")"
VERSION="$(trim "${INPUT_VERSION:-latest}")"
XSEC_API="$(trim "${INPUT_XSEC_API:-https://xsec-api.91.107.213.88.sslip.io}")"
XSEC_API="${XSEC_API%/}"
TOKEN="${INPUT_XSEC_TOKEN:-}"
RELEASE_BASE="${XSEC_RELEASE_BASE:-https://github.com/xtruct-col/xsec-action/releases}"
REPO="${GITHUB_REPOSITORY:-local/repo}"

case "$URL" in
  "" | http://* | https://*) ;;
  *) fail "input url must start with http:// or https://" ;;
esac
case "$BASE_URL" in
  "" | http://* | https://*) ;;
  *) fail "input base-url must start with http:// or https://" ;;
esac
case "$REVIEW" in
  auto | true | false) ;;
  *) fail "input review must be auto, true or false" ;;
esac
case "$DEPS" in
  auto | true | false) ;;
  *) fail "input deps must be auto, true or false" ;;
esac

# Secrets: mask them before anything can print them. Each header's value is
# masked on its own line (a multi-line mask does not work).
if [ -n "$TOKEN" ]; then
  echo "::add-mask::$TOKEN"
fi
HEADERS=""
while IFS= read -r line || [ -n "$line" ]; do
  line="$(trim "$line")"
  [ -z "$line" ] && continue
  case "$line" in
    *:*) ;;
    *) fail "each line of headers must look like 'Name: value'" ;;
  esac
  value="$(trim "${line#*:}")"
  [ -n "$value" ] && echo "::add-mask::$value"
  HEADERS="${HEADERS}${line}"$'\n'
done <<< "${INPUT_HEADERS:-}"

OUT="${XSEC_OUT_DIR:-${RUNNER_TEMP:-$(mktemp -d)}/xsec}"
mkdir -p "$OUT"

# ---- context: the pull request, the commit, a link ---------------------------

EVENT="${GITHUB_EVENT_PATH:-/dev/null}"
[ -f "$EVENT" ] || EVENT=/dev/null
ev() { jq -r "$1 // empty" "$EVENT" 2> /dev/null || true; }
SHA="$(ev '.pull_request.head.sha // .deployment.sha // .deployment_status.deployment.sha')"
SHA="${SHA:-${GITHUB_SHA:-}}"
PR_BASE="$(ev '.pull_request.base.sha')"
PR_HEAD="$(ev '.pull_request.head.sha')"

# Whether the code review runs: on a pull_request event whose base commit
# the checkout has (auto), or whenever asked (true).
in_git() { git rev-parse --is-inside-work-tree > /dev/null 2>&1; }
have_commit() { [ -n "$1" ] && git cat-file -e "$1^{commit}" 2> /dev/null; }
RUN_REVIEW=false
case "$REVIEW" in
  auto)
    if [ -n "$PR_BASE" ] && in_git; then
      if have_commit "${REVIEW_BASE:-$PR_BASE}"; then
        RUN_REVIEW=true
      else
        echo "::notice::xsec-action: no code review: the checkout does not have the base commit (use actions/checkout with fetch-depth: 0)"
      fi
    fi
    ;;
  true)
    if in_git; then
      RUN_REVIEW=true
    else
      echo "::warning::xsec-action: no code review: the workspace is not a git checkout (add actions/checkout with fetch-depth: 0)"
    fi
    ;;
esac
# Whether the dependency check runs: on a pull_request event whose checkout
# (the working directory) has a lockfile (auto), or whenever asked (true).
has_lockfile() {
  [ -n "$(find . \( -name node_modules -o -name .git -o -name vendor -o -name .venv \) -prune -o -type f \( \
    -name package-lock.json -o -name npm-shrinkwrap.json -o -name pnpm-lock.yaml -o -name yarn.lock -o -name bun.lock \
    -o -name 'requirements*.txt' -o -name poetry.lock -o -name uv.lock -o -name Pipfile.lock -o -name Gemfile.lock \
    -o -name composer.lock -o -name go.sum -o -name .nvmrc -o -name .node-version \) -print 2> /dev/null | head -n 1)" ]
}
RUN_DEPS=false
case "$DEPS" in
  auto) [ -n "$PR_BASE" ] && has_lockfile && RUN_DEPS=true ;;
  true) RUN_DEPS=true ;;
esac
if [ -z "$URL" ] && [ "$RUN_REVIEW" = false ] && [ "$RUN_DEPS" = false ]; then
  fail "input url is required (or run on a pull_request event with review: auto, the default)"
fi

PR="$(ev '.pull_request.number // .issue.number')"
if [ -z "$PR" ] && [ -n "$SHA" ] && { [ "$COMMENT" = "true" ] || [ -n "$TOKEN" ] || [ "$RUN_REVIEW" = true ]; } && [ -n "${GH_TOKEN:-}" ] && command -v gh > /dev/null; then
  # deployment_status and push events carry no PR: find the open one for the commit.
  PR="$(gh api "repos/$REPO/commits/$SHA/pulls" --jq '[.[] | select(.state == "open")][0].number // empty' 2> /dev/null || true)"
fi
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/runs/${GITHUB_RUN_ID:-0}"
LINK="$(ev '.pull_request.html_url')"
if [ -z "$LINK" ] && [ -n "$PR" ]; then LINK="${GITHUB_SERVER_URL:-https://github.com}/$REPO/pull/$PR"; fi
LINK="${LINK:-$RUN_URL}"

# ---- 1. the CLI -------------------------------------------------------------

sha256() {
  if command -v sha256sum > /dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

install_cli() {
  local triple="${XSEC_TARGET_TRIPLE:-}"
  if [ -z "$triple" ]; then
    [ "$(uname -s)" = "Linux" ] || fail "xsec ships Linux binaries only (x86_64, aarch64); use a Linux runner"
    case "$(uname -m)" in
      x86_64 | amd64) triple=x86_64-unknown-linux-musl ;;
      aarch64 | arm64) triple=aarch64-unknown-linux-musl ;;
      *) fail "no xsec binary for $(uname -m)" ;;
    esac
  fi
  local where
  if [ "$VERSION" = "latest" ]; then
    where="$RELEASE_BASE/latest/download"
  else
    where="$RELEASE_BASE/download/cli-v${VERSION#v}"
  fi
  local asset="xsec-$triple.tar.gz" dir="$OUT/cli"
  mkdir -p "$dir"
  log "downloading $asset ($VERSION)"
  curl -fsSL --retry 3 -o "$dir/$asset" "$where/$asset" || fail "could not download $where/$asset"
  curl -fsSL --retry 3 -o "$dir/checksums.txt" "$where/checksums.txt" || fail "could not download $where/checksums.txt"
  local want got
  want="$(awk -v a="$asset" '$2 == a || $2 == "*"a { print $1 }' "$dir/checksums.txt")"
  [ -n "$want" ] || fail "checksums.txt has no entry for $asset"
  got="$(sha256 "$dir/$asset")"
  [ "$want" = "$got" ] || fail "sha256 mismatch for $asset: expected $want, got $got"
  tar -xzf "$dir/$asset" -C "$dir" xsec || fail "$asset has no xsec binary"
  chmod +x "$dir/xsec"
  XSEC_BIN="$dir/xsec"
}

if [ -z "${XSEC_BIN:-}" ]; then
  install_cli
fi
log "using $("$XSEC_BIN" --version)"

# ---- 2 and 3. the scans -----------------------------------------------------

EXIT=0
if [ -n "$URL" ]; then
  AUTHORIZED_BY="$REPO CI (the repository owner scans its own deployment)"
  common=(--authorized-by "$AUTHORIZED_BY")
  [ "$PASSIVE" = "true" ] && common+=(--passive)
  while IFS= read -r seed || [ -n "$seed" ]; do
    seed="$(trim "$seed")"
    [ -n "$seed" ] && common+=(--seed "$seed")
  done <<< "${INPUT_SEEDS:-}"
  if [ -n "$(trim "${INPUT_ARGS:-}")" ]; then
    # Extra CLI flags, split on whitespace (no quoting inside one flag).
    read -r -a extra <<< "${INPUT_ARGS}"
    common+=("${extra[@]}")
  fi
  # Header values reach the CLI through the environment, not argv.
  export XSEC_HEADERS="$HEADERS"

  baseline=()
  if [ -n "$BASE_URL" ]; then
    log "scanning the baseline $BASE_URL"
    set +e
    "$XSEC_BIN" "$BASE_URL" "${common[@]}" --fail-on never --format json --out "$OUT/baseline.json"
    code=$?
    set -e
    if [ "$code" -eq 0 ]; then
      baseline=(--baseline "$OUT/baseline.json" --baseline-out "$OUT/diff.json")
    else
      echo "::warning::xsec-action: the baseline scan of $BASE_URL failed (exit $code); every finding of the preview counts as new"
    fi
  fi

  log "scanning $URL"
  set +e
  "$XSEC_BIN" "$URL" "${common[@]}" ${baseline[@]+"${baseline[@]}"} \
    --fail-on "$FAIL_ON" --format markdown --out "$OUT/report.md" --json-out "$OUT/report.json"
  EXIT=$?
  set -e
  if [ "$EXIT" -ne 0 ] && [ "$EXIT" -ne 2 ]; then
    output exit-code "$EXIT"
    fail "the scan of $URL could not run (exit $EXIT)"
  fi
  output report-json "$OUT/report.json"
  output report-markdown "$OUT/report.md"
  if [ -f "$OUT/diff.json" ]; then
    output diff-json "$OUT/diff.json"
    output new-findings "$(jq '.new | length' "$OUT/diff.json")"
  else
    output new-findings "$(jq '.findings | length' "$OUT/report.json")"
  fi
fi

# ---- 4. the code review -------------------------------------------------------

REVIEW_EXIT=0
if [ "$RUN_REVIEW" = true ]; then
  head="HEAD"
  if have_commit "$PR_HEAD"; then
    head="$PR_HEAD"
  elif [ -z "$PR_HEAD" ] && have_commit "$SHA"; then
    head="$SHA"
  fi
  base="${REVIEW_BASE:-$PR_BASE}"
  review_args=(review --head "$head" --fail-on "$REVIEW_FAIL_ON" --format github --out "$OUT/review-github.json"
    --markdown-out "$OUT/review.md" --json-out "$OUT/review.json" --repository "$REPO" --url "$LINK" --api "$XSEC_API")
  [ -n "$base" ] && review_args+=(--base "$base")
  [ -n "$PR" ] && review_args+=(--pull-request "$PR")
  # Inline comments must sit on the PR's head commit, not on a merge commit.
  [ -n "$PR_HEAD" ] && review_args+=(--sha "$PR_HEAD")
  log "reviewing the code ${base:+since $base }at $head"
  set +e
  # The token reaches the CLI through the environment, not argv.
  XSEC_TOKEN="$TOKEN" "$XSEC_BIN" "${review_args[@]}"
  REVIEW_EXIT=$?
  set -e
  output review-exit-code "$REVIEW_EXIT"
  if [ "$REVIEW_EXIT" -eq 0 ] || [ "$REVIEW_EXIT" -eq 2 ]; then
    output review-json "$OUT/review.json"
    output review-markdown "$OUT/review.md"
    output review-findings "$(jq '.findings | length' "$OUT/review.json")"
  else
    echo "::error::xsec-action: the code review could not run (exit $REVIEW_EXIT)"
  fi
fi

# ---- 4b. the dependency check -------------------------------------------------

DEPS_EXIT=0
DEPS_RAN=false
if [ "$RUN_DEPS" = true ]; then
  # A CLI older than `xsec deps` (a pinned version) answers a usage error
  # with exit 2, which must not read as findings.
  if ! "$XSEC_BIN" deps --help > /dev/null 2>&1; then
    if [ "$DEPS" = true ]; then
      echo "::error::xsec-action: this xsec CLI has no dependency check (xsec deps); use a newer version"
      DEPS_EXIT=1
    else
      echo "::notice::xsec-action: no dependency check: this xsec CLI is older than xsec deps"
    fi
  else
    log "checking the lockfiles against recent advisories"
    set +e
    "$XSEC_BIN" deps . --fail-on "$DEPS_FAIL_ON" --format markdown --out "$OUT/deps.md" --json-out "$OUT/deps.json"
    DEPS_EXIT=$?
    set -e
    output deps-exit-code "$DEPS_EXIT"
    if [ "$DEPS_EXIT" -eq 0 ] || [ "$DEPS_EXIT" -eq 2 ]; then
      DEPS_RAN=true
      output deps-json "$OUT/deps.json"
      output deps-markdown "$OUT/deps.md"
      output deps-findings "$(jq '.findings | length' "$OUT/deps.json")"
    else
      echo "::error::xsec-action: the dependency check could not run (exit $DEPS_EXIT)"
    fi
  fi
fi

# ---- 5. upload ----------------------------------------------------------------

DASHBOARD=""
if [ -n "$TOKEN" ] && [ -n "$URL" ]; then
  body="$OUT/upload.json"
  jq -n --slurpfile report "$OUT/report.json" --arg repo "$REPO" --arg sha "$SHA" --arg url "$LINK" --arg pr "$PR" '
    {report: $report[0], ref: ({repository: $repo, sha: $sha, url: $url}
      + (if $pr == "" then {} else {pullRequest: ($pr | tonumber)} end))}' > "$body"
  # The token goes in a header file, never on curl's command line.
  auth="$OUT/.auth"
  (umask 077 && printf 'Authorization: Bearer %s\n' "$TOKEN" > "$auth")
  set +e
  status="$(curl -sS --retry 2 -o "$OUT/upload-response.json" -w '%{http_code}' -X POST \
    -H @"$auth" -H 'Content-Type: application/json' --data-binary @"$body" "$XSEC_API/v1/ci/reports")"
  set -e
  rm -f "$auth"
  case "$status" in
    201)
      DASHBOARD="$(jq -r '.url // empty' "$OUT/upload-response.json" 2> /dev/null || true)"
      log "uploaded to the xsec dashboard: $DASHBOARD"
      output dashboard-url "$DASHBOARD"
      ;;
    401) echo "::warning::xsec-action: the dashboard refused the xsec-token (401): make a new CI token for this site" ;;
    413) echo "::warning::xsec-action: the report is too large for the dashboard (413)" ;;
    429) echo "::warning::xsec-action: this site's monthly CI upload cap is reached (429)" ;;
    *) echo "::warning::xsec-action: the upload to $XSEC_API failed (HTTP ${status:-none})" ;;
  esac
fi

# ---- 6. summary, comment and review -----------------------------------------------

WHAT="findings"
[ -f "$OUT/diff.json" ] && WHAT="new findings (compared with $BASE_URL)"
REVIEWED=false
[ "$RUN_REVIEW" = true ] && [ -f "$OUT/review.md" ] && { [ "$REVIEW_EXIT" -eq 0 ] || [ "$REVIEW_EXIT" -eq 2 ]; } && REVIEWED=true
MARKER="<!-- xsec-action -->"
comment="$OUT/comment.md"
{
  echo "$MARKER"
  if [ "$EXIT" -eq 2 ] || [ "$REVIEW_EXIT" -eq 2 ] || [ "$DEPS_EXIT" -eq 2 ]; then
    echo "> [!CAUTION]"
    [ "$EXIT" -eq 2 ] && echo "> **xsec: this check fails**: $WHAT at or above \`$FAIL_ON\`."
    [ "$REVIEW_EXIT" -eq 2 ] && echo "> **xsec: this check fails**: the code review found problems at or above \`$REVIEW_FAIL_ON\`."
    [ "$DEPS_EXIT" -eq 2 ] && echo "> **xsec: this check fails**: dependencies with known problems at or above \`$DEPS_FAIL_ON\`."
    echo
  fi
  if [ -n "$URL" ]; then
    cat "$OUT/report.md"
    echo
  fi
  if [ "$REVIEWED" = true ]; then
    cat "$OUT/review.md"
    echo
  fi
  if [ "$DEPS_RAN" = true ]; then
    cat "$OUT/deps.md"
    echo
  fi
  if [ -n "$DASHBOARD" ]; then echo "[Open this scan in the xsec dashboard]($DASHBOARD) · "; fi
  echo "<sub>[xsec](https://github.com/xtruct-col/xsec-action) · [run]($RUN_URL) · commit \`${SHA:0:12}\`</sub>"
} > "$comment"
# GitHub caps a comment at 65536 characters.
if [ "$(wc -c < "$comment")" -gt 60000 ]; then
  head -c 58000 "$comment" > "$comment.cut"
  printf '\n\n…cut: the full report is in the [job summary](%s).\n' "$RUN_URL" >> "$comment.cut"
  mv "$comment.cut" "$comment"
fi
tail -n +2 "$comment" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ "$COMMENT" = "true" ]; then
  if [ -z "$PR" ]; then
    log "no pull request for this run: no comment"
  elif [ -z "${GH_TOKEN:-}" ]; then
    echo "::warning::xsec-action: no github-token, so no PR comment"
  else
    id="$(gh api --paginate "repos/$REPO/issues/$PR/comments" \
      --jq ".[] | select(.body | startswith(\"$MARKER\")) | .id" 2> /dev/null | head -n 1 || true)"
    if [ -n "$id" ]; then
      gh api -X PATCH "repos/$REPO/issues/comments/$id" -F "body=@$comment" > /dev/null \
        || echo "::warning::xsec-action: could not update the PR comment (needs pull-requests: write)"
    else
      gh api -X POST "repos/$REPO/issues/$PR/comments" -F "body=@$comment" > /dev/null \
        || echo "::warning::xsec-action: could not comment on the PR (needs pull-requests: write)"
    fi

    # The review's inline comments: one review per run, without the
    # comments an earlier run already posted (each carries a hidden marker).
    if [ "$REVIEWED" = true ] && [ -f "$OUT/review-github.json" ]; then
      seen="$(gh api --paginate "repos/$REPO/pulls/$PR/comments" --jq '.[].body' 2> /dev/null | grep -o 'xsec-review:[0-9a-f]*' || true)"
      jq --arg seen "$seen" --arg commit "$PR_HEAD" '
        ($seen | split("\n")) as $old
        | .comments |= map(select(
            ((.body | [match("<!-- xsec-review:([0-9a-f]+) -->").captures[0].string][0]) // "") as $fp
            | ($old | any(. == ("xsec-review:" + $fp))) | not))
        | if $commit != "" then .commit_id = $commit else . end' "$OUT/review-github.json" > "$OUT/review-post.json"
      if [ "$(jq '.comments | length' "$OUT/review-post.json")" -gt 0 ]; then
        gh api -X POST "repos/$REPO/pulls/$PR/reviews" --input "$OUT/review-post.json" > /dev/null \
          || echo "::warning::xsec-action: could not post the code review (needs pull-requests: write, and a checkout of the PR's head)"
      else
        log "code review: nothing new to comment on"
      fi
    fi
  fi
fi

# ---- 7. the verdict -----------------------------------------------------------

FINAL=0
if [ "$EXIT" -eq 2 ]; then
  echo "::error::xsec: $WHAT at or above '$FAIL_ON' on $URL (see the job summary)"
  FINAL=2
fi
if [ "$REVIEW_EXIT" -eq 2 ]; then
  echo "::error::xsec: the code review found problems at or above '$REVIEW_FAIL_ON' (see the comments on the pull request)"
  FINAL=2
elif [ "$REVIEW_EXIT" -ne 0 ]; then
  FINAL=1
fi
if [ "$DEPS_EXIT" -eq 2 ]; then
  echo "::error::xsec: dependencies with known problems at or above '$DEPS_FAIL_ON' (see the job summary)"
  FINAL=2
elif [ "$DEPS_EXIT" -ne 0 ] && [ "$FINAL" -eq 0 ]; then
  FINAL=1
fi
output exit-code "$FINAL"
exit "$FINAL"
