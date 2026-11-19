# Rocksmith 2014 en Linux — PipeASIO + RS_ASIO

> Este script nació como setup personal (desarrollado con ayuda de IA) y se
> generalizó para que sirva en cualquier PC Arch/CachyOS. Publícalo/forkéalo
> como base para tu propio montaje; si algo falla en tu hardware, revisa el
> log de RS_ASIO y la documentación de los proyectos enlazados abajo.

Script de instalación para Arch Linux / CachyOS que conecta Rocksmith 2014 a
PipeWire mediante [PipeASIO](https://github.com/M0n7y5/pipeasio) (puente
ASIO ⇄ PipeWire con soporte WoW64) y [RS_ASIO](https://github.com/mdias/rs_asio).

Opcionalmente permite intercalar **REAPER u otro host JACK**: la guitarra entra
por tu interfaz, pasa por tus efectos y la señal procesada llega al juego.

```
Interfaz USB ─┬─> Rocksmith (directo, por PipeASIO)
              └─> REAPER/JACK (efectos) ──> RS:in_1 (Rocksmith)
```

Probado en CachyOS con PipeWire 1.6.11, GE-Proton 11 y Steam nativo.
Basado en [la guía de nizo](https://codeberg.org/nizo/linux-rocksmith/src/branch/main/guides/setup/arch-pipeasio.md).

## Requisitos

- Arch Linux o derivado (CachyOS, EndeavourOS...). Steam **nativo**, no Flatpak.
- PipeWire ≥ 1.4.2 (con `pipewire-jack` si vas a usar REAPER).
- Rocksmith 2014 instalado y abierto al menos una vez (para que exista
  `localconfig.vdf` con el appid).
- Un Proton con **WoW64** en `compatibilitytools.d` (GE-Proton 10 o superior;
  el script elige el más reciente automáticamente).
- `umu-launcher`, `qpwgraph`, `unzip`, `curl` (el script ofrece instalarlos).

RS_ASIO y RSMods **no** son requisitos previos: si existen se conservan; si no,
el script descarga RS_ASIO oficial. PipeASIO se descarga y verifica su SHA256.

## Uso

```sh
chmod +x setup-rocksmith-pipeasio.sh
./setup-rocksmith-pipeasio.sh          # interactivo, cada paso pregunta
./setup-rocksmith-pipeasio.sh --help
```

El script detecta Steam, la biblioteca donde está el juego, el prefijo, el
Proton más reciente con WoW64 y **todas las cuentas** de Steam con el juego
(cada `localconfig.vdf` se respalda por cuenta y se actualiza), y respalda
todo antes de tocar nada en
`~/.local/share/rocksmith-pipeasio/backups/<fecha>/`.

### Qué hace

1. Comprueba requisitos (PipeWire, grupos, paquetes) e instala lo que falte.
2. Localiza juego/prefijo/Proton y **respalda** prefijo, configs de Steam y
   archivos del juego.
3. Descarga PipeASIO (tarball Arch oficial) en `~/.local` verificando SHA256.
4. Con Steam cerrado, fija el compat tool y escribe las opciones de lanzamiento
   en `config.vdf` / `localconfig.vdf` (crea las entradas si no existen).
5. Aparta mods/proxies, borra `Rocksmith.ini` y (opcionalmente) el prefijo
   viejo para recrearlo limpio con WoW64.
6. Te pide abrir el juego una vez hasta el menú; luego registra PipeASIO
   **dentro de ese prefijo** usando `umu-run` (no el wine del sistema).
7. Instala/conserva RS_ASIO (`avrt.dll` + `RS_ASIO.dll`) y lo configura con
   `Driver=PipeASIO`.
8. Escribe la configuración global de PipeASIO (2 in / 2 out, 256 muestras,
   48 kHz, sin autoconexión) y restaura los mods si los había.

### Variables de entorno

| Variable | Default | Uso |
|---|---|---|
| `STEAM_DIR` | autodetectado | raíz de Steam |
| `GAME_DIR` | autodetectado | carpeta de Rocksmith2014 |
| `PROTON_NAME` | GE-Proton más nuevo con WoW64 | carpeta en compatibilitytools.d |
| `LOCAL_PREFIX` | `~/.local` | destino de PipeASIO |
| `PIPEASIO_VER` | `v1.10.0` | versión del tarball |
| `RS_ASIO_VER` | `v0.7.5` | versión a descargar si falta |
| `BUFFER_SIZE` | `256` | muestras por periodo |
| `SAMPLE_RATE` | `48000` | frecuencia |

## Verificación

```sh
GAME_DIR="$HOME/.steam/steam/steamapps/common/Rocksmith2014"   # ajusta si aplica

# El nodo del juego aparece en PipeWire (2 in / 2 out, quantum 256):
pw-dump | grep -A3 '"node.name": "RS"'

# RS_ASIO inicializó (fecha del log = arranque actual):
ls -l "$GAME_DIR/RS_ASIO-log.txt"   # y busca "buffer switch"

# El juego tiene las variables correctas:
tr '\0' '\n' < /proc/$(pgrep -f Rocksmith2014.exe | head -1)/environ \
  | grep -E "WOW64|WINEDLL|PIPEASIO"
```

Conexiones (qpwgraph o `pw-link`): `RS:out_1/2` → tu salida; y si usas REAPER,
`interfaz → REAPER` y `REAPER → RS:in_1`. Con `pipeasio-settings` (requiere
Qt6) puedes ajustar el driver; el panel solo funciona con el búfer detenido.

## Latencia

- `LatencyBuffer` en `Rocksmith.ini`: prueba 4 → 3 → 2 hasta que aparezcan
  crujidos (−5 ms por paso).
- `BUFFER_SIZE` (PipeASIO): 256 → 128 baja ~2,7 ms; si cruje, vuelve a 256.
- Host JACK (REAPER): 256 muestras y 2–3 períodos es un buen equilibrio.
- Mide con `pw-top`: columnas `ERR` (xruns) y `BUSY` del nodo `RS`.

## Desinstalar / rollback

Restaura `compatdata/`, los `.vdf` y los archivos del juego desde el respaldo;
los mods apartados están en `<respaldo>/game/apartados/`. Borra
`~/.config/pipeasio` y `~/.local/lib/wine/pipeasio*` para quitar el driver.

## Licencias

- Este repo: uso libre.
- [PipeASIO](https://github.com/M0n7y5/pipeasio): GPL-3.0.
- [RS_ASIO](https://github.com/mdias/rs_asio): MIT.
- Guía base de [nizo](https://codeberg.org/nizo/linux-rocksmith): CC-BY-SA-4.0.
