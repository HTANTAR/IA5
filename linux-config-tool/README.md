# Linux Config Tool

Herramienta portable para Windows (un solo `.exe`, sin instalar nada) que, desde una interfaz web local, configura servidores Linux por SSH con usuario y contraseña:

- **IP fija** en RHEL / Rocky / Alma / Oracle / CentOS, Ubuntu, Debian y SUSE, con **backup y rollback automático** si la PC no puede reconectarse con la IP nueva.
- **Acceso por grupos de seguridad de Active Directory**: permitir login, dar sudo (con o sin contraseña), verificar el GID unix del grupo y unir el servidor al dominio.
- **Comandos para consola**: si el servidor no tiene red, genera los comandos exactos para su distribución, listos para copiar o descargar como `.sh`.

## Descarga

[**LinuxConfigTool.exe**](https://github.com/HTANTAR/IA5/raw/feature/linux-config-tool/linux-config-tool/dist/LinuxConfigTool.exe)

Doble clic y se abre el navegador en `http://localhost:8765`. La ventana negra es el servidor local: no la cierres mientras la uses.

Requisitos: Windows 10/11 o Windows Server 2016+ (usa Windows PowerShell 5.1 y .NET Framework 4.x, que ya vienen con Windows). Como el .exe no está firmado, SmartScreen puede pedir "Más información → Ejecutar de todas formas".

## Cómo se usa

**Proxy:** si los servidores salen a internet por proxy, cargalo en *Proxy de internet del servidor* (paso 1, ej. `http://proxy.empresa.local:8080`; con usuario: `http://usuario:clave@proxy:8080`) y marcá *Usar este proxy por defecto* para que quede para todos los servidores (se guarda sin la contraseña).
- *Usar el proxy de esta PC*: carga el proxy que usa Windows (manual o elegido por configuración automática/PAC).
- *Probar (servidor y esta PC)*: prueba el mismo proxy desde el servidor y desde tu PC y explica la diferencia: el servidor no resuelve el nombre del proxy, hay un firewall entre la red del servidor y el proxy (te da la IP de origen para pedir la regla), el proxy pide usuario/contraseña, el proxy solo acepta autenticación de Windows (NTLM/Kerberos, por eso en tu PC anda y en Linux no), el proxy bloquea al servidor (403), inspección SSL, o tu PC en realidad usa otro proxy (PAC) con botón para probar ese.
- *Configurar en el servidor*: lo deja fijo en `/etc/environment`, sudo (`env_keep`), apt / dnf / yum / zypper, subscription-manager (si registra contra Red Hat) y snap, con backup. *Quitar del servidor* lo revierte.
- Al unir al dominio, los paquetes se instalan por el proxy automáticamente (y opcionalmente queda configurado).
- *Comandos para consola → Configurar el proxy de internet* da los mismos pasos para hacerlo a mano.

1. **Servidor**: IP actual, usuario (root o un usuario con sudo) y contraseña → *Conectar y detectar*. Muestra sistema operativo, gestor de red, interfaces (DHCP o fija), gateway, DNS y estado de Active Directory.
2. **IP fija**: elegí la interfaz, *Usar valores actuales* (para convertir DHCP en fija con la misma IP) o cargá una IP nueva, máscara, gateway y DNS → *Aplicar por SSH*.
   - Se hace backup en `/var/lib/linuxconfigtool/backup`.
   - El cambio corre en segundo plano en el servidor; la app se reconecta a la IP nueva y lo confirma.
   - Si no logra reconectarse en el tiempo indicado (120 s por defecto), el servidor **vuelve solo** a la configuración anterior.
   - Deshacer a mano: `sudo bash /var/lib/linuxconfigtool/ipjob.sh rollback`
3. **Acceso por grupos AD**: escribí uno o varios grupos (separados por coma), el GID unix esperado si querés validarlo, y el nivel:
   - *Solo iniciar sesión* → `realm permit -g grupo`
   - *Administrador* → además `/etc/sudoers.d/lct-<grupo>` con `%grupo ALL=(ALL) ALL` (validado con `visudo`)
   - *Admin sin contraseña* → `NOPASSWD: ALL`
   - *Verificar grupo* muestra cómo lo ve Linux (`getent group`) y avisa si el GID no coincide con el de AD.
   - Si el GID no coincide porque SSSD genera los IDs solo, el botón *Usar UID/GID de AD* pone `ldap_id_mapping = False`.
   - *Unir el servidor al dominio* (necesario una sola vez para que Linux conozca los usuarios y grupos de AD; por sí solo no da acceso a nadie):
     - instala solo los paquetes que falten (realmd, sssd, adcli, oddjob…). Si el servidor no tiene repositorios (RHEL sin registrar, sin internet/proxy), usa el **ISO/DVD de instalación** conectado a la VM;
     - `realm join` en la OU indicada, home automático, UID/GID de AD y login con nombre corto (opcional);
     - deja el login cerrado y **habilita automáticamente los grupos cargados arriba** con el nivel elegido;
     - si algo falla muestra la causa (sin repositorios, DNS, permisos en la OU, contraseña, hora) y el detalle del servidor.
   - *Ver configuración AD completa*: muestra (solo lectura) cómo está integrado un servidor que ya funciona: paquetes, servicios, realm, sssd.conf (contraseñas ocultas), Kerberos, PAM, nsswitch, sudoers, SSH, hora, DNS y los grupos con acceso con su GID. Sirve para copiar la misma configuración en los servidores nuevos.
4. **Comandos para consola**: elegí la distribución y la tarea; copiá o descargá el `.sh`. La opción *Script automático* detecta la distro sola.

Los servidores se guardan (nombre, IP, usuario; **nunca la contraseña**) en `LinuxConfigTool-datos.json` junto al .exe, y queda un historial en `LinuxConfigTool-historial.log`.

## Qué soporta

| Gestor de red | Distros típicas | Cómo aplica |
|---|---|---|
| NetworkManager | RHEL/Rocky/Alma/Oracle 7-10, Fedora, SLES 16, Ubuntu Desktop | `nmcli connection modify` + `up` |
| netplan | Ubuntu Server 18.04+ | edita los YAML de `/etc/netplan`, desactiva la red de cloud-init, `netplan apply` |
| ifupdown | Debian | `/etc/network/interfaces` |
| network-scripts | RHEL/CentOS 6-7 sin NM | `ifcfg-<iface>` |
| wicked | SLES 12-15, openSUSE Leap | `ifcfg`, `ifroute`, `netconfig` |

Active Directory: realmd + SSSD (lo que usa `realm join`). Si el servidor tiene SSSD sin realmd, edita `simple_allow_groups` en `sssd.conf`.

## Seguridad

- La interfaz solo escucha en `localhost` y cada sesión usa un token aleatorio.
- La contraseña viaja por SFTP a un archivo temporal `600` que se borra antes de ejecutar `sudo`, así no aparece en la lista de procesos del servidor. Si el servidor no tiene SFTP, se usa un método alternativo.
- Se acepta la clave del servidor SSH sin preguntar (la huella queda en *Registro*).

## Estructura

```
linux-config-tool/
├─ dist/LinuxConfigTool.exe   ← el ejecutable portable
├─ src/app.ps1                ← backend PowerShell (servidor web local + API)
├─ src/LctSsh.cs              ← helper SSH en C# (sobre SSH.NET)
├─ src/scripts/*.sh           ← lo que corre en el Linux (detección, IP, AD)
├─ src/www/                   ← interfaz web
├─ src/lib/                   ← Renci.SshNet.dll (SSH.NET 2020.0.2, MIT) y LctSsh.dll
├─ launcher/Launcher.cs       ← el .exe: extrae todo y arranca PowerShell
├─ build.ps1                  ← recompilar en Windows (sin instalar nada)
└─ build.sh                   ← recompilar en Linux con Mono
```

Sin el .exe también funciona: `powershell -ExecutionPolicy Bypass -File src\app.ps1`

Para cambiar algo, editá `src/` y recompilá con `build.ps1`.

## Licencias

SSH.NET (Renci.SshNet) © RENCI, licencia MIT — compilado desde el tag `2020.0.2` de https://github.com/sshnet/SSH.NET.
