# Compila dist\LinuxConfigTool.exe en Windows usando el compilador C# que trae .NET Framework 4.x.
# Uso:  powershell -ExecutionPolicy Bypass -File build.ps1
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'No se encontro csc.exe de .NET Framework 4.x' }

# 1) Helper SSH
& $csc /nologo /target:library /optimize+ /r:src\lib\Renci.SshNet.dll /out:src\lib\LctSsh.dll src\LctSsh.cs
if ($LASTEXITCODE -ne 0) { throw 'Fallo la compilacion de LctSsh.dll' }

# 2) Id de build
$files = Get-ChildItem src -Recurse -File | Where-Object { $_.Extension -in '.ps1','.dll','.sh','.html','.js','.css','.cs' } | Sort-Object FullName
$sha = [Security.Cryptography.SHA256]::Create()
$all = New-Object IO.MemoryStream
foreach ($f in $files) { $b = [IO.File]::ReadAllBytes($f.FullName); $all.Write($b, 0, $b.Length) }
$build = ([BitConverter]::ToString($sha.ComputeHash($all.ToArray())) -replace '-', '').Substring(0, 12).ToLower()
$tmp = Join-Path $env:TEMP ('lct-build-' + $build)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
[IO.File]::WriteAllText((Join-Path $tmp 'buildid'), $build)

# 3) Recursos embebidos
$srcRoot = (Resolve-Path src).Path
$res = @("/resource:$tmp\buildid,lct/buildid")
foreach ($f in $files) {
    $rel = $f.FullName.Substring($srcRoot.Length + 1).Replace('\', '/')
    $res += "/resource:$($f.FullName),lct/$rel"
}
New-Item -ItemType Directory -Force -Path dist | Out-Null
& $csc /nologo /target:exe /platform:anycpu /optimize+ /win32icon:launcher\app.ico @res /out:dist\LinuxConfigTool.exe launcher\Launcher.cs
if ($LASTEXITCODE -ne 0) { throw 'Fallo la compilacion del .exe' }
Remove-Item $tmp -Recurse -Force
Write-Host "OK -> dist\LinuxConfigTool.exe (build $build)" -ForegroundColor Green
