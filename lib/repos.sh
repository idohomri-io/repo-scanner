#!/usr/bin/env bash

read_repos() {
  local repos_file="$1"

  if [[ -n "${REPOS:-}" ]]; then
    IFS=',' read -ra REPOS <<< "$REPOS"
    for i in "${!REPOS[@]}"; do
      REPOS[$i]="$(printf '%s' "${REPOS[$i]}" | xargs)"
    done
    return
  fi

  if [[ ! -f "$repos_file" ]]; then
    echo "ERROR: $repos_file not found and no REPOS env var set." >&2
    exit 1
  fi

  mapfile -t REPOS < <(grep -vE '^\s*(#|$)' "$repos_file")
}

repo_display_name() {
  local repo_ref="$1"

  if [[ -d "$repo_ref" ]]; then
    basename "$repo_ref"
    return
  fi

  repo_ref="${repo_ref%.git}"
  repo_ref="${repo_ref#https://}"
  repo_ref="${repo_ref#http://}"
  repo_ref="${repo_ref#ssh://}"
  repo_ref="${repo_ref#git@}"
  repo_ref="${repo_ref/:/\/}"
  printf '%s\n' "$repo_ref"
}

safe_repo_dir() {
  printf '%s\n' "$1" | tr '/:@' '---' | tr -cd '[:alnum:]._-'
}

repo_clone_url() {
  local repo_ref="$1"

  if [[ "$repo_ref" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf 'https://github.com/%s.git\n' "$repo_ref"
    return
  fi

  printf '%s\n' "$repo_ref"
}

checkout_repo() {
  local repo_ref="$1"
  local checkout_dir="$2"
  local clone_url
  local auth_header

  if [[ -d "$repo_ref" ]]; then
    mkdir -p "$checkout_dir"
    if git -C "$repo_ref" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$repo_ref" archive HEAD | tar -x -C "$checkout_dir"
      return $?
    fi

    tar -C "$repo_ref" \
      --exclude=.git \
      --exclude=node_modules \
      --exclude=.venv \
      --exclude=venv \
      -cf - . |
      tar -x -C "$checkout_dir"
    return $?
  fi

  clone_url="$(repo_clone_url "$repo_ref")"

  if auth_header="$(git_auth_header "$clone_url")"; then
    git -c "http.extraheader=AUTHORIZATION: basic $auth_header" clone --depth 1 --quiet "$clone_url" "$checkout_dir" 2>/dev/null
    return $?
  fi

  git clone --depth 1 --quiet "$clone_url" "$checkout_dir" 2>/dev/null
}

git_auth_header() {
  local clone_url="$1"

  if [[ -n "${GH_TOKEN:-}" && "$clone_url" == https://github.com/* ]]; then
    printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n'
    return 0
  fi

  if [[ -n "${GITLAB_TOKEN:-}" && ( "$clone_url" == https://gitlab.com/* || "$clone_url" == https://*/gitlab/* ) ]]; then
    printf 'oauth2:%s' "$GITLAB_TOKEN" | base64 | tr -d '\n'
    return 0
  fi

  if [[ -n "${BITBUCKET_TOKEN:-}" && "$clone_url" == https://bitbucket.org/* ]]; then
    printf '%s:%s' "${BITBUCKET_USERNAME:-x-token-auth}" "$BITBUCKET_TOKEN" | base64 | tr -d '\n'
    return 0
  fi

  return 1
}

detect_manifests() {
  local repo_dir="$1"

  (cd "$repo_dir" && find . -type d \( \
      -name node_modules -o -name .venv -o -name venv -o -name vendor -o -name .git \
    \) -prune -o -type f \( \
      -name 'package.json' -o -name 'package-lock.json' -o -name 'yarn.lock' -o -name 'pnpm-lock.yaml' -o -name 'bun.lock' -o \
      -name 'requirements*.txt' -o -name 'pyproject.toml' -o -name 'poetry.lock' -o -name 'Pipfile*' -o \
      -name 'go.mod' -o -name 'go.sum' -o \
      -name 'Gemfile*' -o \
      -name 'pom.xml' -o -name 'build.gradle*' -o -name 'gradle.lockfile' -o \
      -name 'Cargo.toml' -o -name 'Cargo.lock' -o \
      -name 'composer.json' -o -name 'composer.lock' \
    \) -print) |
    sed 's|^\./||' |
    paste -sd ', ' -
}
