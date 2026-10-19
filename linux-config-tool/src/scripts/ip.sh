# ---- ip.sh : configurar IP fija con backup y rollback automatico ----
# Fases:  stage   -> backup + escribe la configuracion nueva + lanza "run" en segundo plano
#         run     -> activa la configuracion; si no llega la confirmacion en LCT_ROLLBACK_SECS, vuelve atras
#         rollback-> restaura el backup manualmente
#         confirm -> marca el cambio como confirmado (lo usa la app al reconectar con la IP nueva)
IFC=${LCT_IFACE:-}
IP=${LCT_IP:-}
PFX=${LCT_PREFIX:-24}
GW=${LCT_GW:-}
DNS=${LCT_DNS:-}
SEARCH=${LCT_SEARCH:-}
NEWHOST=${LCT_HOSTNAME:-}
RB=${LCT_ROLLBACK_SECS:-0}
PHASE=${1:-${LCT_PHASE:-stage}}
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
JOB=$LCT_STATE/ipjob.sh
LOG=$LCT_STATE/ipjob.log
BK=$LCT_STATE/backup
STATUS=$LCT_STATE/ipjob.status
export IFC IP PFX GW DNS SEARCH

backup_paths() {
  case "$1" in
    nm)       echo "/etc/NetworkManager/system-connections /etc/sysconfig/network-scripts /etc/netplan" ;;
    netplan)  echo "/etc/netplan /etc/cloud/cloud.cfg.d" ;;
    ifupdown) echo "/etc/network/interfaces /etc/network/interfaces.d /etc/resolv.conf /etc/systemd/resolved.conf.d" ;;
    ifcfg)    echo "/etc/sysconfig/network-scripts /etc/resolv.conf" ;;
    wicked)   echo "/etc/sysconfig/network /etc/resolv.conf" ;;
  esac
}

do_backup() {
  rm -rf "$BK"; mkdir -p "$BK"; chmod 700 "$BK"
  : > "$BK/manifest"
  local p existing=""
  for p in $(backup_paths "$BACKEND") /etc/hostname; do
    if [ -e "$p" ] || [ -L "$p" ]; then echo "E $p" >> "$BK/manifest"; existing="$existing $p"
    else echo "A $p" >> "$BK/manifest"; fi
  done
  if [ -n "$existing" ]; then
    # shellcheck disable=SC2086
    tar -czpPf "$BK/files.tgz" $existing || return 1
  fi
  hostname > "$BK/hostname" 2>/dev/null
  echo "$BACKEND" > "$BK/backend"
  echo "$IFC" > "$BK/iface"
  date '+%Y-%m-%d %H:%M:%S' > "$BK/date"
}

do_restore() {
  [ -f "$BK/manifest" ] || { echo "No hay backup para restaurar"; return 1; }
  local t p
  while read -r t p; do
    [ -n "$p" ] && rm -rf "$p"
  done < "$BK/manifest"
  [ -f "$BK/files.tgz" ] && tar -xzpPf "$BK/files.tgz"
  if [ -s "$BK/hostname" ] && [ "$(hostname)" != "$(cat "$BK/hostname")" ]; then
    if lct_has hostnamectl; then hostnamectl set-hostname "$(cat "$BK/hostname")"; else hostname "$(cat "$BK/hostname")"; fi
  fi
  return 0
}

write_resolv() {
  # Solo para backends que no gestionan DNS por si mismos.
  [ -z "$DNS" ] && [ -z "$SEARCH" ] && return 0
  if [ -L /etc/resolv.conf ] && readlink /etc/resolv.conf | grep -q systemd && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    { echo "[Resolve]"; [ -n "$DNS" ] && echo "DNS=$DNS"; [ -n "$SEARCH" ] && echo "Domains=$SEARCH"; } > /etc/systemd/resolved.conf.d/linuxconfigtool.conf
    echo "resolved" > "$BK/dns_mode"
    return 0
  fi
  if lct_has resolvconf && [ "$BACKEND" = ifupdown ]; then return 0; fi
  [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
  { echo "# Generado por Linux Config Tool"; [ -n "$SEARCH" ] && echo "search $SEARCH"; for d in $DNS; do echo "nameserver $d"; done; } > /etc/resolv.conf
}

# ---------------- configuracion por backend (fase stage) ----------------
config_nm() {
  local uuid u
  uuid=$(nmcli -g GENERAL.CON-UUID device show "$IFC" 2>/dev/null)
  if [ -z "$uuid" ]; then
    for u in $(nmcli -g UUID connection show 2>/dev/null); do
      if [ "$(nmcli -g connection.interface-name connection show "$u" 2>/dev/null)" = "$IFC" ]; then uuid=$u; break; fi
    done
  fi
  if [ -z "$uuid" ]; then
    lct_log "No hay perfil de NetworkManager para $IFC, se crea uno nuevo (lct-$IFC)"
    nmcli connection add type ethernet ifname "$IFC" con-name "lct-$IFC" >/dev/null || return 1
    uuid=$(nmcli -g connection.uuid connection show "lct-$IFC" 2>/dev/null)
  fi
  echo "$uuid" > "$BK/nm_uuid"
  lct_log "Perfil NetworkManager: $(nmcli -g connection.id connection show "$uuid") ($uuid)"
  nmcli connection modify "$uuid" \
    ipv4.method manual ipv4.addresses "$IP/$PFX" ipv4.gateway "$GW" \
    ipv4.dns "$DNS" ipv4.dns-search "$SEARCH" ipv4.ignore-auto-dns yes \
    connection.autoconnect yes || return 1
}
activate_nm() {
  nmcli connection up "$(cat "$BK/nm_uuid")"
}
reactivate_nm() {
  nmcli connection reload
  nmcli connection up "$(cat "$BK/nm_uuid")" 2>/dev/null || nmcli device connect "$IFC"
}

config_netplan() {
  lct_has python3 || { echo "python3 no esta instalado; use el modo 'comandos manuales'."; return 1; }
  python3 -c 'import yaml' 2>/dev/null || { echo "Falta python3-yaml; use el modo 'comandos manuales'."; return 1; }
  python3 - <<'PY' || return 1
import os, glob, yaml
ifc = os.environ['IFC']; ip = os.environ['IP']; pfx = os.environ['PFX']
gw = os.environ.get('GW', ''); dns = os.environ.get('DNS', '').split(); search = os.environ.get('SEARCH', '').split()
docs, found = {}, []
for f in sorted(glob.glob('/etc/netplan/*.yaml')):
    with open(f) as fh:
        d = yaml.safe_load(fh) or {}
    docs[f] = d
    for sect, v in (d.get('network') or {}).items():
        if isinstance(v, dict) and ifc in v:
            found.append((f, sect))
if not found:
    t = '/etc/netplan/99-linuxconfigtool.yaml'
    docs[t] = {'network': {'version': 2, 'ethernets': {ifc: {}}}}
    found = [(t, 'ethernets')]
def addr_str(a):
    return a if isinstance(a, str) else list(a.keys())[0]
for f, s in found:
    c = docs[f]['network'][s][ifc]
    if c is None:
        c = docs[f]['network'][s][ifc] = {}
    c['dhcp4'] = False
    c.pop('gateway4', None)
    c.pop('nameservers', None)
    if 'addresses' in c:
        c['addresses'] = [a for a in c['addresses'] if ':' in addr_str(a)]
        if not c['addresses']:
            c.pop('addresses')
    if 'routes' in c:
        c['routes'] = [r for r in c['routes'] if str(r.get('to')) not in ('default', '0.0.0.0/0')]
        if not c['routes']:
            c.pop('routes')
f, s = found[-1]
c = docs[f]['network'][s][ifc]
c['addresses'] = [ip + '/' + pfx] + c.get('addresses', [])
if gw:
    c.setdefault('routes', []).append({'to': '0.0.0.0/0', 'via': gw})
if dns or search:
    ns = {}
    if dns: ns['addresses'] = dns
    if search: ns['search'] = search
    c['nameservers'] = ns
for f in sorted(set(x[0] for x in found)):
    with open(f, 'w') as fh:
        yaml.safe_dump(docs[f], fh, default_flow_style=False, sort_keys=False)
    os.chmod(f, 0o600)
    print('Archivo netplan actualizado: ' + f)
PY
  if [ -d /etc/cloud ]; then
    mkdir -p /etc/cloud/cloud.cfg.d
    echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    lct_log "cloud-init: configuracion de red desactivada para que no pise la IP fija"
  fi
  netplan generate || return 1
}
activate_netplan() { netplan apply; }
reactivate_netplan() { netplan apply; }

config_ifupdown() {
  local f tmp mask
  for f in /etc/network/interfaces /etc/network/interfaces.d/*; do
    [ -f "$f" ] || continue
    tmp=$(mktemp)
    awk -v ifc="$IFC" '
      function stanza(l) { return l ~ /^[ \t]*(iface|auto|allow-[a-z-]+|mapping|source|source-directory|rename)[ \t]/ }
      {
        if (skip) { if (stanza($0)) skip = 0; else next }
        if ($1 == "iface" && $2 == ifc && $3 == "inet") { skip = 1; next }
        if ($1 == "auto" || $1 ~ /^allow-/) {
          out = $1; n = 0
          for (i = 2; i <= NF; i++) if ($i != ifc) { out = out " " $i; n++ }
          if (n == 0) next
          print out; next
        }
        print
      }' "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
  done
  mask=$(lct_prefix_to_mask "$PFX")
  {
    echo ""
    echo "# IP fija configurada por Linux Config Tool"
    echo "auto $IFC"
    echo "iface $IFC inet static"
    echo "    address $IP"
    echo "    netmask $mask"
    [ -n "$GW" ] && echo "    gateway $GW"
    [ -n "$DNS" ] && echo "    dns-nameservers $DNS"
    [ -n "$SEARCH" ] && echo "    dns-search $SEARCH"
  } >> /etc/network/interfaces
  write_resolv
}
activate_ifupdown() {
  ifdown --force "$IFC" >/dev/null 2>&1 || ifdown "$IFC" >/dev/null 2>&1
  pkill -f "dhclient.*[[:space:]]$IFC([[:space:]]|$)" 2>/dev/null
  ip addr flush dev "$IFC" scope global
  ifup "$IFC" || return 1
  [ -f "$BK/dns_mode" ] && systemctl restart systemd-resolved
  return 0
}
reactivate_ifupdown() {
  ifdown --force "$IFC" >/dev/null 2>&1 || ifdown "$IFC" >/dev/null 2>&1
  pkill -f "dhclient.*[[:space:]]$IFC([[:space:]]|$)" 2>/dev/null
  ip addr flush dev "$IFC" scope global
  ifup "$IFC"
  systemctl is-active --quiet systemd-resolved 2>/dev/null && systemctl restart systemd-resolved
  return 0
}

config_ifcfg() {
  local f=/etc/sysconfig/network-scripts/ifcfg-$IFC i=1 d
  if [ ! -f "$f" ]; then
    printf 'DEVICE=%s\nNAME=%s\nTYPE=Ethernet\n' "$IFC" "$IFC" > "$f"
  fi
  sed -i -E '/^[[:space:]]*(BOOTPROTO|IPADDR[0-9]*|PREFIX[0-9]*|NETMASK[0-9]*|GATEWAY[0-9]*|DNS[0-9]+|DOMAIN|PEERDNS|ONBOOT)=/d' "$f"
  {
    echo "BOOTPROTO=none"
    echo "ONBOOT=yes"
    echo "IPADDR=$IP"
    echo "PREFIX=$PFX"
    [ -n "$GW" ] && echo "GATEWAY=$GW"
    for d in $DNS; do echo "DNS$i=$d"; i=$((i+1)); done
    [ -n "$SEARCH" ] && echo "DOMAIN=\"$SEARCH\""
    echo "PEERDNS=no"
  } >> "$f"
  write_resolv
}
activate_ifcfg() { ifdown "$IFC" >/dev/null 2>&1; ifup "$IFC"; }
reactivate_ifcfg() { ifdown "$IFC" >/dev/null 2>&1; ifup "$IFC"; }

config_wicked() {
  local d=/etc/sysconfig/network f
  f=$d/ifcfg-$IFC
  [ -f "$f" ] || : > "$f"
  sed -i -E '/^[[:space:]]*(BOOTPROTO|IPADDR[_0-9]*|NETMASK[_0-9]*|PREFIXLEN[_0-9]*|STARTMODE)=/d' "$f"
  { echo "BOOTPROTO='static'"; echo "STARTMODE='auto'"; echo "IPADDR='$IP/$PFX'"; } >> "$f"
  [ -f "$d/routes" ] && sed -i -E '/^[[:space:]]*default[[:space:]]/d' "$d/routes"
  [ -f "$d/ifroute-$IFC" ] && sed -i -E '/^[[:space:]]*default[[:space:]]/d' "$d/ifroute-$IFC"
  [ -n "$GW" ] && echo "default $GW - $IFC" >> "$d/ifroute-$IFC"
  if [ -f "$d/config" ]; then
    sed -i -E "s|^NETCONFIG_DNS_STATIC_SERVERS=.*|NETCONFIG_DNS_STATIC_SERVERS=\"$DNS\"|; s|^NETCONFIG_DNS_STATIC_SEARCHLIST=.*|NETCONFIG_DNS_STATIC_SEARCHLIST=\"$SEARCH\"|" "$d/config"
  fi
}
activate_wicked() { lct_has netconfig && netconfig update -f; wicked ifreload "$IFC"; }
reactivate_wicked() { lct_has netconfig && netconfig update -f; wicked ifreload all; }

set_hostname() {
  [ -z "$NEWHOST" ] && return 0
  if lct_has hostnamectl; then hostnamectl set-hostname "$NEWHOST"; else echo "$NEWHOST" > /etc/hostname; hostname "$NEWHOST"; fi
  lct_log "Hostname cambiado a $NEWHOST"
}

do_rollback() {
  lct_log "ROLLBACK: restaurando configuracion anterior..."
  BACKEND=$(cat "$BK/backend" 2>/dev/null); IFC=$(cat "$BK/iface" 2>/dev/null)
  do_restore
  "reactivate_$BACKEND"
  echo "ROLLED_BACK" > "$STATUS"
  lct_log "Rollback terminado. IP actual: $(ip -o -4 addr show dev "$IFC" | awk '{print $4}' | paste -sd, -)"
}

lct_require_root
mkdir -p "$LCT_STATE"; chmod 700 "$LCT_STATE"
cd / || true

case "$PHASE" in
  stage)
    [ -n "$IFC" ] && [ -n "$IP" ] || lct_fail "Faltan la interfaz o la IP."
    ip link show "$IFC" >/dev/null 2>&1 || lct_fail "La interfaz $IFC no existe en este servidor."
    if [ -f "$LCT_STATE/ipjob.pid" ] && kill -0 "$(cat "$LCT_STATE/ipjob.pid")" 2>/dev/null; then
      lct_fail "Ya hay un cambio de IP en curso en este servidor. Espere a que termine."
    fi
    BACKEND=${LCT_BACKEND:-$(lct_backend "$IFC")}
    [ "$BACKEND" = unknown ] && lct_fail "No pude detectar como se gestiona la red (NetworkManager/netplan/ifupdown/ifcfg/wicked). Use 'comandos manuales'."
    lct_log "Backend de red: $BACKEND"
    do_backup || lct_fail "No se pudo hacer el backup de la configuracion."
    lct_log "Backup guardado en $BK"
    if ! "config_$BACKEND"; then
      do_restore
      lct_fail "Error al escribir la configuracion nueva; se restauro el backup. No se cambio nada."
    fi
    set_hostname
    cp "$SELF" "$JOB" || lct_fail "No se pudo preparar el job."
    chmod 700 "$JOB"
    rm -f "$LCT_STATE/confirmed"
    echo "PENDING" > "$STATUS"
    : > "$LOG"
    if lct_has systemd-run && [ -d /run/systemd/system ]; then
      systemd-run --unit="lct-ipjob-$(date +%s)" --quiet /bin/bash -c "exec /bin/bash $JOB run >>$LOG 2>&1" \
        || { setsid nohup /bin/bash "$JOB" run >>"$LOG" 2>&1 </dev/null & }
    else
      setsid nohup /bin/bash "$JOB" run >>"$LOG" 2>&1 </dev/null &
    fi
    echo "BACKEND=$BACKEND"
    echo "LCT_BACKUP=$BK"
    echo "LCT_STAGED=1"
    ;;
  run)
    echo $$ > "$LCT_STATE/ipjob.pid"
    BACKEND=$(cat "$BK/backend")
    sleep 2
    lct_log "Activando IP $IP/$PFX en $IFC ($BACKEND)..."
    if ! "activate_$BACKEND"; then
      lct_log "ERROR al activar la configuracion nueva."
      do_rollback
    else
      echo "APPLIED" > "$STATUS"
      lct_log "IP aplicada: $(ip -o -4 addr show dev "$IFC" | awk '{print $4}' | paste -sd, -)"
      if [ "$RB" -gt 0 ] 2>/dev/null; then
        lct_log "Esperando confirmacion de la app durante $RB segundos..."
        i=0
        while [ "$i" -lt "$RB" ]; do
          [ -f "$LCT_STATE/confirmed" ] && break
          sleep 1; i=$((i+1))
        done
        if [ -f "$LCT_STATE/confirmed" ]; then
          echo "CONFIRMED" > "$STATUS"; lct_log "Cambio CONFIRMADO."
        else
          lct_log "No llego la confirmacion a tiempo."
          do_rollback
        fi
      else
        echo "CONFIRMED" > "$STATUS"; lct_log "Cambio aplicado (sin rollback automatico)."
      fi
    fi
    rm -f "$LCT_STATE/ipjob.pid"
    ;;
  confirm)
    touch "$LCT_STATE/confirmed"
    for _ in 1 2 3 4 5 6; do
      case "$(cat "$STATUS" 2>/dev/null)" in CONFIRMED|ROLLED_BACK) break ;; esac
      sleep 1
    done
    echo "STATUS=$(cat "$STATUS" 2>/dev/null)"
    echo "---- log ----"
    cat "$LOG" 2>/dev/null
    ;;
  rollback)
    do_rollback
    cat "$LOG" 2>/dev/null | tail -n 5
    ;;
  status)
    echo "STATUS=$(cat "$STATUS" 2>/dev/null)"
    cat "$LOG" 2>/dev/null
    ;;
  *)
    lct_fail "Fase desconocida: $PHASE"
    ;;
esac
