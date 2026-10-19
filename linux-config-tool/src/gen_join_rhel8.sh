# ===== Unir al dominio corp.local =====
# RHEL / Rocky / Alma / Oracle / CentOS 8, 9, 10 · Fedora
# Ejecutar como root (sudo -i). Los DNS deben apuntar a los DC y la hora debe estar sincronizada.

# 1) Paquetes
dnf -y install realmd sssd sssd-tools oddjob oddjob-mkhomedir adcli samba-common-tools krb5-workstation
# Si falla por falta de repositorios (servidor sin registrar / sin internet): conectar el ISO/DVD COMPLETO
# de instalacion a la VM y usarlo como repositorio:
#   mkdir -p /mnt/iso && mount -o ro /dev/sr0 /mnt/iso
#   printf "[iso-baseos]\nbaseurl=file:///mnt/iso/BaseOS\ngpgcheck=0\n[iso-appstream]\nbaseurl=file:///mnt/iso/AppStream\ngpgcheck=0\n" > /etc/yum.repos.d/iso.repo
#   dnf -y --disablerepo='*' --enablerepo='iso-*' install realmd sssd oddjob oddjob-mkhomedir adcli samba-common-tools
#   rm /etc/yum.repos.d/iso.repo; umount /mnt/iso

# 2) Verificar que se ve el dominio
timedatectl | grep -i synchronized
realm discover 'corp.local'

# 3) Unir (pide la contraseña de adm)
realm join --user='adm' --computer-ou='OU=Linux,DC=corp,DC=local' 'corp.local'

# 4) Crear el home automaticamente al primer login
authselect enable-feature with-mkhomedir 2>/dev/null || authconfig --enablemkhomedir --update
systemctl enable --now oddjobd

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