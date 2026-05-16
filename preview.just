# Shared preview-kit recipes — per-worktree dev stacks with Traefik routing.
# Import this in your repo's justfile:
#   import 'preview.just'   (via absolute symlink → _templates/preview.just)
# Requires preview-kit.toml at the repo root.
#
# Recipes provided:
#   env          — print worktree env vars (SLUG, COMPOSE_PROJECT_NAME, WORKTREE_HOST, ports, PREVIEW_*)
#   up           — bring the worktree stack up (builds images, prints URL)
#   down         — stop containers, keep volumes
#   down-clean   — stop containers AND delete volumes
#   logs [svc]   — tail compose logs
#   ps           — show stack container status
#   shell        — exec bash in the shell_service container
#   pytest [...]  — run pytest in the test_service container
#   worktree <slug>    — create/resume .worktrees/<slug> and `just up`
#   worktree-rm <slug> — `just down-clean` and remove the worktree
#   pr           — push branch, wait for health, create draft GitHub PR

# Print the env vars this worktree resolves to.
# Reads preview-kit.toml via Python's stdlib tomllib (Python 3.11+).
# Output is KEY=VALUE lines safe for: eval "$(just env | sed 's/^/export /')"
env:
    #!/usr/bin/env python3
    import os, subprocess, hashlib, tomllib

    with open("preview-kit.toml", "rb") as f:
        cfg = tomllib.load(f)["preview-kit"]

    toplevel = subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], text=True
    ).strip()
    slug = os.path.basename(toplevel)

    h = hashlib.sha1(slug.encode()).hexdigest()
    offset = int(h[:4], 16) % 1000

    git_common = subprocess.check_output(
        ["git", "rev-parse", "--git-common-dir"], text=True
    ).strip()
    main_repo = os.path.dirname(os.path.realpath(git_common))
    env_path = os.path.join(main_repo, ".env")
    domain = "khanpikehome.com"
    if os.path.exists(env_path):
        for line in open(env_path):
            if line.startswith("DOMAIN="):
                domain = line[7:].strip().strip('"').strip("'")
                break

    prefix = cfg["project_prefix"]
    host = cfg["host_pattern"].replace("{slug}", slug).replace("{domain}", domain)

    print(f"SLUG={slug}")
    print(f"COMPOSE_PROJECT_NAME={prefix}-{slug}")
    print(f"WORKTREE_HOST={host}")
    print(f"PREVIEW_COMPOSE_FILE={cfg.get('compose_file', 'compose.worktree.yml')}")
    print(f"PREVIEW_HEALTH_PATH={cfg.get('health_path', '/api/health')}")
    print(f"PREVIEW_BASE_BRANCH={cfg.get('base', 'main')}")
    print(f"PREVIEW_SHELL_SERVICE={cfg.get('shell_service', 'app')}")
    test_svc = cfg.get("test_service", cfg.get("shell_service", "app"))
    print(f"PREVIEW_TEST_SERVICE={test_svc}")
    print(f"PREVIEW_TEST_COMMAND={cfg.get('test_command', 'pytest')}")

    for name, base in cfg.get("ports", {}).items():
        print(f"{name}={base + offset}")

# Bring the worktree stack up. Symlinks .env from the main repo if missing.
up:
    #!/usr/bin/env bash
    set -euo pipefail
    toplevel="$(git rev-parse --show-toplevel)"
    main_repo="$(dirname "$(git rev-parse --git-common-dir | xargs -I{} readlink -f {})")"
    [ -f .env ] || ln -s "$main_repo/.env" .env
    set -a; . ./.env; set +a
    eval "$(just env | sed 's/^/export /')"
    branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo 'detached')"
    head_line="$(git log -1 --format='%h %s' 2>/dev/null || echo 'unknown')"
    dirty="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    echo "▶ project:  $COMPOSE_PROJECT_NAME"
    echo "  branch:   $branch"
    echo "  HEAD:     $head_line"
    if [ "$dirty" -gt 0 ]; then
        echo "  dirty:    $dirty file(s) uncommitted"
    fi
    echo "  worktree: $toplevel"
    if [ -L .env ]; then
        echo "  .env:     symlink → $(readlink .env)"
    else
        echo "  .env:     local file"
    fi
    echo
    echo "  app:      https://$WORKTREE_HOST           ← open this"
    # Print any port vars emitted by just env
    while IFS='=' read -r key val; do
        case "$key" in
            *_PORT) echo "    $key: $val" ;;
        esac
    done < <(just env)
    echo
    echo "▶ building images and starting containers..."
    docker compose -f "$PREVIEW_COMPOSE_FILE" up -d --build
    echo
    echo "✓ stack up. Tail logs with 'just logs'."

# Stop and remove containers but keep volumes (DB data survives).
down:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just env | sed 's/^/export /')"
    docker compose -f "$PREVIEW_COMPOSE_FILE" down

# Stop and remove containers AND volumes (fresh DB on next up).
down-clean:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just env | sed 's/^/export /')"
    docker compose -f "$PREVIEW_COMPOSE_FILE" down -v

# Tail logs across all services. Pass a service name to scope: just logs backend
logs *args:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just env | sed 's/^/export /')"
    docker compose -f "$PREVIEW_COMPOSE_FILE" logs -f {{args}}

# Show worktree stack status.
ps:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just env | sed 's/^/export /')"
    docker compose -f "$PREVIEW_COMPOSE_FILE" ps

# Open a bash shell inside the shell_service container.
shell:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just env | sed 's/^/export /')"
    docker compose -f "$PREVIEW_COMPOSE_FILE" exec "$PREVIEW_SHELL_SERVICE" bash

# Run the test suite inside the test_service container.
pytest *args:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just env | sed 's/^/export /')"
    docker compose -f "$PREVIEW_COMPOSE_FILE" exec -T "$PREVIEW_TEST_SERVICE" $PREVIEW_TEST_COMMAND {{args}}

# Create-if-missing a worktree at .worktrees/<slug> on a new branch named
# <slug> (or resume if it already exists), then bring its stack up.
worktree slug:
    #!/usr/bin/env bash
    set -euo pipefail
    main_repo="$(dirname "$(git rev-parse --git-common-dir | xargs -I{} readlink -f {})")"
    wt_path="$main_repo/.worktrees/{{slug}}"
    base_branch="$(git -C "$main_repo" symbolic-ref --short HEAD 2>/dev/null || echo 'main')"
    if [ ! -d "$wt_path" ]; then
        echo "▶ Creating new worktree"
        echo "  path:   $wt_path"
        echo "  base:   $base_branch ($(git -C "$main_repo" log -1 --format='%h %s'))"
        echo "  branch: {{slug}}  (new)"
        echo
        git -C "$main_repo" worktree add "$wt_path" -b "{{slug}}"
    else
        echo "▶ Reusing existing worktree"
        echo "  path:   $wt_path"
        wt_branch="$(git -C "$wt_path" symbolic-ref --short HEAD 2>/dev/null || echo 'detached')"
        wt_head="$(git -C "$wt_path" log -1 --format='%h %s' 2>/dev/null || echo 'unknown')"
        ahead="$(git -C "$wt_path" rev-list --count "${base_branch}..HEAD" 2>/dev/null || echo '?')"
        behind="$(git -C "$wt_path" rev-list --count "HEAD..${base_branch}" 2>/dev/null || echo '?')"
        dirty="$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
        echo "  branch: $wt_branch  (ahead $ahead, behind $behind vs $base_branch)"
        echo "  HEAD:   $wt_head"
        if [ "$dirty" -gt 0 ]; then
            echo "  dirty:  $dirty uncommitted file(s):"
            git -C "$wt_path" status --short | sed 's/^/            /'
        else
            echo "  dirty:  clean"
        fi
        echo
    fi
    cd "$wt_path"
    just up
    eval "$(just env | sed 's/^/export /')"
    echo
    echo "▶ Starting on https://$WORKTREE_HOST"

# Tear down a worktree's stack (with volumes) and remove the worktree itself.
worktree-rm slug:
    #!/usr/bin/env bash
    set -euo pipefail
    main_repo="$(dirname "$(git rev-parse --git-common-dir | xargs -I{} readlink -f {})")"
    wt_path="$main_repo/.worktrees/{{slug}}"
    if [ ! -d "$wt_path" ]; then
        echo "no worktree at $wt_path — nothing to do"
        exit 0
    fi
    (cd "$wt_path" && just down-clean) || true
    git -C "$main_repo" worktree remove "$wt_path" --force
    echo "✓ removed worktree '{{slug}}' (branch left intact — delete with 'git branch -D {{slug}}')"

# Push branch, wait for stack health check, create a draft GitHub PR.
# Skips PR creation if no commits ahead of base branch (prints URL and exits 0).
# Requires: stack already up via `just up`, gh CLI authenticated.
pr:
    #!/usr/bin/env bash
    set -euo pipefail
    eval "$(just env | sed 's/^/export /')"
    branch="$(git symbolic-ref --short HEAD 2>/dev/null)"
    if [ -z "$branch" ]; then
        echo "ERROR: detached HEAD — checkout a branch before creating a PR" >&2
        exit 1
    fi
    preview_url="https://$WORKTREE_HOST"
    health_url="${preview_url}${PREVIEW_HEALTH_PATH}"
    ahead="$(git rev-list --count "${PREVIEW_BASE_BRANCH}..HEAD" 2>/dev/null || echo 0)"
    if [ "$ahead" -eq 0 ]; then
        echo "No commits ahead of '$PREVIEW_BASE_BRANCH'. Preview stack:"
        echo "  $preview_url"
        exit 0
    fi
    echo "▶ pushing branch '$branch' to origin..."
    git push -u origin "$branch"
    echo
    echo "▶ waiting for health check at $health_url (timeout 120s)..."
    deadline=$((SECONDS + 120))
    while [ $SECONDS -lt $deadline ]; do
        if curl -fsS "$health_url" >/dev/null 2>&1; then
            echo "  ✓ healthy"
            break
        fi
        remaining=$((deadline - SECONDS))
        printf "  ... not ready (%ds remaining)\r" "$remaining"
        sleep 5
    done
    if ! curl -fsS "$health_url" >/dev/null 2>&1; then
        echo "" >&2
        echo "  ✗ timed out after 120s. Check 'just logs' for errors." >&2
        exit 1
    fi
    echo
    commit_log="$(git log "${PREVIEW_BASE_BRANCH}..HEAD" --format='- %h %s')"
    pr_body="$(printf 'Preview: %s\n\n%s' "$preview_url" "$commit_log")"
    pr_url="$(gh pr create --draft \
        --title "$branch" \
        --base "$PREVIEW_BASE_BRANCH" \
        --body "$pr_body")"
    echo
    echo "✓ PR created: $pr_url"
    echo "  Preview:    $preview_url"
