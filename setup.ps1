[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$SkipCursorSettings
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        $fwd = @($PSBoundParameters.Keys | ForEach-Object { "-$_" })
        & $pwsh.Source -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @fwd
        exit $LASTEXITCODE
    }
}

$RepoDir   = $PSScriptRoot
$TaskName  = 'cursor-nordlynx-wireproxy'
$ConfPath  = Join-Path $RepoDir 'wireproxy.conf'
$BinDir    = Join-Path $RepoDir 'bin'
$EnvPath   = Join-Path $RepoDir '.env'
$Runner    = Join-Path $RepoDir 'start-wireproxy.ps1'
$CursorSettings = Join-Path $env:APPDATA 'Cursor\User\settings.json'
$CliConfig      = Join-Path $HOME '.cursor\cli-config.json'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Read-Utf8($path) { [IO.File]::ReadAllText($path, $Utf8NoBom) }
function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, $Utf8NoBom) }

function Import-DotEnv($path) {
    $map = @{}
    if (-not (Test-Path $path)) { return $map }
    foreach ($line in (Read-Utf8 $path) -split "`r?`n") {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $map[$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim().Trim('"').Trim("'")
    }
    return $map
}

function ConvertFrom-Jsonc($text) {
    $str = '("(?:\\.|[^"\\])*")'
    $text = [regex]::Replace($text, "$str|//[^\r\n]*|/\*[\s\S]*?\*/", '$1')
    $text = [regex]::Replace($text, "$str|,(?=\s*[}\]])", '$1')
    return ($text | ConvertFrom-Json)
}

function Read-JsonFile($path) {
    if (-not (Test-Path $path)) { return [pscustomobject]@{} }
    $raw = Read-Utf8 $path
    if (-not $raw -or -not $raw.Trim()) { return [pscustomobject]@{} }
    try { return (ConvertFrom-Jsonc $raw) }
    catch { throw "Failed to parse $path ($($_.Exception.Message)). Fix the JSON first, or use -SkipCursorSettings and add settings manually." }
}

function Save-JsonFile($path, $obj) {
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    if (Test-Path $path) { Copy-Item $path "$path.bak" -Force }
    Write-Utf8 $path (($obj | ConvertTo-Json -Depth 50) + "`n")
}

function Set-Prop($obj, $name, $value) {
    $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
}

function Remove-Prop($obj, $name) {
    if ($obj.PSObject.Properties[$name]) { $obj.PSObject.Properties.Remove($name) }
}

function Test-PortExcluded([int]$port) {
    foreach ($l in (netsh int ipv4 show excludedportrange protocol=tcp)) {
        if ($l -match '^\s*(\d+)\s+(\d+)') {
            if ($port -ge [int]$matches[1] -and $port -le [int]$matches[2]) { return $true }
        }
    }
    return $false
}

function Stop-Wireproxy([int[]]$ports) {
    $owners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $ports -contains $_.LocalPort } | Select-Object -ExpandProperty OwningProcess)
    Get-Process wireproxy -ErrorAction SilentlyContinue | ForEach-Object {
        try { $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine } catch { $cmdline = '' }
        if ($cmdline -like '*wireproxy.conf*' -or $owners -contains $_.Id) {
            Write-Host "Stopping old wireproxy (PID $($_.Id))"
            Stop-Process -Id $_.Id -Force
        }
    }
    Start-Sleep -Milliseconds 500
}

# ---------------------------------------------------------------- uninstall
if ($Uninstall) {
    Write-Step 'Remove autostart task'
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) "$TaskName.lnk"
    Remove-Item $startupLnk -Force -ErrorAction SilentlyContinue

    Write-Step 'Stop wireproxy'
    $cfg = Import-DotEnv $EnvPath
    Stop-Wireproxy @([int]($(if ($cfg.SOCKS_PORT) { $cfg.SOCKS_PORT } else { 8964 })), [int]($(if ($cfg.HTTP_PORT) { $cfg.HTTP_PORT } else { 8965 })))

    if (-not $SkipCursorSettings) {
        Write-Step 'Restore Cursor settings'
        if (Test-Path $CursorSettings) {
            $s = Read-JsonFile $CursorSettings
            foreach ($k in 'http.proxy', 'http.proxySupport', 'cursor.general.disableHttp2') { Remove-Prop $s $k }
            $termEnv = $s.'terminal.integrated.env.windows'
            if ($termEnv) {
                foreach ($k in 'HTTP_PROXY', 'HTTPS_PROXY', 'NODE_USE_ENV_PROXY') { Remove-Prop $termEnv $k }
                if (-not $termEnv.PSObject.Properties.Name) { Remove-Prop $s 'terminal.integrated.env.windows' }
            }
            Save-JsonFile $CursorSettings $s
        }
        if (Test-Path $CliConfig) {
            $c = Read-JsonFile $CliConfig
            if ($c.network) { Remove-Prop $c.network 'useHttp1ForAgent' }
            Save-JsonFile $CliConfig $c
        }
    }
    Write-Host 'Done. wireproxy.conf and bin/ are kept in the repo; delete them yourself if you want.' -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- config
Write-Step 'Load config'
$cfg = Import-DotEnv $EnvPath
$Token     = if ($cfg.NORDVPN_TOKEN) { $cfg.NORDVPN_TOKEN } elseif ($env:NORDVPN_TOKEN) { $env:NORDVPN_TOKEN } else { '' }
$CountryId = if ($cfg.ContainsKey('COUNTRY_ID')) { $cfg.COUNTRY_ID } else { '' }
$SocksPort = if ($cfg.SOCKS_PORT) { [int]$cfg.SOCKS_PORT } else { 8964 }
$HttpPort  = if ($cfg.HTTP_PORT)  { [int]$cfg.HTTP_PORT }  else { 8965 }

if (-not $Token) {
    $Token = (Read-Host 'Paste NordVPN access token (https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/)').Trim()
    if (-not $Token) { throw 'No token; cannot continue.' }
    if (-not (Test-Path $EnvPath)) { Copy-Item (Join-Path $RepoDir '.env.example') $EnvPath }
    $envText = Read-Utf8 $EnvPath
    if ($envText -match '(?m)^NORDVPN_TOKEN=') { $envText = $envText -replace '(?m)^NORDVPN_TOKEN=.*$', "NORDVPN_TOKEN=$Token" }
    else { $envText += "`nNORDVPN_TOKEN=$Token`n" }
    Write-Utf8 $EnvPath $envText
}

foreach ($p in $SocksPort, $HttpPort) {
    if (Test-PortExcluded $p) {
        throw "Port $p is in a Windows reserved range (Hyper-V/WSL); wireproxy will fail to bind. Pick another port in .env. List ranges with: netsh int ipv4 show excludedportrange protocol=tcp"
    }
}

# ---------------------------------------------------------------- wireproxy binary
Write-Step 'Locate wireproxy'
$Exe = Join-Path $BinDir 'wireproxy.exe'
if (-not (Test-Path $Exe)) {
    $found = Get-Command wireproxy.exe -ErrorAction SilentlyContinue
    if ($found) {
        $Exe = $found.Source
        Write-Host "Using installed $Exe"
    } else {
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'AMD64' { 'amd64' } 'x86' { '386' } default { throw "wireproxy has no Windows build for $($env:PROCESSOR_ARCHITECTURE)." } }
        $url = "https://github.com/pufferffish/wireproxy/releases/latest/download/wireproxy_windows_$arch.tar.gz"
        Write-Host "Downloading $url"
        New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
        $tmp = Join-Path $env:TEMP 'wireproxy.tar.gz'
        Invoke-WebRequest $url -OutFile $tmp -UseBasicParsing
        tar -xzf $tmp -C $BinDir
        Remove-Item $tmp -Force
        if (-not (Test-Path $Exe)) { throw 'bin\wireproxy.exe not found after extract' }
    }
}

# ---------------------------------------------------------------- NordVPN API
Write-Step 'Fetch NordLynx private key and server from NordVPN'
$auth = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("token:$Token"))
try {
    $cred = Invoke-RestMethod 'https://api.nordvpn.com/v1/users/services/credentials' -Headers @{ Authorization = $auth }
} catch { throw "NordVPN API rejected this token ($($_.Exception.Message)). Check that it is valid and not expired." }
$PrivateKey = $cred.nordlynx_private_key
if (-not $PrivateKey) { throw 'API response has no nordlynx_private_key.' }

$q = 'https://api.nordvpn.com/v1/servers/recommendations?filters[servers_technologies][identifier]=wireguard_udp&limit=1'
if ($CountryId) { $q += "&filters[country_id]=$CountryId" }
$srv = @(Invoke-RestMethod $q)
if (-not $srv -or -not $srv[0]) { throw "No server found (COUNTRY_ID=$CountryId)." }
$srv = $srv[0]
$tech = $srv.technologies | Where-Object identifier -eq 'wireguard_udp'
$PublicKey = ($tech.metadata | Where-Object name -eq 'public_key' | Select-Object -First 1).value
if (-not $PublicKey) { throw 'Server data has no WireGuard public key.' }
Write-Host "Server: $($srv.name)  ($($srv.hostname), $($srv.station))  load=$($srv.load)"

# ---------------------------------------------------------------- wireproxy.conf
Write-Step "Write $ConfPath"
Stop-Wireproxy @($SocksPort, $HttpPort)
@"
# $($srv.name) / $($srv.hostname) - generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')
[Interface]
PrivateKey = $PrivateKey
Address = 10.5.0.2/32
DNS = 103.86.96.100, 103.86.99.100

[Peer]
PublicKey = $PublicKey
Endpoint = $($srv.station):51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

[Socks5]
BindAddress = 127.0.0.1:$SocksPort

[http]
BindAddress = 127.0.0.1:$HttpPort
"@ | ForEach-Object { Write-Utf8 $ConfPath $_ }

# ---------------------------------------------------------------- Cursor settings
if (-not $SkipCursorSettings) {
    Write-Step "Update Cursor settings: $CursorSettings"
    $s = Read-JsonFile $CursorSettings
    Set-Prop $s 'http.proxy' "socks5://127.0.0.1:$SocksPort"
    Set-Prop $s 'http.proxySupport' 'override'
    Set-Prop $s 'cursor.general.disableHttp2' $true
    $termEnv = $s.'terminal.integrated.env.windows'
    if (-not $termEnv) { $termEnv = [pscustomobject]@{} }
    Set-Prop $termEnv 'HTTP_PROXY' "http://127.0.0.1:$HttpPort"
    Set-Prop $termEnv 'HTTPS_PROXY' "http://127.0.0.1:$HttpPort"
    Set-Prop $termEnv 'NODE_USE_ENV_PROXY' '1'
    Set-Prop $s 'terminal.integrated.env.windows' $termEnv
    Save-JsonFile $CursorSettings $s

    Write-Step "Update Cursor CLI config: $CliConfig"
    $c = Read-JsonFile $CliConfig
    if (-not $c.network) { Set-Prop $c 'network' ([pscustomobject]@{}) }
    Set-Prop $c.network 'useHttp1ForAgent' $true
    Save-JsonFile $CliConfig $c
}

# ---------------------------------------------------------------- autostart
Write-Step 'Register Task Scheduler autostart'
$psArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Runner`""
try {
    $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs -WorkingDirectory $RepoDir
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Created task `"$TaskName`""
} catch {
    Write-Warning "Could not create scheduled task ($($_.Exception.Message)); falling back to Startup-folder shortcut."
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) "$TaskName.lnk"
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $sc.TargetPath = 'powershell.exe'
    $sc.Arguments = $psArgs
    $sc.WorkingDirectory = $RepoDir
    $sc.WindowStyle = 7
    $sc.Save()
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Runner
}

# ---------------------------------------------------------------- verify
Write-Step 'Wait for wireproxy to start'
$ok = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    if (Get-NetTCPConnection -LocalPort $SocksPort -State Listen -ErrorAction SilentlyContinue) { $ok = $true; break }
}
if (-not $ok) {
    Write-Warning "wireproxy is not listening on 127.0.0.1:$SocksPort; see logs\wireproxy.err.log"
} else {
    try {
        $ip = Invoke-RestMethod 'https://api.ipify.org?format=json' -Proxy "http://127.0.0.1:$HttpPort" -TimeoutSec 15
        Write-Host "Exit IP via proxy: $($ip.ip)" -ForegroundColor Green
    } catch {
        Write-Warning "Proxy is listening, but the test request failed: $($_.Exception.Message)"
    }
}

Write-Host ''
Write-Host 'Done. Fully quit Cursor (not Reload Window) and reopen it.' -ForegroundColor Green
