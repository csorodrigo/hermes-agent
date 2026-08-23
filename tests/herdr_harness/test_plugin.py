from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLUGIN_DIR = ROOT / "deploy" / "herdr-harness" / "plugin"
SPEC = importlib.util.spec_from_file_location(
    "herdr_harness_plugin",
    PLUGIN_DIR / "__init__.py",
    submodule_search_locations=[str(PLUGIN_DIR)],
)
assert SPEC and SPEC.loader
plugin = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = plugin
SPEC.loader.exec_module(plugin)


def test_task_create_maps_to_controller_arguments():
    command, blocked = plugin.build_args(
        {
            "action": "task_create",
            "profile": "team",
            "task": "issue-142",
            "branch": "agent/issue-142",
            "base": "main",
            "timeout_ms": 180000,
        }
    )
    assert blocked is None
    assert command == [
        "--profile",
        "team",
        "--json",
        "task-create",
        "issue-142",
        "--branch",
        "agent/issue-142",
        "--base",
        "main",
        "--operation-timeout-ms",
        "180000",
    ]


def test_pane_run_obeys_security_guard(monkeypatch):
    monkeypatch.setattr(
        plugin,
        "guard",
        lambda command: {
            "approved": False,
            "status": "approval_required",
            "command": command,
        },
    )
    command, blocked = plugin.build_args(
        {"action": "pane_run", "pane_id": "pane:1", "command": "rm -rf /tmp/project"}
    )
    assert command is None
    assert blocked["approved"] is False
    assert blocked["status"] == "approval_required"


def test_agent_start_preserves_native_arguments():
    command, blocked = plugin.build_args(
        {
            "action": "agent_start",
            "agent_name": "issue-142",
            "agent_kind": "codex",
            "pane_id": "pane:1",
            "agent_args": ["--full-auto"],
            "start_timeout_ms": 45000,
        }
    )
    assert blocked is None
    assert command[-2:] == ["--", "--full-auto"]
    assert "agent-start" in command
    assert "45000" in command


def test_missing_required_parameter_fails_before_execution():
    command, blocked = plugin.build_args({"action": "agent_prompt", "target": "issue-142"})
    assert command is None
    assert "prompt" in blocked["error"]
