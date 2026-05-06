#!/usr/bin/env bash
set -euo pipefail

# ════════════════════════════════════════════════════════════════
#  WINDOWS VM TOOL v16
#  LLVM 16 via apt (không dùng external repo)
#  Rootless build fallback từ source nếu không có conda
#  Fix: removed --user from pip install (virtualenv compatibility)
#  KVM: Auto detect /dev/kvm → enable KVM acceleration if available
#  NEW: CLI flags --auto --winXXXX để chạy hoàn toàn không tương tác
#
#  Cách dùng:
#    bash winv16.sh                          # chế độ interactive như cũ
#    bash winv16.sh --auto --win2012         # auto, Windows Server 2012 R2
#    bash winv16.sh --auto --win2022         # auto, Windows Server 2022
#    bash winv16.sh --auto --win11           # auto, Windows 11 LTSB
#    bash winv16.sh --auto --win10ltsb       # auto, Windows 10 LTSB 2015
#    bash winv16.sh --auto --win10ltsc       # auto, Windows 10 LTSC 2023
#    bash winv16.sh --auto --win2012 --rdp   # auto + mở tunnel RDP
# ════════════════════════════════════════════════════════════════

# ── MÀU SẮC ────────────────────────────────────────────────────
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
B='\033[1;34m'; C='\033[1;36m'; W='\033[0m'

# ════════════════════════════════════════════════════════════════
#  CLI ARGUMENT PARSER
#  --auto          : bỏ qua tất cả câu hỏi, chạy hoàn toàn tự động
#  --win2012       : Windows Server 2012 R2
#  --win2022       : Windows Server 2022
#  --win11         : Windows 11 LTSB
#  --win10ltsb     : Windows 10 LTSB 2015
#  --win10ltsc     : Windows 10 LTSC 2023
#  --rdp           : tự động mở tunnel RDP sau khi VM chạy
#  --build         : force build QEMU dù đã có sẵn
#  --no-build      : bỏ qua build QEMU
# ════════════════════════════════════════════════════════════════
AUTO_MODE=0        # 1 = không hỏi bất cứ gì
AUTO_WIN=""        # win choice preset: 1-5
AUTO_RDP=0         # 1 = tự mở tunnel RDP
AUTO_BUILD=""      # "yes" | "no" | "" (hỏi)

for _arg in "$@"; do
    case "$_arg" in
        --auto)       AUTO_MODE=1    ;;
        --win2012)    AUTO_WIN=1     ;;
        --win2022)    AUTO_WIN=2     ;;
        --win11)      AUTO_WIN=3     ;;
        --win10ltsb)  AUTO_WIN=4     ;;
        --win10ltsc)  AUTO_WIN=5     ;;
        --rdp)        AUTO_RDP=1     ;;
        --build)      AUTO_BUILD="yes" ;;
        --no-build)   AUTO_BUILD="no"  ;;
        --help|-h)
            echo "Usage: bash winv16.sh [OPTIONS]"
            echo ""
            echo "  --auto          Chạy không tương tác (bắt buộc kết hợp với --winXXXX)"
            echo "  --win2012       Windows Server 2012 R2"
            echo "  --win2022       Windows Server 2022"
            echo "  --win11         Windows 11 LTSB"
            echo "  --win10ltsb     Windows 10 LTSB 2015"
            echo "  --win10ltsc     Windows 10 LTSC 2023"
            echo "  --rdp           Tự động mở tunnel RDP"
            echo "  --build         Force build QEMU"
            echo "  --no-build      Bỏ qua build QEMU"
            exit 0
            ;;
        *) echo -e "${Y}⚠${W}  Unknown argument: $_arg (bỏ qua)"; ;;
    esac
done

# Hàm ask có nhận biết AUTO_MODE
ask() {
    local prompt="$1"
    local default="$2"
    if [[ "$AUTO_MODE" == "1" ]]; then
        echo "$default"
        return
    fi
    read -rp "$prompt" ans
    ans="${ans,,}"
    echo "${ans:-$default}"
}

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

ver_lt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

# ── HÀM pip_install: tự chọn --user hay không tuỳ môi trường ──
pip_install() {
    if python3 -c "import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)" 2>/dev/null; then
        python3 -m pip install -q "$@"
    else
        python3 -m pip install -q --user "$@" 2>/dev/null \
            || python3 -m pip install -q "$@"
    fi
}

# ════════════════════════════════════════════════════════════════
#  KVM DETECTION
#  Kiểm tra /dev/kvm bằng ls -l, xác nhận quyền root/kvm group
# ════════════════════════════════════════════════════════════════
KVM_AVAILABLE=0   # 1 = có thể dùng KVM
KVM_MODE=""       # "kvm" hoặc "tcg"

_detect_kvm() {
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔍 KIỂM TRA KVM ACCELERATION${W}"
    echo -e "${C}════════════════════════════════════${W}"

    # Bước 1: kiểm tra /dev/kvm tồn tại không
    if [[ ! -e /dev/kvm ]]; then
        echo -e "${Y}⚠${W}  /dev/kvm không tồn tại — dùng TCG"
        KVM_AVAILABLE=0
        KVM_MODE="tcg"
        return
    fi

    # Bước 2: ls -l /dev/kvm để xem owner/group/permission
    KVM_LS=$(ls -l /dev/kvm 2>/dev/null)
    echo -e "${B}ℹ${W}  ${KVM_LS}"

    KVM_OWNER=$(echo "$KVM_LS" | awk '{print $3}')
    KVM_GROUP=$(echo "$KVM_LS" | awk '{print $4}')
    KVM_PERMS=$(echo "$KVM_LS" | awk '{print $1}')

    echo -e "   Owner : ${Y}${KVM_OWNER}${W} | Group : ${Y}${KVM_GROUP}${W}"
    echo -e "   Perms : ${B}${KVM_PERMS}${W}"

    # Bước 3: kiểm tra owner/group có nằm trong whitelist hợp lệ không
    #   HỢP LỆ:  owner=root  AND  group=root|kvm
    #   KHÔNG:   owner=nobody / nogroup / hoặc bất kỳ owner khác root
    CAN_USE_KVM=0

    if [[ "$KVM_OWNER" == "root" ]] && [[ "$KVM_GROUP" == "root" || "$KVM_GROUP" == "kvm" ]]; then
        echo -e "${G}✔${W}  /dev/kvm owner/group hợp lệ: ${Y}${KVM_OWNER}:${KVM_GROUP}${W}"

        # Bước 3a: nếu đang là root → dùng được ngay
        if [[ "$(id -u)" == "0" ]]; then
            CAN_USE_KVM=1
            echo -e "${G}✔${W}  Đang chạy với quyền root → có thể dùng KVM"

        # Bước 3b: không phải root → kiểm tra user có trong group kvm không
        else
            CURRENT_USER=$(id -un)
            CURRENT_GROUPS=$(id -Gn)
            if echo "$CURRENT_GROUPS" | grep -qw "$KVM_GROUP"; then
                CAN_USE_KVM=1
                echo -e "${G}✔${W}  User '${CURRENT_USER}' thuộc group '${KVM_GROUP}' → có thể dùng KVM"
            else
                echo -e "${Y}⚠${W}  User '${CURRENT_USER}' KHÔNG thuộc group '${KVM_GROUP}' → không dùng được KVM"
            fi
        fi

    else
        # owner/group không phải root:root hoặc root:kvm → coi như không dùng được
        echo -e "${R}✘${W}  /dev/kvm owner/group KHÔNG hợp lệ: ${Y}${KVM_OWNER}:${KVM_GROUP}${W}"
        echo -e "   Chỉ chấp nhận: ${G}root:root${W} hoặc ${G}root:kvm${W}"
        echo -e "   Phát hiện     : ${R}${KVM_OWNER}:${KVM_GROUP}${W} → fallback TCG"
        CAN_USE_KVM=0
    fi

    # Bước 4: nếu owner/group ok nhưng vẫn muốn double-check → thử -r -w
    if [[ $CAN_USE_KVM -eq 0 ]]; then
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            CAN_USE_KVM=1
            echo -e "${G}✔${W}  /dev/kvm readable+writable (fallback check) → có thể dùng KVM"
        fi
    fi

    # Bước 4: thử chạy kvm-ok hoặc kiểm tra /proc/cpuinfo flags
    if [[ $CAN_USE_KVM -eq 1 ]]; then
        # Kiểm tra CPU có vmx/svm flag không
        if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
            echo -e "${G}✔${W}  CPU có hỗ trợ hardware virtualization (vmx/svm)"
            KVM_AVAILABLE=1
            KVM_MODE="kvm"
            echo -e "${G}🚀 KVM ACCELERATION: BẬT${W}"
        else
            echo -e "${Y}⚠${W}  CPU không có vmx/svm flag — KVM sẽ không hoạt động đúng"
            echo -e "${Y}⚠${W}  Fallback sang TCG"
            KVM_AVAILABLE=0
            KVM_MODE="tcg"
        fi
    else
        echo -e "${Y}⚠${W}  Không đủ quyền dùng /dev/kvm — dùng TCG"
        KVM_AVAILABLE=0
        KVM_MODE="tcg"
    fi

    echo -e "${C}════════════════════════════════════${W}"
    echo ""
}

# ════════════════════════════════════════════════════════════════
#  PACKAGE MANAGER — root → sudo apt → rootless build từ source
# ════════════════════════════════════════════════════════════════

APT_CMD=""
APT_OK=0
ROOTLESS=0

_detect_apt() {
    echo -ne "${B}◜${W} Kiểm tra quyền package manager..."

    if [[ "$(id -u)" == "0" ]] && apt-get update -qq > /dev/null 2>&1; then
        APT_CMD="apt-get"
        APT_OK=1
        echo -e "\r${G}✔${W} Dùng apt-get (root)              "
        return
    fi

    if sudo -n true 2>/dev/null && sudo apt-get update -qq > /dev/null 2>&1; then
        APT_CMD="sudo apt-get"
        APT_OK=1
        echo -e "\r${G}✔${W} Dùng sudo apt-get                "
        return
    fi

    echo -e "\r${Y}⚠${W}  Không có apt — chuyển sang build rootless từ source"
    APT_OK=0
    ROOTLESS=1
}

apt_install() {
    local pkg="$1"
    $APT_CMD install -y -qq "$pkg" > /dev/null 2>&1
}

# ════════════════════════════════════════════════════════════════
#  BUILD LIBRARIES FROM SOURCE (khi không có conda)
# ════════════════════════════════════════════════════════════════

_build_zlib_from_source() {
    local prefix="$1"; local build_dir="$2"
    spin_start "Build zlib từ source..."
    cd "$build_dir"
    wget -c -q https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz
    tar xzf v1.3.1.tar.gz; cd zlib-1.3.1
    ./configure --prefix="$prefix" --shared > /dev/null 2>&1
    make -j"$(nproc)" > /dev/null 2>&1
    make install > /dev/null 2>&1
    spin_stop "zlib 1.3.1 đã build xong"
}

_build_libffi_from_source() {
    local prefix="$1"; local build_dir="$2"
    spin_start "Build libffi từ source..."
    cd "$build_dir"
    wget -c -q https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz
    tar xzf libffi-3.4.6.tar.gz; cd libffi-3.4.6
    ./configure --prefix="$prefix" > /dev/null 2>&1
    make -j"$(nproc)" > /dev/null 2>&1
    make install > /dev/null 2>&1
    spin_stop "libffi 3.4.6 đã build xong"
}

_build_pixman_from_source() {
    local prefix="$1"; local build_dir="$2"
    spin_start "Build pixman từ source..."
    cd "$build_dir"
    wget -c -q https://cairographics.org/releases/pixman-0.42.2.tar.gz
    tar xzf pixman-0.42.2.tar.gz; cd pixman-0.42.2
    ./configure --prefix="$prefix" --disable-gtk --enable-shared > /dev/null 2>&1
    make -j"$(nproc)" > /dev/null 2>&1
    make install > /dev/null 2>&1
    spin_stop "pixman 0.42.2 đã build xong"
}

_build_glib_from_source() {
    local prefix="$1"; local build_dir="$2"; local py_prefix="$3"
    spin_start "Build glib từ source (mất 5-10 phút)..."
    cd "$build_dir"
    wget -c -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz
    tar xJf glib-2.76.6.tar.xz; cd glib-2.76.6
    mkdir -p build; cd build
    local meson_cmd="meson"
    [[ -x "$py_prefix/bin/meson" ]] && meson_cmd="$py_prefix/bin/meson"
    PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_PATH:-}" \
    $meson_cmd setup . .. --prefix="$prefix" -Dlibdir="lib" > /dev/null 2>&1
    ninja -j"$(nproc)" > /dev/null 2>&1
    ninja install > /dev/null 2>&1
    spin_stop "glib 2.76.6 đã build xong"
}

# ════════════════════════════════════════════════════════════════
#  ROOTLESS BUILD
# ════════════════════════════════════════════════════════════════
_rootless_build() {
    local ROOTLESS_QEMU="$HOME/qemu-static/bin/qemu-system-x86_64"

    if [[ -x "$ROOTLESS_QEMU" ]]; then
        local rv
        rv=$("$ROOTLESS_QEMU" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU rootless v${rv} đã tồn tại — bỏ qua build${W}"
        export QEMU_BIN="$ROOTLESS_QEMU"
        export PREFIX="$HOME/qemu-static"
        export PY_PREFIX="${CONDA_PREFIX:-$HOME/python-local}"
        export PATH="$PREFIX/bin:$PY_PREFIX/bin:$PATH"
        export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:$PY_PREFIX/lib:${LD_LIBRARY_PATH:-}"
        return 0
    fi

    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔧 ROOTLESS BUILD MODE${W}"
    echo -e "${C}════════════════════════════════════${W}"

    rm -rf "$HOME/python-local" "$HOME/qemu-static" "$HOME/qemu-build" "$HOME/certs"
    export PREFIX="$HOME/qemu-static"
    export BUILD="$HOME/qemu-build"
    mkdir -p "$PREFIX" "$BUILD" "$HOME/certs"

    spin_start "Tải SSL certs..."
    cd "$HOME/certs"
    wget -q https://curl.se/ca/cacert.pem
    export SSL_CERT_FILE="$HOME/certs/cacert.pem"
    export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
    spin_stop "SSL certs xong"

    HAVE_CONDA=0
    if command -v conda &>/dev/null; then
        HAVE_CONDA=1
        export PY_PREFIX="${CONDA_PREFIX:-/opt/conda}"
        export PATH="$PY_PREFIX/bin:$HOME/.local/bin:$PREFIX/bin:$PATH"
        echo -e "${G}✔${W} Phát hiện conda tại: $CONDA_PREFIX"
    else
        echo -e "${Y}⚠${W}  Không phát hiện conda — sẽ build từ source"
        export PY_PREFIX="$HOME/python-local"
        mkdir -p "$PY_PREFIX"
        export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"
    fi

    if [[ $HAVE_CONDA -eq 0 ]]; then
        echo -ne "${B}◜${W} Kiểm tra Python system..."
        PY_VER_SYSTEM=$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
        if [[ -n "$PY_VER_SYSTEM" ]]; then
            echo -e "\r${G}✔${W} Python system $PY_VER_SYSTEM          "
        else
            echo -e "\r${R}✘${W} Không tìm thấy Python 3"; exit 1
        fi
    else
        echo -ne "${B}◜${W} Kiểm tra Python conda..."
        PY_VER_CONDA=$($PY_PREFIX/bin/python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
        echo -e "\r${G}✔${W} Python conda $PY_VER_CONDA          "
    fi

    if python3 -c "import ssl; print('SSL OK:', ssl.OPENSSL_VERSION)" 2>/dev/null; then
        echo -e "${G}✔${W} Python ssl module OK"
    else
        echo -e "${R}✘${W} Python ssl module KHÔNG có"; exit 1
    fi

    if [[ $HAVE_CONDA -eq 1 ]]; then
        echo -ne "${B}◜${W} Cài meson/ninja từ conda..."
        conda install -y -q -c conda-forge meson ninja pkg-config > /tmp/conda-meson.log 2>&1
        echo -e "\r${G}✔${W} meson/ninja/pkg-config xong          "
    else
        echo -ne "${B}◜${W} Cài pip packages (meson/ninja)..."
        pip_install --upgrade pip meson ninja > /tmp/pip-meson.log 2>&1
        echo -e "\r${G}✔${W} meson/ninja từ pip xong          "
    fi

    if [[ $HAVE_CONDA -eq 0 ]]; then
        echo ""
        echo -e "${C}════════════════════════════════════${W}"
        echo -e "${C}🔨 BUILD LIBRARIES FROM SOURCE${W}"
        echo -e "${C}════════════════════════════════════${W}"
        _build_zlib_from_source "$PREFIX" "$BUILD"
        _build_libffi_from_source "$PREFIX" "$BUILD"
        _build_pixman_from_source "$PREFIX" "$BUILD"
        _build_glib_from_source "$PREFIX" "$BUILD" "$PY_PREFIX"
    else
        echo -ne "${B}◜${W} Cài deps từ conda..."
        conda install -y -q -c conda-forge glib pixman zlib libffi > /tmp/conda-deps.log 2>&1
        echo -e "\r${G}✔${W} glib/pixman/zlib/libffi xong          "
    fi

    PIXMAN_INC=""
    if [[ $HAVE_CONDA -eq 1 ]]; then
        for d in "$CONDA_PREFIX/include/pixman-1" "$CONDA_PREFIX/include" \
                 "/opt/conda/include/pixman-1" "/opt/conda/include"; do
            [[ -f "$d/pixman.h" ]] && { PIXMAN_INC="$d"; break; }
        done
    else
        PIXMAN_INC="$PREFIX/include"
    fi
    [[ -z "$PIXMAN_INC" ]] && \
        PIXMAN_INC=$(find "$PREFIX" -name "pixman.h" -type f 2>/dev/null | head -1 | xargs dirname)
    echo -e "${G}✔${W} pixman.h tại: ${PIXMAN_INC}"

    echo -ne "${B}◜${W} Cài pip packages (packaging/truststore)..."
    pip_install --upgrade pip packaging truststore > /tmp/pip-rootless.log 2>&1
    echo -e "\r${G}✔${W} pip packages xong          "

    echo -ne "${B}◜${W} Tải QEMU 11.0.0..."
    cd "$BUILD"
    wget -c -qO- https://download.qemu.org/qemu-11.0.0.tar.xz | tar xJ > /dev/null 2>&1
    echo -e "\r${G}✔${W} Tải QEMU xong          "

    echo -ne "${B}◜${W} Cài libslirp..."
    SLIRP_OK=0

    if [[ $HAVE_CONDA -eq 1 ]]; then
        if conda install -y -q -c conda-forge libslirp > /tmp/slirp-conda.log 2>&1; then
            SLIRP_PC=$(find "$CONDA_PREFIX" -name "slirp.pc" 2>/dev/null | head -1)
            if [[ -n "$SLIRP_PC" ]]; then
                export PKG_CONFIG_PATH="$(dirname "$SLIRP_PC"):${PKG_CONFIG_PATH:-}"
                SLIRP_OK=1
                echo -e "\r${G}✔${W} libslirp từ conda xong          "
            fi
        fi
    fi

    if [[ "$SLIRP_OK" == "0" ]]; then
        mkdir -p "$BUILD/qemu-11.0.0/subprojects"
        wget -c -qO- \
            "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.7.0/libslirp-v4.7.0.tar.gz" \
            | tar xz -C "$BUILD/qemu-11.0.0/subprojects/" > /dev/null 2>&1 \
            && mv "$BUILD/qemu-11.0.0/subprojects/libslirp-v4.7.0" \
                  "$BUILD/qemu-11.0.0/subprojects/libslirp" \
            && SLIRP_OK=1 \
            && echo -e "\r${G}✔${W} libslirp tarball xong          "
    fi

    if [[ "$SLIRP_OK" == "0" ]]; then
        git clone -q --depth 1 \
            https://gitlab.freedesktop.org/slirp/libslirp.git \
            "$BUILD/qemu-11.0.0/subprojects/libslirp" > /dev/null 2>&1 \
            && SLIRP_OK=1 \
            && echo -e "\r${G}✔${W} libslirp git xong          " \
            || { echo -e "\r${R}✘${W} libslirp thất bại toàn bộ"; exit 1; }
    fi
    spin_stop "libslirp xong"

    if [[ $HAVE_CONDA -eq 1 ]]; then
        CONDA_GLIB_DIR=$(dirname "$(find "$CONDA_PREFIX" -name "glib-2.0.pc" 2>/dev/null | grep "lib/pkgconfig" | head -1)")
        if [[ -n "$CONDA_GLIB_DIR" && "$CONDA_GLIB_DIR" != "." ]]; then
            export PKG_CONFIG_PATH="$CONDA_GLIB_DIR:${PKG_CONFIG_PATH:-}"
            echo -e "${G}✔${W} glib từ conda: $CONDA_GLIB_DIR"
        fi
        for d in "$CONDA_PREFIX/lib/pkgconfig" "$CONDA_PREFIX/lib64/pkgconfig"; do
            [[ -d "$d" ]] && export PKG_CONFIG_PATH="$d:${PKG_CONFIG_PATH:-}"
        done
    else
        for d in "$PREFIX/lib/pkgconfig" "$PREFIX/lib64/pkgconfig"; do
            [[ -d "$d" ]] && export PKG_CONFIG_PATH="$d:${PKG_CONFIG_PATH:-}"
        done
    fi
    for d in "$PREFIX/lib/pkgconfig" "$PREFIX/lib64/pkgconfig"; do
        [[ -d "$d" ]] && export PKG_CONFIG_PATH="$d:${PKG_CONFIG_PATH:-}"
    done
    export PKG_CONFIG_PATH="${PKG_CONFIG_PATH%:}"
    echo -e "${B}ℹ${W}  PKG_CONFIG_PATH=$PKG_CONFIG_PATH"

    if [[ $HAVE_CONDA -eq 1 ]]; then
        CONDA_INC="$CONDA_PREFIX/include"; CONDA_LIB="$CONDA_PREFIX/lib"
    else
        CONDA_INC="$PREFIX/include"; CONDA_LIB="$PREFIX/lib"
    fi

    QEMU_EXTRA_CFLAGS="-I$PREFIX/include -I${PIXMAN_INC:-$CONDA_INC/pixman-1} -I$CONDA_INC"
    QEMU_EXTRA_LDFLAGS="-L$PREFIX/lib64 -L$PREFIX/lib -L$CONDA_LIB -Wl,-rpath,$CONDA_LIB"

    # ── KVM flag cho configure rootless ──────────────────────────
    if [[ "$KVM_AVAILABLE" == "1" ]]; then
        QEMU_KVM_FLAG="--enable-kvm"
        echo -e "${G}⚡ Rootless QEMU build: --enable-kvm${W}"
    else
        QEMU_KVM_FLAG="--disable-kvm"
        echo -e "${B}ℹ${W}  Rootless QEMU build: --disable-kvm (TCG mode)"
    fi

    echo -ne "${B}◜${W} Configure QEMU rootless..."
    cd "$BUILD/qemu-11.0.0"
    rm -rf build

    ./configure \
        --prefix="$PREFIX" \
        --python="$(command -v python3)" \
        --target-list=x86_64-softmmu \
        --enable-tcg \
        $QEMU_KVM_FLAG \
        --disable-werror \
        --disable-gtk \
        --disable-sdl \
        --disable-opengl \
        --disable-virglrenderer \
        --enable-slirp \
        --enable-vnc \
        --disable-libusb \
        --disable-capstone \
        --extra-cflags="$QEMU_EXTRA_CFLAGS" \
        --extra-ldflags="$QEMU_EXTRA_LDFLAGS" \
        > /tmp/qemu-configure.log 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "\r${R}✘${W} Configure QEMU thất bại — xem /tmp/qemu-configure.log"
        exit 1
    fi
    echo -e "\r${G}✔${W} Configure QEMU xong          "

    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔨 Compile QEMU (mất 10-20 phút)${W}"
    echo -e "${C}════════════════════════════════════${W}"
    make -j"$(nproc)" 2>&1 | grep --line-buffered -E "^\[|error:|warning:|FAILED"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo -e "${R}✘ Compile QEMU thất bại — xem /tmp/qemu-build.log${W}"
        make -j"$(nproc)" > /tmp/qemu-build.log 2>&1
        exit 1
    fi
    make install > /dev/null 2>&1
    strip "$PREFIX/bin/qemu-system-x86_64" 2>/dev/null || true
    echo -e "${G}✔ QEMU rootless build xong${W}"

    export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:$PREFIX/lib/x86_64-linux-gnu:$CONDA_LIB:${LD_LIBRARY_PATH:-}"
    export QEMU_BIN="$PREFIX/bin/qemu-system-x86_64"
    export PATH="$PREFIX/bin:$PATH"

    if [[ $HAVE_CONDA -eq 1 ]]; then
        spin_start "Cài aria2 từ conda..."
        conda install -y -q aria2 > /dev/null 2>&1 \
            && spin_stop "aria2 từ conda xong" \
            || spin_fail "aria2 conda thất bại — bỏ qua, dùng wget"
    else
        echo -e "${B}ℹ${W}  build từ source — bỏ qua aria2, dùng wget để tải"
    fi

    echo -e "${G}✔ Rootless build hoàn tất${W}"
    echo -e "   QEMU  : $QEMU_BIN"
    echo -e "   Python: $(python3 --version 2>&1)"
    echo -e "   Accel : ${KVM_MODE^^}"
}


# ════════════════════════════════════════════════════════════════
#  MAIN — detect apt, detect KVM, detect QEMU
# ════════════════════════════════════════════════════════════════
QEMU_BIN="/usr/bin/qemu-system-x86_64"
ROOTLESS_QEMU="$HOME/qemu-static/bin/qemu-system-x86_64"

_detect_apt
_detect_kvm   # ← chạy KVM detection ngay sau apt detection

_detect_existing_qemu() {
    for q in "$QEMU_BIN" "$ROOTLESS_QEMU" \
              "$(command -v qemu-system-x86_64 2>/dev/null)"; do
        if [[ -n "$q" && -x "$q" ]]; then
            local qv
            qv=$("$q" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
            echo -e "${G}⚡ Tìm thấy QEMU v${qv} tại: $q${W}"
            export QEMU_BIN="$q"
            export PATH="$(dirname "$q"):$PATH"
            return 0
        fi
    done
    return 1
}

if _detect_existing_qemu; then
    if [[ -n "$AUTO_BUILD" ]]; then
        choice="$AUTO_BUILD"
    else
        choice=$(ask "👉 QEMU đã có sẵn. Bạn có muốn build lại không? (y/n): " "n")
    fi
else
    if [[ -n "$AUTO_BUILD" ]]; then
        choice="$AUTO_BUILD"
    else
        choice=$(ask "👉 Bạn có muốn build QEMU không? (y/n): " "n")
    fi
fi

if [[ "$choice" == "y" ]]; then

    if [[ "$ROOTLESS" == "1" ]]; then
        _rootless_build
    elif [[ -x "$QEMU_BIN" ]]; then
        BUILT_VER=$("$QEMU_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU v${BUILT_VER} đã tồn tại — bỏ qua build${W}"
        export PATH="/opt/qemu-optimized/bin:$PATH"
    else
        echo ""
        spin_start "Cập nhật apt cache..."
        $APT_CMD update -qq > /dev/null 2>&1
        spin_stop "apt cache đã cập nhật"

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
            "genisoimage|genisoimage|genisoimage"
        )

        TOTAL=${#DEPS[@]}; IDX=0
        for entry in "${DEPS[@]}"; do
            IFS='|' read -r label pkg chk <<< "$entry"
            IDX=$(( IDX + 1 ))
            PREFIX_LABEL="[${IDX}/${TOTAL}]"
            if [[ -n "$chk" ]] && command -v "$chk" &>/dev/null; then
                echo -e "${G}✔${W} ${PREFIX_LABEL} ${label} ${B}(đã có)${W}"; continue
            fi
            if dpkg -s "$pkg" &>/dev/null 2>&1; then
                echo -e "${G}✔${W} ${PREFIX_LABEL} ${label} ${B}(đã cài)${W}"; continue
            fi
            spin_start "Đang cài $label..."
            if apt_install "$pkg"; then spin_stop "$PREFIX_LABEL $label"
            else spin_fail "$PREFIX_LABEL $label thất bại — bỏ qua"; fi
        done
        echo -e "${G}✔ Tất cả dependencies đã sẵn sàng${W}"

        spin_start "Cài LLVM 16 (clang, lld, llvm)..."
        export DEBIAN_FRONTEND=noninteractive
        if silent $APT_CMD install -y clang-16 lld-16 llvm-16 llvm-16-dev llvm-16-tools; then
            spin_stop "LLVM 16 đã cài"
        else
            spin_fail "LLVM 16 cài thất bại — kiểm tra apt"; exit 1
        fi

        export PATH="/usr/lib/llvm-16/bin:$PATH"
        export CC="clang-16"; export CXX="clang++-16"; export LD="lld-16"

        if command -v lld-16 &>/dev/null; then
            LLD_AVAILABLE=1; echo -e "${G}✔ lld-16 tìm thấy${W}"
        else
            LLD_AVAILABLE=0; echo -e "${Y}⚠️  lld-16 không tìm thấy, fallback sang ld mặc định${W}"
        fi

        GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")
        if ver_lt "$GLIB_VER" "2.66"; then
            echo -e "${Y}⚠️  glib hiện tại: $GLIB_VER — quá cũ, build glib 2.76.6${W}"
            spin_start "Tải source glib 2.76.6..."
            silent sudo apt-get install -y libffi-dev gettext
            cd /tmp; silent wget -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz
            spin_stop "Tải glib xong"
            spin_start "Giải nén glib..."; silent tar -xf glib-2.76.6.tar.xz; spin_stop "Giải nén xong"
            spin_start "Build & install glib 2.76.6..."
            cd glib-2.76.6; silent meson setup build --prefix=/usr/local
            silent ninja -C build; silent sudo ninja -C build install
            spin_stop "glib 2.76.6 đã cài"
            export PKG_CONFIG_PATH="/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
            export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:${LD_LIBRARY_PATH:-}"
        else
            echo -e "${G}✔ glib đủ yêu cầu: $GLIB_VER${W}"
        fi

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

        if [[ -d ~/qemu-env ]] && [[ ! -f ~/qemu-env/bin/activate ]]; then
            echo -e "${Y}⚠${W} venv cũ bị broken — xóa và tạo lại"
            rm -rf ~/qemu-env
        fi

        if [[ ! -f ~/qemu-env/bin/activate ]]; then
            echo -ne "${B}◜${W} Tạo Python venv..."
            python3 -m venv ~/qemu-env > /tmp/venv-create.log 2>&1
            if [[ $? -eq 0 ]]; then echo -e "\r${G}✔${W} Python venv đã tạo          "
            else echo -e "\r${R}✘${W} Tạo venv thất bại:"; cat /tmp/venv-create.log; exit 1; fi
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

        if [[ ! -d /tmp/qemu-src ]]; then
            spin_start "Tải source QEMU v11.0.0..."
            silent git clone --depth 1 --branch v11.0.0 \
                https://gitlab.com/qemu-project/qemu.git /tmp/qemu-src
            spin_stop "Tải source QEMU xong"
        else
            echo -e "${G}✔ Source QEMU đã có tại /tmp/qemu-src — bỏ qua clone${W}"
        fi

        rm -rf /tmp/qemu-build
        mkdir -p /tmp/qemu-build
        cd /tmp/qemu-build

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

        # ── KVM flag cho configure apt-mode ──────────────────────
        if [[ "$KVM_AVAILABLE" == "1" ]]; then
            QEMU_KVM_FLAG="--enable-kvm"
            echo -e "${G}⚡ QEMU apt-build: --enable-kvm${W}"
        else
            QEMU_KVM_FLAG="--disable-kvm"
            echo -e "${B}ℹ${W}  QEMU apt-build: --disable-kvm (TCG mode)"
        fi

        spin_start "Configure QEMU..."
        ../qemu-src/configure \
            --prefix=/opt/qemu-optimized \
            --target-list=x86_64-softmmu \
            --enable-tcg \
            $QEMU_KVM_FLAG \
            --enable-slirp \
            --enable-lto \
            --enable-coroutine-pool \
            --enable-vnc \
            --disable-opengl \
            --disable-virglrenderer \
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
            CC="$CC" CXX="$CXX" LD="$LD" \
            CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS" \
            > /tmp/qemu-configure.log 2>&1
        spin_stop "Configure xong"

        ulimit -n 84857 2>/dev/null || true
        NCPU=$(nproc)
        spin_start "Đang compile QEMU với ${NCPU} cores (mất 5-20 phút)..."
        if ninja -j"$NCPU" > /tmp/qemu-build.log 2>&1; then
            spin_stop "Compile QEMU xong"
        else
            spin_fail "Compile QEMU thất bại — xem log: /tmp/qemu-build.log"; exit 1
        fi

        spin_start "Cài đặt QEMU vào /opt/qemu-optimized..."
        if sudo ninja install > /dev/null 2>&1; then spin_stop "Cài đặt QEMU hoàn tất"
        else spin_fail "Cài đặt thất bại"; exit 1; fi

        export PATH="/opt/qemu-optimized/bin:$PATH"
        echo -e "${G}🔥 QEMU build xong! $($QEMU_BIN --version | head -1)${W}"
        echo -e "   Accel: ${KVM_MODE^^}"
    fi
else
    echo -e "${Y}⚡ Bỏ qua build QEMU.${W}"
fi

[[ -x "$QEMU_BIN" ]] && export PATH="/opt/qemu-optimized/bin:$PATH"

# ════════════════════════════════════════════════════════════════
#  MENU CHÍNH
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}🖥️  WINDOWS VM MANAGER  v16${W}"
if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "${C}⚡ Acceleration: ${G}KVM (hardware)${C}${W}"
else
    echo -e "${C}⚡ Acceleration: ${Y}TCG (software)${C}${W}"
fi
echo -e "${C}════════════════════════════════════${W}"

if [[ "$AUTO_MODE" == "1" ]]; then
    echo -e "${G}🤖 AUTO MODE — bỏ qua menu, tiến hành tạo VM${W}"
    main_choice="1"
else
    echo "1️⃣  Tạo Windows VM"
    echo "2️⃣  Quản Lý Windows VM"
    echo -e "${C}════════════════════════════════════${W}"
    read -rp "👉 Nhập lựa chọn [1-2]: " main_choice
fi

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
if [[ "$AUTO_MODE" == "1" && -n "$AUTO_WIN" ]]; then
    win_choice="$AUTO_WIN"
    echo -e "${G}🤖 AUTO MODE — Windows preset: ${AUTO_WIN}${W}"
else
    echo "🪟 Chọn phiên bản Windows muốn tải:"
    echo "1️⃣  Windows Server 2012 R2 x64"
    echo "2️⃣  Windows Server 2022 x64"
    echo "3️⃣  Windows 11 LTSB x64"
    echo "4️⃣  Windows 10 LTSB 2015 x64"
    echo "5️⃣  Windows 10 LTSC 2023 x64"
    read -rp "👉 Nhập số [1-5]: " win_choice
fi

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
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}⬇  Đang tải: ${Y}$WIN_NAME${W}"
    echo -e "${C}════════════════════════════════════${W}"
    if command -v aria2c &>/dev/null; then
        aria2c -x16 -s16 -j16 --continue=true --file-allocation=none \
            --console-log-level=notice --summary-interval=3 \
            --human-readable=true --download-result=full "$WIN_URL" -o win.img
    else
        echo -e "${Y}⚠${W}  aria2c không có — dùng wget..."
        wget --progress=bar:force --continue "$WIN_URL" -O win.img
    fi
    echo -e "${G}✔ Tải $WIN_NAME xong${W}"
else
    echo -e "${G}✔ win.img đã tồn tại — bỏ qua tải${W}"
fi

if [[ "$AUTO_MODE" == "1" ]]; then
    extra_gb=0
    echo -e "${G}🤖 AUTO MODE — disk extend: 0GB (bỏ qua resize)${W}"
else
    read -rp "📦 Mở rộng đĩa thêm bao nhiêu GB (default 20)? " extra_gb
    extra_gb="${extra_gb:-20}"
fi

if [[ "$extra_gb" -gt 0 ]]; then
    spin_start "Resize disk +${extra_gb}GB..."
    silent qemu-img resize win.img "+${extra_gb}G"
    spin_stop "Resize disk xong"
else
    echo -e "${B}ℹ${W}  Bỏ qua resize disk (extra_gb=0)"
fi

# ════════════════════════════════════════════════════════════════
#  CẤU HÌNH VM
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}⚙  CHỌN CHẾ ĐỘ CẤU HÌNH VM${W}"
echo -e "${C}════════════════════════════════════${W}"

if [[ "$AUTO_MODE" == "1" ]]; then
    cfg_mode="1"
    echo -e "${G}🤖 AUTO MODE — tự động chọn cấu hình tài nguyên${W}"
else
    echo "1️⃣  Auto cấu hình (khuyên dùng)"
    echo "2️⃣  Tự chọn thủ công"
    echo -e "${C}════════════════════════════════════${W}"
    read -rp "👉 Nhập lựa chọn [1-2]: " cfg_mode
fi

if [[ "$cfg_mode" == "1" ]]; then
    spin_start "Auto detect tài nguyên host..."
    cpu_v=$(nproc 2>/dev/null); cpu_u=$cpu_v

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
    cpu_core=$cpu_u; ram_size=$mem_auto_gb
    spin_stop "Auto detect xong"
    echo "   🖥️  CPU : ${cpu_v} cores (usable: ${cpu_core})"
    echo "   💾 RAM : ${mem_total_gb}GB total → VM ${ram_size}GB"
else
    read -rp "⚙  CPU core (default 4): " cpu_core; cpu_core="${cpu_core:-4}"
    read -rp "💾 RAM GB   (default 4): " ram_size; ram_size="${ram_size:-4}"
fi

# ════════════════════════════════════════════════════════════════
#  BUILD QEMU COMMAND — KVM vs TCG
# ════════════════════════════════════════════════════════════════

if [[ "$KVM_AVAILABLE" == "1" ]]; then
    # ── KVM MODE ─────────────────────────────────────────────────
    echo -e "${G}⚡ VM sẽ chạy với KVM acceleration + CPU host passthrough${W}"
    ACCEL_OPT="-accel kvm"
    CPU_OPT="-cpu host"

    # Network
    [[ "$win_choice" == "4" ]] \
        && NET_DEVICE="-device e1000e,netdev=n0" \
        || NET_DEVICE="-device virtio-net-pci,netdev=n0"

    # BIOS/UEFI
    [[ "$USE_UEFI" == "yes" ]] \
        && BIOS_OPT="-bios /usr/share/qemu/OVMF.fd" \
        || BIOS_OPT=""

    QEMU_CMD=(
        ${QEMU_BIN:-qemu-system-x86_64}
        -machine q35,hpet=off,accel=kvm
        $CPU_OPT
        -smp "$cpu_core"
        -m "${ram_size}G"
        $ACCEL_OPT
        -rtc base=localtime,clock=host
    )

else
    # ── TCG MODE ─────────────────────────────────────────────────
    echo -e "${Y}⚡ VM sẽ chạy với TCG (software emulation)${W}"

    # TCG TB cache
    TCG_TB_MB=$(( ram_size * 1024 / 4 ))
    [[ "$TCG_TB_MB" -lt 64  ]] && TCG_TB_MB=64
    [[ "$TCG_TB_MB" -gt 256 ]] && TCG_TB_MB=256
    echo -e "${G}⚡ TCG TB cache: ${TCG_TB_MB}MB${W}"

    # CPU flags
    cpu_host=$(grep -m1 "model name" /proc/cpuinfo | sed 's/^.*: //')
    cpu_host="${cpu_host//,/ }"
    CPU_EXTRA=""
    grep -q ssse3  /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+ssse3"
    grep -q sse4_1 /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.1"
    grep -q sse4_2 /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.2"
    grep -q rdtscp /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+rdtscp"
    grep -q ' avx ' /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx"
    grep -q avx2   /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx2"
    cpu_model="qemu64,hypervisor=off,tsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+cx16,+x2apic,+sep,+pat,+pse,+aes,+popcnt${CPU_EXTRA},model-id=${cpu_host// /_}"

    # Network
    [[ "$win_choice" == "4" ]] \
        && NET_DEVICE="-device e1000e,netdev=n0" \
        || NET_DEVICE="-device virtio-net-pci,netdev=n0"

    # BIOS/UEFI
    [[ "$USE_UEFI" == "yes" ]] \
        && BIOS_OPT="-bios /usr/share/qemu/OVMF.fd" \
        || BIOS_OPT=""

    QEMU_CMD=(
        ${QEMU_BIN:-qemu-system-x86_64}
        -machine q35,hpet=off
        -cpu "$cpu_model"
        -smp "$cpu_core"
        -m "${ram_size}G"
        -accel tcg,thread=multi,tb-size=$TCG_TB_MB
        -rtc base=localtime
    )
fi

# ── Thêm BIOS/UEFI ───────────────────────────────────────────
[[ -n "$BIOS_OPT" ]] && QEMU_CMD+=($BIOS_OPT)

# ── Disk ─────────────────────────────────────────────────────
QEMU_CMD+=(
    -drive file=win.img,if=virtio,cache=unsafe,aio=threads,format=raw
)

# ── Network ──────────────────────────────────────────────────
QEMU_CMD+=(
    -netdev user,id=n0,hostfwd=tcp::3389-:3389
    $NET_DEVICE
)

# ── Input ────────────────────────────────────────────────────
QEMU_CMD+=(
    -device virtio-mouse-pci
    -device virtio-keyboard-pci
)

# ── Display ──────────────────────────────────────────────────
QEMU_CMD+=(-nodefaults)
QEMU_CMD+=(-serial none -monitor none)
QEMU_CMD+=(-vga virtio)
QEMU_CMD+=(-display none)

# ── SMBIOS ───────────────────────────────────────────────────
QEMU_CMD+=(
    -global ICH9-LPC.disable_s3=1
    -global ICH9-LPC.disable_s4=1
    -smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640"
    -no-user-config
)

# ════════════════════════════════════════════════════════════════
#  KHỞI ĐỘNG VM
# ════════════════════════════════════════════════════════════════
spin_start "Khởi động VM ${WIN_NAME}..."

QEMU_LOG="/tmp/qemu-launch.log"
echo "QEMU CMD: ${QEMU_CMD[*]}" > "$QEMU_LOG"
nohup "${QEMU_CMD[@]}" >> "$QEMU_LOG" 2>&1 &
QEMU_PID=$!
disown "$QEMU_PID"

sleep 4
if kill -0 "$QEMU_PID" 2>/dev/null; then
    spin_stop "VM đã khởi động (PID: $QEMU_PID)"
else
    spin_fail "VM KHÔNG khởi động được!"
    echo -e "${R}═══ QEMU ERROR LOG ═══${W}"
    cat "$QEMU_LOG"
    echo -e "${R}═══════════════════════${W}"
    echo -e "${Y}Tip: Xem log đầy đủ tại $QEMU_LOG${W}"
    exit 1
fi

# ════════════════════════════════════════════════════════════════
#  TUNNEL RDP
# ════════════════════════════════════════════════════════════════
if [[ "$AUTO_RDP" == "1" ]]; then
    use_rdp="y"
    echo -e "${G}🤖 AUTO MODE — tự động mở tunnel RDP${W}"
else
    use_rdp=$(ask "🛰️  Mở port tunnel để kết nối RDP? (y/n): " "n")
fi

if [[ "$use_rdp" == "y" ]]; then
    spin_start "Cài tmux..."
    if [[ "$APT_OK" == "1" ]]; then
        silent $APT_CMD install -y tmux
    elif command -v conda &>/dev/null; then
        silent conda install -y -q tmux
    fi
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
    echo -e "${C}🚀 WINDOWS VM DEPLOYED SUCCESSFULLY  [v16]${W}"
    if [[ "$AUTO_MODE" == "1" ]]; then
        echo -e "${C}🤖 Launched via: --auto${AUTO_WIN:+ --win$AUTO_WIN}${AUTO_RDP:+ --rdp}${W}"
    fi
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "🪟 OS           : ${Y}$WIN_NAME${W}"
    echo -e "⚙  CPU Cores    : ${B}$cpu_core${W}"
    echo -e "💾 RAM          : ${B}${ram_size} GB${W}"
    if [[ "$KVM_AVAILABLE" == "1" ]]; then
        echo -e "⚡ Acceleration : ${G}KVM (hardware) + CPU host${W}"
    else
        echo -e "⚡ Acceleration : ${Y}TCG (software) | TB cache: ${TCG_TB_MB}MB${W}"
        echo -e "🧠 CPU Model    : ${B}${cpu_host}${W}"
    fi
    echo -e "${C}──────────────────────────────────────────────${W}"
    echo -e "📡 RDP Address  : ${G}${PUBLIC:-<chờ tunnel>}${W}"
    echo -e "👤 Username     : ${Y}$RDP_USER${W}"
    echo -e "🔑 Password     : ${Y}$RDP_PASS${W}"
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "${G}🟢 Status       : RUNNING${W}"
    echo "⏱  GUI Mode     : Headless / RDP"
    echo -e "${C}══════════════════════════════════════════════${W}"
else
    # Hiển thị summary dù không mở tunnel
    echo ""
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "${C}🚀 WINDOWS VM DEPLOYED SUCCESSFULLY  [v16]${W}"
    if [[ "$AUTO_MODE" == "1" ]]; then
        echo -e "${C}🤖 Launched via: --auto${AUTO_WIN:+ --win$AUTO_WIN}${W}"
    fi
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "🪟 OS           : ${Y}$WIN_NAME${W}"
    echo -e "⚙  CPU Cores    : ${B}$cpu_core${W}"
    echo -e "💾 RAM          : ${B}${ram_size} GB${W}"
    if [[ "$KVM_AVAILABLE" == "1" ]]; then
        echo -e "⚡ Acceleration : ${G}KVM (hardware) + CPU host${W}"
    else
        echo -e "⚡ Acceleration : ${Y}TCG (software) | TB cache: ${TCG_TB_MB}MB${W}"
        echo -e "🧠 CPU Model    : ${B}${cpu_host}${W}"
    fi
    echo -e "${C}──────────────────────────────────────────────${W}"
    echo -e "📡 RDP (local)  : ${G}localhost:3389${W}"
    echo -e "👤 Username     : ${Y}$RDP_USER${W}"
    echo -e "🔑 Password     : ${Y}$RDP_PASS${W}"
    echo -e "${C}══════════════════════════════════════════════${W}"
    echo -e "${G}🟢 Status       : RUNNING (PID: $QEMU_PID)${W}"
    echo "⏱  GUI Mode     : Headless / RDP"
    echo -e "${C}══════════════════════════════════════════════${W}"
fi
