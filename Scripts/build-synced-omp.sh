#!/bin/zsh
set -euo pipefail

OMP_MINI_SCRIPT_DIR=${0:A:h}
OMP_MINI_PROJECT_DIR=${OMP_MINI_SCRIPT_DIR:h}
OMP_MINI_VERSION=18.1.4
OMP_MINI_BUN_VERSION=1.3.14
OMP_MINI_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omp-mini-sync.XXXXXX")
trap 'rm -rf "${OMP_MINI_TEMP_DIR}"' EXIT

case "$(uname -m)" in
  arm64)
    OMP_MINI_ARCH=arm64
    OMP_MINI_BUN_ARCH=aarch64
    ;;
  x86_64)
    OMP_MINI_ARCH=x64
    OMP_MINI_BUN_ARCH=x64
    ;;
  *)
    print -u2 "Unsupported Mac architecture: $(uname -m)"
    exit 1
    ;;
esac

OMP_MINI_BUN_ROOT=${OMP_MINI_TEMP_DIR}/bun
OMP_MINI_SOURCE_ROOT=${OMP_MINI_TEMP_DIR}/oh-my-pi
mkdir -p "${OMP_MINI_BUN_ROOT}"

print "Downloading Bun ${OMP_MINI_BUN_VERSION}…"
curl --fail --location --silent --show-error \
  "https://github.com/oven-sh/bun/releases/download/bun-v${OMP_MINI_BUN_VERSION}/bun-darwin-${OMP_MINI_BUN_ARCH}.zip" \
  --output "${OMP_MINI_TEMP_DIR}/bun.zip"
ditto -x -k "${OMP_MINI_TEMP_DIR}/bun.zip" "${OMP_MINI_BUN_ROOT}"
OMP_MINI_BUN_BIN=${OMP_MINI_BUN_ROOT}/bun-darwin-${OMP_MINI_BUN_ARCH}/bun

print "Checking out OMP ${OMP_MINI_VERSION}…"
git clone --depth 1 --branch "v${OMP_MINI_VERSION}" \
  https://github.com/can1357/oh-my-pi.git "${OMP_MINI_SOURCE_ROOT}"
git -C "${OMP_MINI_SOURCE_ROOT}" apply "${OMP_MINI_PROJECT_DIR}/Integration/omp-collab-extension-api.patch"

print "Installing pinned OMP dependencies…"
env PATH="${OMP_MINI_BUN_BIN:h}:${PATH}" \
  "${OMP_MINI_BUN_BIN}" --cwd="${OMP_MINI_SOURCE_ROOT}" install --frozen-lockfile

print "Fetching the official OMP native addon…"
curl --fail --location --silent --show-error \
  "https://registry.npmjs.org/@oh-my-pi/pi-natives-darwin-${OMP_MINI_ARCH}/-/pi-natives-darwin-${OMP_MINI_ARCH}-${OMP_MINI_VERSION}.tgz" \
  --output "${OMP_MINI_TEMP_DIR}/pi-natives.tgz"
tar -xzf "${OMP_MINI_TEMP_DIR}/pi-natives.tgz" \
  --strip-components=1 \
  -C "${OMP_MINI_SOURCE_ROOT}/packages/natives/native" \
  'package/*.node'

print "Building sync-enabled OMP ${OMP_MINI_VERSION}…"
env PATH="${OMP_MINI_BUN_BIN:h}:${PATH}" \
  "${OMP_MINI_BUN_BIN}" --cwd="${OMP_MINI_SOURCE_ROOT}/packages/coding-agent" run build

install -m 755 \
  "${OMP_MINI_SOURCE_ROOT}/packages/coding-agent/dist/omp" \
  "${OMP_MINI_PROJECT_DIR}/Vendor/omp-sync"
print -r -- "${OMP_MINI_VERSION}-darwin-${OMP_MINI_ARCH}" > "${OMP_MINI_PROJECT_DIR}/Vendor/omp-sync.version"
print "Built: ${OMP_MINI_PROJECT_DIR}/Vendor/omp-sync"
