#!/bin/bash
# ---- inspect.sh : muestra como esta integrado el servidor con Active Directory (SOLO LECTURA, no cambia nada) ----
# Uso:  sudo bash ver-ad.sh        (las claves que pudiera haber en sssd.conf se ocultan)
export LC_ALL=C
sec() { echo; echo "===== $*"; }
clean() { grep -vE '^[[:space:]]*(#|;|$)' "$@" 2>/dev/null; }

sec "SISTEMA"
. /etc/os-release 2>/dev/null; echo "OS: ${PRETTY_NAME:-?}"; echo "Hostname: $(hostname -f 2>/dev/null || hostname)"

sec "PAQUETES DE AD / AUTENTICACION"
if command -v dpkg-query >/dev/null; then
  dpkg-query -W -f='${Status} ${Package} ${Version}\n' 2>/dev/null | awk '$1=="install" && $3=="installed" {print $4, $5}'
else
  rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null
fi | grep -Ei '^(sssd|realmd|adcli|krb5|libkrb5|samba|winbind|libnss-winbind|libpam-winbind|oddjob|centrify|delinea|pbis|likewise|nslcd|libnss-ldap|libpam-ldap|libnss-sss|libpam-sss|sudo|chrony|ntp|authselect|packagekit)' | sort

sec "SERVICIOS"
for s in sssd realmd oddjobd winbind smbd nslcd centrifydc chrony chronyd ntp systemd-timesyncd; do
  st=$(systemctl is-active "$s" 2>/dev/null); en=$(systemctl is-enabled "$s" 2>/dev/null)
  [ -n "$en" ] && [ "$en" != "not-found" ] && echo "$s: $st ($en)"
done

sec "REALM (realm list)"
command -v realm >/dev/null && realm list 2>&1 || echo "realmd no instalado"

sec "SSSD (/etc/sssd/sssd.conf, claves ocultas)"
for f in /etc/sssd/sssd.conf /etc/sssd/conf.d/*.conf; do
  [ -f "$f" ] || continue
  echo "--- $f"
  clean "$f" | sed -E 's/^([[:space:]]*[a-z_]*(authtok|password|secret)[a-z_]*[[:space:]]*=).*/\1 ***OCULTO***/I'
done

sec "KERBEROS"
clean /etc/krb5.conf || echo "sin /etc/krb5.conf"
echo "--- principals del keytab"; klist -k 2>/dev/null | awk 'NR>3{print $2}' | sort -u | head -n 10

sec "SAMBA / WINBIND (si se usa)"
[ -f /etc/samba/smb.conf ] && clean /etc/samba/smb.conf | sed -n '/^\[global\]/,/^\[/p' | head -n 40 || echo "sin smb.conf"

sec "CENTRIFY / DELINEA (si se usa)"
command -v adinfo >/dev/null && adinfo 2>&1 | head -n 15 || echo "no instalado"

sec "NSSWITCH"
grep -E '^(passwd|group|shadow|sudoers|netgroup|automount|initgroups)' /etc/nsswitch.conf

sec "PAM"
for f in common-auth common-account common-session common-password sshd login system-auth password-auth; do
  [ -f "/etc/pam.d/$f" ] || continue
  echo "--- /etc/pam.d/$f"; clean "/etc/pam.d/$f"
done
command -v authselect >/dev/null && { echo "--- authselect"; authselect current 2>&1; }

sec "ACCESS.CONF (/etc/security/access.conf)"
clean /etc/security/access.conf || echo "(vacio)"

sec "SUDOERS"
clean /etc/sudoers | grep -vE '^Defaults[[:space:]]+(env_reset|mail_badpass|secure_path|use_pty)'
for f in /etc/sudoers.d/*; do [ -f "$f" ] && { echo "--- $f"; clean "$f"; }; done

sec "SSH (valores efectivos)"
sshd -T 2>/dev/null | grep -Ei '^(allowgroups|allowusers|denygroups|denyusers|passwordauthentication|kbdinteractiveauthentication|kerberosauthentication|gssapiauthentication|usepam|permitrootlogin|authorizedkeyscommand)' || echo "sshd -T no disponible"

sec "HORA"
timedatectl 2>/dev/null | grep -Ei 'zone|synchronized|NTP service'
grep -hE '^(server|pool|NTP=|FallbackNTP=)' /etc/chrony/chrony.conf /etc/chrony.conf /etc/systemd/timesyncd.conf /etc/ntp.conf 2>/dev/null

sec "DNS"
if command -v resolvectl >/dev/null; then resolvectl status 2>/dev/null | grep -E 'DNS Servers|DNS Domain|Current DNS'; else grep -E '^(nameserver|search|domain)' /etc/resolv.conf; fi

sec "HOME Y LOGIN"
grep -Ei '^(UMASK|HOME_MODE|USERGROUPS_ENAB)' /etc/login.defs
grep -Ei 'mkhomedir|oddjob' /etc/pam.d/common-session /etc/pam.d/system-auth 2>/dev/null
echo "Carpetas en /home: $(ls /home 2>/dev/null | head -n 15 | paste -sd' ' -)"

sec "GRUPOS DE AD CON ACCESO (como los ve Linux)"
groups=""
command -v realm >/dev/null && groups=$(realm list 2>/dev/null | sed -n 's/^[[:space:]]*permitted-groups:[[:space:]]*//p' | head -n1)
[ -z "$groups" ] && groups=$(grep -hiE '^[[:space:]]*simple_allow_groups' /etc/sssd/sssd.conf /etc/sssd/conf.d/*.conf 2>/dev/null | sed 's/^[^=]*=[[:space:]]*//' | head -n1)
if [ -n "$groups" ]; then
  echo "$groups" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | while IFS= read -r g; do
    [ -n "$g" ] || continue
    line=$(getent group "$g" 2>/dev/null)
    if [ -n "$line" ]; then echo "$line" | awk -F: '{n=split($4,m,","); printf "%s  GID=%s  miembros=%d\n", $1, $3, ($4==""?0:n)}'; else echo "$g  (getent no lo resuelve)"; fi
  done
else
  echo "No hay grupos restringidos por realm/sssd (revisar access.conf, AllowGroups de SSH o sudoers arriba)"
fi
echo
echo "Fin. Para ver un usuario de AD:  id usuario   (o id usuario@dominio)"
