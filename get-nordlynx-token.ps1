# Extract NordLynx WireGuard details from the active NordVPN connection.
# Requires: NordVPN connected with NordLynx + WireGuard tools (wg.exe on PATH).
#
#   powershell -ExecutionPolicy Bypass -File .\get-nordlynx-token.ps1
#   powershell -ExecutionPolicy Bypass -File .\get-nordlynx-token.ps1 -Country "South Korea"
#
# Optional -Country uses `nordvpn connect` first when the nordvpn CLI is available.
[CmdletBinding()]
param(
    [string]$Country,
    [string]$Interface = 'NordLynx'
)

$ErrorActionPreference = 'Stop'

function Assert-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "'$name' not found on PATH. Install WireGuard for Windows (includes wg.exe)."
    }
}

function Invoke-Wg {
    $out = & wg @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("wg {0} failed: {1}" -f ($args -join ' '), ($out | Out-String).Trim())
    }
    return $out
}

Assert-Command wg

$nordvpn = Get-Command nordvpn -ErrorAction SilentlyContinue
if ($Country) {
    if (-not $nordvpn) {
        throw "nordvpn CLI not found; connect NordVPN to '$Country' manually, then rerun without -Country."
    }
    Write-Host "==> nordvpn set technology NordLynx"
    & nordvpn set technology NordLynx | Out-Host
    Write-Host "==> nordvpn connect $Country"
    & nordvpn connect $Country | Out-Host
    Start-Sleep -Seconds 3
} elseif ($nordvpn) {
    $status = (& nordvpn status 2>&1 | Out-String)
    if ($status -notmatch 'Status:\s*Connected') {
        Write-Warning "NordVPN does not look connected. Connect with NordLynx first, or pass -Country `"South Korea`"."
    }
}

# Confirm the interface exists before dumping keys.
Invoke-Wg show $Interface | Out-Null

$conf = (Invoke-Wg showconf $Interface | Out-String)
if ($conf -notmatch '(?m)^\s*PrivateKey\s*=\s*(\S+)') {
    throw "No PrivateKey in wg showconf $Interface (try elevating PowerShell as Administrator)."
}
$privateKey = $Matches[1]

if ($conf -notmatch '(?ms)\[Peer\].*?^\s*PublicKey\s*=\s*(\S+)') {
    throw "No peer PublicKey in wg showconf $Interface."
}
$serverPublicKey = $Matches[1]

if ($conf -notmatch '(?ms)\[Peer\].*?^\s*Endpoint\s*=\s*(\S+)') {
    # Fallback: `wg show <iface> endpoints` → "<peer-pubkey>\t<ip>:<port>"
    $endpointLine = @(Invoke-Wg show $Interface endpoints | ForEach-Object { "$_" }) | Select-Object -First 1
    if ($endpointLine -match '((?:\d{1,3}\.){3}\d{1,3}:\d+)') {
        $endpoint = $Matches[1]
    } else {
        throw "No Endpoint in wg showconf / endpoints for $Interface."
    }
} else {
    $endpoint = $Matches[1]
}

$serverIp = ($endpoint -split ':')[0]

Write-Host ''
Write-Host "Interface : $Interface"
Write-Host "PrivateKey: $privateKey"
Write-Host "PublicKey : $serverPublicKey"
Write-Host "Endpoint  : $endpoint"
Write-Host "ServerIP  : $serverIp"
Write-Host ''

[pscustomobject]@{
    Interface  = $Interface
    PrivateKey = $privateKey
    PublicKey  = $serverPublicKey
    Endpoint   = $endpoint
    ServerIP   = $serverIp
}
