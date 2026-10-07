$ErrorActionPreference = 'Stop'
$RepoDir = $PSScriptRoot
$Conf = Join-Path $RepoDir 'wireproxy.conf'
$LogDir = Join-Path $RepoDir 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$exe = Join-Path $RepoDir 'bin\wireproxy.exe'
if (-not (Test-Path $exe)) {
    $cmd = Get-Command wireproxy.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'wireproxy.exe not found. Run setup.ps1 first.' }
    $exe = $cmd.Source
}

$port = (Select-String -Path $Conf -Pattern 'BindAddress\s*=\s*[\d.]+:(\d+)' | Select-Object -First 1).Matches[0].Groups[1].Value
if ($port -and (Get-NetTCPConnection -LocalPort ([int]$port) -State Listen -ErrorAction SilentlyContinue)) {
    exit 0
}

Start-Process -FilePath $exe -ArgumentList "-c `"$Conf`"" -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $LogDir 'wireproxy.out.log') `
    -RedirectStandardError (Join-Path $LogDir 'wireproxy.err.log')
