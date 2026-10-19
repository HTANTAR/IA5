# ===== IP fija: ens192 -> 10.1.2.5/24  gw 10.1.2.1 =====
# Ubuntu Server 18.04+ (netplan)
# Ejecutar como root (si no lo sos, primero:  sudo -i )

cp -a /etc/netplan /root/netplan.bak.$(date +%F)
cat > /etc/netplan/99-ip-fija.yaml <<'EOF'
network:
  version: 2
  ethernets:
    ens192:
      dhcp4: false
      addresses: [10.1.2.5/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.1.2.1
      nameservers:
        addresses: [10.1.1.1, 10.1.1.2]
        search: [corp.local]
EOF
chmod 600 /etc/netplan/*.yaml
# Que cloud-init no vuelva a poner DHCP al reiniciar:
[ -d /etc/cloud ] && echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

netplan try        # aplica y pide Enter para confirmar; si no confirmas vuelve atras en 120 s
# (en versiones viejas sin "try":  netplan apply)

hostnamectl set-hostname 'web01'

# ---- Verificar ----
ip -4 addr show ens192
ip route | grep default
cat /etc/resolv.conf
ping -c 3 10.1.2.1