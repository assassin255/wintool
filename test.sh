echo "🚀 Đang Tải Các Apt Cần Thiết..."
echo "⚠️ Nếu lỗi hãy thử dùng apt install sudo"

OS_ID="$(. /etc/os-release && echo "$ID")"
OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

if [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
LLVM_VER=19
else
LLVM_VER=15
fi

sudo apt update
sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools ovmf linux-perf

export PATH="/usr/lib/llvm-$LLVM_VER/bin:$PATH"
export CC="clang-$LLVM_VER"
export CXX="clang++-$LLVM_VER"
export LD="lld-$LLVM_VER"

python3 -m venv ~/qemu-env
source ~/qemu-env/bin/activate
pip install --upgrade pip tomli packaging

rm -rf /tmp/qemu-src /tmp/qemu-build
cd /tmp
git clone --depth 1 --branch v10.2.0 https://gitlab.com/qemu-project/qemu.git qemu-src
mkdir /tmp/qemu-build
cd /tmp/qemu-build

echo "⚡ Phase 1: Build với PGO Generate"

EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -ffast-math -fprofile-generate -fuse-ld=lld -fno-semantic-interposition -fno-plt -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector -funsafe-math-optimizations -ffinite-math-only -fno-math-errno -fstrict-aliasing -funroll-loops -finline-functions -finline-hint-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=2097152"

LDFLAGS="-flto=full -fprofile-generate -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"

../qemu-src/configure \
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
--disable-vnc \
--disable-plugins \
--disable-docs \
--disable-werror \
CC="$CC" CXX="$CXX" LD="$LD" CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS"

ninja -j"$(nproc)"

echo "⚡ Phase 1: Tạo profile data..."
./qemu-system-x86_64 -accel tcg -version > /dev/null 2>&1 || true

echo "⚡ Phase 2: Rebuild với PGO Use"

rm -rf *

EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -ffast-math -fprofile-use -fprofile-correction -fuse-ld=lld -fno-semantic-interposition -fno-plt -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector -funsafe-math-optimizations -ffinite-math-only -fno-math-errno -fstrict-aliasing -funroll-loops -finline-functions -finline-hint-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=2097152"

LDFLAGS="-flto=full -fprofile-use -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"

../qemu-src/configure \
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
--disable-vnc \
--disable-plugins \
--disable-docs \
--disable-werror \
CC="$CC" CXX="$CXX" LD="$LD" CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS"

ninja -j"$(nproc)"
sudo ninja install

echo "⚡ Phase 3: BOLT Optimization"

QEMU_BIN="/opt/qemu-optimized/bin/qemu-system-x86_64"

sudo perf record -F 999 -e cycles:u -o perf.data -- $QEMU_BIN -accel tcg -version

sudo llvm-bolt $QEMU_BIN \
-o ${QEMU_BIN}.bolt \
-data=perf.data \
-reorder-blocks=ext-tsp \
-reorder-functions=hfsort+ \
-split-functions \
-split-all-cold \
-inline-all \
-dyno-stats

sudo mv ${QEMU_BIN}.bolt $QEMU_BIN

export PATH="/opt/qemu-optimized/bin:$PATH"
qemu-system-x86_64 --version

echo "🔥 QEMU ULTRA PGO + BOLT đã build xong"
