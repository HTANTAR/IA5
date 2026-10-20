<#
  Linux Config Tool
  -----------------
  Backend local en PowerShell: levanta una interfaz web en http://localhost y se conecta por SSH
  (usuario + contrasena) a servidores Linux para:
    * configurar IP fija (RHEL/Rocky/Alma/Oracle/CentOS, Ubuntu, Debian, SUSE...) con rollback automatico
    * dar acceso por grupos de seguridad de Active Directory (realmd/sssd + sudo)
    * generar los comandos para ejecutar a mano en la consola si el servidor no tiene red

  Uso:  powershell -ExecutionPolicy Bypass -File app.ps1 [-Port 8765] [-DataDir carpeta] [-NoBrowser]
  Compatible con Windows PowerShell 5.1 (viene con Windows 10/11 y Server 2016+).
#>
param(
    [int]$Port = 0,
    [string]$DataDir = '',
    [string]$AppRoot = '',
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
try { $Host.UI.RawUI.WindowTitle = "Linux Config Tool $Version" } catch { }

# ---------- carpeta de datos (portable: junto al .exe si se puede escribir) ----------
if (-not $DataDir) { $DataDir = $AppRoot }
try {
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Force -Path $DataDir | Out-Null }
    $probe = Join-Path $DataDir '.lct-write-test'
    [IO.File]::WriteAllText($probe, 'x')
    Remove-Item $probe -Force
} catch {
    $DataDir = Join-Path $env:LOCALAPPDATA 'LinuxConfigTool'
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
}
$StoreFile = Join-Path $DataDir 'LinuxConfigTool-datos.json'
$LogFile   = Join-Path $DataDir 'LinuxConfigTool-historial.log'

function Write-AppLog([string]$text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text
    try { [IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8) } catch { }
    Write-Host $line -ForegroundColor DarkGray
}

# ---------- librerias SSH ----------
$sshDll = Join-Path $AppRoot 'lib\Renci.SshNet.dll'
$lctDll = Join-Path $AppRoot 'lib\LctSsh.dll'
Add-Type -Path $sshDll
if (Test-Path $lctDll) {
    Add-Type -Path $lctDll
} else {
    # Modo desarrollo: compila el helper desde el codigo fuente.
    $src = [IO.File]::ReadAllText((Join-Path $AppRoot 'LctSsh.cs'))
    Add-Type -TypeDefinition $src -ReferencedAssemblies @($sshDll, 'System.dll') -Language CSharp
}

# ---------- servidor web local ----------
$Token = [Guid]::NewGuid().ToString('N')
$listener = $null
$candidates = if ($Port -gt 0) { @($Port) } else { 8765..8799 }
foreach ($p in $candidates) {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/")
    try { $l.Start(); $listener = $l; $Port = $p; break } catch { try { $l.Close() } catch { } }
}
if (-not $listener) {
    Write-Host 'No pude abrir ningun puerto local entre 8765 y 8799.' -ForegroundColor Red
    Read-Host 'Enter para salir'
    exit 1
}
$Url = "http://localhost:$Port/"

$mime = @{
    '.html' = 'text/html; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8';  '.sh' = 'text/plain; charset=utf-8'
    '.svg'  = 'image/svg+xml';            '.ico' = 'image/x-icon'; '.png' = 'image/png'
}

function Send-Bytes($ctx, [byte[]]$bytes, [string]$type, [int]$code) {
    $res = $ctx.Response
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.Headers.Add('Cache-Control', 'no-store')
    $res.Headers.Add('X-Content-Type-Options', 'nosniff')
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}
function Send-Text($ctx, [string]$text, [string]$type, [int]$code) {
    Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes($text)) $type $code
}
function Send-Json($ctx, $obj, [int]$code) {
    if (-not $code) { $code = 200 }
    $json = ConvertTo-Json -InputObject $obj -Depth 6 -Compress
    Send-Text $ctx $json 'application/json; charset=utf-8' $code
}
function Read-Body($ctx) {
    $sr = New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd()
    $sr.Close()
    return $txt
}
function Get-Prop($obj, [string]$name, $default) {
    if ($null -ne $obj -and ($obj.PSObject.Properties.Name -contains $name) -and $null -ne $obj.$name) { return $obj.$name }
    return $default
}

function Invoke-Api($ctx, [string]$path, [string]$method) {
    if ($ctx.Request.Headers['X-LCT-Token'] -ne $Token) {
        Send-Json $ctx @{ error = 'Token invalido. Recargue la pagina.' } 403
        return
    }
    switch ($path) {
        '/api/info' {
            Send-Json $ctx @{ version = $Version; dataDir = $DataDir; logFile = $LogFile; user = $env:USERNAME } 200
        }
        '/api/run' {
            $b = Read-Body $ctx | ConvertFrom-Json
            $h = [string](Get-Prop $b 'host' '')
            $port = [int](Get-Prop $b 'port' 22)
            $user = [string](Get-Prop $b 'user' '')
            $pass = [string](Get-Prop $b 'password' '')
            $scr = [string](Get-Prop $b 'script' '')
            $asRoot = [bool](Get-Prop $b 'asRoot' $true)
            $timeout = [int](Get-Prop $b 'timeout' 180)
            $label = [string](Get-Prop $b 'label' 'comando')
            if (-not $h -or -not $user) { Send-Json $ctx @{ Ok = $false; ErrorKind = 'input'; ErrorMessage = 'Faltan servidor o usuario.' } 200; return }
            Write-AppLog ("{0}@{1}:{2}  ->  {3}" -f $user, $h, $port, $label)
            $r = [Lct.Ssh]::Run($h, $port, $user, $pass, $scr, $asRoot, $timeout)
            if ($r.Ok) { Write-AppLog ("   resultado: codigo {0}" -f $r.ExitCode) } else { Write-AppLog ("   ERROR: {0}" -f $r.ErrorMessage) }
            Send-Json $ctx $r 200
        }
        '/api/probe' {
            $b = Read-Body $ctx | ConvertFrom-Json
            $ok = [Lct.Ssh]::Probe([string](Get-Prop $b 'host' ''), [int](Get-Prop $b 'port' 22), [int](Get-Prop $b 'timeoutMs' 2000))
            Send-Json $ctx @{ open = $ok } 200
        }
        '/api/pcproxy' {
            Send-Json $ctx ([Lct.NetDiag]::GetPcProxy()) 200
        }
        '/api/proxytest' {
            $b = Read-Body $ctx | ConvertFrom-Json
            $tg = @()
            foreach ($t in @(Get-Prop $b 'targets' @())) { if ($t) { $tg += [string]$t } }
            $px = [string](Get-Prop $b 'proxy' '')
            Write-AppLog ("Prueba de proxy desde esta PC: {0}" -f ($px -replace '//[^@/]+@', '//***@'))
            $r = [Lct.NetDiag]::Test($px, [string[]]$tg, [int](Get-Prop $b 'timeoutMs' 8000))
            Send-Json $ctx $r 200
        }
        '/api/store' {
            if ($method -eq 'POST') {
                $txt = Read-Body $ctx
                try { $null = $txt | ConvertFrom-Json } catch { Send-Json $ctx @{ error = 'JSON invalido' } 400; return }
                [IO.File]::WriteAllText($StoreFile, $txt, (New-Object Text.UTF8Encoding($false)))
                Send-Json $ctx @{ saved = $true } 200
            } else {
                $txt = '{}'
                if (Test-Path $StoreFile) { $txt = [IO.File]::ReadAllText($StoreFile) }
                Send-Text $ctx $txt 'application/json; charset=utf-8' 200
            }
        }
        '/api/shutdown' {
            Send-Json $ctx @{ bye = $true } 200
            $script:Running = $false
        }
        default { Send-Json $ctx @{ error = 'No existe' } 404 }
    }
}

function Invoke-Static($ctx, [string]$path) {
    if ($path -eq '/' -or $path -eq '') { $path = '/index.html' }
    if ($path -match '^/scripts/([a-z]+\.sh)$') {
        $file = Join-Path (Join-Path $AppRoot 'scripts') $Matches[1]
    } elseif ($path -match '^/([A-Za-z0-9_\-]+\.(html|js|css|svg|ico|png))$') {
        $file = Join-Path (Join-Path $AppRoot 'www') $Matches[1]
    } else {
        Send-Text $ctx 'No encontrado' 'text/plain' 404; return
    }
    if (-not (Test-Path $file)) { Send-Text $ctx 'No encontrado' 'text/plain' 404; return }
    $ext = [IO.Path]::GetExtension($file).ToLower()
    $type = $mime[$ext]; if (-not $type) { $type = 'application/octet-stream' }
    if ($ext -eq '.html') {
        $html = [IO.File]::ReadAllText($file).Replace('__LCT_TOKEN__', $Token).Replace('__LCT_VERSION__', $Version)
        Send-Text $ctx $html $type 200
    } else {
        Send-Bytes $ctx ([IO.File]::ReadAllBytes($file)) $type 200
    }
}

# ---------- arranque ----------
Write-Host ''
Write-Host '  ======================================================' -ForegroundColor Cyan
Write-Host "    Linux Config Tool $Version" -ForegroundColor Cyan
Write-Host '  ======================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host "  Interfaz abierta en:  $Url" -ForegroundColor Green
Write-Host "  Datos e historial en: $DataDir"
Write-Host ''
Write-Host '  NO cierre esta ventana mientras use la herramienta.' -ForegroundColor Yellow
Write-Host '  Para salir: boton "Salir" en la pagina, o cierre esta ventana.' -ForegroundColor Yellow
Write-Host ''
if (-not $NoBrowser) { try { Start-Process $Url } catch { } }

$script:Running = $true
try {
    while ($script:Running -and $listener.IsListening) {
        $ar = $listener.BeginGetContext($null, $null)
        while (-not $ar.AsyncWaitHandle.WaitOne(500)) { }
        $ctx = $listener.EndGetContext($ar)
        $path = $ctx.Request.Url.AbsolutePath
        try {
            if ($path.StartsWith('/api/')) { Invoke-Api $ctx $path $ctx.Request.HttpMethod }
            else { Invoke-Static $ctx $path }
        } catch {
            Write-Host ("Error atendiendo {0}: {1}" -f $path, $_.Exception.Message) -ForegroundColor Red
            try { Send-Json $ctx @{ Ok = $false; ErrorKind = 'app'; ErrorMessage = $_.Exception.Message } 500 } catch { }
        }
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    Write-Host 'Linux Config Tool cerrado.'
}
