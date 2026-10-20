# ---- common.sh : funciones compartidas (Linux Config Tool) ----
# Este bloque se antepone a detect.sh / ip.sh / ad.sh. Las variables LCT_* las define la app.

LCT_STATE=/var/lib/linuxconfigtool
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

lct_has() { command -v "$1" >/dev/null 2>&1; }
lct_log() { echo "[$(date '+%H:%M:%S')] $*"; }
lct_fail() { echo "LCT_ERROR=$*"; exit 1; }

lct_os() {
  if [ -r /etc/os-release ]; then
    # Se lee en un subshell para no pisar variables del script (os-release define NAME, VERSION, ID...)
    eval "$(
      # shellcheck disable=SC1091
      . /etc/os-release
      printf 'LCT_OS_ID=%q\nLCT_OS_LIKE=%q\nLCT_OS_NAME=%q\nLCT_OS_VERSION=%q\nLCT_OS_CODENAME=%q\n' \
        "${ID:-unknown}" "${ID_LIKE:-}" "${PRETTY_NAME:-${ID:-unknown}}" "${VERSION_ID:-}" "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    )"
  elif [ -r /etc/redhat-release ]; then
    LCT_OS_ID=rhel; LCT_OS_LIKE=rhel; LCT_OS_NAME=$(cat /etc/redhat-release); LCT_OS_VERSION=$(sed -E 's/[^0-9]*([0-9]+(\.[0-9]+)?).*/\1/' /etc/redhat-release)
  else
    LCT_OS_ID=unknown; LCT_OS_LIKE=; LCT_OS_NAME=$(uname -sr); LCT_OS_VERSION=
  fi
}

lct_nm_running() {
  lct_has nmcli || return 1
  [ "$(nmcli -t -f RUNNING general 2>/dev/null)" = "running" ]
}

# Devuelve el backend de red que gestiona la interfaz $1:
# nm | netplan | wicked | ifupdown | ifcfg | unknown
lct_backend() {
  local ifc=$1 st
  if lct_nm_running; then
    st=$(nmcli -g GENERAL.STATE device show "$ifc" 2>/dev/null)
    case "$st" in
      *unmanaged*|"") : ;;
      *) echo nm; return ;;
    esac
  fi
  if lct_has netplan && ls /etc/netplan/*.yaml >/dev/null 2>&1; then echo netplan; return; fi
  if lct_has wicked && systemctl is-active --quiet wicked 2>/dev/null; then echo wicked; return; fi
  if [ -f /etc/network/interfaces ] && lct_has ifup; then echo ifupdown; return; fi
  if [ -d /etc/sysconfig/network-scripts ] && lct_has ifup; then echo ifcfg; return; fi
  if [ -d /etc/sysconfig/network ] && [ -x /sbin/ifup ]; then echo wicked; return; fi
  echo unknown
}

lct_prefix_to_mask() {
  local p=$1 m="" i oct
  for i in 1 2 3 4; do
    if [ "$p" -ge 8 ]; then oct=255; p=$((p-8))
    else oct=$((256 - (1 << (8 - p)))); [ "$p" -le 0 ] && oct=0; p=0; fi
    m="$m${m:+.}$oct"
  done
  echo "$m"
}

lct_require_root() {
  [ "$(id -u)" = 0 ] || lct_fail "Se necesitan permisos de root (sudo)."
}
# ---------------- proxy de internet ----------------
LCT_PROXY=${LCT_PROXY:-}
LCT_NOPROXY=${LCT_NOPROXY:-}
LCT_PX_BEGIN="# >>> linuxconfigtool proxy"
LCT_PX_END="# <<< linuxconfigtool proxy"

# "http://usr:clave@host:8080/" -> "host 8080"
lct_proxy_hostport() {
  local u=${1#*://}
  u=${u##*@}; u=${u%%/*}
  case "$u" in *:*) echo "${u%:*} ${u##*:}" ;; *) echo "$u 80" ;; esac
}
lct_proxy_mask() { echo "$1" | sed -E 's#(//)[^:/@]+:[^@]*@#\1***:***@#'; }

# Exporta el proxy solo para este script (instalacion de paquetes, pruebas)
lct_proxy_env() {
  [ -n "$LCT_PROXY" ] || return 0
  export http_proxy="$LCT_PROXY" https_proxy="$LCT_PROXY" ftp_proxy="$LCT_PROXY"
  export HTTP_PROXY="$LCT_PROXY" HTTPS_PROXY="$LCT_PROXY" FTP_PROXY="$LCT_PROXY"
  if [ -n "$LCT_NOPROXY" ]; then export no_proxy="$LCT_NOPROXY" NO_PROXY="$LCT_NOPROXY"; fi
}

# Comenta (#lct#) las lineas que coinciden con la regex (minusculas) y quita el bloque gestionado
# $3 (opcional): solo dentro de esa seccion ini, ej "[main]"
lct_px_strip() {
  local f=$1 re=$2 sec=${3:-} tmp
  [ -f "$f" ] || return 0
  tmp=$(mktemp)
  awk -v b="$LCT_PX_BEGIN" -v e="$LCT_PX_END" -v re="$re" -v sec="$sec" '
    BEGIN { insec = (sec == "") }
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    skip { next }
    sec != "" && /^[[:space:]]*\[/ { t = $0; gsub(/[[:space:]]/, "", t); insec = (t == sec) }
    insec && re != "" && tolower($0) ~ re { print "#lct# " $0; next }
    { print }' "$f" > "$tmp" && cat "$tmp" > "$f"
  rm -f "$tmp"
}
lct_px_unstrip() {
  local f=$1
  [ -f "$f" ] || return 0
  lct_px_strip "$f" ""
  sed -i 's/^#lct# //' "$f"
}

# Configura el proxy de forma permanente en el servidor
lct_proxy_apply() {
  local url=$1 np=$2 st=$LCT_STATE/proxy f host port tmp h user="" pass="" auth done_list=""
  [ -n "$url" ] || { echo "Falta la URL del proxy"; return 1; }
  read -r host port <<<"$(lct_proxy_hostport "$url")"
  local us npx
  us=$(printf '%s' "$url" | sed 's/[&|\\]/\\&/g'); npx=$(printf '%s' "$np" | sed 's/[&|\\]/\\&/g')
  mkdir -p "$st"; chmod 700 "$st"
  # 1) Variables de entorno para todo el sistema
  [ -f /etc/environment ] || touch /etc/environment
  [ -f "$st/environment.orig" ] || cp -p /etc/environment "$st/environment.orig"
  lct_px_strip /etc/environment '^[[:space:]]*(export[[:space:]]+)?(http|https|ftp|no)_proxy[[:space:]]*='
  {
    echo "$LCT_PX_BEGIN"
    for v in http_proxy https_proxy ftp_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY; do echo "$v=\"$url\""; done
    if [ -n "$np" ]; then echo "no_proxy=\"$np\""; echo "NO_PROXY=\"$np\""; fi
    echo "$LCT_PX_END"
  } >> /etc/environment
  done_list="/etc/environment"
  # 2) sudo conserva las variables del proxy
  if [ -d /etc/sudoers.d ] && lct_has visudo; then
    tmp=$(mktemp)
    echo 'Defaults env_keep += "http_proxy https_proxy ftp_proxy no_proxy HTTP_PROXY HTTPS_PROXY FTP_PROXY NO_PROXY"' > "$tmp"
    if visudo -cf "$tmp" >/dev/null 2>&1; then install -m 0440 -o root -g root "$tmp" /etc/sudoers.d/lct-proxy; done_list="$done_list, sudo"; fi
    rm -f "$tmp"
  fi
  # 3) apt
  if [ -d /etc/apt/apt.conf.d ]; then
    {
      echo "// Linux Config Tool"
      echo "Acquire::http::Proxy \"$url\";"
      echo "Acquire::https::Proxy \"$url\";"
      for h in $(echo "$np" | tr ',' ' '); do
        case "$h" in .*|*/*|\**|localhost|127.*|"") ;; *) echo "Acquire::http::Proxy::$h \"DIRECT\";"; echo "Acquire::https::Proxy::$h \"DIRECT\";" ;; esac
      done
    } > /etc/apt/apt.conf.d/95lct-proxy
    done_list="$done_list, apt"
  fi
  # 4) dnf / yum
  for f in /etc/dnf/dnf.conf /etc/yum.conf; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    grep -q '^\[main\]' "$f" || continue
    lct_px_strip "$f" '^[[:space:]]*proxy[[:space:]]*=' '[main]'
    sed -i "/^\[main\]/a $LCT_PX_BEGIN\nproxy=$us\n$LCT_PX_END" "$f"
    done_list="$done_list, $(basename "$f")"
  done
  # 5) SUSE
  if [ -f /etc/sysconfig/proxy ]; then
    [ -f "$st/sysconfig-proxy.orig" ] || cp -p /etc/sysconfig/proxy "$st/sysconfig-proxy.orig"
    sed -i -E "s|^PROXY_ENABLED=.*|PROXY_ENABLED=\"yes\"|; s|^HTTP_PROXY=.*|HTTP_PROXY=\"$us\"|; s|^HTTPS_PROXY=.*|HTTPS_PROXY=\"$us\"|; s|^FTP_PROXY=.*|FTP_PROXY=\"$us\"|; s|^NO_PROXY=.*|NO_PROXY=\"$npx\"|" /etc/sysconfig/proxy
    done_list="$done_list, /etc/sysconfig/proxy"
  fi
  # 6) Red Hat Subscription Manager (solo si registra contra Red Hat, no Satellite)
  if lct_has subscription-manager && grep -qE '^[[:space:]]*hostname[[:space:]]*=[[:space:]]*subscription\.rhsm\.redhat\.com' /etc/rhsm/rhsm.conf 2>/dev/null; then
    auth=${url#*://}; auth=${auth%%/*}
    case "$auth" in *@*) auth=${auth%@*}; user=${auth%%:*}; pass=${auth#*:} ;; esac
    if subscription-manager config --server.proxy_hostname="$host" --server.proxy_port="$port" \
         ${user:+--server.proxy_user="$user"} ${pass:+--server.proxy_password="$pass"} >/dev/null 2>&1; then
      touch "$st/rhsm"; done_list="$done_list, subscription-manager"
    fi
  fi
  # 7) snap
  if lct_has snap && snap version >/dev/null 2>&1; then
    snap set system proxy.http="$url" proxy.https="$url" >/dev/null 2>&1 && touch "$st/snap" && done_list="$done_list, snap"
  fi
  echo "$url" > "$st/current"
  echo "Proxy $(lct_proxy_mask "$url") configurado en: $done_list"
}

lct_proxy_remove() {
  local st=$LCT_STATE/proxy f
  lct_px_unstrip /etc/environment
  rm -f /etc/sudoers.d/lct-proxy /etc/apt/apt.conf.d/95lct-proxy
  for f in /etc/dnf/dnf.conf /etc/yum.conf; do [ -f "$f" ] && [ ! -L "$f" ] && lct_px_unstrip "$f"; done
  if [ -f "$st/sysconfig-proxy.orig" ]; then cp -p "$st/sysconfig-proxy.orig" /etc/sysconfig/proxy
  elif [ -f /etc/sysconfig/proxy ]; then sed -i 's/^PROXY_ENABLED=.*/PROXY_ENABLED="no"/' /etc/sysconfig/proxy; fi
  if [ -f "$st/rhsm" ]; then subscription-manager config --server.proxy_hostname="" --server.proxy_port="" --server.proxy_user="" --server.proxy_password="" >/dev/null 2>&1; fi
  if [ -f "$st/snap" ]; then snap unset system proxy.http proxy.https >/dev/null 2>&1; fi
  rm -rf "$st"
  echo "Proxy quitado del servidor."
}
# ---- fin common.sh ----
