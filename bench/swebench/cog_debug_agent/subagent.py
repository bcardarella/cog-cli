"""Reusable subprocess runner for spawning Claude subagents.

Provides SubagentConfig, SubagentResult, and SubagentRunner — a clean
abstraction over the subprocess lifecycle (build command, capture output,
parse JSON, handle timeouts) so any agent can spawn `claude -p` processes
with model override, MCP config, timeout, and cost tracking.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

logger = logging.getLogger(__name__)


@dataclass
class SubagentConfig:
    """Configuration for a single subagent invocation."""

    prompt: str
    model: str = "claude-sonnet-4-6"
    timeout: int = 120
    mcp_config_path: str | None = None
    cwd: str | None = None
    env_overrides: dict | None = None
    dangerously_skip_permissions: bool = True
    strict_mcp_config: bool = True


@dataclass
class SubagentResult:
    """Result from a subagent invocation."""

    success: bool
    text: str
    cost_usd: float
    returncode: int | None  # None = timeout
    stdout_raw: str
    stderr_raw: str
    timed_out: bool
    duration_seconds: float


class SubagentRunner:
    """Spawns ``claude -p`` subprocesses with file-based output capture.

    Parameters
    ----------
    work_dir:
        Directory for stdout/stderr capture files.
    log_fn:
        Logging callback; defaults to ``logger.info``.
    """

    def __init__(self, work_dir: str, log_fn: Callable | None = None):
        self._work_dir = work_dir
        self._log_fn = log_fn or logger.info
        self._call_count = 0

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def run(self, config: SubagentConfig) -> SubagentResult:
        """Spawn a ``claude -p`` subprocess and return the result."""
        self._call_count += 1
        call_id = self._call_count

        cmd = self._build_command(config)
        env = self._build_env(config)

        stdout_path = Path(self._work_dir) / f"subagent_stdout_{call_id}.log"
        stderr_path = Path(self._work_dir) / f"subagent_stderr_{call_id}.log"

        start = time.monotonic()

        try:
            with open(stdout_path, "w") as stdout_f, open(stderr_path, "w") as stderr_f:
                proc = subprocess.Popen(
                    cmd,
                    stdout=stdout_f,
                    stderr=stderr_f,
                    text=True,
                    cwd=config.cwd or self._work_dir,
                    env=env,
                )

                timed_out = False
                try:
                    returncode = proc.wait(timeout=config.timeout)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                    returncode = None
                    timed_out = True

            duration = time.monotonic() - start

            stdout_content = stdout_path.read_text().strip() if stdout_path.exists() else ""
            stderr_content = stderr_path.read_text().strip() if stderr_path.exists() else ""

            cost = self.extract_cost(stdout_content)
            text = self.extract_text(stdout_content)

            return SubagentResult(
                success=(returncode == 0),
                text=text,
                cost_usd=cost,
                returncode=returncode,
                stdout_raw=stdout_content,
                stderr_raw=stderr_content,
                timed_out=timed_out,
                duration_seconds=duration,
            )

        except FileNotFoundError:
            duration = time.monotonic() - start
            return SubagentResult(
                success=False,
                text="'claude' CLI not found. Is it installed?",
                cost_usd=0.0,
                returncode=None,
                stdout_raw="",
                stderr_raw="",
                timed_out=False,
                duration_seconds=duration,
            )

    # ------------------------------------------------------------------
    # Static helpers
    # ------------------------------------------------------------------

    @staticmethod
    def extract_text(stdout: str) -> str:
        """Parse text from ``claude --output-format json`` response.

        Falls back to raw stdout if JSON parsing fails.
        """
        if not stdout:
            return ""
        try:
            result = json.loads(stdout)
            return (result.get("result", "") or "").strip()
        except (json.JSONDecodeError, TypeError, AttributeError):
            return stdout.strip()

    @staticmethod
    def extract_cost(stdout: str) -> float:
        """Parse ``cost_usd`` from ``claude --output-format json`` response."""
        if not stdout:
            return 0.0
        try:
            result = json.loads(stdout)
            return float(result.get("cost_usd", 0) or 0)
        except (json.JSONDecodeError, TypeError, ValueError):
            return 0.0

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _build_command(config: SubagentConfig) -> list[str]:
        cmd = [
            "claude", "-p", config.prompt,
            "--model", config.model,
            "--output-format", "json",
        ]
        if config.dangerously_skip_permissions:
            cmd.append("--dangerously-skip-permissions")
        if config.strict_mcp_config:
            cmd.append("--strict-mcp-config")
        if config.mcp_config_path:
            cmd.extend(["--mcp-config", config.mcp_config_path])
        return cmd

    @staticmethod
    def _build_env(config: SubagentConfig) -> dict[str, str]:
        env = {
            k: v for k, v in os.environ.items()
            if k not in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT")
        }
        if config.env_overrides:
            env.update(config.env_overrides)
        return env
