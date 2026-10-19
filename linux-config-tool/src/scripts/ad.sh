# ---- ad.sh : acceso por grupos de seguridad de Active Directory (realmd + sssd) ----
# LCT_ACTION: verify | add | remove | join | idmap-off
ACTION=${LCT_ACTION:-verify}
GROUP=${LCT_GROUP:-}
ACCESS=${LCT_ACCESS:-login}          # login | sudo | sudo-nopasswd
EXPECTED_GID=${LCT_EXPECTED_GID:-}
DOMAIN=${LCT_DOMAIN:-}
ADUSER=${LCT_ADUSER:-}
OU=${LCT_OU:-}
INSTALL=${LCT_INSTALL:-0}
IDMAP_OFF=${LCT_IDMAP_OFF:-0}
SHORTNAMES=${LCT_SHORTNAMES:-0}
SSSD=/etc/sssd/sssd.conf
PKGLOG=/var/lib/linuxconfigtool/paquetes.log

lct_require_root

realm_domain() {
  local d=""
  lct_has realm && d=$(realm list --name-only 2>/dev/null | head -n1)
  if [ -z "$d" ] && [ -r "$SSSD" ]; then
    d=$(awk '/^[[:space:]]*\[domain\//{s=$0; sub(/.*\[domain\//,"",s); sub(/\].*/,"",s); print s; exit}' "$SSSD")
  fi
  echo "$d"
}

# Resuelve el grupo tal como lo devuelve SSSD. Prueba "grupo", "grupo@dominio" y "DOMINIO\grupo".
resolve_group() {
  local g=$1 d cand line
  d=${DOMAIN:-$(realm_domain)}
  for cand in "$g" "$g@$d" "$(echo "$d" | cut -d. -f1 | tr '[:lower:]' '[:upper:]')\\$g"; do
    [ -z "$cand" ] && continue
    line=$(getent group "$cand" 2>/dev/null) && [ -n "$line" ] && { echo "$line"; return 0; }
  done
  return 1
}

sudoers_file_for() {
  echo "/etc/sudoers.d/lct-$(echo "$1" | tr -c 'A-Za-z0-9_-' '_' | tr '[:upper:]' '[:lower:]' | sed 's/_*$//')"
}

sssd_domain_section() {
  awk '/^[[:space:]]*\[domain\//{gsub(/[][[:space:]]/,""); print; exit}' "$SSSD"
}

# Cambia (o agrega) "clave = valor" dentro de la seccion [domain/...] de sssd.conf
sssd_set() {
  local key=$1 val=$2 sec tmp
  sec=$(sssd_domain_section)
  [ -n "$sec" ] || { echo "No encontre la seccion [domain/...] en $SSSD"; return 1; }
  cp -p "$SSSD" "$SSSD.lct.$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp)
  awk -v sec="[$sec]" -v key="$key" -v val="$val" '
    function flush() { if (insec && !done) { print key " = " val; done = 1 } }
    /^[[:space:]]*\[/ { s = $0; gsub(/[[:space:]]/, "", s); if (insec) flush(); insec = (s == sec) }
    insec && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { if (!done) { print key " = " val; done = 1 }; next }
    { print }
    END { flush() }' "$SSSD" > "$tmp" && cat "$tmp" > "$SSSD"
  rm -f "$tmp"
  chmod 600 "$SSSD"
}

restart_sssd_clean() {
  systemctl stop sssd 2>/dev/null
  rm -f /var/lib/sss/db/*.ldb /var/lib/sss/mc/* 2>/dev/null
  systemctl start sssd
}

print_group() {
  local line=$1
  echo "GROUP_NAME=$(echo "$line" | cut -d: -f1)"
  echo "GROUP_GID=$(echo "$line" | cut -d: -f3)"
  echo "GROUP_MEMBERS=$(echo "$line" | cut -d: -f4)"
}

check_gid() {
  local gid=$1 idmap
  [ -z "$EXPECTED_GID" ] && return 0
  if [ "$gid" = "$EXPECTED_GID" ]; then
    echo "GID_MATCH=yes"
  else
    echo "GID_MATCH=no"
    idmap=$(awk -F= 'tolower($1) ~ /ldap_id_mapping/ {gsub(/[ \t]/,"",$2); print tolower($2)}' "$SSSD" 2>/dev/null | tail -n1)
    if [ "${idmap:-true}" != "false" ]; then
      echo "LCT_WARN=El GID que ve Linux ($gid) no coincide con el GID de AD ($EXPECTED_GID): SSSD esta generando IDs automaticamente (ldap_id_mapping = True). Use 'Usar GID/UID de AD'."
    else
      echo "LCT_WARN=El GID que ve Linux ($gid) no coincide con el esperado ($EXPECTED_GID). Revise el atributo gidNumber del grupo en AD."
    fi
  fi
}

# ---------------- paquetes (union al dominio) ----------------
PM=""
pkg_detect_pm() {
  if lct_has dnf; then PM=dnf
  elif lct_has yum; then PM=yum
  elif lct_has apt-get; then PM=apt
  elif lct_has zypper; then PM=zypper
  else PM=""; fi
}

pkg_installed() {
  case "$PM" in
    dnf|yum|zypper) rpm -q --whatprovides "$1" >/dev/null 2>&1 ;;
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    *) return 1 ;;
  esac
}

# Paquetes: "requeridos|opcionales"
pkg_sets() {
  case "$PM" in
    dnf|yum) echo "realmd sssd adcli oddjob oddjob-mkhomedir samba-common-tools|krb5-workstation sssd-tools" ;;
    apt)     echo "realmd sssd libnss-sss libpam-sss adcli samba-common-bin|oddjob oddjob-mkhomedir packagekit krb5-user sssd-tools" ;;
    zypper)  echo "realmd sssd sssd-ad adcli|samba-client krb5-client sssd-tools oddjob oddjob-mkhomedir" ;;
  esac
}

REPO_OPTS=()
APT_UPDATED=0
pkg_install_list() {
  [ $# -eq 0 ] && return 0
  {
    echo "===== $(date '+%F %T') instalar: $* ${REPO_OPTS[*]}"
    case "$PM" in
      dnf|yum) "$PM" -y "${REPO_OPTS[@]}" install "$@" ;;
      apt)
        if [ "$APT_UPDATED" = 0 ]; then apt-get -o DPkg::Lock::Timeout=180 update; APT_UPDATED=1; fi
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -q "$@" ;;
      zypper) zypper -n install "$@" ;;
    esac
  } >>"$PKGLOG" 2>&1
}

# Instala lo que falte: primero todo junto, si falla de a uno (asi un opcional inexistente no frena nada)
pkg_install_missing() {
  local p miss=()
  for p in "$@"; do pkg_installed "$p" || miss+=("$p"); done
  [ ${#miss[@]} -eq 0 ] && return 0
  lct_log "Instalando: ${miss[*]}"
  pkg_install_list "${miss[@]}" && return 0
  # Si el problema es el repositorio (sin red, sin registrar, bloqueado) no tiene sentido reintentar de a uno.
  grep -qiE 'No match for argument|Unable to locate package|not found in package names|No package .* available|has no installation candidate' "$PKGLOG" || return 0
  for p in "${miss[@]}"; do pkg_installed "$p" || pkg_install_list "$p"; done
  return 0
}

pkg_missing_of() {
  local p out=""
  for p in "$@"; do pkg_installed "$p" || out="$out $p"; done
  echo "${out# }"
}

# Si no hay repositorios: usar el DVD/ISO de instalacion conectado a la VM (RHEL/Rocky/Alma/Oracle/CentOS)
MEDIA_MNT=/mnt/lct-media
MEDIA_MOUNTED=0
media_setup() {
  case "$PM" in dnf|yum) ;; *) return 1 ;; esac
  local m dev media="" sub keys="" k
  for m in $(awk '$3=="iso9660"||$3=="udf"{print $2}' /proc/mounts); do
    if [ -d "$m/BaseOS/repodata" ] || [ -d "$m/repodata" ]; then media=$m; break; fi
  done
  if [ -z "$media" ]; then
    mkdir -p "$MEDIA_MNT"
    for dev in /dev/sr0 /dev/sr1 /dev/cdrom; do
      [ -b "$dev" ] || continue
      mount -o ro "$dev" "$MEDIA_MNT" 2>/dev/null || continue
      if [ -d "$MEDIA_MNT/BaseOS/repodata" ] || [ -d "$MEDIA_MNT/repodata" ]; then media=$MEDIA_MNT; MEDIA_MOUNTED=1; break; fi
      umount "$MEDIA_MNT" 2>/dev/null
    done
  fi
  [ -n "$media" ] || return 1
  for k in /etc/pki/rpm-gpg/RPM-GPG-KEY-*; do [ -f "$k" ] && keys="$keys file://$k"; done
  {
    for sub in BaseOS AppStream .; do
      [ -d "$media/$sub/repodata" ] || continue
      echo "[lct-media-$( [ "$sub" = . ] && echo root || echo "$sub")]"
      echo "name=Medio de instalacion ($sub) - Linux Config Tool"
      echo "baseurl=file://$media/$sub"
      echo "enabled=1"
      if [ -n "$keys" ]; then echo "gpgcheck=1"; echo "gpgkey=${keys# }"; else echo "gpgcheck=0"; fi
      echo
    done
  } > /etc/yum.repos.d/lct-media.repo
  REPO_OPTS=(--disablerepo='*' --enablerepo='lct-media-*')
  lct_log "Usando el medio de instalacion montado en $media"
  return 0
}
media_cleanup() {
  rm -f /etc/yum.repos.d/lct-media.repo
  [ "$MEDIA_MOUNTED" = 1 ] && umount "$MEDIA_MNT" 2>/dev/null
  REPO_OPTS=()
}

pkg_diagnose() {
  local f=$1
  if grep -qiE 'not registered|no est. registrad|entitlement|consumer identity|subscription' "$f"; then
    echo "el servidor no esta registrado en Red Hat / Satellite, por eso no tiene repositorios. Registralo (subscription-manager) o conecta el ISO/DVD completo de instalacion a la VM y reintenta."
  elif grep -qiE 'Could not resolve host|Temporary failure in name resolution|Name or service not known|resolve' "$f"; then
    echo "el servidor no puede resolver los nombres de los repositorios (DNS). Revisa los DNS o el proxy, o conecta el ISO/DVD de instalacion a la VM."
  elif grep -qiE 'Could not get lock|Unable to acquire the dpkg|is held by process|waiting for process|another app is currently holding' "$f"; then
    echo "otro proceso esta instalando paquetes en este momento (apt/dnf/zypper bloqueado). Espera unos minutos y reintenta."
  elif grep -qiE 'Curl error|Failed to download metadata|Cannot download repomd|repomd.xml|Connection timed out|Failed to connect|Could not connect|Network is unreachable|No route to host|Cannot retrieve repository metadata|Failed to fetch|Unable to connect|Timeout was reached|proxy' "$f"; then
    echo "el servidor no llega a los repositorios de paquetes (sin internet, sin proxy o firewall). Configura el proxy/Satellite o conecta el ISO/DVD de instalacion a la VM y reintenta."
  elif grep -qiE 'no enabled repo|There are no enabled repositories|No repositories available|No repos defined' "$f"; then
    echo "no hay repositorios habilitados en el servidor. Conecta el ISO/DVD de instalacion a la VM y reintenta."
  elif grep -qiE 'No match for argument|Unable to locate package|not found in package names|No package .* available|has no installation candidate' "$f"; then
    echo "algunos paquetes no existen en los repositorios configurados del servidor."
  elif grep -qiE 'GPG|signature' "$f"; then
    echo "fallo la verificacion de firmas GPG de los paquetes."
  else
    echo "revisa el detalle debajo."
  fi
}

ensure_packages() {
  local sets req opt miss
  [ -n "$PM" ] || { lct_fail "No reconozco el gestor de paquetes del servidor (dnf/yum/apt/zypper)."; }
  mkdir -p "$(dirname "$PKGLOG")"; : > "$PKGLOG"
  sets=$(pkg_sets); req=${sets%%|*}; opt=${sets#*|}
  # shellcheck disable=SC2086
  miss=$(pkg_missing_of $req)
  if [ -z "$miss" ]; then
    lct_log "Paquetes necesarios ya instalados ($req)."
    # shellcheck disable=SC2086
    pkg_install_missing $opt
    return 0
  fi
  lct_log "Faltan instalar: $miss"
  # shellcheck disable=SC2086
  pkg_install_missing $req $opt
  # shellcheck disable=SC2086
  miss=$(pkg_missing_of $req)
  if [ -n "$miss" ] && media_setup; then
    # shellcheck disable=SC2086
    pkg_install_missing $req $opt
    media_cleanup
    # shellcheck disable=SC2086
    miss=$(pkg_missing_of $req)
  fi
  if [ -n "$miss" ]; then
    grep -vE '^\s*$|^(Updating|Last metadata|Dependencies resolved|Reading|Building|Hit:|Get:|Ign:|Loading|Repository .* is listed more than once|=====)' "$PKGLOG" | awk '!seen[$0]++' | tail -n 10 | sed 's/^/LCT_DETAIL=/'
    echo "LCT_DETAIL=(log completo en el servidor: $PKGLOG)"
    lct_fail "No se pudieron instalar los paquetes ($miss): $(pkg_diagnose "$PKGLOG")"
  fi
  lct_log "Paquetes instalados correctamente."
  return 0
}

join_diagnose() {
  local f=$1
  if grep -qiE 'Preauthentication failed|password|Couldn.t authenticate|Invalid credentials|KDC reply did not match|Client .* not found in Kerberos' "$f"; then
    echo "usuario o contrasena de AD incorrectos (o la cuenta esta bloqueada)."
  elif grep -qiE 'Insufficient access|Access denied|INSUFF_ACCESS|not have permission|Couldn.t create computer account' "$f"; then
    echo "el usuario de AD no tiene permiso para crear equipos en esa OU."
  elif grep -qiE 'No such object|Couldn.t find|OU.*not|The computer organizational unit is invalid|invalid.*ou' "$f"; then
    echo "la OU no existe o esta mal escrita (formato OU=...,DC=...,DC=...)."
  elif grep -qiE 'Clock skew|clock' "$f"; then
    echo "la hora del servidor difiere mas de 5 minutos con el controlador de dominio. Sincroniza NTP."
  elif grep -qiE 'Necessary packages are not installed|packagekit' "$f"; then
    echo "faltan paquetes que pide realmd. Marca 'Instalar los paquetes necesarios'."
  elif grep -qiE 'Already joined|already a member' "$f"; then
    echo "el servidor ya esta unido a un dominio."
  elif grep -qiE 'Cannot contact|Cannot find KDC|resolve|unreachable|timed out' "$f"; then
    echo "no se puede contactar a los controladores de dominio (DNS o firewall: puertos 53, 88, 389, 445, 464)."
  else
    echo "revisa el detalle debajo."
  fi
}

case "$ACTION" in
  verify)
    [ -n "$GROUP" ] || lct_fail "Indique el nombre del grupo."
    sss_cache -G >/dev/null 2>&1
    line=$(resolve_group "$GROUP") || lct_fail "El grupo '$GROUP' no se encuentra desde este servidor (getent group). Verifique el nombre, que el servidor este unido al dominio y que el grupo tenga GID unix (gidNumber) si usa IDs de AD."
    print_group "$line"
    check_gid "$(echo "$line" | cut -d: -f3)"
    echo "LCT_OK=1"
    ;;

  add)
    [ -n "$GROUP" ] || lct_fail "Indique el nombre del grupo."
    sss_cache -G >/dev/null 2>&1
    line=$(resolve_group "$GROUP") || lct_fail "El grupo '$GROUP' no se encuentra desde este servidor (getent group). No se cambio nada."
    name=$(echo "$line" | cut -d: -f1); gid=$(echo "$line" | cut -d: -f3)
    print_group "$line"
    check_gid "$gid"
    # 1) Permitir login
    if lct_has realm && [ -n "$(realm_domain)" ]; then
      pol=$(realm list 2>/dev/null | awk -F': ' '/login-policy/{print $2; exit}')
      if [ "$pol" = "allow-realm-logins" ] || [ "$pol" = "allow-any-login" ]; then
        echo "LCT_NOTE=Antes TODOS los usuarios del dominio podian entrar ($pol). Desde ahora solo entran los grupos permitidos."
      fi
      realm permit -g "$name" || lct_fail "realm permit fallo."
    elif [ -f "$SSSD" ]; then
      cur=$(awk -F= 'tolower($1) ~ /simple_allow_groups/ {sub(/^[ \t]*/,"",$2); print $2}' "$SSSD" | tail -n1)
      if ! echo "$cur" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -qiFx "$name"; then
        sssd_set access_provider simple
        sssd_set simple_allow_groups "${cur:+$cur, }$name"
        systemctl restart sssd
      fi
    else
      lct_fail "Este servidor no tiene realm ni sssd configurado. Unalo primero al dominio."
    fi
    echo "Login permitido para el grupo $name"
    # 2) sudo
    f=$(sudoers_file_for "$name")
    if [ "$ACCESS" = sudo ] || [ "$ACCESS" = sudo-nopasswd ]; then
      esc=$(printf '%s' "$name" | sed 's/\\/\\\\/g; s/ /\\ /g')
      if [ "$ACCESS" = sudo-nopasswd ]; then rule="%$esc ALL=(ALL) NOPASSWD: ALL"; else rule="%$esc ALL=(ALL) ALL"; fi
      tmp=$(mktemp)
      { echo "# Acceso sudo para el grupo AD $name (GID $gid) - Linux Config Tool $(date '+%Y-%m-%d')"; echo "$rule"; } > "$tmp"
      if visudo -cf "$tmp" >/dev/null; then
        install -m 0440 -o root -g root "$tmp" "$f"
        echo "sudo habilitado: $rule  ($f)"
      else
        rm -f "$tmp"; lct_fail "La regla sudo no paso la validacion de visudo; no se aplico."
      fi
      rm -f "$tmp"
    else
      [ -f "$f" ] && rm -f "$f" && echo "sudo quitado para $name (era solo login)"
    fi
    echo "LCT_OK=1"
    ;;

  remove)
    [ -n "$GROUP" ] || lct_fail "Indique el nombre del grupo."
    line=$(resolve_group "$GROUP"); name=${line%%:*}; [ -n "$name" ] || name=$GROUP
    if lct_has realm && [ -n "$(realm_domain)" ]; then
      realm permit -x -g "$name" 2>/dev/null || realm permit -x -g "$GROUP" 2>/dev/null || echo "Aviso: realm no tenia permitido ese grupo"
    elif [ -f "$SSSD" ]; then
      cur=$(awk -F= 'tolower($1) ~ /simple_allow_groups/ {sub(/^[ \t]*/,"",$2); print $2}' "$SSSD" | tail -n1)
      new=$(echo "$cur" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -viFx "$name" | paste -sd, - | sed 's/,/, /g')
      if [ -z "$new" ]; then
        sssd_set access_provider deny
        sssd_set simple_allow_groups ""
        echo "LCT_NOTE=No quedan grupos permitidos: el login de dominio queda bloqueado (access_provider = deny)."
      else
        sssd_set simple_allow_groups "$new"
      fi
      systemctl restart sssd
    fi
    for f in "$(sudoers_file_for "$name")" "$(sudoers_file_for "$GROUP")"; do
      [ -f "$f" ] && rm -f "$f" && echo "Regla sudo eliminada ($f)"
    done
    echo "Acceso quitado para $name"
    echo "LCT_OK=1"
    ;;

  join)
    [ -n "$DOMAIN" ] && [ -n "$ADUSER" ] || lct_fail "Faltan dominio o usuario de AD."
    ADPASS=$(printf '%s' "${LCT_ADPASS_B64:-}" | base64 -d 2>/dev/null)
    lct_os
    pkg_detect_pm
    if [ "$INSTALL" = 1 ]; then
      ensure_packages || exit 1
    fi
    lct_has realm || lct_fail "realmd no esta instalado en el servidor. Marque 'Instalar los paquetes necesarios'."
    if lct_has timedatectl && [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "no" ]; then
      echo "LCT_WARN=La hora del servidor no esta sincronizada (NTP). Kerberos falla si hay mas de 5 minutos de diferencia con el DC."
    fi
    lct_log "Buscando el dominio $DOMAIN..."
    disc=$(realm discover "$DOMAIN" 2>&1) || {
      echo "$disc" | tail -n 5 | sed 's/^/LCT_DETAIL=/'
      echo "LCT_DETAIL=DNS del servidor: $(awk '/^nameserver/{print $2}' /etc/resolv.conf | paste -sd' ' -)"
      if echo "$disc" | grep -qi 'system bus'; then
        lct_fail "realmd necesita el servicio dbus y no esta corriendo (systemctl start dbus)."
      fi
      lct_fail "No se encontro el dominio $DOMAIN. Los DNS del servidor tienen que ser los de Active Directory (los DC)."
    }
    echo "$disc"
    if echo "$disc" | grep -q 'configured: kerberos-member'; then
      echo "LCT_NOTE=El servidor ya estaba unido a $DOMAIN; se omite la union."
    else
      # Paquetes que realmd pide para este dominio
      if [ "$INSTALL" = 1 ]; then
        req=$(echo "$disc" | awk -F': ' '/required-package:/{print $2}')
        miss=""
        for p in $req; do pkg_installed "$p" || miss="$miss $p"; done
        if [ -n "$miss" ]; then
          lct_log "realmd pide ademas:$miss"
          # shellcheck disable=SC2086
          pkg_install_list $miss || true
        fi
      fi
      lct_log "Uniendo al dominio (crea la cuenta de equipo $(hostname -s | tr '[:lower:]' '[:upper:]') en AD)..."
      jout=$(mktemp)
      if [ -n "$OU" ]; then
        printf '%s\n' "$ADPASS" | realm join -v --user="$ADUSER" --computer-ou="$OU" "$DOMAIN" >"$jout" 2>&1; rc=$?
      else
        printf '%s\n' "$ADPASS" | realm join -v --user="$ADUSER" "$DOMAIN" >"$jout" 2>&1; rc=$?
      fi
      if [ $rc -ne 0 ]; then
        grep -v '^ \* ' "$jout" | tail -n 8 | sed 's/^/LCT_DETAIL=/'
        why=$(join_diagnose "$jout"); rm -f "$jout"
        lct_fail "realm join fallo: $why"
      fi
      rm -f "$jout"
      lct_log "Cuenta de equipo creada en AD."
    fi
    # Directorios home automaticos al primer login
    if lct_has authselect; then
      authselect enable-feature with-mkhomedir >/dev/null 2>&1 || authselect select sssd with-mkhomedir --force >/dev/null 2>&1
      systemctl enable --now oddjobd >/dev/null 2>&1
    elif lct_has pam-auth-update; then
      pam-auth-update --enable mkhomedir >/dev/null 2>&1
    elif lct_has pam-config; then
      pam-config -a --mkhomedir >/dev/null 2>&1
    fi
    changed=0
    if [ "$IDMAP_OFF" = 1 ]; then
      sssd_set ldap_id_mapping False && lct_log "SSSD usara los UID/GID definidos en AD (uidNumber/gidNumber)" && changed=1
    fi
    if [ "$SHORTNAMES" = 1 ]; then
      sssd_set use_fully_qualified_names False && sssd_set fallback_homedir /home/%u && changed=1 \
        && lct_log "Los usuarios entran con nombre corto (usuario, sin @$DOMAIN)"
    fi
    [ $changed = 1 ] && restart_sssd_clean
    # Por seguridad: nadie del dominio entra hasta que se habiliten grupos.
    if realm list 2>/dev/null | grep -q 'login-policy: allow-realm-logins'; then
      realm deny --all >/dev/null 2>&1 && lct_log "Login de dominio cerrado hasta que se habiliten grupos."
    fi
    echo "Servidor unido a $DOMAIN"
    echo "LCT_OK=1"
    ;;

  idmap-off)
    [ -f "$SSSD" ] || lct_fail "No existe $SSSD"
    sssd_set ldap_id_mapping False || lct_fail "No se pudo modificar sssd.conf"
    restart_sssd_clean
    echo "SSSD ahora usa los UID/GID de AD. Backup de sssd.conf en /etc/sssd/"
    echo "LCT_OK=1"
    ;;

  *)
    lct_fail "Accion desconocida: $ACTION"
    ;;
esac
