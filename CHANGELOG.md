# Cambios

## 1.0.10 · 2026-11-12

- **Detecta si falta Git:** en un Mac sin Git la app lo dice al abrir, ofrece el instalador oficial de Apple
  (herramientas de línea de comandos, sin Xcode completo) y continúa sola cuando termina. Si ya tienes Git de
  Homebrew, usa ese.
- **Integración con Butake Stack:** botón «Abrir en Butake Stack» cuando el repositorio es un sitio de Stack, o
  «Agregar a Butake Stack» para servirlo como sitio `.test`.
- **Abrir desde otras apps:** `butakegit://open?path=…` y las carpetas entregadas a la app abren el repositorio.
- Los temas y el tamaño de texto vienen ahora del paquete compartido
  [Butake Design](https://github.com/Jose-Currinir/Butake-Design), el mismo de Butake Stack.

## 1.0.9 · 2026-11-11

- **Corregido: la app se pegaba al guardar** desde el editor con la pestaña «Ver cambios» abierta.
- **Consola Git:** un comando ya ejecutado no vuelve a correr al regresar a la pestaña; con una sesión en curso la
  app no deja cambiar de sección (antes la mataba a medias y quedaba bloqueada).
- **Confirmaciones:** el botón dice lo que hace («Eliminar rama», «Subir cambios») en vez de «Descartar»; subir y bajar
  muestran el destino (`develop → origin/develop`); `reset --hard` avisa que descarta cambios.
- **Notch:** «Commit y subir» confirma el push y no sube nada si preparar o commitear falló.
- **Bloques del diff:** preparar un bloque ya no puede caer en otro archivo (`diff.noprefix`), ni en otro bloque si el
  archivo cambió; funciona con archivos no UTF-8 y con renombres preparados.
- **Organizar commits:** conserva los mensajes nuevos si hay conflicto, no ofrece commits ya publicados y deshacer
  guarda otro respaldo antes de volver atrás.
- **Copiar commits:** informa cuántos copió de verdad, vuelve al commit original desde HEAD suelto y reconoce los
  conflictos «agregado en ambos» / «eliminado en ambos».
- **Protección de main:** un corte de red o un token vencido ya no la desactiva; la consola no la salta con
  `switch -C`, `checkout -B` ni `rebase <x> main`.
- **Diffs con finales de línea CRLF** ya no desalinean las tarjetas por archivo ni la numeración del editor.
- **Editor:** deshacer tras «Recargar» ya no corrompe el texto; cambiar de pestaña conserva cursor y deshacer.
- **Conflictos:** una línea `=======` propia del archivo ya no impide guardar; cancelar con cambios pide confirmación.
- **Pull requests:** el borrador de un comentario no se envía a otro PR al cambiar de selección.
- Historial con filtro: el grafo ya no congela la app con miles de commits; un filtro de archivo escrito en Cambios
  no lleva al Historial.
- Al cambiar de repositorio, una lectura tardía del anterior ya no lo reemplaza; los worktrees enlazados se
  refrescan con los cambios de Git hechos fuera de la app.
- Los hooks lentos o que dejan procesos en segundo plano ya no cortan el commit a los 2 minutos.
- Nueva rama valida el nombre antes de ejecutar; «Corregir el último commit» se desactiva después de enmendar.
- Más identificadores de accesibilidad (Archivos, Nueva rama, Conflictos, Consola) y sin identificadores repetidos.
- **Corregido: la app se pegaba con «Organizar commits» abierto** en cuanto VoiceOver o un agente consultaba la
  ventana; los estados vacíos de toda la app usan ahora una vista propia.
- **Corregido: abrir Clonar, Publicar o Pull requests podía bloquear la ventana** esperando al Llavero; las cuentas
  se leen una vez, en segundo plano.
- Comentarios, revisiones, checks y repositorios del proveedor se leen completos (antes sólo los
  primeros 100); un repositorio renombrado en el proveedor ya no aparece como error de red.
- **Archivo nuevo preparado y luego editado** (por ejemplo, una copia que el IDE agrega sola): «Sin preparar» lo
  muestra completo como archivo nuevo, con un aviso de que tiene una parte preparada y otra no, y sus líneas se
  cuentan una sola vez (antes parecía un archivo existente modificado, con +30 −10 para 20 líneas).
- La actualización valida la firma con un requisito de código (certificado Developer ID de Butake y bundle exacto).
- **Web:** en teléfonos la página ya no se ensancha y angosta sola ni deja deslizar hacia la derecha.

## 1.0.8 · 2026-11-11

- **Diff por archivos:** al ver un commit o una comparación, cada archivo es una tarjeta con su estado (Nuevo,
  Modificado, Eliminado, Movido) y sus +/−; se expande o contrae con un clic, con «Contraer todo / Expandir todo».
- **Paneles de Cambios contraíbles:** «Sin preparar» y «Preparados para commit» se pliegan a su cabecera.
- **Tamaño del texto:** ⌘+ y ⌘− agrandan o achican el texto de toda la app (listas, diff, editor, terminal); ⌘0 lo restablece.
- **Tema en toda la app:** barras, listas, formularios, hojas, ajustes y terminal usan los colores del tema (antes
  Worktrees, Etiquetas, Stash, Remotos, Reflog, Ramas y otros quedaban con el gris del sistema).
- **Sincronizar ramas compara el estado real:** consulta el remoto al abrir, lista también las ramas que sólo
  existen en el remoto y, si una rama de tu Mac está atrasada, compara contra la del remoto y lo avisa. Ya no
  asume nombres de rama.
- Las insignias del Historial («solo <rama>», «en ambas») comparan la rama principal con la rama en la que trabajas,
  sea cual sea su nombre; antes sólo aparecían si existía una rama llamada develop.
- Las barras de scroll usan el color de acento del tema, sin la pista gris del sistema.
- **Accesibilidad para IA:** identificadores estables en Ramas, Herramientas, Archivos, Consola, Diccionario, Agentes y
  Rebase; preparar un bloque del diff desde el menú «Bloques»; reordenar commits y operar el árbol de Carpetas con
  acciones de accesibilidad, sin arrastrar ni hacer doble clic.
- Corregido: al elegir un archivo el diff podía quedarse cargando aunque ya hubiera llegado.
- Subir, bajar y buscar cambios ya no se cortan a los 2 minutos en repos grandes o enlaces lentos (30 minutos).
- Refresco más liviano: las ediciones de archivos sólo releen el estado, y el snapshot usa menos procesos de Git.

## 1.0.7 · 2026-11-11

- **Temas:** Butake Git y Drácula en claro y oscuro (o según el sistema), aplicados a toda la app: acento,
  fondos, tipos de cambio, diff, resaltado de código y grafo. Personalizador con vista previa en Ajustes.
- Seleccionar un commit con miles de archivos ya no congela ni cierra la app: el detalle los muestra por páginas.
- Los filtros del Historial se aplican al instante (animar miles de filas congelaba la app).
- Hoja de actualización más grande y legible.

## 1.0.6 · 2026-11-11

- **Búsqueda con filtros en el Historial:** `@autor:`, `@archivo:` y `@ext:` (y sus nombres en inglés), con
  sugerencias desplegables de autores, archivos y extensiones; combinables con texto libre.
- **Selección múltiple en Cambios** con ⇧/⌘: preparar, sacar o descartar varios archivos de una vez, con una
  sola confirmación y botón Descartar en la cabecera.
- **Menú contextual** con íconos y acciones en lote; «Ver commits de este archivo» abre el Historial filtrado.
- Fila seleccionada y contador de la barra lateral legibles en blanco sobre la selección.

## 1.0.5 · 2026-11-10

- **Cambios en Lista o Carpetas:** una sola vista con selector centrado. En Carpetas, cada casilla es
  «va en el commit» (archivo o carpeta entera, con estado parcial); mismo diff y compositor en ambas.
- Se retira la pantalla «Revisar cambios» con marcas de revisado: preparar y revisar son lo mismo.
- Historial queda como sección propia.
- Sin pestañazos al preparar: preparar no bloquea la ventana (los clics se encadenan), la barra lateral ya
  no se deshabilita, el diff no se vacía al cambiar de grupo y el árbol de Carpetas se arma en segundo plano
  (de ~355 ms a menos de 2 cuadros por clic con 3.000 archivos).
- Sin pantallazos en blanco: los indicadores de carga nativos de AppKit hacían recomponer toda la ventana en
  cada operación de Git; ahora se dibujan con SwiftUI. La barra de herramientas ya no se reconfigura en cada
  operación.

## 1.0.4 · 2026-11-10

- La instalación de una actualización ya no se queda en «Instalando»: la hoja se cierra antes de salir y,
  si algo bloquea el cierre, la app sale igual para que el reemplazo verificado termine.
- Comando para actualizar versiones anteriores sin desinstalar (`scripts/actualizar.sh`): descarga la
  última versión, verifica suma SHA-256, firma y notarización, y reemplaza la app.

## 1.0.3 · 2026-11-10

- **Actualizaciones:** la versión instalada se ve junto a Ajustes; la app busca versiones nuevas en
  GitHub (al abrir, cada 6 horas o a pedido) y las instala tras verificar la suma SHA-256 y la firma
  Developer ID de Butake SpA notarizada por Apple.
- **Fluidez con agentes de IA:** con miles de cambios y un agente escribiendo sin parar, la app pasa de
  congelarse 80–120 ms varias veces por segundo a casi 60 fps. Los refrescos que sólo cambian archivos
  ya no redibujan la ventana completa; contadores sin animación con listas grandes; estadísticas por fila.
- Listas de Cambios con más de 150 archivos muestran los primeros y un botón para ver todos.
- La barra superior queda alineada con la columna al abrir el panel de detalle.

## 1.0.2 · 2026-11-10

- Scroll del historial fluido a 60 fps también con miles de commits (antes ~20–40 fps en
  repositorios grandes): las filas ya no crean tooltips ni anclajes de popover propios.

## 1.0.1 · 2026-11-10

- Instalador firmado con Developer ID de Butake SpA y notarizado por Apple: abre sin advertencias.
- Al cerrar la ventana, la app sigue en el notch y vuelve a abrirse desde el Dock o con «Abrir»
  del notch (antes quedaba en uso sin ventana).
- El buscador de la barra ya no queda partido sobre el panel «Detalle del commit».

## 1.0.0 · 2026-11-10

Primera versión pública.

- Historial con grafo, cambios con preparación por archivo y bloque, compositor de commit.
- Revisar cambios para lotes grandes de agentes de IA, con marcas persistentes.
- Diff con resaltado de sintaxis y cambios dentro de la línea; editor de código nativo.
- Ramas según cada repositorio (main o master), locales y remotas; sincronizar ramas,
  copiar commits y organizar historia con respaldo.
- Asistente para bajar cambios y resolver conflictos.
- GitHub y Bitbucket: pull requests, checks, revisores, comentarios en línea, pipelines,
  clonar, crear y publicar repositorios.
- Notch con estado, cambio de repositorio y rama, commit y confirmaciones.
- Protección de la rama principal según el remoto; force push bloqueado.
