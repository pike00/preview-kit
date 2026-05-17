# preview-kit

[![CI](https://github.com/pike00/preview-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/pike00/preview-kit/actions/workflows/ci.yml)

Shared per-worktree dev stack recipes for solo-developer git repos that use
[git worktrees](https://git-scm.com/docs/git-worktree) for parallel feature
development. Drop a symlink and a TOML file into any repo and get isolated,
Traefik-routed dev stacks with zero per-worktree configuration.

## What it provides

Importing `preview.just` into a repo's `justfile` adds 11 recipes:

| Recipe | What it does |
|---|---|
| `env` | Print all worktree env vars (SLUG, COMPOSE_PROJECT_NAME, WORKTREE_HOST, ports, PREVIEW_*) |
| `dev` | Bring the worktree stack up at `<slug>.<project>.<domain>` — builds images, threads GIT_HASH + APP_VERSION |
| `down` | Stop containers, keep volumes |
| `down-clean` | Stop containers AND delete volumes |
| `logs [svc]` | Tail compose logs |
| `ps` | Show stack container status |
| `shell` | Exec bash in the shell_service container |
| `pytest [...]` | Run pytest in the test_service container |
| `worktree <slug>` | Create/resume `.worktrees/<slug>` and `just dev` |
| `worktree-rm <slug>` | `just down-clean` and remove the worktree |
| `pr` | Push branch, wait for health, create draft GitHub PR |

## Adopt in a new repo

```bash
cd ~/projects/<new-repo>

# 1. Symlink preview.just — MUST be absolute so it resolves from .worktrees/<slug>/
ln -sf "$(git -C ~/projects/preview-kit rev-parse --show-toplevel)/preview.just" preview.just

# 2. Create preview-kit.toml (see preview-kit.example.toml for all options)
cat > preview-kit.toml <<'EOF'
[preview-kit]
project_prefix = "<prefix>"
host_pattern = "{slug}.<name>.example.com"
compose_file = "compose.worktree.yml"
health_path = "/api/health"
base = "main"
shell_service = "app"
test_service = "app"
test_command = "pytest"
EOF

# 3. Add to your main justfile
echo "import 'preview.just'" >> justfile
```

## `preview-kit.toml` reference

```toml
[preview-kit]
# Required
project_prefix = "myapp"           # COMPOSE_PROJECT_NAME = {prefix}-{slug}
host_pattern = "{slug}.myapp.example.com"  # {slug} and {domain} are substituted
compose_file = "compose.worktree.yml"

# Optional (shown with defaults)
health_path = "/api/health"        # used by `pr` recipe health check
base = "main"                      # base branch for pr recipe + ahead/behind display
shell_service = "app"              # container targeted by `just shell`
test_service = "app"               # container targeted by `just pytest`
test_command = "pytest"            # command run inside test_service by `just pytest`

# Optional: host-published ports (offset per worktree to avoid collisions)
[preview-kit.ports]
APP_PORT = 8000                    # exported as APP_PORT=<base + per-slug offset>
DB_PORT = 5432
```

### Port offset formula

Each port gets a deterministic per-slug offset so worktrees never collide:

```
offset = int(sha1(slug.encode()).hexdigest()[:4], 16) % 1000
```

The same formula works in bash (`printf %s "$slug" | sha1sum | head -c 4`).

### `{domain}` substitution

`host_pattern` supports `{slug}` and `{domain}`. `{domain}` is read from the
`DOMAIN=` line in the main repo's `.env`, defaulting to `example.com`.

## How `env` works

The `env` recipe runs a Python 3.11+ `#!/usr/bin/env python3` shebang using
`tomllib` (stdlib). It emits `KEY=VALUE` lines safe for:

```bash
eval "$(just env | sed 's/^/export /')"
```

All other recipes source `just env` this way, so `COMPOSE_PROJECT_NAME`,
`WORKTREE_HOST`, and all port vars flow through automatically.

## The `pr` recipe

`just pr` from a worktree:

1. Checks the branch has commits ahead of `base`.
2. `git push -u origin <branch>`.
3. Polls `https://{WORKTREE_HOST}{health_path}` for up to 120s.
4. Creates a draft GitHub PR (via `gh`) with the preview URL and `git log` in
   the body.

Skips PR creation (prints stack URL and exits 0) if 0 commits ahead of base.

## Relative vs absolute symlinks

`release.just` uses relative symlinks (`../_templates/release.just`) because
release recipes only ever run from the main repo root.

`preview.just` **must** use absolute symlinks — worktrees live at
`.worktrees/<slug>/` and a relative symlink would try to resolve
`../../_templates/preview.just` from the worktree path, which doesn't exist.

## Consumer repos

- [kindred](https://github.com/pike00/Kindred)
- [finance-hub](https://github.com/pike00/finance-hub)
- [plaid-sync](https://github.com/pike00/plaid-sync)
