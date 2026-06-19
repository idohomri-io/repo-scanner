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
  local error_file="${CHECKOUT_ERROR_FILE:-/dev/null}"

  if [[ -d "$repo_ref" ]]; then
    mkdir -p "$checkout_dir"
    if git -C "$repo_ref" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$repo_ref" archive HEAD 2>"$error_file" | tar -x -C "$checkout_dir" 2>>"$error_file"
      return $?
    fi

    tar -C "$repo_ref" \
      --exclude=.git \
      --exclude=node_modules \
      --exclude=.venv \
      --exclude=venv \
      -cf - . 2>"$error_file" |
      tar -x -C "$checkout_dir" 2>>"$error_file"
    return $?
  fi

  clone_url="$(repo_clone_url "$repo_ref")"

  if auth_header="$(git_auth_header "$clone_url")"; then
    if ! git -c "http.extraheader=AUTHORIZATION: basic $auth_header" ls-remote --heads "$clone_url" >/dev/null 2>"$error_file"; then
      {
        echo "Read-access check failed before clone. The scanner only runs git ls-remote and git clone; it does not request write access."
        cat "$error_file"
      } > "${error_file}.tmp"
      mv "${error_file}.tmp" "$error_file"
      return 1
    fi
    git -c "http.extraheader=AUTHORIZATION: basic $auth_header" clone --depth 1 --quiet "$clone_url" "$checkout_dir" 2>"$error_file"
    return $?
  fi

  if ! git ls-remote --heads "$clone_url" >/dev/null 2>"$error_file"; then
    {
      echo "Read-access check failed before clone. The scanner only runs git ls-remote and git clone; it does not request write access."
      cat "$error_file"
    } > "${error_file}.tmp"
    mv "${error_file}.tmp" "$error_file"
    return 1
  fi

  git clone --depth 1 --quiet "$clone_url" "$checkout_dir" 2>"$error_file"
}

checkout_failure_hint() {
  local repo_ref="$1"
  local clone_url

  if [[ -d "$repo_ref" ]]; then
    echo "Check that the local path is mounted into the container and readable."
    return
  fi

  clone_url="$(repo_clone_url "$repo_ref")"

  case "$clone_url" in
    https://github.com/*)
      if [[ -z "${GH_TOKEN:-}" ]]; then
        echo "Set GH_TOKEN for private GitHub repos, or confirm the repo is public and the owner/name is correct."
      else
        echo "Use a GitHub fine-grained token for this repo with Contents: Read-only. GitHub may say 'Write access not granted' even when a read-only clone token is missing, not authorized for the repo, or blocked by org SSO."
      fi
      ;;
    https://gitlab.com/*)
      if [[ -z "${GITLAB_TOKEN:-}" ]]; then
        echo "Set GITLAB_TOKEN for private GitLab repos, or confirm the project URL is public and correct."
      else
        echo "Check that GITLAB_TOKEN has read_repository access to this project."
      fi
      ;;
    https://bitbucket.org/*)
      if [[ -z "${BITBUCKET_TOKEN:-}" ]]; then
        echo "Set BITBUCKET_USERNAME and BITBUCKET_TOKEN for private Bitbucket repos."
      else
        echo "Check that BITBUCKET_USERNAME/BITBUCKET_TOKEN have read access to this repository."
      fi
      ;;
    git@*|ssh://*)
      echo "Check that SSH keys and known_hosts are mounted into the container and can access this repo."
      ;;
    *)
      echo "Check that the repo URL is reachable from inside the container."
      ;;
  esac
}

sanitize_checkout_error() {
  local error_file="$1"

  if [[ ! -s "$error_file" ]]; then
    echo "No error output was captured from the checkout command."
    return
  fi

  tr '\n' ' ' < "$error_file" |
    sed -E \
      -e 's#https://[^/@[:space:]]+@#https://***@#g' \
      -e 's#(Authorization: basic )[A-Za-z0-9+/=]+#\1***#gi' \
      -e 's#(x-access-token:)[^[:space:]]+#\1***#gi' \
      -e 's#(oauth2:)[^[:space:]]+#\1***#gi' |
    cut -c 1-500
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
