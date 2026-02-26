"""CogDebugAgent — intercepts cog_debug tool calls and delegates to a Claude subagent.

This agent subclasses SWE-agent's DefaultAgent. When the model calls the `cog_debug`
tool, instead of executing it in the container (where it would fail), the agent:

1. Extracts breakpoint/inspect/test/condition arguments
2. Builds a subagent prompt
3. Creates a temporary python3 docker-exec wrapper for the current container
4. Spawns `claude -p` with cog MCP config pointing to the container
5. Returns the subagent's output as the tool observation

All other tool calls (bash, str_replace_editor, submit) pass through to the container
via the normal SWE-agent flow.
"""

from __future__ import annotations

import json
import logging
import os
import stat
import subprocess
import tempfile
from pathlib import Path

from sweagent.agent.agents import DefaultAgent
from sweagent.types import StepOutput

logger = logging.getLogger(__name__)


class CogDebugAgent(DefaultAgent):
    """DefaultAgent extended with host-side cog_debug interception."""

    def __init__(self, *, cog_bin: str | None = None, **kwargs):
        super().__init__(**kwargs)
        self._cog_bin = cog_bin or os.environ.get("COG_BIN", "cog")
        self._container_id: str | None = None
        self._tmp_dir: tempfile.TemporaryDirectory | None = None

    def setup(self, env, problem_statement, output_dir=Path(".")):
        """Set up the agent, then discover the Docker container for cog MCP."""
        super().setup(env, problem_statement, output_dir)

        # Discover container ID by running hostname inside the container
        try:
            self._container_id = self._env.communicate("cat /proc/1/cpuset 2>/dev/null | grep -oP '[a-f0-9]{64}$' || hostname").strip()
            if not self._container_id:
                self._container_id = self._env.communicate("hostname").strip()
            logger.info("CogDebugAgent: container_id=%s", self._container_id)
        except Exception as e:
            logger.warning("CogDebugAgent: could not discover container ID: %s", e)
            self._container_id = None

        # Create temp directory for wrapper scripts and MCP config
        self._tmp_dir = tempfile.TemporaryDirectory(prefix="cog_debug_")
        if self._container_id:
            self._create_python3_wrapper()
            self._create_mcp_config()

    def _create_python3_wrapper(self):
        """Create a python3 wrapper script that delegates to docker exec."""
        bin_dir = Path(self._tmp_dir.name) / "bin"
        bin_dir.mkdir(exist_ok=True)
        wrapper = bin_dir / "python3"
        wrapper.write_text(
            f'#!/bin/bash\nexec docker exec -i "{self._container_id}" python3 "$@"\n'
        )
        wrapper.chmod(wrapper.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        logger.info("CogDebugAgent: python3 wrapper at %s", wrapper)

    def _create_mcp_config(self):
        """Create MCP config for the cog debug subagent."""
        bin_dir = str(Path(self._tmp_dir.name) / "bin")
        system_path = os.environ.get("PATH", "")

        config = {
            "mcpServers": {
                "cog": {
                    "command": self._cog_bin,
                    "args": ["mcp", "--debug-tools=core"],
                    "env": {
                        "PATH": bin_dir + ":" + system_path,
                        "SWEBENCH_CONTAINER": self._container_id,
                    },
                }
            }
        }
        config_path = Path(self._tmp_dir.name) / "mcp_config.json"
        config_path.write_text(json.dumps(config))
        logger.info("CogDebugAgent: MCP config at %s", config_path)

    def handle_action(self, step: StepOutput) -> StepOutput:
        """Intercept cog_debug tool calls; delegate everything else to super()."""
        if self._is_cog_debug_call(step):
            return self._handle_cog_debug(step)
        return super().handle_action(step)

    def _is_cog_debug_call(self, step: StepOutput) -> bool:
        """Check if this step is a cog_debug tool call."""
        # Check structured tool_calls first (function calling mode)
        if step.tool_calls:
            for tc in step.tool_calls:
                fn = tc.get("function", {})
                if fn.get("name") == "cog_debug":
                    return True
        # Fallback: check action string
        if step.action and step.action.strip().startswith("cog_debug"):
            return True
        return False

    def _extract_cog_debug_args(self, step: StepOutput) -> dict:
        """Extract cog_debug arguments from the tool call."""
        if step.tool_calls:
            for tc in step.tool_calls:
                fn = tc.get("function", {})
                if fn.get("name") == "cog_debug":
                    args = fn.get("arguments", {})
                    if isinstance(args, str):
                        args = json.loads(args)
                    return args
        # Fallback: can't reliably parse from action string
        return {}

    def _handle_cog_debug(self, step: StepOutput) -> StepOutput:
        """Execute cog_debug by spawning a Claude subagent with cog MCP."""
        args = self._extract_cog_debug_args(step)

        breakpoint_loc = args.get("breakpoint", "")
        inspect_exprs = args.get("inspect", "")
        test_cmd = args.get("test", "")
        condition = args.get("condition", "")

        if not breakpoint_loc or not inspect_exprs or not test_cmd:
            step.observation = (
                "ERROR: cog_debug requires breakpoint, inspect, and test arguments. "
                f"Got: breakpoint={breakpoint_loc!r}, inspect={inspect_exprs!r}, test={test_cmd!r}"
            )
            return step

        # Build subagent prompt
        prompt_parts = [
            f"BREAKPOINT: {breakpoint_loc}",
            f"INSPECT: {inspect_exprs}",
            f"TEST: {test_cmd}",
        ]
        if condition:
            prompt_parts[0] = f"BREAKPOINT: {breakpoint_loc} WHEN {condition}"
        subagent_prompt = "\n".join(prompt_parts)

        if not self._container_id:
            step.observation = "ERROR: No Docker container discovered. Cannot run cog debug subagent."
            return step

        mcp_config_path = str(Path(self._tmp_dir.name) / "mcp_config.json")

        logger.info(
            "CogDebugAgent: spawning subagent — breakpoint=%s inspect=%s test=%s",
            breakpoint_loc, inspect_exprs, test_cmd,
        )

        try:
            # Spawn claude -p with cog MCP
            env = {
                k: v for k, v in os.environ.items()
                if k not in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT")
            }
            env["SWEBENCH_CONTAINER"] = self._container_id
            bin_dir = str(Path(self._tmp_dir.name) / "bin")
            env["PATH"] = bin_dir + ":" + env.get("PATH", "")

            proc = subprocess.run(
                [
                    "claude", "-p", subagent_prompt,
                    "--model", "sonnet",
                    "--dangerously-skip-permissions",
                    "--strict-mcp-config",
                    "--mcp-config", mcp_config_path,
                ],
                capture_output=True,
                text=True,
                timeout=300,
                env=env,
            )

            if proc.returncode == 0:
                output = proc.stdout.strip()
                if not output:
                    output = "(subagent returned no output)"
                step.observation = f"[cog_debug result]\n{output}"
            else:
                stderr_preview = proc.stderr.strip()[:500] if proc.stderr else ""
                step.observation = (
                    f"[cog_debug error] Subagent exited with code {proc.returncode}.\n"
                    f"{stderr_preview}"
                )

        except subprocess.TimeoutExpired:
            step.observation = "[cog_debug timeout] Subagent timed out after 300s."
        except FileNotFoundError:
            step.observation = "[cog_debug error] 'claude' CLI not found. Is it installed?"
        except Exception as e:
            step.observation = f"[cog_debug error] {type(e).__name__}: {e}"

        # Get state for consistency with normal flow
        try:
            step.state = self.tools.get_state(env=self._env)
        except Exception:
            pass

        return step
