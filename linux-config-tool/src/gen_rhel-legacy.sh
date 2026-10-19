# ===== IP fija: ens192 -> 10.1.2.5/24  gw 10.1.2.1 =====
# RHEL / CentOS 6-7 sin NetworkManager (ifcfg)
# Ejecutar como root (si no lo sos, primero:  sudo -i )

IF=ens192
F=/etc/sysconfig/network-scripts/ifcfg-$IF
cp $F /root/ifcfg-$IF.bak 2>/dev/null
[ -f $F ] || printf "DEVICE=$IF\nNAME=$IF\nTYPE=Ethernet\n" > $F
sed -i -E '/^(BOOTPROTO|IPADDR[0-9]*|PREFIX[0-9]*|NETMASK[0-9]*|GATEWAY|DNS[0-9]|DOMAIN|ONBOOT|PEERDNS)=/d' $F
cat >> $F <<'EOF'
BOOTPROTO=none
ONBOOT=yes
IPADDR=10.1.2.5
PREFIX=24
GATEWAY=10.1.2.1
DNS1=10.1.1.1
DNS2=10.1.1.2
DOMAIN="corp.local"
PEERDNS=no
EOF
ifdown $IF; ifup $IF                     # o: systemctl restart network

hostnamectl set-hostname 'web01'

# ---- Verificar ----
ip -4 addr show ens192
ip route | grep default
cat /etc/resolv.conf
ping -c 3 10.1.2.1