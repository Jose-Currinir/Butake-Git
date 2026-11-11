#!/bin/bash
# Actualiza Butake Git a la última versión publicada, sin desinstalar ni arrastrar nada.
#
#   curl -fsSL https://jose-currinir.github.io/Butake-Git/actualizar.sh | bash
#
# Qué hace: descarga el instalador de la última versión de GitHub, comprueba su suma SHA-256 publicada y que la
# app esté firmada con el Developer ID de Butake SpA y notarizada por Apple, cierra la app, la reemplaza en su
# carpeta (restaurando la anterior si algo falla) y la vuelve a abrir. Si la carpeta no es tuya, macOS pide tu
# contraseña con sudo; este script nunca la lee.
#
# Opciones: --forzar reinstala aunque ya tengas la última versión.
# Variable: BUTAKE_APP=/ruta/Butake Git.app para actualizar una copia en otra ubicación.
set -euo pipefail

REPO="Jose-Currinir/Butake-Git"
TEAM="9MJ82YJXM2"
BUNDLE="cl.butake.git.native"
FORCE=0; [ "${1:-}" = "--forzar" ] && FORCE=1

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "Butake Git es para macOS."

if [ -n "${BUTAKE_APP:-}" ]; then APP="${BUTAKE_APP}"
elif [ -d "/Applications/Butake Git.app" ]; then APP="/Applications/Butake Git.app"
elif [ -d "${HOME}/Applications/Butake Git.app" ]; then APP="${HOME}/Applications/Butake Git.app"
else APP="/Applications/Butake Git.app"; fi

installed="$( [ -d "${APP}" ] && /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP}/Contents/Info.plist" 2>/dev/null || echo "")"
api="$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO}/releases/latest")" || fail "No se pudo consultar GitHub."
tag="$(printf '%s' "${api}" | plutil -extract tag_name raw -o - - 2>/dev/null)" || fail "No se pudo leer la versión publicada en la respuesta de GitHub."
latest="${tag#[vV]}"
[ -n "${latest}" ] || fail "No se encontró la última versión publicada."
# URL de esa versión exacta: «releases/latest/download» puede seguir sirviendo la anterior por caché.
DOWNLOAD="https://github.com/${REPO}/releases/download/${tag}"

newer() { # ¿$1 es mayor que $2? (comparación numérica por partes)
  local IFS=.; local a=($1) b=($2) i
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    local x=${a[i]:-0} y=${b[i]:-0}; x=${x%%[!0-9]*}; y=${y%%[!0-9]*}
    (( 10#${x:-0} > 10#${y:-0} )) && return 0
    (( 10#${x:-0} < 10#${y:-0} )) && return 1
  done
  return 1
}

if [ -n "${installed}" ]; then say "Instalada: ${installed} · Última: ${latest} · ${APP}"; else say "Butake Git no está instalada; se instalará la ${latest} en ${APP}"; fi
if [ -n "${installed}" ] && ! newer "${latest}" "${installed}" && [ ${FORCE} = 0 ]; then
  echo "Ya tienes la última versión. Usa --forzar para reinstalarla."; exit 0
fi

WORK="$(mktemp -d -t butake-actualizar)"
MOUNT="${WORK}/mount"
cleanup() { hdiutil detach "${MOUNT}" -force >/dev/null 2>&1 || true; rm -rf "${WORK}"; }
trap cleanup EXIT

say "Descargando Butake Git ${latest}…"
curl -fL --progress-bar -o "${WORK}/Butake-Git.dmg" "${DOWNLOAD}/Butake-Git.dmg" || fail "No se pudo descargar el instalador."
curl -fsSL -o "${WORK}/Butake-Git.dmg.sha256" "${DOWNLOAD}/Butake-Git.dmg.sha256" || fail "No se pudo descargar la suma SHA-256."

say "Verificando…"
expected="$(awk '{print tolower($1)}' "${WORK}/Butake-Git.dmg.sha256")"
actual="$(shasum -a 256 "${WORK}/Butake-Git.dmg" | awk '{print $1}')"
[ -n "${expected}" ] && [ "${expected}" = "${actual}" ] || fail "La descarga no coincide con la suma SHA-256 publicada. No se instaló nada."
echo "  ✓ Suma SHA-256"

mkdir -p "${MOUNT}"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "${MOUNT}" "${WORK}/Butake-Git.dmg" >/dev/null 2>&1 || fail "No se pudo abrir el instalador."
ditto "${MOUNT}/Butake Git.app" "${WORK}/Butake Git.app" || fail "El instalador no contiene la app."
got="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${WORK}/Butake Git.app/Contents/Info.plist" 2>/dev/null || echo "")"
[ "${got}" = "${latest}" ] || fail "El instalador descargado es la versión ${got}, no la ${latest}. No se instaló nada; inténtalo en unos minutos."
hdiutil detach "${MOUNT}" -force >/dev/null 2>&1 || true

codesign --verify --deep --strict "${WORK}/Butake Git.app" 2>/dev/null || fail "La firma de la app no es válida. No se instaló nada."
# Requisito de código que el sistema comprueba contra la cadena de certificados (el mismo que usa la app al
# actualizarse): certificado Developer ID emitido por Apple, equipo de Butake SpA y este identificador de bundle.
REQUIREMENT="anchor apple generic and identifier \"${BUNDLE}\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"${TEAM}\""
codesign --verify --deep --strict -R="${REQUIREMENT}" "${WORK}/Butake Git.app" 2>/dev/null || fail "La app no está firmada por Butake SpA. No se instaló nada."
echo "  ✓ Firma Developer ID de Butake SpA (${TEAM})"
spctl --assess --type execute "${WORK}/Butake Git.app" 2>/dev/null || fail "macOS no acepta la app como notarizada. No se instaló nada."
echo "  ✓ Notarizada por Apple"

# Cierra la app si está abierta (primero con normalidad; si no responde, la termina).
pid="$(pgrep -f "${APP}/Contents/MacOS/ButakeGit" || true)"
if [ -n "${pid}" ]; then
  say "Cerrando Butake Git…"
  osascript -e "tell application \"${APP}\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do kill -0 ${pid} 2>/dev/null || break; sleep 0.5; done
  kill -0 ${pid} 2>/dev/null && { kill ${pid} 2>/dev/null || true; sleep 1; }
fi

say "Instalando…"
SUDO=""; [ -w "$(dirname "${APP}")" ] && { [ ! -e "${APP}" ] || [ -w "${APP}" ]; } || SUDO="sudo"
[ -n "${SUDO}" ] && echo "  La carpeta requiere permisos de administrador; macOS te pedirá tu contraseña."
BACKUP="${APP}.anterior"
${SUDO} rm -rf "${BACKUP}"
[ -e "${APP}" ] && ${SUDO} mv "${APP}" "${BACKUP}"
if ${SUDO} ditto "${WORK}/Butake Git.app" "${APP}"; then
  ${SUDO} rm -rf "${BACKUP}"
else
  ${SUDO} rm -rf "${APP}"; [ -e "${BACKUP}" ] && ${SUDO} mv "${BACKUP}" "${APP}"
  fail "No se pudo copiar la app; se restauró la versión anterior."
fi

say "Listo: Butake Git ${latest} instalada. Desde ahora la app te avisa de las nuevas versiones."
[ "${BUTAKE_NO_OPEN:-0}" = "1" ] || open "${APP}"
