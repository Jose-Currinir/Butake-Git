// Textos de la página. Un solo idioma por ahora; todo texto visible vive aquí.
export const repo = 'https://github.com/Jose-Currinir/Butake-Git'
export const descarga = `${repo}/releases/latest/download/Butake-Git.dmg`

export const t = {
  titulo: 'Butake Git · Cliente Git nativo para macOS',
  descripcion: 'El cliente Git nativo para macOS pensado para equipos que trabajan con IA: revisa cientos de cambios, intercambia commits entre ramas y publica, en español.',
  nav: { funciones: 'Funciones', seguridad: 'Seguridad', instalar: 'Instalar', github: 'GitHub', descargar: 'Descargar' },
  hero: {
    etiqueta: 'Gratis y de código abierto · Apache 2.0',
    titulo: 'El cliente Git nativo para equipos que trabajan con IA',
    texto: 'Revisa cientos de cambios de un agente, mueve commits entre main y develop sin miedo y controla tu repositorio desde el notch. Todo en español.',
    descargar: 'Descargar para Mac',
    github: 'Ver en GitHub',
    requisitos: 'macOS 14 o superior · Mac con Apple Silicon',
    imagen: 'Historial con grafo de ramas y detalle del commit',
  },
  porque: {
    titulo: 'Hecho para el ritmo de hoy',
    texto: 'Los clientes Git se diseñaron para cambios a mano. Un agente de IA puede tocar 1.200 archivos en minutos, y muchos equipos trabajan main y develop en paralelo.',
    tarjetas: [
      { icono: 'flashlight-line', titulo: 'Rápida con miles de archivos', texto: '1.500 cambios: refresco en ~100 ms, preparar todo en 0,3 s y scroll a 120 fps.' },
      { icono: 'robot-2-line', titulo: 'Pensada para IA', texto: 'Revisor con marcas que se quitan solas si el agente vuelve a cambiar el archivo.' },
      { icono: 'shield-check-line', titulo: 'Segura por defecto', texto: 'Confirmación antes de cada cambio, force push bloqueado y tokens sólo en el llavero.' },
      { icono: 'apple-line', titulo: 'Nativa de verdad', texto: 'SwiftUI y AppKit, sin WebView. Vidrio de macOS, modo claro y oscuro, en español.' },
    ],
  },
  funciones: [
    { id: 'revisar', icono: 'checkbox-multiple-line', etiqueta: 'Revisar cambios', titulo: 'Revisa lo que hizo la IA, archivo por archivo', texto: 'Árbol por carpetas, progreso y filtros por tipo y extensión. La marca de revisado se quita sola si el archivo vuelve a cambiar: nunca das por bueno algo que el agente modificó después.', puntos: ['Espacio: revisado y siguiente', 'S: preparar · N: siguiente sin revisar', 'Acciones por carpeta'], imagen: 'revisar.png', alt: 'Revisor de cambios agrupado por carpetas' },
    { id: 'codigo', icono: 'code-s-slash-line', etiqueta: 'Código', titulo: 'Diff que se lee como código', texto: 'Colores de sintaxis para más de 20 lenguajes, el +/− en el margen y sólo la parte que cambió resaltada dentro de la línea. Editor nativo con números de línea y vista previa de Markdown.', puntos: ['PHP, Blade, JS/TS, Python, Swift, Rust, SQL…', 'Más de 600 íconos de archivo', 'Guardado con detección de cambios ajenos'], imagen: 'diff.png', alt: 'Diff con resaltado de sintaxis y cambio dentro de la línea' },
    { id: 'ramas', icono: 'git-branch-line', etiqueta: 'Ramas', titulo: 'Intercambia commits entre main y develop', texto: 'Sincronizar ramas compara por contenido: un commit copiado con cherry-pick aparece como «ya está en ambas». Selecciona lo que falta y cópialo con un clic. Organiza la historia sin editor y con «Deshacer».', puntos: ['Detecta main o master en cada repositorio', 'Ramas remotas agrupadas por tipo', 'Respaldo antes de reescribir'], imagen: 'sincronizar.png', alt: 'Sincronizar ramas entre develop y main' },
    { id: 'pr', icono: 'git-pull-request-line', etiqueta: 'Pull requests', titulo: 'Todo lo que falta para integrar, en una vista', texto: 'Checks agrupados por lo que requieren, revisores, comentarios en línea con el código alrededor y sugerencias como −/+. «Arreglar con IA» copia una instrucción lista para tu agente.', puntos: ['GitHub y Bitbucket', 'Actions y Pipelines', 'Tokens sólo en el llavero de macOS'], imagen: 'pull-request.png', alt: 'Panel de pull request con checks y conversación' },
    { id: 'notch', icono: 'macbook-line', etiqueta: 'Notch', titulo: 'Tu repositorio, junto a la cámara', texto: 'Cambios y commits por bajar o subir a los lados del notch. Al pasar el cursor: cambia de repositorio o rama, confirma subir o bajar y haz commit sin abrir la ventana.', puntos: ['Panel flotante nativo', 'Commit y subir en un paso', 'Se desactiva en Ajustes'], imagen: 'notch-open.png', alt: 'Tarjeta del notch con métricas y acciones' },
  ],
  galeria: {
    titulo: 'Y mucho más',
    items: [
      { icono: 'git-merge-line', texto: 'Asistente para bajar cambios y resolver conflictos' },
      { icono: 'list-ordered', texto: 'Organizar commits: combinar, reordenar, editar' },
      { icono: 'folder-add-line', texto: 'Crear, clonar y publicar repositorios' },
      { icono: 'terminal-box-line', texto: 'Consola Git con terminal nativa' },
      { icono: 'book-2-line', texto: 'Diccionario de 152 comandos en español' },
      { icono: 'history-line', texto: 'Reflog en lenguaje humano' },
      { icono: 'stack-line', texto: 'Worktrees, etiquetas, stash y remotos' },
      { icono: 'accessibility-line', texto: 'Operable por agentes de IA y VoiceOver' },
    ],
  },
  seguridad: {
    titulo: 'Seguridad sin sustos',
    texto: 'Butake Git asume que trabajas sobre repositorios reales.',
    puntos: [
      'Git sin shell: argumentos separados y rutas, referencias y direcciones validadas.',
      'Confirmación con el comando exacto antes de subir, descartar, reescribir o publicar.',
      'Force push y push masivo siempre bloqueados.',
      'Rama principal protegida según la regla real de GitHub o Bitbucket.',
      'Tokens sólo en el llavero de macOS; Git usa tu SSH Agent y tu gestor de credenciales.',
    ],
    estado: 'Activo',
  },
  rendimiento: {
    titulo: 'Medido, no prometido',
    datos: [
      { valor: '~100 ms', texto: 'refresco con 1.500 archivos cambiados' },
      { valor: '0,3 s', texto: 'preparar 1.500 archivos de una vez' },
      { valor: '120 fps', texto: 'scroll con 4.635 commits' },
      { valor: '1', texto: 'refresco por ráfaga de 600 escrituras' },
    ],
    nota: 'Mediciones en un Mac con Apple Silicon.',
  },
  instalar: {
    titulo: 'Instalar',
    pasos: [
      { titulo: 'Descarga', texto: 'Baja Butake-Git.dmg desde la última versión.' },
      { titulo: 'Arrastra', texto: 'Abre el .dmg y arrastra Butake Git a Aplicaciones.' },
      { titulo: 'Abre', texto: 'La primera vez, macOS pedirá confirmar: Ajustes del Sistema › Privacidad y seguridad › «Abrir igualmente».' },
    ],
    aviso: 'La app aún no está firmada con un certificado de Apple (Developer ID); por eso macOS pide confirmarla la primera vez.',
    codigoTitulo: 'O compila desde el código',
    codigo: 'git clone https://github.com/Jose-Currinir/Butake-Git.git\ncd Butake-Git\n./scripts/install-native.sh',
  },
  contribuir: {
    titulo: 'Abierto a tu aporte',
    texto: 'Nadie sube cambios directo: haz un fork y abre un pull request hacia develop. El equipo lo revisa y lo integra.',
    boton: 'Cómo contribuir',
  },
  pie: {
    licencia: 'Código bajo licencia Apache 2.0.',
    marca: 'Butake y su logo son marcas de Butake SpA y no se incluyen en la licencia.',
    copyright: '© 2026 Butake SpA',
  },
}
