# ---- detect.sh : inventario del servidor (solo lectura, no cambia nada) ----
lct_os
echo "OS_ID=$LCT_OS_ID"
echo "OS_LIKE=$LCT_OS_LIKE"
echo "OS_NAME=$LCT_OS_NAME"
echo "OS_VERSION=$LCT_OS_VERSION"
echo "HOSTNAME=$(hostname 2>/dev/null)"
echo "FQDN=$(hostname -f 2>/dev/null)"
echo "IS_ROOT=$([ "$(id -u)" = 0 ] && echo yes || echo no)"
echo "NM=$(lct_nm_running && echo yes || echo no)"

if lct_has ip; then
  set -- $(ip -4 route show default 2>/dev/null | head -n1)
  gw=""; gwdev=""
  while [ $# -gt 0 ]; do
    case "$1" in via) gw=$2; shift ;; dev) gwdev=$2; shift ;; esac
    shift
  done
  echo "GW=$gw"
  echo "GW_DEV=$gwdev"
  for ifc in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//'); do
    case "$ifc" in lo|veth*|docker*|br-*|virbr*-nic|cali*|flannel*|cni*|tun*) continue ;; esac
    state=$(cat "/sys/class/net/$ifc/operstate" 2>/dev/null)
    mac=$(cat "/sys/class/net/$ifc/address" 2>/dev/null)
    addrs=$(ip -o -4 addr show dev "$ifc" 2>/dev/null | awk '{print $4}' | paste -sd, -)
    if ip -o -4 addr show dev "$ifc" 2>/dev/null | grep -q dynamic; then method=dhcp
    elif [ -n "$addrs" ]; then method=static
    else method=none; fi
    be=$(lct_backend "$ifc")
    conn=""
    if [ "$be" = nm ]; then
      conn=$(nmcli -g GENERAL.CONNECTION device show "$ifc" 2>/dev/null)
      uuid=$(nmcli -g GENERAL.CON-UUID device show "$ifc" 2>/dev/null)
      if [ -n "$uuid" ]; then
        m=$(nmcli -g ipv4.method connection show "$uuid" 2>/dev/null)
        case "$m" in auto) method=dhcp ;; manual) method=static ;; esac
      fi
    fi
    echo "IF|$ifc|$state|$mac|$addrs|$method|$be|$conn"
  done
fi

dns=$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | paste -sd' ' -)
if echo "$dns" | grep -q '127.0.0.53' && lct_has resolvectl; then
  real=$(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1{print $2}' | tr ' ' '\n' | grep -v '^$' | sort -u | paste -sd' ' -)
  [ -n "$real" ] && dns=$real
fi
echo "DNS=$dns"
echo "SEARCH=$(awk '/^search/{$1="";print}' /etc/resolv.conf 2>/dev/null | sed 's/^ //')"

# ---- Active Directory / SSSD ----
echo "HAS_REALM=$(lct_has realm && echo yes || echo no)"
echo "HAS_SSSD=$( (lct_has sssd || [ -x /usr/sbin/sssd ]) && echo yes || echo no)"
if lct_has realm; then
  realm list 2>/dev/null | awk '
    /^[^ \t]/ { if (done) exit; name=$1; next }
    /configured:/ { if ($2 != "no") { joined=1 } }
    /login-policy:/ { pol=$2 }
    /permitted-groups:/ { sub(/^[ \t]*permitted-groups:[ \t]*/, ""); grp=$0 }
    /permitted-logins:/ { sub(/^[ \t]*permitted-logins:[ \t]*/, ""); lg=$0 }
    /^[ \t]*$/ { if (joined) done=1 }
    END {
      if (joined) { print "REALM_JOINED=yes"; print "REALM_DOMAIN=" name; print "REALM_POLICY=" pol; print "REALM_GROUPS=" grp; print "REALM_LOGINS=" lg }
      else print "REALM_JOINED=no"
    }'
else
  echo "REALM_JOINED=no"
fi
if [ -r /etc/sssd/sssd.conf ]; then
  idmap=$(awk -F= 'tolower($1) ~ /^[ \t]*ldap_id_mapping[ \t]*$/ {gsub(/[ \t]/,"",$2); print tolower($2)}' /etc/sssd/sssd.conf | tail -n1)
  fqn=$(awk -F= 'tolower($1) ~ /^[ \t]*use_fully_qualified_names[ \t]*$/ {gsub(/[ \t]/,"",$2); print tolower($2)}' /etc/sssd/sssd.conf | tail -n1)
  echo "SSSD_IDMAP=${idmap:-true}"
  echo "SSSD_FQN=${fqn:-false}"
  echo "SSSD_ACCESS=$(awk -F= 'tolower($1) ~ /^[ \t]*access_provider[ \t]*$/ {gsub(/[ \t]/,"",$2); print $2}' /etc/sssd/sssd.conf | tail -n1)"
  echo "SSSD_SIMPLE_GROUPS=$(awk -F= 'tolower($1) ~ /^[ \t]*simple_allow_groups[ \t]*$/ {sub(/^[ \t]*/,"",$2); print $2}' /etc/sssd/sssd.conf | tail -n1)"
elif [ -e /etc/sssd/sssd.conf ]; then
  echo "SSSD_IDMAP=unknown"
fi
# Metodo de integracion con AD (realm / sssd manual / Centrify-Delinea / winbind)
ad_method=none; ad_domain=""
if lct_has realm && realm list --name-only 2>/dev/null | grep -q .; then
  ad_method=realm; ad_domain=$(realm list --name-only 2>/dev/null | head -n1)
elif [ -r /etc/sssd/sssd.conf ] && grep -qiE '^[[:space:]]*id_provider[[:space:]]*=[[:space:]]*(ad|ldap|ipa)' /etc/sssd/sssd.conf; then
  ad_method=sssd; ad_domain=$(awk '/^[[:space:]]*\[domain\//{s=$0; sub(/.*\[domain\//,"",s); sub(/\].*/,"",s); print s; exit}' /etc/sssd/sssd.conf)
elif lct_has adinfo && adinfo -d >/dev/null 2>&1; then
  ad_method=centrify; ad_domain=$(adinfo -d 2>/dev/null)
elif lct_has wbinfo && wbinfo -t >/dev/null 2>&1; then
  ad_method=winbind; ad_domain=$(wbinfo --own-domain 2>/dev/null)
fi
echo "AD_METHOD=$ad_method"
echo "AD_DOMAIN=$ad_domain"
miss=""
lct_has realm || miss="$miss realmd"
{ lct_has sssd || [ -x /usr/sbin/sssd ]; } || miss="$miss sssd"
lct_has adcli || miss="$miss adcli"
echo "AD_PKGS_MISSING=${miss# }"
# Proxy configurado actualmente
px=""
if [ -d /etc/apt ]; then
  px=$(grep -hsE '^[[:space:]]*Acquire::https?::Proxy[[:space:]]+"[^"]+"' /etc/apt/apt.conf /etc/apt/apt.conf.d/* | grep -v DIRECT | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
fi
[ -z "$px" ] && px=$(awk -F= '/^[[:space:]]*proxy[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); print; exit}' /etc/dnf/dnf.conf /etc/yum.conf 2>/dev/null)
[ -z "$px" ] && grep -qs '^PROXY_ENABLED="yes"' /etc/sysconfig/proxy && px=$(sed -nE 's/^HTTP_PROXY="([^"]*)".*/\1/p' /etc/sysconfig/proxy | head -n1)
[ -z "$px" ] && px=$(grep -hsiE '^[[:space:]]*(export[[:space:]]+)?https?_proxy[[:space:]]*=' /etc/environment /etc/profile.d/*.sh | head -n1 | sed -E 's/^[^=]*=[[:space:]]*//; s/^["'"'"']//; s/["'"'"';]*$//')
echo "PROXY_CURRENT=$(lct_proxy_mask "$px")"
echo "PROXY_NO=$(grep -hsiE '^[[:space:]]*(export[[:space:]]+)?no_proxy[[:space:]]*=' /etc/environment /etc/profile.d/*.sh | head -n1 | sed -E 's/^[^=]*=[[:space:]]*//; s/^["'"'"']//; s/["'"'"';]*$//')"
for f in /etc/sudoers.d/*; do
  [ -f "$f" ] || continue
  grep -E '^[[:space:]]*%' "$f" 2>/dev/null | while IFS= read -r line; do echo "SUDO|$f|$line"; done
done
if lct_has timedatectl; then
  echo "TIMESYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || timedatectl 2>/dev/null | awk -F': ' '/synchronized/{print $2}')"
fi
echo "LCT_DETECT_OK=1"
