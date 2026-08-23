#!/usr/bin/env bash
set -euo pipefail

STORE="${HERDRM_DEVICE_STORE:-$HOME/Library/Application Support/HerdrM/devices.json}"
TIMEOUT="${HERDR_FLEET_SSH_TIMEOUT:-12}"

usage() {
  cat <<'EOF'
Read-only audit of Herdr, Hermes and harness state across HerdrM SSH devices.

Usage:
  scripts/audit_herdr_fleet.command
  scripts/audit_herdr_fleet.command alias-one alias-two

Without arguments, SSH targets are read from HerdrM devices.json and deduplicated
case-insensitively. The script does not install, stop, restart or modify anything.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

for binary in python3 ssh; do
  command -v "$binary" >/dev/null 2>&1 || {
    echo "ERROR: $binary is required" >&2
    exit 1
  }
done

if [[ $# -gt 0 ]]; then
  TARGETS=("$@")
else
  [[ -f "$STORE" ]] || {
    echo "ERROR: HerdrM inventory not found: $STORE" >&2
    exit 1
  }
  mapfile_cmd='import json,sys
p=sys.argv[1]
data=json.load(open(p, encoding="utf-8"))
seen=set()
for item in data:
    kind=item.get("kind", {}) if isinstance(item, dict) else {}
    ssh=kind.get("ssh", {}) if isinstance(kind, dict) else {}
    target=ssh.get("target") if isinstance(ssh, dict) else None
    if not isinstance(target, str) or not target.strip():
        continue
    key=target.casefold()
    if key in seen:
        continue
    seen.add(key)
    print(target)'
  TARGETS=()
  while IFS= read -r target; do
    [[ -n "$target" ]] && TARGETS+=("$target")
  done < <(python3 -c "$mapfile_cmd" "$STORE")
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No SSH targets found."
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="${HERDR_FLEET_REPORT:-$HOME/Desktop/herdr-fleet-audit-$STAMP.log}"
mkdir -p "$(dirname "$REPORT")"
: > "$REPORT"

log() {
  printf '%s\n' "$*" | tee -a "$REPORT"
}

log "Herdr fleet audit"
log "Generated: $(date -Iseconds)"
log "Inventory: $STORE"
log "Targets: ${#TARGETS[@]}"
log ""

for target in "${TARGETS[@]}"; do
  log "================================================================================"
  log "TARGET: $target"
  log "--------------------------------------------------------------------------------"

  effective="$(ssh -G "$target" 2>/dev/null | awk '
    $1=="hostname" || $1=="user" || $1=="port" || $1=="proxyjump" ||
    $1=="remotecommand" || $1=="controlmaster" || $1=="controlpersist" ||
    $1=="identityfile" {print}
  ' || true)"
  if [[ -n "$effective" ]]; then
    log "OpenSSH effective configuration:"
    while IFS= read -r line; do log "  $line"; done <<< "$effective"
  else
    log "OpenSSH effective configuration: unavailable"
  fi

  remote_output="$(ssh \
    -o BatchMode=yes \
    -o ConnectTimeout="$TIMEOUT" \
    -o ServerAliveInterval=5 \
    -o ServerAliveCountMax=1 \
    "$target" 'sh -s' 2>&1 <<'REMOTE'
set +e
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

echo "identity.user=$(id -un 2>/dev/null || true)"
echo "identity.uid=$(id -u 2>/dev/null || true)"
echo "identity.host=$(hostname 2>/dev/null || true)"
echo "identity.home=$HOME"

echo "--- binaries"
for binary in herdr hermes codex claude opencode gemini; do
  path="$(command -v "$binary" 2>/dev/null || true)"
  echo "$binary.path=${path:-missing}"
done

if command -v herdr >/dev/null 2>&1; then
  echo "herdr.version=$(herdr --version 2>&1 | head -n 1)"
else
  echo "herdr.version=missing"
fi
if command -v hermes >/dev/null 2>&1; then
  echo "hermes.version=$(hermes --version 2>&1 | head -n 1)"
else
  echo "hermes.version=missing"
fi

echo "--- default socket"
if test -S "$HOME/.config/herdr/herdr.sock"; then
  echo "herdr.default_socket=present"
else
  echo "herdr.default_socket=missing"
fi

echo "--- harness"
if test -f "$HOME/.hermes/plugins/herdr-harness/plugin.yaml"; then
  echo "harness.plugin=present"
else
  echo "harness.plugin=missing"
fi
if test -x "$HOME/.local/bin/herdr-hermesctl"; then
  echo "harness.controller=present"
else
  echo "harness.controller=missing"
fi
profiles="$(find "$HOME/.config/herdr-harness" -maxdepth 1 -type f -name '*.ini' -print 2>/dev/null | paste -sd ',' -)"
echo "harness.profiles=${profiles:-none}"

if command -v systemctl >/dev/null 2>&1; then
  services="$(systemctl --user list-units --all --type=service 'herdr-*.service' --no-legend 2>/dev/null | sed 's/^[[:space:]]*//' | paste -sd ';' -)"
  echo "harness.systemd_services=${services:-none-or-user-bus-unavailable}"
else
  echo "harness.systemd_services=systemd-unavailable"
fi

echo "--- herdr status"
if command -v herdr >/dev/null 2>&1; then
  herdr status --json 2>&1 || true
  echo "--- herdr sessions"
  herdr session list --json 2>&1 || true
  echo "--- herdr workspaces"
  herdr workspace list 2>&1 || true
  echo "--- herdr agents"
  herdr agent list 2>&1 || true
fi

echo "--- active coding processes for this Unix account"
ps -u "$(id -u)" -o pid=,ppid=,command= 2>/dev/null \
  | grep -E '(^|[ /])(codex|claude|hermes|opencode|gemini)([ ]|$)' \
  | grep -v -E 'grep -E|audit_herdr_fleet' \
  || echo "none"
REMOTE
  )"
  ssh_rc=$?

  log "SSH result: exit $ssh_rc"
  while IFS= read -r line; do log "  $line"; done <<< "$remote_output"
  log ""
done

log "================================================================================"
log "Report saved to: $REPORT"
log "Interpretation:"
log "  - Green HerdrM only proves the default Herdr socket is reachable."
log "  - harness.plugin/controller/profile must be present for Hermes orchestration."
log "  - processes listed outside Herdr workspaces will not appear as HerdrM agents."
