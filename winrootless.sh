#!/usr/bin/env bash

# Thiết lập các thư mục build
BASE=$HOME/qemu-stack
PREFIX=$BASE/install
BUILD=$BASE/build

mkdir -p "$PREFIX" "$BUILD"
cd "$BUILD"

# Xuất biến môi trường (Bổ sung đường dẫn x86_64-linux-gnu để fix lỗi glib không tìm thấy)
export PATH=$HOME/.local/bin:$PREFIX/bin:$PATH
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig
export LD_LIBRARY_PATH=$PREFIX/lib:$PREFIX/lib64:$PREFIX/lib/x86_64-linux-gnu
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -L$PREFIX/lib/x86_64-linux-gnu"

# Cài đặt meson nếu chưa có
command -v meson >/dev/null 2>&1 || pip3 install --user meson ninja

echo "=== 1. Building zlib ==="
wget -q -c https://zlib.net/fossils/zlib-1.3.1.tar.gz
tar xf zlib-1.3.1.tar.gz
cd zlib-1.3.1
./configure --prefix=$PREFIX --static
make -j$(nproc) install
cd ..

echo "=== 2. Building pixman ==="
wget -q -c https://cairographics.org/releases/pixman-0.43.4.tar.gz
tar xf pixman-0.43.4.tar.gz
cd pixman-0.43.4
rm -rf build
meson setup build --prefix=$PREFIX --default-library=static -Dtests=disabled -Dlibpng=disabled
ninja -C build install
cd ..

echo "=== 3. Building libffi (Cần cho GLib) ==="
wget -q -c https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz
tar xf libffi-3.4.6.tar.gz
cd libffi-3.4.6
./configure --prefix=$PREFIX --enable-static --disable-shared --with-pic
make -j$(nproc) install
cd ..

echo "=== 4. Building pcre2 (Cần cho GLib) ==="
wget -q -c https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz
tar xf pcre2-10.44.tar.gz
cd pcre2-10.44
./configure --prefix=$PREFIX --enable-static --disable-shared --with-pic
make -j$(nproc) install
cd ..

echo "=== 5. Building glib ==="
wget -q -c https://download.gnome.org/sources/glib/2.80/glib-2.80.0.tar.xz
tar xf glib-2.80.0.tar.xz
cd glib-2.80.0
rm -rf build
# Lưu ý: GLib yêu cầu kiểu boolean cho tests
meson setup build --prefix=$PREFIX --default-library=static -Dtests=false -Dselinux=disabled -Dlibmount=disabled -Dsysprof=disabled
ninja -C build install
cd ..

echo "=== 6. Building QEMU 11.0.0-rc3 ==="
wget -q -c https://download.qemu.org/qemu-11.0.0-rc3.tar.xz
tar xf qemu-11.0.0-rc3.tar.xz
cd qemu-11.0.0-rc3

# Configure với các flag tối ưu của bạn và fix lỗi tìm GLib
./configure \
--prefix=$PREFIX \
--static \
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
--extra-cflags="-I$PREFIX/include -Ofast -march=native -mtune=native -pipe -ffast-math -fno-rtti -fno-exceptions -fmerge-all-constants -fno-semantic-interposition -fno-plt -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector -funsafe-math-optimizations -ffinite-math-only -fno-math-errno -fstrict-aliasing -funroll-loops -finline-functions -finline-hint-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=3097152" \
--extra-ldflags="-L$PREFIX/lib -L$PREFIX/lib64 -L$PREFIX/lib/x86_64-linux-gnu"

make -j$(nproc)
make install

QEMU_BIN="$PREFIX/bin/qemu-system-x86_64"
echo "=== QEMU READY ==="

# =========================
# PHẦN QUẢN LÝ VM GIỮ NGUYÊN THEO LOGIC CỦA BẠN
# =========================
IMG=$HOME/win.img
echo ""
echo "🪟 WINDOWS SELECT"
echo "1 Server 2012 | 2 Server 2022 | 3 Windows 11"
read -rp "Choice: " win_choice

case "$win_choice" in
    1) WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img" ;;
    2) WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img" ;;
    3) WIN_URL="https://archive.org/download/win_20260203/win.img" ;;
    *) WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img" ;;
esac

[[ ! -f "$IMG" ]] && echo "Downloading image..." && wget -q -O "$IMG" "$WIN_URL"

read -rp "Expand GB (mặc định 20): " gb
gb=${gb:-20}
$PREFIX/bin/qemu-img resize "$IMG" +${gb}G

cpu_host=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2)
cpu_model="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"

read -rp "CPU cores (mặc định 4): " cpu_core
cpu_core=${cpu_core:-4}
read -rp "RAM GB (mặc định 4): " ram
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
-daemonize

echo "🟢 VM RUNNING → RDP localhost:3389"
echo ""
echo "===== VM MANAGER ====="
pgrep -f qemu-system
read -rp "Kill PID (enter skip): " pid
[[ -n "$pid" ]] && kill "$pid"
