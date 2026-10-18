# Componente propio: alcance, riesgos y revisión

Revisión de fuentes propias: 18 de octubre de 2026. No se incorpora el adaptador de ungive ni código descargado. La revisión anterior del candidato externo permanece en la carpeta del laboratorio; no certifica esta implementación.

## Qué se ejecuta

La aplicación Swift inicia `/usr/bin/perl`, incluido en este Mac, con un script propio y una ruta absoluta al dylib propio empaquetado. El script carga ese dylib dentro del auxiliar. El dylib carga exclusivamente `/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote`, de Apple. No se inyecta código en los reproductores. Es la misma técnica general de acceso a la interfaz privada, implementada aquí con código propio; escribirlo nosotros no convierte esa interfaz en pública.

La disponibilidad de Perl y de los símbolos privados se comprueba al ejecutar. Cambios futuros del sistema pueden impedir que funcione. La distribución con firma Developer ID, hardened runtime, notarización, arquitecturas y sandbox necesita su propia validación. Este prototipo no acredita compatibilidad con Mac App Store.

## Datos y acciones permitidos

- Se consulta primero el PID de la aplicación que macOS considera reproductora. Solo si tiene identificador de aplicación no vacío y no es `com.apple.Music` ni `com.spotify.client` se solicita su diccionario de reproducción. Las dos aplicaciones excluidas conservan sus integraciones separadas, aunque sus tarjetas estén desactivadas.
- A la interfaz llegan únicamente PID, identificador y nombre de la aplicación activa, título, artista/canal si existe, duración, posición, velocidad, estado, identidad de pista y portada. No se deduce YouTube por la duración.
- Los metadatos se tratan como datos JSON, nunca como comandos o código. Las portadas no se descargan desde URLs: solo se admiten bytes que entrega el sistema, con máximo de 4 MiB. Se generan miniaturas de 256 píxeles.
- No hay instrucciones de acceso a cookies, credenciales, perfiles, historial, páginas, micrófono, portapapeles, red, telemetría ni persistencia. No se guardan metadatos en disco ni se imprimen en logs. El auxiliar ve momentáneamente el diccionario que devuelve MediaRemote; limita los campos que reenvía.
- stdin/stdout privados entre padre e hijo; sin socket ni servidor. Entorno reducido a PATH y LANG. Solo se admiten play, pause, next, previous y seek con PID, identificador de aplicación, identificador de petición y argumentos validados. No se invoca shell para las órdenes.
- Antes de cada orden se comprueba que el PID y el identificador de aplicación coincidan con el reproductor activo y que no sea una fuente excluida. Tras consultar capacidades se revalidan ambos. Anterior y Siguiente usan `MRMediaRemoteSendCommandToApp` dirigido a ese identificador de aplicación. Pausa, reanudación y seek conservan la vía comprobada mediante `MRMediaRemoteSendCommand` / `MRMediaRemoteSetElapsedTime`, previa validación del reproductor activo. En estas acciones básicas sigue existiendo una pequeña carrera entre comprobar la identidad y enviar la orden global. No se cambia la selección global del reproductor. La portada abre solo la instancia con el PID y el identificador de aplicación del estado mostrado. La identificación por aplicación no identifica una pestaña concreta ni hace atómica la secuencia frente a cambios de reproducción.
- Se deshabilitan anterior/siguiente cuando una lista de capacidades disponible los excluye. Las respuestas de capacidades pueden omitir Play al estar en pausa; no se usan para vetar las acciones básicas. Una consulta vacía, no disponible, malformada o que tarda más de un segundo se trata como desconocida y no bloquea los metadatos: permite una solicitud explícita con comprobación de respuesta y de cambio, sin afirmar que esté soportada. No se reenvía automáticamente una orden sin confirmar.
- La respuesta de transporte y los estados de sus manejadores se comprueban, pero una respuesta aceptada no prueba un cambio de canción. La app espera una identidad de pista nueva o, para Anterior, un reinicio de la posición. El avance normal del reloj no cuenta como confirmación. Se impiden pulsaciones duplicadas mientras hay una orden pendiente, con un plazo máximo de cuatro segundos y sin reenvíos automáticos. Un fallo aparece brevemente en la tarjeta.
- No hay lectura del DOM ni historial de vídeos para inventar un Anterior. Si el reproductor o el contenido no implementa la acción para ese contenido, esta vía no puede crear una cola anterior. No hay control de volumen de pestaña.

## Recursos y cierre

Suscripción a eventos, agrupación de avisos de 100 ms y una lectura inicial. Sin sondeo recurrente. Las lecturas tienen un plazo de cinco segundos; no se reintentan indefinidamente. Tras una acción del usuario hay una lectura de confirmación. La interfaz actualiza el reloj localmente como máximo una vez por segundo durante reproducción y pausa ese calendario al detenerse. Las ondas del laboratorio son estáticas; Coucou conserva su animación decorativa suave y su lectura del volumen de salida. No hay captura de audio.

Los metadatos tienen límites de longitud; el protocolo permite líneas de hasta 6 MiB y hasta 8 MiB en tránsito hacia el parser. Solo se envía de nuevo una portada cuando cambia. Si falta momentáneamente la portada de la misma pista, se conserva la anterior; un cambio de pista la elimina. Cerrar stdin o la app cierra el auxiliar; el padre también puede terminarlo. No se instala LaunchAgent, servicio permanente ni autoactualizador.

Esto limita trabajo y exposición, pero no demuestra consumo mínimo ni ausencia absoluta de vulnerabilidades. Falta medir CPU, memoria, activaciones y energía con reproducción, pausa y suspensión; y probar cambios de aplicación y reposo/despertar reales. Siguiente manual y seek por la barra se comprobaron en Chrome; Anterior no produjo cambio con ese contenido. Se verificaron metadatos de Chrome, portada visible, pausa/reanudación y cambio automático de pista en el laboratorio. Los controles solo deben verificarse con reproducción que el usuario acepte modificar.

Las pruebas automáticas de fase uno cubren exclusiones de Spotify y Apple Music, fuentes alternativas y cambio de identidad de aplicación. La admisión del protocolo no garantiza compatibilidad real de cada reproductor.

La fase uno se probó además con YouTube en Safari: metadatos, portada, progreso y pausa/reanudación correctos en el laboratorio; el origen publicado fue Safari Graphics and Media. No se ha validado navegación Anterior/Siguiente en Safari.

## Control de volumen general del Mac

La tarjeta Ahora suena incluye un control explícito del volumen de salida del sistema mediante CoreAudio público. No cambia el volumen de una pestaña ni utiliza MediaRemote para ello. Lee volumen/silencio y sigue el dispositivo de salida predeterminado; las escrituras solo ocurren al interactuar con el control. Si el dispositivo no expone controles de volumen modificables, se desactiva. Al subir desde silencio se desactiva el mute de esa salida. No se abre un flujo de audio ni se solicita grabación, micrófono o Automatización. Los observadores se retiran cuando la tarjeta deja de mostrarse; no se añade sondeo periódico.
