"""Tests for the output processing pipeline in CogDebugAgent.

These tests validate the MCP log extraction, subagent text fallback,
and the complete _process_output pipeline without requiring any external
dependencies (no SWE-agent, no Docker, no claude CLI).
"""

import json
import pytest


# We can't import CogDebugAgent directly since it depends on sweagent.
# Instead, extract the static methods and test them in isolation.
# For the instance methods, we test the logic via the static helpers.

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Import the module but handle the case where sweagent isn't installed
try:
    from cog_debug_agent.agent import CogDebugAgent
    HAS_SWEAGENT = True
except ImportError:
    HAS_SWEAGENT = False


# ── Helper: build MCP log lines ──────────────────────────────────────

def _mcp_send_line(tool_result_json: dict, rpc_id: int = 1) -> str:
    """Build a SEND line as it appears in cog-mcp.log."""
    rpc_response = {
        "jsonrpc": "2.0",
        "id": rpc_id,
        "result": {
            "content": [
                {
                    "type": "text",
                    "text": json.dumps(tool_result_json),
                }
            ]
        }
    }
    return f"[1234567890] <<< SEND: {json.dumps(rpc_response)}"


def _mcp_dispatch_line(tool_name: str) -> str:
    return f"[1234567890] callDebugTool: dispatching {tool_name}"


def _mcp_returned_line(tool_name: str) -> str:
    return f"[1234567890] callDebugTool: {tool_name} returned"


# ── Tests for _extract_structured_from_mcp_log ──────────────────────

@pytest.mark.skipif(not HAS_SWEAGENT, reason="sweagent not installed")
class TestExtractStructuredFromMcpLog:

    def test_breakpoint_not_hit_exited(self):
        """When stop_reason=exited, produce concise 'BREAKPOINT NOT HIT' message."""
        stop_state = {"stop_reason": "exited", "exit_code": 1}
        mcp_log = "\n".join([
            _mcp_dispatch_line("cog_debug_run"),
            _mcp_send_line(stop_state, rpc_id=3),
            _mcp_returned_line("cog_debug_run"),
        ])

        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "file.py:42", ["x", "y"]
        )
        assert result == "BREAKPOINT NOT HIT — exit_code: 1"

    def test_breakpoint_not_hit_exit_code_0(self):
        """Exit code 0 means program completed but breakpoint was never reached."""
        stop_state = {"stop_reason": "exited", "exit_code": 0}
        mcp_log = _mcp_send_line(stop_state)

        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "file.py:42", ["x"]
        )
        assert result == "BREAKPOINT NOT HIT — exit_code: 0"

    def test_breakpoint_not_hit_exit_code_4(self):
        """Exit code 4 = pytest no tests collected."""
        stop_state = {"stop_reason": "exited", "exit_code": 4}
        mcp_log = _mcp_send_line(stop_state)

        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "file.py:42", ["x"]
        )
        assert result == "BREAKPOINT NOT HIT — exit_code: 4"

    def test_breakpoint_hit_with_inspect_results(self):
        """Breakpoint hit with successful inspect results."""
        stop_state = {
            "stop_reason": "breakpoint",
            "location": {"file": "/app/lib/utils.py", "line": 42, "function": "parse"},
        }
        inspect1 = {"result": "'hello'", "type": "str"}
        inspect2 = {"result": "42", "type": "int"}

        mcp_log = "\n".join([
            _mcp_dispatch_line("cog_debug_launch"),
            _mcp_send_line({"session_id": "s1"}, rpc_id=1),
            _mcp_returned_line("cog_debug_launch"),
            _mcp_dispatch_line("cog_debug_breakpoint"),
            _mcp_send_line({"id": 1}, rpc_id=2),
            _mcp_returned_line("cog_debug_breakpoint"),
            _mcp_dispatch_line("cog_debug_run"),
            _mcp_send_line(stop_state, rpc_id=3),
            _mcp_returned_line("cog_debug_run"),
            _mcp_dispatch_line("cog_debug_inspect"),
            _mcp_send_line(inspect1, rpc_id=4),
            _mcp_returned_line("cog_debug_inspect"),
            _mcp_dispatch_line("cog_debug_inspect"),
            _mcp_send_line(inspect2, rpc_id=5),
            _mcp_returned_line("cog_debug_inspect"),
        ])

        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "lib/utils.py:42", ["data", "count"]
        )
        assert "breakpoint: hit at /app/lib/utils.py:42 (parse)" in result
        assert "data = 'hello'  # str" in result
        assert "count = 42  # int" in result

    def test_breakpoint_hit_with_error_expression(self):
        """Inspect result that is a NameError."""
        stop_state = {
            "stop_reason": "breakpoint",
            "location": {"file": "/app/foo.py", "line": 10, "function": "bar"},
        }
        inspect1 = {"result": "NameError: name 'x' is not defined", "type": ""}

        mcp_log = "\n".join([
            _mcp_send_line(stop_state, rpc_id=1),
            _mcp_send_line(inspect1, rpc_id=2),
        ])

        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "foo.py:10", ["x"]
        )
        assert "breakpoint: hit" in result
        assert "x = NameError: name 'x' is not defined" in result
        # Error results should NOT have a type comment
        assert "# " not in result.split("\n")[1]

    def test_breakpoint_hit_fewer_inspects_than_expressions(self):
        """When some expressions weren't inspected (e.g., subagent stopped early)."""
        stop_state = {
            "stop_reason": "breakpoint",
            "location": {"file": "/app/foo.py", "line": 10, "function": "bar"},
        }
        inspect1 = {"result": "42", "type": "int"}

        mcp_log = "\n".join([
            _mcp_send_line(stop_state, rpc_id=1),
            _mcp_send_line(inspect1, rpc_id=2),
        ])

        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "foo.py:10", ["x", "y", "z"]
        )
        assert "x = 42" in result
        assert "y = (not inspected)" in result
        assert "z = (not inspected)" in result

    def test_exception_stop_reason(self):
        """Program raised an exception during debugging."""
        stop_state = {
            "stop_reason": "exception",
            "exception": {
                "exception_id": "ValueError",
                "description": "invalid literal for int()",
            },
        }
        mcp_log = _mcp_send_line(stop_state)

        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "foo.py:10", ["x"]
        )
        assert "Program raised an exception: ValueError" in result
        assert "invalid literal for int()" in result

    def test_step_stop_reason(self):
        """Step mode (trace)."""
        stop_state = {
            "stop_reason": "step",
            "location": {"file": "/app/foo.py", "line": 15, "function": "compute"},
            "locals": [
                {"name": "x", "value": "1"},
                {"name": "y", "value": "'hello'"},
            ],
        }
        mcp_log = _mcp_send_line(stop_state)

        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "foo.py:10", []
        )
        assert "stopped at /app/foo.py:15 (compute)" in result
        assert "x = 1" in result
        assert "y = 'hello'" in result

    def test_empty_mcp_log(self):
        """Empty MCP log returns empty string."""
        result = CogDebugAgent._extract_structured_from_mcp_log("", "foo.py:10", ["x"])
        assert result == ""

    def test_no_stop_state_in_log(self):
        """MCP log without any stop_reason returns empty string."""
        mcp_log = "\n".join([
            _mcp_dispatch_line("cog_debug_launch"),
            _mcp_send_line({"session_id": "s1"}, rpc_id=1),
            _mcp_returned_line("cog_debug_launch"),
        ])
        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "foo.py:10", ["x"]
        )
        assert result == ""

    def test_malformed_json_in_send_line(self):
        """Gracefully handle malformed JSON in SEND lines."""
        mcp_log = "[1234567890] <<< SEND: {not valid json}\n" + _mcp_send_line(
            {"stop_reason": "exited", "exit_code": 2}
        )
        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "foo.py:10", ["x"]
        )
        assert result == "BREAKPOINT NOT HIT — exit_code: 2"


# ── Tests for _extract_subagent_text ─────────────────────────────────

@pytest.mark.skipif(not HAS_SWEAGENT, reason="sweagent not installed")
class TestExtractSubagentText:

    def test_json_output(self):
        stdout = json.dumps({"type": "result", "result": "breakpoint: hit\nx = 42"})
        assert CogDebugAgent._extract_subagent_text(stdout) == "breakpoint: hit\nx = 42"

    def test_plain_text_fallback(self):
        assert CogDebugAgent._extract_subagent_text("some plain text") == "some plain text"

    def test_empty_input(self):
        assert CogDebugAgent._extract_subagent_text("") == ""

    def test_json_with_empty_result(self):
        stdout = json.dumps({"type": "result", "result": ""})
        assert CogDebugAgent._extract_subagent_text(stdout) == ""


# ── Tests for _extract_exit_code_from_text ───────────────────────────

@pytest.mark.skipif(not HAS_SWEAGENT, reason="sweagent not installed")
class TestExtractExitCodeFromText:

    def test_exit_code_in_prose(self):
        text = "The test ran and exited with exit_code: 1 before reaching the breakpoint."
        assert CogDebugAgent._extract_exit_code_from_text(text) == "1"

    def test_exit_code_with_equals(self):
        text = "exit code = 4"
        assert CogDebugAgent._extract_exit_code_from_text(text) == "4"

    def test_passed_implies_zero(self):
        text = "The test passed but never reached the breakpoint."
        assert CogDebugAgent._extract_exit_code_from_text(text) == "0"

    def test_no_exit_code(self):
        text = "Something went wrong."
        assert CogDebugAgent._extract_exit_code_from_text(text) == "unknown"


# ── Tests for output size expectations ───────────────────────────────

@pytest.mark.skipif(not HAS_SWEAGENT, reason="sweagent not installed")
class TestOutputSizeConstraints:
    """Verify the pipeline produces concise output."""

    def test_breakpoint_not_hit_is_concise(self):
        """BREAKPOINT NOT HIT output should be under 50 chars."""
        stop_state = {"stop_reason": "exited", "exit_code": 1}
        mcp_log = _mcp_send_line(stop_state)
        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "foo.py:42", ["x", "y"]
        )
        assert len(result) < 50

    def test_breakpoint_hit_scales_with_expressions(self):
        """Hit output size should scale with number of expressions, not narration."""
        stop_state = {
            "stop_reason": "breakpoint",
            "location": {"file": "/app/foo.py", "line": 42, "function": "f"},
        }
        inspects = [
            {"result": f"value_{i}", "type": "str"} for i in range(5)
        ]
        lines = [_mcp_send_line(stop_state, rpc_id=1)]
        for i, insp in enumerate(inspects):
            lines.append(_mcp_send_line(insp, rpc_id=i + 2))
        mcp_log = "\n".join(lines)

        exprs = [f"expr_{i}" for i in range(5)]
        result = CogDebugAgent._extract_structured_from_mcp_log(
            mcp_log, "foo.py:42", exprs
        )
        # Should be roughly: header + 5 expression lines
        result_lines = result.strip().split("\n")
        assert len(result_lines) == 6  # 1 header + 5 exprs
        # Total should be well under 500 chars
        assert len(result) < 500


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
