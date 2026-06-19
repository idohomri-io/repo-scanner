# Repo Scanner

Small daemon for scanning your repositories for vulnerable dependencies.

The scanner is platform-independent by design:

1. Read repos from `REPOS` or `repos.txt`.
2. Clone each repo, or snapshot a local path.
3. Run scanner adapters against the checked-out source.
4. Normalize findings to JSON.
5. Write Markdown and JSON reports.
6. Optionally post the results to a webhook and ask an LLM for a concise remediation summary.

OSV-Scanner is the default vulnerability source. The LLM is optional and is used only to explain and prioritize scanner findings, not to decide whether a dependency is vulnerable.

## Configure

Copy `.env.example` to `.env` and edit it:

```sh
cp .env.example .env
```

Repos can be configured as a comma-separated `REPOS` value or in `repos.txt`.

Supported repo formats:

```text
owner/repo
https://github.com/owner/repo.git
https://gitlab.com/group/project.git
https://bitbucket.org/workspace/project.git
git@gitlab.com:group/project.git
/absolute/path/to/local/repo
```

For private HTTPS repos, set the matching provider token:

```env
GH_TOKEN=...
GITLAB_TOKEN=...
BITBUCKET_USERNAME=your-bitbucket-username
BITBUCKET_TOKEN=...
```

GitHub `owner/repo` shorthand expands to `https://github.com/owner/repo.git` and uses `GH_TOKEN` when set.

For SSH Git URLs, mount/provide SSH credentials to the container environment.

## Run

```sh
docker compose up --build
```

Reports are written to `reports/YYYY-MM-DD.md` and normalized findings to `reports/YYYY-MM-DD.findings.json`.

## Optional LLM Recommendations

Disable LLM output:

```env
LLM_PROVIDER=none
```

Use Ollama:

```env
LLM_PROVIDER=ollama
LLM_ENDPOINT=http://host.docker.internal:11434
LLM_MODEL=llama3.1
```

Use an OpenAI-compatible API:

```env
LLM_PROVIDER=openai-compatible
LLM_ENDPOINT=https://api.openai.com/v1
LLM_MODEL=gpt-4.1-mini
LLM_API_KEY=...
```

## Exit Codes

`scan.sh` exits with `1` when it finds critical/high vulnerabilities or when at least one repo failed to scan. The daemon entrypoint logs that and keeps running on the configured interval.
