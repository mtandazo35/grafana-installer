#!/usr/bin/env bash
#
# grafana-installer — Grafana 12.4.3 en Debian / Ubuntu
# https://github.com/mtandazo35/grafana-installer
#
# Uso:
#   bash <(curl -fsSL https://raw.githubusercontent.com/mtandazo35/grafana-installer/main/install.sh)
#   ./install.sh [install|uninstall] [--version X.Y.Z] [--port N] [--domain host]
#                [--admin-pass CLAVE] [--enterprise] [--no-pin] [--force] [--check]
#
set -euo pipefail

VERSION_DEFAULT="12.4.3"
GRAFANA_VERSION="$VERSION_DEFAULT"
EDITION="oss"
PKG="grafana"
HTTP_PORT="3000"
DOMAIN=""
ADMIN_USER="admin"
ADMIN_PASS=""
PIN=1
FORCE=0
CHECK_ONLY=0
PURGE_DATA=0
ACTION="install"

KEYRING="/etc/apt/keyrings/grafana.gpg"
SRC_LIST="/etc/apt/sources.list.d/grafana.list"
APT_PREF="/etc/apt/preferences.d/99-grafana-pin"
DROPIN_DIR="/etc/systemd/system/grafana-server.service.d"
DROPIN="${DROPIN_DIR}/zz-installer.conf"
BOOTSTRAP="${DROPIN_DIR}/zz-bootstrap.conf"
CRED_FILE="/root/grafana-credentials.txt"
WORKDIR="/root"

C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[36m'; C_0=$'\e[0m'
log()  { printf '%s[*]%s %s\n'  "$C_B" "$C_0" "$*"; }
ok()   { printf '%s[OK]%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$C_Y" "$C_0" "$*"; }
err()  { printf '%s[X]%s %s\n'  "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<HELP
grafana-installer — Grafana ${VERSION_DEFAULT} en Debian/Ubuntu

  install.sh [install|uninstall] [opciones]

Opciones:
  --version X.Y.Z     Version a instalar (default: ${VERSION_DEFAULT})
  --port N            Puerto HTTP (default: 3000)
  --domain HOST       Dominio publico -> root_url (ej. grafana.midominio.com)
  --admin-pass CLAVE  Clave del usuario admin (default: aleatoria de 20 chars)
  --enterprise        Instala grafana-enterprise en vez de grafana (OSS)
  --no-pin            No fija la version (permite que apt la actualice)
  --force             Reconfigura aunque Grafana ya este instalado
  --check             Solo audita requisitos, no instala nada
  --purge-data        Solo con uninstall: borra tambien datos y config
  -h, --help          Esta ayuda
HELP
}

# ---------------------------------------------------------------- argumentos
while [ $# -gt 0 ]; do
  case "$1" in
    install|uninstall) ACTION="$1" ;;
    --version)     GRAFANA_VERSION="${2:-}"; shift ;;
    --port)        HTTP_PORT="${2:-}"; shift ;;
    --domain)      DOMAIN="${2:-}"; shift ;;
    --admin-pass)  ADMIN_PASS="${2:-}"; shift ;;
    --enterprise)  EDITION="enterprise"; PKG="grafana-enterprise" ;;
    --no-pin)      PIN=0 ;;
    --force)       FORCE=1 ;;
    --check)       CHECK_ONLY=1 ;;
    --purge-data)  PURGE_DATA=1 ;;
    -h|--help)     usage; exit 0 ;;
    *) die "Opcion desconocida: $1 (--help para la ayuda)" ;;
  esac
  shift
done

[ -n "$GRAFANA_VERSION" ] || die "--version requiere un valor"
case "$HTTP_PORT" in ''|*[!0-9]*) die "--port debe ser numerico" ;; esac

# ------------------------------------------------------------------ helpers
have() { command -v "$1" >/dev/null 2>&1; }

wait_apt() {
  local i=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then die "apt/dpkg sigue bloqueado por otro proceso tras 5 min"; fi
    if [ "$i" -eq 1 ]; then log "Esperando a que se libere apt/dpkg..."; fi
    sleep 5
  done
  return 0
}

# ------------------------------------------------------------ fase de checks
run_checks() {
  local fail=0

  if [ "$(id -u)" -ne 0 ]; then
    err "Hay que ejecutarlo como root (sudo)"
    fail=1
  fi

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
      *debian*|*ubuntu*) ok "Distro: ${PRETTY_NAME:-$ID}" ;;
      *) err "Distro no soportada (${PRETTY_NAME:-$ID}); este instalador usa paquetes .deb"; fail=1 ;;
    esac
  else
    err "No existe /etc/os-release"
    fail=1
  fi

  have systemctl || { err "systemd no disponible"; fail=1; }
  have apt-get   || { err "apt-get no disponible"; fail=1; }

  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || echo desconocida)"
  case "$arch" in
    amd64|arm64|armhf|i386) ok "Arquitectura: $arch" ;;
    *) err "Arquitectura sin paquetes en apt.grafana.com: $arch"; fail=1 ;;
  esac

  local ram_mb
  ram_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
  if [ "$ram_mb" -lt 900 ]; then
    err "RAM ${ram_mb} MB - Grafana necesita ~1 GB"
    fail=1
  else
    ok "RAM: ${ram_mb} MB"
  fi

  local free_mb
  free_mb="$(df -Pm /usr | awk 'NR==2{print $4}')"
  if [ "$free_mb" -lt 2048 ]; then
    err "Disco libre en /usr: ${free_mb} MB - el paquete ocupa ~800 MB instalado"
    fail=1
  else
    ok "Disco libre en /usr: ${free_mb} MB"
  fi

  if have ss; then
    local busy
    busy="$(ss -Hltnp "( sport = :${HTTP_PORT} )" 2>/dev/null || true)"
    if [ -n "$busy" ]; then
      if echo "$busy" | grep -q grafana; then
        ok "Puerto ${HTTP_PORT}: ocupado por Grafana (reinstalacion)"
      else
        err "Puerto ${HTTP_PORT} ocupado por: $(echo "$busy" | sed 's/.*users:((//; s/).*//')"
        fail=1
      fi
    else
      ok "Puerto ${HTTP_PORT} libre"
    fi
  fi

  if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    warn "apt/dpkg ocupado ahora mismo (el instalador esperaria)"
  else
    ok "apt/dpkg libre"
  fi

  if have curl; then
    if curl -fsI --max-time 20 https://apt.grafana.com/dists/stable/Release >/dev/null 2>&1; then
      ok "apt.grafana.com accesible"
    else
      err "No hay acceso a https://apt.grafana.com"
      fail=1
    fi
  else
    warn "curl no instalado (el instalador lo instala)"
  fi

  if dpkg-query -W -f='${Status}' grafana 2>/dev/null | grep -q "ok installed" \
  || dpkg-query -W -f='${Status}' grafana-enterprise 2>/dev/null | grep -q "ok installed"; then
    warn "Grafana ya esta instalado en este host"
  fi

  if [ "$fail" -ne 0 ]; then
    err "Revision: NO cumple los requisitos"
    return 1
  fi
  ok "Revision: listo para instalar Grafana ${GRAFANA_VERSION} (${EDITION})"
  return 0
}

# --------------------------------------------------------------- desinstalar
do_uninstall() {
  [ "$(id -u)" -eq 0 ] || die "Hay que ejecutarlo como root (sudo)"
  log "Desinstalando Grafana..."
  systemctl disable --now grafana-server >/dev/null 2>&1 || true
  apt-mark unhold grafana grafana-enterprise >/dev/null 2>&1 || true
  wait_apt
  DEBIAN_FRONTEND=noninteractive apt-get purge -y grafana grafana-enterprise >/dev/null 2>&1 || true
  rm -f "$DROPIN" "$BOOTSTRAP" "$APT_PREF" "$SRC_LIST" "$KEYRING"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  if [ "$PURGE_DATA" -eq 1 ]; then
    rm -rf /var/lib/grafana /var/log/grafana /etc/grafana "$CRED_FILE"
    warn "Datos, configuracion y credenciales borrados"
  else
    log "Se conservan /var/lib/grafana y /etc/grafana (usa --purge-data para borrarlos)"
  fi
  ok "Grafana desinstalado"
}

# ------------------------------------------------------------------ instalar
add_repo() {
  log "Configurando el repositorio oficial de Grafana..."
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o "$KEYRING"
  chmod 0644 "$KEYRING"
  echo "deb [signed-by=${KEYRING}] https://apt.grafana.com stable main" > "$SRC_LIST"
  wait_apt
  apt-get update -o Dir::Etc::sourcelist="$SRC_LIST" \
                 -o Dir::Etc::sourceparts="-" \
                 -o APT::Get::List-Cleanup="0" >/dev/null
  ok "Repositorio anadido"
}

install_package() {
  local arch
  arch="$(dpkg --print-architecture)"

  if apt-cache madison "$PKG" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}' | grep -qx "$GRAFANA_VERSION"; then
    log "Instalando ${PKG}=${GRAFANA_VERSION} desde apt.grafana.com (~220 MB, tarda)..."
    wait_apt
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKG}=${GRAFANA_VERSION}"
  else
    warn "La version ${GRAFANA_VERSION} no aparece en el indice apt; probando el .deb directo"
    local base deb url
    if [ "$EDITION" = "enterprise" ]; then base="enterprise"; else base="oss"; fi
    deb="${PKG}_${GRAFANA_VERSION}_${arch}.deb"
    url="https://dl.grafana.com/${base}/release/${deb}"
    curl -fSL --max-time 1800 -o "${WORKDIR}/${deb}" "$url" \
      || die "No existe ${GRAFANA_VERSION} para ${arch} (ni en apt ni en dl.grafana.com)"
    wait_apt
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${WORKDIR}/${deb}"
    rm -f "${WORKDIR}/${deb}"
  fi
  ok "Paquete instalado: $(dpkg-query -W -f='${Version}' "$PKG")"
}

pin_version() {
  if [ "$PIN" -eq 0 ]; then
    rm -f "$APT_PREF"
    apt-mark unhold grafana grafana-enterprise >/dev/null 2>&1 || true
    warn "Sin fijar version: apt podra actualizar Grafana"
    return 0
  fi
  cat > "$APT_PREF" <<PREF
# grafana-installer: fija Grafana en ${GRAFANA_VERSION}
Package: grafana grafana-enterprise
Pin: version ${GRAFANA_VERSION}
Pin-Priority: 1001
PREF
  apt-mark hold "$PKG" >/dev/null
  ok "Version fijada en ${GRAFANA_VERSION} (apt pin + hold)"
}

# El puerto y el root_url van en un drop-in de systemd, no editando
# /etc/grafana/grafana.ini (que es un conffile de dpkg): asi el instalador
# es idempotente y las actualizaciones no preguntan por conflictos.
write_dropin() {
  install -d -m 0755 "$DROPIN_DIR"
  {
    echo "[Service]"
    echo "Environment=\"GF_SERVER_HTTP_PORT=${HTTP_PORT}\""
    if [ -n "$DOMAIN" ]; then
      echo "Environment=\"GF_SERVER_DOMAIN=${DOMAIN}\""
      echo "Environment=\"GF_SERVER_ROOT_URL=https://${DOMAIN}/\""
    fi
  } > "$DROPIN"
  chmod 0644 "$DROPIN"
  systemctl daemon-reload
}

wait_health() {
  local i=0
  while [ "$i" -lt 60 ]; do
    if curl -fsS --max-time 3 "http://127.0.0.1:${HTTP_PORT}/api/health" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  return 1
}

# Solo en instalacion limpia: Grafana crea el usuario admin en el primer
# arranque con esta clave y la guarda HASHEADA en su base de datos. El
# drop-in con el secreto se borra en cuanto el servicio responde.
bootstrap_admin() {
  install -d -m 0755 "$DROPIN_DIR"
  printf '[Service]\nEnvironment="GF_SECURITY_ADMIN_USER=%s"\nEnvironment="GF_SECURITY_ADMIN_PASSWORD=%s"\n' \
    "$ADMIN_USER" "$ADMIN_PASS" > "$BOOTSTRAP"
  chmod 0600 "$BOOTSTRAP"
  systemctl daemon-reload
}

scrub_bootstrap() {
  if [ -f "$BOOTSTRAP" ]; then
    rm -f "$BOOTSTRAP"
    systemctl daemon-reload
    systemctl restart grafana-server
    wait_health || warn "Grafana tardo en responder tras retirar la clave del entorno"
  fi
}

open_firewall() {
  if have ufw && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow "${HTTP_PORT}/tcp" >/dev/null 2>&1 || true
    ok "UFW activo: abierto ${HTTP_PORT}/tcp"
  fi
}

host_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

do_install() {
  run_checks || die "Corrige lo anterior y vuelve a ejecutar (--check audita sin tocar nada)"

  if dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null | grep -q "ok installed" && [ "$FORCE" -eq 0 ]; then
    warn "Grafana ya esta instalado ($(dpkg-query -W -f='${Version}' "$PKG")). No se toca nada."
    warn "Usa --force para reconfigurar, o 'uninstall' para quitarlo."
    exit 0
  fi

  local fresh=0
  [ -f /var/lib/grafana/grafana.db ] || fresh=1

  if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  fi

  log "Instalando dependencias del instalador..."
  wait_apt
  DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl gpg ca-certificates apt-transport-https >/dev/null

  add_repo
  install_package
  pin_version
  write_dropin
  if [ "$fresh" -eq 1 ]; then bootstrap_admin; fi

  log "Arrancando grafana-server..."
  systemctl enable grafana-server >/dev/null 2>&1
  systemctl restart grafana-server

  if wait_health; then
    ok "Grafana responde en el puerto ${HTTP_PORT}"
  else
    err "Grafana no respondio en 120 s. Ultimas lineas del journal:"
    journalctl -u grafana-server -n 30 --no-pager || true
    exit 1
  fi

  if [ "$fresh" -eq 1 ]; then
    scrub_bootstrap
  else
    log "Base de datos existente: la clave de admin no se modifica"
    log "Para cambiarla: sudo -u grafana grafana-cli admin reset-admin-password 'NUEVA'"
    ADMIN_PASS="(sin cambios - base de datos previa)"
  fi

  open_firewall

  umask 077
  cat > "$CRED_FILE" <<CRED
Grafana $(dpkg-query -W -f='${Version}' "$PKG") (${EDITION})
Instalado: $(date -Is)
URL:       http://$(host_ip):${HTTP_PORT}
Usuario:   ${ADMIN_USER}
Clave:     ${ADMIN_PASS}
CRED
  chmod 600 "$CRED_FILE"

  echo
  ok "Grafana ${GRAFANA_VERSION} (${EDITION}) instalado y corriendo"
  echo "  URL:      http://$(host_ip):${HTTP_PORT}"
  if [ -n "$DOMAIN" ]; then echo "  root_url: https://${DOMAIN}/"; fi
  echo "  Usuario:  ${ADMIN_USER}"
  echo "  Clave:    ${ADMIN_PASS}"
  echo "  Copia en ${CRED_FILE} (chmod 600)"
  echo
  echo "  Config:   /etc/grafana/grafana.ini  (overrides del instalador: ${DROPIN})"
  echo "  Datos:    /var/lib/grafana          Logs: journalctl -u grafana-server -f"
  if [ "$PIN" -eq 1 ]; then
    echo "  Version fijada: apt no la actualizara (liberar con: apt-mark unhold ${PKG} && rm ${APT_PREF})"
  fi
  echo
  return 0
}

# --------------------------------------------------------------------- main
if [ "$ACTION" = "uninstall" ]; then
  do_uninstall
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  if run_checks; then exit 0; else exit 1; fi
fi

do_install
exit 0
