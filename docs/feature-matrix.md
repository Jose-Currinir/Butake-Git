# Matriz funcional

Revisión: 2026-11-09. Referencias oficiales consultadas: GitKraken Desktop y Git de IntelliJ IDEA. Las imágenes aportadas incluyen productos diferentes: GitLens (contexto dentro del IDE), Kepler/Agents (orquestación) e Insights (métricas). No son comandos de Git ni equivalen a una sola pantalla del cliente.

**Nativo** = pantalla implementada; **consola** = comando Git real con PTY/confirmación, sujeto a instalación y guardas; **parcial** = límites explícitos; **pendiente** = sin implementar. La implementación no sustituye validación con servicios remotos reales.

| Área | Butake Git | Límite / siguiente paso |
|---|---|---|
| Repositorios locales y recientes | Nativo | Selector de carpetas y bookmarks |
| Estado, staging, commit/amend | Nativo | Dos paneles, scroll independiente, preparación por archivo/bloque, conteo +/−, descartar con confirmación |
| Revisión de lotes grandes (IA) | Nativo | Árbol compacto, filtros por tipo (nuevo/modificado/eliminado/movido) y extensión, +/− también en archivos nuevos, progreso, marcas por contenido guardadas en `.git/butake-review.json`, preparar/descartar por carpeta |
| Stage por líneas individuales | Pendiente | No confundir selección del archivo con inclusión en commit |
| Diff de texto | Nativo | Numeración original/nueva, búsqueda y selección; sin vista lado a lado |
| Imágenes, binarios y blame | Consola / parcial | Preview UTF-8; no comparador visual binario ni blame visual |
| Historial y grafo de commits | Nativo / parcial | Padres y merges reales; paginación de 180 en 180 (máx. 5.000), hover con rama, navegación por teclado |
| Branch, checkout/switch, merge | Nativo + consola | Formularios y acciones; main protegido |
| Fetch, pull, push/upstream | Nativo + consola | «Bajar cambios» ff-only con asistente: combinar, reorganizar o autostash; conflictos guiados; push con destino explícito; sin force/mass push |
| Organizar commits (squash, reordenar, mensajes, quitar) | Nativo | Sólo commits no publicados; sin editor; respaldo `refs/butake/backup/<rama>/<epoch>` y «Deshacer» con `reset --keep`; conflictos al reordenar van al asistente |
| Rebase interactivo | Nativo + PTY | Pick/reword/edit/squash/fixup/drop/reordenar; merges por consola |
| Conflictos | Nativo / parcial | Base/ours/theirs y resultado editable; cambios concurrentes comprobados; texto UTF-8 |
| Cherry-pick, revert y reset | Nativo + consola | Confirmación; guardas de main |
| Intercambio main/develop | Nativo | «Sincronizar ramas»: compara por contenido (`--cherry-mark`), lista exclusivos y ya copiados, copia seleccionados con `cherry-pick -x` y vuelve a la rama; etiquetas «solo main/solo develop/copiado» en el historial |
| Protección de main | Nativo | Por repo: explícita (`butake.protectMain`), si no la regla del proveedor leída por API (`butake.remoteProtectMain`), si no libre con aviso al subir a main; pull con avance rápido permitido en main protegida; force-push y push masivo siempre bloqueados |
| Stash, tags, remotos, reflog | Nativo + consola | Listas/formularios y acciones; variantes avanzadas en consola |
| Worktrees | Nativo + consola | Crear/listar y abrir; operaciones avanzadas en consola |
| Submódulos, LFS y bisect | Consola | Dependencias externas deben estar instaladas; sin asistentes dedicados |
| Clone/init, config, firma | Consola | Sin asistente completo de onboarding/firma |
| Hooks, SSH y helpers | Git real + PTY | Usa configuración local; no administrador visual de credenciales Git |
| PR GitHub y Bitbucket Cloud | Nativo / parcial | Proveedor detectado desde origin; listar/crear/comentar/aprobar/merge/checks; Ajustes › Cuentas guía la creación del token y prueba la conexión antes de guardar; sin revisión inline; no validado con cuentas reales |
| CI/CD | Parcial | GitHub Actions y Bitbucket Pipelines (consulta); sin AWS CodePipeline ni despliegues propios |
| Notch | Nativo | Panel junto al notch: cambios, por bajar/subir, líneas, commits de hoy, acciones rápidas; fetch automático opcional cada 5 min |
| GitLab y Azure PR | Pendiente | No confundir soporte Git remoto con API de PR |
| Diccionario y comandos | Nativo | 152 entradas offline; capacidades contrastadas con Git instalado; ciertas variantes bloqueadas |
| Agentes en worktrees | Parcial | Detectar y lanzar CLI instalado, una sesión activa; no orquestación simultánea |
| GitLens, Kepler, Insights, Jira | Pendiente | Contexto de código, métricas y gestión de tareas requieren productos/integraciones adicionales |
| Funciones generales IntelliJ | Fuera del cliente Git actual | Compilador, refactorización semántica, debugger y navegación de símbolos no son Git |

## Fuentes oficiales

- [GitKraken Desktop](https://www.gitkraken.com/git-client): grafo, operaciones Git e integraciones.
- [Rebase interactivo](https://help.gitkraken.com/gitkraken-desktop/interactive-rebase/): edición de historial y límites con merges.
- [Pull requests](https://help.gitkraken.com/gitkraken-desktop/pull-requests/) y [Bitbucket](https://help.gitkraken.com/gitkraken-desktop/bitbucket/): integración del proveedor, separada de Git local.
- [Worktrees](https://help.gitkraken.com/gitkraken-desktop/worktrees/) y [agentes](https://help.gitkraken.com/gitkraken-desktop/agents/): espacios de trabajo y sesiones.
- [Git en IntelliJ IDEA](https://www.jetbrains.com/help/idea/using-git-integration.html), [editar historial](https://www.jetbrains.com/help/idea/edit-project-history.html), [resolver conflictos](https://www.jetbrains.com/help/idea/resolve-conflicts.html) y [worktrees](https://www.jetbrains.com/help/idea/use-git-worktrees.html).
- [Manual de Git](https://git-scm.com/docs/git) y [git rebase](https://git-scm.com/docs/git-rebase): comandos y semántica canónica.
- [API Bitbucket](https://developer.atlassian.com/cloud/bitbucket/rest/) y [API tokens](https://support.atlassian.com/bitbucket-cloud/docs/using-api-tokens/).
- [NSScrollView contentInsets](https://developer.apple.com/documentation/appkit/nsscrollview/contentinsets): comportamiento de rulers y márgenes nativos.

Estas referencias orientan la comparación; no constituyen certificación de equivalencia funcional ni una lista exhaustiva de cada variante de cada producto.
