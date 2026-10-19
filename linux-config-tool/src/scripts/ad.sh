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
SSSD=/etc/sssd/sssd.conf

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
    if [ "$INSTALL" = 1 ]; then
      lct_log "Instalando paquetes necesarios..."
      if lct_has dnf || lct_has yum; then
        pm=$(lct_has dnf && echo dnf || echo yum)
        $pm -y install realmd sssd sssd-tools oddjob oddjob-mkhomedir adcli samba-common-tools krb5-workstation authselect-compat >/dev/null 2>&1 \
          || $pm -y install realmd sssd oddjob oddjob-mkhomedir adcli samba-common-tools krb5-workstation || lct_fail "No se pudieron instalar los paquetes (revise repositorios/suscripcion)."
      elif lct_has apt-get; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin oddjob oddjob-mkhomedir packagekit krb5-user || lct_fail "No se pudieron instalar los paquetes."
      elif lct_has zypper; then
        zypper -n install realmd sssd sssd-ad sssd-tools adcli samba-client krb5-client oddjob oddjob-mkhomedir || lct_fail "No se pudieron instalar los paquetes."
      else
        lct_fail "Gestor de paquetes no reconocido."
      fi
    fi
    lct_has realm || lct_fail "realmd no esta instalado. Marque 'Instalar paquetes'."
    if lct_has timedatectl && [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "no" ]; then
      echo "LCT_WARN=La hora del servidor no esta sincronizada (NTP). Kerberos falla si hay mas de 5 minutos de diferencia con el DC."
    fi
    lct_log "Buscando el dominio $DOMAIN..."
    realm discover "$DOMAIN" || lct_fail "No se encontro el dominio $DOMAIN. Revise que los DNS del servidor apunten a los DC de AD."
    lct_log "Uniendo al dominio..."
    if [ -n "$OU" ]; then
      printf '%s\n' "$ADPASS" | realm join --user="$ADUSER" --computer-ou="$OU" "$DOMAIN" || lct_fail "realm join fallo (usuario/clave/OU/permisos)."
    else
      printf '%s\n' "$ADPASS" | realm join --user="$ADUSER" "$DOMAIN" || lct_fail "realm join fallo (usuario/clave/permisos)."
    fi
    # Directorios home automaticos
    if lct_has authselect; then
      authselect enable-feature with-mkhomedir >/dev/null 2>&1 || authselect select sssd with-mkhomedir --force >/dev/null 2>&1
      systemctl enable --now oddjobd >/dev/null 2>&1
    elif lct_has pam-auth-update; then
      pam-auth-update --enable mkhomedir >/dev/null 2>&1
    fi
    if [ "$IDMAP_OFF" = 1 ]; then
      sssd_set ldap_id_mapping False && lct_log "SSSD usara los UID/GID definidos en AD (uidNumber/gidNumber)"
      restart_sssd_clean
    fi
    # Por seguridad: nadie del dominio entra hasta que se habiliten grupos.
    realm deny --all >/dev/null 2>&1 && lct_log "Login de dominio restringido: agregue los grupos que deben tener acceso."
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
