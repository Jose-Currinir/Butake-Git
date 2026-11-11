# Desarrollo de Butake Git

Notas técnicas para quien compila, prueba o contribuye. La presentación del producto está en el [README](../README.md).

## Ejecutar

Requisitos: macOS 14+, Xcode Command Line Tools con Swift 6, Rust estable y Git. Swift Package Manager descarga SwiftTerm desde su repositorio oficial.

```sh
./scripts/run-native.sh
```

Instalar o actualizar en /Applications: `./scripts/install-native.sh`. Compilar sin instalar: `./scripts/build-native.sh`. Resultado: `build/native.noindex/Butake Git.app`, firmado ad hoc para uso local. Validar: `./scripts/test-native.sh`.

## Funciones

- Archivos sin preparar y preparados en paneles separados, redimensionables, con scroll independiente; compositor de commit fijo.
- Cambios en Lista o en Carpetas: el mismo diff y el mismo compositor en ambas; en Carpetas cada casilla es «va en el commit» (archivo o carpeta entera, con estado parcial), con conteos, +/− y recorrido con teclado.
- Diff nativo seleccionable, búsqueda, números originales/nuevos y stage/unstage por archivo o bloque. Commit y amend con hooks reales.
- Historial con grafo de padres, filtros, detalle y comparación; ramas, remotos, tags, stash, reflog y worktrees.
- Sincronizar ramas: compara main/develop (u otras) por contenido, muestra qué falta en cada una y qué ya se copió, y copia lo seleccionado con un clic.
- Protección de main por repositorio: automática según la regla real de GitHub/Bitbucket (con token), o elegida a mano desde la barra de estado. Si no se conoce, main queda libre y subir a main pide confirmación. Bajar cambios con avance rápido siempre está permitido.
- Íconos de archivo de [Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme) (MIT; licencia en `native/Sources/ButakeGit/FileIcons/`). Actualizar con `scripts/update-file-icons.py`.
- Organizar commits: combinar (squash), reordenar arrastrando, editar mensajes o quitar commits no publicados, sin editor, con respaldo y «Deshacer».
- Rebase visual: pick, reword, edit, squash, fixup, drop y reordenamiento; continuar/abortar y terminal interactiva.
- Editor de conflictos con base/ours/theirs y resultado editable; comprobación de cambios concurrentes antes de guardar/preparar.
- Consola Git con terminal PTY nativa, argumentos separados y confirmación del comando; diccionario offline de 152 comandos y más de 50 conceptos.
- GitHub y Bitbucket Cloud: PR (listar, crear, comentar, aprobar, integrar), checks y Actions/Pipelines. Ajustes › Cuentas indica dónde crear cada token y qué permisos marcar; los tokens viven sólo en el llavero.
- Notch: estado del repositorio, commits por bajar/subir, métricas y acciones rápidas al pasar el cursor.
- Detección de agentes CLI instalados y lanzamiento confirmado en un worktree.

**No equivale todavía a paridad completa con GitKraken o IntelliJ.** Ver [matriz de funciones](feature-matrix.md) y [pendientes](roadmap.md). El catálogo no implica que todos los comandos estén instalados ni que todas sus variantes puedan ejecutarse.

## Rendimiento

Pensado para alto flujo con agentes de IA (cientos o miles de archivos cambiados). Medido con 1.500 archivos cambiados en un Mac Apple Silicon: refresco ~100 ms, preparar o retirar todo en un solo proceso Git (~0,3 s), estadísticas +/− en segundo plano y cambios externos detectados en vivo con FSEvents (una ráfaga de 600 archivos produce un único refresco). Scroll medido a 120 fps sin tirones en historial con 4.635 commits y en Cambios con 1.500 archivos. Cambiar entre Historial y Cambios produce a lo sumo una pausa breve (~30–60 ms) en repos grandes, a menudo ninguna. Para repos muy grandes conviene activar en el repo `core.fsmonitor` y `core.untrackedCache`.

## Límites

Historial paginado de 180 en 180 commits (máximo 5.000 cargados); sin virtualización ni mediciones con repos grandes. Preparación por bloque, todavía no por líneas individuales. Planificador visual de rebase sin merges; otras variantes van por consola. Previews de texto UTF-8; binarios requieren herramienta externa.

La política local protege main y bloquea force push, pushes masivos y ciertas variantes de plumbing. Git conserva sus hooks, SSH Agent y credential helpers. La terminal permite responder prompts y usar el editor de Git. Estas guardas no reemplazan branch permissions del proveedor.

La API Bitbucket está implementada, **sin validación contra una cuenta real**; la lista de pull requests muestra los 50 más recientes (comentarios, revisiones, checks y repositorios se leen completos). No hay revisión inline de PR, orquestación simultánea de agentes, Insights, Jira ni integración AWS CodePipeline. Sólo una sesión PTY activa.

`native/` (app) y `engine/` (motor) son todo el producto. No hay CI/CD activado. La firma y notarización se hacen en local con `package-dmg.sh`.

## Instalador y sitio

- `./scripts/package-dmg.sh` arma `build/Butake-Git.dmg` (firmado con Developer ID, notarizado y con ticket adjunto si el certificado y el perfil `butake-notary` están en el llavero; si no, ad hoc) y su suma SHA-256. Se publica como recurso de cada versión en GitHub Releases.
- `site/` es la página de presentación (Astro, estándar visual Butake: monocromo, Inter, Remix Icon). `cd site && npm install && npm run dev`. El workflow `.github/workflows/pages.yml` la publica en GitHub Pages cuando cambia `main`.
