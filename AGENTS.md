# Butake Git

Cliente Git local macOS. Producto canónico: SwiftUI/AppKit en `native/`, motor Rust en `engine/`, Git CLI real. Sin WebView. El catálogo de comandos vive en `native/Sources/ButakeGit/Resources/` y el motor lo incluye al compilar.

- Trabajar en develop. main es promoción/release; no push directo.
- Conservar cambios y staging del usuario; QA de mutaciones sólo contra repos temporales. Nunca mutar repositorios reales del usuario para QA.
- Código y archivos nuevos en inglés; texto visible mediante `L` y `native/Sources/ButakeGit/Resources/es.lproj/Localizable.strings`.
- Usar logo Butake oficial, verde de marca, controles y tipografía nativos macOS. Cabecera: logo + “Git”, sin subtítulo técnico ni versión.
- Paneles de archivos preparados/sin preparar con scroll independiente; compositor fijo. Selección visual no equivale a staging.
- No interpolar shell: Git recibe argumentos separados. Validar rutas/referencias y serializar mutaciones.
- Confirmar comandos de consola, operaciones destructivas y push en el producto. Destino explícito del push. Protección de main en el producto: elección manual del repo, si no la regla real del proveedor (GitHub/Bitbucket); si no se conoce, no bloquear, pero subir a main pide confirmación con aviso.
- API del proveedor separada de Git. Tokens sólo Keychain; nunca repo, logs o UserDefaults.
- Git usa SSH Agent/credential helpers; fechas epoch UTC, conversión en presentación.
- No anunciar paridad completa o funciones sin evidencia. Catálogo ≠ disponibilidad ni ejecución sin restricciones.
- Operable por IA: todo control con `accessibilityIdentifier` estable y acción AX equivalente a hover/gestos; ver docs/automation.md.
- Validar `./scripts/test-native.sh`, `./scripts/build-native.sh`, `git diff --check`; verificar visualmente cambios de UI.
- No publicar, activar CI, crear remoto ni push salvo instrucción del usuario.

Fuentes: README.md, docs/automation.md, docs/architecture.md, docs/feature-matrix.md, docs/roadmap.md, CHANGELOG.md. Bitácora interna detallada: internal/worklog.md (local, no versionada).
