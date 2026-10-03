#!/usr/bin/env bash
# Scan a Git workspace with Betterleaks v2 running in Docker.
set -uo pipefail

: "${BETTERLEAKS_IMAGE:=ghcr.io/betterleaks/betterleaks:latest}"
: "${BETTERLEAKS_GLOBAL_CONFIG:=$HOME/git/betterleaks-scripts/betterleaks-global.toml}"

usage() {
  cat <<'EOF'
Usage: betterleaks-scan [--fetch] [--branch BRANCH] [--help]

Scan the invoking Git worktree with Betterleaks running in Docker. Run from any
directory inside the worktree. The script requires the selected origin branch.

The scan includes:
  staged       Added lines staged in the Git index.
  unstaged     Added lines in modified tracked files.
  untracked    Untracked files not ignored by Git.
  committed    Added content in commits reachable from HEAD but not the selected
               origin comparison branch.

Options:
  -f, --fetch  Run `git fetch origin` before resolving the comparison branch.
  -b, --branch BRANCH
                Compare committed changes with origin/BRANCH instead of
                origin/main. Default: main.
  -h, --help   Show this help text and exit.

Environment:
  BETTERLEAKS_IMAGE          Container image to run.
                              Default: ghcr.io/betterleaks/betterleaks:latest
  BETTERLEAKS_GLOBAL_CONFIG  Readable global Betterleaks TOML policy.
                              Default: ~/.config/betterleaks/global.toml

Workspace configuration:
  A readable .betterleaks.local.toml in the worktree root overrides the global
  configuration and must extend /config/global.toml. See the example template.

Output:
  A redacted JSONL report is created at
  <worktree>/.betterleaks/scan-<UTC timestamp>.jsonl. The report contains a
  scan_section record before each Betterleaks JSONL stream.

Exit status:
  0  No findings and all scans completed successfully.
  1  Betterleaks found one or more secrets in at least one scan.
  2  Script setup or argument error.
EOF
}

die() {
  printf 'betterleaks-scan: %s\n' "$*" >&2
  exit 2
}

fetch=false
branch=main
while (($#)); do
  case "$1" in
    -f|--fetch)
      fetch=true
      ;;
    -b|--branch)
      shift
      [ -n "${1-}" ] || die 'missing branch name after --branch'
      branch=$1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
  shift
done

repo=$(git rev-parse --show-toplevel 2>/dev/null) || die 'run this from a Git worktree'
cd "$repo" || exit 2

command -v docker >/dev/null || die 'docker is required'
[ -r "$BETTERLEAKS_GLOBAL_CONFIG" ] || die "global config is unreadable: $BETTERLEAKS_GLOBAL_CONFIG"
if "$fetch"; then
  git fetch origin || die 'git fetch origin failed'
fi
base_ref="origin/$branch"
git rev-parse --verify --quiet "$base_ref" >/dev/null || die "$base_ref is not available; fetch it first or use --fetch"

workspace_config="$repo/.betterleaks.local.toml"
config_mounts=(
  --mount "type=bind,src=$BETTERLEAKS_GLOBAL_CONFIG,dst=/config/global.toml,readonly"
)
config_path=/config/global.toml
if [ -r "$workspace_config" ]; then
  config_mounts+=(--mount "type=bind,src=$workspace_config,dst=/config/workspace.toml,readonly")
  config_path=/config/workspace.toml
fi

log_dir="$repo/.betterleaks"
mkdir -p "$log_dir" || die "cannot create $log_dir"
log_file="$log_dir/scan-$(date -u +%Y%m%dT%H%M%SZ).jsonl"

docker_args=(
  docker run --rm
  --mount "type=bind,src=$repo,dst=/repo,readonly"
  "${config_mounts[@]}"
  --workdir /repo
  "$BETTERLEAKS_IMAGE"
)

run_scan() {
  local name=$1
  shift
  printf '{"scan_section":"%s"}\n' "$name" >>"$log_file"
  "${docker_args[@]}" "$@" \
    --config "$config_path" \
    --redact=100 \
    --jsonl \
    --output - \
    --silent >>"$log_file"
}

status=0
run_scan staged git /repo --staged || status=$?
run_scan unstaged git /repo --unstaged || status=$?

# --exclude-standard applies .gitignore, .git/info/exclude, and the configured
# global Git excludes. It intentionally applies only to untracked files: Git
# diff modes scan tracked content even if it later becomes ignored.
untracked=()
while IFS= read -r -d '' path; do
  untracked+=("/repo/$path")
done < <(git ls-files --others --exclude-standard -z)
if ((${#untracked[@]})); then
  run_scan untracked fs "${untracked[@]}" || status=$?
else
  printf '{"scan_section":"untracked","skipped":"no non-ignored untracked files"}\n' >>"$log_file"
fi

# Scan added content from every local commit not reachable from the comparison ref.
run_scan committed git /repo --log-opts="$base_ref..HEAD" || status=$?

printf 'Redacted Betterleaks report: %s\n' "$log_file"
exit "$status"
