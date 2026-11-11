# Operación por IA y accesibilidad

Butake Git debe poder manejarse por completo mediante Accesibilidad de macOS (AX), que es como operan los agentes de IA de escritorio y VoiceOver. Regla: **ninguna acción puede depender sólo del hover, de un gesto o de un tooltip.**

## Convenciones

- Cada control relevante lleva `accessibilityIdentifier` estable, en inglés, con formato `área.acción`. El texto visible (`accessibilityLabel`) va en español mediante `L`.
- Botones sólo con ícono: siempre con `accessibilityLabel`.
- Filas con acciones de hover o menú contextual: `accessibilityAction(named:)` equivalentes (preparar, descartar, cambiar de rama, copiar…).
- La información que aparece en tarjetas de hover se expone también como `accessibilityValue`/`accessibilityHint`.

## Identificadores

| Área | Identificadores |
|---|---|
| Barra de herramientas | `toolbar.fetch`, `toolbar.pull`, `toolbar.push`, `toolbar.tools`, `toolbar.refresh`, `toolbar.inspector` |
| Barra lateral | `sidebar.repository`, `sidebar.clone`, `sidebar.newBranch`, `route.<ruta>` (p. ej. `route.history`, `route.changes`), `branch.<nombre>` (acciones AX: cambiar, renombrar, eliminar), `remoteBranch.<remoto/rama>` (acciones AX: traer, eliminar remota) |
| Bienvenida | `welcome.open`, `welcome.clone`, `welcome.newRepository` |
| Crear y publicar | `sidebar.newRepository`, `sidebar.publish`, `status.publish`, `remotes.publish`, `newRepo.name`, `newRepo.create`, `publish.name`, `publish.submit` |
| Clonar | `clone.url`, `clone.chooseFolder`, `clone.name`, `clone.submit` |
| Editor de archivo | `editor.content`, `diff.editFile` (botón «Editar» del diff en Cambios) |
| Historial | `commit.<hash7>`, `history.loadMore` |
| Inspector de commit | `inspector.close`, `inspector.copyHashIcon`, `inspector.copyHash`, `inspector.branchHere`, `inspector.revert`, `inspector.cherryPick`, `inspector.compare`, `inspector.viewCommit`, `inspector.parent.<hash7>` |
| Cambios | `file.unstaged.<ruta>`, `file.staged.<ruta>`, `changes.stageAll`, `changes.unstageAll`, `changes.toggleUnstaged`, `changes.toggleStaged` (contraer o expandir cada panel), `commit.type`, `commit.message`, `commit.amend`, `commit.submit`, `inspector.toggleStage`, `inspector.copyPath`, `inspector.reveal`, `inspector.discard` |
| Conflictos | `conflicts.resolveNext`, `conflict.<ruta>`, `conflict.result`, `conflict.useOurs`, `conflict.useTheirs`, `conflict.useBoth`, `conflict.save`, `conflict.cancel`, `banner.resolve`, `banner.continue`, `banner.skip`, `banner.abort` |
| Bajar cambios | `pull.sync`, `pull.branches` (main protegida y divergente), `pull.merge`, `pull.rebase`, `pull.autostash`, `pull.goCommit`, `pull.resolve`, `pull.abort`, `pull.push`, `pull.retry`, `pull.close` |
| Confirmación | `confirm.preview`, `confirm.cancel`, `confirm.execute` |
| Diff nativo | `diff.content`, `diff.copy`, `diff.openEditor`, `diff.close`; con varios archivos: `diff.expandAll` / `diff.collapseAll` (el mismo botón, según el estado) y `diff.file.<ruta>` (cabecera de cada archivo: expandir o contraer; su valor AX dice si está expandido) |
| Sincronizar ramas | `route.sync`, `sync.left`, `sync.right` (ramas locales y remotas), `sync.swap`, `sync.refresh` (volver a consultar el remoto), `sync.stale.<rama>` (aviso de rama local atrasada), `sync.selectAll.<rama>`, `sync.commit.<hash7>`, `sync.copyTo.<rama>` |
| Barra de estado | `status.mainProtection`, `status.checkRemoteProtection` |
| Ramas | `branches.switch` |
| Listas de herramientas | `<sección>.<id>` (p. ej. `tags.v1.0`, `stash.stash@{0}`, `reflog.HEAD@{3}`, `remotes.origin`), `pr.viewRemotes` |
| Pull requests | `pr.<número>`, `pr.new`, `pr.approve`, `pr.merge`, `pr.tab.overview`, `pr.tab.changes`, `pr.toggleChecks`, `pr.comment.agent.<id>`, `pr.commentText`, `pr.sendComment`, `pr.viewRemotes` |
| Ajustes | `settings.notch` (mostrar u ocultar el notch) |
| Tamaño del texto | Menú Visualización: «Aumentar tamaño del texto» (⌘+), «Reducir tamaño del texto» (⌘−), «Tamaño real del texto» (⌘0) |
| Bloques del diff | `diff.newFileNotice` (aviso de archivo nuevo con una parte preparada y otra no; en ese caso no hay bloques), `diff.hunks` (menú) y `diff.hunk.<n>`: preparar o retirar un bloque sin clic derecho |
| Árbol de Cambios (Carpetas) | `tree.<ruta>`: acción AX por omisión (abrir carpeta o elegir archivo) y acción «Preparar archivo» / «Retirar del índice»; el valor AX dice si está preparado o contraído |
| Ramas (vista) | `branches.newBranch`, `branches.findBranch`, `branches.compareBase`, `branches.refresh`, `branches.switch`, `branches.branchActions` (`branches.merge`, `branches.rebase`, `branches.rename`, `branches.delete`), `branches.branchDisplay` |
| Herramientas (worktrees, etiquetas, stash, remotos, reflog) | `tools.refresh`, `tools.newWorktree`, `tools.newTag`, `tools.newRemote`, `tools.stashSave`, y por fila `tools.open`, `tools.openFinder`, `tools.delete`, `tools.stashApply`, `tools.stashPop`, `tools.stashDrop`, `tools.diff`, `tools.viewChanges`, `tools.fetch`; formulario: `tools.name`, `tools.remoteURL`, `tools.path`, `tools.create`, `tools.cancel` |
| Archivos | `files.findFile`, `files.refresh`, `files.file.<ruta>` (acción AX «Editar archivo»), `files.editorDisplay`, `files.saveFile`, `files.reloadFile`, `files.discardAndReload` (en el diálogo de descartar), `files.close` |
| Consola Git | `console.command`, `console.arguments`, `console.execute`, `console.stop` |
| Nueva rama | `newBranch.name`, `newBranch.problem` (por qué el nombre no sirve), `newBranch.create`, `newBranch.cancel` |
| Otros | `branches.renameConfirm`, `tools.more`, `tools.stashMenu` (acciones de stash también como acciones AX de la fila), `tree.toggleAll`, `tree.more`, `dictionary.category.<categoría>`, `publish.branch.<rama>` |
| Diccionario | `dictionary.dictionary` (comandos o conceptos), `dictionary.commands` (categoría), `dictionary.inspectConsole`, `dictionary.localHelp` |
| Agentes | `agents.worktrees`, `agents.open.<nombre>`, `agents.confirm` |
| Rebase visual | `rebase.rebaseBase`, `rebase.loadPlan`, `rebase.step.<n>.action`, `rebase.step.<n>.moveUp`, `rebase.step.<n>.moveDown`, `rebase.applyPlan`, `rebase.cancel` |
| Notch | `notch.repository` (cambiar repo, ocultar notch, ajustes), `notch.branch` (cambiar/traer/crear rama), `notch.pull`, `notch.push`, `notch.commit`; panel flotante: `quick.commitMessage`, `quick.commit`, `quick.commitPush`, `quick.confirm`, `quick.branchName` |
| Organizar commits | `organize.combine`, `organize.split`, `organize.drop`, `organize.edit`, `organize.reset`, `organize.apply`, `organize.message`, `organize.item.<hash7>` (acciones AX «Subir commit» / «Bajar commit», equivalentes a arrastrar), `history.undoRewrite` |

## Flujo «Bajar cambios»

1. `toolbar.pull` → confirmación → `git pull --ff-only`.
2. Si falla, el motor devuelve un código: `pull_diverged`, `pull_local_changes`, `pull_conflicts`, `pull_no_upstream` o `pull_remote_unreachable`, y la app abre el asistente con opciones (combinar, reorganizar, guardar cambios temporalmente, resolver, cancelar).
3. Con conflictos: sección «Conflictos» en Cambios y banner naranja; cada archivo se resuelve en el editor (tu versión, entrante, ambas o edición) y al guardar se prepara; luego `banner.continue`.

## Motor sin interfaz

`butake-git-engine` recibe un JSON por stdin y responde `{ok, value | error{code, detail}}`. Métodos útiles: `open`, `snapshot` (`limit`), `action` (`stage`, `unstage`, `discard`, `commit`, `fetch`, `pull`, `pull_merge`, `pull_rebase`, `pull_autostash`, `push`…; las mutaciones exigen `confirmed: true`), `setRemoteProtection` (`true`/`false`/`unknown`, caché de la regla del proveedor), `clone` (`path` = carpeta destino, `url`, `name`; sólo https, ssh y git@), `init` (`path` = carpeta, `name`, `develop`), `publish` (`url`, `branches`, exige `confirmed`; agrega origin y sube sin forzar), acciones de rama `track_branch`, `rename_branch` (`vieja:nueva`), `delete_branch`, `force_delete_branch`, `delete_remote_branch` (las eliminaciones exigen `confirmed`), `query` (lista blanca de lectura), `prepare`/`run`, `conflict`, `resolveConflict`. Las guardas de `main`, rutas y referencias aplican igual que en la app.

## QA automatizado (sólo compilación debug)

Compilar con `BUTAKE_DEBUG=1 ./scripts/build-native.sh` (debug) o `BUTAKE_QA=1 ./scripts/build-native.sh` (optimizada, para medir rendimiento real); la build normal es release y no incluye estos ganchos.

`BUTAKE_QA_ACTIONS=pull,pull_merge,resolve` junto a `--repository <ruta>` reproduce acciones sin mover el mouse y registra el estado con `NSLog("BUTAKE_QA …")`. Pasos de rendimiento: `bench` (refresco, preparar/retirar todo, grafo), `loadAll` (5.000 commits), `history`/`changes`, `scroll` (480 cuadros sincronizados con la pantalla; reporta promedio, p95 y tirones), `refreshbench` y `switchbench`. `clone`, `newBranch`, `newRepository` y `publish` abren sus hojas; `notchOff`/`notchOn` cambian la opción del notch; `fileDiff:<ruta>` muestra el diff de un archivo en HEAD; `renderEditor:<archivo>|<png>|<pestaña>[|dark]` dibuja el editor; `route:<sección>` abre cualquier sección (p. ej. `route:reflog`). `shot:<ruta.png>` guarda una captura hecha desde la app (no depende de Spaces ni del foco); `sync`, `tags`, `dark`/`light`/`system` cambian sección o tema; `renderQuick:<commit|push|branch>|<png>` dibuja el panel del notch; `renderPR:<ruta.png>[|dark]` dibuja el panel de PR con datos de ejemplo (sin token); `organize`, `org:combine:<h7>+<h7>`, `org:apply` y `undoRewrite` manejan el organizador. Las ejecuciones QA no modifican la lista de recientes. Usar sólo con repositorios temporales.
