#!/usr/bin/env bash
set -euo pipefail

MODE="server"
PROFILE="hermes"
TARGET=""
SESSION=""
REPO_DIR=""
REPO_URL=""
WORKTREES_ROOT=""
BASE_REF="main"
CONFIGURE_HERDRM=0
HERDRM_DEVICE_NAME=""
SKIP_HERDR_INSTALL=0
SKIP_PLUGIN=0
SKIP_SERVICE=0
SKIP_WORKSPACE=0
SKIP_DOCTOR=0

usage() {
  cat <<'EOF'
Install the Herdr + Hermes coding harness for one Unix user.

Server/workbox (recommended primary runtime):
  ./scripts/bootstrap_herdr_harness.sh \
    --mode server --profile hermes-bot --session default \
    --repo-dir /srv/hermes/users/hermes-bot/projects/hermes-agent \
    --repo-url git@github.com:ORG/hermes-agent.git

Controller/developer Mac with HerdrM:
  ./scripts/bootstrap_herdr_harness.sh \
    --mode client --profile hermes-alice --target hermes-workbox \
    --session default \
    --repo-dir /srv/hermes/users/alice/projects/hermes-agent \
    --worktrees-root /srv/hermes/users/alice/worktrees/hermes-agent \
    --configure-herdrm --herdrm-device-name "Hermes Workbox"

Options:
  --mode server|client
  --profile NAME
  --target SSH_ALIAS          Required in client mode. Prefer ~/.ssh/config alias.
  --session NAME              Defaults to default (required for current HerdrM SSH support).
  --repo-dir PATH             Local path in server mode; remote absolute path in client mode.
  --repo-url URL              Clone when server repo-dir is not already a Git repository.
  --worktrees-root PATH
  --base-ref REF
  --configure-herdrm          Add the client-mode SSH target to HerdrM on macOS.
  --herdrm-device-name NAME   Display name used by HerdrM (defaults to profile).
  --skip-herdr-install        Require an existing Herdr executable.
  --skip-plugin               Reuse an already installed harness plugin.
  --skip-service              Do not install/start a systemd user service in server mode.
  --skip-workspace
  --skip-doctor
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --repo-url) REPO_URL="$2"; shift 2 ;;
    --worktrees-root) WORKTREES_ROOT="$2"; shift 2 ;;
    --base-ref) BASE_REF="$2"; shift 2 ;;
    --configure-herdrm) CONFIGURE_HERDRM=1; shift ;;
    --herdrm-device-name) HERDRM_DEVICE_NAME="$2"; shift 2 ;;
    --skip-herdr-install) SKIP_HERDR_INSTALL=1; shift ;;
    --skip-plugin) SKIP_PLUGIN=1; shift ;;
    --skip-service) SKIP_SERVICE=1; shift ;;
    --skip-workspace) SKIP_WORKSPACE=1; shift ;;
    --skip-doctor) SKIP_DOCTOR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$MODE" != "server" && "$MODE" != "client" ]]; then
  echo "--mode must be server or client" >&2
  exit 2
fi
if [[ ! "$PROFILE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  echo "Invalid profile name" >&2
  exit 2
fi
if [[ "$MODE" == "client" && -z "$TARGET" ]]; then
  echo "--target is required in client mode" >&2
  exit 2
fi
if [[ "$CONFIGURE_HERDRM" -eq 1 && "$MODE" != "client" ]]; then
  echo "--configure-herdrm is only valid in client mode" >&2
  exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PLUGIN_SOURCE="$REPO_ROOT/deploy/herdr-harness/plugin"
HERDRM_CONFIGURATOR="$REPO_ROOT/scripts/configure_herdrm.py"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PLUGIN_DEST="$HERMES_HOME/plugins/herdr-harness"
BIN_DIR="$HOME/.local/bin"
PROFILE_DIR="$HOME/.config/herdr-harness"
PROFILE_FILE="$PROFILE_DIR/$PROFILE.ini"
SERVICE_NAME="herdr-${PROFILE}.service"
SERVICE_FILE="$HOME/.config/systemd/user/$SERVICE_NAME"
SERVICE_STATE="not-installed"

SESSION="${SESSION:-default}"
if [[ ! "$SESSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  echo "Invalid Herdr session name" >&2
  exit 2
fi
if [[ "$CONFIGURE_HERDRM" -eq 1 ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "--configure-herdrm requires macOS" >&2
    exit 2
  fi
  if [[ "$SESSION" != "default" ]]; then
    echo "HerdrM currently forwards the remote default socket only; use --session default" >&2
    exit 2
  fi
  [[ -f "$HERDRM_CONFIGURATOR" ]] || {
    echo "HerdrM configurator not found: $HERDRM_CONFIGURATOR" >&2
    exit 1
  }
fi
if [[ -z "$REPO_DIR" ]]; then
  if [[ "$MODE" == "server" ]]; then
    REPO_DIR="$HOME/src/$PROFILE"
  else
    echo "--repo-dir is required in client mode and must be an absolute remote path" >&2
    exit 2
  fi
fi
if [[ -z "$WORKTREES_ROOT" ]]; then
  if [[ "$MODE" == "server" ]]; then
    WORKTREES_ROOT="$HOME/worktrees/$PROFILE"
  else
    echo "--worktrees-root is required in client mode and must be an absolute remote path" >&2
    exit 2
  fi
fi
if [[ "$MODE" == "client" ]]; then
  [[ "$REPO_DIR" == /* ]] || { echo "client --repo-dir must be absolute" >&2; exit 2; }
  [[ "$WORKTREES_ROOT" == /* ]] || { echo "client --worktrees-root must be absolute" >&2; exit 2; }
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git is required" >&2; exit 1; }
if [[ "$MODE" == "client" ]]; then
  command -v ssh >/dev/null 2>&1 || { echo "OpenSSH client is required" >&2; exit 1; }
fi
mkdir -p "$BIN_DIR" "$PROFILE_DIR" "$HERMES_HOME/plugins"
chmod 700 "$PROFILE_DIR" 2>/dev/null || true

export PATH="$BIN_DIR:$HOME/.local/bin:$PATH"
if ! command -v herdr >/dev/null 2>&1; then
  if [[ "$SKIP_HERDR_INSTALL" -eq 1 ]]; then
    echo "Herdr is not installed and --skip-herdr-install was set" >&2
    exit 1
  fi
  command -v curl >/dev/null 2>&1 || { echo "curl is required to install Herdr" >&2; exit 1; }
  echo "Installing Herdr stable channel..."
  curl -fsSL https://herdr.dev/install.sh | sh
  hash -r
fi
command -v herdr >/dev/null 2>&1 || {
  echo "Herdr installation completed but the executable is not on PATH" >&2
  exit 1
}

if [[ "$SKIP_PLUGIN" -eq 0 ]]; then
  [[ -f "$PLUGIN_SOURCE/plugin.yaml" && -f "$PLUGIN_SOURCE/__init__.py" && -f "$PLUGIN_SOURCE/controller.py" ]] || {
    echo "Harness plugin source is incomplete: $PLUGIN_SOURCE" >&2
    exit 1
  }
  rm -rf "$PLUGIN_DEST"
  mkdir -p "$PLUGIN_DEST"
  cp "$PLUGIN_SOURCE/plugin.yaml" "$PLUGIN_SOURCE/__init__.py" "$PLUGIN_SOURCE/controller.py" "$PLUGIN_DEST/"
else
  [[ -f "$PLUGIN_DEST/plugin.yaml" && -f "$PLUGIN_DEST/__init__.py" && -f "$PLUGIN_DEST/controller.py" ]] || {
    echo "--skip-plugin requires an existing complete plugin at $PLUGIN_DEST" >&2
    exit 1
  }
fi
python3 -m py_compile "$PLUGIN_DEST/__init__.py" "$PLUGIN_DEST/controller.py"

cat > "$BIN_DIR/herdr-hermesctl" <<EOF
#!/usr/bin/env bash
exec python3 "$PLUGIN_DEST/controller.py" "\$@"
EOF
chmod 0755 "$BIN_DIR/herdr-hermesctl"

if [[ "$MODE" == "server" ]]; then
  mkdir -p "$(dirname -- "$REPO_DIR")" "$WORKTREES_ROOT"
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    if [[ -n "$REPO_URL" ]]; then
      if [[ -e "$REPO_DIR" && -n "$(ls -A "$REPO_DIR" 2>/dev/null || true)" ]]; then
        echo "Repo directory exists and is not empty: $REPO_DIR" >&2
        exit 1
      fi
      git clone "$REPO_URL" "$REPO_DIR"
    else
      echo "No Git repository at $REPO_DIR. Supply --repo-url or clone it first." >&2
      exit 1
    fi
  fi
fi

TMP_PROFILE="$(mktemp "$PROFILE_DIR/.${PROFILE}.XXXXXX")"
trap 'rm -f "$TMP_PROFILE"' EXIT
cat > "$TMP_PROFILE" <<EOF
[harness]
target = $TARGET
session = $SESSION
repo = $REPO_DIR
worktrees_root = $WORKTREES_ROOT
base_ref = $BASE_REF
herdr_binary = herdr
ssh_control_persist = 600
timeout_ms = 120000
EOF
chmod 0600 "$TMP_PROFILE"
mv "$TMP_PROFILE" "$PROFILE_FILE"
trap - EXIT

export HERDR_HARNESS_PROFILE="$PROFILE"
if [[ "$MODE" == "server" && "$SKIP_SERVICE" -eq 0 ]]; then
  if [[ "$(uname -s)" == "Linux" && -n "$(command -v systemctl 2>/dev/null || true)" ]]; then
    HERDR_EXECUTABLE="$(command -v herdr)"
    mkdir -p "$(dirname -- "$SERVICE_FILE")"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Herdr headless server ($PROFILE)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$HERDR_EXECUTABLE --session $SESSION server
Restart=on-failure
RestartSec=3
Environment=PATH=$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF
    chmod 0644 "$SERVICE_FILE"
    systemctl --user daemon-reload
    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
      systemctl --user enable "$SERVICE_NAME" >/dev/null
      SERVICE_STATE="active"
    elif herdr --session "$SESSION" status --json >/dev/null 2>&1; then
      systemctl --user enable "$SERVICE_NAME" >/dev/null
      SERVICE_STATE="enabled-existing-server"
      echo "Warning: an existing Herdr server is not owned by systemd; stop it before starting $SERVICE_NAME." >&2
    else
      systemctl --user enable --now "$SERVICE_NAME"
      SERVICE_STATE="active"
    fi
    if command -v loginctl >/dev/null 2>&1; then
      if ! loginctl enable-linger "${USER:-$(id -un)}" >/dev/null 2>&1; then
        echo "Warning: could not enable user linger; the Herdr service may require a login after reboot." >&2
      fi
    fi
  else
    echo "Warning: systemd user services are unavailable; start 'herdr --session $SESSION server' under your supervisor." >&2
    SERVICE_STATE="external-supervisor-required"
  fi
elif [[ "$MODE" == "server" ]]; then
  SERVICE_STATE="skipped"
fi

if [[ "$SKIP_WORKSPACE" -eq 0 ]]; then
  if ! "$BIN_DIR/herdr-hermesctl" --profile "$PROFILE" --json workspace-ensure --label "$PROFILE"; then
    echo "Workspace creation failed; profile and plugin were still installed." >&2
  fi
fi
if [[ "$SKIP_DOCTOR" -eq 0 ]]; then
  if ! "$BIN_DIR/herdr-hermesctl" --profile "$PROFILE" --json doctor; then
    echo "Doctor found missing or unreachable dependencies; inspect the JSON above." >&2
  fi
fi

if [[ "$CONFIGURE_HERDRM" -eq 1 ]]; then
  DEVICE_NAME="${HERDRM_DEVICE_NAME:-$PROFILE}"
  python3 "$HERDRM_CONFIGURATOR" add \
    --name "$DEVICE_NAME" \
    --target "$TARGET" \
    --probe
fi

cat <<EOF

Herdr harness installed.
  Mode:       $MODE
  Profile:    $PROFILE
  Session:    $SESSION
  Controller: $BIN_DIR/herdr-hermesctl
  Plugin:     $PLUGIN_DEST
  Config:     $PROFILE_FILE
  Service:    $SERVICE_STATE

Attach:
  herdr-hermesctl --profile $PROFILE attach

Hermes environment:
  HERDR_HARNESS_PROFILE=$PROFILE
  HERDR_HARNESS_AUTO_ENABLE=1
EOF

if [[ "$CONFIGURE_HERDRM" -eq 1 ]]; then
  cat <<EOF

HerdrM:
  Device:     ${HERDRM_DEVICE_NAME:-$PROFILE}
  SSH target: $TARGET
  Quit and reopen HerdrM so it reloads devices.json.
EOF
fi
