#!/usr/bin/env bash
set -euo pipefail

SERVER_NAME="atuin-server"
CLIENT1="atuin-client1"
CLIENT2="atuin-client2"
PORT="8888"
VERSION="18.10.0"

CLIENT1_IMAGE="images:ubuntu/22.04"
CLIENT2_IMAGE="images:ubuntu/24.04"

USERNAME="testuser"
EMAIL="testuser@example.com"
PASSWORD="test-pass-123"

require() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] Missing '$1'"; exit 1; }; }
require incus

if ! incus info "${SERVER_NAME}" >/dev/null 2>&1; then
  echo "[ERROR] Server '${SERVER_NAME}' not found. Run ./atuin-incus-up.sh first."
  exit 1
fi

echo "[INFO] Ensuring server service is active..."
if ! incus exec "${SERVER_NAME}" -- bash -lc "systemctl is-active --quiet atuin-server"; then
  echo "[ERROR] atuin-server service is not active"
  incus exec "${SERVER_NAME}" -- bash -lc "systemctl status atuin-server --no-pager -l || true"
  incus exec "${SERVER_NAME}" -- bash -lc "journalctl -u atuin-server --no-pager -n 200 -l || true"
  exit 1
fi

echo "[INFO] Getting server IPv4..."
SERVER_IP="$(incus list "${SERVER_NAME}" -c 4 --format csv | head -n1 | cut -d' ' -f1 | cut -d, -f1)"
if [[ -z "${SERVER_IP}" ]]; then
  echo "[ERROR] Could not detect server IP."
  exit 1
fi
SYNC_ADDR="http://${SERVER_IP}:${PORT}"
echo "[INFO] Using ATUIN_SYNC_ADDRESS=${SYNC_ADDR}"

cleanup_instance() {
  local n="$1"
  if incus info "$n" >/dev/null 2>&1; then
    incus delete -f "$n" >/dev/null
  fi
}

install_atuin() {
  local n="$1"
  incus exec "$n" -- bash -lc "
    set -e
    apt-get update
    apt-get install -y ca-certificates curl tar
    arch=\$(uname -m)
    case \"\$arch\" in
      x86_64)  pkg='atuin-x86_64-unknown-linux-gnu.tar.gz' ;;
      aarch64) pkg='atuin-aarch64-unknown-linux-gnu.tar.gz' ;;
      *) echo 'Unsupported arch: '\"\$arch\"; exit 1 ;;
    esac
    cd /tmp
    curl -fsSL -o atuin.tgz \"https://github.com/atuinsh/atuin/releases/download/v${VERSION}/\${pkg}\"
    tar -xzf atuin.tgz
    dir=\$(find . -maxdepth 1 -type d -name 'atuin-*unknown-linux-*' | head -n1)
    install -m 0755 \"\${dir}/atuin\" /usr/local/bin/atuin
    /usr/local/bin/atuin --version
  "
}

echo "[INFO] Recreating clients..."
cleanup_instance "${CLIENT1}"
cleanup_instance "${CLIENT2}"

echo "[INFO] Launching client1: Ubuntu 22.04"
incus launch "${CLIENT1_IMAGE}" "${CLIENT1}"

echo "[INFO] Launching client2: Ubuntu 24.04"
incus launch "${CLIENT2_IMAGE}" "${CLIENT2}"

echo "[INFO] Installing atuin in clients..."
install_atuin "${CLIENT1}"
install_atuin "${CLIENT2}"

echo "[TEST] Client1: register + execute 5 harmless cmds + import + sync"
incus exec "${CLIENT1}" -- bash -lc "
  set -e
  export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'
  export ATUIN_SESSION=\"incus-test-client1-\$(date +%s%N)\"

  atuin register -u '${USERNAME}' -e '${EMAIL}' -p '${PASSWORD}'

  RUN_ID=\$(date +%s%N)
  echo \"\$RUN_ID\" > /tmp/atuin_run_id

  HISTFILE=/tmp/atuin_bash_history
  export HISTFILE
  set -o history
  history -c

  for i in 1 2 3 4 5; do
    cmd=\"echo ATUIN_TEST_\${RUN_ID}_\${i}\"
    eval \"\$cmd\"
    history -s \"\$cmd\"
  done
  history -a

  atuin import bash
  atuin sync
  atuin status | sed -n '1,120p'
"

RUN_ID="$(incus exec "${CLIENT1}" -- bash -lc "cat /tmp/atuin_run_id" | tr -d '\r\n')"
if [[ -z "${RUN_ID}" ]]; then
  echo "[ERROR] Failed to read RUN_ID from client1"
  exit 1
fi
echo "[INFO] RUN_ID=${RUN_ID}"

echo "[INFO] Client1: extracting key"
KEY="$(incus exec "${CLIENT1}" -- bash -lc "export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'; atuin key" | tr -d '\r' | sed -n '1p')"
if [[ -z "${KEY}" ]]; then
  echo "[ERROR] Failed to read atuin key from client1"
  exit 1
fi

echo "[TEST] Client1: logout"
incus exec "${CLIENT1}" -- bash -lc "
  set -e
  export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'
  export ATUIN_SESSION=\"incus-test-client1-logout-\$(date +%s%N)\"
  atuin logout
"

echo "[TEST] Client2: login + sync + verify 5 cmds were synced"
incus exec "${CLIENT2}" -- bash -lc "
  set -e
  export ATUIN_SYNC_ADDRESS='${SYNC_ADDR}'
  export ATUIN_SESSION=\"incus-test-client2-\$(date +%s%N)\"

  atuin login -u '${USERNAME}' -p '${PASSWORD}' -k '${KEY}'
  atuin sync

  got=\$(atuin history list --cmd-only | grep -F \"ATUIN_TEST_${RUN_ID}_\" | sort -u | wc -l)
  if [ \"\$got\" -ne 5 ]; then
    echo \"[ERROR] Expected 5 synced commands for RUN_ID=${RUN_ID}, got \$got\"
    echo \"[DEBUG] Matching lines:\"
    atuin history list --cmd-only | grep -F \"ATUIN_TEST_${RUN_ID}_\" | tail -n 100 || true
    exit 1
  fi

  echo \"[OK] Synced 5 test commands (RUN_ID=${RUN_ID})\"
  atuin status | sed -n '1,120p'
"

echo "[OK] Tests passed: register, execute+record 5 cmds, import, sync, login, verify sync."
echo "[INFO] Leaving clients running for inspection:"
echo "       incus exec ${CLIENT1} -- bash"
echo "       incus exec ${CLIENT2} -- bash"

