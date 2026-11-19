#!/usr/bin/env bash
# =============================================================================
# Rocksmith 2014 en Arch/CachyOS: PipeASIO + RS_ASIO + salida ASIO
#
# Cadena:  Interfaz USB -> (REAPER/JACK opcional) -> PipeASIO -> Rocksmith -> salida
#
# Requisitos: Steam nativo + PipeWire >= 1.4.2 + GE-Proton con WoW64.
# Todo lo que modifica se respalda antes. Se puede sobrescribir con variables:
#   STEAM_DIR=...  GAME_DIR=...  PROTON_NAME=...  LOCAL_PREFIX=...
#   PIPEASIO_VER=v1.10.0  RS_ASIO_VER=v0.7.5  BUFFER_SIZE=256  SAMPLE_RATE=48000
# =============================================================================
set -euo pipefail

APPID="221680"
STEAM_DIR="${STEAM_DIR:-}"
GAME_DIR="${GAME_DIR:-}"
PROTON_NAME="${PROTON_NAME:-}"
LOCAL_PREFIX="${LOCAL_PREFIX:-$HOME/.local}"
PIPEASIO_VER="${PIPEASIO_VER:-v1.10.0}"
RS_ASIO_VER="${RS_ASIO_VER:-v0.7.5}"
BUFFER_SIZE="${BUFFER_SIZE:-256}"
SAMPLE_RATE="${SAMPLE_RATE:-48000}"
BACKUP_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/rocksmith-pipeasio/backups"

c_info() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m AVISO:\033[0m %s\n' "$*"; }
c_die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
ask()    { read -r -p "$1 [s/N] " R; [ "${R,,}" = "s" ]; }
ask_def() { read -r -p "$1 [S/n] " R; [ "${R,,}" != "n" ]; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    awk 'NR>1 { if (/^#/) { sub(/^# ?/, ""); print } else exit }' "$0"
    exit 0
fi

[ "$(id -u)" -ne 0 ] || c_die "No ejecutes como root; usa tu usuario normal (sudo se pide solo)."
command -v pacman >/dev/null || c_die "Este script es para Arch Linux o derivados (requiere pacman)."

# --------------------------------------------------------------- localización
c_info "Localizando Steam y Rocksmith 2014"
if [ -z "$STEAM_DIR" ]; then
    for d in "$HOME/.steam/steam" "$HOME/.local/share/Steam" \
             "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        [ -f "$d/config/config.vdf" ] && { STEAM_DIR="$d"; break; }
    done
fi
[ -n "$STEAM_DIR" ] || c_die "No encontré Steam nativo. Define STEAM_DIR=/ruta/a/Steam"
[ -f "$STEAM_DIR/config/config.vdf" ] || c_die "STEAM_DIR=$STEAM_DIR no parece una instalación de Steam"

LIB_ROOTS="$STEAM_DIR"
if [ -f "$STEAM_DIR/steamapps/libraryfolders.vdf" ]; then
    LIB_ROOTS="$LIB_ROOTS
$(grep -oP '"path"\s+"\K[^"]+' "$STEAM_DIR/steamapps/libraryfolders.vdf")"
fi
if [ -z "$GAME_DIR" ]; then
    while IFS= read -r lib; do
        [ -n "$lib" ] || continue
        [ -d "$lib/steamapps/common/Rocksmith2014" ] \
            && { GAME_DIR="$lib/steamapps/common/Rocksmith2014"; break; }
    done <<< "$LIB_ROOTS"
fi
[ -n "$GAME_DIR" ] || c_die "Rocksmith 2014 no instalado. Instálalo en Steam o define GAME_DIR=..."
[ -d "$GAME_DIR" ] || c_die "GAME_DIR=$GAME_DIR no existe"
GAME_LIB="$(dirname "$(dirname "$GAME_DIR")")"
PFX="$GAME_LIB/compatdata/$APPID/pfx"

if [ -z "$PROTON_NAME" ]; then
    for d in $(ls -d "$STEAM_DIR/compatibilitytools.d"/GE-Proton* 2>/dev/null | sort -V -r); do
        [ -d "$d/files/lib/wine/i386-windows" ] || continue
        grep -qi wow64 "$d/proton" 2>/dev/null || continue
        PROTON_NAME="$(basename "$d")"; break
    done
fi
[ -n "$PROTON_NAME" ] || c_die "No encontré ningún GE-Proton con WoW64 en compatibilitytools.d.
Descarga la última release desde https://github.com/GloriousEggroll/proton-ge-custom/releases
o pasa PROTON_NAME=<carpeta exacta>."
RUNNER_DIR="$STEAM_DIR/compatibilitytools.d/$PROTON_NAME"
[ -d "$RUNNER_DIR/files" ] || c_die "No existe $RUNNER_DIR"
grep -qi wow64 "$RUNNER_DIR/proton" 2>/dev/null \
    || c_die "$PROTON_NAME no soporta WoW64 (PipeASIO 32-bit no funcionará). Usa GE-Proton 10+."

CONFIG_VDF="$STEAM_DIR/config/config.vdf"
mapfile -t LOCALCONFIGS < <(find "$STEAM_DIR/userdata" -maxdepth 3 -name localconfig.vdf -print0 2>/dev/null \
    | xargs -0 -r grep -lZ "\"$APPID\"" 2>/dev/null | tr '\0' '\n' || true)
[ "${#LOCALCONFIGS[@]}" -gt 0 ] || c_die "Ningún localconfig.vdf contiene el appid $APPID.
Abre el juego una vez en Steam y reintenta."

BACKUP="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
c_info "Juego:      $GAME_DIR"
c_info "Prefijo:    $PFX"
c_info "Proton:     $PROTON_NAME"
c_info "Respaldos:  $BACKUP"

# -------------------------------------------------------------- requisitos
c_info "Comprobando requisitos"
command -v pw-dump >/dev/null || c_die "PipeWire no está activo (necesitas PipeWire, no PulseAudio)"
PW_VER="$(pipewire --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || true)"
if [ -n "$PW_VER" ] && [ "$(printf '%s\n1.4.2\n' "$PW_VER" | sort -V | head -1)" != "1.4.2" ]; then
    c_warn "PipeWire $PW_VER < 1.4.2: la escritura de búfer de PipeASIO puede no funcionar."
fi
id -nG "$USER" | grep -qw audio || c_warn "Tu usuario no está en el grupo 'audio'."

pkgs=()
for p in umu-launcher qpwgraph unzip curl; do
    pacman -Q "$p" >/dev/null 2>&1 || pkgs+=("$p")
done
if [ "${#pkgs[@]}" -gt 0 ]; then
    c_warn "Faltan paquetes: ${pkgs[*]}"
    if ask "¿Instalarlos con pacman? (pedirá sudo)"; then
        sudo pacman -S --needed --noconfirm "${pkgs[@]}" || c_die "Instalación de paquetes falló"
    fi
fi
command -v pipeasio-register >/dev/null 2>&1 || [ -x "$LOCAL_PREFIX/bin/pipeasio-register" ] \
    || c_warn "PipeASIO aún no está instalado; se instalará en el siguiente paso."

# ---------------------------------------------------------------- respaldo
c_info "Respaldando estado actual"
mkdir -p "$BACKUP/game" "$BACKUP/steam-config" "$BACKUP/compatdata"
[ -d "$(dirname "$PFX")" ] && cp -a "$(dirname "$PFX")" "$BACKUP/compatdata/" || c_warn "Aún no existe compatdata/$APPID (normal en instalación nueva)"
for f in RS_ASIO.ini Rocksmith.ini RS_ASIO-log.txt RSMods RSMods.ini \
         avrt.dll RS_ASIO.dll xinput1_3.dll xinput1_3.pdb D3DX9_42.dll; do
    [ -e "$GAME_DIR/$f" ] && cp -a "$GAME_DIR/$f" "$BACKUP/game/"
done
cp -a "$CONFIG_VDF" "$BACKUP/steam-config/"
for c in "${LOCALCONFIGS[@]}"; do
    acct="$(basename "$(dirname "$(dirname "$c")")")"
    mkdir -p "$BACKUP/steam-config/$acct"
    cp -a "$c" "$BACKUP/steam-config/$acct/"
done

MODS=0
{ [ -d "$GAME_DIR/RSMods" ] || [ -f "$GAME_DIR/RSMods.ini" ] \
  || [ -f "$GAME_DIR/xinput1_3.dll" ] || [ -f "$GAME_DIR/D3DX9_42.dll" ]; } && MODS=1
RSASI0=0
{ [ -f "$GAME_DIR/RS_ASIO.dll" ] && [ -f "$GAME_DIR/avrt.dll" ]; } && RSASI0=1

# --------------------------------------------------------------- PipeASIO
c_info "Instalando PipeASIO $PIPEASIO_VER en $LOCAL_PREFIX"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BURL="https://github.com/M0n7y5/pipeasio/releases/download/$PIPEASIO_VER"
TARBALL="pipeasio-$PIPEASIO_VER-archlinux-x86_64.tar.gz"
curl -fsSL -o "$TMP/$TARBALL" "$BURL/$TARBALL"
curl -fsSL -o "$TMP/$TARBALL.sha256" "$BURL/$TARBALL.sha256"
EXPECTED="$(cut -d' ' -f1 "$TMP/$TARBALL.sha256")"
ACTUAL="$(sha256sum "$TMP/$TARBALL" | cut -d' ' -f1)"
[ "$EXPECTED" = "$ACTUAL" ] || c_die "SHA256 inválido: esperado $EXPECTED, obtenido $ACTUAL"
mkdir -p "$LOCAL_PREFIX"
tar -xzf "$TMP/$TARBALL" -C "$LOCAL_PREFIX"
export PATH="$LOCAL_PREFIX/bin:$PATH"
c_info "PipeASIO instalado ($(find "$LOCAL_PREFIX/lib/wine" -name 'pipeasio*' | wc -l) archivos)"

# ------------------------------------------------------------------- Steam
c_info "Configurando Steam (compat tool + opciones de lanzamiento)"
STOP_STEAM=0
if pgrep -x steam >/dev/null; then
    ask "Steam está abierto y hay que cerrarlo para editar su config. ¿Cerrarlo ahora?" \
        || c_die "Cierra Steam manualmente y vuelve a ejecutar el script."
    command -v steam >/dev/null || c_die "No encontré el binario 'steam'; ciérralo a mano y reintenta."
    steam -shutdown || true
    for _ in $(seq 1 45); do pgrep -x steam >/dev/null || break; sleep 2; done
    pgrep -x steam >/dev/null && c_die "Steam no cerró; ciérralo a mano y reintenta"
    STOP_STEAM=1
fi

python3 - "$CONFIG_VDF" "${LOCALCONFIGS[@]}" "$APPID" "$PROTON_NAME" "$LOCAL_PREFIX" <<'PYEOF'
import sys, re

config_vdf, *rest = sys.argv[1:]
appid, proton, prefix = rest[-3], rest[-2], rest[-1]
localconfigs = rest[:-3]

def match_close(s, o):
    depth = 0; inq = False; i = o
    while i < len(s):
        c = s[i]
        if inq:
            if c == '\\': i += 2; continue
            if c == '"': inq = False
        else:
            if c == '"': inq = True
            elif c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0: return i
        i += 1
    raise SystemExit("VDF malformado: llave sin cerrar")

def find_block(s, key, start=0):
    for m in re.finditer(r'"%s"[ \t]*\n?[ \t]*\{' % re.escape(key), s[start:]):
        o = start + m.end() - 1
        return o, match_close(s, o)
    return None

s = open(config_vdf).read()
sec = find_block(s, 'CompatToolMapping')
if not sec:
    raise SystemExit("No encontré 'CompatToolMapping' en config.vdf")
so, sc = sec
body = s[so:sc]
entry = find_block(body, appid)
if entry:
    eo, ec = entry
    inner = body[eo:ec]
    if re.search(r'"name"\s+"[^"]*"', inner):
        inner = re.sub(r'("name"\s+)"[^"]*"', lambda m: m.group(1) + '"%s"' % proton, inner, count=1)
    else:
        inner = inner[:1] + '\n\t\t\t\t\t\t"name"\t\t"%s"' % proton + inner[1:]
    body = body[:eo] + inner + body[ec:]
else:
    ind = re.match(r'\n([ \t]*)', body)
    ind = ind.group(1) if ind else '\t\t\t\t'
    body = body[:sc - so] + ('\n%s"%s"\n%s{\n%s\t"name"\t\t"%s"\n%s}\n'
                             % (ind, appid, ind, ind, proton, ind)) + body[sc - so:]
s = s[:so] + body + s[sc:]
open(config_vdf, 'w').write(s)
print("  config.vdf: compat tool de %s = %s" % (appid, proton))

lo = ('PROTON_USE_WOW64=1 '
      'WINEDLLPATH=%s/lib/wine '
      'WINEDLLOVERRIDES=\\"avrt,d3dx9_42=n,b;xinput1_3=b\\" '
      'PIPEASIO_CLIENT_NAME=RS '
      'PIPEASIO_CONNECT_TO_HARDWARE=off %%command%%' % prefix)

for path in localconfigs:
    s = open(path).read()
    root = find_block(s, 'UserLocalConfigStore')
    base, end = (root if root else (0, len(s)))
    scope = s[base:end]
    cands = []
    for m in re.finditer(r'"%s"[ \t]*\n?[ \t]*\{' % re.escape(appid), scope):
        o = m.end() - 1
        c = match_close(scope, o)
        body = scope[o:c]
        score = sum(k in body for k in ('LaunchOptions', 'LastPlayed', 'Playtime'))
        cands.append((score, o, c))
    if not cands:
        print("  AVISO: %s sin bloque de %s; edítalo a mano" % (path, appid)); continue
    _, o, c = max(cands, key=lambda t: t[0])
    body = scope[o:c]
    m = re.search(r'("LaunchOptions"[ \t]+)"([^"]*)"', body)
    if m:
        body = body[:m.start(2)] + lo + body[m.end(2):]
    else:
        ind = re.match(r'\n([ \t]*)', body)
        ind = ind.group(1) if ind else '\t\t\t\t\t'
        body = body[:1] + '\n%s"LaunchOptions"\t\t"%s"' % (ind, lo) + body[1:]
    scope = scope[:o] + body + scope[c:]
    s = s[:base] + scope + s[end:]
    open(path, 'w').write(s)
    print("  %s: launch options escritas" % path)

print()
print("  Las comillas escapadas de WINEDLLOVERRIDES son obligatorias: Steam")
print("  ejecuta las opciones con un shell y el ';' suelto partiría la línea.")
PYEOF

# ------------------------------------------------------------ primer arranque
c_info "Preparando el juego"
KEEP_MODS=0
if [ "$MODS" = 1 ]; then
    c_info "Detecté mods/proxies instalados (RSMods / xinput1_3 / D3DX9_42)"
    if ask_def "¿Conservarlos? Se apartan para el primer arranque y se restauran al final"; then
        KEEP_MODS=1
    fi
fi
mkdir -p "$BACKUP/game/apartados"
for f in RSMods RSMods.ini RS_ASIO.dll RS_ASIO.ini avrt.dll D3DX9_42.dll xinput1_3.dll xinput1_3.pdb; do
    [ -e "$GAME_DIR/$f" ] && mv "$GAME_DIR/$f" "$BACKUP/game/apartados/"
done
[ -f "$GAME_DIR/Rocksmith.ini" ] && mv "$GAME_DIR/Rocksmith.ini" "$BACKUP/game/"

if [ -d "$(dirname "$PFX")" ]; then
    if ask "¿Borrar el prefijo actual de compatdata/$APPID (respaldo ya hecho) para recrearlo con WoW64?"; then
        rm -rf "$(dirname "$PFX")"
    else
        c_warn "Se conserva el prefijo existente: si fue creado por otro Proton sin WoW64,"
        c_warn "el registro de PipeASIO puede fallar. En ese caso vuelve a ejecutar el script."
    fi
fi

c_info "Primer arranque: crea el prefijo con WoW64 y regenera Rocksmith.ini"
if ask "¿Abrir Steam y lanzar Rocksmith ahora? Llega al menú y ciérralo tú."; then
    nohup steam -applaunch "$APPID" >/dev/null 2>&1 || true
    read -r -p "Pulsa Enter cuando el juego esté cerrado..."
    [ -d "$PFX" ] || c_die "El prefijo no se creó; ¿llegó el juego a abrirse?"
    [ -f "$GAME_DIR/Rocksmith.ini" ] && c_info "Rocksmith.ini regenerado ✓"
else
    c_warn "Sin primer arranque no habrá prefijo para registrar PipeASIO."
    [ -d "$PFX" ] || c_die "Prefijo inexistente; abre el juego una vez con Steam y reintenta."
fi

# ------------------------------------------------------------- registro
c_info "Registrando PipeASIO dentro del prefijo vía umu-run"
REG_LOG="$(WINEPREFIX="$PFX" WINE=umu-run PROTONPATH="$RUNNER_DIR" \
           GAMEID="umu-$APPID" PATH="$LOCAL_PREFIX/bin:$PATH" \
           pipeasio-register 2>&1 || true)"
printf '%s\n' "$REG_LOG" | grep -E "registered|front end|ERROR" || true
grep -qi "registered" <<< "$REG_LOG" \
    || c_die "PipeASIO no se registró. Revisa: WINEPREFIX=$PFX WINE=umu-run PROTONPATH=$RUNNER_DIR GAMEID=umu-$APPID pipeasio-register"

# --------------------------------------------------------------- RS_ASIO
c_info "Instalando RS_ASIO ($RS_ASIO_VER) configurado para PipeASIO"
if [ -f "$BACKUP/game/apartados/RS_ASIO.dll" ] && [ -f "$BACKUP/game/apartados/avrt.dll" ]; then
    cp "$BACKUP/game/apartados/RS_ASIO.dll" "$BACKUP/game/apartados/avrt.dll" "$GAME_DIR/"
elif [ "$RSASI0" = 1 ] && [ -f "$BACKUP/game/RS_ASIO.dll" ] && [ -f "$BACKUP/game/avrt.dll" ]; then
    cp "$BACKUP/game/RS_ASIO.dll" "$BACKUP/game/avrt.dll" "$GAME_DIR/"
else
    c_info "No había RS_ASIO; descargando release oficial $RS_ASIO_VER"
    curl -fsSL -o "$TMP/rsasio.zip" \
        "https://github.com/mdias/rs_asio/releases/download/$RS_ASIO_VER/release-${RS_ASIO_VER#v}.zip"
    unzip -o -j "$TMP/rsasio.zip" avrt.dll RS_ASIO.dll -d "$GAME_DIR" >/dev/null
fi
[ -f "$GAME_DIR/avrt.dll" ] || c_die "No se pudo instalar avrt.dll (proxy de RS_ASIO)"
[ -f "$GAME_DIR/RS_ASIO.dll" ] || c_die "No se pudo instalar RS_ASIO.dll"

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

c_info "Config global de PipeASIO: ${BUFFER_SIZE} muestras, ${SAMPLE_RATE} Hz, sin autoconexión"
mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio"
cat > "${XDG_CONFIG_HOME:-$HOME/.config}/pipeasio/config.ini" <<EOF
[pipeasio]
inputs = 2
outputs = 2
buffer_size = $BUFFER_SIZE
sample_rate = $SAMPLE_RATE
auto_connect = 0
EOF

# ------------------------------------------------------------------- mods
if [ "$KEEP_MODS" = 1 ]; then
    c_info "Restaurando mods"
    for f in RSMods RSMods.ini xinput1_3.dll D3DX9_42.dll xinput1_3.pdb; do
        [ -e "$BACKUP/game/apartados/$f" ] && cp -a "$BACKUP/game/apartados/$f" "$GAME_DIR/"
    done
else
    c_info "Mods no restaurados (quedaron en $BACKUP/game/apartados)"
fi

c_info "TERMINADO"
cat <<EOF
  Valida:
   1. steam -applaunch $APPID  -> nodo "RS" (2 in / 2 out, $BUFFER_SIZE/$SAMPLE_RATE) en qpwgraph
   2. Conecta RS:out_1/RS:out_2 a tu salida la primera vez
   3. Si usas REAPER/JACK: interfaz -> REAPER -> RS:in_1 (y RS:out_* -> salida)
   4. Audio del juego en RS_ASIO-log.txt del directorio del juego
  Respaldos: $BACKUP
  Ajuste de latencia: LatencyBuffer en Rocksmith.ini (4 -> 3 -> 2) y
  buffer_size/sample_rate aquí arriba si necesitas más o menos estabilidad.
EOF
