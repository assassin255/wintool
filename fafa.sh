#!/usr/bin/env bash
set -e
#1
silent() {
"$@" > /dev/null 2>&1
}

ask() {
read -rp "$1" ans
ans="${ans,,}"
if [[ -z "$ans" ]]; then
echo "$2"
else
echo "$ans"
fi
}

choice=$(ask "👉 Bạn có muốn build QEMU để tạo VM với tăng tốc LLVM không ? (y/n): " "n")

if [[ "$choice" == "y" ]]; then
if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
echo "⚡ QEMU ULTRA đã tồn tại — skip build"
export PATH="/opt/qemu-optimized/bin:$PATH"
else
echo "🚀 Đang Tải Các Apt Cần Thiết..."
echo "⚠️ Nếu lỗi hãy thử dùng apt install sudo"

OS_ID="$(. /etc/os-release && echo "$ID")"
OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

if [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
LLVM_VER=19
else
LLVM_VER=15
fi

silent sudo apt update
silent sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools ovmf

export PATH="/usr/lib/llvm-$LLVM_VER/bin:$PATH"
export CC="clang-$LLVM_VER"
export CXX="clang++-$LLVM_VER"
export LD="lld-$LLVM_VER"

python3 -m venv ~/qemu-env
source ~/qemu-env/bin/activate
silent pip install --upgrade pip tomli packaging

rm -rf /tmp/qemu-src /tmp/qemu-build
cd /tmp
silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src
mkdir /tmp/qemu-build
cd /tmp/qemu-build

EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -ffast-math -fuse-ld=lld -fno-rtti -fno-exceptions -fmerge-all-constants -fno-semantic-interposition -fno-plt -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector -funsafe-math-optimizations -ffinite-math-only -fno-math-errno -fstrict-aliasing -funroll-loops -finline-functions -finline-hint-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=3097152"
LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"

echo "🔁 Đang Biên Dịch..."
silent ../qemu-src/configure \
--prefix=/opt/qemu-optimized \
--target-list=x86_64-softmmu \
--enable-tcg \
--enable-slirp \
--enable-lto \
--enable-coroutine-pool \
--disable-kvm \
--disable-mshv \
--disable-xen \
--disable-gtk \
--disable-sdl \
--disable-spice \
--disable-plugins \
--disable-debug-info \
--disable-docs \
--disable-werror \
--disable-fdt \
--disable-vdi \
--disable-vvfat \
--disable-cloop \
--disable-dmg \
--disable-pa \
--disable-alsa \
--disable-oss \
--disable-jack \
--disable-gnutls \
--disable-smartcard \
--disable-libusb \
--disable-seccomp \
--disable-modules \
--enable-opengl
--enable-virglrenderer
CC="$CC" CXX="$CXX" LD="$LD" CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS"

echo "🕧 QEMU đang được build vui lòng đợi..."
echo "💣Nếu trong quá trình build bị lỗi hãy thử ulimit -n 84857"
ninja -j"$(nproc)"
sudo ninja install

export PATH="/opt/qemu-optimized/bin:$PATH"
qemu-system-x86_64 --version
echo "🔥 QEMU LLVM đã build xong"
done
