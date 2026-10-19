# ===== IP fija: ens192 -> 10.1.2.5/24  gw 10.1.2.1 =====
# Debian (/etc/network/interfaces)
# Ejecutar como root (si no lo sos, primero:  sudo -i )

IF=ens192
ifdown $IF 2>/dev/null                    # bajar la interfaz ANTES de editar
cp /etc/network/interfaces /root/interfaces.bak.$(date +%F)
# Quitar la configuracion vieja de la interfaz (revisa tambien /etc/network/interfaces.d/):
sed -i -e "/^iface $IF inet /d" -e "/^auto $IF\$/d" -e "/^allow-hotplug $IF\$/d" /etc/network/interfaces
cat >> /etc/network/interfaces <<EOF

auto $IF
iface $IF inet static
    address 10.1.2.5
    netmask 255.255.255.0
    gateway 10.1.2.1
    dns-nameservers 10.1.1.1 10.1.1.2
    dns-search corp.local
EOF
cat /etc/network/interfaces              # verificar que no quedaron lineas viejas de $IF
ifup $IF
# Si no esta instalado "resolvconf", poner los DNS a mano:
command -v resolvconf >/dev/null || printf "search corp.local\nnameserver 10.1.1.1\nnameserver 10.1.1.2\n" > /etc/resolv.conf

hostnamectl set-hostname 'web01'

# ---- Verificar ----
ip -4 addr show ens192
ip route | grep default
cat /etc/resolv.conf
ping -c 3 10.1.2.1