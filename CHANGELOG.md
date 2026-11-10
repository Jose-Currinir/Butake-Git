# Cambios

## 1.0.5 · 2026-11-10

- **Cambios en Lista o Carpetas:** una sola vista con selector centrado. En Carpetas, cada casilla es
  «va en el commit» (archivo o carpeta entera, con estado parcial); mismo diff y compositor en ambas.
- Se retira la pantalla «Revisar cambios» con marcas de revisado: preparar y revisar son lo mismo.
- Historial queda como sección propia.

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
