# ===== Acceso por grupos de AD =====
# Ejecutar como root (sudo -i). Requiere el servidor unido al dominio (realm list).

# ---------- GRP Linux Admins@corp.local ----------
getent group 'GRP Linux Admins@corp.local'        # tiene que mostrar  nombre:*:GID:miembros  (GID esperado 5000)
# Si no aparece, proba el nombre sin "@dominio" y usa el que muestre getent en los pasos siguientes.
realm permit -g 'GRP Linux Admins@corp.local'
# sudo compara el nombre exacto: SSSD devuelve los grupos de AD en minusculas (usar el nombre que muestra getent).
cat > /etc/sudoers.d/lct-grp_linux_admins_corp_local <<'EOF'
%grp\ linux\ admins@corp.local ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/lct-grp_linux_admins_corp_local
visudo -cf /etc/sudoers.d/lct-grp_linux_admins_corp_local        # tiene que decir "parsed OK"

# ---------- ops@corp.local ----------
getent group 'ops@corp.local'        # tiene que mostrar  nombre:*:GID:miembros  (GID esperado 5000)
# Si no aparece, proba el nombre sin "@dominio" y usa el que muestre getent en los pasos siguientes.
realm permit -g 'ops@corp.local'
# sudo compara el nombre exacto: SSSD devuelve los grupos de AD en minusculas (usar el nombre que muestra getent).
cat > /etc/sudoers.d/lct-ops_corp_local <<'EOF'
%ops@corp.local ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/lct-ops_corp_local
visudo -cf /etc/sudoers.d/lct-ops_corp_local        # tiene que decir "parsed OK"

# Sin realmd (sssd configurado a mano): en /etc/sssd/sssd.conf, seccion [domain/...]:
#   access_provider = simple
#   simple_allow_groups = GRP Linux Admins@corp.local, ops@corp.local
#   y luego: systemctl restart sssd

# ---- Verificar ----
realm list | grep -E 'login-policy|permitted-groups'
ls -l /etc/sudoers.d/
# Quitar acceso a un grupo:  realm permit -x -g 'GRP Linux Admins@corp.local'  y borrar su archivo en /etc/sudoers.d/