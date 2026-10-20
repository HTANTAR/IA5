# ---- proxy.sh : probar / configurar / quitar el proxy de internet del servidor ----
# LCT_ACTION: test | apply | remove
ACTION=${LCT_ACTION:-test}
lct_os

# Prueba una URL. Imprime "codigo|error". Sin proxy: $2 vacio.
px_probe() {
  local url=$1 px=$2 code err ef
  ef=$(mktemp)
  if lct_has curl; then
    if [ -n "$px" ]; then code=$(curl -sS -m 12 -o /dev/null -w '%{http_code}' -x "$px" "$url" 2>"$ef")
    else code=$(curl -sS -m 12 -o /dev/null -w '%{http_code}' --noproxy '*' "$url" 2>"$ef"); fi
  elif lct_has wget; then
    if [ -n "$px" ]; then code=$(wget -S --spider -T 12 -t 1 -e use_proxy=on -e http_proxy="$px" -e https_proxy="$px" "$url" 2>&1 | tee "$ef" | awk '/HTTP\//{c=$2} END{print c+0}')
    else code=$(wget -S --spider -T 12 -t 1 --no-proxy "$url" 2>&1 | tee "$ef" | awk '/HTTP\//{c=$2} END{print c+0}'); fi
  else
    echo "000|ni curl ni wget estan instalados"; rm -f "$ef"; return
  fi
  err=$(grep -iE 'curl:|error|fail|unable|refused|timed out|resolve' "$ef" | head -n1 | tr '|' ' ' | cut -c1-160)
  rm -f "$ef"
  [ -z "$code" ] && code=000
  echo "${code}|${err}"
}

px_targets() {
  local u list=""
  # Repositorio real configurado en el servidor
  if [ -d /etc/apt ]; then
    u=$( { grep -hsE '^[[:space:]]*deb[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d/*.list | awk '{for(i=2;i<=NF;i++) if($i ~ /^https?:\/\//){print $i; exit}}'
           grep -hsE '^[[:space:]]*URIs:' /etc/apt/sources.list.d/*.sources | awk '{print $2}'; } | head -n1)
    [ -n "$u" ] && list="$list $u"
  fi
  if [ -d /etc/yum.repos.d ]; then
    u=$(grep -hsE '^[[:space:]]*(baseurl|mirrorlist|metalink)[[:space:]]*=[[:space:]]*https?://' /etc/yum.repos.d/*.repo | head -n1 | sed -E 's/^[^=]*=[[:space:]]*//')
    [ -n "$u" ] && list="$list $u"
  fi
  if [ -d /etc/zypp/repos.d ]; then
    u=$(grep -hsE '^[[:space:]]*baseurl[[:space:]]*=[[:space:]]*https?://' /etc/zypp/repos.d/*.repo | head -n1 | sed -E 's/^[^=]*=[[:space:]]*//')
    [ -n "$u" ] && list="$list $u"
  fi
  case "$LCT_OS_ID" in
    ubuntu) list="$list http://archive.ubuntu.com/ubuntu/" ;;
    debian) list="$list http://deb.debian.org/debian/" ;;
    rhel) list="$list https://cdn.redhat.com/" ;;
    rocky) list="$list https://dl.rockylinux.org/" ;;
    almalinux) list="$list https://repo.almalinux.org/" ;;
    ol) list="$list https://yum.oracle.com/" ;;
    centos) list="$list https://mirror.stream.centos.org/" ;;
    fedora) list="$list https://mirrors.fedoraproject.org/" ;;
    sles|sled) list="$list https://updates.suse.com/" ;;
    opensuse*) list="$list https://download.opensuse.org/" ;;
  esac
  # Reducir a esquema://host/ (las variables $releasever etc. no importan para ver si llega) y sin repetidos
  for u in $list; do echo "$u" | sed -E 's#^(https?://[^/]+).*#\1/#'; done | awk '!seen[$0]++' | head -n 3
}

case "$ACTION" in
  test)
    [ -n "$LCT_PROXY" ] || lct_fail "Escriba la direccion del proxy."
    read -r phost pport <<<"$(lct_proxy_hostport "$LCT_PROXY")"
    echo "PX_HOST=$phost"
    if getent hosts "$phost" >/dev/null 2>&1 || echo "$phost" | grep -qE '^[0-9.]+$'; then
      echo "PX_DNS=ok"
    else
      echo "PX_DNS=fail"
    fi
    if timeout 6 bash -c "exec 3<>/dev/tcp/$phost/$pport" 2>/dev/null; then echo "PX_PORT=ok"; else echo "PX_PORT=fail"; fi
    for t in $(px_targets); do
      d=$(px_probe "$t" "")
      p=$(px_probe "$t" "$LCT_PROXY")
      echo "TEST|$t|$d|$p"
    done
    echo "LCT_OK=1"
    ;;
  apply)
    lct_require_root
    [ -n "$LCT_PROXY" ] || lct_fail "Escriba la direccion del proxy."
    lct_proxy_apply "$LCT_PROXY" "$LCT_NOPROXY" || lct_fail "No se pudo configurar el proxy."
    echo "LCT_NOTE=Las sesiones nuevas (SSH, sudo, apt/dnf) ya usan el proxy. Las que estaban abiertas tienen que volver a entrar."
    echo "LCT_OK=1"
    ;;
  remove)
    lct_require_root
    lct_proxy_remove
    echo "LCT_OK=1"
    ;;
  *)
    lct_fail "Accion desconocida: $ACTION"
    ;;
esac
