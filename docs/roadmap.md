# Estado y pendientes

## Implementado

Interfaz SwiftUI/AppKit, marca Butake oficial, dos paneles de archivos y composer fijo; diff con números originales/nuevos; preparación por archivo/bloque; commit/amend; grafo real y detalle; ramas, tags, stash, remotos, reflog y worktrees; rebase visual; conflictos; consola PTY y diccionario. Bitbucket REST y lanzamiento individual de agentes CLI implementados.

## Pendiente antes de declarar paridad amplia

- Stage por líneas, diff lado a lado, comparación de imágenes/binarios, blame visual y búsqueda avanzada de historial.
- Virtualización del historial y mediciones con repos grandes (paginación implementada hasta 5.000 commits).
- Planes de rebase con merges; operaciones drag-and-drop y recuperación más guiada.
- Clonar/inicializar con asistente; formularios completos de submódulos, LFS, bisect, firma, config y ramas remotas (consola disponible según Git instalado).
- Validación Bitbucket con cuenta real; paginación, revisión inline, solicitud de cambios y manejo completo de revisores.
- Integraciones GitHub/GitLab/Azure, AWS CodePipeline, issues/Jira.
- Orquestación simultánea de agentes, tareas compartidas, métricas tipo Insights.
- Firma Developer ID, notarización, actualizaciones firmadas, distribución y CI autorizado.

La consola restringe force push, push masivo y ciertas operaciones de plumbing. No se promete ejecución irrestricta de todas las variantes de Git. No hay versión Windows/Linux nativa en este alcance.
