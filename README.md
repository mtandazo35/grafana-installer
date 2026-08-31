# grafana-installer

Instalador de [Grafana](https://grafana.com/) **12.4.3** en Debian / Ubuntu: repositorio oficial `apt.grafana.com`, servicio systemd, **versión fijada** (apt pin + hold) y clave de admin aleatoria guardada en `/root/grafana-credentials.txt`.

## ⚡ Quick install (one-liner)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mtandazo35/grafana-installer/main/install.sh)
```

Al terminar, abre:

```
http://<IP_DEL_SERVIDOR>:3000
```

El usuario es `admin` y la clave se genera aleatoria (20 caracteres): sale por pantalla y queda en `/root/grafana-credentials.txt` (modo 600).

## Requisitos

- Debian 12/13 o Ubuntu 22.04/24.04 (systemd)
- root
- amd64, arm64, armhf o i386
- 1 GB RAM y ~2 GB libres en `/usr` (el paquete ocupa ~800 MB instalado)

## Qué hace

1. **Audita antes de tocar nada**: distro, systemd, arquitectura, RAM, disco, puerto 3000 libre (con el nombre del proceso que lo ocupa), `apt`/`dpkg` sin bloquear y acceso real a `apt.grafana.com`. Si algo falla, aborta sin instalar.
2. Añade el repositorio oficial con la clave en `/etc/apt/keyrings/grafana.gpg` (`signed-by`, nada de `apt-key`).
3. Instala `grafana=12.4.3`. Si esa versión no estuviera en el índice, cae al `.deb` de `dl.grafana.com` (descargado a `/root`, nunca a `/tmp`).
4. **Fija la versión**: `/etc/apt/preferences.d/99-grafana-pin` + `apt-mark hold`, para que un `apt upgrade` no se lleve por delante los dashboards.
5. Configura puerto y `root_url` en un **drop-in de systemd** (`/etc/systemd/system/grafana-server.service.d/zz-installer.conf`), no editando `/etc/grafana/grafana.ini` — que es un conffile de dpkg y provocaría conflictos en cada actualización.
6. Crea el admin en el primer arranque vía `GF_SECURITY_ADMIN_PASSWORD`, que Grafana guarda **hasheada** en su base de datos; después borra ese drop-in y reinicia, así el secreto no queda en systemd.
7. Habilita el servicio, espera a `GET /api/health` y abre el puerto en UFW si está activo.

Si Grafana ya está instalado **sale sin modificar nada** (`--force` reconfigura encima). Sobre una base de datos existente no toca la clave del admin.

## Opciones

```bash
./install.sh [install|uninstall] [opciones]
```

| Opción | Efecto |
|---|---|
| `--version X.Y.Z` | Otra versión (default `12.4.3`) |
| `--port N` | Puerto HTTP (default `3000`) |
| `--domain HOST` | Fija `root_url` a `https://HOST/` (para poner Grafana detrás de NPM/Caddy) |
| `--admin-pass CLAVE` | Clave del admin en vez de una aleatoria |
| `--enterprise` | Instala `grafana-enterprise` en lugar de `grafana` (OSS) |
| `--no-pin` | No fija la versión: apt podrá actualizarla |
| `--force` | Reconfigura aunque ya esté instalado |
| `--check` | Solo audita requisitos, no instala (exit 1 si no cumple) |
| `--purge-data` | Solo con `uninstall`: borra también `/var/lib/grafana` y `/etc/grafana` |

Ejemplos:

```bash
# Auditar antes de instalar
curl -fsSL https://raw.githubusercontent.com/mtandazo35/grafana-installer/main/install.sh -o /root/install.sh
bash /root/install.sh --check

# Detrás de un proxy inverso, en el puerto 3001
bash /root/install.sh --port 3001 --domain grafana.midominio.com

# Quitarlo conservando dashboards y datasources
bash /root/install.sh uninstall
```

## Dónde queda cada cosa

| Ruta | Contenido |
|---|---|
| `/etc/grafana/grafana.ini` | Config principal (sin tocar por el instalador) |
| `/etc/systemd/system/grafana-server.service.d/zz-installer.conf` | Puerto y `root_url` |
| `/etc/apt/preferences.d/99-grafana-pin` | Pin de la versión |
| `/var/lib/grafana` | Base de datos SQLite, plugins |
| `/root/grafana-credentials.txt` | URL, usuario y clave (modo 600) |

Logs: `journalctl -u grafana-server -f`

## Después de instalar

- **Cambiar la clave del admin**: `sudo -u grafana grafana-cli admin reset-admin-password 'NUEVA'`
- **TLS**: publicarlo detrás de Nginx Proxy Manager o Caddy y arrancar con `--domain` para que `root_url` sea correcto (si no, los enlaces de share y los redirects salen con la IP).
- **Actualizar de versión** (rompe el pin a propósito):
  ```bash
  apt-mark unhold grafana
  rm /etc/apt/preferences.d/99-grafana-pin
  apt-get update && apt-get install -y grafana=12.4.7
  ```

## Desinstalar

```bash
bash /root/install.sh uninstall              # conserva datos y config
bash /root/install.sh uninstall --purge-data # borra todo
```

## Licencia

Grafana OSS es AGPLv3 (Grafana Labs). Este instalador es un script propio, sin garantía.
