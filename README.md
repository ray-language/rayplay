# RayPlay

Reproductor de audio mínimo escrito en [raylang](https://github.com/ray-language/raylang),
para **iPhone y Android** (y escritorio con el mismo fuente). Existe para una sola pregunta:
¿sigue sonando la app cuando pasa a segundo plano? En Ray808 no puede, porque su audio vive en
la página (Web Audio, que el webview congela). Aquí el sonido lo produce el **programa raylang**
con `std/audio`, y la página es solo la interfaz.

## Qué hace

- Tres pistas **procedurales** (un estudio pentatónico, un dron, un pulso de bajo), calculadas
  trozo a trozo: la app no lleva archivos de audio y ninguna pista ocupa memoria entera.
- **Cargar un WAV de 16 bits** desde la página (selector de archivos del webview) y añadirlo a
  la lista: el programa lo analiza (`src/wav.ray`) y lo reproduce a su frecuencia y canales.
- Play/pausa, stop, anterior/siguiente (con vuelta), **seek** tocando la barra, volumen, y al
  acabar una pista sigue con la siguiente.
- El display muestra el último evento `lifecycle` del shell (`background 12:01:03`) y **cuánto
  audio se reprodujo en segundo plano** desde entonces: la prueba de que no se paró.

## Arquitectura

```
┌──────────── webview del sistema ────────────┐
│  www/index.html   botones, lista, barra      │
│      │ window.ray.request({op, …})   ▲ JSON  │
└──────┼───────────────────────────────┼───────┘
       ▼                               │
┌────────── programa raylang (src/) ───┴─────────────────────────────┐
│  main.ray     ventana (std/ui), eventos: message, lifecycle, closed │
│  api.ray      protocolo: state, play, toggle, stop, next, prev,     │
│               seek, volume, add                                     │
│  player.ray   ACTOR: una fibra con el dispositivo (std/audio) y la  │
│               lista; comandos por canal; 50 ms por chunk            │
│  synth.ray    las pistas: procedurales o WAV cargado → s16le        │
│  wav.ray      lector/escritor RIFF/WAVE PCM 16 bits                 │
└────────────────────────────────────────────────────────────────────┘
```

- **El audio es del programa**: `audio.open_latency(rate, channels, 120)` + `audio.write` de
  50 ms por vuelta; `write` aparca la fibra cuando el dispositivo está lleno, así que el
  dispositivo marca el paso y los comandos se atienden entre chunk y chunk (`try_recv`).
- **Posición**: el dispositivo se reabre en cada play, seek y reanudación; `audio.played_ms`
  cuenta desde ahí y `base_ms` recuerda dónde iba la pista. La pausa cierra el dispositivo.
- **Segundo plano**: `[ios] background_audio = true` y `[android] background_audio = true` en
  `ray.toml` (raylang 1.27.19, M324): sesión `playback` + `UIBackgroundModes = audio` en iOS,
  *foreground service* `mediaPlayback` en Android. La página deja de pedir el estado cuando no
  se ve (sus timers se paran igualmente); el programa ni se entera.
- **Sin servidor local**: la página va embebida (`[native] embed = ["www"]`) y se sirve por
  `ray://app` con `ui.mount_embed_at("", "www")`; bajo `ray run` se lee del disco.

## Uso

```bash
make test            # 13 tests: WAV, pistas, el actor (con RAY_AUDIO_SINK=null), protocolo
make run             # ventana de escritorio
make bundle-ios      # proyecto Xcode en RayPlay-ios/ (iPhone + simulador)
make bundle-android  # proyecto Gradle en RayPlay-android/ (arm64)
make icon            # assets/icon.png, dibujado con std/image
```

Para el iPhone: `make bundle-ios`, abrir `RayPlay-ios/RayPlay.xcodeproj`, elegir el iPhone como
destino y Run (la primera vez, el equipo de firma en `RayPlay-ios/App.xcconfig` o en `[ios]
development_team`). Tras un cambio en `src/` o `www/`, basta `make ios-lib` y Run.

**La prueba**: Play, cambiar de app (o bloquear el teléfono) y esperar; al volver, el display
dice cuánto sonó en segundo plano y la posición ha avanzado. Verificada en un iPhone real y en
el emulador Android.

## Estado

| Qué | Verificado |
|---|---|
| Backend | `make test`: 13 tests, VM |
| Programa completo | `ray run` headless: monta `www/` y abre `ray://app/index.html` |
| iOS | simulador iPhone 16 Pro (`ray bundle --ios --ios-target sim`, shell 1.27.19 con sesión `playback` y `UIBackgroundModes = audio`): arranca, la página llega por `ray://app`, el puente responde y el display muestra el `lifecycle` del shell; `audio.open` abre el dispositivo dentro del shell (comprobado con una mini app) |
| Android | emulador arm64 (`ray bundle --android`, shell 1.27.19 con *foreground service* `mediaPlayback`): Play por `adb`, Home durante 10 s, vuelta: la posición pasó de 0:05 a 0:17 y el display dice «played in the background: 0:09». **El audio sigue en segundo plano** |
| Segundo plano en iPhone real | **verificado** (29 sep 2026): Play, cambio de app, vuelta: el audio sigue y el display muestra lo reproducido en segundo plano |

## Limitaciones

- Solo WAV PCM de 16 bits, mono o estéreo, 8–192 kHz: no hay decodificador de MP3/OGG en la
  stdlib, y el reproductor no remuestrea (abre el dispositivo a la frecuencia de la pista).
- El WAV cargado viaja entero por el puente en base64 y se copia al actor: vale para archivos
  de unos MB, no para discos enteros.
- Sin cola persistente: la lista vuelve a las tres pistas al relanzar.

## Hallazgos de dogfood

Ver también `RAYLANG-FINDINGS.md` y el README de Ray808 (hallazgo 18, el origen de esta app).

1. **Android pide el permiso de notificaciones nada más arrancar** (raylang 1.27.19,
   `[android] background_audio`): el shell lo solicita en `onCreate` para el *foreground
   service*, antes de que suene nada; el diálogo tapa la página y, si se rechaza, no vuelve a
   preguntar. Propuesta: pedirlo al primer `audio.open` (o exponer al programa cuándo pedirlo),
   con el texto de la notificación configurable (`[android] background_audio_title`).
