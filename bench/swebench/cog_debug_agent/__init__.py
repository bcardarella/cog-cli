"""CogDebugAgent: SWE-agent agent that intercepts cog_debug tool calls host-side."""

from .agent import CogDebugAgent
from .subagent import SubagentConfig, SubagentResult, SubagentRunner

__all__ = ["CogDebugAgent", "SubagentConfig", "SubagentResult", "SubagentRunner"]
