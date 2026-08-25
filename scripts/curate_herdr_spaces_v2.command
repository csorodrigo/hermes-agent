#!/usr/bin/env bash
set -euo pipefail

BRANCH="${HERDR_HARNESS_BRANCH:-feat/herdr-hermes-team-harness}"
SOURCE_URL="${HERDR_CURATOR_SOURCE_URL:-https://raw.githubusercontent.com/csorodrigo/hermes-agent/refs/heads/$BRANCH/scripts/curate_herdr_spaces.command}"
TMP="$(mktemp -t curate-herdr-spaces-v2.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

for binary in curl python3 bash; do
  command -v "$binary" >/dev/null 2>&1 || {
    echo "ERROR: missing dependency: $binary" >&2
    exit 1
  }
done

curl -fsSL "$SOURCE_URL" -o "$TMP"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# Herdr 0.8.x AgentInfo serializes lifecycle as `agent_status`. The original
# curator looked only for `status`/`state`, so every successfully started Codex
# was misclassified as `unknown` and all five hosts failed at the same check.
old_field = 'value = item.get("status") or item.get("state")'
new_field = 'value = item.get("agent_status") or item.get("status") or item.get("state")'
if old_field in text:
    text = text.replace(old_field, new_field, 1)
elif new_field not in text:
    raise SystemExit("ERROR: could not locate the agent status parser to patch")

old_guard = '''state = agent_status(control)\nif state in {"blocked", "unknown"}:\n    run(["herdr", "agent", "send-keys", "codexctl", "ctrl+c"])\n    raise SystemExit(f"codexctl is not ready; state={state}")'''
new_guard = '''state = agent_status(control)\ninteractive_ready = bool(control.get("interactive_ready"))\nlaunch_pending = bool(control.get("launch_pending"))\nif state == "blocked" or launch_pending or not interactive_ready:\n    run(["herdr", "agent", "send-keys", "codexctl", "ctrl+c"])\n    raise SystemExit(\n        f"codexctl is not ready; state={state} "\n        f"interactive_ready={interactive_ready} launch_pending={launch_pending}"\n    )'''
if old_guard in text:
    text = text.replace(old_guard, new_guard, 1)
elif new_guard not in text:
    raise SystemExit("ERROR: could not locate the readiness guard to patch")

old_result = '''    "control_state": state,\n}, indent=2, ensure_ascii=False))'''
new_result = '''    "control_state": state,\n    "interactive_ready": interactive_ready,\n    "launch_pending": launch_pending,\n}, indent=2, ensure_ascii=False))'''
if old_result in text:
    text = text.replace(old_result, new_result, 1)

text = text.replace(
    "FINAL RESULT: PASS — spaces curated, setup wizards removed, Codex controls ready and existing Hermes services preserved/reloaded where safely supervised.",
    "FINAL RESULT: PASS — spaces curated, Herdr 0.8 agent state validated, Codex controls ready and existing Hermes services preserved/reloaded where safely supervised.",
)

path.write_text(text, encoding="utf-8")
PY

bash -n "$TMP"
exec bash "$TMP"
