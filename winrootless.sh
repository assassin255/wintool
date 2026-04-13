#!/usr/bin/env bash

silent() {
"$@" > /dev/null 2>&1
}

ask() {
read -rp "$1" ans
ans="${ans,,}"
[[ -z "$ans" ]] && echo "$2" || echo "$ans"
}

BASE=$HOME/qemu-stack
PREFIX=$BASE/install
BUILD=$BASE/build

mkdir -p "$PREFIX" "$BUILD"
cd "$BUILD"

export PATH=$HOME/.local/bin:$PREFIX/bin:$PATH
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
export LD_LIBRARY_PATH=$PREFIX/lib

command -v meson >/dev/null 2>&1 || pip3 install --user meson ninja

# =========================
# BUILD DEPS (NO ROOT)
# =========================

echo "=== zlib ==="
wget -q https://zlib.net/fossils/zlib-1.3.tar.gz
tar xf zlib-1.3.tar.gz
cd zlib-1.3
./configure --prefix=$PREFIX --static
make -j$(nproc)
make install
cd ..

echo "=== pixman ==="
wget -q https://cairographics.org/releases/pixman-0.43.4.tar.gz
tar xf pixman-0.43.4.tar.gz
cd pixman-0.43.4
meson setup build --prefix=$PREFIX --default-library=static -Dtests=false
ninja -C build
ninja -C build install
cd ..

echo "=== glib ==="
wget -q https://download.gnome.org/sources/glib/2.80/glib-2.80.0.tar.xz
tar xf glib-2.80.0.tar.xz
cd glib-2.80.0
meson setup build --prefix=$PREFIX --default-library=static -Dtests=false
ninja -C build
ninja -C build install
cd ..

# =========================
# QEMU BUILD (CONFIG GIỮ NGUYÊN)
# =========================

echo "=== QEMU ==="
wget -q https://download.qemu.org/qemu-11.0.0-rc3.tar.xz
tar xf qemu-11.0.0-rc3.tar.xz
cd qemu-11.0.0-rc3

./configure \
--prefix=$PREFIX \
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
--disable-vnc \
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
CC="clang" CXX="clang++" LD="lld" \
CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -ffast-math -fuse-ld=lld -fno-rtti -fno-exceptions -fmerge-all-constants -fno-semantic-interposition -fno-plt -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector -funsafe-math-optimizations -ffinite-math-only -fno-math-errno -fstrict-aliasing -funroll-loops -finline-functions -finline-hint-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=3097152" \
LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"

make -j$(nproc)
make install

QEMU_BIN="$PREFIX/bin/qemu-system-x86_64"

echo "=== QEMU READY ==="

# =========================
# WINDOWS IMAGE
# =========================

IMG=$HOME/win.img

echo ""
echo "🪟 WINDOWS SELECT"
echo "1 Server 2012"
echo "2 Server 2022"
echo "3 Windows 11"
read -rp "Choice: " win_choice

case "$win_choice" in
1) WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img" ;;
2) WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img" ;;
3) WIN_URL="https://archive.org/download/win_20260203/win.img" ;;
*) WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img" ;;
esac

[[ ! -f "$IMG" ]] && wget -q -O "$IMG" "$WIN_URL"

read -rp "Expand GB: " gb
gb=${gb:-20}
qemu-img resize "$IMG" +${gb}G

# =========================
# CPU MODEL (GIỮ NGUYÊN M)
# =========================

cpu_host=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2)
cpu_model="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"

# =========================
# VM CONFIG
# =========================

read -rp "CPU cores: " cpu_core
cpu_core=${cpu_core:-4}

read -rp "RAM GB: " ram
ram=${ram:-4}

echo "🚀 Starting VM..."

$QEMU_BIN \
-machine q35,hpet=off \
-cpu "$cpu_model" \
-smp "$cpu_core" \
-m "${ram}G" \
-accel tcg,thread=multi,tb-size=3097152 \
-rtc base=localtime \
-drive file="$IMG",if=virtio,cache=unsafe,aio=threads,format=raw \
-netdev user,id=n0,hostfwd=tcp::3389-:3389 \
-device virtio-net-pci,netdev=n0 \
-vga virtio \
-display none \
-daemonize \
> /dev/null 2>&1

echo "🟢 VM RUNNING → RDP localhost:3389"

# =========================
# SIMPLE MANAGER
# =========================

echo ""
echo "===== VM MANAGER ====="
pgrep -f qemu-system

read -rp "Kill PID (enter skip): " pid
[[ -n "$pid" ]] && kill "$pid"
