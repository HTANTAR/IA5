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
    # shellcheck disable=SC1091
    . /etc/os-release
    LCT_OS_ID=${ID:-unknown}
    LCT_OS_LIKE=${ID_LIKE:-}
    LCT_OS_NAME=${PRETTY_NAME:-$ID}
    LCT_OS_VERSION=${VERSION_ID:-}
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
# ---- fin common.sh ----
