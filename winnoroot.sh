#!/usr/bin/env bash

PREFIX=$HOME/qemu-static
BUILD=$HOME/qemu-build
PATH=$HOME/.local/bin:$PREFIX/bin:$PATH
PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig

mkdir -p $PREFIX $BUILD
cd $BUILD

echo "=== install meson ninja (no venv) ==="
pip3 install --user meson ninja packaging tomli

echo "=== build zlib ==="
wget -c -qO- https://zlib.net/fossils/zlib-1.3.1.tar.gz | tar xz
cd zlib-1.3.1
./configure --prefix=$PREFIX --static
make -j$(nproc)
make install
cd ..

echo "=== build pixman ==="
wget -c -qO- https://cairographics.org/releases/pixman-0.43.4.tar.gz | tar xz
cd pixman-0.43.4
meson setup build \
 --prefix=$PREFIX \
 --default-library=static \
 -Dtests=disabled \
 -Dlibpng=disabled
ninja -C build
ninja -C build install
cd ..

echo "=== build libffi ==="
wget -c -qO- https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz | tar xz
cd libffi-3.4.6
./configure \
 --prefix=$PREFIX \
 --enable-static \
 --disable-shared \
 --with-pic
make -j$(nproc)
make install
cd ..

echo "=== build pcre2 ==="
wget -c -qO- https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz | tar xz
cd pcre2-10.44
./configure \
 --prefix=$PREFIX \
 --enable-static \
 --disable-shared \
 --with-pic
make -j$(nproc)
make install
cd ..

echo "=== build glib (fix ensurepip issue) ==="
wget -c -qO- https://download.gnome.org/sources/glib/2.80/glib-2.80.0.tar.xz | tar xJ
cd glib-2.80.0

meson setup build \
 --prefix=$PREFIX \
 --default-library=static \
 -Dtests=false \
 -Dselinux=disabled \
 -Dlibmount=disabled \
 -Dsysprof=disabled \
 -Dintrospection=disabled

ninja -C build
ninja -C build install
cd ..

echo "=== build QEMU ==="
wget -c -qO- https://download.qemu.org/qemu-11.0.0-rc3.tar.xz | tar xJ
cd qemu-11.0.0-rc3

./configure \
 --prefix=$PREFIX \
 --static \
 --target-list=x86_64-softmmu \
 --enable-tcg \
 --disable-kvm \
 --disable-werror \
 --disable-gtk \
 --disable-sdl \
 --disable-vnc \
 --disable-opengl \
 --disable-slirp \
 --disable-libusb \
 --disable-capstone \
 --disable-tools \
 --disable-docs \
 --extra-cflags="-I$PREFIX/include" \
 --extra-ldflags="-L$PREFIX/lib -L$PREFIX/lib/x86_64-linux-gnu"

make -j$(nproc)
make install

QEMU_BIN="$PREFIX/bin/qemu-system-x86_64"

echo ""
echo "=== QEMU READY ==="
echo "$QEMU_BIN"

##################################################
# INSTALL ARIA2 STATIC (NO ROOT)
##################################################

echo "=== install aria2 static ==="

cd $PREFIX/bin

wget -q \
https://github.com/q3aql/aria2-static-builds/releases/download/v1.37.0/aria2-1.37.0-linux-gnu-64bit-build1.tar.bz2

tar xf aria2-1.37.0-linux-gnu-64bit-build1.tar.bz2

cp aria2-*/aria2c .
chmod +x aria2c

cd ~

echo "=== aria2 installed ==="

##################################################
# WINDOWS DEPLOY
##################################################

IMG=$HOME/win.img

echo ""
echo "🪟 WINDOWS SELECT"
echo "1 Server 2012"
echo "2 Server 2022"
echo "3 Windows 11"

read -rp "Choice: " win_choice

case "$win_choice" in
1)
WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"
;;
2)
WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img"
;;
3)
WIN_URL="https://archive.org/download/win_20260203/win.img"
;;
*)
WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"
;;
esac

if [[ ! -f "$IMG" ]]; then
echo "=== downloading Windows image ==="

aria2c \
 -x16 \
 -s16 \
 -k1M \
 -o win.img \
 "$WIN_URL"

fi

echo "=== resize disk ==="

read -rp "Expand GB (default 20): " gb
gb=${gb:-20}

$PREFIX/bin/qemu-img resize "$IMG" +${gb}G

##################################################
# CPU MODEL (giữ nguyên bản của m)
##################################################

cpu_host=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2)

cpu_model="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"

read -rp "CPU cores (default 4): " cpu_core
cpu_core=${cpu_core:-4}

read -rp "RAM GB (default 4): " ram
ram=${ram:-4}

echo "🚀 starting VM..."

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

echo ""
echo "🟢 VM RUNNING"
echo "RDP → localhost:3389"

##################################################
# VM MANAGER
##################################################

echo ""
echo "===== VM MANAGER ====="

pgrep -f qemu-system

read -rp "Enter PID to kill VM (Enter skip): " pid

if [[ -n "$pid" ]]; then
kill "$pid"
echo "VM stopped."
fi
