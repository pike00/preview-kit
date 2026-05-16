"""Load and validate preview-kit.toml configuration."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field, field_validator


class ConfigError(Exception):
    """Configuration error."""


class PreviewKitConfig(BaseModel):
    """Parsed [preview-kit] section of preview-kit.toml."""

    project_name: str
    project_prefix: str
    host_pattern: str
    compose_file: str = "compose.worktree.yml"
    health_path: str = "/api/health"
    base: str = "main"
    shell_service: str = "app"
    test_service: str | None = None
    test_command: str = "pytest"
    ports: dict[str, int] = Field(default_factory=dict)

    @field_validator("test_service", mode="before")
    @classmethod
    def default_test_service(cls, v: str | None, info: Any) -> str:
        """Use shell_service if test_service is not specified."""
        if v is None:
            return info.data.get("shell_service", "app")
        return v


def repo_root() -> Path:
    """Return git repo root."""
    try:
        root = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return Path(root)
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        raise ConfigError("Not in a git repository") from exc


def load(cwd: Path | None = None) -> PreviewKitConfig:
    """Load and validate preview-kit.toml from repo root."""
    if cwd is None:
        cwd = repo_root()

    config_path = cwd / "preview-kit.toml"
    if not config_path.exists():
        raise ConfigError(f"preview-kit.toml not found at {config_path}")

    try:
        import tomllib
    except ImportError:
        import tomli as tomllib  # type: ignore

    try:
        raw = tomllib.loads(config_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise ConfigError(f"Failed to parse preview-kit.toml: {exc}") from exc

    if "preview-kit" not in raw:
        raise ConfigError("No [preview-kit] section in preview-kit.toml")

    try:
        return PreviewKitConfig.model_validate(raw["preview-kit"])
    except Exception as exc:
        raise ConfigError(f"Invalid preview-kit.toml: {exc}") from exc
