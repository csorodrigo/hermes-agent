from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "configure_herdrm.py"
SPEC = importlib.util.spec_from_file_location("configure_herdrm", SCRIPT)
assert SPEC and SPEC.loader
herdrm = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = herdrm
SPEC.loader.exec_module(herdrm)


def test_upsert_uses_swift_codable_shape_and_is_idempotent():
    devices, changed = herdrm.upsert_device(
        [herdrm.local_device()],
        name="Workbox",
        target="hermes-workbox",
    )
    assert changed is True
    remote = devices[1]
    assert remote["kind"] == {"ssh": {"target": "hermes-workbox"}}

    again, changed_again = herdrm.upsert_device(
        devices,
        name="Workbox",
        target="hermes-workbox",
    )
    assert changed_again is False
    assert again == devices


def test_load_missing_store_seeds_local_device(tmp_path: Path):
    devices = herdrm.load_devices(tmp_path / "devices.json")
    assert devices == [herdrm.local_device()]


def test_atomic_save_preserves_local_first_and_mode(tmp_path: Path):
    store = tmp_path / "HerdrM" / "devices.json"
    devices, _ = herdrm.upsert_device([], name="Workbox", target="workbox")
    herdrm.atomic_save(store, devices)
    saved = json.loads(store.read_text(encoding="utf-8"))
    assert "local" in saved[0]["kind"]
    assert saved[1]["kind"]["ssh"]["target"] == "workbox"
    assert store.stat().st_mode & 0o777 == 0o600


def test_parse_ssh_aliases_follows_include_and_skips_patterns(tmp_path: Path):
    config_d = tmp_path / "config.d"
    config_d.mkdir()
    (config_d / "work").write_text(
        "Host buildbox\n  HostName 10.0.0.2\n",
        encoding="utf-8",
    )
    config = tmp_path / "config"
    config.write_text(
        f"Include {config_d}/*\nHost workbox *.internal !blocked\n"
        "  HostName 10.0.0.1\n",
        encoding="utf-8",
    )
    assert herdrm.parse_ssh_aliases(config) == ["buildbox", "workbox"]


def test_duplicate_display_name_for_other_target_fails():
    devices, _ = herdrm.upsert_device([], name="Workbox", target="one")
    with pytest.raises(herdrm.HerdrMConfigError, match="already used"):
        herdrm.upsert_device(devices, name="Workbox", target="two")


def test_invalid_inventory_fails_closed(tmp_path: Path):
    store = tmp_path / "devices.json"
    store.write_text("{not-json", encoding="utf-8")
    with pytest.raises(herdrm.HerdrMConfigError, match="cannot read"):
        herdrm.load_devices(store)


def test_probe_prepends_remote_login_paths(monkeypatch):
    captured = {}

    def fake_run(command, **kwargs):
        captured["command"] = command
        return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

    monkeypatch.setattr(herdrm.subprocess, "run", fake_run)
    result = herdrm.probe_target("workbox")
    assert result["ok"] is True
    remote = captured["command"][-1]
    assert "$HOME/.local/bin" in remote
    assert "command -v herdr" in remote


def test_running_app_guard_fails_closed_on_macos(monkeypatch):
    monkeypatch.setattr(herdrm.sys, "platform", "darwin")
    monkeypatch.setattr(
        herdrm.subprocess,
        "run",
        lambda *args, **kwargs: subprocess.CompletedProcess(args[0], 0),
    )
    with pytest.raises(herdrm.HerdrMConfigError, match="HerdrM is running"):
        herdrm.ensure_herdrm_stopped()


def test_running_app_guard_can_be_overridden(monkeypatch):
    monkeypatch.setattr(herdrm.sys, "platform", "darwin")
    herdrm.ensure_herdrm_stopped(allow_running=True)
