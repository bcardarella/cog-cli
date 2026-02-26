#!/usr/bin/env python3
"""Wrapper to run SWE-agent with CogDebugAgent support.

This script patches SWE-agent's agent factory to recognize agent.type: "cog_debug"
in YAML configs, then delegates to the standard sweagent run-batch entry point.

Usage:
    python3 bench/swebench/run_sweagent.py --config configs/debugger-subagent.yaml [...]

For baseline runs (no patching needed), you can use `sweagent run-batch` directly.
"""

import os
import sys

# Ensure the bench/swebench directory is on the Python path so cog_debug_agent is importable
script_dir = os.path.dirname(os.path.abspath(__file__))
if script_dir not in sys.path:
    sys.path.insert(0, script_dir)

# Import SWE-agent modules
from sweagent.agent import agents as _agents_module
from sweagent.agent.agents import DefaultAgent, get_agent_from_config as _original_factory

from cog_debug_agent import CogDebugAgent


def patched_get_agent_from_config(config):
    """Extended agent factory that handles agent.type == 'cog_debug'."""
    if getattr(config, "type", None) == "default":
        # Check for cog_debug marker in the config's extra fields or env
        cog_bin = os.environ.get("COG_BIN", "cog")

        # If COG_DEBUG_AGENT env var is set, use CogDebugAgent instead of DefaultAgent
        if os.environ.get("COG_DEBUG_AGENT") == "1":
            agent = CogDebugAgent.from_config(config)
            agent._cog_bin = cog_bin
            return agent

    return _original_factory(config)


# Monkey-patch the factory
_agents_module.get_agent_from_config = patched_get_agent_from_config

# Also patch it in the run module where it's imported
try:
    from sweagent.run import run_batch as _run_batch_module
    _run_batch_module.get_agent_from_config = patched_get_agent_from_config
except (ImportError, AttributeError):
    pass

try:
    from sweagent.run import run_single as _run_single_module
    _run_single_module.get_agent_from_config = patched_get_agent_from_config
except (ImportError, AttributeError):
    pass


if __name__ == "__main__":
    from sweagent.run.run import main
    main()
