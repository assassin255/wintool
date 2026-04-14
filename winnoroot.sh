#!/usr/bin/env bash

# =========================================================
# THIẾT LẬP MÔI TRƯỜNG (Dựa trên lệnh đã chạy thành công)
# =========================================================
BASE=$HOME/qemu-stack
PREFIX=$BASE/install
BUILD=$BASE/build

mkdir -p "$PREFIX" "$BUILD"
cd "$BUILD"

# Xuất các biến môi trường quan trọng để trình biên dịch tìm thấy thư viện
export PATH=$HOME/.local/bin:$PREFIX/bin:$PATH
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig
export LD_LIBRARY_PATH=$PREFIX/lib:$PREFIX/lib64:$PREFIX/lib/x86_64-linux-gnu
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib64 -L$PREFIX/lib/x86_64-linux-gnu"

# Cài đặt công cụ build nếu thiếu
command -v meson >/dev/null 2>&1 || pip3 install --user meson ninja

# =========================================================
# BUILD DEPENDENCIES (STATIC)
# =========================================================

echo "=== 1. Building zlib ==="
wget -c -qO- https://zlib.net/fossils/zlib-1.3.1.tar.gz | tar xz
cd zlib-1.3.1
./configure --prefix=$PREFIX --static
make -j$(nproc) install
cd ..

echo "=== 2. Building pixman ==="
wget -c -qO- https://cairographics.org/releases/pixman-0.43.4.tar.gz | tar xz
cd pixman-0.43.4
rm -rf build
# Sử dụng -Dtests=disabled (string) theo log thành công trước đó
meson setup build --prefix=$PREFIX --default-library=static -Dtests=disabled -Dlibpng=disabled
ninja -C build install
cd ..

echo "=== 3. Building libffi ==="
wget -c -qO- https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz | tar xz
cd libffi-3.4.6
./configure --prefix=$PREFIX --enable-static --disable-shared --with-pic
make -j$(proc) install
cd ..

echo "=== 4. Building pcre2 ==="
wget -c -qO- https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz | tar xz
cd pcre2-10.44
./configure --prefix=$PREFIX --enable-static --disable-shared --with-pic
make -j$(nproc) install
cd ..

echo "=== 5. Building glib ==="
wget -c -qO- https://download.gnome.org/sources/glib/2.80/glib-2.80.0.tar.xz | tar xJ
cd glib-2.80.0
rm -rf build
# Sử dụng -Dtests=false (boolean) để tránh lỗi Meson check kiểu dữ liệu
meson setup build --prefix=$PREFIX --default-library=static -Dtests=false -Dselinux=disabled -Dlibmount=disabled -Dsysprof=disabled
ninja -C build install
cd ..

# =========================================================
# QEMU BUILD (Với các flag tối ưu hóa cực mạnh)
# =========================================================

echo "=== 6. Building QEMU 11.0.0-rc3 ==="
wget -c -qO- https://download.qemu.org/qemu-11.0.0-rc3.tar.xz | tar xJ
cd qemu-11.0.0-rc3

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
--disable-vnc \
--disable-opengl \
--disable-libusb \
--disable-capstone \
--disable-docs \
--disable-werror \
--extra-cflags="-I$PREFIX/include -Ofast -march=native -mtune=native -ffast-math -fno-stack-protector -funroll-loops -DNDEBUG -DDEFAULT_TCG_TB_SIZE=3097152" \
--extra-ldflags="-L$PREFIX/lib -L$PREFIX/lib64 -L$PREFIX/lib/x86_64-linux-gnu"

make -j$(nproc)
make install

QEMU_BIN="$PREFIX/bin/qemu-system-x86_64"
echo "=== QEMU READY: $QEMU_BIN ==="

# =========================================================
# QUẢN LÝ WINDOWS IMAGE & CHẠY VM
# =========================================================

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

[[ ! -f "$IMG" ]] && echo "Đang tải image..." && wget -q -O "$IMG" "$WIN_URL"

read -rp "Expand GB (mặc định 20): " gb
gb=${gb:-20}
$PREFIX/bin/qemu-img resize "$IMG" +${gb}G

# Tối ưu hóa CPU model để bypass các kiểm tra của Windows
cpu_host=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2)
cpu_model="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"

read -rp "CPU cores (mặc định 4): " cpu_core
cpu_core=${cpu_core:-4}

read -rp "RAM GB (mặc định 4): " ram
ram=${ram:-4}

echo "🚀 Đang khởi động VM..."
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

echo "🟢 VM ĐANG CHẠY → Kết nối RDP qua localhost:3389"

# =========================
# TRÌNH QUẢN LÝ ĐƠN GIẢN
# =========================
echo ""
echo "===== VM MANAGER ====="
pgrep -f qemu-system
read -rp "Nhập PID để tắt VM (Enter để bỏ qua): " pid
[[ -n "$pid" ]] && kill "$pid" && echo "Đã tắt VM."

