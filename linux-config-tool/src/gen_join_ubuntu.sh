# ===== Unir al dominio corp.local =====
# Ubuntu Server 18.04+ (netplan)
# Ejecutar como root (sudo -i). Los DNS deben apuntar a los DC y la hora debe estar sincronizada.

# 1) Paquetes
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin oddjob oddjob-mkhomedir packagekit krb5-user

# 2) Verificar que se ve el dominio
timedatectl | grep -i synchronized
realm discover 'corp.local'

# 3) Unir (pide la contraseña de adm)
realm join --user='adm' --computer-ou='OU=Linux,DC=corp,DC=local' 'corp.local'

# 4) Crear el home automaticamente al primer login
pam-auth-update --enable mkhomedir

# 5) Usar los UID/GID de AD (uidNumber/gidNumber)
cp -p /etc/sssd/sssd.conf /etc/sssd/sssd.conf.bak.$(date +%F)
sed -i -E 's/^[[:space:]]*ldap_id_mapping[[:space:]]*=.*/ldap_id_mapping = False/' /etc/sssd/sssd.conf
grep -q '^ldap_id_mapping' /etc/sssd/sssd.conf || sed -i '/^\[domain\//a ldap_id_mapping = False' /etc/sssd/sssd.conf
systemctl stop sssd; rm -f /var/lib/sss/db/*.ldb /var/lib/sss/mc/*; systemctl start sssd

# 6) Nadie del dominio entra hasta que habilites grupos
realm deny --all
# realm permit -g <grupo>      (o usá la pestaña "Acceso por grupos AD")
realm list
# Probar: id <usuario>   y   getent group <grupo>