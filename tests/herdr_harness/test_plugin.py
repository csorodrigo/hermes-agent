from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import types
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

CONTROLLER_SPEC = importlib.util.spec_from_file_location(
    "herdr_harness_controller_for_plugin_tests",
    PLUGIN_DIR / "controller.py",
)
assert CONTROLLER_SPEC and CONTROLLER_SPEC.loader
controller = importlib.util.module_from_spec(CONTROLLER_SPEC)
sys.modules[CONTROLLER_SPEC.name] = controller
CONTROLLER_SPEC.loader.exec_module(controller)


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


def test_guard_never_inherits_container_exemption(monkeypatch):
    captured = {}

    def fake_guard(command, env_type):
        captured["command"] = command
        captured["env_type"] = env_type
        return {"approved": True, "message": None}

    tools_package = types.ModuleType("tools")
    tools_package.__path__ = []
    approval_module = types.ModuleType("tools.approval")
    approval_module.check_all_command_guards = fake_guard
    monkeypatch.setitem(sys.modules, "tools", tools_package)
    monkeypatch.setitem(sys.modules, "tools.approval", approval_module)
    monkeypatch.setenv("TERMINAL_ENV", "docker")
    monkeypatch.delenv("HERDR_SSH_TARGET", raising=False)

    assert plugin.guard("git status")["approved"] is True
    assert captured == {"command": "git status", "env_type": "ssh"}


def test_agent_start_preserves_timeout_and_native_arguments():
    command, blocked = plugin.build_args(
        {
            "action": "agent_start",
            "profile": "team",
            "agent_name": "issue-142",
            "agent_kind": "codex",
            "pane_id": "pane:1",
            "agent_args": ["--full-auto"],
            "start_timeout_ms": 45000,
        }
    )
    assert blocked is None

    parsed = controller.build_parser().parse_args(command)
    assert parsed.command == "agent-start"
    assert parsed.name == "issue-142"
    assert parsed.kind == "codex"
    assert parsed.pane_id == "pane:1"
    assert parsed.start_timeout_ms == 45000
    assert parsed.agent_args == ["--full-auto"]


def test_agent_start_outer_timeout_covers_controller_startup(monkeypatch):
    captured = {}

    def fake_run(command, **kwargs):
        captured["command"] = command
        captured["timeout"] = kwargs["timeout"]
        return subprocess.CompletedProcess(
            command,
            0,
            stdout=json.dumps({"ok": True}),
            stderr="",
        )

    monkeypatch.setattr(plugin, "controller_path", lambda: Path("/tmp/controller.py"))
    monkeypatch.setattr(plugin.subprocess, "run", fake_run)

    result = json.loads(
        plugin.handle(
            {
                "action": "agent_start",
                "agent_name": "reviewer",
                "agent_kind": "codex",
                "pane_id": "pane:1",
                "start_timeout_ms": 300000,
            }
        )
    )

    assert result["ok"] is True
    assert captured["timeout"] == 330


def test_force_task_remove_is_not_available_to_model():
    command, blocked = plugin.build_args(
        {
            "action": "task_remove",
            "workspace_id": "w1",
            "force": True,
        }
    )
    assert command is None
    assert "not available through the Hermes tool" in blocked["error"]
    assert "force" not in plugin.SCHEMA["parameters"]["properties"]


def test_missing_required_parameter_fails_before_execution():
    command, blocked = plugin.build_args(
        {"action": "agent_prompt", "target": "issue-142"}
    )
    assert command is None
    assert "prompt" in blocked["error"]
