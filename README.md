# Docker Betterleaks workspace scan

`betterleaks-scan` runs Betterleaks v2 against the Git worktree from which it
is invoked. It appends four redacted JSON Lines reports to a timestamped file:

- staged additions (`git --staged`)
- unstaged additions in tracked files (`git --unstaged`)
- untracked files not excluded by Git (`git ls-files --others --exclude-standard`)
- added content in commits in `origin/main..HEAD`

The scanner is detection-only. It does not validate, analyze, or revoke
credentials. Findings are written with `--redact=100`, so the report never
contains the matched secret values.

## Usage

```text
betterleaks-scan [--fetch] [--branch BRANCH] [--help]
```

`--fetch` (`-f`) runs `git fetch origin` before scanning. Use `--branch` (`-b`)
to compare commits against `origin/BRANCH`; it defaults to `origin/main`.

The script intentionally accepts no target path or Betterleaks pass-through
arguments: it always scans the invoking Git worktree using its fixed four-part
scope. Run `betterleaks-scan --help` for the complete CLI description,
environment variables, report location, and exit statuses.

## Install

```bash
install -Dm644 betterleaks-global.toml "$HOME/.config/betterleaks/global.toml"
install -Dm755 betterleaks-scan "$HOME/.local/bin/betterleaks-scan"
docker pull ghcr.io/betterleaks/betterleaks:v2
```

Add the shell function to `.bashrc` or `.zshrc` if you prefer a function name:

```bash
betterleaks() {
  command betterleaks-scan "$@"
}
```

Run `betterleaks-scan` from any directory within a Git repository. The report
is placed at `.betterleaks/scan-<UTC timestamp>.jsonl`; add `.betterleaks/` to
the repository's `.gitignore` if it is not already ignored.

Set `BETTERLEAKS_IMAGE` to override the container image or
`BETTERLEAKS_GLOBAL_CONFIG` to select another global policy file.

## Policy configuration

The global configuration extends Betterleaks' built-in rules and prefilters
`node_modules/`, `venv/`, and `.venv/` directories. Betterleaks v2 does not
automatically load project configuration files, so the script explicitly loads
`~/.config/betterleaks/global.toml`.

For per-workspace rules, copy `betterleaks-workspace.toml.example` to
`.betterleaks.local.toml` at the repository root. It extends the mounted global
policy; add a `prefilter` expression there for additional path exclusions.

`git ls-files --others --exclude-standard` honors `.gitignore`,
`.git/info/exclude`, and Git's global excludes for the untracked-file pass.
Git diff/history scans deliberately operate on tracked Git content, including a
file that is tracked but later added to `.gitignore`. Betterleaks does not
evaluate `.gitignore` itself. Add those paths explicitly to the workspace
`prefilter` when they must also be excluded from staged, unstaged, or committed
history scans.

Each report contains a small `scan_section` JSON record before each Betterleaks
JSONL stream. Betterleaks exits with status `1` if a scan finds secrets; the
script preserves that status while still completing the remaining scans.
