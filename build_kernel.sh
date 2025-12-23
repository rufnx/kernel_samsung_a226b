#!/usr/bin/env bash

set -e

NC="\e[0m"
RED="\e[1;31m"
GREEN="\e[1;32m"
YELLOW="\e[1;33m"
BLUE="\e[1;34m"
CYAN="\e[1;36m"

_log() {
  local level=$1 color=$2 msg=$3
  echo -e "${color}[${level}]${NC} ${msg}"
}

log_info()  { _log "INFO"  "$BLUE" "$1"; }
log_ok()    { _log "OK"    "$GREEN" "$1"; }
log_warn()  { _log "WARN"  "$YELLOW" "$1"; }
log_err()   { _log "ERR"   "$RED" "$1"; }

send_notif() {
  local text=$1
  if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    log_warn "Telegram credentials not set, skipping notification"
    return 0
  fi
  
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d parse_mode="Markdown" \
    --data-urlencode text="${text}" >/dev/null || log_warn "Failed to send notification"
}

send_file() {
  local file=$1
  local caption=$2
  
  if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
    log_warn "Telegram credentials not set, skipping file upload"
    return 0
  fi
  
  if [[ ! -f "$file" ]]; then
    log_err "File not found: $file"
    return 1
  fi
  
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendDocument" \
    -F chat_id="${CHAT_ID}" \
    -F parse_mode="Markdown" \
    -F document=@"${file}" \
    -F caption="${caption}" >/dev/null || log_warn "Failed to send file"
}

upload_gofile() {
  local file=$1
  
  if [[ ! -f "$file" ]]; then
    log_err "File not found: $file"
    return 1
  fi
  
  log_info "Uploading to GoFile..."
  local response
  response=$(curl -s -F "file=@${file}" https://store1.gofile.io/contents/uploadfile 2>/dev/null || \
             curl -s -F "file=@${file}" https://store2.gofile.io/contents/uploadfile 2>/dev/null)
  
  local link
  link=$(echo "$response" | grep -oP '"downloadPage":"\K[^"]+')
  
  if [[ -z "$link" ]]; then
    log_err "Failed to upload to GoFile"
    return 1
  fi
  
  echo "$link"
}

setup_clang() {
  local clang_dir
  clang_dir=$(pwd)/../clang
  
  if [[ ! -d "$clang_dir" ]]; then
    log_warn "Clang not found, downloading..."
    mkdir -p "$clang_dir"
    
    local clang_url="https://github.com/Impqxr/aosp_clang_ci/releases/download/13289611/clang-13289611-linux-x86.tar.xz"
    
    if ! wget -q --show-progress "$clang_url" -O clang.tar.xz; then
      log_err "Failed to download clang"
      exit 1
    fi
    
    log_info "Extracting clang..."
    tar -xf clang.tar.xz -C "$clang_dir"
    mv "$clang_dir"/clang-*/* "$clang_dir" 2>/dev/null || true
    rm -rf clang.tar.xz "$clang_dir"/clang-*
    log_ok "Clang setup complete"
  else
    log_ok "Clang found at $clang_dir"
  fi
  
  echo "$clang_dir"
}

compile_kernel() {
  local clang_dir
  clang_dir=$(setup_clang)
  
  # Export build environment
  export PATH="$clang_dir/bin:$PATH"
  export KCFLAGS=-w
  export USE_CCACHE=1
  export KBUILD_BUILD_HOST="$(whoami)"
  export KBUILD_BUILD_USER="$(hostname)"
  export CONFIG_SECTION_MISMATCH_WARN_ONLY=y
  
  # Clean previous build
  [[ -d "out" ]] && log_info "Cleaning previous build..." && rm -rf out
  
  # Generate defconfig
  log_info "Generating defconfig..."
  if ! make O=out ARCH=arm64 a22x_defconfig; then
    log_err "Failed to generate defconfig"
    exit 1
  fi
  
  # Start compilation
  log_info "Starting kernel compilation..."
  local start_time
  start_time=$(date +%s)
  
  if ! make -j"$(nproc --all)" \
    O=out \
    ARCH=arm64 \
    LLVM=1 \
    LLVM_IAS=1 \
    CC=clang \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    OBJCOPY=llvm-objcopy \
    OBJDUMP=llvm-objdump \
    STRIP=llvm-strip \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-; then
    return 1
  fi
  
  local end_time
  end_time=$(date +%s)
  local build_time=$((end_time - start_time))
  
  log_ok "Build completed in $((build_time / 60))m $((build_time % 60))s"
}

package_kernel() {
  local kernel_image="out/arch/arm64/boot/Image"
  local dtb="out/arch/arm64/boot/dts/mediatek/mt6769.dtb"
  local dtbo="out/arch/arm64/boot/dtbo.img"
  
  # Clone AnyKernel3
  log_info "Cloning AnyKernel3..."
  rm -rf ak3
  if ! git clone --depth=1 -q -b a22x https://github.com/AxelinnXD/AnyKernel3.git ak3; then
    log_err "Failed to clone AnyKernel3"
    return 1
  fi
  
  # Copy kernel files
  log_info "Copying kernel files..."
  cp "$kernel_image" ak3/
  [[ -f "$dtb" ]] && cp "$dtb" ak3/ && log_info "DTB copied"
  [[ -f "$dtbo" ]] && cp "$dtbo" ak3/ && log_info "DTBO copied"
  
  # Create flashable zip
  local zip_name="A22-KERNEL-$(date +%Y%m%d-%H%M).zip"
  log_info "Creating flashable zip: $zip_name"
  
  cd ak3
  if ! zip -r9 -q "../$zip_name" * -x .git\* -x README.md; then
    log_err "Failed to create zip"
    return 1
  fi
  cd ..
  
  echo "$zip_name"
}

run_build() {
  local build_start
  build_start=$(date +%s)
  
  # Send start notification
send_notif "*Kernel Build Started*
*Device:* Samsung A22
*Host:* $(hostname)
*Compiler:* LLVM/Clang"
  
  # Compile kernel
  if ! compile_kernel 2>&1 | tee build.log; then
    log_err "Compilation failed!"
    send_file "build.log" "Build Failed*
    Check the log for details"
    exit 1
  fi

  # Check kernel image
  local kernel_image="out/arch/arm64/boot/Image"
  if [[ ! -f "$kernel_image" ]]; then
    log_err "Kernel image not found after build!"
    send_file "build.log" "Build Failed*
    Kernel image not generated"
    exit 1
  fi

  log_ok "Kernel image generated successfully"

  # Package kernel
  local zip_file
  if ! zip_file=$(package_kernel); then
    log_err "Failed to package kernel"
    exit 1
  fi

  log_ok "Kernel packaged: $zip_file"

  # Upload to GoFile
  local download_link
  if download_link=$(upload_gofile "$zip_file"); then
    log_ok "Upload successful!"
    log_info "Download link: $download_link"
  else
    log_warn "Upload failed, zip file available locally: $zip_file"
    download_link="Local file: $zip_file"
  fi

  # Calculate total build time
  local build_end
  build_end=$(date +%s)
  local total_time=$((build_end - build_start))

  # Get clang version
  local clang_ver
  clang_ver=$(clang --version | head -n1 | cut -d' ' -f4)

  # Send success notification
  send_notif "Kernel Build Successful*

*File:* ${zip_file}
*Download:* ${download_link}
*Clang:* ${clang_ver}
*Build Time:* $((total_time / 60))m $((total_time % 60))s
*Host:* $(hostname)"

  echo "Download: $download_link"
}

run_build
