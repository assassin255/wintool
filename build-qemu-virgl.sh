#!/usr/bin/env bash
set -euo pipefail

QEMU_VERSION="${QEMU_VERSION:-v10.2.1}"
PREFIX="${PREFIX:-/opt/qemu-virgl}"
SRC="${SRC:-/tmp/qemu-virgl-src}"
BUILD="${BUILD:-/tmp/qemu-virgl-build}"
TARGET_LIST="${TARGET_LIST:-x86_64-softmmu}"
JOBS="${JOBS:-$(nproc)}"
CC="${CC:-cc}"
CXX="${CXX:-c++}"
LD="${LD:-ld}"
CFLAGS="${CFLAGS:--O3 -pipe -fomit-frame-pointer}"
CXXFLAGS="${CXXFLAGS:-$CFLAGS}"
LDFLAGS="${LDFLAGS:--Wl,--gc-sections -Wl,-O2}"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root" >&2
    exit 1
  fi
}

install_deps() {
  apt-get update
  apt-get install -y \
    build-essential git ninja-build meson pkg-config \
    python3 python3-pip python3-venv wget curl xauth xvfb \
    libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev \
    libvirglrenderer-dev libepoxy-dev libegl1-mesa-dev libgles2-mesa-dev \
    libgtk-3-dev libsdl2-dev libgbm-dev libdrm-dev
}

install_display_backend() {
  if command -v xvfb-run >/dev/null 2>&1 && command -v xauth >/dev/null 2>&1; then
    return 0
  fi

  apt-get update
  apt-get install -y \
    xvfb xauth dbus-x11 x11-xserver-utils \
    libgtk-3-0 libepoxy0 libgl1-mesa-dri libglx-mesa0 \
    libx11-6 libxext6 libxrender1 libxrandr2 libxcursor1 libxi6 \
    libxkbcommon0 libwayland-client0 libwayland-cursor0 libwayland-egl1
}

configure_qemu() {
  rm -rf "$SRC" "$BUILD"
  git clone --depth 1 --branch "$QEMU_VERSION" https://gitlab.com/qemu-project/qemu.git "$SRC"
  mkdir -p "$BUILD"
  cd "$BUILD"

  "$SRC/configure" \
    --prefix="$PREFIX" \
    --target-list="$TARGET_LIST" \
    --enable-tcg \
    --enable-slirp \
    --enable-virglrenderer \
    --enable-opengl \
    --enable-gtk \
    --enable-sdl \
    --enable-coroutine-pool \
    --disable-docs \
    --disable-werror \
    --disable-xen \
    --disable-mshv \
    --disable-debug-info \
    CC="$CC" CXX="$CXX" LD="$LD" \
    CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS"

  ninja -C "$BUILD" -j"$JOBS" qemu-system-x86_64 qemu-img
  mkdir -p "$PREFIX/bin" "$PREFIX/share/qemu"
  cp "$BUILD/qemu-system-x86_64" "$PREFIX/bin/"
  cp "$BUILD/qemu-img" "$PREFIX/bin/"
  cp -r "$SRC/pc-bios"/* "$PREFIX/share/qemu/" 2>/dev/null || true
}

resolve_qemu_bin() {
  if [ -x "$PREFIX/bin/qemu-system-x86_64" ]; then
    printf '%s\n' "$PREFIX/bin/qemu-system-x86_64"
  elif command -v qemu-system-x86_64 >/dev/null 2>&1; then
    command -v qemu-system-x86_64
  else
    echo "qemu-system-x86_64 not found" >&2
    exit 1
  fi
}

check_virgl() {
  local bin have_gtk have_gl
  bin="$(resolve_qemu_bin)"
  if "$bin" -display help 2>/dev/null | grep -qx 'gtk'; then have_gtk=1; else have_gtk=0; fi
  if "$bin" -device help 2>/dev/null | grep -q 'virtio-vga-gl'; then have_gl=1; else have_gl=0; fi
  printf 'gtk=%s virtio-vga-gl=%s\n' "$have_gtk" "$have_gl"
}

launch_vm() {
  local img="${1:-win.img}"
  local smp="${2:-4}"
  local ram="${3:-4G}"
  local bin display_cmd gpu_dev
  bin="$(resolve_qemu_bin)"
  gpu_dev='-device virtio-vga'
  display_cmd=()

  if "$bin" -display help 2>/dev/null | grep -qx 'gtk'; then
    gpu_dev='-device virtio-vga-gl'
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
      display_cmd=(-display gtk,gl=on)
    else
      install_display_backend
      display_cmd=(xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe "$bin" -display gtk,gl=on)
    fi
  else
    echo "This QEMU build does not expose gtk, so VirGL launch is not available." >&2
    exit 2
  fi

  if [ "${display_cmd[0]}" = "xvfb-run" ]; then
    exec "${display_cmd[@]}" \
      -machine q35,hpet=off \
      -cpu max \
      -smp "$smp" \
      -m "$ram" \
      -accel tcg,thread=multi,tb-size=67108864 \
      -rtc base=localtime \
      -drive file="$img",if=virtio,cache=unsafe,aio=threads,format=raw \
      -netdev user,id=n0,hostfwd=tcp::3389-:3389 \
      -device virtio-net-pci,netdev=n0 \
      -device virtio-mouse-pci \
      -device virtio-keyboard-pci \
      -nodefaults \
      -no-user-config \
      -global ICH9-LPC.disable_s3=1 \
      -global ICH9-LPC.disable_s4=1 \
      -smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640" \
      "$gpu_dev"
  fi

  exec "$bin" \
    -machine q35,hpet=off \
    -cpu max \
    -smp "$smp" \
    -m "$ram" \
    -accel tcg,thread=multi,tb-size=67108864 \
    -rtc base=localtime \
    -drive file="$img",if=virtio,cache=unsafe,aio=threads,format=raw \
    -netdev user,id=n0,hostfwd=tcp::3389-:3389 \
    -device virtio-net-pci,netdev=n0 \
    -device virtio-mouse-pci \
    -device virtio-keyboard-pci \
    -nodefaults \
    -no-user-config \
    -global ICH9-LPC.disable_s3=1 \
    -global ICH9-LPC.disable_s4=1 \
    -smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640" \
    "${display_cmd[@]}" \
    "$gpu_dev"
}

usage() {
  cat <<EOF
Usage: $0 --install | --check-virgl | --launch [img] [smp] [ram]
EOF
}

main() {
  need_root
  case "${1:-}" in
    --install)
      install_deps
      install_display_backend
      configure_qemu
      check_virgl
      ;;
    --check-virgl)
      check_virgl
      ;;
    --launch)
      shift
      launch_vm "${1:-win.img}" "${2:-4}" "${3:-4G}"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
