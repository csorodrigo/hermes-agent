#!/usr/bin/env bash
set -euo pipefail

BRANCH="${HERDR_HARNESS_BRANCH:-feat/herdr-hermes-team-harness}"
REPO_URL_SSH="${HERDR_HARNESS_REPO_URL:-git@github.com:csorodrigo/hermes-agent.git}"
REPO_URL_HTTPS="https://github.com/csorodrigo/hermes-agent.git"
HARNESS_DIR="${HERDR_HARNESS_DIR:-$HOME/.cache/herdr-hermes-harness}"

for binary in git python3 ssh; do
  if ! command -v "$binary" >/dev/null 2>&1; then
    echo "ERRO: $binary não está disponível no PATH." >&2
    exit 1
  fi
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERRO: este instalador é destinado ao macOS." >&2
  exit 1
fi

if ! command -v herdr >/dev/null 2>&1; then
  echo "Instalando o Herdr local..."
  curl -fsSL https://herdr.dev/install.sh | sh
  export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
fi

if ! command -v herdr >/dev/null 2>&1; then
  echo "ERRO: Herdr foi instalado, mas ainda não está no PATH." >&2
  echo 'Adicione export PATH="$HOME/.local/bin:$PATH" ao seu shell e execute novamente.' >&2
  exit 1
fi

echo "Fechando o HerdrM para atualizar o inventário com segurança..."
osascript -e 'tell application "HerdrM" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! pgrep -x HerdrM >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if pgrep -x HerdrM >/dev/null 2>&1; then
  echo "ERRO: o HerdrM continua aberto. Feche-o completamente e execute novamente." >&2
  exit 1
fi

mkdir -p "$(dirname "$HARNESS_DIR")"
if [[ -d "$HARNESS_DIR/.git" ]]; then
  echo "Atualizando harness em $HARNESS_DIR..."
  git -C "$HARNESS_DIR" fetch origin "$BRANCH"
  git -C "$HARNESS_DIR" switch "$BRANCH" 2>/dev/null \
    || git -C "$HARNESS_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
  git -C "$HARNESS_DIR" pull --ff-only origin "$BRANCH"
else
  echo "Clonando harness em $HARNESS_DIR..."
  if ! git clone --branch "$BRANCH" --single-branch "$REPO_URL_SSH" "$HARNESS_DIR"; then
    echo "Clone por SSH falhou; tentando HTTPS..."
    rm -rf "$HARNESS_DIR"
    git clone --branch "$BRANCH" --single-branch "$REPO_URL_HTTPS" "$HARNESS_DIR"
  fi
fi

echo
echo "Procurando aliases concretos em ~/.ssh/config e adicionando apenas hosts com Herdr ativo..."
python3 "$HARNESS_DIR/scripts/configure_herdrm.py" sync-ssh-config --probe

echo
echo "Validando todos os dispositivos remotos configurados..."
python3 "$HARNESS_DIR/scripts/configure_herdrm.py" doctor || true

echo
echo "Inventário final do HerdrM:"
python3 "$HARNESS_DIR/scripts/configure_herdrm.py" list

echo
echo "Abrindo o HerdrM..."
open -a HerdrM

echo
echo "Concluído. Se somente Local aparecer, os hosts SSH ainda não têm o Herdr padrão ativo ou não passaram no probe."
