# Ahora suena para Coucou

Integración propia que muestra en Coucou la reproducción publicada por las aplicaciones en «Ahora suena» de macOS. Incluye título, artista o canal, portada, progreso y controles cuando el reproductor los ofrece. Chrome y Safari se han probado con YouTube. No reconoce cualquier sonido del ordenador ni identifica necesariamente el sitio o la pestaña.

Apple Music y Spotify conservan sus controladores y tarjetas independientes y se excluyen del lector general. No se pausan otras aplicaciones automáticamente ni se añade coordinación entre sus tarjetas.

## Uso y presentación

En la versión de GitHub para macOS, activa la etiqueta «Ahora suena» y pulsa Conectar. Coucou guarda esa elección y detiene el auxiliar al desconectar, dormir o salir. No necesitas abrir Coucou Media Lab, instalar extensiones ni otro reproductor.

La vista compacta muestra portada, ondas decorativas y tiempo restante. Las ondas varían suavemente con el volumen del sistema; no capturan audio ni siguen el ritmo real. En la vista ampliada, arrastra el tirador del borde derecho de la tarjeta para darle más espacio. Las otras cuatro etiquetas pasan a una columna de cabecitas animadas. Apple Music, Spotify y Ahora suena comparten esta presentación. La portada ampliada queda a la derecha y los controles se alinean con la barra de progreso; la tarjeta pequeña conserva su disposición.

## Estructura

- `Sources/BridgeProtocol.swift`: validación y decodificación del protocolo, identidad de reproducción y confirmación de navegación.
- `Sources/SystemNowPlaying.swift`: ciclo de vida del auxiliar, estado, portadas y solicitudes de control.
- `Native/NowPlayingBridge.m`: acceso aislado a MediaRemote, suscripción a eventos y validación del destino de las órdenes.
- `Resources/bridge.pl`: carga el auxiliar propio dentro de Perl del sistema.
- `scripts/build-bridge.sh`: compilación y firma de la biblioteca incluida en Coucou.
- `Tests/`: protocolo, capacidades y cierre/rechazo de órdenes inválidas.

El adaptador de Coucou y sus vistas están en `Sources/App/ChromeController.swift` y `ChromeViews.swift`, relativos a NotchBuddy. Los nombres internos de Chrome, el identificador de etiqueta y la preferencia se conservan por compatibilidad; la función visible es general. El laboratorio utiliza estas mismas fuentes, no una segunda implementación.

## Privacidad y límites

Código propio, sin el programa de ungive ni dependencias añadidas. Este componente no accede a páginas, cookies, historial, credenciales, micrófono ni red. Recibe metadatos del sistema y no los guarda en disco. Las portadas se reciben como bytes del sistema y se reducen a miniaturas. Consulta [SECURITY.md](SECURITY.md) para los límites del protocolo, procesos y controles.

MediaRemote es una interfaz privada de Apple y puede cambiar entre versiones de macOS. El auxiliar requiere Perl del sistema. Esta integración está destinada a la versión de GitHub; las pruebas locales no certifican distribución por Mac App Store, notarización ni compatibilidad universal. El reconocimiento depende de que la aplicación publique datos. Anterior/Siguiente pueden no estar disponibles para un contenido. No se identifica YouTube por duración ni se inventan controles ausentes.

La escucha usa eventos agrupados, sin sondeo periódico del reproductor. Esto no demuestra un ahorro concreto de batería; no se ha realizado una medición comparativa.

## Validación

Desde esta carpeta, ejecuta `bash scripts/check.sh` con las herramientas de desarrollo de Xcode y Python 3. Compila el auxiliar y las pruebas en una carpeta temporal. Comprueba Unicode y fragmentación, límites y datos inválidos, exclusión de Apple Music/Spotify, fuentes alternativas, identidad del destino, capacidades y cierre del proceso. La prueba de humo rechaza un PID inválido sin modificar la reproducción.

En este Mac se verificaron metadatos, portada, progreso y pausa/reanudación de Chrome y Safari en el laboratorio. La presentación ampliada se comprobó en Coucou con Apple Music y Ahora suena y fue aceptada por el usuario. Spotify conserva la presentación compartida, pero su prueba con reproducción real está pendiente por no estar instalado. No se afirma haber verificado todas las combinaciones de reproductores ni todos los controles en cada aplicación.

La revisión final conserva diseño y lógica, sin pausa automática ni prioridad conjunta entre tarjetas. Los comentarios explican decisiones y límites; se evitan renombres de identificadores persistidos.

## Referencias técnicas

Las firmas se contrastaron con las declaraciones de [MediaRemote SPI de WebKit](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/mac/MediaRemoteSPI.h) y sus [pruebas de Media Session](https://github.com/WebKit/WebKit/blob/main/Tools/TestWebKitAPI/Tests/WebKit/WKWebView/MediaSession.mm), sin incorporar código externo.

## Siguiente proyecto

Después de publicar esta actualización del fork, extraer el lector de Ahora suena a un repositorio independiente reutilizable, con su interfaz, ejemplo, pruebas y límites documentados. Esa extracción queda como trabajo posterior y no cambia esta integración.
