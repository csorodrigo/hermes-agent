from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
CONTROLLER_PATH = ROOT / "deploy" / "herdr-harness" / "plugin" / "controller.py"
SPEC = importlib.util.spec_from_file_location("herdr_harness_controller", CONTROLLER_PATH)
assert SPEC and SPEC.loader
controller = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = controller
SPEC.loader.exec_module(controller)


def test_find_identifier_accepts_string_and_nested_id():
    response = {
        "result": {
            "workspace": {"id": "workspace:7"},
            "root_pane": {"id": "pane:9"},
        }
    }
    assert controller.find_identifier(response, ("workspace_id", "workspace")) == "workspace:7"
    assert controller.find_identifier(response, ("pane_id", "root_pane")) == "pane:9"


def test_profile_file_is_loaded(tmp_path: Path):
    profile = tmp_path / "team.ini"
    profile.write_text(
        "\n".join(
            [
                "[harness]",
                "target = workbox",
                "session = hermes-team-alice",
                "repo = /srv/hermes/repo",
                "worktrees_root = /srv/hermes/worktrees/alice",
                "base_ref = main",
            ]
        ),
        encoding="utf-8",
    )
    args = controller.build_parser().parse_args(["--config", str(profile), "config-show"])
    config = controller.load_config(args)
    assert config.target == "workbox"
    assert config.session == "hermes-team-alice"
    assert config.repo == "/srv/hermes/repo"
    assert config.worktrees_root == "/srv/hermes/worktrees/alice"


def test_remote_paths_must_be_absolute(tmp_path: Path):
    profile = tmp_path / "bad.ini"
    profile.write_text(
        "[harness]\ntarget = workbox\nrepo = relative/repo\nworktrees_root = /srv/worktrees\n",
        encoding="utf-8",
    )
    args = controller.build_parser().parse_args(["--config", str(profile), "config-show"])
    with pytest.raises(controller.HarnessError, match="absolute paths"):
        controller.load_config(args)


def test_ssh_command_preserves_remote_argument_boundaries(monkeypatch, tmp_path: Path):
    captured = {}

    def fake_run(command, **kwargs):
        captured["command"] = command
        return subprocess.CompletedProcess(command, 0, stdout="ok\n", stderr="")

    monkeypatch.setattr(controller.shutil, "which", lambda _: "/usr/bin/ssh")
    monkeypatch.setattr(controller.subprocess, "run", fake_run)
    config = controller.HarnessConfig(
        profile="team",
        target="workbox",
        session="hermes-team",
        repo="/srv/repo",
        worktrees_root="/srv/worktrees",
        base_ref="main",
        herdr_binary="herdr",
        ssh_binary="ssh",
        ssh_port=None,
        ssh_key="",
        ssh_control_path=str(tmp_path / "cm-%C"),
        ssh_control_persist=600,
        timeout_ms=120000,
    )
    result = controller.Runner(config).host(["printf", "%s", "a b'c"])
    assert result.returncode == 0
    remote_command = captured["command"][-1]
    assert remote_command.startswith("printf %s ")
    assert "a b" in remote_command


def test_task_slug_and_ref_validation():
    assert controller.task_slug("Issue 142 / auth") == "Issue-142-auth"
    assert controller.validate_ref("agent/issue-142", "branch") == "agent/issue-142"
    with pytest.raises(controller.HarnessError):
        controller.validate_ref("../main", "branch")


def test_payload_parses_json_result():
    result = subprocess.CompletedProcess(
        ["herdr"],
        0,
        stdout=json.dumps({"result": {"pane_id": "pane:1"}}),
        stderr="",
    )
    body = controller.payload(result)
    assert body["ok"] is True
    assert body["result"]["result"]["pane_id"] == "pane:1"
