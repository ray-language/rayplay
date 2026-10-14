# RayPlay

Reproductor de audio mínimo escrito en [raylang](https://github.com/ray-language/raylang),
para **iPhone y Android** (y escritorio con el mismo fuente). Existe para una sola pregunta:
¿sigue sonando la app cuando pasa a segundo plano? En Ray808 no puede, porque su audio vive en
la página (Web Audio, que el webview congela). Aquí el sonido lo produce el **programa raylang**
con `std/audio`, y la página es solo la interfaz.

## Qué hace

- Tres pistas **procedurales** (un estudio pentatónico, un dron, un pulso de bajo), calculadas
  trozo a trozo: la app no lleva archivos de audio y ninguna pista ocupa memoria entera.
- **Cargar una canción en MP3, AAC o ALAC (.m4a), Ogg Vorbis, Opus, FLAC, WAV o AIFF** y añadirla a la lista (diálogo nativo en el
  escritorio, selector del webview en el móvil). Los decodificadores están escritos en **raylang
  puro** (`src/mp3.ray`, `src/aac.ray` y `src/alac.ray` con `src/mp4.ray`, `src/vorbis.ray` y `src/opus.ray` (con `src/celt.ray` y `src/silk.ray`) sobre `src/ogg.ray`, `src/flac.ray`, `src/wav.ray`, `src/aiff.ray`) y la reproduce a su frecuencia y canales.
  El formato se reconoce por el contenido, no por el nombre.
- **MP3, AAC, Vorbis, Opus, FLAC y ALAC se decodifican mientras suenan** (`codec.Stream`): al cargar solo se leen las
  cabeceras, así que la canción empieza al momento y ocupa lo que pesa el archivo. El seek salta
  a cualquier punto: en FLAC, bisecando el archivo por los números de muestra de las cabeceras de
  frame; en MP3, con un índice de frames y decodificando antes los 8 frames previos (reservorio de
  bits); en AAC y ALAC, por la tabla de paquetes del MP4, y en Vorbis, por la lista de paquetes
  del Ogg con la posición de cada uno sacada de su tamaño de bloque (AAC y Vorbis decodifican antes
  el paquete previo, porque cada uno solapa la mitad del anterior); en Opus, por la misma lista con
  la duración de cada paquete sacada de su TOC, y como cada trama depende de las anteriores
  (predicción de energías, filtros, solapes), reiniciando el decodificador y decodificando antes
  medio segundo si todo es CELT o dos si hay SILK. Tras un salto, las muestras son idénticas a
  decodificar desde el principio (salvo el ruido de las bandas PNS de AAC, que es otro igual de
  válido; en Opus, a ±1 en CELT, y en un archivo estéreo con FEC y largos tramos solo de canal
  medio el SILK todavía no ha convergido a los dos segundos).
- Play/pausa, stop, anterior/siguiente (con vuelta), **seek** tocando la barra, volumen, y al
  acabar una pista sigue con la siguiente. Un cambio de volumen se aplica como una rampa a lo
  largo del siguiente trozo de 50 ms (`synth.chunk_ramp`), no como un escalón que suena a clic.
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
│               seek, volume, pick, add                               │
│  player.ray   ACTOR: una fibra con el dispositivo (std/audio) y la  │
│               lista; comandos por canal; 50 ms por chunk            │
│  synth.ray    las pistas: procedurales o archivo cargado → s24le    │
│  codec.ray    reconoce el formato (salta ID3v2); Stream sirve       │
│               cualquier ventana (seek): MP3/AAC/Vorbis/Opus/FLAC/   │
│               ALAC                                                  │
│               decodif. por frames, WAV/AIFF leídos tal cual         │
│  mp3.ray      MPEG-1/2/2.5 Layer III (port de minimp3)              │
│  flac.ray     FLAC nativo, 4–32 bits, cualquier tamaño de bloque    │
│  wav.ray      PCM de 16 bits (Pcm, Sink) y RIFF/WAVE (16 y 24 bits) │
│  pcm24.ray    las muestras del reproductor: enteros de 24 bits      │
│  aiff.ray     AIFF y AIFF-C (8–32 bits, big-endian y `sowt`)        │
│  mp4.ray      contenedor MP4/M4A: pista de sonido, tablas, gapless  │
│  aac.ray      AAC-LC (M/S, intensidad, PNS, TNS; de HE-AAC, el LC)  │
│  alac.ray     Apple Lossless (16–32 bits, paquetes independientes)  │
│  ogg.ray      contenedor Ogg: paquetes de la primera pista, granule │
│  vorbis.ray   Vorbis I (floor 1, residuos 0–2, acoplamiento)        │
│  opus.ray     Ogg Opus: paquetes, modos, tramas redundantes         │
│  celt.ray     CELT (port del decodificador float de libopus)        │
│  silk.ray     SILK (port del de punto fijo: bit a bit) y remuestreo │
│  rangedec.ray decodificador de rango de Opus                        │
│  *_tables.ray tablas de CELT y SILK sacadas de libopus              │
│  mdct.ray     la IMDCT de AAC y Vorbis (DCT-IV por una FFT)         │
│  bits.ray     lector de bits big-endian sobre bytes                 │
└────────────────────────────────────────────────────────────────────┘
```

- **El audio es del programa**: `audio.open_format(rate, channels, "s24le", 120)` (raylang
  1.27.53) + `audio.write` de 50 ms por vuelta; todo se reproduce en 24 bits, así que un FLAC,
  ALAC, WAV o AIFF de 24 bits llega al dispositivo tal cual; `write` aparca la fibra cuando el dispositivo está lleno, así que el
  dispositivo marca el paso y los comandos se atienden entre chunk y chunk (`try_recv`).
- **Posición**: `audio.played_ms` cuenta desde que se abrió el dispositivo y `base_ms` es lo que
  hay que sumarle para saber dónde va la pista. Un seek, una pausa, un stop o una pista elegida
  descartan lo que queda en cola con `audio.flush` (1.27.53), que corta con un fundido breve, y
  lo nuevo suena enseguida. Pero el `flush` corta sin fundido y chasquea: a 44,1 y 48 kHz desde
  1.27.53 (hallazgo #171) y a cualquier frecuencia con 1.27.54 (#173), así que por ahora el corte
  escribe su propio fundido de 10 ms detrás de la cola y lo nuevo suena cuando esta termina
  (`FLUSH_FADES_ABOVE_HZ` en `src/player.ray`). Con la misma frecuencia y canales, la salida sigue abierta. Una pista
  que termina pasa a la siguiente sin hueco. La pausa cierra el dispositivo.
- **Segundo plano**: `[ios] background_audio = true` y `[android] background_audio = true` en
  `ray.toml` (raylang 1.27.19, M324): sesión `playback` + `UIBackgroundModes = audio` en iOS,
  *foreground service* `mediaPlayback` en Android. La página deja de pedir el estado cuando no
  se ve (sus timers se paran igualmente); el programa ni se entera.
- **Sin servidor local**: la página va embebida (`[native] embed = ["www"]`) y se sirve por
  `ray://app` con `ui.mount_embed_at("", "www")`; bajo `ray run` y `ray dev --device` se lee
  del disco (bajo `--device`, desde 1.27.46; ver hallazgo 2).

## Uso

```bash
make test            # 45 tests: MP3, AAC, Vorbis, Opus, FLAC, ALAC (24 bits exactos), WAV, AIFF, pistas, el actor (audio nulo, diálogo headless), protocolo
make run             # ventana de escritorio
make bundle-ios      # proyecto Xcode en RayPlay-ios/ (iPhone + simulador)
make bundle-android  # proyecto Gradle en RayPlay-android/ (arm64)
make dev-device      # desarrollo en vivo en el teléfono (ver abajo)
make icon            # assets/icon.png, dibujado con std/image
```

Para el iPhone: `make bundle-ios`, abrir `RayPlay-ios/RayPlay.xcodeproj`, elegir el iPhone como
destino y Run (la primera vez, el equipo de firma en `RayPlay-ios/App.xcconfig` o en `[ios]
development_team`). Tras un cambio en `src/` o `www/`, basta `make ios-lib` y Run.

### Desarrollo en vivo en el teléfono (raylang 1.27.25)

Sin recompilar ni reinstalar en cada cambio:

1. Una vez: `make bundle-ios-dev` (Xcode, `RayPlay-dev-ios/`) o `make bundle-android-dev` +
   `make android-dev-apk` (`RayPlay-dev-android/`), e instalar la app **RayPlay-dev**
   (`org.raylang.rayplay.dev`). Convive con RayPlay y conserva `background_audio`.
2. `make dev-device`: imprime el enlace `org.raylang.rayplay.dev://ip:puerto/token` y su QR.
   Escanearlo con la cámara abre la shell y la empareja (teléfono y Mac en la misma red).
3. Cada cambio guardado en `src/`, `www/` o `ray.toml` que compile reinicia el programa en el
   teléfono; sus `print`/`eprint` salen en la terminal.

Sin teléfono, `ray dev-client <ray-dev://…> <dir>` hace de dispositivo en el escritorio.

**La prueba**: Play, cambiar de app (o bloquear el teléfono) y esperar; al volver, el display
dice cuánto sonó en segundo plano y la posición ha avanzado. Verificada en un iPhone real y en
el emulador Android.

## Estado

| Qué | Verificado |
|---|---|
| Backend | `make test`: 45 tests, VM y nativo (`make test-native`) |
| Decodificadores | Opus a ±1 de libopus 1.5.2 en float (`op_read_float` de opusfile redondeado a 16 bits) y con la misma longitud (pre-skip y granule final), en 36 archivos del codificador libopus (vía ffmpeg): CELT de 12 a 510 kb/s, CBR, VBR y VBR restringido, tramas de 2,5 a 60 ms (40 y 60 ms empaquetadas), mono y estéreo, ruido y tonos; SILK de 6 a 24 kb/s en banda estrecha, media y ancha, tramas de 10 a 60 ms, con FEC (LBRR) y estéreo (mid/side); híbrido, y archivos que cambian entre SILK, híbrido y CELT con las tramas redundantes de cada cambio. SILK sale idéntico bit a bit (es de punto fijo; también al libopus en punto fijo). El decodificador nativo de ffmpeg se aparta de libopus (hasta 86 en CELT y SNR de 22 dB en SILK, que remuestrea a su manera). 5 min en 1,8 s (CELT a 128 kb/s) y 1,9 s (SILK, híbrido y CELT a 32 kb/s) y ~21 MB de pico en nativo, leído como lo hace el reproductor (el archivo pesa 6 MB); en la VM, SILK mono ~6× tiempo real, CELT estéreo ~2,6× e híbrido estéreo ~2,3×; 1500 archivos con bytes corrompidos (cabeceras, paquetes, TOC, cortes) se rechazan o suenan sin un fallo, también tras saltos. Vorbis a ±1 del decodificador de libvorbis y de la salida en float de ffmpeg redondeada, con la misma longitud (el granule de la última página recorta el final): archivos del codificador de libvorbis de calidad −0,1 a 1, mono y estéreo, de 8 a 96 kHz, con transitorios (bloques cortos) y ruido blanco; los del codificador experimental de ffmpeg coinciden con libvorbis (el decodificador de ffmpeg da otro canal derecho en ellos). 5 min en 1,2 s y 17 MB de pico en nativo (el archivo pesa 3,7), ~4,6× tiempo real en la VM; 900 archivos con bytes corrompidos al azar se rechazan o suenan sin un fallo. AAC-LC a ±1 de la salida en float de ffmpeg redondeada y del decodificador de Apple (`afconvert`), con la misma longitud gapless (`iTunSMPB` o `elst`): archivos de `afconvert` y del codificador de ffmpeg, mono y estéreo, de 8 a 96 kHz y de 16 a 256 kb/s, ventanas cortas, M/S, intensidad, TNS y PNS (el mismo generador de ruido que ffmpeg, así que también coincide). De un HE-AAC suena el núcleo AAC-LC, a media frecuencia y alineado con el original. 5 min en 1,1 s y 27 MB de pico en nativo (el archivo pesa 9,5), ~5× tiempo real en la VM. ALAC idéntico bit a bit a ffmpeg (16 y 24 bits, mono y estéreo, 44,1/48/96 kHz, ruido blanco con escapes, silencio con rachas de ceros; codificado por `afconvert` de Apple y por ffmpeg); 5 min en 1,5 s en nativo y ~3,7× tiempo real en la VM. AIFF idéntico bit a bit a ffmpeg (8, 16, 24 y 32 bits; mono y estéreo; AIFF-C `NONE` y `sowt`; archivos de `afconvert` de Apple). FLAC idéntico bit a bit a ffmpeg (16 y 24 bits, mono, nivel 12, el codificador de Apple). MP3 idéntico a minimp3 compilado en C salvo ±1 en el 0,1 % de las muestras (floats de 64 frente a 32 bits): CBR, VBR, mono, joint y simple stereo, MPEG-2 22 kHz, MPEG-2.5 8 kHz, con ID3v2/ID3v1 y el recorte gapless de LAME. Una pista de 5 min en nativo (Mac), entera en streaming: FLAC 0,6 s y 68 MB de pico (el archivo pesa 30), MP3 1,0 s y 16 MB (antes, decodificándola entera al cargar: 287 y 256 MB). Abrir y servir el primer trozo, ~1 ms. Tras 40 saltos aleatorios por archivo, las muestras coinciden exactamente con la decodificación completa |
| Programa completo | `ray run` headless: monta `www/` y abre `ray://app/index.html` |
| iOS | simulador iPhone 16 Pro (`ray bundle --ios --ios-target sim`, shell 1.27.19 con sesión `playback` y `UIBackgroundModes = audio`): arranca, la página llega por `ray://app`, el puente responde y el display muestra el `lifecycle` del shell; `audio.open` abre el dispositivo dentro del shell (comprobado con una mini app) |
| Android | emulador arm64 (`ray bundle --android`, shell 1.27.19 con *foreground service* `mediaPlayback`): Play por `adb`, Home durante 10 s, vuelta: la posición pasó de 0:05 a 0:17 y el display dice «played in the background: 0:09». **El audio sigue en segundo plano** |
| Desarrollo en vivo | `ray dev --device` + `ray dev-client` en el escritorio (1.27.25, headless): recibe los 12 archivos, monta `www/` y abre `ray://app/index.html`. Las shells `--dev` de iOS y Android se generan con `background_audio`; en un **iPhone real**, la shell de desarrollo arranca la app y suena (con los chasquidos del hallazgo 4) |
| Segundo plano en iPhone real | **verificado** (29 sep 2026): Play, cambio de app, vuelta: el audio sigue y el display muestra lo reproducido en segundo plano |
| MP3, FLAC, AIFF, ALAC, AAC, Ogg Vorbis y Opus en iPhone real, hasta 24/192 | **verificado** (12 oct 2026, iPhone 12, app nativa): MP3 y FLAC de 24 bits y 5 min cargados con el `<input type=file>` suenan limpios, también en segundo plano; con la decodificación en streaming empiezan al momento y el seek funciona en ambos sentidos. Con raylang 1.27.49, lo mismo; y un AIFF de 24 bits de `afconvert` (13 oct 2026). Un ALAC de 16 bits (.m4a de `afconvert`) suena bien, con los WAV y AIFF ya leídos directamente del archivo (13 oct 2026). Un AAC-LC de 6 s a 128 kb/s y otro de 5 min a 256 kb/s (.m4a de `afconvert`) suenan bien y el seek funciona (13 oct 2026); lo mismo con el decodificador acelerado. Un Ogg Vorbis de 6 s (q0.4) y otro de 5 min (de libvorbis) se eligen en el selector, suenan bien y el seek funciona (13 oct 2026). FLAC y ALAC de 24 bits a 96 y 192 kHz (un groove sintético de 33 s, bit a bit iguales a ffmpeg al pasar a 16 bits) suenan bien; con música rítmica, cada salto dejaba oír medio segundo de la posición vieja encima de la nueva al cerrar y reabrir la salida, y ahora el salto sigue en la misma salida con fundidos de 10 ms: los saltos suenan naturales y la traza de audio no da cortes (13 oct 2026). Next, el paso solo de una pista a la siguiente, pausa y reanudación ya no se solapan: con la misma frecuencia y canales la salida sigue (sin hueco entre pistas) y si no, se cierra cuando ha sonado su cola (13 oct 2026). Con el dither de 24 a 16 bits, los FLAC y ALAC de 24 bits suenan como antes (13 oct 2026). Tres Opus de libopus (el groove a 128 y 24 kb/s, y entero a 96 kb/s) se eligen en el selector, suenan bien y el seek funciona (13 oct 2026). Con raylang 1.27.50 y la subida decodificada con `base64_decode_bytes`, una canción grande cargada con el botón entra y suena igual (13 oct 2026) |

## Limitaciones

- MP3 (Layer III; ni Layer I/II ni *free format*), FLAC nativo (no Ogg FLAC), WAV PCM de 16 o 24
  bits y AIFF/AIFF-C PCM de 8 a 32 bits (no comprimido: ni µ-law, ni A-law, ni float). ALAC mono o
  estéreo de 16 a 32 bits. AAC-LC mono o estéreo en MP4/M4A (no ADTS suelto, ni Main, SSR o LTP,
  ni frames de 960); de HE-AAC v1/v2 solo el núcleo LC, sin la banda alta de SBR (suena apagado,
  a media frecuencia). Vorbis mono o estéreo en Ogg, sin el floor 0 (LSP) y solo la primera pista
  de un Ogg encadenado. Opus mono o estéreo en Ogg (familia de canales 0, o 1 con un solo stream),
  solo la primera pista de un Ogg encadenado y sin ocultación de pérdidas: un paquete dañado suena
  como silencio, igual que los de DTX (sin carga, donde libopus pondría ruido de confort), y un
  cambio de modo sin su trama redundante (solo pasa tras perder paquetes) no se funde. Hasta 24 bits todo
  suena tal cual; lo que pasa de 24 (WAV, AIFF, FLAC o ALAC de 32 bits) se redondea a 24, muy
  por debajo del ruido de cualquier conversor; de un FLAC de más de dos canales se quedan los dos primeros. El
  reproductor no remuestrea: abre el dispositivo a la frecuencia de la pista.
- En la shell de desarrollo (VM), decodificar va justo: en el Mac, 5 s de audio en 1,4–1,6 s
  (MP3), 1 s (AAC) y 0,6 s (FLAC), unas 3,5–5× el tiempo real; un seek, 30–80 ms. Opus va más
  justo: 5 s de CELT estéreo en ~1,9 s, y un seek decodifica antes medio segundo (CELT) o dos (SILK). En un teléfono puede no dar
  abasto; para probar con música de verdad, la app nativa.
- Un WAV o un AIFF tampoco se convierte al cargar: se guarda el archivo tal cual y cada trozo
  de 50 ms se pasa a 24 bits al reproducirlo (`wav.Raw`). Un AIFF de 5 min se abre en 12 ms y
  ocupa lo que pesa (antes, convertido entero: 213 ms y 325 MB de pico).
- Cargar un archivo: en el escritorio, el programa abre el diálogo nativo y lo lee del disco.
  En iOS/Android no hay diálogo (`ui.pick_file_with` devuelve «file dialogs are not available on
  mobile (v1)», #152), así que la página usa su `<input type=file>` y el archivo cruza el puente
  entero en base64. Va como string plano y no como JSON, porque `json.parse` gasta ~55× un string
  largo (#150), y se decodifica con `base64_decode_bytes` (1.27.50) sobre los octetos de la petición,
  sin copiarlos (#161). Un WAV de 56 MB de 24 bits llega a unos 470 MB
  durante la subida (casi todo, la petición y su base64) y tarda 0,3 s en nativo; en la shell de desarrollo (VM) no cabe.
- Sin cola persistente: la lista vuelve a las tres pistas al relanzar.

## Hallazgos de dogfood

Ver también `../findings/` (los números son los de allí) y el README de Ray808 (hallazgo 18, el origen de esta app).

1. **Android pide el permiso de notificaciones nada más arrancar** (raylang 1.27.19,
   `[android] background_audio`): el shell lo solicita en `onCreate` para el *foreground
   service*, antes de que suene nada; el diálogo tapa la página y, si se rechaza, no vuelve a
   preguntar. Propuesta: pedirlo al primer `audio.open` (o exponer al programa cuándo pedirlo),
   con el texto de la notificación configurable (`[android] background_audio_title`).
2. **`std/embed` no ve `[native] embed` bajo `ray dev --device`** (raylang 1.27.25): el
   snapshot trae `ray.toml` y `www/`, pero `ui.mount_embed_at` / `embed.list()` fallan con
   «no embedded assets configured», y la app moría al arrancar. Sigue igual en 1.27.26;
   **corregido en 1.27.46**, y se quitó el rodeo con `ui.mount_dir`. Detalle en
   `../findings/` (#109).
3. **`ray dev --device` guarda el token de emparejamiento en `.ray-dev`**, en la raíz del
   proyecto, sin documentarlo ni ignorarlo: aquí va en `.gitignore`. Ver #111.
4. **Chasquidos en el iPhone con 1.27.25**, en la shell de desarrollo y en la app normal. Con
   1.27.19 sonaba limpio y en el Mac no se reproduce: es del backend de audio de iOS. Corregido
   en 1.27.26; **comprobado en el iPhone con 1.27.46** (limpio, también en segundo plano). Ver #112.
5. **Cargar un WAV de 56 MB cerraba la app en el iPhone** (1.27.46): iOS la mataba por memoria
   (~2 GB, `per-process-limit`). El archivo iba en base64 dentro del JSON de `window.ray.request`,
   y `json.parse` gasta ~55× un string largo: 6,3 GB en el Mac. Ver #150. Ahora va como string
   plano.
6. **`base64.base64_decode` es lento y caro**: ~15 MB/s y ~14× la entrada en nativo. Un
   decodificador en raylang sobre `bytes` (`src/b64.ray`) es ~17× más rápido. Ver #151.
   Corregido en 1.27.47; `src/b64.ray` se quedó hasta 1.27.50: ver el 11.
7. **No hay diálogos de archivo en móvil** y la doc no lo dice: `ui.pick_file_with` devuelve
   «file dialogs are not available on mobile (v1)». Ver #152. Con 1.27.47, #150, #151 y #152
   están corregidos.
8. **En nativo, `for i in 0..xs.len()` con `xs[i] = …` en el cuerpo revienta** con «RefCell
   already borrowed»; en la VM funciona. El decodificador FLAC pasaba los tests en la VM y moría
   en el binario. Rodeo: sacar `xs.len()` a una variable. Ver #156. **Corregido en 1.27.49**, y
   se quitó el rodeo.
9. **Indexar un `const` array lo reconstruye en cada acceso**: con las tablas de Huffman del MP3
   (2164 entradas), unas 400× más lento que una copia local. Por eso `src/mp3_tables.ray` son
   funciones que se llaman una vez por archivo. Ver #157. **Corregido en 1.27.49**.
10. **No está documentado cómo escribir el valor `unit`**: `Result.Ok(())` es un error de sintaxis;
    funciona `Result.Ok({ })`. Ver #158. Documentado en 1.27.49.
11. **`std/base64` no compensa aquí, aunque ya es rápido**: `base64_decode` solo acepta `string`, y
    sacar el base64 de la petición copia. Para un WAV de 56 MB, `src/b64.ray` tarda 370 ms y
    ocupa ~450 MB; con `std/base64`, ≥ 510 ms y hasta 550 MB. Si el nombre del archivo lleva un
    acento, recortar con `substring` dispara el pico a 1 GB, porque cuesta ~6 octetos por carácter.
    Además, `ray_doc string.index_of` dice «octet index» y devuelve un índice de carácter. Ver
    #159, #160 y #161. **Corregidos en 1.27.50**: `base64_decode_bytes` decodifica el tramo de la
    petición sin copiarlo, en unos 100 ms frente a 230 de `src/b64.ray` y con ~100 MB menos (78
    MB de base64), así que `src/b64.ray` se quitó; `substring` ya no gasta memoria con acentos, y
    `ray_doc` dice «character index».
12. **`std/audio` solo aceptaba muestras de 16 bits, y `close` no podía descartar la cola**: un
    archivo de 24 bits había que reducirlo con dither (`src/dither.ray`), y cada seek o pausa
    dejaba sonar lo que quedaba en cola (en iOS, un cuarto de segundo o más), así que el
    reproductor hacía sus propios fundidos detrás de ella. Ver #166 y #167. **Corregidos en
    1.27.53**: `audio.open_format` acepta s24le (y s32le y f32le), y `audio.flush` descarta la
    cola sin cerrar la salida. Se quitó el dither, y en el Mac un salto con latencia de 120 ms
    suena unos 70 ms antes (290 ms con 500 ms de latencia). Solo por encima de 48 kHz: a 44,1
    y 48 kHz el `flush` chasquea (#171) y se mantienen los fundidos propios. Con 1.27.54 chasquea
    a cualquier frecuencia (#173), así que no se usa en ninguna.
