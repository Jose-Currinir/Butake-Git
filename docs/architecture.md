# Arquitectura nativa

SwiftUI/AppKit → procesos JSON del motor Rust → Git CLI instalado. La terminal usa SwiftTerm/AppKit y PTY; no hay WebView ni servidor web en la app nativa.

- `native/Sources/ButakeGit/Models`: estado observable, modelos Codable, grafo, parser de diff y catálogo offline.
- `native/Sources/ButakeGit/Views`: navegación macOS, listas, inspectores, formularios, diff AppKit, conflictos y planificador de rebase.
- `native/Sources/ButakeGit/Services/GitEngine.swift`: actor y protocolo JSON con el ejecutable incluido en el bundle.
- `engine/src/git.rs`: snapshots, acciones tipadas, parseo y guardas.
- `engine/src/terminal.rs`: catálogo, capacidades del Git instalado y validación de argumentos/planes.
- `engine/src/editing.rs`: preparación por bloque, lectura de conflictos y guardado con comprobación del contenido esperado.
- `engine/src/main.rs`: protocolo de procesos y entrada PTY.
- `BitbucketClient.swift`: REST HTTPS exclusivo para Bitbucket Cloud; credenciales Keychain y sesiones efímeras.

La selección de una carpeta usa NSOpenPanel y bookmarks de acceso. Historial de rutas y apariencia viven en UserDefaults; los tokens no. El motor canonicaliza rutas. El diff utiliza NSTextView seleccionable con ruler original/nuevo, clipping explícito y scroll horizontal para líneas largas. Cada panel de archivos mantiene su propio scroll y el formulario de commit permanece fijo.

El motor recibe argumentos separados, sin shell libre. Las mutaciones de UI se serializan y se bloquean mientras hay sesión PTY activa. Comandos de consola requieren preview y confirmación. La protección de main permite lecturas y operaciones de staging/switch/fetch autorizadas, pero bloquea escrituras de historial sobre main. Rebase de develop sobre main está permitido. Push requiere destino de rama explícito; no force/mirror/mass push.

La terminal hereda el entorno local, SSH Agent, credential helpers, hooks y editor de Git. Un comando Git puede ejecutar herramientas configuradas por el repositorio. No hay telemetría propia ni persistencia del transcript de terminal. Lecturas ligeras tienen timeout de 12 segundos; otras operaciones tipadas 120 segundos. La terminal interactiva tiene cancelación por usuario.

Build mediante Cargo y SwiftPM; SwiftTerm fijado en Package.resolved. El script ensambla un .app local firmado ad hoc. El catálogo de comandos (`native/Sources/ButakeGit/Resources/commands.json`) es la única fuente: la app lo empaqueta y el motor lo incluye al compilar.

Límites conocidos: snapshot de historial de 180 commits, texto/diff en memoria, paginación remota incompleta, previsualización UTF-8. No se declara paridad total con clientes maduros. Ver matriz y roadmap.
