#!/usr/bin/env bash

run_osv_scan() {
  local repo_dir="$1"
  local output_file="$2"
  local scan_status

  osv-scanner scan --format json "$repo_dir" > "$output_file"
  scan_status=$?

  if [[ "$scan_status" -eq 0 || "$scan_status" -eq 1 ]]; then
    jq empty "$output_file" >/dev/null 2>&1
    return $?
  fi

  return "$scan_status"
}

normalize_osv_findings() {
  local repo="$1"
  local repo_dir="$2"
  local osv_json_file="$3"

  jq -c --arg repo "$repo" --arg repo_dir "$repo_dir" '
    def severity_rank($severity):
      if $severity == "critical" then 0
      elif $severity == "high" then 1
      elif $severity == "moderate" then 2
      elif $severity == "low" then 3
      else 4
      end;

    def fixed_versions:
      ([.affected[]?.ranges[]?.events[]?.fixed] | unique | join(", "));

    def relative_path:
      if startswith($repo_dir + "/") then .[($repo_dir | length) + 1:]
      else .
      end;

    .results[]? as $result |
    $result.source.path as $source |
    $result.packages[]? as $pkg |
    $pkg.vulnerabilities[]? as $vuln |
    ($vuln.database_specific.severity // "unknown" | ascii_downcase) as $severity |
    {
      repo: $repo,
      scanner: "osv-scanner",
      package: $pkg.package.name,
      ecosystem: ($pkg.package.ecosystem // "unknown"),
      installed_version: ($pkg.package.version // "unknown"),
      manifest: ($source | relative_path),
      vulnerability_id: $vuln.id,
      aliases: ($vuln.aliases // []),
      summary: ($vuln.summary // ""),
      details: ($vuln.details // ""),
      severity: $severity,
      severity_rank: severity_rank($severity),
      cvss: ($vuln.severity // []),
      fixed_version: (($vuln | fixed_versions) // ""),
      url: ("https://osv.dev/" + $vuln.id),
      recommendation: (
        if (($vuln | fixed_versions) // "") != "" then
          "Upgrade " + $pkg.package.name + " to " + ($vuln | fixed_versions) + " or later."
        else
          "No fixed version is listed yet; review advisory impact, consider mitigation, or suppress with justification."
        end
      )
    }
  ' "$osv_json_file"
}

generate_llm_summary() {
  local findings_file="$1"
  local provider="${LLM_PROVIDER:-none}"
  local endpoint="${LLM_ENDPOINT:-}"
  local model="${LLM_MODEL:-}"
  local api_key="${LLM_API_KEY:-}"

  if [[ "$provider" == "ollama" ]]; then
    endpoint="${endpoint:-http://localhost:11434}"
    model="${model:-llama3.1}"
    jq -n \
      --arg model "$model" \
      --arg prompt "$(llm_prompt "$findings_file")" \
      '{model: $model, stream: false, messages: [{role: "system", content: "You are a senior application security engineer. Be concise and practical."}, {role: "user", content: $prompt}]}' |
      curl -fsS "$endpoint/api/chat" -H 'Content-Type: application/json' -d @- |
      jq -r '.message.content'
    return
  fi

  endpoint="${endpoint:-https://api.openai.com/v1}"
  model="${model:-gpt-4.1-mini}"

  jq -n \
    --arg model "$model" \
    --arg prompt "$(llm_prompt "$findings_file")" \
    '{model: $model, messages: [{role: "system", content: "You are a senior application security engineer. Be concise and practical."}, {role: "user", content: $prompt}], temperature: 0.2}' |
    curl -fsS "$endpoint/chat/completions" \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $api_key" \
      -d @- |
    jq -r '.choices[0].message.content'
}

llm_prompt() {
  local findings_file="$1"
  local compact_findings

  compact_findings="$(jq -c '[.[] | {repo, severity, package, installed_version, fixed_version, manifest, vulnerability_id, summary, recommendation}] | .[:40]' "$findings_file")"

  cat <<EOF
Summarize these vulnerability scan findings for a developer who owns the repos.

Return Markdown with:
- the top 3 fixes to do first
- any packages that can likely be fixed by a direct version bump
- any findings that need manual investigation

Keep it short and avoid inventing facts not present in the JSON.

Findings JSON:
$compact_findings
EOF
}
