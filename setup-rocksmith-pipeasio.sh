#!/usr/bin/env bash
# =============================================================================
# Rocksmith 2014 en Arch/CachyOS: PipeASIO + RS_ASIO + REAPER nativo
#
# Reproduce la instalación validada el 2026-11-17 en CachyOS.
#   Cadena:  Interfaz USB -> REAPER (efectos) -> PipeASIO -> Rocksmith -> salida
#
# El script asume PipeWire + GE-Proton con WoW64 ya instalados.
# Cada paso se detiene si falla. Respalda TODO antes de tocar nada.
# =============================================================================
set -euo pipefail

STEAM_DIR="${STEAM_DIR:-$HOME/.local/share/Steam}"
APPID="221680"
PROTON_NAME="${PROTON_NAME:-GE-Proton11-12-x86_64}"   # carpeta dentro de compatibilitytools.d
PIPEASIO_VER="v1.10.0"
GAME_DIR="${GAME_DIR:-}"                              # se autodetecta si se deja vacío
RUN_STEAM=0                                           # 1 = abrir Steam al final

c_info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m AVISO:\033[0m %s\n' "$*"; }
c_die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
ask()    { read -r -p "$1 [s/N] " R; [ "${R,,}" = "s" ]; }

# ----------------------------------------------------------------- detección
for d in "$STEAM_DIR/steamapps" /mnt/HDD/SteamLibrary/steamapps \
         "$STEAM_DIR/../Steam/steamapps"; do
    if [ -d "$d/common/Rocksmith2014" ]; then GAME_DIR="${GAME_DIR:-$d/common/Rocksmith2014}"; fi
    if [ -d "$d/compatdata/$APPID" ];      then PFX="${PFX:-$d/compatdata/$APPID/pfx}"; fi
done
GAME_DIR="${GAME_DIR:?No encontré Rocksmith2014; define GAME_DIR=... y reintenta}"
PFX="${PFX:?No encontré el prefijo; abre el juego una vez en Steam y reintenta}"
CONFIG_VDF="$STEAM_DIR/config/config.vdf"
LOCALCONFIG="$(find "$STEAM_DIR/userdata" -maxdepth 3 -name localconfig.vdf | xargs grep -l "\"$APPID\"" 2>/dev/null | head -1 || true)"
BACKUP="$HOME/.local/share/rocksmith-linux/backups/pipeasio-$(date +%Y%m%d-%H%M%S)"

c_info "Juego:      $GAME_DIR"
c_info "Prefijo:    $PFX"
c_info "Proton:     $PROTON_NAME"
c_info "Respaldos:  $BACKUP"

# ----------------------------------------------------------------- paso 0
c_info "Comprobando requisitos"
command -v pw-dump     >/dev/null || c_die "PipeWire no está corriendo"
[ -d "$STEAM_DIR/compatibilitytools.d/$PROTON_NAME/files" ] \
    || c_die "No existe compatibilitytools.d/$PROTON_NAME (descárgalo de GE-Proton releases)"
pkg_missing=""
for p in umu-launcher qpwgraph pavucontrol base-devel cmake; do
    pacman -Q "$p" >/dev/null 2>&1 || pkg_missing="$pkg_missing $p"
done
pacman -Q wine-staging >/dev/null 2>&1 || pacman -Q wine >/dev/null 2>&1 || pkg_missing="$pkg_missing wine-staging"
if [ -n "$pkg_missing" ]; then
    c_warn "Instalando paquetes faltantes:$pkg_missing (pedirá sudo)"
    sudo pacman -S --needed --noconfirm $pkg_missing
fi
pw-dump | grep -q '"alsa.card"' || c_warn "No veo hardware de audio ALSA en PipeWire"

# ----------------------------------------------------------------- paso 1
c_info "Respaldando estado actual"
mkdir -p "$BACKUP/steam-config" "$BACKUP/game" "$BACKUP/compatdata"
cp -a "$(dirname "$PFX")" "$BACKUP/compatdata/"
for f in RS_ASIO.ini Rocksmith.ini RS_ASIO-log.txt RSMods RSMods.ini \
         avrt.dll RS_ASIO.dll xinput1_3.dll D3DX9_42.dll; do
    [ -e "$GAME_DIR/$f" ] && cp -a "$GAME_DIR/$f" "$BACKUP/game/"
done
cp -a "$CONFIG_VDF" "$BACKUP/steam-config/" 2>/dev/null || true
[ -n "$LOCALCONFIG" ] && cp -a "$LOCALCONFIG" "$BACKUP/steam-config/"

# ----------------------------------------------------------------- paso 2
c_info "Descargando PipeASIO $PIPEASIO_VER y verificando SHA256"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BURL="https://github.com/M0n7y5/pipeasio/releases/download/$PIPEASIO_VER"
curl -fsSL -o "$TMP/pa.tar.gz"        "$BURL/pipeasio-$PIPEASIO_VER-archlinux-x86_64.tar.gz"
curl -fsSL -o "$TMP/pa.tar.gz.sha256" "$BURL/pipeasio-$PIPEASIO_VER-archlinux-x86_64.tar.gz.sha256"
( cd "$TMP" && sha256sum -c pa.tar.gz.sha256 --quiet ) || c_die "SHA256 inválido"
tar -xzf "$TMP/pa.tar.gz" -C "$HOME/.local"
find "$HOME/.local/lib/wine" -name "pipeasio*" | sort

# ----------------------------------------------------------------- paso 3
c_info "Cerrando Steam para editar su configuración"
if pgrep -x steam >/dev/null; then
    steam -shutdown || true
    for _ in $(seq 1 45); do pgrep -x steam >/dev/null || break; sleep 2; done
    pgrep -x steam >/dev/null && c_die "Steam no cerró; ciérralo a mano y reintenta"
fi
ask "¿Fijar compat tool '$PROTON_NAME' y opciones de lanzamiento en Steam?" && FIX_STEAM=1 || FIX_STEAM=0
if [ "$FIX_STEAM" = 1 ]; then
    python3 - "$CONFIG_VDF" "$LOCALCONFIG" "$APPID" "$PROTON_NAME" "$HOME" <<'PYEOF'
import sys, re
config_vdf, localconfig, appid, proton, home = sys.argv[1:6]
s = open(config_vdf).read()
pat = re.compile(r'("%s"\s*\{\s*\n\s*"name"\s+)"([^"]*)"' % appid)
s, n = pat.subn(lambda m: m.group(1) + '"%s"' % proton, s, count=1)
assert n == 1, "No encontré CompatToolMapping del appid en config.vdf"
open(config_vdf, 'w').write(s)
print("  config.vdf: compat tool =", proton)

lo = ('PROTON_USE_WOW64=1 '
      'WINEDLLPATH=%s/.local/lib/wine '
      'WINEDLLOVERRIDES=\\"avrt,d3dx9_42=n,b;xinput1_3=b\\" '
      'PIPEASIO_CLIENT_NAME=RS '
      'PIPEASIO_CONNECT_TO_HARDWARE=off %%command%%' % home)
s = open(localconfig).read()
pat = re.compile(r'("%s"\s*\{(?:[^{}"]|"[^"]*")*?"LaunchOptions"\s+)"([^"]*)"' % appid, re.S)
m = pat.search(s)
assert m, "No encontré LaunchOptions del appid en localconfig.vdf"
s = s[:m.start(2)] + lo + s[m.end(2):]
open(localconfig, 'w').write(s)
print("  localconfig.vdf: launch options escritas")
print("  IMPORTANTE: el ; de WINEDLLOVERRIDES va con comillas escapadas; sin")
print("  ellas Steam parte la línea y WOW64/WINEDLLPATH no llegan al juego.")
PYEOF
fi

# ----------------------------------------------------------------- paso 4
c_info "Limpiando el juego y creando prefijo nuevo"
ask "¿Apartar mods y proxies del juego (RSMods, avrt, xinput, d3dx9) para el primer arranque?" && CLEAN_GAME=1 || CLEAN_GAME=0
if [ "$CLEAN_GAME" = 1 ]; then
    mkdir -p "$BACKUP/game/apartados"
    for f in RSMods RSMods.ini RS_ASIO.dll RS_ASIO.ini avrt.dll D3DX9_42.dll xinput1_3.dll xinput1_3.pdb; do
        [ -e "$GAME_DIR/$f" ] && mv "$GAME_DIR/$f" "$BACKUP/game/apartados/"
    done
fi
[ -f "$GAME_DIR/Rocksmith.ini" ] && mv "$GAME_DIR/Rocksmith.ini" "$BACKUP/game/"
ask "¿Borrar el prefijo viejo de compatdata/$APPID (ya respaldado) para crear uno limpio?" \
    && rm -rf "$(dirname "$PFX")"

c_info "Abriendo Steam para el primer arranque (se creará el prefijo con WoW64)"
ask "¿Abrir Steam ahora? El juego debe llegar al menú y lo cierras tú." \
    && RUN_STEAM=1
if [ "$RUN_STEAM" = 1 ]; then
    nohup steam -applaunch "$APPID" >/dev/null 2>&1 || true
    c_warn "Espera al menú del juego y ciérralo; vuelve cuando esté cerrado."
    read -r -p "Pulsa Enter cuando el juego esté cerrado..."
    [ -f "$GAME_DIR/Rocksmith.ini" ] && c_info "Rocksmith.ini regenerado ✓"
fi

# ----------------------------------------------------------------- paso 5
c_info "Registrando PipeASIO en el prefijo vía umu-run"
WINEPREFIX="$PFX" WINE=umu-run \
PROTONPATH="$STEAM_DIR/compatibilitytools.d/$PROTON_NAME" \
GAMEID="umu-$APPID" PATH="$HOME/.local/bin:$PATH" \
    pipeasio-register 2>&1 | grep -E "registered|front end|ERROR" || true

# ----------------------------------------------------------------- paso 6
c_info "Restaurando RS_ASIO (proxy avrt + dll) y configurándolo para PipeASIO"
[ -f "$BACKUP/game/apartados/RS_ASIO.dll" ] && cp "$BACKUP/game/apartados/RS_ASIO.dll" "$GAME_DIR/"
[ -f "$BACKUP/game/apartados/avrt.dll" ]    && cp "$BACKUP/game/apartados/avrt.dll"    "$GAME_DIR/"
[ -f "$BACKUP/game/apartados/RS_ASIO.ini" ] || touch "$BACKUP/game/apartados/RS_ASIO.ini"
cat > "$GAME_DIR/RS_ASIO.ini" <<'EOF'
[Config]
EnableWasapiOutputs=0
EnableWasapiInputs=0
EnableAsio=1

[Asio]
BufferSizeMode=driver
CustomBufferSize=

[Asio.Output]
Driver=PipeASIO
BaseChannel=0
AltBaseChannel=
EnableSoftwareEndpointVolumeControl=1
EnableSoftwareMasterVolumeControl=1
SoftwareMasterVolumePercent=100
EnableRefCountHack=

[Asio.Input.0]
Driver=PipeASIO
Channel=0
EnableSoftwareEndpointVolumeControl=1
EnableSoftwareMasterVolumeControl=1
SoftwareMasterVolumePercent=100
EnableRefCountHack=

[Asio.Input.1]
Driver=
Channel=1
EnableSoftwareEndpointVolumeControl=1
EnableSoftwareMasterVolumeControl=1
SoftwareMasterVolumePercent=100
EnableRefCountHack=

[Asio.Input.Mic]
Driver=
Channel=1
EnableSoftwareEndpointVolumeControl=1
EnableSoftwareMasterVolumeControl=1
SoftwareMasterVolumePercent=100
EnableRefCountHack=
EOF

c_info "Config global de PipeASIO: 256 muestras, 48 kHz, sin autoconexión"
mkdir -p "$HOME/.config/pipeasio"
cat > "$HOME/.config/pipeasio/config.ini" <<'EOF'
[pipeasio]
inputs = 2
outputs = 2
buffer_size = 256
sample_rate = 48000
auto_connect = 0
EOF

# ----------------------------------------------------------------- paso 7
c_info "Recuperando mods (RSMods, xinput, d3dx9)"
if [ "$CLEAN_GAME" = 1 ]; then
    for f in RSMods RSMods.ini xinput1_3.dll D3DX9_42.dll xinput1_3.pdb; do
        [ -e "$BACKUP/game/apartados/$f" ] && cp -a "$BACKUP/game/apartados/$f" "$GAME_DIR/"
    done
fi

c_info "TERMINADO. Valida así:"
echo "  1. steam -applaunch $APPID  → menú con audio (nodo 'RS' en qpwgraph)"
echo "  2. Conecta RS:out_1/out_2 a tu salida en qpwgraph la primera vez"
echo "  3. REAPER + tu proyecto: interfaz → REAPER → RS:in_1"
echo "Respaldos en: $BACKUP"
