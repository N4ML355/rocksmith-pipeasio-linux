# Rocksmith 2014 en Linux (CachyOS/Arch) — PipeASIO + REAPER nativo

Setup para tocar guitarra con latencia baja: la señal entra por una interfaz
USB, pasa por efectos en REAPER (nativo, sobre JACK/PipeWire) y llega al juego
por PipeASIO. Probado en CachyOS el **2026-11-17** con:

| Componente     | Versión                                  |
|----------------|------------------------------------------|
| CachyOS        | rolling, kernel 7.3.4-1-cachyos          |
| PipeWire       | 1.6.11 (mínimo requerido: 1.4.2)         |
| Proton         | GE-Proton11-12 (soporte WoW64)           |
| PipeASIO       | v1.10.0 (tarball oficial Arch, con WoW64)|
| RS_ASIO        | v0.7.5                                   |
| umu-launcher   | 1.4.3                                    |
| REAPER         | nativo, sesión JACK sobre PipeWire       |

Basado en [la guía de nizo](https://codeberg.org/nizo/linux-rocksmith/src/branch/main/guides/setup/arch-pipeasio.md)
y en la [documentación oficial de PipeASIO](https://github.com/M0n7y5/pipeasio).

## Cadena de audio

```
Interfaz USB (input físico 2)
        ↓
REAPER (nativo) → Brusfri → Re-Guitar → pitch shifter
        ↓ (out3)
PipeWire ── PipeASIO (WoW64) ── RS_ASIO ── Rocksmith 2014
        ↓ (out_1/out_2 del juego)
Salida (auriculares G933 o interfaz USB)
```

Para tocar sin el juego: interfaz → REAPER → Neural DSP / AmpliTube → salida.

## Qué hace el script

`setup-rocksmith-pipeasio.sh` automatiza, con respaldos y confirmaciones:

1. **Requisitos**: comprueba PipeWire, GE-Proton y los paquetes necesarios
   (`umu-launcher`, `wine-staging`, `qpwgraph`, `pavucontrol`).
2. **Respaldo completo**: prefijo de Steam, `RS_ASIO.ini`, `Rocksmith.ini`,
   mods, `config.vdf` y `localconfig.vdf` antes de tocar nada.
3. **PipeASIO**: descarga el tarball oficial `v1.10.0` para Arch, **verifica el
   SHA256** e instala en `~/.local` (user-local, que es lo que ve Proton).
4. **Steam (cerrado)**: fija la compat tool a GE-Proton y escribe las opciones
   de lanzamiento del juego.
5. **Prefijo limpio**: aparta mods/proxies, borra `Rocksmith.ini` y el prefijo
   viejo; abres el juego una vez para regenerarlos con WoW64.
6. **Registro**: registra PipeASIO en el prefijo **a través del runner**
   (`umu-run`), nunca con el wine del host.
7. **RS_ASIO**: instala el proxy `avrt.dll` + `RS_ASIO.dll` y configura
   `Driver=PipeASIO` en todas las secciones.
8. **PipeASIO global**: 2 entradas, 2 salidas, 256 muestras, 48 kHz,
   `auto_connect = 0` (el enrutado se controla con qpwgraph).
9. **Mods**: recupera RSMods y las DLL restantes.

```sh
chmod +x setup-rocksmith-pipeasio.sh
./setup-rocksmith-pipeasio.sh
```

## Las tres trampas que costaron encontrar

1. **El `;` en las opciones de lanzamiento de Steam.** Steam ejecuta las
   opciones con un shell: un punto y coma suelto parte la línea en dos y las
   variables anteriores (`PROTON_USE_WOW64`, `WINEDLLPATH`) *desaparecen*.
   El juego abre, pero RS_ASIO falla con
   `cannot load pipeasio32.so: needs new WoW64 and WINEDLLPATH`.
   Solución: comillas escapadas alrededor del **valor**:
   `WINEDLLOVERRIDES="avrt,d3dx9_42=n,b;xinput1_3=b"`.
   (Comillas alrededor de `NOMBRE=valor` también rompen todo: bash deja de
   tratarlo como asignación y el juego directamente no abre.)

2. **`avrt.dll` es el cargador de RS_ASIO.** Sin el proxy `avrt.dll` en la
   carpeta del juego y sin `WINEDLLOVERRIDES=avrt=n,b`, Wine carga su avrt
   interno, RS_ASIO nunca se inicializa y el juego suena por WASAPI vanilla
   (el `RS_ASIO-log.txt` queda viejo — mira siempre su fecha).

3. **Registrar por el runner, no por el wine del host.** `pipeasio-register`
   con el wine del sistema re-estampa el prefijo para otra build de Wine.
   Siempre con `WINE=umu-run PROTONPATH=<proton> GAMEID=umu-221680`.

## Verificación rápida

```sh
# El juego registró el driver y suena:
grep "buffer switch" <carpeta del juego>/RS_ASIO-log.txt | head -3

# El nodo del juego existe en PipeWire (2 in / 2 out, 256/48000):
pw-dump | grep '"node.name": "RS"'

# El driver carga el WoW64 correcto:
tr '\0' '\n' < /proc/$(pgrep -f Rocksmith2014.exe | head -1)/environ | grep -E "WOW64|WINEDLL"
```

## Uso diario (con el workspace de REAPER ya montado)

```sh
~/.local/bin/guitarra rocksmith   # REAPER + juego + enrutamiento automático
~/.local/bin/guitarra tocar       # solo REAPER para tocar/grabar
~/.local/bin/guitarra afinacion   # panel de semitonos (ReaPitch)
~/.local/bin/guitarra salida g933 # cambiar salida
```

El servicio `guitarra-routing.service` mantiene las conexiones de PipeWire
cada 2 s: `interfaz → REAPER:in1`, `REAPER:out3 → RS:in_1` y las salidas
hacia los auriculares.

## Respaldos y rollback

Todo lo modificado queda en
`~/.local/share/rocksmith-linux/backups/pipeasio-<fecha>/`:
restaura `compatdata/`, los `.vdf` de Steam y los archivos del juego desde ahí
para volver al estado anterior.

## Licencias

- Este repo: uso libre.
- [PipeASIO](https://github.com/M0n7y5/pipeasio): GPL-3.0.
- [RS_ASIO](https://github.com/mdias/rs_asio): MIT.
- Guía base de [nizo](https://codeberg.org/nizo/linux-rocksmith): CC-BY-SA-4.0.
