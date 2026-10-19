# ===== IP fija: ens192 -> 10.1.2.5/24  gw 10.1.2.1 =====
# RHEL / CentOS / Oracle Linux 7 (NetworkManager)
# Ejecutar como root (si no lo sos, primero:  sudo -i )

IF=ens192
nmcli device status                       # ver interfaces
CON=$(nmcli -t -f GENERAL.CONNECTION device show $IF | cut -d: -f2-)
echo "Perfil: $CON"
# Si "Perfil" sale vacio, crear uno:  nmcli connection add type ethernet ifname $IF con-name $IF ; CON=$IF

nmcli connection modify "$CON" ipv4.method manual ipv4.addresses 10.1.2.5/24 ipv4.gateway '10.1.2.1' ipv4.dns '10.1.1.1 10.1.1.2' ipv4.dns-search 'corp.local' ipv4.ignore-auto-dns yes connection.autoconnect yes
nmcli connection up "$CON"

hostnamectl set-hostname 'web01'

# ---- Verificar ----
ip -4 addr show ens192
ip route | grep default
cat /etc/resolv.conf
ping -c 3 10.1.2.1