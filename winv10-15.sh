#!/usr/bin/env bash
set -euo pipefail

# ════════════════════════════════════════════════════════════════
#  WINDOWS VM TOOL v10
#  Fix: build/compile 1 lần | spinner loading | glib/venv/qemu
# ════════════════════════════════════════════════════════════════

# ── MÀU SẮC ────────────────────────────────────────────────────
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
B='\033[1;34m'; C='\033[1;36m'; W='\033[0m'

# ── SPINNER ─────────────────────────────────────────────────────
_SPIN_PID=""

spin_start() {
    local msg="${1:-Processing...}"
    local frames=('◜' '◝' '◞' '◟')
    (
        while :; do
            for f in "${frames[@]}"; do
                printf "\r${B}%s${W} %s" "$f" "$msg"
                sleep 0.1
            done
        done
    ) &
    _SPIN_PID=$!
    disown "$_SPIN_PID"
}

spin_stop() {
    local msg="${1:-Done}"
    if [[ -n "$_SPIN_PID" ]] && kill -0 "$_SPIN_PID" 2>/dev/null; then
        kill "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
    fi
    _SPIN_PID=""
    printf "\r${G}✔${W} %s\n" "$msg"
}

spin_fail() {
    local msg="${1:-Failed}"
    if [[ -n "$_SPIN_PID" ]] && kill -0 "$_SPIN_PID" 2>/dev/null; then
        kill "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
    fi
    _SPIN_PID=""
    printf "\r${R}✘${W} %s\n" "$msg"
}

# ── HÀM HỖ TRỢ ─────────────────────────────────────────────────
silent() { "$@" > /dev/null 2>&1; }

ask() {
    read -rp "$1" ans
    ans="${ans,,}"
    echo "${ans:-$2}"
}

ver_lt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

# ── AUTO DETECT HUGEPAGE ─────────────────────────────────────────
detect_hugepage() {
    HUGEPAGE_OPT=""
    HP_INFO="none"

    HP_1G=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo "0")
    HP_2M=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages   2>/dev/null || echo "0")
    THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "never")

    echo ""
    echo "🔎 Kiểm tra HugePages..."
    echo "   1GB hugepages : $HP_1G"
    echo "   2MB hugepages : $HP_2M"
    echo "   THP status    : $THP"

    if [ "$HP_1G" -gt 0 ]; then
        # Tự cấp thêm 1GB hugepages nếu còn ít hơn ram_size
        NEED=$(( ram_size ))
        if [ "$HP_1G" -lt "$NEED" ]; then
            echo "$NEED" | sudo tee /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages > /dev/null 2>&1 || true
            HP_1G=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo "$HP_1G")
        fi
        HUGEPAGE_OPT="-mem-prealloc -mem-path /dev/hugepages"
        HP_INFO="1GB hugepages (${HP_1G} pages = ${HP_1G}GB)"
        echo -e "${G}✅ Dùng 1GB hugepages → tối ưu nhất cho TCG${W}"

    elif [ "$HP_2M" -gt 0 ]; then
        # Tự cấp thêm 2MB hugepages = ram_size * 512 pages
        NEED=$(( ram_size * 512 ))
        if [ "$HP_2M" -lt "$NEED" ]; then
            echo "$NEED" | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages > /dev/null 2>&1 || true
            HP_2M=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo "$HP_2M")
        fi
        HUGEPAGE_OPT="-mem-prealloc -mem-path /dev/hugepages"
        HP_INFO="2MB hugepages (${HP_2M} pages = $(( HP_2M * 2 ))MB)"
        echo -e "${G}✅ Dùng 2MB hugepages${W}"

    else
        # Không có static hugepage — thử bật THP always
        if echo "always" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null 2>&1; then
            THP="always"
            echo -e "${G}✅ Đã bật THP = always${W}"
        fi

        if echo "$THP" | grep -q '\[always\]\|always'; then
            # Tối ưu thêm THP
            echo "defer+madvise" | sudo tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null 2>&1 || true
            echo "1"            | sudo tee /sys/kernel/mm/transparent_hugepage/khugepaged/defrag > /dev/null 2>&1 || true
            HUGEPAGE_OPT="-mem-prealloc"
            HP_INFO="Transparent HugePages (THP=always)"
            echo -e "${G}✅ THP=always + mem-prealloc${W}"
        else
            echo -e "${Y}⚠️  Không có hugepage — chạy bình thường${W}"
        fi
    fi
}

# ════════════════════════════════════════════════════════════════
#  PACKAGE MANAGER — root → sudo apt → rootless build từ source
# ════════════════════════════════════════════════════════════════

APT_CMD=""        # lệnh apt cuối cùng dùng được
APT_OK=0          # 1 = apt khả dụng
ROOTLESS=0        # 1 = phải build rootless

_detect_apt() {
    echo -ne "${B}◜${W} Kiểm tra quyền package manager..."

    # Tầng 1: root trực tiếp
    if [[ "$(id -u)" == "0" ]] && apt-get update -qq > /dev/null 2>&1; then
        APT_CMD="apt-get"
        APT_OK=1
        echo -e "\r${G}✔${W} Dùng apt-get (root)              "
        return
    fi

    # Tầng 2: sudo apt
    if sudo -n true 2>/dev/null && sudo apt-get update -qq > /dev/null 2>&1; then
        APT_CMD="sudo apt-get"
        APT_OK=1
        echo -e "\r${G}✔${W} Dùng sudo apt-get                "
        return
    fi

    # Tầng 3: cả 2 thất bại → rootless mode
    echo -e "\r${Y}⚠${W}  Không có apt — chuyển sang build rootless từ source"
    APT_OK=0
    ROOTLESS=1
}

# ── Cài 1 package qua apt (dùng APT_CMD đã detect) ───────────
apt_install() {
    local pkg="$1"
    $APT_CMD install -y -qq "$pkg" > /dev/null 2>&1
}

# ════════════════════════════════════════════════════════════════
#  ROOTLESS BUILD — python + deps + qemu từ source không cần root
# ════════════════════════════════════════════════════════════════
_rootless_build() {
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔧 ROOTLESS BUILD MODE${W}"
    echo -e "${C}════════════════════════════════════${W}"

    # Dọn build cũ
    rm -rf "$HOME/python-local" "$HOME/qemu-static" "$HOME/qemu-build" "$HOME/certs"

    export PY_PREFIX="$HOME/python-local"
    export PREFIX="$HOME/qemu-static"
    export BUILD="$HOME/qemu-build"
    mkdir -p "$PY_PREFIX" "$PREFIX" "$BUILD" "$HOME/certs"

    # ── SSL certs ────────────────────────────────────────────────
    spin_start "Tải SSL certs..."
    cd "$HOME/certs"
    wget -q https://curl.se/ca/cacert.pem
    export SSL_CERT_FILE="$HOME/certs/cacert.pem"
    export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
    spin_stop "SSL certs xong"

    # ── OpenSSL 3.x (bắt buộc trước Python để có ssl module) ────
    spin_start "Build OpenSSL 3.3.1..."
    cd "$BUILD"
    wget -c -qO- https://github.com/openssl/openssl/releases/download/openssl-3.3.1/openssl-3.3.1.tar.gz | tar xz
    cd openssl-3.3.1
    ./Configure --prefix="$PREFIX" --openssldir="$PREFIX/ssl" \
        no-shared no-tests linux-x86_64 \
        > /tmp/openssl-build.log 2>&1
    make -j"$(nproc)" >> /tmp/openssl-build.log 2>&1
    make install_sw >> /tmp/openssl-build.log 2>&1
    spin_stop "OpenSSL 3.3.1 xong"

    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:${LD_LIBRARY_PATH:-}"

    # ── zlib ─────────────────────────────────────────────────────
    spin_start "Build zlib 1.3.1..."
    cd "$BUILD"
    wget -c -qO- https://zlib.net/fossils/zlib-1.3.1.tar.gz | tar xz
    cd zlib-1.3.1
    CFLAGS="-fPIC" ./configure --prefix="$PREFIX" --static > /dev/null 2>&1
    make -j"$(nproc)" install > /dev/null 2>&1
    spin_stop "zlib xong"

    # ── Python 3.12 ──────────────────────────────────────────────
    spin_start "Tải Python 3.12.2 source..."
    cd "$HOME"
    wget -c -q https://www.python.org/ftp/python/3.12.2/Python-3.12.2.tar.xz
    tar xf Python-3.12.2.tar.xz
    spin_stop "Tải Python xong"

    spin_start "Build Python 3.12.2 (mất 5-10 phút)..."
    cd "$HOME/Python-3.12.2"
    CPPFLAGS="-I$PREFIX/include -I$PREFIX/include/openssl" \
    LDFLAGS="-L$PREFIX/lib64 -L$PREFIX/lib -Wl,-rpath,$PREFIX/lib" \
    ./configure \
        --prefix="$PY_PREFIX" \
        --with-ensurepip=install \
        --with-openssl="$PREFIX" \
        --with-openssl-rpath=auto \
        > /tmp/python-configure.log 2>&1
    make -j"$(nproc)" > /tmp/python-build.log 2>&1
    make install >> /tmp/python-build.log 2>&1
    spin_stop "Python 3.12.2 xong"

    export PATH="$PY_PREFIX/bin:$HOME/.local/bin:$PREFIX/bin:$PATH"

    # Verify ssl module
    if "$PY_PREFIX/bin/python3" -c "import ssl; print('SSL OK:', ssl.OPENSSL_VERSION)" 2>/dev/null; then
        echo -e "${G}✔${W} Python ssl module OK"
    else
        echo -e "${R}✘${W} Python ssl module KHÔNG có — pip sẽ thất bại"
        echo "   Build log: /tmp/python-build.log"
        exit 1
    fi

    echo -ne "${B}◜${W} Cài pip packages..."
    "$PY_PREFIX/bin/python3" -m pip install -q --upgrade \
        pip setuptools wheel packaging meson ninja truststore \
        > /tmp/pip-rootless.log 2>&1
    if [[ $? -eq 0 ]]; then
        echo -e "\r${G}✔${W} pip packages xong          "
    else
        echo -e "\r${R}✘${W} pip thất bại — xem /tmp/pip-rootless.log"
        exit 1
    fi

    # ── pixman ───────────────────────────────────────────────────
    spin_start "Build pixman..."
    cd "$BUILD"
    wget -c -qO- https://cairographics.org/releases/pixman-0.43.4.tar.gz | tar xz
    cd pixman-0.43.4
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/lib64/pkgconfig"
    meson setup build --prefix="$PREFIX" --default-library=static \
        -Dtests=disabled > /dev/null 2>&1
    ninja -C build install > /dev/null 2>&1
    spin_stop "pixman xong"

    # ── libffi ───────────────────────────────────────────────────
    spin_start "Build libffi..."
    cd "$BUILD"
    wget -c -qO- https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz | tar xz
    cd libffi-3.4.6
    CFLAGS="-fPIC" ./configure --prefix="$PREFIX" \
        --enable-static --disable-shared --with-pic > /dev/null 2>&1
    make -j"$(nproc)" install > /dev/null 2>&1
    spin_stop "libffi xong"

    # ── pcre2 ────────────────────────────────────────────────────
    spin_start "Build pcre2..."
    cd "$BUILD"
    wget -c -qO- https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz | tar xz
    cd pcre2-10.44
    CFLAGS="-fPIC" ./configure --prefix="$PREFIX" \
        --enable-static --disable-shared --with-pic > /dev/null 2>&1
    make -j"$(nproc)" install > /dev/null 2>&1
    spin_stop "pcre2 xong"

    # ── glib 2.80 ────────────────────────────────────────────────
    spin_start "Build glib 2.80.0..."
    cd "$BUILD"
    wget -c -qO- https://download.gnome.org/sources/glib/2.80/glib-2.80.0.tar.xz | tar xJ
    cd glib-2.80.0
    meson setup build --prefix="$PREFIX" --default-library=static \
        -Dtests=false -Dselinux=disabled -Dlibmount=disabled \
        -Dsysprof=disabled > /dev/null 2>&1
    ninja -C build install > /dev/null 2>&1
    spin_stop "glib 2.80.0 xong"

    # ── QEMU 11.0.0-rc3 ──────────────────────────────────────────
    spin_start "Tải QEMU 11.0.0-rc3..."
    cd "$BUILD"
    wget -c -qO- https://download.qemu.org/qemu-11.0.0-rc3.tar.xz | tar xJ
    spin_stop "Tải QEMU xong"

    spin_start "Clone libslirp..."
    mkdir -p "$BUILD/qemu-11.0.0-rc3/subprojects"
    git clone -q https://gitlab.freedesktop.org/slirp/libslirp.git \
        "$BUILD/qemu-11.0.0-rc3/subprojects/libslirp"
    spin_stop "libslirp xong"

    spin_start "Configure QEMU rootless..."
    cd "$BUILD/qemu-11.0.0-rc3"
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/lib64/pkgconfig"
    ./configure \
        --prefix="$PREFIX" \
        --python="$PY_PREFIX/bin/python3" \
        --target-list=x86_64-softmmu \
        --enable-tcg \
        --disable-kvm \
        --disable-werror \
        --disable-gtk \
        --disable-sdl \
        --disable-opengl \
        --enable-slirp \
        --enable-vnc \
        --disable-libusb \
        --disable-capstone \
        --extra-cflags="-I$PREFIX/include" \
        --extra-ldflags="-L$PREFIX/lib64 -L$PREFIX/lib" \
        > /tmp/qemu-configure.log 2>&1
    spin_stop "Configure xong"

    spin_start "Compile QEMU rootless (mất 10-20 phút)..."
    if make -j"$(nproc)" > /tmp/qemu-build.log 2>&1; then
        make install > /dev/null 2>&1
        strip "$PREFIX/bin/qemu-system-x86_64" 2>/dev/null || true
        spin_stop "QEMU rootless build xong"
    else
        spin_fail "Compile QEMU thất bại — xem /tmp/qemu-build.log"
        exit 1
    fi

    export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:$PREFIX/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
    export QEMU_BIN="$PREFIX/bin/qemu-system-x86_64"
    export PATH="$PREFIX/bin:$PATH"

    # ── Thử cài aria2 từ conda ────────────────────────────────────
    if command -v conda &>/dev/null; then
        spin_start "Cài aria2 từ conda..."
        conda install -y -q aria2 > /dev/null 2>&1 \
            && spin_stop "aria2 từ conda xong" \
            || spin_fail "aria2 conda thất bại — bỏ qua, dùng wget"
    else
        echo -e "${B}ℹ${W}  conda không có — bỏ qua aria2, dùng wget để tải"
    fi

    echo -e "${G}✔ Rootless build hoàn tất${W}"
    echo -e "   QEMU : $QEMU_BIN"
    echo -e "   Python: $($PY_PREFIX/bin/python3 --version 2>&1)"
}


QEMU_BIN="/opt/qemu-optimized/bin/qemu-system-x86_64"

# Detect package manager ngay từ đầu
_detect_apt

choice=$(ask "👉 Bạn có muốn build QEMU để tạo VM với tăng tốc LLVM không? (y/n): " "n")

if [[ "$choice" == "y" ]]; then

    # ── Nếu không có apt → rootless build rồi skip phần apt ──────
    if [[ "$ROOTLESS" == "1" ]]; then
        _rootless_build
    elif [[ -x "$QEMU_BIN" ]]; then
        BUILT_VER=$("$QEMU_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU ULTRA v${BUILT_VER} đã tồn tại — bỏ qua build${W}"
        export PATH="/opt/qemu-optimized/bin:$PATH"
    else
        # ── Cài dependencies — skip package đã có, hiện progress ────
        echo ""
        spin_start "Cập nhật apt cache..."
        $APT_CMD update -qq > /dev/null 2>&1
        spin_stop "apt cache đã cập nhật"

        # Danh sách: "tên_hiển_thị|package_apt|lệnh_check"
        DEPS=(
            "lsb-release|lsb-release|lsb_release"
            "wget|wget|wget"
            "gnupg|gnupg|gpg"
            "build-essential|build-essential|gcc"
            "ninja-build|ninja-build|ninja"
            "git|git|git"
            "python3-venv|python3-venv|python3"
            "python3-pip|python3-pip|pip3"
            "pkg-config|pkg-config|pkg-config"
            "aria2|aria2|aria2c"
            "ovmf|ovmf|"
            "libglib2.0-dev|libglib2.0-dev|"
            "libpixman-1-dev|libpixman-1-dev|"
            "zlib1g-dev|zlib1g-dev|"
            "libslirp-dev|libslirp-dev|"
            "meson|meson|meson"
            "software-properties-common|software-properties-common|"
        )

        TOTAL=${#DEPS[@]}
        IDX=0
        for entry in "${DEPS[@]}"; do
            IFS='|' read -r label pkg chk <<< "$entry"
            IDX=$(( IDX + 1 ))
            PREFIX="[${IDX}/${TOTAL}]"

            # Skip nếu lệnh check đã có sẵn
            if [[ -n "$chk" ]] && command -v "$chk" &>/dev/null; then
                echo -e "${G}✔${W} ${PREFIX} ${label} ${B}(đã có)${W}"
                continue
            fi
            # Skip nếu dpkg đã cài
            if dpkg -s "$pkg" &>/dev/null 2>&1; then
                echo -e "${G}✔${W} ${PREFIX} ${label} ${B}(đã cài)${W}"
                continue
            fi

            spin_start "Đang cài $label..."
            if apt_install "$pkg"; then
                spin_stop "$PREFIX $label"
            else
                spin_fail "$PREFIX $label thất bại — bỏ qua"
            fi
        done
        echo -e "${G}✔ Tất cả dependencies đã sẵn sàng${W}"

        # ── Thiết lập LLVM ────────────────────────────────────────
        OS_ID="$(. /etc/os-release && echo "$ID")"
        OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

        if [[ "$OS_ID" == "ubuntu" ]]; then
            spin_start "Cài LLVM 21 (Ubuntu)..."
            silent wget -q https://apt.llvm.org/llvm.sh
            silent chmod +x llvm.sh
            silent sudo bash llvm.sh 21
            LLVM_VER=21
            spin_stop "LLVM 21 đã cài"
        else
            if [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then LLVM_VER=19; else LLVM_VER=15; fi
            spin_start "Cài LLVM ${LLVM_VER}..."
            silent sudo apt-get install -y \
                clang-$LLVM_VER lld-$LLVM_VER \
                llvm-$LLVM_VER llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools
            spin_stop "LLVM ${LLVM_VER} đã cài"
        fi

        export PATH="/usr/lib/llvm-$LLVM_VER/bin:$PATH"
        export CC="clang-$LLVM_VER"
        export CXX="clang++-$LLVM_VER"
        export LD="lld-$LLVM_VER"

        if command -v "lld-$LLVM_VER" &>/dev/null || command -v lld &>/dev/null; then
            LLD_AVAILABLE=1
            echo -e "${G}✔ lld tìm thấy${W}"
        else
            LLD_AVAILABLE=0
            echo -e "${Y}⚠️  lld không tìm thấy, fallback sang ld mặc định${W}"
        fi

        # ── Build glib nếu quá cũ (chỉ 1 lần) ───────────────────
        GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")
        if ver_lt "$GLIB_VER" "2.66"; then
            echo -e "${Y}⚠️  glib hiện tại: $GLIB_VER — quá cũ, build glib 2.76.6${W}"

            spin_start "Tải source glib 2.76.6..."
            silent sudo apt-get install -y libffi-dev gettext
            cd /tmp
            silent wget -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz
            spin_stop "Tải glib xong"

            spin_start "Giải nén glib..."
            silent tar -xf glib-2.76.6.tar.xz
            spin_stop "Giải nén xong"

            spin_start "Build & install glib 2.76.6 (mất vài phút)..."
            cd glib-2.76.6
            silent meson setup build --prefix=/usr/local
            silent ninja -C build
            silent sudo ninja -C build install
            spin_stop "glib 2.76.6 đã cài"

            export PKG_CONFIG_PATH="/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
            export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:${LD_LIBRARY_PATH:-}"
            GLIB_NEW=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "unknown")
            echo -e "${G}✔ glib mới: $GLIB_NEW${W}"
        else
            echo -e "${G}✔ glib đủ yêu cầu: $GLIB_VER${W}"
        fi

        # ── Python venv + meson (chỉ tạo 1 lần) ─────────────────
        # Detect đúng version Python đang dùng rồi cài python3.X-venv
        PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        echo -e "${B}ℹ${W} Python version: ${PY_VER}"

        VENV_PKG="python${PY_VER}-venv"
        if ! dpkg -s "$VENV_PKG" &>/dev/null 2>&1; then
            echo -ne "${B}◜${W} Cài ${VENV_PKG}..."
            sudo apt-get install -y -qq "$VENV_PKG" > /dev/null 2>&1
            echo -e "\r${G}✔${W} ${VENV_PKG} đã cài          "
        else
            echo -e "${G}✔${W} ${VENV_PKG} đã có"
        fi

        # Xóa venv cũ nếu bị broken
        if [[ -d ~/qemu-env ]] && [[ ! -f ~/qemu-env/bin/activate ]]; then
            echo -e "${Y}⚠${W} venv cũ bị broken — xóa và tạo lại"
            rm -rf ~/qemu-env
        fi

        if [[ ! -f ~/qemu-env/bin/activate ]]; then
            echo -ne "${B}◜${W} Tạo Python venv..."
            python3 -m venv ~/qemu-env > /tmp/venv-create.log 2>&1
            venv_exit=$?
            if [[ $venv_exit -eq 0 ]]; then
                echo -e "\r${G}✔${W} Python venv đã tạo          "
            else
                echo -e "\r${R}✘${W} Tạo venv thất bại:"
                cat /tmp/venv-create.log
                exit 1
            fi
        else
            echo -e "${G}✔${W} Python venv đã tồn tại — bỏ qua"
        fi

        source ~/qemu-env/bin/activate

        echo -ne "${B}◜${W} Cài meson / ninja trong venv..."
        {
            pip install --upgrade pip tomli packaging
            pip install meson ninja
            sudo apt-get remove -y meson 2>/dev/null || true
            hash -r
        } > /tmp/pip-install.log 2>&1
        echo -e "\r${G}✔${W} meson / ninja sẵn sàng          "

        # ── Tải QEMU source (chỉ 1 lần) ──────────────────────────
        if [[ ! -d /tmp/qemu-src ]]; then
            spin_start "Tải source QEMU v11.0.0..."
            silent git clone --depth 1 --branch v11.0.0 \
                https://gitlab.com/qemu-project/qemu.git /tmp/qemu-src
            spin_stop "Tải source QEMU xong"
        else
            echo -e "${G}✔ Source QEMU đã có tại /tmp/qemu-src — bỏ qua clone${W}"
        fi

        # ── Configure (chỉ 1 lần) ─────────────────────────────────
        rm -rf /tmp/qemu-build
        mkdir -p /tmp/qemu-build
        cd /tmp/qemu-build

        # TCG_TB_SIZE compile-time = 256MB để khớp runtime
        TCG_TB_COMPILE=$(( 256 * 1024 * 1024 ))

        EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe \
-flto=full -ffast-math -fuse-ld=lld \
-fmerge-all-constants -fno-semantic-interposition \
-fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables \
-fno-stack-protector -funsafe-math-optimizations \
-ffinite-math-only -fno-math-errno -fstrict-aliasing \
-funroll-loops -finline-functions -finline-hint-functions \
-fvectorize -fslp-vectorize \
-mllvm -inline-threshold=500 \
-mllvm -unroll-count=8 \
-mllvm -enable-gvn-hoist=1 \
-mllvm -enable-load-pre=1 \
-DNDEBUG \
-DDEFAULT_TCG_TB_SIZE=${TCG_TB_COMPILE} \
-DTCG_TARGET_REG_BITS=64 \
-DCONFIG_TCG_INTERPRETER=0"
        LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3 -Wl,--thinlto-cache-dir=/tmp/lto-cache"

        spin_start "Configure QEMU..."
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
            CC="$CC" CXX="$CXX" LD="$LD" \
            CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS" \
            > /tmp/qemu-configure.log 2>&1
        spin_stop "Configure xong"

        # ── Compile (1 lần, không lặp) ────────────────────────────
        ulimit -n 84857 2>/dev/null || true
        NCPU=$(nproc)
        spin_start "Đang compile QEMU với ${NCPU} cores (mất 5-20 phút)..."
        if ninja -j"$NCPU" > /tmp/qemu-build.log 2>&1; then
            spin_stop "Compile QEMU xong"
        else
            spin_fail "Compile QEMU thất bại — xem log: /tmp/qemu-build.log"
            exit 1
        fi

        spin_start "Cài đặt QEMU vào /opt/qemu-optimized..."
        if sudo ninja install > /dev/null 2>&1; then
            spin_stop "Cài đặt QEMU hoàn tất"
        else
            spin_fail "Cài đặt thất bại"
            exit 1
        fi

        export PATH="/opt/qemu-optimized/bin:$PATH"
        echo -e "${G}🔥 QEMU LLVM build xong! $($QEMU_BIN --version | head -1)${W}"
    fi
else
    echo -e "${Y}⚡ Bỏ qua build QEMU.${W}"
fi

# ── Đảm bảo QEMU tìm thấy ────────────────────────────────────
[[ -x "$QEMU_BIN" ]] && export PATH="/opt/qemu-optimized/bin:$PATH"

# ════════════════════════════════════════════════════════════════
#  MENU CHÍNH
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}🖥️  WINDOWS VM MANAGER  v10${W}"
echo -e "${C}════════════════════════════════════${W}"
echo "1️⃣  Tạo Windows VM"
echo "2️⃣  Quản Lý Windows VM"
echo -e "${C}════════════════════════════════════${W}"
read -rp "👉 Nhập lựa chọn [1-2]: " main_choice

case "$main_choice" in
2)
    echo ""
    echo -e "${C}🚀 ===== MANAGE RUNNING VM =====${W}"

    if pgrep -f 'qemu-system-x86_64' > /dev/null; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
            vcpu=$(sed -n 's/.*-smp \([^ ,]*\).*/\1/p' <<< "$cmd")
            ram=$(sed -n  's/.*-m \([^ ]*\).*/\1/p'    <<< "$cmd")
            cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo "?")
            mem=$(ps -p "$pid" -o %mem= 2>/dev/null || echo "?")
            echo -e "🆔 PID: ${Y}${pid}${W}  |  vCPU: ${B}${vcpu}${W}  |  RAM: ${B}${ram}${W}  |  CPU: ${G}${cpu}%${W}  |  MEM: ${R}${mem}%${W}"
        done < <(pgrep -f 'qemu-system-x86_64')
    else
        echo -e "${R}❌ Không có VM nào đang chạy${W}"
    fi

    echo -e "${C}==================================${W}"
    read -rp "🆔 Nhập PID VM muốn tắt (hoặc Enter để bỏ qua): " kill_pid
    if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
        kill "$kill_pid" 2>/dev/null || true
        echo -e "${G}✅ Đã gửi tín hiệu tắt VM PID $kill_pid${W}"
    fi
    exit 0
    ;;
esac

# ════════════════════════════════════════════════════════════════
#  CHỌN PHIÊN BẢN WINDOWS
# ════════════════════════════════════════════════════════════════
echo ""
echo "🪟 Chọn phiên bản Windows muốn tải:"
echo "1️⃣  Windows Server 2012 R2 x64"
echo "2️⃣  Windows Server 2022 x64"
echo "3️⃣  Windows 11 LTSB x64"
echo "4️⃣  Windows 10 LTSB 2015 x64"
echo "5️⃣  Windows 10 LTSC 2023 x64"
read -rp "👉 Nhập số [1-5]: " win_choice

case "$win_choice" in
1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ;;
2) WIN_NAME="Windows Server 2022";    WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img";   USE_UEFI="no"  ;;
3) WIN_NAME="Windows 11 LTSB";        WIN_URL="https://archive.org/download/win_20260203/win.img";       USE_UEFI="yes" ;;
4) WIN_NAME="Windows 10 LTSB 2015";   WIN_URL="https://archive.org/download/win_20260208/win.img";       USE_UEFI="no"  ;;
5) WIN_NAME="Windows 10 LTSC 2023";   WIN_URL="https://archive.org/download/win_20260215/win.img";       USE_UEFI="no"  ;;
*) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ;;
esac

case "$win_choice" in
3|4|5) RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
*)     RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
esac

if [[ ! -f win.img ]]; then
    spin_start "Đang tải $WIN_NAME..."
    aria2c -x16 -s16 --continue --file-allocation=none "$WIN_URL" -o win.img \
        > /dev/null 2>&1
    spin_stop "Tải $WIN_NAME xong"
else
    echo -e "${G}✔ win.img đã tồn tại — bỏ qua tải${W}"
fi

read -rp "📦 Mở rộng đĩa thêm bao nhiêu GB (default 20)? " extra_gb
extra_gb="${extra_gb:-20}"

spin_start "Resize disk +${extra_gb}GB..."
silent qemu-img resize win.img "+${extra_gb}G"
spin_stop "Resize disk xong"

# ════════════════════════════════════════════════════════════════
#  CẤU HÌNH VM
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}⚙  CHỌN CHẾ ĐỘ CẤU HÌNH VM${W}"
echo -e "${C}════════════════════════════════════${W}"
echo "1️⃣  Auto cấu hình (khuyên dùng)"
echo "2️⃣  Tự chọn thủ công"
echo -e "${C}════════════════════════════════════${W}"
read -rp "👉 Nhập lựa chọn [1-2]: " cfg_mode

if [[ "$cfg_mode" == "1" ]]; then
    spin_start "Auto detect tài nguyên host..."

    cpu_v=$(nproc 2>/dev/null)
    cpu_u=$cpu_v

    if [[ -f /sys/fs/cgroup/cpu.max ]]; then
        IFS=" " read -r cq cp < /sys/fs/cgroup/cpu.max
        [[ "$cq" != "max" ]] && cpu_u=$(awk "BEGIN{printf \"%.0f\",$cq/$cp}")
    elif [[ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then
        cq=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        cp=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
        [[ "$cq" != "-1" ]] && cpu_u=$(awk "BEGIN{printf \"%.0f\",$cq/$cp}")
    fi
    [[ "$cpu_u" -lt 1 ]] && cpu_u=1

    mem_total_gb=$(awk '/MemTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo)
    mem_auto_gb=$(awk "BEGIN{printf \"%d\", ($mem_total_gb*0.85)+0.5}")
    [[ "$mem_auto_gb" -lt 2 ]] && mem_auto_gb=2
    max_ram=$(( mem_total_gb - 1 ))
    [[ "$mem_auto_gb" -gt "$max_ram" ]] && mem_auto_gb=$max_ram

    cpu_core=$cpu_u
    ram_size=$mem_auto_gb
    spin_stop "Auto detect xong"

    echo "   🖥️  CPU : ${cpu_v} cores (usable: ${cpu_core})"
    echo "   💾 RAM : ${mem_total_gb}GB total → VM ${ram_size}GB"
else
    read -rp "⚙  CPU core (default 4): " cpu_core;  cpu_core="${cpu_core:-4}"
    read -rp "💾 RAM GB   (default 4): " ram_size;  ram_size="${ram_size:-4}"
fi

detect_hugepage

# TCG TB cache: scale theo RAM, tối đa 25% RAM, cap 256MB
TCG_TB_MB=$(( ram_size * 1024 / 4 ))   # 25% RAM tính theo MB
[[ "$TCG_TB_MB" -lt 64  ]] && TCG_TB_MB=64
[[ "$TCG_TB_MB" -gt 256 ]] && TCG_TB_MB=256
TCG_TB_BYTES=$(( TCG_TB_MB * 1024 * 1024 ))
echo -e "${G}⚡ TCG TB cache: ${TCG_TB_MB}MB (25% of ${ram_size}GB RAM)${W}"

# ── CPU flags ─────────────────────────────────────────────────
cpu_host=$(grep -m1 "model name" /proc/cpuinfo | sed 's/^.*: //')
cpu_host="${cpu_host//,/ }"
CPU_EXTRA=""
grep -q ssse3  /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+ssse3"
grep -q sse4_1 /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.1"
grep -q sse4_2 /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.2"
grep -q rdtscp /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+rdtscp"
grep -q ' avx ' /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx"
grep -q avx2   /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx2"
cpu_model="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+cx16,+x2apic,+sep,+pat,+pse,+aes,+popcnt${CPU_EXTRA},model-id=${cpu_host}"

# ── Network ───────────────────────────────────────────────────
[[ "$win_choice" == "4" ]] \
    && NET_DEVICE="-device e1000e,netdev=n0" \
    || NET_DEVICE="-device virtio-net-pci,netdev=n0"

# ── BIOS/UEFI ─────────────────────────────────────────────────
[[ "$USE_UEFI" == "yes" ]] \
    && BIOS_OPT="-bios /usr/share/qemu/OVMF.fd" \
    || BIOS_OPT=""

# ════════════════════════════════════════════════════════════════
#  KHỞI ĐỘNG VM
# ════════════════════════════════════════════════════════════════
# ── Kernel tweaks nhẹ — chỉ những thứ an toàn ───────────────
# Tắt watchdog
echo 0   | sudo tee /proc/sys/kernel/watchdog             > /dev/null 2>&1 || true
# Giảm swap
echo 10  | sudo tee /proc/sys/vm/swappiness               > /dev/null 2>&1 || true
# Bật THP = always nếu chưa bật
echo "always" | sudo tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null 2>&1 || true
echo "defer+madvise" | sudo tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null 2>&1 || true
echo -e "${G}✔${W} Kernel tweaks: watchdog off, swappiness=10, THP=always"

spin_start "Khởi động VM ${WIN_NAME}..."
qemu-system-x86_64 \
    -machine q35,hpet=off \
    -cpu "$cpu_model" \
    -smp "$cpu_core" \
    -m "${ram_size}G" \
    $HUGEPAGE_OPT \
    -accel tcg,thread=multi,tb-size=$TCG_TB_BYTES \
    -rtc base=localtime \
    $BIOS_OPT \
    -drive file=win.img,if=virtio,cache=unsafe,aio=threads,format=raw \
    -netdev user,id=n0,hostfwd=tcp::3389-:3389 \
    $NET_DEVICE \
    -device virtio-mouse-pci \
    -device virtio-keyboard-pci \
    -nodefaults \
    -global ICH9-LPC.disable_s3=1 \
    -global ICH9-LPC.disable_s4=1 \
    -smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640" \
    -global kvm-pit.lost_tick_policy=discard \
    -no-user-config \
    -display none \
    -vga virtio \
    -daemonize \
    > /dev/null 2>&1 || true

sleep 3
spin_stop "VM đã khởi động"

# ════════════════════════════════════════════════════════════════
#  TUNNEL RDP
# ════════════════════════════════════════════════════════════════
use_rdp=$(ask "🛰️  Mở port tunnel để kết nối RDP? (y/n): " "n")

if [[ "$use_rdp" == "y" ]]; then
    spin_start "Cài tmux..."
    silent sudo apt-get install -y tmux
    spin_stop "tmux sẵn sàng"

    spin_start "Tải kami-tunnel..."
    silent wget -q https://github.com/kami2k1/tunnel/releases/latest/download/kami-tunnel-linux-amd64.tar.gz
    silent tar -xzf kami-tunnel-linux-amd64.tar.gz
    silent chmod +x kami-tunnel
    spin_stop "kami-tunnel sẵn sàng"

    spin_start "Tạo tunnel RDP port 3389..."
    tmux kill-session -t kami 2>/dev/null || true
    tmux new-session -d -s kami "./kami-tunnel 3389"
    sleep 5
    spin_stop "Tunnel đang chạy"

    PUBLIC=$(tmux capture-pane -pt kami -p | \
        sed 's/\x1b\[[0-9;]*m//g' | \
        grep -i 'public' | \
        grep -oE '[a-zA-Z0-9.\-]+:[0-9]+' | head -n1)

    echo ""
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "${C}🚀 WINDOWS VM DEPLOYED SUCCESSFULLY  [v10]${W}"
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "🪟 OS           : ${Y}$WIN_NAME${W}"
    echo -e "⚙  CPU Cores    : ${B}$cpu_core${W}"
    echo -e "💾 RAM          : ${B}${ram_size} GB${W}"
    echo -e "🧠 CPU Host     : $cpu_host"
    echo -e "⚡ TCG TB Cache  : ${TCG_TB_MB}MB"
    echo -e "📄 HugePages    : $HP_INFO"
    echo -e "${C}──────────────────────────────────────────────${W}"
    echo -e "📡 RDP Address  : ${G}${PUBLIC:-<chờ tunnel>}${W}"
    echo -e "👤 Username     : ${Y}$RDP_USER${W}"
    echo -e "🔑 Password     : ${Y}$RDP_PASS${W}"
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "${G}🟢 Status       : RUNNING${W}"
    echo "⏱  GUI Mode     : Headless / RDP"
    echo -e "${C}══════════════════════════════════════════════${W}"
fi
