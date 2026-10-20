/* Linux Config Tool - interfaz web (sin dependencias externas) */
'use strict';

/* =====================================================================
   Funciones puras (tambien se usan en las pruebas con Node)
   ===================================================================== */
const LCT = (() => {
  const shq = (s) => "'" + String(s == null ? '' : s).replace(/'/g, "'\\''") + "'";

  const isIp = (s) => /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/.test(String(s || '').trim());
  const ipToInt = (ip) => ip.split('.').reduce((a, o) => (a * 256) + Number(o), 0);
  const intToIp = (n) => [24, 16, 8, 0].map((s) => Math.floor(n / Math.pow(2, s)) % 256).join('.');
  const prefixToMask = (p) => intToIp(p === 0 ? 0 : (0xFFFFFFFF - (Math.pow(2, 32 - p) - 1)));
  const maskToPrefix = (m) => {
    if (!isIp(m)) return -1;
    const bits = ipToInt(m).toString(2).padStart(32, '0');
    return /^1*0*$/.test(bits) ? bits.indexOf('0') === -1 ? 32 : bits.indexOf('0') : -1;
  };
  const networkOf = (ip, p) => { const size = Math.pow(2, 32 - p); return Math.floor(ipToInt(ip) / size) * size; };
  const sameNet = (a, b, p) => networkOf(a, p) === networkOf(b, p);
  const isHostname = (h) => /^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$/.test(h);
  const isIface = (s) => /^[A-Za-z0-9_.:@-]{1,15}$/.test(s);

  // Valida los datos de IP. Devuelve lista de {level: err|warn|info, text}
  function validateIp(p) {
    const m = [];
    if (!p.iface) m.push({ level: 'err', text: 'Elegí la interfaz de red.' });
    else if (!isIface(p.iface)) m.push({ level: 'err', text: 'Nombre de interfaz inválido.' });
    if (!p.ip) m.push({ level: 'err', text: 'Falta la IP nueva.' });
    else if (!isIp(p.ip)) m.push({ level: 'err', text: 'La IP "' + p.ip + '" no es válida.' });
    if (!(p.prefix >= 1 && p.prefix <= 32)) m.push({ level: 'err', text: 'Máscara inválida.' });
    if (isIp(p.ip) && p.prefix >= 1 && p.prefix <= 30) {
      const n = networkOf(p.ip, p.prefix), b = n + Math.pow(2, 32 - p.prefix) - 1, x = ipToInt(p.ip);
      if (x === n) m.push({ level: 'err', text: 'La IP es la dirección de red (' + intToIp(n) + '/' + p.prefix + '), no se puede usar.' });
      if (x === b) m.push({ level: 'err', text: 'La IP es la dirección de broadcast, no se puede usar.' });
    }
    if (p.gw) {
      if (!isIp(p.gw)) m.push({ level: 'err', text: 'El gateway no es una IP válida.' });
      else if (isIp(p.ip) && p.prefix >= 1 && !sameNet(p.ip, p.gw, p.prefix)) m.push({ level: 'warn', text: 'El gateway ' + p.gw + ' no está en la misma red que ' + p.ip + '/' + p.prefix + '. Revisá la máscara.' });
      else if (p.gw === p.ip) m.push({ level: 'err', text: 'La IP y el gateway son iguales.' });
    } else {
      m.push({ level: 'warn', text: 'Sin gateway el servidor no va a poder salir de su red.' });
    }
    (p.dns || []).forEach((d) => { if (d && !isIp(d)) m.push({ level: 'err', text: 'DNS inválido: ' + d }); });
    if (!(p.dns || []).filter(Boolean).length) m.push({ level: 'warn', text: 'Sin DNS no va a resolver nombres (necesario para unirse a AD).' });
    if (p.search && !/^[A-Za-z0-9.\- ]+$/.test(p.search)) m.push({ level: 'err', text: 'Dominio de búsqueda inválido.' });
    if (p.hostname && !isHostname(p.hostname)) m.push({ level: 'err', text: 'Hostname inválido (solo letras, números, guiones y puntos).' });
    return m;
  }

  // Convierte la salida de detect.sh en un objeto
  function parseDetect(text) {
    const d = { ifaces: [], sudo: [], raw: text };
    String(text || '').split(/\r?\n/).forEach((line) => {
      if (line.startsWith('IF|')) {
        const f = line.split('|');
        d.ifaces.push({ name: f[1], state: f[2], mac: f[3], addrs: f[4] ? f[4].split(',') : [], method: f[5], backend: f[6], conn: f.slice(7).join('|') });
      } else if (line.startsWith('SUDO|')) {
        const f = line.split('|');
        d.sudo.push({ file: f[1], rule: f.slice(2).join('|').trim() });
      } else {
        const i = line.indexOf('=');
        if (i > 0 && /^[A-Z_]+$/.test(line.slice(0, i))) d[line.slice(0, i)] = line.slice(i + 1);
      }
    });
    d.groups = (d.REALM_GROUPS || d.SSSD_SIMPLE_GROUPS || '').split(',').map((s) => s.trim()).filter(Boolean);
    return d;
  }

  // Lineas KEY=VALUE de cualquier script + avisos
  function parseKV(text) {
    const kv = { warns: [], notes: [], details: [] };
    String(text || '').split(/\r?\n/).forEach((line) => {
      const i = line.indexOf('=');
      if (i > 0 && /^[A-Z_]+$/.test(line.slice(0, i))) {
        const k = line.slice(0, i), v = line.slice(i + 1);
        if (k === 'LCT_WARN') kv.warns.push(v); else if (k === 'LCT_NOTE') kv.notes.push(v); else if (k === 'LCT_DETAIL') kv.details.push(v); else kv[k] = v;
      }
    });
    return kv;
  }

  function header(vars) {
    let h = '#!/bin/bash\n# Generado por Linux Config Tool\n';
    Object.keys(vars).forEach((k) => { h += k + '=' + shq(vars[k]) + '\n'; });
    return h;
  }
  const assemble = (common, body, vars) => header(vars) + '\n' + common + '\n' + body;

  const DISTROS = [
    { k: 'rhel8', n: 'RHEL / Rocky / Alma / Oracle / CentOS 8, 9, 10 · Fedora', net: 'nm', pkg: 'dnf' },
    { k: 'rhel7', n: 'RHEL / CentOS / Oracle Linux 7 (NetworkManager)', net: 'nm', pkg: 'yum' },
    { k: 'rhel-legacy', n: 'RHEL / CentOS 6-7 sin NetworkManager (ifcfg)', net: 'ifcfg', pkg: 'yum' },
    { k: 'ubuntu', n: 'Ubuntu Server 18.04+ (netplan)', net: 'netplan', pkg: 'apt' },
    { k: 'debian', n: 'Debian (/etc/network/interfaces)', net: 'ifupdown', pkg: 'apt' },
    { k: 'debian-nm', n: 'Debian / Ubuntu con NetworkManager', net: 'nm', pkg: 'apt' },
    { k: 'suse', n: 'SUSE / SLES 12-15 / openSUSE Leap (wicked)', net: 'wicked', pkg: 'zypper' },
    { k: 'suse-nm', n: 'SLES 16 / openSUSE con NetworkManager', net: 'nm', pkg: 'zypper' },
    { k: 'auto', n: 'No sé · Script automático (detecta la distro solo)', net: 'auto', pkg: 'auto' },
  ];
  const distro = (k) => DISTROS.find((d) => d.k === k) || DISTROS[0];

  function distroFromDetect(det, iface) {
    if (!det) return 'auto';
    const i = (det.ifaces || []).find((x) => x.name === iface) || {};
    const be = i.backend;
    const id = (det.OS_ID || '') + ' ' + (det.OS_LIKE || '');
    const v = parseInt(det.OS_VERSION || '0', 10);
    if (/suse|sles/.test(id)) return be === 'nm' ? 'suse-nm' : 'suse';
    if (/ubuntu|debian/.test(id)) return be === 'nm' ? 'debian-nm' : be === 'netplan' ? 'ubuntu' : 'debian';
    if (/rhel|centos|fedora|rocky|alma|ol/.test(id)) {
      if (be === 'ifcfg') return 'rhel-legacy';
      return v && v < 8 && !/fedora/.test(id) ? 'rhel7' : 'rhel8';
    }
    if (be === 'nm') return 'rhel8';
    return 'auto';
  }

  // ---------------- comandos manuales: IP fija ----------------
  function ipCommands(dk, p) {
    const d = distro(dk), IF = p.iface || 'IFAZ', cidr = p.ip + '/' + p.prefix, mask = prefixToMask(p.prefix);
    const dns = (p.dns || []).filter(Boolean);
    const L = [];
    L.push('# ===== IP fija: ' + IF + ' -> ' + cidr + (p.gw ? '  gw ' + p.gw : '') + ' =====');
    L.push('# ' + d.n);
    L.push('# Ejecutar como root (si no lo sos, primero:  sudo -i )');
    L.push('');
    if (d.net === 'nm') {
      L.push('IF=' + IF);
      L.push('nmcli device status                       # ver interfaces');
      L.push('CON=$(nmcli -t -f GENERAL.CONNECTION device show $IF | cut -d: -f2-)');
      L.push('echo "Perfil: $CON"');
      L.push('# Si "Perfil" sale vacio, crear uno:  nmcli connection add type ethernet ifname $IF con-name $IF ; CON=$IF');
      L.push('');
      L.push('nmcli connection modify "$CON" ipv4.method manual ipv4.addresses ' + cidr +
        ' ipv4.gateway ' + shq(p.gw || '') + ' ipv4.dns ' + shq(dns.join(' ')) +
        ' ipv4.dns-search ' + shq(p.search || '') + ' ipv4.ignore-auto-dns yes connection.autoconnect yes');
      L.push('nmcli connection up "$CON"');
    } else if (d.net === 'netplan') {
      L.push('cp -a /etc/netplan /root/netplan.bak.$(date +%F)');
      L.push("cat > /etc/netplan/99-ip-fija.yaml <<'EOF'");
      L.push('network:');
      L.push('  version: 2');
      L.push('  ethernets:');
      L.push('    ' + IF + ':');
      L.push('      dhcp4: false');
      L.push('      addresses: [' + cidr + ']');
      if (p.gw) { L.push('      routes:'); L.push('        - to: 0.0.0.0/0'); L.push('          via: ' + p.gw); }
      if (dns.length || p.search) {
        L.push('      nameservers:');
        if (dns.length) L.push('        addresses: [' + dns.join(', ') + ']');
        if (p.search) L.push('        search: [' + p.search.split(/\s+/).join(', ') + ']');
      }
      L.push('EOF');
      L.push('chmod 600 /etc/netplan/*.yaml');
      L.push('# Que cloud-init no vuelva a poner DHCP al reiniciar:');
      L.push("[ -d /etc/cloud ] && echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg");
      L.push('');
      L.push('netplan try        # aplica y pide Enter para confirmar; si no confirmas vuelve atras en 120 s');
      L.push('# (en versiones viejas sin "try":  netplan apply)');
    } else if (d.net === 'ifupdown') {
      L.push('IF=' + IF);
      L.push('ifdown $IF 2>/dev/null                    # bajar la interfaz ANTES de editar');
      L.push('cp /etc/network/interfaces /root/interfaces.bak.$(date +%F)');
      L.push('# Quitar la configuracion vieja de la interfaz (revisa tambien /etc/network/interfaces.d/):');
      L.push('sed -i -e "/^iface $IF inet /d" -e "/^auto $IF\\$/d" -e "/^allow-hotplug $IF\\$/d" /etc/network/interfaces');
      L.push('cat >> /etc/network/interfaces <<EOF');
      L.push('');
      L.push('auto $IF');
      L.push('iface $IF inet static');
      L.push('    address ' + p.ip);
      L.push('    netmask ' + mask);
      if (p.gw) L.push('    gateway ' + p.gw);
      if (dns.length) L.push('    dns-nameservers ' + dns.join(' '));
      if (p.search) L.push('    dns-search ' + p.search);
      L.push('EOF');
      L.push('cat /etc/network/interfaces              # verificar que no quedaron lineas viejas de $IF');
      L.push('ifup $IF');
      if (dns.length) {
        L.push('# Si no esta instalado "resolvconf", poner los DNS a mano:');
        L.push('command -v resolvconf >/dev/null || printf "' + (p.search ? 'search ' + p.search + '\\n' : '') + dns.map((x) => 'nameserver ' + x + '\\n').join('') + '" > /etc/resolv.conf');
      }
    } else if (d.net === 'ifcfg') {
      L.push('IF=' + IF);
      L.push('F=/etc/sysconfig/network-scripts/ifcfg-$IF');
      L.push('cp $F /root/ifcfg-$IF.bak 2>/dev/null');
      L.push('[ -f $F ] || printf "DEVICE=$IF\\nNAME=$IF\\nTYPE=Ethernet\\n" > $F');
      L.push("sed -i -E '/^(BOOTPROTO|IPADDR[0-9]*|PREFIX[0-9]*|NETMASK[0-9]*|GATEWAY|DNS[0-9]|DOMAIN|ONBOOT|PEERDNS)=/d' $F");
      L.push("cat >> $F <<'EOF'");
      L.push('BOOTPROTO=none');
      L.push('ONBOOT=yes');
      L.push('IPADDR=' + p.ip);
      L.push('PREFIX=' + p.prefix);
      if (p.gw) L.push('GATEWAY=' + p.gw);
      dns.forEach((x, i) => L.push('DNS' + (i + 1) + '=' + x));
      if (p.search) L.push('DOMAIN="' + p.search + '"');
      L.push('PEERDNS=no');
      L.push('EOF');
      L.push('ifdown $IF; ifup $IF                     # o: systemctl restart network');
    } else if (d.net === 'wicked') {
      L.push('IF=' + IF);
      L.push('D=/etc/sysconfig/network');
      L.push('cp -a $D /root/network.bak.$(date +%F)');
      L.push('touch $D/ifcfg-$IF');
      L.push("sed -i -E '/^(BOOTPROTO|IPADDR[_0-9]*|NETMASK[_0-9]*|PREFIXLEN[_0-9]*|STARTMODE)=/d' $D/ifcfg-$IF");
      L.push("cat >> $D/ifcfg-$IF <<'EOF'");
      L.push("BOOTPROTO='static'");
      L.push("STARTMODE='auto'");
      L.push("IPADDR='" + cidr + "'");
      L.push('EOF');
      if (p.gw) L.push('echo "default ' + p.gw + ' - $IF" > $D/ifroute-$IF');
      L.push('sed -i \'s|^NETCONFIG_DNS_STATIC_SERVERS=.*|NETCONFIG_DNS_STATIC_SERVERS="' + dns.join(' ') + '"|\' $D/config');
      L.push('sed -i \'s|^NETCONFIG_DNS_STATIC_SEARCHLIST=.*|NETCONFIG_DNS_STATIC_SEARCHLIST="' + (p.search || '') + '"|\' $D/config');
      L.push('netconfig update -f');
      L.push('wicked ifreload $IF');
      L.push('# Alternativa con menus:  yast lan');
    }
    if (p.hostname) { L.push(''); L.push('hostnamectl set-hostname ' + shq(p.hostname)); }
    L.push('');
    L.push('# ---- Verificar ----');
    L.push('ip -4 addr show ' + IF);
    L.push('ip route | grep default');
    L.push('cat /etc/resolv.conf');
    if (p.gw) L.push('ping -c 3 ' + p.gw);
    return L.join('\n');
  }

  // ---------------- comandos manuales: grupos AD ----------------
  function fqGroup(g, domain) {
    g = String(g).trim();
    if (!domain || g.includes('@') || g.includes('\\')) return g;
    return g + '@' + domain;
  }
  const sudoEsc = (g) => g.replace(/\\/g, '\\\\').replace(/ /g, '\\ ');
  const fileSafe = (g) => 'lct-' + g.toLowerCase().replace(/[^a-z0-9_-]/g, '_').replace(/_+$/, '');

  function adCommands(p) {
    const groups = (p.groups || []).filter(Boolean);
    const L = ['# ===== Acceso por grupos de AD =====', '# Ejecutar como root (sudo -i). Requiere el servidor unido al dominio (realm list).', ''];
    if (!groups.length) { L.push('# Completa el/los grupo(s) en la pestaña "Acceso por grupos AD".'); return L.join('\n'); }
    groups.forEach((g0) => {
      const g = fqGroup(g0, p.domain);
      L.push('# ---------- ' + g + ' ----------');
      L.push('getent group ' + shq(g) + '        # tiene que mostrar  nombre:*:GID:miembros' + (p.gid ? '  (GID esperado ' + p.gid + ')' : ''));
      L.push('# Si no aparece, proba el nombre sin "@dominio" y usa el que muestre getent en los pasos siguientes.');
      L.push('realm permit -g ' + shq(g));
      if (p.access === 'sudo' || p.access === 'sudo-nopasswd') {
        const f = '/etc/sudoers.d/' + fileSafe(g);
        L.push('# sudo compara el nombre exacto: SSSD devuelve los grupos de AD en minusculas (usar el nombre que muestra getent).');
        L.push("cat > " + f + " <<'EOF'");
        L.push('%' + sudoEsc(g.toLowerCase()) + ' ALL=(ALL) ' + (p.access === 'sudo-nopasswd' ? 'NOPASSWD: ALL' : 'ALL'));
        L.push('EOF');
        L.push('chmod 440 ' + f);
        L.push('visudo -cf ' + f + '        # tiene que decir "parsed OK"');
      }
      L.push('');
    });
    L.push('# Sin realmd (sssd configurado a mano): en /etc/sssd/sssd.conf, seccion [domain/...]:');
    L.push('#   access_provider = simple');
    L.push('#   simple_allow_groups = ' + groups.map((g) => fqGroup(g, p.domain)).join(', '));
    L.push('#   y luego: systemctl restart sssd');
    L.push('');
    L.push('# ---- Verificar ----');
    L.push("realm list | grep -E 'login-policy|permitted-groups'");
    L.push('ls -l /etc/sudoers.d/');
    L.push('# Quitar acceso a un grupo:  realm permit -x -g ' + shq(fqGroup(groups[0], p.domain)) + '  y borrar su archivo en /etc/sudoers.d/');
    return L.join('\n');
  }

  function joinCommands(dk, p) {
    const d = distro(dk), dom = p.domain || 'empresa.local', user = p.user || 'usuario.admin';
    const L = ['# ===== Unir al dominio ' + dom + ' =====', '# ' + d.n, '# Ejecutar como root (sudo -i). Los DNS deben apuntar a los DC y la hora debe estar sincronizada.', ''];
    if (p.proxy) {
      L.push('# 0) Proxy para salir a internet (solo esta sesion; para dejarlo fijo usá "Configurar el proxy de internet")');
      L.push('export http_proxy=' + shq(p.proxy) + ' https_proxy=' + shq(p.proxy) + (p.noProxy ? ' no_proxy=' + shq(p.noProxy) : ''));
      L.push('');
    }
    L.push('# 1) Paquetes');
    if (d.pkg === 'dnf' || d.pkg === 'yum') {
      L.push(d.pkg + ' -y install realmd sssd sssd-tools oddjob oddjob-mkhomedir adcli samba-common-tools krb5-workstation');
      L.push('# Si falla por falta de repositorios (servidor sin registrar / sin internet): conectar el ISO/DVD COMPLETO');
      L.push('# de instalacion a la VM y usarlo como repositorio:');
      L.push('#   mkdir -p /mnt/iso && mount -o ro /dev/sr0 /mnt/iso');
      L.push('#   printf "[iso-baseos]\\nbaseurl=file:///mnt/iso/BaseOS\\ngpgcheck=0\\n[iso-appstream]\\nbaseurl=file:///mnt/iso/AppStream\\ngpgcheck=0\\n" > /etc/yum.repos.d/iso.repo');
      L.push('#   ' + d.pkg + " -y --disablerepo='*' --enablerepo='iso-*' install realmd sssd oddjob oddjob-mkhomedir adcli samba-common-tools");
      L.push('#   rm /etc/yum.repos.d/iso.repo; umount /mnt/iso');
    }
    else if (d.pkg === 'apt') { L.push('apt-get update'); L.push('DEBIAN_FRONTEND=noninteractive apt-get install -y realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin oddjob oddjob-mkhomedir packagekit krb5-user'); }
    else if (d.pkg === 'zypper') L.push('zypper -n install realmd sssd sssd-ad sssd-tools adcli samba-client krb5-client oddjob oddjob-mkhomedir');
    else { L.push('# RHEL/Rocky/Alma: dnf -y install realmd sssd oddjob oddjob-mkhomedir adcli samba-common-tools krb5-workstation'); L.push('# Ubuntu/Debian:   apt-get install -y realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin oddjob oddjob-mkhomedir packagekit'); L.push('# SUSE:            zypper -n install realmd sssd sssd-ad adcli samba-client krb5-client'); }
    L.push('');
    L.push('# 2) Verificar que se ve el dominio');
    L.push('timedatectl | grep -i synchronized');
    L.push('realm discover ' + shq(dom));
    L.push('');
    L.push('# 3) Unir (pide la contraseña de ' + user + ')');
    L.push('realm join --user=' + shq(user) + (p.ou ? ' --computer-ou=' + shq(p.ou) : '') + ' ' + shq(dom));
    L.push('');
    L.push('# 4) Crear el home automaticamente al primer login');
    if (d.pkg === 'apt') L.push('pam-auth-update --enable mkhomedir');
    else if (d.pkg === 'dnf' || d.pkg === 'yum') { L.push('authselect enable-feature with-mkhomedir 2>/dev/null || authconfig --enablemkhomedir --update'); L.push('systemctl enable --now oddjobd'); }
    else L.push('pam-config -a --mkhomedir 2>/dev/null || pam-auth-update --enable mkhomedir');
    let n = 5;
    if (p.shortnames) {
      L.push(''); L.push('# ' + (n++) + ') Login con nombre corto (usuario en vez de usuario@' + dom + ')');
      L.push("sed -i -E 's/^[[:space:]]*use_fully_qualified_names[[:space:]]*=.*/use_fully_qualified_names = False/; s|^[[:space:]]*fallback_homedir[[:space:]]*=.*|fallback_homedir = /home/%u|' /etc/sssd/sssd.conf");
    }
    if (p.idmap) { L.push(''); L.push('# ' + (n++) + ') Usar los UID/GID de AD (uidNumber/gidNumber)'); L.push(idmapCommands(true)); }
    else if (p.shortnames) L.push('systemctl stop sssd; rm -f /var/lib/sss/db/*.ldb /var/lib/sss/mc/*; systemctl start sssd');
    L.push('');
    L.push('# ' + n + ') Nadie del dominio entra hasta que habilites grupos');
    L.push('realm deny --all');
    if (p.groups && p.groups.length) {
      p.groups.forEach((g) => L.push('realm permit -g ' + shq(p.shortnames ? g : fqGroup(g, dom))));
      if (p.access === 'sudo' || p.access === 'sudo-nopasswd') {
        p.groups.forEach((g0) => { const g = (p.shortnames ? g0 : fqGroup(g0, dom)).toLowerCase(); const f = '/etc/sudoers.d/' + fileSafe(g);
          L.push("echo '%" + sudoEsc(g).replace(/'/g, "'\\''") + ' ALL=(ALL) ' + (p.access === 'sudo-nopasswd' ? 'NOPASSWD: ALL' : 'ALL') + "' > " + f + ' && chmod 440 ' + f + ' && visudo -cf ' + f); });
      }
    } else L.push('# realm permit -g <grupo>      (o usá la pestaña "Acceso por grupos AD")');
    L.push('realm list');
    L.push('# Probar: id <usuario>   y   getent group <grupo>');
    return L.join('\n');
  }

  function idmapCommands(inner) {
    const L = inner ? [] : ['# ===== Usar los UID/GID definidos en AD (ldap_id_mapping = False) =====',
      '# ATENCION: cambia los UID/GID de TODOS los usuarios de AD en este servidor.',
      '# Los usuarios de AD deben tener uidNumber (y los grupos gidNumber) o no podran entrar.', ''];
    L.push('cp -p /etc/sssd/sssd.conf /etc/sssd/sssd.conf.bak.$(date +%F)');
    L.push("sed -i -E 's/^[[:space:]]*ldap_id_mapping[[:space:]]*=.*/ldap_id_mapping = False/' /etc/sssd/sssd.conf");
    L.push("grep -q '^ldap_id_mapping' /etc/sssd/sssd.conf || sed -i '/^\\[domain\\//a ldap_id_mapping = False' /etc/sssd/sssd.conf");
    L.push('systemctl stop sssd; rm -f /var/lib/sss/db/*.ldb /var/lib/sss/mc/*; systemctl start sssd');
    if (!inner) L.push('# Verificar con un usuario del dominio:  id usuario@dominio   (tiene que mostrar el uid/gid de AD)');
    return L.join('\n');
  }

  // ---------------- proxy ----------------
  // Normaliza "proxy:8080" -> "http://proxy:8080". Devuelve {url, error}
  function normalizeProxy(v) {
    v = String(v || '').trim();
    if (!v) return { url: '' };
    if (!/^[a-z]+:\/\//i.test(v)) v = 'http://' + v;
    v = v.replace(/\/+$/, '');
    const m = v.match(/^(https?|socks5h?):\/\/(?:([^\s@\/]+)@)?([A-Za-z0-9.-]+|\[[0-9a-fA-F:]+\])(?::(\d{1,5}))?$/);
    if (!m) return { url: v, error: 'Dirección de proxy inválida. Ejemplo: http://proxy.empresa.local:8080' };
    if (!m[4]) return { url: v, error: 'Falta el puerto del proxy (ej: ' + v + ':8080).' };
    if (+m[4] < 1 || +m[4] > 65535) return { url: v, error: 'Puerto de proxy inválido.' };
    return { url: v, hasAuth: !!m[2], host: m[3], port: m[4] };
  }
  const stripProxyAuth = (u) => String(u || '').replace(/(\/\/)[^@\/]+@/, '$1');
  const maskProxy = (u) => String(u || '').replace(/(\/\/)[^:@\/]+:[^@\/]*@/, '$1***:***@');

  // Interpreta un codigo HTTP de la prueba
  function reachInfo(code, err) {
    code = String(code || '000');
    if (code === '000' || code === '0') return { ok: false, text: 'No llega' + (err ? ' — ' + err.replace(/^curl: \(\d+\)\s*/, '') : '') };
    if (code === '407') return { ok: false, auth: true, text: 'El proxy pide usuario y contraseña (407)' };
    if (/^50[234]$/.test(code)) return { ok: false, text: 'El proxy no llega al destino (' + code + ')' };
    return { ok: true, text: 'Llega (HTTP ' + code + ')' };
  }

  function proxyCommands(dk, p) {
    const d = distro(dk), u = p.url || 'http://proxy.empresa.local:8080', np = p.no || 'localhost,127.0.0.1';
    const n = normalizeProxy(u), L = [];
    L.push('# ===== Proxy de internet: ' + maskProxy(u) + ' =====');
    L.push('# ' + d.n);
    L.push('# Ejecutar como root (sudo -i)');
    L.push('');
    L.push('# 1) Usarlo ya, en esta sesion');
    L.push('export http_proxy=' + shq(u) + ' https_proxy=' + shq(u) + ' no_proxy=' + shq(np));
    L.push('export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" NO_PROXY="$no_proxy"');
    L.push('');
    L.push('# 2) Probar (cualquier codigo HTTP distinto de 000 / 407 significa que el proxy funciona)');
    const probe = { apt: 'http://archive.ubuntu.com/', dnf: 'https://cdn.redhat.com/', yum: 'https://cdn.redhat.com/', zypper: 'https://updates.suse.com/' }[d.pkg] || 'https://www.google.com/';
    L.push("curl -sS -o /dev/null -w '%{http_code}\\n' -x \"$http_proxy\" " + probe);
    L.push('');
    L.push('# 3) Dejarlo fijo para todo el sistema (sesiones nuevas)');
    L.push("sed -i -E '/^(export )?(http|https|ftp|no)_proxy=/Id' /etc/environment");
    L.push("cat >> /etc/environment <<'EOF'");
    ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY'].forEach((v) => L.push(v + '="' + u + '"'));
    L.push('no_proxy="' + np + '"'); L.push('NO_PROXY="' + np + '"');
    L.push('EOF');
    L.push("echo 'Defaults env_keep += \"http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY\"' > /etc/sudoers.d/proxy && chmod 440 /etc/sudoers.d/proxy && visudo -cf /etc/sudoers.d/proxy");
    L.push('');
    const apt = () => { L.push('# apt'); L.push("cat > /etc/apt/apt.conf.d/95proxy <<'EOF'"); L.push('Acquire::http::Proxy "' + u + '";'); L.push('Acquire::https::Proxy "' + u + '";'); L.push('EOF'); L.push('apt-get update'); };
    const dnf = (f, pm) => { L.push('# ' + pm); L.push("sed -i '/^proxy=/d' " + f + " && sed -i '/^\\[main\\]/a proxy=" + u.replace(/[&|\\]/g, '\\$&') + "' " + f); L.push(pm + ' makecache');
      L.push('# Si se registra contra Red Hat (no Satellite):');
      L.push('# subscription-manager config --server.proxy_hostname=' + (n.host || 'proxy') + ' --server.proxy_port=' + (n.port || '8080')); };
    const zyp = () => { L.push('# SUSE'); L.push("sed -i -E 's|^PROXY_ENABLED=.*|PROXY_ENABLED=\"yes\"|; s|^HTTP_PROXY=.*|HTTP_PROXY=\"" + u + "\"|; s|^HTTPS_PROXY=.*|HTTPS_PROXY=\"" + u + "\"|; s|^NO_PROXY=.*|NO_PROXY=\"" + np + "\"|' /etc/sysconfig/proxy"); L.push('zypper refresh'); };
    if (d.pkg === 'apt') apt();
    else if (d.pkg === 'dnf') dnf('/etc/dnf/dnf.conf', 'dnf');
    else if (d.pkg === 'yum') dnf('/etc/yum.conf', 'yum');
    else if (d.pkg === 'zypper') zyp();
    else { L.push('# Segun la distribucion:'); L.push('if [ -d /etc/apt/apt.conf.d ]; then'); apt(); L.push('fi');
      L.push('if [ -f /etc/dnf/dnf.conf ]; then'); dnf('/etc/dnf/dnf.conf', 'dnf'); L.push('fi');
      L.push('if [ -f /etc/sysconfig/proxy ]; then'); zyp(); L.push('fi'); }
    if (n.hasAuth) { L.push(''); L.push('# ATENCION: la contraseña del proxy queda en texto plano en estos archivos.'); }
    return L.join('\n');
  }

  return { shq, isIp, ipToInt, intToIp, prefixToMask, maskToPrefix, networkOf, sameNet, isHostname, validateIp, parseDetect, parseKV,
    header, assemble, DISTROS, distro, distroFromDetect, ipCommands, adCommands, joinCommands, idmapCommands, fqGroup, sudoEsc, fileSafe,
    normalizeProxy, stripProxyAuth, maskProxy, reachInfo, proxyCommands };
})();

if (typeof module !== 'undefined') { module.exports = LCT; }

/* =====================================================================
   Interfaz
   ===================================================================== */
if (typeof window !== 'undefined') (function () {
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const state = { det: null, connectedHost: null, store: { servers: [] }, logs: [], scripts: {}, busy: false, passwords: {} };

  // ---------- API ----------
  async function api(path, body, method) {
    const res = await fetch(path, {
      method: method || (body !== undefined ? 'POST' : 'GET'),
      headers: { 'X-LCT-Token': window.LCT_TOKEN, 'Content-Type': 'application/json' },
      body: body !== undefined ? (typeof body === 'string' ? body : JSON.stringify(body)) : undefined,
    });
    const txt = await res.text();
    try { return JSON.parse(txt); } catch (e) { throw new Error('Respuesta inválida del servidor local: ' + txt.slice(0, 200)); }
  }
  async function script(name) {
    if (!state.scripts[name]) {
      const res = await fetch('scripts/' + name + '.sh');
      if (!res.ok) throw new Error('No se encontró el script ' + name);
      state.scripts[name] = (await res.text()).replace(/\r\n/g, '\n');
    }
    return state.scripts[name];
  }
  async function buildScript(name, vars) {
    return LCT.assemble(await script('common'), await script(name), vars);
  }

  function conn(hostOverride) {
    return {
      host: (hostOverride || $('cHost').value).trim(),
      port: parseInt($('cPort').value, 10) || 22,
      user: $('cUser').value.trim(),
      password: $('cPass').value,
    };
  }

  function friendlyError(r) {
    if (!r) return 'Sin respuesta';
    if (!r.Ok) return r.ErrorMessage || 'Error desconocido';
    const out = r.Output || '';
    const kv = LCT.parseKV(out);
    if (kv.LCT_ERROR) return kv.LCT_ERROR;
    if (/is not in the sudoers file|no est. en el archivo sudoers|not allowed to execute/i.test(out)) return 'El usuario no tiene permisos de sudo en el servidor. Usá root o un usuario administrador.';
    if (/incorrect password|Sorry, try again|contrase.a incorrecta/i.test(out)) return 'sudo rechazó la contraseña.';
    if (/a terminal is required|no tty present|requiretty/i.test(out)) return 'sudo exige una terminal (requiretty). Conectate con root o quitá "Defaults requiretty" de /etc/sudoers.';
    return 'El comando terminó con código ' + r.ExitCode + '. Mirá el detalle en "Registro".';
  }

  // Ejecuta un script remoto. Devuelve {ok, r, kv, error}
  async function runRemote(label, name, vars, opts) {
    opts = opts || {};
    const c = conn(opts.host);
    if (!c.host || !c.user) throw new Error('Completá IP del servidor y usuario.');
    if (!c.password) throw new Error('Falta la contraseña.');
    const body = await buildScript(name, vars);
    const r = await api('/api/run', { host: c.host, port: c.port, user: c.user, password: c.password, script: body,
      asRoot: opts.asRoot !== false, timeout: opts.timeout || 180, label });
    const kv = LCT.parseKV(r.Output);
    const ok = !!(r.Ok && r.ExitCode === 0 && !kv.LCT_ERROR);
    addLog({ label, host: c.host, ok, r });
    return { ok, r, kv, error: ok ? null : friendlyError(r) };
  }

  // ---------- UI helpers ----------
  function toast(msg, ms) {
    const t = $('toast'); t.textContent = msg; t.classList.remove('hidden');
    clearTimeout(toast._t); toast._t = setTimeout(() => t.classList.add('hidden'), ms || 3000);
  }
  function chip(text, cls) { const c = $('connChip'); c.textContent = text; c.className = 'chip ' + (cls || ''); }
  function confirmBox(title, html, okText) {
    return new Promise((resolve) => {
      $('modalTitle').textContent = title; $('modalBody').innerHTML = html; $('modalOk').textContent = okText || 'Confirmar';
      $('modal').classList.remove('hidden');
      const done = (v) => { $('modal').classList.add('hidden'); $('modalOk').onclick = null; $('modalCancel').onclick = null; resolve(v); };
      $('modalOk').onclick = () => done(true); $('modalCancel').onclick = () => done(false);
    });
  }
  function msgs(list) { return list.map((m) => '<div class="msg ' + m.level + '">' + esc(m.text) + '</div>').join(''); }
  async function withBusy(btn, fn) {
    if (state.busy) { toast('Hay una operación en curso, esperá a que termine.'); return; }
    state.busy = true; const old = btn ? btn.textContent : ''; if (btn) { btn.disabled = true; btn.textContent = 'Trabajando...'; }
    try { await fn(); } catch (e) { toast(e.message || String(e), 6000); } finally {
      state.busy = false; if (btn) { btn.disabled = false; btn.textContent = old; }
    }
  }

  // ---------- registro ----------
  function addLog(e) {
    e.time = new Date(); state.logs.unshift(e); renderLog();
  }
  function renderLog() {
    const el = $('logList');
    if (!state.logs.length) { el.innerHTML = '<p class="hint">Todavía no se ejecutó nada.</p>'; return; }
    el.innerHTML = state.logs.map((e) => {
      const r = e.r || {};
      const status = e.ok ? '<span class="chip ok">OK</span>' : '<span class="chip err">Error</span>';
      const out = (r.Ok ? (r.Output || '') : (r.ErrorMessage || '')) + (r.HostKey ? '\n\n[huella SSH del servidor: ' + r.HostKey + ']' : '');
      return '<details class="log-item"><summary>' + status + '<b>' + esc(e.label) + '</b><span class="t">' + esc(e.host) + ' · ' +
        e.time.toLocaleTimeString() + (r.Ok ? ' · código ' + r.ExitCode : '') + '</span></summary><pre class="out">' + esc(out) + '</pre></details>';
    }).join('');
  }

  // ---------- servidores guardados ----------
  async function loadStore() {
    try { const s = await api('/api/store'); state.store = s && s.servers ? s : { servers: [] }; } catch (e) { state.store = { servers: [] }; }
    state.store.settings = state.store.settings || {};
    const st = state.store.settings;
    if (st.proxy && !$('pxUrl').value) { $('pxUrl').value = st.proxy; $('pxNo').value = st.noProxy || ''; }
    $('pxDefault').checked = !!st.proxy;
    updateProxyUi();
    renderServers();
  }
  async function saveStore() { try { await api('/api/store', JSON.stringify(state.store)); } catch (e) { toast('No se pudo guardar: ' + e.message); } }
  function serverKey(s) { return (s.user || '') + '@' + (s.host || ''); }
  function renderServers() {
    const f = $('serverFilter').value.toLowerCase();
    const cur = serverKey(conn());
    const list = state.store.servers.filter((s) => !f || JSON.stringify(s).toLowerCase().includes(f));
    $('serverList').innerHTML = list.length ? list.map((s, i) =>
      '<li data-i="' + state.store.servers.indexOf(s) + '" class="' + (serverKey(s) === cur ? 'active' : '') + '"><div><div class="s-name">' + esc(s.name || s.host) +
      '</div><div class="s-sub">' + esc(s.user + '@' + s.host) + (s.os ? ' · ' + esc(s.os) : '') + '</div></div><button class="del" title="Quitar" data-del="' + state.store.servers.indexOf(s) + '">✕</button></li>').join('')
      : '<li class="hint">Sin servidores guardados.</li>';
  }
  function upsertServer(extra) {
    const c = conn();
    if (!c.host) return;
    const idx = state.store.servers.findIndex((s) => serverKey(s) === serverKey(c) || (extra && extra.oldHost && s.host === extra.oldHost && s.user === c.user));
    const rec = Object.assign(idx >= 0 ? state.store.servers[idx] : {}, { name: $('cName').value.trim() || (idx >= 0 ? state.store.servers[idx].name : ''), host: c.host, port: c.port, user: c.user, updated: new Date().toISOString() });
    if (state.det) rec.os = state.det.OS_NAME;
    const px = LCT.normalizeProxy($('pxUrl').value);
    rec.proxy = px.error ? '' : LCT.stripProxyAuth(px.url); rec.noProxy = $('pxNo').value.trim();
    if (idx >= 0) state.store.servers[idx] = rec; else state.store.servers.unshift(rec);
    saveStore(); renderServers();
  }

  // ---------- proxy ----------
  function knownDomain() {
    const d = state.det || {};
    return ($('adDomain').value || $('jDomain').value || d.REALM_DOMAIN || d.AD_DOMAIN || (d.SEARCH || '').split(' ')[0] || '').trim();
  }
  function defaultNoProxy() { const dom = knownDomain(); return 'localhost,127.0.0.1' + (dom ? ',.' + dom : ''); }
  // Devuelve {url, no} o null (y avisa) si es invalido. required=true exige que haya proxy.
  function proxyVals(required) {
    const n = LCT.normalizeProxy($('pxUrl').value);
    if (n.error) { toast(n.error, 5000); $('pxUrl').classList.add('bad'); $('pxUrl').focus(); return null; }
    if (required && !n.url) { toast('Escribí la dirección del proxy (ej: http://proxy.empresa.local:8080).', 5000); $('pxUrl').focus(); return null; }
    if (n.url && (!$('pxNo').value.trim() || $('pxNo').value.trim() === 'localhost,127.0.0.1')) $('pxNo').value = defaultNoProxy();
    return { url: n.url, no: $('pxNo').value.trim().replace(/\s+/g, ''), hasAuth: n.hasAuth };
  }
  function updateProxyUi() {
    const n = LCT.normalizeProxy($('pxUrl').value);
    $('pxUrl').classList.toggle('bad', !!($('pxUrl').value.trim() && n.error));
    const has = !!n.url && !n.error;
    $('jPxRow').classList.toggle('hidden', !has);
    if (has) $('jPxLabel').innerHTML = 'Instalar los paquetes por el proxy <span class="mono">' + esc(LCT.maskProxy(n.url)) + '</span> y dejarlo configurado en el servidor';
  }
  function saveProxyDefault() {
    const st = state.store.settings = state.store.settings || {};
    if ($('pxDefault').checked) {
      const n = LCT.normalizeProxy($('pxUrl').value);
      if (n.error || !n.url) { $('pxDefault').checked = false; if (n.error) toast(n.error); else toast('Escribí primero la dirección del proxy.'); return; }
      st.proxy = LCT.stripProxyAuth(n.url); st.noProxy = $('pxNo').value.trim();
      if (n.hasAuth) toast('Guardado como predeterminado sin usuario/contraseña del proxy.', 5000); else toast('Proxy guardado como predeterminado.');
    } else { delete st.proxy; delete st.noProxy; }
    saveStore();
  }
  function renderProxyCurrent() {
    const d = state.det; if (!d) return;
    const cur = d.PROXY_CURRENT;
    $('pxCurrent').innerHTML = cur ? 'Proxy configurado hoy en el servidor: <span class="mono">' + esc(cur) + '</span>' : 'El servidor no tiene proxy configurado.';
    if (cur && !$('pxUrl').value.trim() && !cur.includes('***')) { $('pxUrl').value = cur; $('pxNo').value = d.PROXY_NO || ''; updateProxyUi(); }
  }

  async function proxyTest() {
    const px = proxyVals(true); if (!px) return;
    $('pxResult').innerHTML = msgs([{ level: 'info', text: 'Probando desde el servidor...' }]);
    const res = await runRemote('Probar proxy ' + LCT.maskProxy(px.url), 'proxy', { LCT_ACTION: 'test', LCT_PROXY: px.url, LCT_NOPROXY: px.no }, { asRoot: false, timeout: 120 });
    if (!res.ok) { $('pxResult').innerHTML = msgs([{ level: 'err', text: res.error }]); return; }
    const rows = res.r.Output.split(/\r?\n/).filter((l) => l.startsWith('TEST|')).map((l) => {
      const f = l.split('|'); return { url: f[1], d: LCT.reachInfo(f[2], f[3]), p: LCT.reachInfo(f[4], f[5]) };
    });
    const m = [], kv = res.kv;
    if (kv.PX_DNS === 'fail') m.push({ level: 'err', text: 'El servidor no resuelve el nombre del proxy "' + kv.PX_HOST + '" (DNS). Probá con la IP del proxy o revisá los DNS del servidor.' });
    else if (kv.PX_PORT === 'fail') m.push({ level: 'err', text: 'El servidor no puede conectarse al proxy ' + kv.PX_HOST + ' en ese puerto (puerto equivocado o firewall).' });
    const anyP = rows.some((r) => r.p.ok), anyD = rows.some((r) => r.d.ok), auth = rows.some((r) => r.p.auth);
    if (anyP) m.push({ level: 'ok', text: 'El proxy funciona: el servidor llega a internet a través de él. Ya podés instalar paquetes / unir al dominio, o dejarlo fijo con "Configurar en el servidor".' });
    else if (auth) m.push({ level: 'err', text: 'El proxy pide usuario y contraseña. Escribilo así: http://usuario:clave@proxy:puerto' });
    else if (anyD && !m.length) m.push({ level: 'warn', text: 'El servidor sale a internet directo, sin proxy; pero por el proxy no llega. Revisá la dirección.' });
    else if (!m.length) m.push({ level: 'err', text: 'Ni directo ni por el proxy llega a los repositorios.' });
    $('pxResult').innerHTML = msgs(m) + (rows.length ? '<table><thead><tr><th>Destino</th><th>Directo (sin proxy)</th><th>Por el proxy</th></tr></thead><tbody>' +
      rows.map((r) => '<tr><td class="mono">' + esc(r.url) + '</td><td class="' + (r.d.ok ? 'ok-t' : 'err-t') + '">' + esc(r.d.text) + '</td><td class="' + (r.p.ok ? 'ok-t' : 'err-t') + '">' + esc(r.p.text) + '</td></tr>').join('') + '</tbody></table>' : '');
  }
  async function proxyApply() {
    const px = proxyVals(true); if (!px) return;
    const ok = await confirmBox('Configurar el proxy en el servidor',
      '<p>Proxy: <b class="mono">' + esc(LCT.maskProxy(px.url)) + '</b><br>Sin proxy para: <span class="mono">' + esc(px.no) + '</span></p>' +
      '<p class="hint">Se configura en /etc/environment, sudo, apt / dnf / yum / zypper (según la distro), subscription-manager si registra contra Red Hat, y snap. Se guarda backup y se puede quitar con "Quitar del servidor".</p>' +
      (px.hasAuth ? '<div class="msg warn">La contraseña del proxy va a quedar en texto plano en esos archivos del servidor.</div>' : ''), 'Configurar');
    if (!ok) return;
    const res = await runRemote('Configurar proxy ' + LCT.maskProxy(px.url), 'proxy', { LCT_ACTION: 'apply', LCT_PROXY: px.url, LCT_NOPROXY: px.no }, { timeout: 120 });
    const out = res.ok ? res.r.Output.split(/\r?\n/).filter((l) => /^Proxy /.test(l)).map((t) => ({ level: 'ok', text: t })) : [{ level: 'err', text: res.error }];
    $('pxResult').innerHTML = msgs(out.concat(res.kv.notes.map((t) => ({ level: 'info', text: t }))));
    if (res.ok) { try { await detect(true); } catch (e) { /* ignore */ } }
  }
  async function proxyRemove() {
    const ok = await confirmBox('Quitar el proxy del servidor', '<p>Se quita la configuración de proxy que puso esta herramienta y se restaura la anterior.</p>', 'Quitar');
    if (!ok) return;
    const res = await runRemote('Quitar proxy', 'proxy', { LCT_ACTION: 'remove' }, { timeout: 120 });
    $('pxResult').innerHTML = msgs([res.ok ? { level: 'ok', text: 'Proxy quitado del servidor.' } : { level: 'err', text: res.error }]);
    if (res.ok) { try { await detect(true); } catch (e) { /* ignore */ } }
  }

  // ---------- conexion y deteccion ----------
  async function detect(quiet) {
    let res = await runRemote('Detectar servidor', 'detect', {}, { timeout: 60 });
    let limited = false;
    if (!res.ok && res.r && res.r.Ok) {
      // sudo fallo: probar sin privilegios para al menos ver la red
      const sudoErr = res.error;
      res = await runRemote('Detectar servidor (sin sudo)', 'detect', {}, { asRoot: false, timeout: 60 });
      limited = sudoErr;
    }
    if (!res.ok) { chip('Error', 'err'); throw new Error(res.error); }
    state.det = LCT.parseDetect(res.r.Output);
    state.det.limited = limited;
    state.connectedHost = conn().host;
    state.passwords[serverKey(conn())] = conn().password;
    chip(limited ? 'Conectado (sin sudo)' : 'Conectado', limited ? 'warn' : 'ok');
    renderDetect(); renderAdStatus(); fillIfaces(); renderProxyCurrent();
    $('adDomain').value = $('adDomain').value || state.det.REALM_DOMAIN || state.det.AD_DOMAIN || '';
    $('jDomain').value = $('jDomain').value || state.det.REALM_DOMAIN || (state.det.SEARCH || '').split(' ')[0] || '';
    $('conDistro').value = LCT.distroFromDetect(state.det, ipIface());
    renderConsole();
    if (limited && !quiet) toast(limited, 7000);
    return state.det;
  }

  function renderDetect() {
    const d = state.det; if (!d) return;
    const gwIf = d.ifaces.find((i) => i.name === d.GW_DEV) || d.ifaces[0] || {};
    const beName = { nm: 'NetworkManager', netplan: 'netplan', ifupdown: 'ifupdown', ifcfg: 'network-scripts (ifcfg)', wicked: 'wicked', unknown: 'desconocido' };
    const facts = [
      ['Sistema', d.OS_NAME], ['Hostname', d.FQDN || d.HOSTNAME], ['Gestor de red', beName[gwIf.backend] || gwIf.backend || '-'],
      ['Gateway', d.GW || '-'], ['DNS', d.DNS || '-'], ['Active Directory', adJoined(d) ? 'Unido a ' + adDomainOf(d) : (d.AD_METHOD === 'centrify' || d.AD_METHOD === 'winbind') ? d.AD_METHOD + ': ' + d.AD_DOMAIN : 'No unido'],
    ];
    let html = (d.limited ? '<div class="msg warn">' + esc(d.limited) + ' Solo se muestra información básica.</div>' : '') +
      '<div class="facts">' + facts.map((f) => '<div class="fact"><small>' + f[0] + '</small><b>' + esc(f[1]) + '</b></div>').join('') + '</div>';
    html += '<table><thead><tr><th>Interfaz</th><th>Estado</th><th>IP actual</th><th>Tipo</th><th>MAC</th><th>Perfil</th></tr></thead><tbody>' +
      d.ifaces.map((i) => '<tr class="pick" data-if="' + esc(i.name) + '" title="Click para usar esta interfaz"><td class="mono"><b>' + esc(i.name) + '</b>' + (i.name === d.GW_DEV ? ' <span class="chip">principal</span>' : '') + '</td><td>' + esc(i.state) +
        '</td><td class="mono">' + esc(i.addrs.join(', ') || '-') + '</td><td>' + (i.method === 'dhcp' ? '<span class="chip warn">DHCP</span>' : i.method === 'static' ? '<span class="chip ok">Fija</span>' : '-') +
        '</td><td class="mono">' + esc(i.mac) + '</td><td>' + esc(i.conn || '') + '</td></tr>').join('') + '</tbody></table>';
    $('detectBox').innerHTML = html; $('detectBox').classList.remove('hidden');
  }

  function fillIfaces() {
    const sel = $('ipIface'), d = state.det;
    if (!d || !d.ifaces.length) { sel.classList.add('hidden'); $('ipIfaceText').classList.remove('hidden'); return; }
    const prev = sel.value;
    sel.innerHTML = d.ifaces.map((i) => '<option value="' + esc(i.name) + '">' + esc(i.name) + (i.addrs.length ? ' — ' + esc(i.addrs[0]) : '') + (i.method === 'dhcp' ? ' (DHCP)' : '') + '</option>').join('') + '<option value="__other">Otra (escribir)...</option>';
    sel.value = d.ifaces.some((i) => i.name === prev) ? prev : (d.GW_DEV && d.ifaces.some((i) => i.name === d.GW_DEV) ? d.GW_DEV : d.ifaces[0].name);
    sel.classList.remove('hidden'); $('ipIfaceText').classList.add('hidden');
    validateIpForm();
  }
  function ipIface() {
    const sel = $('ipIface');
    if (sel.classList.contains('hidden') || sel.value === '__other' || !sel.value) return $('ipIfaceText').value.trim();
    return sel.value;
  }

  // ---------- IP fija ----------
  function ipParams() {
    return {
      iface: ipIface(), ip: $('ipAddr').value.trim(), prefix: parseInt($('ipMask').value, 10), gw: $('ipGw').value.trim(),
      dns: [$('ipDns1').value.trim(), $('ipDns2').value.trim()].filter(Boolean), search: $('ipSearch').value.trim(), hostname: $('ipHostname').value.trim(),
    };
  }
  function validateIpForm() {
    const p = ipParams(), m = LCT.validateIp(p);
    [['ipAddr', p.ip && !LCT.isIp(p.ip)], ['ipGw', p.gw && !LCT.isIp(p.gw)], ['ipDns1', $('ipDns1').value && !LCT.isIp($('ipDns1').value.trim())],
      ['ipDns2', $('ipDns2').value && !LCT.isIp($('ipDns2').value.trim())]].forEach(([id, bad]) => $(id).classList.toggle('bad', !!bad));
    if (LCT.isIp(p.ip) && p.prefix && !m.some((x) => x.level === 'err')) {
      const net = LCT.intToIp(LCT.networkOf(p.ip, p.prefix));
      m.unshift({ level: 'info', text: 'Red: ' + net + '/' + p.prefix + ' (máscara ' + LCT.prefixToMask(p.prefix) + ')' });
    }
    const cur = state.connectedHost;
    if (cur && LCT.isIp(p.ip) && p.ip !== cur && state.det) {
      const i = state.det.ifaces.find((x) => x.name === p.iface);
      if (i && i.addrs.some((a) => a.split('/')[0] === cur)) m.push({ level: 'info', text: 'Te conectaste por esta interfaz: la sesión SSH se va a cortar y la app se reconecta sola a ' + p.ip + '.' });
    }
    $('ipValidation').innerHTML = msgs(m.filter((x) => p.ip || x.level !== 'err'));
    renderConsole();
    return m;
  }
  function fillCurrent() {
    const d = state.det; if (!d) { toast('Primero conectá el servidor.'); return; }
    const i = d.ifaces.find((x) => x.name === ipIface()); if (!i || !i.addrs.length) { toast('Esa interfaz no tiene IP actual.'); return; }
    const [ip, pfx] = i.addrs[0].split('/');
    $('ipAddr').value = ip; $('ipMask').value = pfx || '24';
    if (d.GW && (!d.GW_DEV || d.GW_DEV === i.name)) $('ipGw').value = d.GW;
    const dns = (d.DNS || '').split(/\s+/).filter((x) => LCT.isIp(x) && !x.startsWith('127.'));
    $('ipDns1').value = dns[0] || ''; $('ipDns2').value = dns[1] || '';
    if (d.SEARCH) $('ipSearch').value = d.SEARCH;
    validateIpForm(); toast('Valores actuales cargados. Cambiá lo que necesites.');
  }

  function progress(steps) {
    const el = $('ipProgress'); el.classList.remove('hidden');
    el.innerHTML = steps.map((s, i) => '<li id="pg' + i + '"><div>' + esc(s) + '<small></small></div></li>').join('');
    return (i, cls, note) => { const li = $('pg' + i); if (!li) return; li.className = cls; if (note !== undefined) li.querySelector('small').textContent = note; };
  }

  async function applyIp() {
    const p = ipParams(), errs = LCT.validateIp(p).filter((m) => m.level === 'err');
    if (errs.length) { $('ipValidation').innerHTML = msgs(errs); toast('Corregí los datos marcados.'); return; }
    const c = conn(); if (!c.host || !c.user || !c.password) { toast('Completá servidor, usuario y contraseña (paso 1).'); return; }
    const rbOn = $('ipRollback').checked, rbSecs = Math.max(30, parseInt($('ipRollbackSecs').value, 10) || 120);
    const cur = state.det && state.det.ifaces.find((i) => i.name === p.iface);
    const row = (k, a, b) => '<div>' + k + '</div><div>' + esc(a || '-') + '</div><div class="new">' + esc(b || '-') + '</div>';
    const ok = await confirmBox('Aplicar IP fija en ' + (state.det ? state.det.HOSTNAME : c.host),
      '<div class="cmp"><div class="h"></div><div class="h">Actual</div><div class="h">Nueva</div>' +
      row('Interfaz', p.iface, p.iface) + row('IP', cur ? cur.addrs.join(', ') : '', p.ip + '/' + p.prefix) + row('Gateway', state.det && state.det.GW, p.gw) +
      row('DNS', state.det && state.det.DNS, p.dns.join(' ')) + (p.hostname ? row('Hostname', state.det && state.det.HOSTNAME, p.hostname) : '') + '</div>' +
      '<p class="hint">' + (rbOn ? 'Si en ' + rbSecs + ' s la app no logra conectarse a ' + esc(p.ip) + ', el servidor vuelve solo a la configuración anterior.' : '<b>Sin rollback automático:</b> si algo sale mal vas a necesitar la consola del servidor.') + '</p>', 'Aplicar');
    if (!ok) return;

    const step = progress(['Respaldar y preparar la configuración', 'Aplicar la IP nueva', 'Reconectar con ' + p.ip, 'Confirmar el cambio']);
    step(0, 'run');
    const vars = { LCT_IFACE: p.iface, LCT_IP: p.ip, LCT_PREFIX: String(p.prefix), LCT_GW: p.gw, LCT_DNS: p.dns.join(' '), LCT_SEARCH: p.search,
      LCT_HOSTNAME: p.hostname, LCT_ROLLBACK_SECS: String(rbOn ? rbSecs : 0), LCT_PHASE: 'stage' };
    const st = await runRemote('IP fija ' + p.iface + ' → ' + p.ip + '/' + p.prefix, 'ip', vars, { timeout: 120 });
    if (!st.ok) { step(0, 'fail', st.error); throw new Error(st.error); }
    const t0 = Date.now();
    step(0, 'done', 'Backend: ' + (st.kv.BACKEND || '?') + ' · backup en ' + (st.kv.LCT_BACKUP || ''));
    step(1, 'run', 'Aplicando...');
    await sleep(5000);
    step(1, 'done');
    step(2, 'run', 'Esperando que ' + p.ip + ' responda por SSH...');
    const deadline = t0 + (rbOn ? (rbSecs - 12) * 1000 : 180000);
    let confirmed = null;
    while (Date.now() < deadline) {
      const pr = await api('/api/probe', { host: p.ip, port: c.port, timeoutMs: 2000 });
      if (pr.open) {
        step(2, 'done'); step(3, 'run', 'Confirmando...');
        const cf = await runRemote('Confirmar IP en ' + p.ip, 'ip', { LCT_PHASE: 'confirm' }, { host: p.ip, timeout: 60 });
        if (cf.ok) { confirmed = cf; break; }
      }
      step(2, 'run', 'Esperando que ' + p.ip + ' responda por SSH... (' + Math.round((deadline - Date.now()) / 1000) + ' s)');
      await sleep(2500);
    }
    if (confirmed && confirmed.kv.STATUS === 'CONFIRMED') {
      step(3, 'done', 'Listo. El servidor quedó con IP fija ' + p.ip + '/' + p.prefix);
      const oldHost = c.host;
      $('cHost').value = p.ip;
      if (state.store.servers.some((s) => s.host === oldHost && s.user === c.user)) upsertServer({ oldHost });
      toast('IP fija aplicada y confirmada.', 5000);
      try { await detect(true); } catch (e) { /* no critico */ }
    } else if (confirmed) {
      step(3, 'fail', 'Estado: ' + (confirmed.kv.STATUS || 'desconocido') + '. Mirá el detalle en Registro.');
    } else {
      step(2, 'fail', 'No pude conectarme a ' + p.ip + ' desde esta PC.');
      if (rbOn) {
        step(3, 'run', 'El servidor vuelve a la configuración anterior. Verificando en ' + c.host + '...');
        const until = t0 + (rbSecs + 60) * 1000;
        await sleep(Math.max(0, t0 + rbSecs * 1000 + 5000 - Date.now()));
        let back = false;
        while (Date.now() < until) {
          const pr = await api('/api/probe', { host: c.host, port: c.port, timeoutMs: 2000 });
          if (pr.open) {
            const s = await runRemote('Estado del cambio de IP', 'ip', { LCT_PHASE: 'status' }, { timeout: 30 });
            if (s.ok) { back = true; step(3, s.kv.STATUS === 'ROLLED_BACK' ? 'done' : 'fail', 'Estado: ' + s.kv.STATUS + (s.kv.STATUS === 'ROLLED_BACK' ? ' — se restauró la configuración anterior, no cambió nada.' : '')); break; }
          }
          await sleep(3000);
        }
        if (!back) step(3, 'fail', 'Tampoco responde la IP anterior. Revisá por consola: sudo bash /var/lib/linuxconfigtool/ipjob.sh status');
      } else {
        step(3, 'fail', 'Sin rollback automático. Verificá por consola. Para deshacer: sudo bash /var/lib/linuxconfigtool/ipjob.sh rollback');
      }
    }
  }

  // ---------- AD ----------
  function adGroups() { return $('adGroup').value.split(/[,;\n]/).map((s) => s.trim()).filter(Boolean); }
  function adAccess() { const r = document.querySelector('input[name="adAccess"]:checked'); return r ? r.value : 'login'; }
  function adBaseVars() { return { LCT_DOMAIN: $('adDomain').value.trim(), LCT_EXPECTED_GID: $('adGid').value.trim(), LCT_ACCESS: adAccess() }; }

  function adJoined(d) { d = d || state.det; return !!d && (d.REALM_JOINED === 'yes' || d.AD_METHOD === 'realm' || d.AD_METHOD === 'sssd'); }
  function adDomainOf(d) { return d.REALM_DOMAIN || d.AD_DOMAIN || ''; }

  function renderAdStatus() {
    const d = state.det, el = $('adStatus');
    if (!d) return;
    if (d.AD_METHOD === 'centrify' || d.AD_METHOD === 'winbind') {
      el.innerHTML = '<div class="msg warn">Este servidor ya está integrado a <b>' + esc(d.AD_DOMAIN) + '</b> con <b>' + (d.AD_METHOD === 'centrify' ? 'Centrify / Delinea' : 'Samba winbind') +
        '</b>. Esta herramienta gestiona el acceso con realmd/SSSD; con ' + (d.AD_METHOD === 'centrify' ? 'Centrify el acceso se da desde las zonas en AD' : 'winbind se usa require_membership_of en pam_winbind') + '. No lo unas de nuevo.</div>';
      $('joinBox').open = false;
      return;
    }
    if (!adJoined(d)) {
      const miss = d.AD_PKGS_MISSING;
      el.innerHTML = '<div class="msg warn"><b>Este servidor no está unido al dominio</b>, por eso Linux todavía no conoce a los usuarios ni grupos de AD. ' +
        'Para que los usuarios del grupo puedan entrar hay que unirlo una vez (abajo). Unirlo <b>no</b> le da acceso a nadie: después se habilitan solo los grupos que indiques.</div>' +
        '<div class="msg ' + (miss ? 'info' : 'ok') + '">' + (miss ? 'Paquetes que faltan en el servidor: <b>' + esc(miss) + '</b>. Se instalan al unir (de los repositorios, o del ISO/DVD de instalación si la VM lo tiene conectado).' : 'Los paquetes necesarios (realmd, sssd, adcli) ya están instalados.') + '</div>';
      $('joinBox').open = true;
      return;
    }
    $('joinBox').open = false;
    if (!d.REALM_DOMAIN) d.REALM_DOMAIN = d.AD_DOMAIN;
    const policy = { 'allow-realm-logins': 'Todos los usuarios del dominio pueden entrar', 'allow-any-login': 'Cualquier usuario puede entrar', 'allow-permitted-logins': 'Solo usuarios/grupos permitidos', 'deny-any-login': 'Nadie del dominio puede entrar' };
    const idmapAuto = (d.SSSD_IDMAP || 'true') !== 'false';
    el.innerHTML =
      '<div class="facts"><div class="fact"><small>Dominio</small><b>' + esc(d.REALM_DOMAIN) + '</b></div>' +
      '<div class="fact"><small>Política de login</small><b>' + esc(policy[d.REALM_POLICY] || d.REALM_POLICY || '-') + '</b></div>' +
      '<div class="fact"><small>UID/GID</small><b>' + (idmapAuto ? 'Automáticos de SSSD' : 'Los de AD (uidNumber/gidNumber)') + '</b></div>' +
      '<div class="fact"><small>Nombres</small><b>' + (d.SSSD_FQN === 'true' ? 'usuario@dominio' : 'usuario (corto)') + '</b></div></div>' +
      '<div><small class="hint">Grupos con acceso (click en ✕ para quitar):</small><div class="chips">' +
      (d.groups.length ? d.groups.map((g) => '<span class="gchip">' + esc(g) + (hasSudo(g) ? ' · sudo' : '') + '<button data-rm="' + esc(g) + '" title="Quitar acceso">✕</button></span>').join('') : '<span class="hint">ninguno</span>') + '</div></div>' +
      (d.sudo.length ? '<div><small class="hint">Reglas sudo con grupos:</small><div class="out">' + esc(d.sudo.map((s) => s.rule + '    # ' + s.file).join('\n')) + '</div></div>' : '') +
      (idmapAuto ? '<div class="msg info">Si sus grupos de AD tienen un GID unix definido y querés que Linux use ese mismo número, activá <button class="small" id="btnIdmap">Usar UID/GID de AD</button></div>' : '');
    const b = $('btnIdmap'); if (b) b.onclick = () => withBusy(b, idmapOff);
  }
  function hasSudo(g) {
    const n = g.toLowerCase().replace(/\\ /g, ' ');
    return state.det.sudo.some((s) => s.rule.toLowerCase().replace(/\\ /g, ' ').startsWith('%' + n + ' '));
  }

  async function adVerify() {
    const groups = adGroups(); if (!groups.length) { toast('Escribí el nombre del grupo.'); return; }
    const rows = [];
    for (const g of groups) {
      const res = await runRemote('Verificar grupo ' + g, 'ad', Object.assign(adBaseVars(), { LCT_ACTION: 'verify', LCT_GROUP: g }), { timeout: 60 });
      rows.push({ g, res });
    }
    $('adResult').innerHTML = '<table><thead><tr><th>Grupo</th><th>Nombre en Linux</th><th>GID</th><th>Miembros</th><th></th></tr></thead><tbody>' +
      rows.map(({ g, res }) => res.ok
        ? '<tr><td>' + esc(g) + '</td><td class="mono">' + esc(res.kv.GROUP_NAME) + '</td><td class="mono">' + esc(res.kv.GROUP_GID) + '</td><td>' + esc((res.kv.GROUP_MEMBERS || '').split(',').filter(Boolean).length) + '</td><td>' +
          (res.kv.GID_MATCH === 'no' ? '<span class="chip warn">GID distinto</span>' : res.kv.GID_MATCH === 'yes' ? '<span class="chip ok">GID OK</span>' : '<span class="chip ok">Encontrado</span>') + '</td></tr>'
        : '<tr><td>' + esc(g) + '</td><td colspan="4"><span class="chip err">No encontrado</span> ' + esc(res.error) + '</td></tr>').join('') + '</tbody></table>' +
      msgs([].concat(...rows.map((x) => (x.res.kv.warns || []).map((w) => ({ level: 'warn', text: w })))));
  }

  const ACC_TXT = { login: 'Solo iniciar sesión', sudo: 'Administrador (sudo)', 'sudo-nopasswd': 'Administrador sin contraseña (sudo NOPASSWD)' };
  function details(list) { return list && list.length ? '<pre class="out">' + esc(list.join('\n')) + '</pre>' : ''; }

  async function grantGroups(groups) {
    const acc = adAccess(), out = [], det = [];
    for (const g of groups) {
      const res = await runRemote('Dar acceso a ' + g + ' (' + acc + ')', 'ad', Object.assign(adBaseVars(), { LCT_ACTION: 'add', LCT_GROUP: g }), { timeout: 120 });
      out.push(res.ok ? { level: 'ok', text: g + ': acceso otorgado (' + ACC_TXT[acc] + ') — en Linux: ' + res.kv.GROUP_NAME + ', GID ' + res.kv.GROUP_GID } : { level: 'err', text: g + ': ' + res.error });
      (res.kv.warns || []).forEach((w) => out.push({ level: 'warn', text: w }));
      (res.kv.notes || []).forEach((w) => out.push({ level: 'info', text: w }));
      (res.kv.details || []).forEach((x) => det.push(x));
    }
    return { out, det };
  }

  async function adAdd() {
    const groups = adGroups(); if (!groups.length) { toast('Escribí el nombre del grupo.'); return; }
    const d = state.det;
    if (d && !adJoined(d)) {
      $('joinBox').open = true;
      if (!$('jDomain').value) $('jDomain').value = $('adDomain').value;
      $('adResult').innerHTML = msgs([{ level: 'info', text: 'Primero hay que unir el servidor al dominio. Completá usuario y contraseña de AD en "Unir el servidor al dominio" (abajo) y apretá "Unir al dominio": al terminar se habilita automáticamente ' + groups.join(', ') + ' con el nivel elegido.' }]);
      $(!$('jUser').value ? 'jUser' : 'jPass').focus();
      return;
    }
    const acc = adAccess();
    let warn = '';
    if (d && (d.REALM_POLICY === 'allow-realm-logins' || d.REALM_POLICY === 'allow-any-login')) warn = '<div class="msg warn">Hoy <b>todos</b> los usuarios del dominio pueden entrar a este servidor. Al agregar grupos, solo entrarán los grupos permitidos.</div>';
    const ok = await confirmBox('Dar acceso', '<p>Grupos: <b>' + esc(groups.join(', ')) + '</b><br>Nivel: <b>' + esc(ACC_TXT[acc]) + '</b></p>' + warn, 'Dar acceso');
    if (!ok) return;
    const r = await grantGroups(groups);
    $('adResult').innerHTML = msgs(r.out) + details(r.det);
    try { await detect(true); } catch (e) { /* ignore */ }
  }

  async function adRemove(g) {
    const ok = await confirmBox('Quitar acceso', '<p>Se quita el login y las reglas sudo del grupo <b>' + esc(g) + '</b> en este servidor.</p>', 'Quitar');
    if (!ok) return;
    const res = await runRemote('Quitar acceso a ' + g, 'ad', { LCT_ACTION: 'remove', LCT_GROUP: g, LCT_DOMAIN: $('adDomain').value.trim() }, { timeout: 120 });
    $('adResult').innerHTML = msgs([res.ok ? { level: 'ok', text: 'Acceso quitado a ' + g } : { level: 'err', text: res.error }].concat((res.kv.notes || []).map((n) => ({ level: 'info', text: n }))));
    try { await detect(true); } catch (e) { /* ignore */ }
  }

  async function idmapOff() {
    const ok = await confirmBox('Usar UID/GID de Active Directory',
      '<div class="msg warn">Linux va a usar los <b>uidNumber/gidNumber</b> definidos en AD en lugar de generarlos. Cambia los UID/GID de <b>todos</b> los usuarios de dominio en este servidor: los usuarios sin uidNumber no podrán entrar y los archivos que ya tengan pueden quedar con otro dueño.</div><p>Se guarda backup de sssd.conf.</p>', 'Cambiar');
    if (!ok) return;
    const res = await runRemote('Desactivar ID mapping (usar GID de AD)', 'ad', { LCT_ACTION: 'idmap-off' }, { timeout: 120 });
    $('adResult').innerHTML = msgs([res.ok ? { level: 'ok', text: 'Listo: SSSD usa los UID/GID de AD.' } : { level: 'err', text: res.error }]);
    try { await detect(true); } catch (e) { /* ignore */ }
  }

  async function adJoin() {
    const dom = $('jDomain').value.trim(), user = $('jUser').value.trim(), pass = $('jPass').value;
    if (!dom || !user || !pass) { toast('Completá dominio, usuario y contraseña de AD.'); return; }
    const groups = adGroups(), acc = adAccess();
    const px = proxyVals(false); if (!px) return;
    const ok = await confirmBox('Unir al dominio', '<p>Servidor: <b>' + esc(conn().host) + '</b><br>Dominio: <b>' + esc(dom) + '</b><br>Usuario AD: <b>' + esc(user) + '</b>' +
      ($('jOu').value ? '<br>OU: <b>' + esc($('jOu').value) + '</b>' : '') + (px.url ? '<br>Proxy: <b class="mono">' + esc(LCT.maskProxy(px.url)) + '</b>' + ($('jPxSave').checked ? ' (queda configurado)' : ' (solo para instalar)') : '') + '</p>' +
      (groups.length ? '<div class="msg info">Al terminar se habilita: <b>' + esc(groups.join(', ')) + '</b> (' + esc(ACC_TXT[acc]) + ')</div>' : '<div class="msg warn">No cargaste ningún grupo arriba: después de unir nadie del dominio va a poder entrar hasta que agregues uno.</div>') +
      '<p class="hint">Puede tardar unos minutos si hay que instalar paquetes.</p>', 'Unir');
    if (!ok) return;
    $('adResult').innerHTML = '<div class="msg info">Uniendo al dominio... (si hay que instalar paquetes puede tardar varios minutos)</div>';
    const b64 = btoa(unescape(encodeURIComponent(pass)));
    const res = await runRemote('Unir al dominio ' + dom, 'ad', { LCT_ACTION: 'join', LCT_DOMAIN: dom, LCT_ADUSER: user, LCT_ADPASS_B64: b64, LCT_OU: $('jOu').value.trim(),
      LCT_INSTALL: $('jInstall').checked ? '1' : '0', LCT_IDMAP_OFF: $('jIdmap').checked ? '1' : '0', LCT_SHORTNAMES: $('jShort').checked ? '1' : '0',
      LCT_PROXY: px.url, LCT_NOPROXY: px.no, LCT_PROXY_SAVE: px.url && $('jPxSave').checked ? '1' : '0' }, { timeout: 1200 });
    $('jPass').value = '';
    let html = msgs([res.ok ? { level: 'ok', text: 'Servidor unido a ' + dom + '.' } : { level: 'err', text: res.error }]
      .concat((res.kv.warns || []).map((w) => ({ level: 'warn', text: w })), (res.kv.notes || []).map((w) => ({ level: 'info', text: w })))) + details(res.kv.details);
    $('adResult').innerHTML = html;
    if (!res.ok) return;
    $('adDomain').value = dom;
    if (groups.length) {
      $('adResult').innerHTML = html + msgs([{ level: 'info', text: 'Habilitando ' + groups.join(', ') + '...' }]);
      const r = await grantGroups(groups);
      html += msgs(r.out) + details(r.det);
      if (r.out.some((m) => m.level === 'ok')) html += msgs([{ level: 'ok', text: 'Listo: los usuarios de ' + groups.join(', ') + ' ya pueden entrar con su usuario' + ($('jShort').checked ? '' : '@' + dom) + ' y contraseña de AD.' }]);
    } else {
      html += msgs([{ level: 'info', text: 'Ahora escribí el grupo arriba y apretá "Dar acceso".' }]);
    }
    $('adResult').innerHTML = html;
    try { await detect(true); } catch (e) { /* ignore */ }
    $('adResult').innerHTML = html;
  }

  // ---------- comandos para consola ----------
  async function renderConsole() {
    const dk = $('conDistro').value || 'rhel8', task = $('conTask').value;
    let code = '', title = '';
    try {
      if (task === 'ip') {
        const p = ipParams();
        if (!p.ip) p.ip = '<IP>';
        title = 'IP fija';
        if (dk === 'auto') {
          const s = await buildScript('ip', { LCT_IFACE: p.iface || 'eth0', LCT_IP: p.ip, LCT_PREFIX: String(p.prefix || 24), LCT_GW: p.gw, LCT_DNS: p.dns.join(' '),
            LCT_SEARCH: p.search, LCT_HOSTNAME: p.hostname, LCT_ROLLBACK_SECS: '0', LCT_PHASE: 'stage' });
          code = '# Guardá esto como ipfija.sh en el servidor y ejecutá:  sudo bash ipfija.sh\n# Detecta la distro y el gestor de red, hace backup y aplica la IP.\n# Para deshacer:  sudo bash /var/lib/linuxconfigtool/ipjob.sh rollback\n\n' + s;
        } else code = LCT.ipCommands(dk, p);
      } else if (task === 'ad') {
        title = 'Acceso por grupos AD';
        code = LCT.adCommands({ groups: adGroups(), domain: $('adDomain').value.trim(), access: adAccess(), gid: $('adGid').value.trim() });
      } else if (task === 'join') {
        title = 'Unir al dominio';
        code = LCT.joinCommands(dk, { domain: $('jDomain').value.trim(), user: $('jUser').value.trim(), ou: $('jOu').value.trim(), idmap: $('jIdmap').checked,
          shortnames: $('jShort').checked, groups: adGroups(), access: adAccess(), proxy: LCT.normalizeProxy($('pxUrl').value).url, noProxy: $('pxNo').value.trim() });
      } else if (task === 'proxy') {
        title = 'Proxy de internet';
        code = LCT.proxyCommands(dk, { url: LCT.normalizeProxy($('pxUrl').value).url, no: $('pxNo').value.trim() || defaultNoProxy() });
      } else {
        title = 'Usar UID/GID de AD';
        code = LCT.idmapCommands(false);
      }
    } catch (e) { code = '# Error: ' + e.message; }
    $('conTitle').textContent = title + ' · ' + LCT.distro(dk).n;
    $('conCode').textContent = code;
  }
  function showConsole(task) {
    $('conTask').value = task;
    if (state.det) $('conDistro').value = LCT.distroFromDetect(state.det, ipIface());
    switchTab('console'); renderConsole();
  }
  async function copyCode() {
    const t = $('conCode').textContent;
    try { await navigator.clipboard.writeText(t); } catch (e) {
      const ta = document.createElement('textarea'); ta.value = t; document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove();
    }
    toast('Copiado al portapapeles.');
  }
  function downloadCode() {
    const blob = new Blob([$('conCode').textContent.replace(/\r\n/g, '\n') + '\n'], { type: 'text/x-sh' });
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = $('conTask').value + '-' + $('conDistro').value + '.sh'; a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
  }

  // ---------- tabs / tema ----------
  function switchTab(name) {
    document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === name));
    document.querySelectorAll('.tab-panel').forEach((p) => p.classList.toggle('hidden', p.id !== 'tab-' + name));
    if (name === 'console') renderConsole();
  }
  function applyTheme(t) { if (t) document.documentElement.setAttribute('data-theme', t); else document.documentElement.removeAttribute('data-theme'); }

  // ---------- init ----------
  function init() {
    $('ver').textContent = 'v' + window.LCT_VERSION;
    const ms = $('ipMask');
    for (let p = 32; p >= 8; p--) { const o = document.createElement('option'); o.value = p; o.textContent = '/' + p + '  —  ' + LCT.prefixToMask(p); ms.appendChild(o); }
    ms.value = '24';
    $('conDistro').innerHTML = LCT.DISTROS.map((d) => '<option value="' + d.k + '">' + esc(d.n) + '</option>').join('');
    $('conDistro').value = 'rhel8';

    document.querySelectorAll('.eye').forEach((b) => b.onclick = () => { const i = $(b.dataset.for); i.type = i.type === 'password' ? 'text' : 'password'; });
    document.querySelectorAll('.tab').forEach((t) => t.onclick = () => switchTab(t.dataset.tab));
    $('btnConnect').onclick = () => withBusy($('btnConnect'), async () => { chip('Conectando...', 'busy'); await detect(false); upsertServer(); });
    $('btnSave').onclick = () => { if (!conn().host) { toast('Completá la IP del servidor.'); return; } upsertServer(); toast('Servidor guardado (sin contraseña).'); };
    $('btnNewServer').onclick = () => { ['cName', 'cHost', 'cUser', 'cPass'].forEach((id) => $(id).value = ''); $('cPort').value = 22; state.det = null; state.connectedHost = null;
      const st = state.store.settings || {}; $('pxUrl').value = st.proxy || ''; $('pxNo').value = st.proxy ? (st.noProxy || '') : ''; $('pxResult').innerHTML = ''; $('pxCurrent').textContent = ''; updateProxyUi();
      $('detectBox').classList.add('hidden'); chip('Sin conectar'); renderServers(); $('cHost').focus(); };
    $('serverFilter').oninput = renderServers;
    $('pxUrl').addEventListener('input', () => { updateProxyUi(); if (!$('tab-console').classList.contains('hidden')) renderConsole(); });
    $('pxUrl').addEventListener('blur', () => { const n = LCT.normalizeProxy($('pxUrl').value); if (n.url && !n.error) { $('pxUrl').value = n.url; if (!$('pxNo').value.trim()) $('pxNo').value = defaultNoProxy(); } updateProxyUi(); if ($('pxDefault').checked) saveProxyDefault(); });
    $('pxNo').addEventListener('change', () => { if ($('pxDefault').checked) saveProxyDefault(); });
    $('pxDefault').addEventListener('change', saveProxyDefault);
    $('btnPxTest').onclick = () => withBusy($('btnPxTest'), proxyTest);
    $('btnPxApply').onclick = () => withBusy($('btnPxApply'), proxyApply);
    $('btnPxRemove').onclick = () => withBusy($('btnPxRemove'), proxyRemove);
    $('serverList').onclick = async (e) => {
      const del = e.target.closest('[data-del]');
      if (del) { e.stopPropagation(); const s = state.store.servers[+del.dataset.del];
        if (await confirmBox('Quitar servidor', '<p>¿Quitar <b>' + esc(s.name || s.host) + '</b> de la lista?</p>', 'Quitar')) { state.store.servers.splice(+del.dataset.del, 1); saveStore(); renderServers(); } return; }
      const li = e.target.closest('li[data-i]'); if (!li) return;
      const s = state.store.servers[+li.dataset.i];
      $('cName').value = s.name || ''; $('cHost').value = s.host; $('cPort').value = s.port || 22; $('cUser').value = s.user || '';
      $('cPass').value = state.passwords[serverKey(s)] || '';
      const st = state.store.settings || {};
      $('pxUrl').value = s.proxy || st.proxy || ''; $('pxNo').value = s.proxy ? (s.noProxy || '') : (st.noProxy || '');
      $('pxResult').innerHTML = ''; $('pxCurrent').textContent = ''; updateProxyUi();
      state.det = null; state.connectedHost = null; $('detectBox').classList.add('hidden'); chip('Sin conectar'); renderServers();
      (s.user && !$('cPass').value ? $('cPass') : $('btnConnect')).focus();
    };
    $('cPass').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('btnConnect').click(); });
    $('detectBox').onclick = (e) => { const tr = e.target.closest('tr[data-if]'); if (!tr) return; $('ipIface').value = tr.dataset.if; switchTab('ip'); validateIpForm(); };

    ['ipAddr', 'ipGw', 'ipDns1', 'ipDns2', 'ipSearch', 'ipHostname', 'ipIfaceText'].forEach((id) => $(id).addEventListener('input', validateIpForm));
    ['ipMask'].forEach((id) => $(id).addEventListener('change', validateIpForm));
    $('ipIface').addEventListener('change', () => { $('ipIfaceText').classList.toggle('hidden', $('ipIface').value !== '__other'); validateIpForm(); });
    $('ipAddr').addEventListener('blur', () => { const v = $('ipAddr').value.trim(); const m = v.match(/^(.+)\/(\d+)$/); if (m && LCT.isIp(m[1])) { $('ipAddr').value = m[1]; $('ipMask').value = m[2]; validateIpForm(); } });
    $('btnFillCurrent').onclick = fillCurrent;
    $('btnApplyIp').onclick = () => withBusy($('btnApplyIp'), applyIp);
    $('btnIpCommands').onclick = () => showConsole('ip');

    $('btnAdRefresh').onclick = () => withBusy($('btnAdRefresh'), () => detect(false));
    $('btnAdVerify').onclick = () => withBusy($('btnAdVerify'), adVerify);
    $('btnAdAdd').onclick = () => withBusy($('btnAdAdd'), adAdd);
    $('btnAdCommands').onclick = () => showConsole('ad');
    $('btnJoin').onclick = () => withBusy($('btnJoin'), adJoin);
    $('btnJoinCommands').onclick = () => showConsole('join');
    $('adStatus').addEventListener('click', (e) => { const b = e.target.closest('[data-rm]'); if (b) withBusy(null, () => adRemove(b.dataset.rm)); });
    ['adGroup', 'adDomain', 'adGid', 'jDomain', 'jUser', 'jOu'].forEach((id) => $(id).addEventListener('input', () => { if (!$('tab-console').classList.contains('hidden')) renderConsole(); }));
    ['jShort', 'jIdmap'].forEach((id) => $(id).addEventListener('change', () => { if (!$('tab-console').classList.contains('hidden')) renderConsole(); }));

    $('conDistro').onchange = renderConsole; $('conTask').onchange = renderConsole;
    $('btnCopy').onclick = copyCode; $('btnDownload').onclick = downloadCode;
    $('btnClearLog').onclick = () => { state.logs = []; renderLog(); };

    let theme = null; try { theme = localStorage.getItem('lct-theme'); } catch (e) { /* ignore */ }
    applyTheme(theme);
    $('btnTheme').onclick = () => {
      const cur = document.documentElement.getAttribute('data-theme');
      const dark = cur ? cur === 'dark' : window.matchMedia('(prefers-color-scheme: dark)').matches;
      const next = dark ? 'light' : 'dark'; applyTheme(next); try { localStorage.setItem('lct-theme', next); } catch (e) { /* ignore */ }
    };
    $('btnQuit').onclick = async () => {
      if (!(await confirmBox('Salir', '<p>Se cierra Linux Config Tool.</p>', 'Salir'))) return;
      try { await api('/api/shutdown', {}); } catch (e) { /* ignore */ }
      document.body.innerHTML = '<div style="padding:40px;text-align:center"><h2>Linux Config Tool cerrado</h2><p>Ya podés cerrar esta pestaña.</p></div>';
    };
    loadStore();
    validateIpForm();
  }
  init();
})();
