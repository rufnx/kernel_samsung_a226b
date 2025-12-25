#!/usr/bin/env bash

set -euo pipefail

N="\e[0m"
R="\e[1;31m"
G="\e[1;32m"
Y="\e[1;33m"
B="\e[1;34m"

_log() {
  echo -e "${2}${1}${N} ${3}"
}

info() { _log "[•]" "$B" "$1"; }
ok()   { _log "[√]" "$G" "$1"; }
warn() { _log "[!]" "$Y" "$1"; }
err()  { _log "[x]" "$R" "$1"; exit 1; }

fetch() {
  curl -LSs https://raw.githubusercontent.com/rufnx/personal_patch/master/clone.sh \
    | bash -s "$1" "$2"
}

toolchains() {
  if [[ ! -d clang || ! -d gcc ]]; then
    info "Fetching toolchains"
    fetch clang-12 clang
    fetch androidcc-4.9 gcc
  else
    ok "Toolchains already exist"
  fi
}

setup_env() {

  export PATH="$PWD/clang/bin:$PWD/gcc/bin:$PATH"
  export USE_CCACHE=1
  export KCFLAGS="-w"
  export KBUILD_BUILD_HOST="$(hostname)"
  export KBUILD_BUILD_USER="$(whoami)"
}

compile() {
  toolchains
  setup_env

  local cfg_dir="arch/arm64/configs"
  local defconfig

  if [[ -f "$cfg_dir/a22x_defconfig" ]]; then
    defconfig="a22x_defconfig"
  elif [[ -f "$cfg_dir/vendor/a22x_defconfig" ]]; then
    defconfig="vendor/a22x_defconfig"
  else
    err "Defconfig not found"
  fi

  info "Generating defconfig: $defconfig"
  make ARCH=arm64 O=out "$defconfig"

  info "Building kernel"
  make -j"$(nproc)" \
    O=out \
    ARCH=arm64 \
    LLVM=1 \
    LLVM_IAS=1 \
    CROSS_COMPILE=aarch64-linux-android- \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CONFIG_SECTION_MISMATCH_WARN_ONLY=y
}

build() {
  info "Start build"
  compile 2>&1 | tee build.log

  local obj="out/arch/arm64/boot"
  local output

  if [[ -f "$obj/Image.gz" ]]; then
    output="$obj/Image.gz"
  elif [[ -f "$obj/Image" ]]; then
    output="$obj/Image"
  else
    grep -i error build.log || true
    err "Kernel output not found"
  fi

  mkdir -p result
  cp "$output" result/

  ok "Kernel build success → result/$(basename "$output")"
}

build "$@"
