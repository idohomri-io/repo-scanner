#!/usr/bin/env bash

severity_emoji() {
  case "$1" in
    critical) echo "CRITICAL" ;;
    high) echo "HIGH" ;;
    moderate) echo "MODERATE" ;;
    low) echo "LOW" ;;
    *) echo "UNKNOWN" ;;
  esac
}

md_escape() {
  printf '%s' "${1:-}" | sed 's/|/\\|/g'
}

report_header() {
  local date_str="$1" repo_count="$2"
  cat <<EOF
# Dependency Vulnerability Scan - $date_str

Scanned $repo_count repo(s) with local scanner adapters. OSV-Scanner is the default vulnerability source.

EOF
}

report_repo_section() {
  local repo="$1" manifests="$2"
  echo "## $repo"
  echo ""
  echo "Manifests detected: ${manifests:-none found}"
  echo ""
}

report_no_findings() {
  echo "No known vulnerabilities found."
  echo ""
}

report_repo_findings_count() {
  local count="$1"
  echo "$count known vulnerabilit$( [[ "$count" == "1" ]] && echo "y" || echo "ies" ) found."
  echo ""
}

report_repo_failed() {
  local message="$1"
  echo "Scan failed: $message"
  echo ""
}

report_finding_table_header() {
  echo "| Severity | Repo | Package | Installed | Fixed | Manifest | Advisory | Recommendation |"
  echo "|---|---|---|---|---|---|---|---|"
}

report_finding_row() {
  local severity="$1" repo="$2" package="$3" installed="$4" fixed="$5" manifest="$6" vuln_id="$7" url="$8" recommendation="$9"
  local label
  label="$(severity_emoji "$severity")"

  echo "| $(md_escape "$label") | $(md_escape "$repo") | $(md_escape "$package") | $(md_escape "$installed") | $(md_escape "${fixed:-not listed}") | $(md_escape "$manifest") | [$(md_escape "$vuln_id")]($url) | $(md_escape "$recommendation") |"
}

report_llm_summary() {
  local summary="$1"
  echo "## Recommended Next Steps"
  echo ""
  printf '%s\n' "$summary"
  echo ""
}

report_failed_repos() {
  local failed_file="$1"
  echo "## Failed Repos"
  echo ""
  while IFS= read -r repo; do
    echo "- $repo"
  done < "$failed_file"
  echo ""
}

report_summary() {
  local critical="$1" high="$2" moderate="$3" low="$4" unknown="$5" failed="$6"
  echo "## Summary"
  echo ""
  echo "- Critical: $critical"
  echo "- High: $high"
  echo "- Moderate: $moderate"
  echo "- Low: $low"
  echo "- Unknown: $unknown"
  echo "- Failed repos: $failed"
}
