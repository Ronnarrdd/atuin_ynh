#!/usr/bin/env bash
set -euo pipefail

# -------- Config you may tweak --------
SERVER_FQDN="atuin.yolo.test"
IMAGE="images:ubuntu/24.04"
CONTAINER_PREFIX="atuin-client-e2e"
# -------------------------------------

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need incus
need curl
need sed
need awk
need tr
need head

# Resolve server IP on the HOST so we can inject it into the container /etc/hosts (helps in local dev setups)
SERVER_IP="${SERVER_IP:-}"
if [[ -z "${SERVER_IP}" ]]; then
  # Try resolve via host resolver (DNS or /etc/hosts)
  if getent hosts "$SERVER_FQDN" >/dev/null 2>&1; then
    SERVER_IP="$(getent hosts "$SERVER_FQDN" | awk '{print $1}' | head -n1)"
  else
    echo "Cannot resolve ${SERVER_FQDN} on host. Set SERVER_IP explicitly, e.g.:" >&2
    echo "  SERVER_IP=10.205.204.175 $0" >&2
    exit 1
  fi
fi

RAND="$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
CNAME="${CONTAINER_PREFIX}-${RAND}"

cleanup() {
  # Best effort cleanup
  incus delete -f "$CNAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[INFO] Launching container: $CNAME ($IMAGE)"
incus launch "$IMAGE" "$CNAME" >/dev/null

# Wait for system to be ready
echo "[INFO] Waiting for cloud-init / system readiness..."
incus exec "$CNAME" -- bash -lc 'until command -v apt-get >/dev/null; do sleep 0.2; done'

# Inject hosts entry so the container can reach your local ynh-dev server by name
echo "[INFO] Injecting /etc/hosts entry inside container: $SERVER_IP $SERVER_FQDN"
incus exec "$CNAME" -- bash -lc "printf '\n# atuin e2e test\n%s %s\n' '$SERVER_IP' '$SERVER_FQDN' >> /etc/hosts"

# Install dependencies
echo "[INFO] Installing dependencies..."
incus exec "$CNAME" -- bash -lc "apt-get update -y >/dev/null && apt-get install -y ca-certificates curl bash >/dev/null"

# Install latest Atuin release (determine tag via GitHub releases/latest redirect)
echo "[INFO] Installing latest Atuin CLI release from GitHub..."
incus exec "$CNAME" -- bash -lc '
set -euo pipefail
TAG="$(curl -fsSLI https://github.com/atuinsh/atuin/releases/latest | awk -F\"/\" \"tolower(\$1) ~ /^location:/ {print \$(NF)}\" | tr -d \"\r\" | head -n1)"
if [[ -z \"$TAG\" ]]; then
  echo \"Failed to determine latest tag\" >&2
  exit 1
fi
echo \"[INFO] Latest tag: $TAG\"
curl -fsSL \"https://github.com/atuinsh/atuin/releases/download/${TAG}/atuin-installer.sh\" -o /tmp/atuin-installer.sh
sh /tmp/atuin-installer.sh >/dev/null

# Ensure atuin is on PATH (installer commonly places it under ~/.atuin/bin)
if command -v atuin >/dev/null 2>&1; then
  true
elif [[ -x \"$HOME/.atuin/bin/atuin\" ]]; then
  install -Dm755 \"$HOME/.atuin/bin/atuin\" /usr/local/bin/atuin
else
  echo \"atuin binary not found after installer\" >&2
  exit 1
fi

atuin --version
'

# Prepare random credentials
USER_NAME="ynh-e2e-${RAND}"
EMAIL="${USER_NAME}@example.invalid"
PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"

echo "[INFO] Using random user: $USER_NAME"

# Run the whole client flow in-container
echo "[INFO] Running client flow (register -> logout -> login -> commands -> sync -> verify)..."
incus exec "$CNAME" -- bash -lc "
set -euo pipefail

export HOME=/root
mkdir -p \"\$HOME/.config/atuin\"

# Configure sync server address (client config key: sync_address)
cat > \"\$HOME/.config/atuin/config.toml\" <<EOF
sync_address = \"https://${SERVER_FQDN}\"
auto_sync = false
EOF

# Register (also logs in on success)
atuin register -u '${USER_NAME}' -e '${EMAIL}' -p '${PASS}'

# Capture encryption key, then force a login step as requested
KEY=\"\$(atuin key)\"
atuin logout
atuin login -u '${USER_NAME}' -p '${PASS}' -k \"\$KEY\"

# Run a tiny interactive bash session with atuin integration enabled so commands get recorded
TEST_MARK=\"atuin-e2e-${RAND}\"
bash --noprofile --norc -i <<'EOS'
set -e
eval \"\$(atuin init bash)\"

echo \"Hello from \$TEST_MARK\"
pwd
echo \"Testing atuin history recording: \$TEST_MARK\"
ls >/dev/null
exit
EOS

# Sync
atuin sync

# Verify commands exist in local atuin history
# (history list --cmd-only is documented)
if ! atuin history list --cmd-only | grep -F \"Hello from atuin-e2e-${RAND}\" >/dev/null; then
  echo \"[FAIL] Expected command not found in atuin history\" >&2
  exit 2
fi

echo \"[OK] Commands recorded + sync executed successfully\"
"

echo "[INFO] Done. Container will be removed."

