#!/usr/bin/env bash
set -euo pipefail

N="\e[0m"
R="\e[1;31m"
G="\e[1;32m"
Y="\e[1;33m"
B="\e[1;34m"

_log() { echo -e ${2}${1}${N} ${3}; }
info() { _log "[•]" "$B" "$1"; }
ok()   { _log "[√]" "$G" "$1"; }
warn() { _log "[!]" "$Y" "$1"; }
err()  { _log "[x]" "$R" "$1"; exit 1; }

fetch() {
  curl -LSs https://raw.githubusercontent.com/rufnx/personal_patch/master/clone.sh | bash -s $1 $2
}

fetch_anykernel() {
  curl -LSs https://raw.githubusercontent.com/rufnx/personal_patch/master/ak3.sh | bash -s $1 $2
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
  export PATH=$(pwd)/clang/bin:$(pwd)/gcc/bin:$PATH
  export USE_CCACHE=1
  export KCFLAGS=-w
  export KBUILD_BUILD_HOST=$(hostname)
  export KBUILD_BUILD_USER=$(whoami)
}

compile() {
  toolchains
  setup_env

  local DF_DIR=arch/arm64/configs
  local DEFCONFIG

  if [[ -f $DF_DIR/a22x_defconfig ]]; then
    DEFCONFIG=a22x_defconfig
  elif [[ -f $DF_DIR/vendor/a22x_defconfig ]]; then
    DEFCONFIG=vendor/a22x_defconfig
  else
    err "Defconfig not found"
  fi

  info "Generating defconfig: $DEFCONFIG"
  make ARCH=arm64 O=out $DEFCONFIG

  info "Building kernel"
  make -j$(nproc) \
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

  local OBJ=out/arch/arm64/boot
  local BRANCH=a22x
  local ZIPNAME=AnyKernel3-A226.zip
  local OUTPUT VERSION

  if [[ -f $OBJ/Image.gz ]]; then
    OUTPUT=$OBJ/Image.gz
    VERSION=$(zcat $OUTPUT | strings | grep "Linux version" || true)
  elif [[ -f $OBJ/Image ]]; then
    OUTPUT=$OBJ/Image
    VERSION=$(strings $OUTPUT | grep "Linux version" || true)
  else
    grep -i error build.log || true
    err "Kernel output not found"
  fi

  mkdir -p result
  cp $OUTPUT result/
  cd result

  ok "Kernel build success"

  [[ -f $ZIPNAME ]] && rm -f $ZIPNAME

  if [[ ! -d ak ]]; then
    fetch_anykernel $BRANCH ak
  else 
    rm -rf ak/Image ak/Image.gz
  fi

  cp $OUTPUT ak/
  cd ak
  zip -r9 ../$ZIPNAME *
  cd ..

  ok "Build finish: $ZIPNAME"
  [[ -n $VERSION ]] && ok "Version: $VERSION"
}

build $@
