#!/usr/bin/env bash
set -e

N="\e[0m"
R="\e[1;31m"
G="\e[1;32m"
Y="\e[1;33m"
B="\e[1;34m"

_log() {
  local level=$1 color=$2 msg=$3
  echo -e "${color}[${level}]${N} ${msg}"
}

info() { _log "INFO" "$B" "$1"; }
ok()   { _log "OK"   "$G" "$1"; }
warn() { _log "WARN" "$Y" "$1"; }
err()  { _log "ERR"  "$R" "$1"; exit 1; }

fetch_tc() {
  curl -LSs https://raw.githubusercontent.com/rufnx/toolchains/README/clone.sh \
  | bash -s "$1" "$2"
}

prepare() {
  if [[ ! -d clang || ! -d gcc ]]; then
    info "Fetching Toolchains"
    fetch_tc clang-12 clang
    fetch_tc androidcc-4.9 gcc
  else
    info "Toolchains already exist, skip"
  fi
}

variabel() {
  export ARCH=arm64
  export PATH="$(pwd)/clang/bin:$(pwd)/gcc/bin:$PATH"
  export CROSS_COMPILE=aarch64-linux-android-
  export CLANG_TRIPLE=aarch64-linux-gnu-
  export CC=clang

  export LLVM=1
  export LLVM_IAS=1
  export USE_CCACHE=1
  export KCFLAGS=-w
  export KBUILD_BUILD_HOST=$(hostname)
  export KBUILD_BUILD_USER=$(whoami)
}

compile() {
  prepare
  variabel

  local df=arch/arm64/configs
  local defconfig

  [[ -f $df/a22x_defconfig ]] \
    && defconfig=a22x_defconfig \
    || defconfig=vendor/a22x_defconfig

  info "Generate defconfig"
  make O=out $defconfig

  info "Build kernel"
  make -j$(nproc) \
       O=out \
       CONFIG_SECTION_MISMATCH_WARN_ONLY=y
}

build() {
  compile

  local obj=out/arch/arm64/boot/Image

  [[ -f $obj ]] || err "Image not found"

  ok "Kernel build success"
  mkdir -p result
  cp $obj result/
}

build
