#!/usr/bin/env bash
set -euo pipefail

for n in atuin-client1 atuin-client2 atuin-server; do
  if incus info "$n" >/dev/null 2>&1; then
    echo "[INFO] Deleting $n"
    incus delete -f "$n"
  fi
done

echo "[OK] Containers removed"
echo "[INFO] Persistent data kept in:"
echo "  ${HOME}/incus-atuin/server/"
echo
echo "[INFO] To delete everything (including root-owned SQLite files) run:"
echo "  sudo rm -rfv \"${HOME}/incus-atuin/\""
