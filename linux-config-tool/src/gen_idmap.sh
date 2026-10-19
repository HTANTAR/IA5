# ===== Usar los UID/GID definidos en AD (ldap_id_mapping = False) =====
# ATENCION: cambia los UID/GID de TODOS los usuarios de AD en este servidor.
# Los usuarios de AD deben tener uidNumber (y los grupos gidNumber) o no podran entrar.

cp -p /etc/sssd/sssd.conf /etc/sssd/sssd.conf.bak.$(date +%F)
sed -i -E 's/^[[:space:]]*ldap_id_mapping[[:space:]]*=.*/ldap_id_mapping = False/' /etc/sssd/sssd.conf
grep -q '^ldap_id_mapping' /etc/sssd/sssd.conf || sed -i '/^\[domain\//a ldap_id_mapping = False' /etc/sssd/sssd.conf
systemctl stop sssd; rm -f /var/lib/sss/db/*.ldb /var/lib/sss/mc/*; systemctl start sssd
# Verificar con un usuario del dominio:  id usuario@dominio   (tiene que mostrar el uid/gid de AD)