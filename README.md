# cursor-nordlynx

Route only **Cursor** traffic (IDE, Agent window, integrated terminal, `cursor-agent` CLI) through NordVPN. Everything else is untouched. No NordVPN desktop app and no split tunneling required.

## How it works

```
Cursor ──socks5://127.0.0.1:8964──┐
                                  ├─▶ wireproxy ──WireGuard (NordLynx)──▶ NordVPN server ──▶ Internet
cursor-agent ──http://127.0.0.1:8965──┘
Other apps ────────────────────────────────────────────────────────────────────▶ Internet (your normal network)
```

- [wireproxy](https://github.com/pufferffish/wireproxy) is a userspace WireGuard client. It does not create a virtual NIC and does not need admin. It opens a local SOCKS5 + HTTP proxy; traffic through it exits via the WireGuard tunnel.
- NordLynx is WireGuard. With a NordVPN access token you fetch your account’s NordLynx private key and a server public key from the API, then connect to any NordVPN server.
- Cursor uses `http.proxy` for SOCKS5. The `cursor-agent` CLI only honors `HTTP_PROXY`/`HTTPS_PROXY` and only supports HTTP proxies, so a separate HTTP listener is opened.

## Prerequisites

1. Create an **access token** at [Nord Account → Manual configuration](https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/) (prefer one that does not expire).
2. Copy `.env.example` to `.env` and fill in the token. Adjust other values as needed:

   ```ini
   NORDVPN_TOKEN=xxxxxxxx
   COUNTRY_ID=114        # empty = nearest recommended server; 97 HK, 108 JP, 114 KR, 195 SG, 211 TW, 228 US
   SOCKS_PORT=8964
   HTTP_PORT=8965
   ```

   You can also run the script without a `.env`; it will prompt for the token and write it for you.

## Windows

```powershell
cd ~\Repo\cursor-nordlynx
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

The script will:

1. Check that ports are not in Windows reserved ranges (Hyper-V/WSL `excludedportrange`, which causes `bind: access permissions` errors).
2. Locate `wireproxy.exe`: `bin\` first, then PATH; if missing, download from GitHub into `bin\`.
3. Call the NordVPN API for the private key and a recommended server, then write `wireproxy.conf`.
4. Update `%APPDATA%\Cursor\User\settings.json` (backs up to `.bak` first):
   ```json
   "http.proxy": "socks5://127.0.0.1:8964",
   "http.proxySupport": "override",
   "cursor.general.disableHttp2": true,
   "terminal.integrated.env.windows": {
     "HTTP_PROXY": "http://127.0.0.1:8965",
     "HTTPS_PROXY": "http://127.0.0.1:8965",
     "NODE_USE_ENV_PROXY": "1"
   }
   ```
5. Update `~\.cursor\cli-config.json`: `"network": { "useHttp1ForAgent": true }`.
6. Create a Task Scheduler job `cursor-nordlynx-wireproxy` that runs `start-wireproxy.ps1` hidden at logon (falls back to a Startup-folder shortcut if permission is denied), and start it immediately.
7. Wait for the proxy, then print your exit IP through the proxy.

When done, **fully quit Cursor and reopen** (Reload Window is not enough).

Manual control:

```powershell
Start-ScheduledTask -TaskName cursor-nordlynx-wireproxy    # start
Get-Process wireproxy | Stop-Process                        # stop
Get-Content .\logs\wireproxy.err.log -Tail 50               # logs
```

## macOS

```bash
cd ~/Repo/cursor-nordlynx
chmod +x setup.sh
./setup.sh
```

The script will:

1. Locate `wireproxy`: `bin/` first, then PATH; otherwise `brew install go` and `go install github.com/windtf/wireproxy/cmd/wireproxy@latest`.
2. Call the NordVPN API for the private key and a recommended server, then write `wireproxy.conf` (mode 600).
3. Update `~/Library/Application Support/Cursor/User/settings.json` (backs up to `.bak` first). Same keys as Windows, except terminal env uses `terminal.integrated.env.osx`.
4. Update `~/.cursor/cli-config.json`: `"network": { "useHttp1ForAgent": true }`.
5. Create `~/Library/LaunchAgents/com.cursor-nordlynx.wireproxy.plist` (`RunAtLoad` + `KeepAlive`, restarts if it dies) and load it immediately.
6. Wait for the proxy, then print your exit IP through the proxy.

When done, **Cmd+Q to fully quit Cursor and reopen**.

Manual control:

```bash
launchctl kickstart -k gui/$(id -u)/com.cursor-nordlynx.wireproxy   # restart
launchctl bootout gui/$(id -u)/com.cursor-nordlynx.wireproxy        # stop (starts again on next login)
tail -50 logs/wireproxy.err.log
```

## Verify

1. **Proxy itself**:
   ```bash
   curl -x http://127.0.0.1:8965 https://api.ipify.org      # should show a NordVPN IP
   curl https://api.ipify.org                                # should show your own IP
   ```
2. **Cursor actually using the proxy**: Temporarily set `http.proxy` in `settings.json` to `socks5://127.0.0.1:9`, fully quit and reopen Cursor, send a prompt. Error = proxy is used; normal reply = bypassed. Change it back afterward.
3. **cursor-agent**: Run `cursor-agent` in Cursor’s integrated terminal; in another terminal run `netstat -ano | findstr :8965` (mac: `lsof -i :8965`) and check for a connection.

## Coverage

| Traffic | Via VPN? | Notes |
|---|---|---|
| Cursor main window, Agent window, Tab, indexing | Yes | Same Cursor process; shares `http.proxy` |
| `cursor-agent`, `git`, `npm`, `curl` in Cursor’s integrated terminal | Yes | Via `terminal.integrated.env.*` |
| `cursor-agent` in an external terminal (Windows Terminal / iTerm) | No | See below |
| Cloud Agent | N/A | Runs on Cursor’s servers |
| All other apps | No | That’s the point |

For `cursor-agent` in an external terminal via VPN, add a wrapper to your shell profile:

```powershell
# PowerShell $PROFILE
function cagent { $env:HTTP_PROXY = $env:HTTPS_PROXY = 'http://127.0.0.1:8965'; $env:NODE_USE_ENV_PROXY = '1'; cursor-agent @args }
```

```bash
# ~/.zshrc
cagent() { HTTP_PROXY=http://127.0.0.1:8965 HTTPS_PROXY=http://127.0.0.1:8965 NODE_USE_ENV_PROXY=1 cursor-agent "$@"; }
```

Do not set `HTTPS_PROXY` as a global environment variable — that would send every app through the VPN.

## Change server / country

Edit `COUNTRY_ID` in `.env` and rerun `setup.ps1` / `setup.sh`. Each run asks NordVPN for a currently low-load server and restarts wireproxy, so a dead server is also fixed by rerunning.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Uninstall
```

```bash
./setup.sh --uninstall
```

Removes the logon task / launch agent, stops wireproxy, and removes the Cursor settings keys the script added. Keeps `wireproxy.conf`, `bin/`, and `.env`.

Both scripts support `-SkipCursorSettings` / `--skip-cursor` to only manage wireproxy and autostart without touching Cursor settings.

## Troubleshooting

**`bind: An attempt was made to access a socket in a way forbidden by its access permissions` (Windows)**  
Port is in a Hyper-V/WSL reserved range. Check with `netsh int ipv4 show excludedportrange protocol=tcp`, change the port in `.env`, and rerun setup. These ranges can change each boot, so pick a port far from all ranges (e.g. 8xxx, 9xxx).

**Cursor ignores the proxy and connects directly**  
`cursor.general.disableHttp2` must be `true`. Agent traffic over HTTP/2 can bypass `http.proxy` (confirmed repeatedly on the Cursor forum). Some versions (3.9.x) also bypassed over HTTP/1.1 — use verify step 2 above.

**settings.json parse failure**  
`//` comments and trailing commas are accepted. If the file is not valid JSON, the script stops and leaves it alone. Fix it and rerun, or use `-SkipCursorSettings` / `--skip-cursor` and paste the settings manually.

**Connected but slow / flaky**  
Rerun setup to pick another server. NordVPN’s recommendation API returns currently low-load servers.

**wireproxy is listening but no traffic goes out**  
Check `logs/wireproxy.err.log`. Common causes: expired NordLynx private key (regenerate token and rerun) or a dead server (rerun setup).

## Files

| File | Purpose | In git? |
|---|---|---|
| `setup.ps1` / `setup.sh` | One-shot install / refresh / uninstall | Yes |
| `start-wireproxy.ps1` | Hidden launcher used by Windows Task Scheduler | Yes |
| `.env.example` | Config template | Yes |
| `.env` | Token and port settings | **No** |
| `wireproxy.conf` | Generated WireGuard config (includes private key) | **No** |
| `bin/`, `logs/` | Downloaded binary, runtime logs | No |
