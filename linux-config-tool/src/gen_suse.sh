# ===== IP fija: ens192 -> 10.1.2.5/24  gw 10.1.2.1 =====
# SUSE / SLES 12-15 / openSUSE Leap (wicked)
# Ejecutar como root (si no lo sos, primero:  sudo -i )

IF=ens192
D=/etc/sysconfig/network
cp -a $D /root/network.bak.$(date +%F)
touch $D/ifcfg-$IF
sed -i -E '/^(BOOTPROTO|IPADDR[_0-9]*|NETMASK[_0-9]*|PREFIXLEN[_0-9]*|STARTMODE)=/d' $D/ifcfg-$IF
cat >> $D/ifcfg-$IF <<'EOF'
BOOTPROTO='static'
STARTMODE='auto'
IPADDR='10.1.2.5/24'
EOF
echo "default 10.1.2.1 - $IF" > $D/ifroute-$IF
sed -i 's|^NETCONFIG_DNS_STATIC_SERVERS=.*|NETCONFIG_DNS_STATIC_SERVERS="10.1.1.1 10.1.1.2"|' $D/config
sed -i 's|^NETCONFIG_DNS_STATIC_SEARCHLIST=.*|NETCONFIG_DNS_STATIC_SEARCHLIST="corp.local"|' $D/config
netconfig update -f
wicked ifreload $IF
# Alternativa con menus:  yast lan

hostnamectl set-hostname 'web01'

# ---- Verificar ----
ip -4 addr show ens192
ip route | grep default
cat /etc/resolv.conf
ping -c 3 10.1.2.1