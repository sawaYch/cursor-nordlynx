#!/usr/bin/env bash
# macOS one-shot setup: wireproxy + NordLynx + Cursor settings + launchd autostart
#   ./setup.sh                 install / refresh
#   ./setup.sh --uninstall     remove launch agent and Cursor settings
#   ./setup.sh --skip-cursor   do not touch Cursor settings
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.cursor-nordlynx.wireproxy"
CONF="$REPO_DIR/wireproxy.conf"
BIN_DIR="$REPO_DIR/bin"
LOG_DIR="$REPO_DIR/logs"
ENV_FILE="$REPO_DIR/.env"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CURSOR_SETTINGS="$HOME/Library/Application Support/Cursor/User/settings.json"
CLI_CONFIG="$HOME/.cursor/cli-config.json"

UNINSTALL=0
SKIP_CURSOR=0
for a in "$@"; do
  case "$a" in
    --uninstall) UNINSTALL=1 ;;
    --skip-cursor) SKIP_CURSOR=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

step() { printf '\033[36m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

json_tool() {
  if command -v python3 >/dev/null 2>&1; then echo python3
  else die "python3 is required to edit JSON settings (built into macOS; run xcode-select --install if needed)."
  fi
}

# json_merge FILE 'JSON'   deep-merges JSON into FILE (creates it if missing)
json_merge() {
  local file="$1" updates="$2"
  mkdir -p "$(dirname "$file")"
  [ -f "$file" ] && cp "$file" "$file.bak"
  "$(json_tool)" - "$file" "$updates" <<'PY'
import json, os, re, sys
path, updates = sys.argv[1], json.loads(sys.argv[2])
STR = r'("(?:\\.|[^"\\])*")'
def loads_jsonc(text):
    text = re.sub(STR + r'|//[^\r\n]*|/\*[\s\S]*?\*/', lambda m: m.group(1) or '', text)
    text = re.sub(STR + r'|,(?=\s*[}\]])', lambda m: m.group(1) or '', text)
    return json.loads(text)
data = {}
if os.path.exists(path) and open(path).read().strip():
    try:
        data = loads_jsonc(open(path).read())
    except json.JSONDecodeError as e:
        sys.exit(f"Failed to parse {path}: {e}\nFix the JSON first, or use --skip-cursor and add settings manually.")
def merge(d, u):
    for k, v in u.items():
        if isinstance(v, dict) and isinstance(d.get(k), dict):
            merge(d[k], v)
        else:
            d[k] = v
merge(data, updates)
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

# json_remove FILE key1 key2 ...   (dotted path = nested, e.g. network.useHttp1ForAgent)
json_remove() {
  local file="$1"; shift
  [ -f "$file" ] || return 0
  cp "$file" "$file.bak"
  "$(json_tool)" - "$file" "$@" <<'PY'
import json, re, sys
path, keys = sys.argv[1], sys.argv[2:]
STR = r'("(?:\\.|[^"\\])*")'
try:
    text = open(path).read()
    text = re.sub(STR + r'|//[^\r\n]*|/\*[\s\S]*?\*/', lambda m: m.group(1) or '', text)
    text = re.sub(STR + r'|,(?=\s*[}\]])', lambda m: m.group(1) or '', text)
    data = json.loads(text)
except Exception:
    sys.exit(0)
for key in keys:
    parts = key.split("/")
    d = data
    for p in parts[:-1]:
        d = d.get(p) if isinstance(d, dict) else None
        if d is None: break
    if isinstance(d, dict):
        d.pop(parts[-1], None)
        if not d and len(parts) > 1:
            parent = data
            for p in parts[:-2]: parent = parent[p]
            parent.pop(parts[-2], None)
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

load_env() {
  [ -f "$ENV_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line// /}"
    [ -z "$line" ] && continue
    key="${line%%=*}"; val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    [ -n "$key" ] && export "ENV_$key=$val"
  done < "$ENV_FILE"
}

stop_wireproxy() {
  pkill -f 'wireproxy.*wireproxy\.conf' 2>/dev/null || true
  for p in "${ENV_SOCKS_PORT:-8964}" "${ENV_HTTP_PORT:-8965}"; do
    for pid in $(lsof -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null); do
      ps -o comm= -p "$pid" | grep -q wireproxy && kill "$pid" 2>/dev/null || true
    done
  done
  sleep 0.5
}

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
  load_env
  step "Remove launch agent"
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  stop_wireproxy
  if [ "$SKIP_CURSOR" = 0 ]; then
    step "Restore Cursor settings"
    json_remove "$CURSOR_SETTINGS" "http.proxy" "http.proxySupport" "cursor.general.disableHttp2" \
      "terminal.integrated.env.osx/HTTP_PROXY" "terminal.integrated.env.osx/HTTPS_PROXY" "terminal.integrated.env.osx/NODE_USE_ENV_PROXY"
    json_remove "$CLI_CONFIG" "network/useHttp1ForAgent"
  fi
  echo "Done. wireproxy.conf and bin/ are kept in the repo; delete them yourself if you want."
  exit 0
fi

# ---------------------------------------------------------------- config
step "Load config"
load_env
TOKEN="${ENV_NORDVPN_TOKEN:-${NORDVPN_TOKEN:-}}"
COUNTRY_ID="${ENV_COUNTRY_ID:-}"
SOCKS_PORT="${ENV_SOCKS_PORT:-8964}"
HTTP_PORT="${ENV_HTTP_PORT:-8965}"

if [ -z "$TOKEN" ]; then
  read -r -p "Paste NordVPN access token (https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/): " TOKEN
  [ -n "$TOKEN" ] || die "No token; cannot continue."
  [ -f "$ENV_FILE" ] || cp "$REPO_DIR/.env.example" "$ENV_FILE"
  if grep -q '^NORDVPN_TOKEN=' "$ENV_FILE"; then
    sed -i '' "s|^NORDVPN_TOKEN=.*|NORDVPN_TOKEN=$TOKEN|" "$ENV_FILE"
  else
    printf '\nNORDVPN_TOKEN=%s\n' "$TOKEN" >> "$ENV_FILE"
  fi
fi

# ---------------------------------------------------------------- wireproxy binary
step "Locate wireproxy"
EXE="$BIN_DIR/wireproxy"
if [ ! -x "$EXE" ]; then
  if command -v wireproxy >/dev/null 2>&1; then
    EXE="$(command -v wireproxy)"
    echo "Using installed $EXE"
  elif command -v brew >/dev/null 2>&1; then
    echo "brew install wireproxy"
    brew install wireproxy
    EXE="$(command -v wireproxy)"
  else
    case "$(uname -m)" in
      arm64) arch=arm64 ;;
      x86_64) arch=amd64 ;;
      *) die "Unsupported architecture $(uname -m)" ;;
    esac
    url="https://github.com/pufferffish/wireproxy/releases/latest/download/wireproxy_darwin_$arch.tar.gz"
    echo "Downloading $url"
    mkdir -p "$BIN_DIR"
    curl -fsSL "$url" | tar -xz -C "$BIN_DIR"
    chmod +x "$EXE"
    xattr -d com.apple.quarantine "$EXE" 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------- NordVPN API
step "Fetch NordLynx private key and server from NordVPN"
PY="$(json_tool)"
CRED_JSON="$(curl -fsS -u "token:$TOKEN" https://api.nordvpn.com/v1/users/services/credentials)" \
  || die "NordVPN API rejected this token. Check that it is valid and not expired."
PRIVATE_KEY="$(printf '%s' "$CRED_JSON" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["nordlynx_private_key"])')"
[ -n "$PRIVATE_KEY" ] || die "API response has no nordlynx_private_key."

Q='https://api.nordvpn.com/v1/servers/recommendations?filters[servers_technologies][identifier]=wireguard_udp&limit=1'
[ -n "$COUNTRY_ID" ] && Q="$Q&filters[country_id]=$COUNTRY_ID"
SRV_JSON="$(curl -fsS -g "$Q")"
read -r SRV_NAME SRV_HOST SRV_IP SRV_LOAD PUBLIC_KEY < <(printf '%s' "$SRV_JSON" | "$PY" -c '
import json, sys
srv = json.load(sys.stdin)
if not srv: sys.exit("No server found")
s = srv[0]
tech = next(t for t in s["technologies"] if t["identifier"] == "wireguard_udp")
pub = next(m["value"] for m in tech["metadata"] if m["name"] == "public_key")
print(s["name"].replace(" ", "_"), s["hostname"], s["station"], s["load"], pub)
')
[ -n "${PUBLIC_KEY:-}" ] || die "No server or WireGuard public key found (COUNTRY_ID=$COUNTRY_ID)."
echo "Server: $SRV_NAME ($SRV_HOST, $SRV_IP) load=$SRV_LOAD"

# ---------------------------------------------------------------- wireproxy.conf
step "Write $CONF"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
stop_wireproxy
cat > "$CONF" <<EOF
# $SRV_NAME / $SRV_HOST - generated $(date '+%Y-%m-%d %H:%M')
[Interface]
PrivateKey = $PRIVATE_KEY
Address = 10.5.0.2/32
DNS = 103.86.96.100, 103.86.99.100

[Peer]
PublicKey = $PUBLIC_KEY
Endpoint = $SRV_IP:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

[Socks5]
BindAddress = 127.0.0.1:$SOCKS_PORT

[http]
BindAddress = 127.0.0.1:$HTTP_PORT
EOF
chmod 600 "$CONF"

# ---------------------------------------------------------------- Cursor settings
if [ "$SKIP_CURSOR" = 0 ]; then
  step "Update Cursor settings: $CURSOR_SETTINGS"
  json_merge "$CURSOR_SETTINGS" "$(cat <<EOF
{
  "http.proxy": "socks5://127.0.0.1:$SOCKS_PORT",
  "http.proxySupport": "override",
  "cursor.general.disableHttp2": true,
  "terminal.integrated.env.osx": {
    "HTTP_PROXY": "http://127.0.0.1:$HTTP_PORT",
    "HTTPS_PROXY": "http://127.0.0.1:$HTTP_PORT",
    "NODE_USE_ENV_PROXY": "1"
  }
}
EOF
)"
  step "Update Cursor CLI config: $CLI_CONFIG"
  json_merge "$CLI_CONFIG" '{"network":{"useHttp1ForAgent":true}}'
fi

# ---------------------------------------------------------------- launchd
step "Register launchd autostart"
mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$EXE</string>
    <string>-c</string>
    <string>$CONF</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$LOG_DIR/wireproxy.out.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/wireproxy.err.log</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"

# ---------------------------------------------------------------- verify
step "Wait for wireproxy to start"
ok=0
for _ in $(seq 1 20); do
  sleep 0.5
  if nc -z 127.0.0.1 "$SOCKS_PORT" 2>/dev/null; then ok=1; break; fi
done
if [ "$ok" = 0 ]; then
  echo "wireproxy is not listening on 127.0.0.1:$SOCKS_PORT; see $LOG_DIR/wireproxy.err.log" >&2
else
  if ip="$(curl -fsS --max-time 15 -x "http://127.0.0.1:$HTTP_PORT" https://api.ipify.org)"; then
    printf '\033[32mExit IP via proxy: %s\033[0m\n' "$ip"
  else
    echo "Proxy is listening, but the test request failed; see $LOG_DIR/wireproxy.err.log" >&2
  fi
fi

echo
printf '\033[32mDone. Fully quit Cursor (Cmd+Q, not Reload Window) and reopen it.\033[0m\n'
