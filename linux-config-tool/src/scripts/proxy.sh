# ---- proxy.sh : probar / configurar / quitar el proxy de internet del servidor ----
# LCT_ACTION: test | apply | remove
ACTION=${LCT_ACTION:-test}
lct_os

# Prueba una URL. Imprime "codigo|error|auth|bloqueado|ssl". Sin proxy: $2 vacio.
#  auth      = esquemas que ofrece el proxy al pedir autenticacion (Basic,NTLM,Negotiate)
#  bloqueado = 1 si el 403 lo genero el proxy (no el sitio)
#  ssl       = 1 si fallo la validacion del certificado HTTPS (tipico de inspeccion SSL)
px_probe() {
  local url=$1 px=$2 code="" conn="" err="" ef hf out auth="" blk=0 ssl=0
  ef=$(mktemp); hf=$(mktemp)
  if lct_has curl; then
    if [ -n "$px" ]; then
      out=$(curl -sS -m 12 -o /dev/null -D "$hf" -w '%{http_code} %{http_connect}' -x "$px" "$url" 2>"$ef")
    else
      out=$(curl -sS -m 12 -o /dev/null -D "$hf" -w '%{http_code} %{http_connect}' --noproxy '*' "$url" 2>"$ef")
    fi
    code=${out%% *}; conn=${out##* }
    # Si el proxy rechazo el CONNECT (https), el codigo esta en http_connect
    if { [ "$code" = 000 ] || [ -z "$code" ]; } && [ -n "$conn" ] && [ "$conn" != 000 ] && [ "$conn" != 200 ]; then code=$conn; fi
  elif lct_has wget; then
    if [ -n "$px" ]; then out=$(wget -S --spider -T 12 -t 1 -e use_proxy=on -e http_proxy="$px" -e https_proxy="$px" "$url" 2>&1)
    else out=$(wget -S --spider -T 12 -t 1 --no-proxy "$url" 2>&1); fi
    echo "$out" > "$ef"; echo "$out" | sed 's/^  //' > "$hf"
    code=$(echo "$out" | awk '/HTTP\//{c=$2} END{print c+0}')
  else
    echo "000|ni curl ni wget estan instalados|||"; rm -f "$ef" "$hf"; return
  fi
  tr -d '\r' < "$hf" > "$hf.n" && mv "$hf.n" "$hf"
  err=$(grep -iE 'curl:|error|fail|unable|refused|timed out|resolve|certificate' "$ef" | head -n1 | tr '|' ' ' | sed 's/^curl: ([0-9]*) //' | cut -c1-160)
  auth=$(grep -i '^Proxy-Authenticate:' "$hf" | awk '{print $2}' | sed 's/,$//' | awk '!s[$0]++' | paste -sd, -)
  if [ "$code" = 403 ] && grep -qiE '^x-squid-error|^proxy-status|^x-bluecoat|^x-zscaler|^x-forcepoint|^server:.*(squid|bluecoat|proxysg|zscaler|mcafee|webwasher|forcepoint|websense|fortigate|fortiweb|cisco|ironport|skyhigh)' "$hf"; then blk=1; fi
  if grep -qiE 'SSL certificate problem|certificate verify failed|self.signed certificate|unable to get local issuer|certificate is not trusted|ERROR: cannot verify' "$ef"; then ssl=1; fi
  rm -f "$ef" "$hf"
  [ -z "$code" ] && code=000
  echo "${code}|${err}|${auth}|${blk}|${ssl}"
}

# Lista "url tipo" de destinos a probar. tipo: os (repositorios del sistema operativo) | otro (otros repos configurados)
px_targets() {
  local code="${VERSION_CODENAME:-}" out
  [ -z "$code" ] && [ -r /etc/os-release ] && code=$(. /etc/os-release; echo "${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}")
  out=$(
    if [ -d /etc/apt ]; then
      # Formato clasico: deb [opciones] URI suite componentes
      grep -hsE '^[[:space:]]*deb[[:space:]]' /etc/apt/sources.list /etc/apt/sources.list.d/*.list | sed -E 's/\[[^]]*\]//' |
        awk -v c="$code" '{u=$2; s=$3; comps=""; for(i=4;i<=NF;i++) comps=comps" "$i
          suite=(c!="" && (s==c || index(s, c"-")==1)); osrepo=(comps ~ / (restricted|universe|multiverse|contrib|non-free)/ || u ~ /^[a-z]+:\/\/([a-z0-9-]+\.)*(ubuntu\.com|debian\.org)\//)
          print u, (suite && osrepo) ? "os" : "otro"}'
      # Formato deb822 (.sources): parrafos con URIs: y Suites:
      for f in /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        awk -v c="$code" '
          function flush() { if (uris != "") { n = split(uris, a, " "); for (i = 1; i <= n; i++) { suite = (c != "" && (" " suites " ") ~ (" " c "[ -]")); osrepo = (comps ~ / (restricted|universe|multiverse|contrib|non-free)/ || a[i] ~ /^[a-z]+:\/\/([a-z0-9-]+\.)*(ubuntu\.com|debian\.org)\//); print a[i], (suite && osrepo) ? "os" : "otro" } }; uris = ""; suites = ""; comps = ""; en = 1 }
          BEGIN { en = 1 }
          /^[[:space:]]*$/ { if (en) flush(); else { uris = ""; suites = ""; comps = "" }; en = 1; next }
          tolower($1) == "uris:" { $1 = ""; uris = $0 }
          tolower($1) == "suites:" { $1 = ""; suites = $0 }
          tolower($1) == "components:" { $1 = ""; comps = $0 }
          tolower($1) == "enabled:" && tolower($2) == "no" { en = 0 }
          END { if (en) flush() }' "$f"
      done
    fi
    if [ -d /etc/yum.repos.d ]; then
      awk '
        /^\[/ { id = tolower($0); en = 1 }
        /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*0/ { en = 0 }
        /^[[:space:]]*(baseurl|mirrorlist|metalink)[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); split($0, a, /[ ,]/); u[id] = a[1]; t[id] = (id ~ /baseos|appstream|rhel|base\]|updates\]|extras\]|crb|codeready|ol[0-9]_|epel/) ? "os" : "otro" }
        END { for (k in u) print u[k], t[k] }' /etc/yum.repos.d/*.repo 2>/dev/null
    fi
    if [ -d /etc/zypp/repos.d ]; then
      grep -hsE '^[[:space:]]*baseurl[[:space:]]*=' /etc/zypp/repos.d/*.repo | sed -E 's/^[^=]*=[[:space:]]*//; s/$/ os/'
    fi
    case "$LCT_OS_ID" in
      ubuntu) echo "http://archive.ubuntu.com/ubuntu/ os"; echo "http://security.ubuntu.com/ubuntu/ os" ;;
      debian) echo "http://deb.debian.org/debian/ os"; echo "http://security.debian.org/ os" ;;
      rhel) echo "https://cdn.redhat.com/ os" ;;
      rocky) echo "https://dl.rockylinux.org/ os" ;;
      almalinux) echo "https://repo.almalinux.org/ os" ;;
      ol) echo "https://yum.oracle.com/ os" ;;
      centos) echo "https://mirror.stream.centos.org/ os" ;;
      fedora) echo "https://mirrors.fedoraproject.org/ os" ;;
      sles|sled) echo "https://updates.suse.com/ os" ;;
      opensuse*) echo "https://download.opensuse.org/ os" ;;
    esac
  )
  # esquema://host/ ; primero los del sistema; sin repetidos (si un host aparece como os y otro, gana os)
  echo "$out" | awk 'NF>=2 && $1 ~ /^https?:\/\// { u=$1; sub(/^(https?:\/\/[^\/]+).*/, "&", u); match(u, /^https?:\/\/[^\/]+/); u=substr(u, RSTART, RLENGTH) "/"; if (!(u in k) || $2=="os") k[u]=$2; if (!(u in o)) { o[u]=++n; ord[n]=u } }
    END { for (i=1;i<=n;i++) if (k[ord[i]]=="os") print ord[i], "os"; for (i=1;i<=n;i++) if (k[ord[i]]!="os") print ord[i], "otro" }' | head -n 6
}

case "$ACTION" in
  test)
    [ -n "$LCT_PROXY" ] || lct_fail "Escriba la direccion del proxy."
    read -r phost pport <<<"$(lct_proxy_hostport "$LCT_PROXY")"
    echo "PX_HOST=$phost"
    if getent hosts "$phost" >/dev/null 2>&1 || echo "$phost" | grep -qE '^[0-9.]+$'; then
      echo "PX_DNS=ok"
    else
      echo "PX_DNS=fail"
    fi
    pip=$(getent hosts "$phost" 2>/dev/null | awk '{print $1; exit}')
    [ -z "$pip" ] && echo "$phost" | grep -qE '^[0-9.]+$' && pip=$phost
    echo "PX_IP=$pip"
    if [ -n "$pip" ] && lct_has ip; then
      echo "SRC_IP=$(ip -4 route get "$pip" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)"
    fi
    if timeout 6 bash -c "exec 3<>/dev/tcp/$phost/$pport" 2>/dev/null; then echo "PX_PORT=ok"; else echo "PX_PORT=fail"; fi
    px_targets | while read -r t kind; do
      [ -n "$t" ] || continue
      d=$(px_probe "$t" "")
      p=$(px_probe "$t" "$LCT_PROXY")
      echo "TEST|$t|$d|$p|$kind"
    done
    echo "LCT_OK=1"
    ;;
  apply)
    lct_require_root
    [ -n "$LCT_PROXY" ] || lct_fail "Escriba la direccion del proxy."
    lct_proxy_apply "$LCT_PROXY" "$LCT_NOPROXY" || lct_fail "No se pudo configurar el proxy."
    echo "LCT_NOTE=Las sesiones nuevas (SSH, sudo, apt/dnf) ya usan el proxy. Las que estaban abiertas tienen que volver a entrar."
    echo "LCT_OK=1"
    ;;
  remove)
    lct_require_root
    lct_proxy_remove
    echo "LCT_OK=1"
    ;;
  *)
    lct_fail "Accion desconocida: $ACTION"
    ;;
esac
