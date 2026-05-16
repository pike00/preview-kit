"""Typer CLI: preview-kit init, doctor, env."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Annotated

import typer

from . import config, init

app = typer.Typer(
    add_completion=False,
    no_args_is_help=True,
    help="Per-worktree dev stack manager: init, up/down, health checks, PR creation.",
)


def _err(msg: str) -> None:
    typer.echo(f"error: {msg}", err=True)


def _die(msg: str, code: int = 1) -> None:
    _err(msg)
    raise typer.Exit(code)


def _prompt(text: str, default: str | None = None) -> str:
    """Prompt user and return input, with optional default."""
    if default:
        prompt_text = f"{text} (default: {default}): "
    else:
        prompt_text = f"{text}: "

    result = typer.prompt(prompt_text).strip()
    if not result and default:
        return default
    if not result:
        typer.echo("error: input required", err=True)
        return _prompt(text, default)
    return result


@app.command("init")
def cmd_init() -> None:
    """Interactive setup: symlink preview.just, create preview-kit.toml, update justfile."""
    try:
        repo_root = config.repo_root()
    except config.ConfigError as exc:
        _die(str(exc))

    # Check for conflicts
    if (repo_root / "preview-kit.toml").exists():
        _die("preview-kit.toml already exists. Remove it first to reinitialize.")
    if (repo_root / "preview.just").exists() or (repo_root / "preview.just").is_symlink():
        _die("preview.just already exists. Remove it first to reinitialize.")

    typer.echo("\n=== preview-kit init ===\n")

    # Gather config interactively
    project_name = _prompt("Project name", "MyProject")
    project_prefix = _prompt("Project prefix (short, unique)", "myproj")
    host_pattern = _prompt(
        "Host pattern ({slug}, {domain})",
        "{slug}.{project_name}.{domain}",
    )
    compose_file = _prompt("Compose file", "compose.worktree.yml")
    health_path = _prompt("Health check path", "/api/health")
    base = _prompt("Base branch", "main")
    shell_service = _prompt("Shell service name", "app")
    test_service = _prompt("Test service name (or leave blank for shell_service)", "")
    if not test_service:
        test_service = shell_service
    test_command = _prompt("Test command", "pytest")

    # Ports (optional)
    define_ports = typer.confirm("Define port mappings?", default=False)
    ports: dict[str, int] = {}
    if define_ports:
        typer.echo("(Ports get a per-slug offset; these are base values)")
        while True:
            port_name = typer.prompt("Port name (e.g. APP_PORT) [or press Enter to skip]").strip()
            if not port_name:
                break
            port_base = typer.prompt(f"Base port for {port_name}", type=int)
            ports[port_name] = port_base

    # Build config
    cfg = config.PreviewKitConfig(
        project_name=project_name,
        project_prefix=project_prefix,
        host_pattern=host_pattern,
        compose_file=compose_file,
        health_path=health_path,
        base=base,
        shell_service=shell_service,
        test_service=test_service,
        test_command=test_command,
        ports=ports,
    )

    # Find preview-kit directory (where this script is)
    preview_kit_path = Path(__file__).parent.parent.parent  # src/preview_kit -> src -> preview-kit

    # Execute init
    try:
        init.init(repo_root, preview_kit_path, cfg, sys.stdout)
    except init.InitError as exc:
        _die(str(exc))


@app.command("doctor")
def cmd_doctor() -> None:
    """Validate preview-kit.toml and setup."""
    try:
        repo_root = config.repo_root()
    except config.ConfigError as exc:
        _die(str(exc))

    typer.echo("\n=== preview-kit doctor ===\n")

    # Check preview-kit.toml
    if not (repo_root / "preview-kit.toml").exists():
        typer.echo("✗ preview-kit.toml not found")
        raise typer.Exit(1)
    typer.echo("✓ preview-kit.toml exists")

    # Load config
    try:
        cfg = config.load(repo_root)
    except config.ConfigError as exc:
        typer.echo(f"✗ Failed to load config: {exc}")
        raise typer.Exit(1)
    typer.echo(f"✓ Config valid: {cfg.project_name}")

    # Check preview.just symlink
    preview_just_path = repo_root / "preview.just"
    if not preview_just_path.exists() and not preview_just_path.is_symlink():
        typer.echo("✗ preview.just symlink missing")
        raise typer.Exit(1)
    if preview_just_path.is_symlink():
        target = preview_just_path.resolve()
        typer.echo(f"✓ preview.just symlink → {target}")
    else:
        typer.echo("⚠ preview.just exists but is not a symlink")

    # Check justfile
    if not (repo_root / "justfile").exists():
        typer.echo("✗ justfile not found")
        raise typer.Exit(1)
    justfile_content = (repo_root / "justfile").read_text(encoding="utf-8")
    if "import 'preview.just'" in justfile_content:
        typer.echo("✓ justfile imports preview.just")
    else:
        typer.echo("⚠ justfile does not import preview.just")

    # Check compose file
    compose_path = repo_root / cfg.compose_file
    if not compose_path.exists():
        typer.echo(f"⚠ {cfg.compose_file} not found (create it with your worktree stack)")
    else:
        typer.echo(f"✓ {cfg.compose_file} exists")

    typer.echo("\n✓ Setup looks good!\n")


if __name__ == "__main__":
    app()
