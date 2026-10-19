#!/bin/bash
# Compila dist/LinuxConfigTool.exe desde Linux usando Mono (apt install mono-devel).
# En Windows usar build.ps1 (no necesita instalar nada).
set -euo pipefail
cd "$(dirname "$0")"

command -v mcs >/dev/null || { echo "Falta mcs (apt install mono-devel)"; exit 1; }

# 1) Helper SSH precompilado (evita compilar C# en la PC del usuario)
mcs -nologo -langversion:5 -sdk:4.5 -target:library -optimize+ \
    -r:src/lib/Renci.SshNet.dll -out:src/lib/LctSsh.dll src/LctSsh.cs

# 2) Id de build = hash del contenido (cada version se extrae en su propia carpeta)
BUILD=$(find src -type f ! -name '*.log' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
echo -n "$BUILD" > "$TMP/buildid"

RES=(-resource:"$TMP/buildid",lct/buildid)
while IFS= read -r -d '' f; do
  rel=${f#src/}
  RES+=(-resource:"$f",lct/"$rel")
done < <(find src -type f \( -name '*.ps1' -o -name '*.dll' -o -name '*.sh' -o -name '*.html' -o -name '*.js' -o -name '*.css' -o -name '*.cs' \) -print0 | sort -z)

mkdir -p dist
mcs -nologo -langversion:5 -sdk:4.5 -target:exe -platform:anycpu -optimize+ \
    -win32icon:launcher/app.ico "${RES[@]}" -out:dist/LinuxConfigTool.exe launcher/Launcher.cs

echo "OK -> dist/LinuxConfigTool.exe (build $BUILD)"
sha256sum dist/LinuxConfigTool.exe
