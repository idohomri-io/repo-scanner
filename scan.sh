#!/usr/bin/env bash
set -uo pipefail

export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_FILE="$SCRIPT_DIR/repos.txt"
REPORT_DIR="${REPORT_DIR:-$SCRIPT_DIR/reports}"
DATE_STR="$(date +%F)"
REPORT_FILE="$REPORT_DIR/$DATE_STR.md"
FINDINGS_FILE="$REPORT_DIR/$DATE_STR.findings.json"

# shellcheck source=lib/repos.sh
source "$SCRIPT_DIR/lib/repos.sh"
# shellcheck source=lib/report.sh
source "$SCRIPT_DIR/lib/report.sh"
# shellcheck source=lib/scanners/osv.sh
source "$SCRIPT_DIR/lib/scanners/osv.sh"

mkdir -p "$REPORT_DIR"

for bin in git jq curl osv-scanner; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: '$bin' is required but not found on PATH." >&2
    exit 1
  fi
done

read_repos "$REPOS_FILE"

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "ERROR: no repos listed (checked REPOS env var and $REPOS_FILE)." >&2
  exit 1
fi

BODY_FILE="$(mktemp)"
FINDINGS_NDJSON="$(mktemp)"
FAILED_FILE="$(mktemp)"
REPO_STATES_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE" "$FINDINGS_NDJSON" "$FAILED_FILE" "$REPO_STATES_FILE"; [[ -n "${WORK_ROOT:-}" ]] && rm -rf "$WORK_ROOT"' EXIT

WORK_ROOT="$(mktemp -d)"

CRITICAL=0
HIGH=0
MODERATE=0
LOW=0
UNKNOWN=0
FAILED=0

prune_old_reports() {
  local report_dir="$1" keep="$2"
  local dates
  mapfile -t dates < <(cd "$report_dir" && ls -1 *.state.json 2>/dev/null | sed 's/\.state\.json$//' | sort -r)

  if [[ ${#dates[@]} -le $keep ]]; then
    return
  fi

  local d
  for d in "${dates[@]:$keep}"; do
    rm -f "$report_dir/$d.md" "$report_dir/$d.findings.json" "$report_dir/$d.state.json" "$report_dir/$d.webhook.json"
  done
}

record_repo_state() {
  local repo="$1" status="$2" manifests="$3" error="${4:-}"

  jq -c -n \
    --arg repo "$repo" \
    --arg status "$status" \
    --arg manifests "$manifests" \
    --arg error "$error" \
    '{
      repo: $repo,
      status: $status,
      manifests: (if $manifests == "" then [] else $manifests | split(", ") end),
      error: (if $error == "" then null else $error end)
    }' >> "$REPO_STATES_FILE"
}

for repo_ref in "${REPOS[@]}"; do
  repo_name="$(repo_display_name "$repo_ref")"
  echo "Scanning $repo_name..."

  CHECKOUT_DIR="$WORK_ROOT/$(safe_repo_dir "$repo_name")"
  CHECKOUT_ERROR_FILE="$(mktemp)"
  if ! checkout_repo "$repo_ref" "$CHECKOUT_DIR"; then
    checkout_error="$(sanitize_checkout_error "$CHECKOUT_ERROR_FILE")"
    checkout_hint="$(checkout_failure_hint "$repo_ref")"
    failure_message="Could not clone or read this repo. $checkout_error Hint: $checkout_hint"
    rm -f "$CHECKOUT_ERROR_FILE"
    echo "  WARNING: failed to prepare $repo_name: $checkout_error" >&2
    report_repo_section "$repo_name" "" >> "$BODY_FILE"
    report_repo_failed "$failure_message" >> "$BODY_FILE"
    record_repo_state "$repo_name" "failed" "" "$failure_message"
    printf '%s\n' "$repo_name" >> "$FAILED_FILE"
    FAILED=$((FAILED + 1))
    continue
  fi
  rm -f "$CHECKOUT_ERROR_FILE"

  MANIFESTS="$(detect_manifests "$CHECKOUT_DIR")"
  report_repo_section "$repo_name" "$MANIFESTS" >> "$BODY_FILE"

  OSV_JSON_FILE="$(mktemp)"
  if ! run_osv_scan "$CHECKOUT_DIR" "$OSV_JSON_FILE"; then
    echo "  WARNING: OSV scan failed for $repo_name." >&2
    report_repo_failed "OSV-Scanner failed before producing valid JSON." >> "$BODY_FILE"
    record_repo_state "$repo_name" "failed" "$MANIFESTS" "OSV-Scanner failed before producing valid JSON."
    printf '%s\n' "$repo_name" >> "$FAILED_FILE"
    rm -f "$OSV_JSON_FILE"
    FAILED=$((FAILED + 1))
    continue
  fi

  REPO_FINDINGS="$(normalize_osv_findings "$repo_name" "$CHECKOUT_DIR" "$OSV_JSON_FILE")"
  rm -f "$OSV_JSON_FILE"

  FINDING_COUNT="$(printf '%s\n' "$REPO_FINDINGS" | jq -s 'length')"
  if [[ "$FINDING_COUNT" -eq 0 ]]; then
    report_no_findings >> "$BODY_FILE"
    record_repo_state "$repo_name" "clean" "$MANIFESTS"
    continue
  fi

  printf '%s\n' "$REPO_FINDINGS" >> "$FINDINGS_NDJSON"
  report_repo_findings_count "$FINDING_COUNT" >> "$BODY_FILE"
  record_repo_state "$repo_name" "vulnerable" "$MANIFESTS"
done

if [[ -s "$FINDINGS_NDJSON" ]]; then
  jq -s 'sort_by(.severity_rank, .repo, .package, .vulnerability_id)' "$FINDINGS_NDJSON" > "$FINDINGS_FILE"
else
  printf '[]\n' > "$FINDINGS_FILE"
fi

STATE_FILE="$REPORT_DIR/$DATE_STR.state.json"
jq -s '.' "$REPO_STATES_FILE" > "$STATE_FILE"

while IFS=$'\t' read -r severity count; do
  case "$severity" in
    critical) CRITICAL="$count" ;;
    high) HIGH="$count" ;;
    moderate) MODERATE="$count" ;;
    low) LOW="$count" ;;
    unknown) UNKNOWN="$count" ;;
  esac
done < <(jq -r 'group_by(.severity)[]? | [.[0].severity, length] | @tsv' "$FINDINGS_FILE")

LLM_SUMMARY=""
if [[ "${LLM_PROVIDER:-none}" != "none" && "$(jq 'length' "$FINDINGS_FILE")" -gt 0 ]]; then
  if LLM_SUMMARY="$(generate_llm_summary "$FINDINGS_FILE" 2>/dev/null)"; then
    :
  else
    echo "WARNING: failed to generate LLM recommendations — continuing without them." >&2
    LLM_SUMMARY=""
  fi
fi

REPORT_CONTENT="$( {
  report_header "$DATE_STR" "${#REPOS[@]}"
  cat "$BODY_FILE"

  if [[ "$(jq 'length' "$FINDINGS_FILE")" -gt 0 ]]; then
    echo "## Open Vulnerabilities"
    echo ""
    report_finding_table_header
    jq -r '.[] | [.severity, .repo, .package, .installed_version, .fixed_version, .manifest, .vulnerability_id, .url, .recommendation] | @tsv' "$FINDINGS_FILE" |
      while IFS=$'\t' read -r severity repo package installed fixed manifest vuln_id url recommendation; do
        report_finding_row "$severity" "$repo" "$package" "$installed" "$fixed" "$manifest" "$vuln_id" "$url" "$recommendation"
      done
    echo ""
  fi

  if [[ -n "$LLM_SUMMARY" ]]; then
    report_llm_summary "$LLM_SUMMARY"
  fi

  if [[ -s "$FAILED_FILE" ]]; then
    report_failed_repos "$FAILED_FILE"
  fi

  report_summary "$CRITICAL" "$HIGH" "$MODERATE" "$LOW" "$UNKNOWN" "$FAILED"
} )"

if printf '%s\n' "$REPORT_CONTENT" > "$REPORT_FILE" 2>/dev/null; then
  echo "Report written to $REPORT_FILE"
  echo "Findings JSON written to $FINDINGS_FILE"
else
  echo "WARNING: could not write report to $REPORT_FILE — continuing without persisting to disk." >&2
fi

echo "$REPORT_CONTENT"

if [[ -n "${WEBHOOK_URL:-}" ]]; then
  PAYLOAD="$(jq -n \
    --arg date "$DATE_STR" \
    --slurpfile repos "$REPO_STATES_FILE" \
    --slurpfile findings "$FINDINGS_FILE" \
    '
    def severity_counts($items):
      {
        critical: ($items | map(select(.severity == "critical")) | length),
        high: ($items | map(select(.severity == "high")) | length),
        moderate: ($items | map(select(.severity == "moderate")) | length),
        low: ($items | map(select(.severity == "low")) | length),
        unknown: ($items | map(select(.severity == "unknown")) | length)
      };

    $repos | map(. as $repo_state |
      ($findings[0] | map(select(.repo == $repo_state.repo))) as $repo_findings |
      {
        date: $date,
        repo: $repo_state.repo,
        status: $repo_state.status,
        manifests: $repo_state.manifests,
        summary: (severity_counts($repo_findings) + {failed: (if $repo_state.status == "failed" then 1 else 0 end)}),
        findings: $repo_findings,
        error: $repo_state.error
      }
    )')"

  WEBHOOK_SUCCESS="true"
  if ! curl -fsS -X POST -H 'Content-Type: application/json' -d "$PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1; then
    echo "WARNING: failed to POST results to WEBHOOK_URL — continuing." >&2
    WEBHOOK_SUCCESS="false"
  fi

  jq -n --argjson success "$WEBHOOK_SUCCESS" --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{success: $success, checked_at: $checked_at}' > "$REPORT_DIR/$DATE_STR.webhook.json"
fi

prune_old_reports "$REPORT_DIR" "${REPORT_RETENTION_DAYS:-10}"

if [[ $CRITICAL -gt 0 || $HIGH -gt 0 || $FAILED -gt 0 ]]; then
  exit 1
fi
exit 0
