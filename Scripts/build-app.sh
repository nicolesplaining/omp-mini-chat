#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
OUTPUT_DIR=${PROJECT_DIR}/outputs
APP_PATH=${OUTPUT_DIR}/OMP\ Mini\ Chat.app
VENDOR_DIR=${PROJECT_DIR}/Vendor
OMP_VERSION=18.1.4

case "$(uname -m)" in
  arm64) OMP_ASSET=omp-darwin-arm64 ;;
  x86_64) OMP_ASSET=omp-darwin-x64 ;;
  *) print -u2 "Unsupported Mac architecture: $(uname -m)"; exit 1 ;;
esac

mkdir -p "${VENDOR_DIR}" "${OUTPUT_DIR}"

if [[ ! -x "${VENDOR_DIR}/omp" || ! -f "${VENDOR_DIR}/omp.version" || "$(<"${VENDOR_DIR}/omp.version")" != "${OMP_VERSION}-${OMP_ASSET}" ]]; then
  print "Downloading official Oh My Pi ${OMP_VERSION} runtime…"
  BASE_URL="https://github.com/can1357/oh-my-pi/releases/download/v${OMP_VERSION}"
  curl --fail --location --progress-bar "${BASE_URL}/${OMP_ASSET}" --output "${VENDOR_DIR}/omp.download"
  curl --fail --location --silent --show-error "${BASE_URL}/SHA256SUMS.txt" --output "${VENDOR_DIR}/SHA256SUMS.txt"
  EXPECTED=$(awk -v asset="${OMP_ASSET}" '$2 == asset { print $1 }' "${VENDOR_DIR}/SHA256SUMS.txt")
  ACTUAL=$(shasum -a 256 "${VENDOR_DIR}/omp.download" | awk '{ print $1 }')
  if [[ -z "${EXPECTED}" || "${EXPECTED}" != "${ACTUAL}" ]]; then
    print -u2 "OMP runtime checksum verification failed."
    exit 1
  fi
  mv "${VENDOR_DIR}/omp.download" "${VENDOR_DIR}/omp"
  chmod 755 "${VENDOR_DIR}/omp"
  print -r -- "${OMP_VERSION}-${OMP_ASSET}" > "${VENDOR_DIR}/omp.version"
fi

BASE_URL="https://github.com/can1357/oh-my-pi/releases/download/v${OMP_VERSION}"
for NOTICE in LICENSE THIRD-PARTY-NOTICES.txt; do
  if [[ ! -f "${VENDOR_DIR}/${NOTICE}" ]]; then
    curl --fail --location --silent --show-error "${BASE_URL}/${NOTICE}" --output "${VENDOR_DIR}/${NOTICE}"
  fi
done

print "Building OMP Mini Chat…"
swift build --package-path "${PROJECT_DIR}" -c release

if [[ -e "${APP_PATH}" ]]; then
  mv "${APP_PATH}" "${APP_PATH}.previous"
  rm -rf "${APP_PATH}.previous"
fi
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"
cp "${PROJECT_DIR}/.build/release/OmpMiniChat" "${APP_PATH}/Contents/MacOS/OmpMiniChat"
cp "${PROJECT_DIR}/Resources/Info.plist" "${APP_PATH}/Contents/Info.plist"
cp "${PROJECT_DIR}/Resources/mini-sync-leaf.js" "${APP_PATH}/Contents/Resources/mini-sync-leaf.js"
cp "${VENDOR_DIR}/omp" "${APP_PATH}/Contents/Resources/omp"
if [[ -x "${VENDOR_DIR}/omp-sync" ]]; then
  cp "${VENDOR_DIR}/omp-sync" "${APP_PATH}/Contents/Resources/omp-sync"
  cp "${PROJECT_DIR}/Integration/omp-mini-auto-sync.js" "${APP_PATH}/Contents/Resources/omp-mini-auto-sync.js"
  cp "${PROJECT_DIR}/Integration/omp" "${APP_PATH}/Contents/Resources/omp-launcher"
  chmod 755 "${APP_PATH}/Contents/Resources/omp-sync" "${APP_PATH}/Contents/Resources/omp-launcher"
  chmod 600 "${APP_PATH}/Contents/Resources/omp-mini-auto-sync.js"
fi
cp "${VENDOR_DIR}/LICENSE" "${APP_PATH}/Contents/Resources/OMP-LICENSE"
cp "${VENDOR_DIR}/THIRD-PARTY-NOTICES.txt" "${APP_PATH}/Contents/Resources/OMP-THIRD-PARTY-NOTICES"
chmod 755 "${APP_PATH}/Contents/MacOS/OmpMiniChat" "${APP_PATH}/Contents/Resources/omp"
codesign --force --deep --sign - "${APP_PATH}"

print "Built: ${APP_PATH}"
