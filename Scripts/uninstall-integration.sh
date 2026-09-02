#!/bin/zsh
set -euo pipefail

OMP_MINI_BIN_DIR=${HOME}/.local/bin
OMP_MINI_LAUNCHER=${OMP_MINI_BIN_DIR}/omp
OMP_MINI_STOCK=${OMP_MINI_BIN_DIR}/omp-stock

if [[ ! -f "${OMP_MINI_LAUNCHER}" ]] || ! grep -q "OMP Mini Chat launcher" "${OMP_MINI_LAUNCHER}"; then
  print -u2 "The active omp command is not managed by OMP Mini Chat; nothing was changed."
  exit 1
fi
if [[ ! -x "${OMP_MINI_STOCK}" ]]; then
  print -u2 "The official OMP fallback is missing; refusing to replace the active command."
  exit 1
fi

install -m 755 "${OMP_MINI_STOCK}" "${OMP_MINI_LAUNCHER}"
print "Official OMP restored at ${OMP_MINI_LAUNCHER}."
