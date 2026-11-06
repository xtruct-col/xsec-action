#!/usr/bin/env bash
# The xsec Action's logic (action.yml only passes its inputs here as
# INPUT_* variables). Steps:
#   1. get the xsec CLI for this runner and check its sha256;
#   2. scan base-url (production) to JSON, if given: the baseline;
#   3. scan url (the preview) once: Markdown, JSON and the diff;
#   4. upload the JSON to the xsec dashboard, if a token is given;
#   5. write the job summary and a sticky pull-request comment;
#   6. exit with the CLI's code (0 ok, 2 new findings at/above fail-on, 1 could not run).
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
bool() {
  case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in
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
VERSION="$(trim "${INPUT_VERSION:-latest}")"
XSEC_API="$(trim "${INPUT_XSEC_API:-https://xsec-api.91.107.213.88.sslip.io}")"
XSEC_API="${XSEC_API%/}"
TOKEN="${INPUT_XSEC_TOKEN:-}"
RELEASE_BASE="${XSEC_RELEASE_BASE:-https://github.com/xtruct-col/xsec-action/releases}"
REPO="${GITHUB_REPOSITORY:-local/repo}"

case "$URL" in
  http://* | https://*) ;;
  "") fail "input url is required" ;;
  *) fail "input url must start with http:// or https://" ;;
esac
case "$BASE_URL" in
  "" | http://* | https://*) ;;
  *) fail "input base-url must start with http:// or https://" ;;
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
output exit-code "$EXIT"
if [ "$EXIT" -ne 0 ] && [ "$EXIT" -ne 2 ]; then
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

# ---- context: the pull request, the commit, a link ---------------------------

EVENT="${GITHUB_EVENT_PATH:-/dev/null}"
[ -f "$EVENT" ] || EVENT=/dev/null
ev() { jq -r "$1 // empty" "$EVENT" 2> /dev/null || true; }
SHA="$(ev '.pull_request.head.sha // .deployment.sha // .deployment_status.deployment.sha')"
SHA="${SHA:-${GITHUB_SHA:-}}"
PR="$(ev '.pull_request.number // .issue.number')"
if [ -z "$PR" ] && [ -n "$SHA" ] && { [ "$COMMENT" = "true" ] || [ -n "$TOKEN" ]; } && [ -n "${GH_TOKEN:-}" ] && command -v gh > /dev/null; then
  # deployment_status and push events carry no PR: find the open one for the commit.
  PR="$(gh api "repos/$REPO/commits/$SHA/pulls" --jq '[.[] | select(.state == "open")][0].number // empty' 2> /dev/null || true)"
fi
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/$REPO/actions/runs/${GITHUB_RUN_ID:-0}"
LINK="$(ev '.pull_request.html_url')"
if [ -z "$LINK" ] && [ -n "$PR" ]; then LINK="${GITHUB_SERVER_URL:-https://github.com}/$REPO/pull/$PR"; fi
LINK="${LINK:-$RUN_URL}"

# ---- 4. upload ----------------------------------------------------------------

DASHBOARD=""
if [ -n "$TOKEN" ]; then
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

# ---- 5. summary and comment ---------------------------------------------------

WHAT="findings"
[ -f "$OUT/diff.json" ] && WHAT="new findings (compared with $BASE_URL)"
MARKER="<!-- xsec-action -->"
comment="$OUT/comment.md"
{
  echo "$MARKER"
  if [ "$EXIT" -eq 2 ]; then
    echo "> [!CAUTION]"
    echo "> **xsec: this check fails**: $WHAT at or above \`$FAIL_ON\`."
    echo
  fi
  cat "$OUT/report.md"
  echo
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
  fi
fi

# ---- 6. the verdict -----------------------------------------------------------

if [ "$EXIT" -eq 2 ]; then
  echo "::error::xsec: $WHAT at or above '$FAIL_ON' on $URL (see the job summary)"
fi
exit "$EXIT"
