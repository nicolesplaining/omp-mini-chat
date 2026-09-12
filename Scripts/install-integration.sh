#!/bin/zsh
set -euo pipefail

OMP_MINI_SCRIPT_DIR=${0:A:h}
OMP_MINI_PROJECT_DIR=${OMP_MINI_SCRIPT_DIR:h}
OMP_MINI_APP_RESOURCES=${OMP_MINI_PROJECT_DIR}/outputs/OMP\ Mini\ Chat.app/Contents/Resources
if [[ -x "${OMP_MINI_SCRIPT_DIR}/omp-sync" ]]; then
  OMP_MINI_APP_RESOURCES=${OMP_MINI_SCRIPT_DIR}
fi
OMP_MINI_VENDOR_DIR=${OMP_MINI_PROJECT_DIR}/Vendor
OMP_MINI_SUPPORT_DIR=${HOME}/.local/share/omp-mini-chat
OMP_MINI_BIN_DIR=${HOME}/.local/bin
OMP_MINI_LAUNCHER=${OMP_MINI_BIN_DIR}/omp
OMP_MINI_STOCK=${OMP_MINI_BIN_DIR}/omp-stock

if [[ -x "${OMP_MINI_APP_RESOURCES}/omp-sync" ]]; then
  OMP_MINI_SYNC_SOURCE=${OMP_MINI_APP_RESOURCES}/omp-sync
  OMP_MINI_EXTENSION_SOURCE=${OMP_MINI_APP_RESOURCES}/omp-mini-auto-sync.js
  OMP_MINI_LAUNCHER_SOURCE=${OMP_MINI_APP_RESOURCES}/omp-launcher
elif [[ -x "${OMP_MINI_VENDOR_DIR}/omp-sync" ]]; then
  OMP_MINI_SYNC_SOURCE=${OMP_MINI_VENDOR_DIR}/omp-sync
  OMP_MINI_EXTENSION_SOURCE=${OMP_MINI_PROJECT_DIR}/Integration/omp-mini-auto-sync.js
  OMP_MINI_LAUNCHER_SOURCE=${OMP_MINI_PROJECT_DIR}/Integration/omp
else
  print -u2 "Build the sync-enabled OMP runtime before installing the integration."
  exit 1
fi

mkdir -p "${OMP_MINI_SUPPORT_DIR}/stock-path" "${OMP_MINI_BIN_DIR}"
chmod 700 "${OMP_MINI_SUPPORT_DIR}"

if [[ -x "${OMP_MINI_LAUNCHER}" ]] && ! grep -q "OMP Mini Chat launcher" "${OMP_MINI_LAUNCHER}"; then
  install -m 755 "${OMP_MINI_LAUNCHER}" "${OMP_MINI_STOCK}"
fi
if [[ ! -x "${OMP_MINI_STOCK}" && -x "${OMP_MINI_APP_RESOURCES}/omp" ]]; then
  install -m 755 "${OMP_MINI_APP_RESOURCES}/omp" "${OMP_MINI_STOCK}"
fi
if [[ ! -x "${OMP_MINI_STOCK}" ]]; then
  print -u2 "No official OMP executable was found at ${OMP_MINI_LAUNCHER}."
  exit 1
fi

install -m 755 "${OMP_MINI_SYNC_SOURCE}" "${OMP_MINI_SUPPORT_DIR}/omp-sync"
install -m 600 "${OMP_MINI_EXTENSION_SOURCE}" "${OMP_MINI_SUPPORT_DIR}/omp-mini-auto-sync.js"
ln -sfn "${OMP_MINI_STOCK}" "${OMP_MINI_SUPPORT_DIR}/stock-path/omp"
install -m 755 "${OMP_MINI_LAUNCHER_SOURCE}" "${OMP_MINI_LAUNCHER}"

print "Automatic OMP Mini Chat sync installed."
print "  omp          sync-enabled OMP"
print "  omp --stock  official OMP fallback"
