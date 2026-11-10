# Cómo contribuir

¡Gracias por tu interés en Butake Git! El proyecto lo mantiene Butake SpA.

**Nadie sube cambios directo a este repositorio.** Se colabora con pull requests, que el
equipo revisa y aprueba antes de integrar. `main` y `develop` están protegidas.

## Pasos

1. Para cambios grandes o nuevas funciones, abre primero un *issue* y lo conversamos.
2. Haz un fork, crea una rama desde `develop` (por ejemplo `feature/mi-cambio` o `fix/mi-arreglo`)
   y abre el pull request hacia `develop`. `main` es la rama de versiones.
3. Verifica antes de enviar:
   ```bash
   ./scripts/test-native.sh
   ./scripts/build-native.sh
   git diff --check
   ```
4. Si cambias la interfaz, adjunta una captura y prueba modo claro y oscuro.

## Reglas del proyecto

- Código y nombres en inglés; textos visibles en español mediante `L(...)` y
  `native/Sources/ButakeGit/Resources/es.lproj/Localizable.strings`.
- Git siempre con argumentos separados (nunca texto de shell); confirmación antes de
  acciones que cambian el repositorio o publican algo.
- Nada de secretos en el repositorio: los tokens viven sólo en el llavero de macOS.
- Cada control relevante con `accessibilityIdentifier` (ver `docs/automation.md`).

## Mensajes de commit

Conventional commits en español: `<tipo>(<módulo>): <descripción>`, por ejemplo
`fix(diff): corrige el resaltado de comentarios`. Tipos: `feat`, `fix`, `docs`, `chore`,
`refactor`, `test`, `perf`, `style`.

## Licencia de los aportes

Al enviar un pull request aceptas que tu aporte se publique bajo la
[Licencia Apache 2.0](LICENSE) del proyecto (sección 5). Conservas el crédito en el
historial; el aviso de copyright (`NOTICE`) se mantiene a nombre de Butake SpA.
El nombre y el logo de Butake no forman parte de la licencia.
