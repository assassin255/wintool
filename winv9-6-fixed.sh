#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
#  WINDOWS VM TOOL v9.3
#  Base: v9-2 + Fixed: thêm -vga virtio (headless vẫn cần VGA
#         để Windows boot hoàn toàn trước khi RDP sẵn sàng)
#       + Auto detect root/sudo, fallback build QEMU không root
# ════════════════════════════════════════════════════════════════

set -uo pipefail

# ── DETECT ROOT / SUDO / NO-ROOT ────────────────────────────────
# Thử apt-get update trực tiếp (root), rồi sudo, rồi no-root mode
NO_ROOT=0
_PRIV=""

_apt_probe() { apt-get update -qq >/dev/null 2>&1; }
_sapt_probe() { sudo apt-get update -qq >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ] && _apt_probe; then
    _PRIV=""           # đang là root, apt hoạt động
    echo "✅ Chạy với quyền root"
elif command -v sudo &>/dev/null && _sapt_probe; then
    _PRIV="sudo"       # sudo hoạt động
    echo "✅ Chạy qua sudo"
else
    NO_ROOT=1
    echo "⚠️  Không có root/sudo — dùng chế độ build không cần root (no-root)"
fi

priv() { ${_PRIV:+$_PRIV} "$@"; }

# ── SPINNER ──────────────────────────────────────────────────────
_SPIN_PID=""
spin_start() {
    local msg="${1:-Processing...}"
    local frames=('◜' '◝' '◞' '◟')
    (
        while :; do
            for f in "${frames[@]}"; do
                printf "\r\033[1;36m%s\033[0m %s  " "$f" "$msg"
                sleep 0.1
            done
        done
    ) &
    _SPIN_PID=$!
    disown "$_SPIN_PID" 2>/dev/null || true
}
spin_stop() {
    local msg="${1:-Done}"
    if [[ -n "$_SPIN_PID" ]]; then
        kill "$_SPIN_PID" 2>/dev/null || true
        wait "$_SPIN_PID" 2>/dev/null || true
        _SPIN_PID=""
    fi
    printf "\r\033[1;32m✔\033[0m %s          \n" "$msg"
}
spin_fail() {
    local msg="${1:-Failed}"
    if [[ -n "$_SPIN_PID" ]]; then
        kill "$_SPIN_PID" 2>/dev/null || true
        wait "$_SPIN_PID" 2>/dev/null || true
        _SPIN_PID=""
    fi
    printf "\r\033[1;31m✘\033[0m %s          \n" "$msg" >&2
}

# ── HÀM TIỆN ÍCH ────────────────────────────────────────────────
silent() { "$@" >/dev/null 2>&1; }
ask() {
    local prompt="$1" default="$2" ans
    read -rp "$prompt" ans
    ans="${ans,,}"
    echo "${ans:-$default}"
}
die() { spin_fail "$*"; echo "❌ $*" >&2; exit 1; }
ver_lt() { [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]; }

# ── DETECT HUGEPAGE ──────────────────────────────────────────────
detect_hugepage() {
    HUGEPAGE_OPT=""
    HP_INFO="none"
    local hp1g hp2m thp
    hp1g=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo 0)
    hp2m=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages   2>/dev/null || echo 0)
    thp=$(cat  /sys/kernel/mm/transparent_hugepage/enabled               2>/dev/null || echo never)
    echo "🔎 HugePages: 1GB=${hp1g}  2MB=${hp2m}  THP=${thp}"
    if [ "$hp1g" -gt 0 ] 2>/dev/null; then
        HUGEPAGE_OPT="-mem-prealloc -mem-path /dev/hugepages"
        HP_INFO="1GB hugepages (${hp1g} pages)"
        echo "✅ Dùng 1GB hugepages"
    elif [ "$hp2m" -gt 0 ] 2>/dev/null; then
        HUGEPAGE_OPT="-mem-prealloc -mem-path /dev/hugepages"
        HP_INFO="2MB hugepages (${hp2m} pages = $(( hp2m * 2 ))MB)"
        echo "✅ Dùng 2MB hugepages"
    elif echo "$thp" | grep -q '\[always\]\|\[madvise\]'; then
        HUGEPAGE_OPT="-mem-prealloc"
        HP_INFO="Transparent HugePages"
        echo "✅ THP có sẵn"
    else
        echo "ℹ️  Không có hugepage — chạy bình thường"
    fi
}

# ── DETECT RAM ───────────────────────────────────────────────────
detect_ram() {
    local proc_total_kb proc_avail_kb
    proc_total_kb=$(awk '/^MemTotal:/{print $2}'    /proc/meminfo 2>/dev/null || echo 0)
    proc_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    local cg_limit_bytes=0 cg_usage_bytes=0 cg_avail_bytes=0
    local cg2_max cg2_cur
    cg2_max=$(cat /sys/fs/cgroup/memory.max     2>/dev/null || echo "max")
    cg2_cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo "0")
    if [[ "$cg2_max" != "max" && "$cg2_max" =~ ^[0-9]+$ ]]; then
        cg_limit_bytes=$cg2_max; cg_usage_bytes=${cg2_cur:-0}
    fi
    if [[ "$cg_limit_bytes" -eq 0 ]]; then
        local cg1_lim cg1_use
        cg1_lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)
        cg1_use=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
        if [[ "$cg1_lim" =~ ^[0-9]+$ && "$cg1_lim" -lt 9000000000000 ]]; then
            cg_limit_bytes=$cg1_lim; cg_usage_bytes=$cg1_use
        fi
    fi
    local total_kb avail_kb
    if [[ "$cg_limit_bytes" -gt 0 ]]; then
        total_kb=$(( cg_limit_bytes / 1024 ))
        cg_avail_bytes=$(( cg_limit_bytes - cg_usage_bytes ))
        [ "$cg_avail_bytes" -lt 0 ] && cg_avail_bytes=0
        avail_kb=$(( cg_avail_bytes / 1024 ))
        [ "$avail_kb" -gt "$proc_avail_kb" ] && avail_kb=$proc_avail_kb
        echo "🐳 Container RAM limit: $(( total_kb / 1024 / 1024 ))GB (cgroup)"
    else
        total_kb=$proc_total_kb; avail_kb=$proc_avail_kb
    fi
    local total_gb avail_gb auto_gb max_gb
    total_gb=$(( total_kb / 1024 / 1024 ))
    avail_gb=$(( avail_kb / 1024 / 1024 ))
    auto_gb=$(( avail_gb * 80 / 100 ))
    [ "$auto_gb" -lt 2 ] && auto_gb=2
    max_gb=$(( total_gb - 1 ))
    [ "$max_gb" -lt 2 ] && max_gb=2
    [ "$auto_gb" -gt "$max_gb" ] && auto_gb=$max_gb
    RAM_TOTAL_GB=$total_gb; RAM_AVAIL_GB=$avail_gb; RAM_AUTO_GB=$auto_gb
}

# ── DETECT CPU ───────────────────────────────────────────────────
detect_cpu() {
    local cpu_phys cpu_limit cq cp
    cpu_phys=$(nproc 2>/dev/null || echo 1)
    cpu_limit=$cpu_phys
    if [ -f /sys/fs/cgroup/cpu.max ]; then
        IFS=" " read -r cq cp < /sys/fs/cgroup/cpu.max 2>/dev/null || true
        if [ "${cq:-max}" != "max" ] && [ "${cp:-0}" -gt 0 ] 2>/dev/null; then
            cpu_limit=$(awk "BEGIN{n=int($cq/$cp); print (n<1)?1:n}")
        fi
    elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        cq=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo -1)
        cp=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || echo 100000)
        if [ "$cq" != "-1" ] && [ "${cp:-0}" -gt 0 ] 2>/dev/null; then
            cpu_limit=$(awk "BEGIN{n=int($cq/$cp); print (n<1)?1:n}")
        fi
    fi
    [ "$cpu_limit" -gt "$cpu_phys" ] && cpu_limit=$cpu_phys
    [ "$cpu_limit" -lt 1 ]           && cpu_limit=1
    CPU_PHYS=$cpu_phys; CPU_USABLE=$cpu_limit
}

# ── DETECT CPU FLAGS ─────────────────────────────────────────────
detect_cpu_flags() {
    local flags="" cpuflags
    cpuflags=$(grep -m1 "^flags" /proc/cpuinfo 2>/dev/null || echo "")
    echo "$cpuflags" | grep -qw "ssse3"  && flags="${flags},+ssse3"
    echo "$cpuflags" | grep -qw "sse4_1" && flags="${flags},+sse4.1"
    echo "$cpuflags" | grep -qw "sse4_2" && flags="${flags},+sse4.2"
    echo "$cpuflags" | grep -qw "rdtscp" && flags="${flags},+rdtscp"
    echo "$cpuflags" | grep -qw "avx"    && flags="${flags},+avx"
    echo "$cpuflags" | grep -qw "avx2"   && flags="${flags},+avx2"
    echo "$cpuflags" | grep -qw "popcnt" && flags="${flags},+popcnt"
    echo "$cpuflags" | grep -qw "aes"    && flags="${flags},+aes"
    CPU_EXTRA_FLAGS="$flags"
    CPU_HOST_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null \
        | sed 's/^.*: //' | tr ',' ' ' || echo "Unknown CPU")
}

# ── SETUP LLVM ───────────────────────────────────────────────────
setup_llvm() {
    local os_id="$1" os_ver="$2"
    CC="gcc"; CXX="g++"; LD=""; LLD_AVAILABLE=0; LLVM_VER=""
    local versions
    if   [[ "$os_id" == "ubuntu" ]];                          then versions=(21 20 19 18 17)
    elif [[ "$os_id" == "debian" && "$os_ver" == "13" ]];     then versions=(19 18 17)
    else                                                            versions=(17 16 15)
    fi
    local v
    for v in "${versions[@]}"; do
        if priv apt-get install -y -qq \
            "clang-${v}" "lld-${v}" "llvm-${v}" "llvm-${v}-dev" "llvm-${v}-tools" \
            >/dev/null 2>&1; then
            LLVM_VER="$v"; echo "✅ LLVM ${v} — apt thường"; break
        fi
    done
    if [[ -z "$LLVM_VER" ]]; then
        echo "📦 Thêm repo apt.llvm.org..."
        priv apt-get install -y -qq wget curl gnupg ca-certificates >/dev/null 2>&1 || true
        if command -v wget &>/dev/null; then
            wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key \
                | priv tee /etc/apt/trusted.gpg.d/llvm-snapshot.asc >/dev/null
        else
            curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key \
                | priv tee /etc/apt/trusted.gpg.d/llvm-snapshot.asc >/dev/null
        fi
        local codename
        codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}")
        for v in "${versions[@]}"; do
            echo "deb https://apt.llvm.org/${codename}/ llvm-toolchain-${codename}-${v} main" \
                | priv tee "/etc/apt/sources.list.d/llvm-${v}.list" >/dev/null
        done
        priv apt-get update -qq >/dev/null 2>&1 || true
        for v in "${versions[@]}"; do
            if priv apt-get install -y -qq \
                "clang-${v}" "lld-${v}" "llvm-${v}" "llvm-${v}-dev" "llvm-${v}-tools" \
                >/dev/null 2>&1; then
                LLVM_VER="$v"; echo "✅ LLVM ${v} — repo llvm.org"; break
            fi
        done
    fi
    if [[ -z "$LLVM_VER" ]]; then
        echo "⚠️  Fallback clang mặc định..."
        priv apt-get install -y -qq clang lld llvm >/dev/null 2>&1 || true
        if command -v clang &>/dev/null; then
            CC="clang"; CXX="clang++"
            if command -v lld &>/dev/null; then LD="lld"; LLD_AVAILABLE=1; fi
            echo "✅ clang mặc định"; return 0
        fi
    fi
    if [[ -z "$LLVM_VER" ]]; then
        echo "⚠️  Fallback gcc"
        CC="gcc"; CXX="g++"; LD=""; LLD_AVAILABLE=0; return 0
    fi
    export PATH="/usr/lib/llvm-${LLVM_VER}/bin:$PATH"
    CC="clang-${LLVM_VER}"; CXX="clang++-${LLVM_VER}"; LD="lld-${LLVM_VER}"; LLD_AVAILABLE=1
    echo "🔥 CC=$CC | LD=$LD"
}

# ── ENSURE GLIB ──────────────────────────────────────────────────
ensure_glib() {
    local meson_bin="${1:-meson}"
    local cur
    cur=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")
    if ver_lt "$cur" "2.66"; then
        echo "⚠️  glib ${cur} quá cũ → build 2.76.6..."
        priv apt-get install -y -qq libffi-dev gettext >/dev/null 2>&1 || true
        spin_start "Tải glib 2.76.6..."
        if command -v wget &>/dev/null; then
            wget -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz -O /tmp/glib-2.76.6.tar.xz \
                || { spin_fail "wget glib thất bại"; return 1; }
        else
            curl -fsSL https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz -o /tmp/glib-2.76.6.tar.xz \
                || { spin_fail "curl glib thất bại"; return 1; }
        fi
        spin_stop "Tải glib xong"
        cd /tmp && tar -xf glib-2.76.6.tar.xz && cd glib-2.76.6
        local GLIB_PREFIX="/opt/glib-local"
        mkdir -p "$GLIB_PREFIX"
        spin_start "Build glib..."
        "$meson_bin" setup build --prefix="$GLIB_PREFIX" --buildtype=release -Dtests=false >/dev/null 2>&1 \
            || { spin_fail "meson setup glib thất bại"; return 1; }
        ninja -C build -j"$(nproc)" >/dev/null 2>&1 \
            || { spin_fail "ninja build glib thất bại"; return 1; }
        priv ninja -C build install >/dev/null 2>&1 \
            || { spin_fail "ninja install glib thất bại"; return 1; }
        spin_stop "Build glib xong"
        cd /tmp
        local glib_pc_dirs=()
        for d in "${GLIB_PREFIX}/lib/x86_64-linux-gnu/pkgconfig" \
                  "${GLIB_PREFIX}/lib/pkgconfig" \
                  "${GLIB_PREFIX}/lib64/pkgconfig"; do
            [ -d "$d" ] && glib_pc_dirs+=("$d")
        done
        local pc_add; pc_add=$(IFS=:; echo "${glib_pc_dirs[*]}")
        export PKG_CONFIG_PATH="${pc_add}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        export LD_LIBRARY_PATH="${GLIB_PREFIX}/lib/x86_64-linux-gnu:${GLIB_PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export PATH="${GLIB_PREFIX}/bin:$PATH"
        echo "✅ glib $(pkg-config --modversion glib-2.0 2>/dev/null || echo 'installed')"
    else
        echo "✅ glib ${cur}"
    fi
}

# ════════════════════════════════════════════════════════════════
#  BUILD QEMU KHÔNG ROOT (no-root fallback)
#  Build toàn bộ dependency chain vào $HOME — không cần apt
# ════════════════════════════════════════════════════════════════
build_qemu_noroot() {
    local QEMU_BIN="$HOME/qemu-static/bin/qemu-system-x86_64"
    if [ -x "$QEMU_BIN" ]; then
        echo "⚡ QEMU no-root đã có — skip build"
        export PATH="$HOME/qemu-static/bin:$HOME/python-local/bin:$PATH"
        export LD_LIBRARY_PATH="$HOME/qemu-static/lib:$HOME/qemu-static/lib64:$HOME/qemu-static/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        return 0
    fi

    echo "🔨 Build QEMU no-root mode (build từ source, không cần root)..."
    echo "⏳ Quá trình này mất 20-60 phút tuỳ máy..."

    # ── Dọn và tạo thư mục ──────────────────────────────────────
    rm -rf "$HOME/python-local" "$HOME/qemu-static" "$HOME/qemu-build" "$HOME/certs"
    export PY_PREFIX="$HOME/python-local"
    export PREFIX="$HOME/qemu-static"
    export BUILD="$HOME/qemu-build"
    mkdir -p "$PY_PREFIX" "$PREFIX" "$BUILD" "$HOME/certs"

    # ── CA certs (wget/curl có thể bị lỗi SSL trong sandbox) ────
    spin_start "Tải CA certs..."
    cd "$HOME/certs"
    wget -q https://curl.se/ca/cacert.pem \
        || curl -fsSL https://curl.se/ca/cacert.pem -o cacert.pem \
        || { spin_fail "Không tải được cacert.pem"; return 1; }
    export SSL_CERT_FILE="$HOME/certs/cacert.pem"
    export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
    spin_stop "CA certs OK"

    # ── zlib (tĩnh, cần cho Python + QEMU) ──────────────────────
    spin_start "Build zlib..."
    cd "$BUILD"
    wget -c -qO- https://zlib.net/fossils/zlib-1.3.1.tar.gz | tar xz \
        || { spin_fail "Tải zlib thất bại"; return 1; }
    cd zlib-1.3.1
    CFLAGS="-fPIC" ./configure --prefix="$PREFIX" --static >/dev/null 2>&1 \
        && make -j"$(nproc)" install >/dev/null 2>&1 \
        || { spin_fail "Build zlib thất bại"; return 1; }
    spin_stop "zlib xong"

    # ── Python 3.12 (cần cho meson) ─────────────────────────────
    spin_start "Build Python 3.12 (lâu ~10 phút)..."
    cd "$HOME"
    wget -c -q https://www.python.org/ftp/python/3.12.2/Python-3.12.2.tar.xz \
        || { spin_fail "Tải Python thất bại"; return 1; }
    tar xf Python-3.12.2.tar.xz
    cd Python-3.12.2
    CPPFLAGS="-I${PREFIX}/include" LDFLAGS="-L${PREFIX}/lib64 -L${PREFIX}/lib" \
        ./configure --prefix="$PY_PREFIX" --with-ensurepip=install \
        >/dev/null 2>&1 \
        && make -j"$(nproc)" >/dev/null 2>&1 \
        && make install >/dev/null 2>&1 \
        || { spin_fail "Build Python thất bại"; return 1; }
    spin_stop "Python xong"

    export PATH="$PY_PREFIX/bin:$HOME/.local/bin:$PREFIX/bin:$PATH"

    spin_start "Cài meson/ninja vào Python local..."
    "$PY_PREFIX/bin/python3" -m pip install --quiet --upgrade \
        pip setuptools wheel packaging meson ninja truststore \
        >/dev/null 2>&1 \
        || { spin_fail "pip install thất bại"; return 1; }
    spin_stop "meson/ninja OK"

    # ── pixman ───────────────────────────────────────────────────
    spin_start "Build pixman..."
    cd "$BUILD"
    wget -c -qO- https://cairographics.org/releases/pixman-0.43.4.tar.gz | tar xz \
        || { spin_fail "Tải pixman thất bại"; return 1; }
    cd pixman-0.43.4
    meson setup build --prefix="$PREFIX" --default-library=static \
        -Dtests=disabled >/dev/null 2>&1 \
        && ninja -C build install >/dev/null 2>&1 \
        || { spin_fail "Build pixman thất bại"; return 1; }
    spin_stop "pixman xong"

    # ── libffi ───────────────────────────────────────────────────
    spin_start "Build libffi..."
    cd "$BUILD"
    wget -c -qO- https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz | tar xz \
        || { spin_fail "Tải libffi thất bại"; return 1; }
    cd libffi-3.4.6
    CFLAGS="-fPIC" ./configure --prefix="$PREFIX" \
        --enable-static --disable-shared --with-pic >/dev/null 2>&1 \
        && make -j"$(nproc)" install >/dev/null 2>&1 \
        || { spin_fail "Build libffi thất bại"; return 1; }
    spin_stop "libffi xong"

    # ── pcre2 ────────────────────────────────────────────────────
    spin_start "Build pcre2..."
    cd "$BUILD"
    wget -c -qO- https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz | tar xz \
        || { spin_fail "Tải pcre2 thất bại"; return 1; }
    cd pcre2-10.44
    CFLAGS="-fPIC" ./configure --prefix="$PREFIX" \
        --enable-static --disable-shared --with-pic >/dev/null 2>&1 \
        && make -j"$(nproc)" install >/dev/null 2>&1 \
        || { spin_fail "Build pcre2 thất bại"; return 1; }
    spin_stop "pcre2 xong"

    # ── glib 2.80 ────────────────────────────────────────────────
    spin_start "Build glib 2.80..."
    cd "$BUILD"
    wget -c -qO- https://download.gnome.org/sources/glib/2.80/glib-2.80.0.tar.xz | tar xJ \
        || { spin_fail "Tải glib thất bại"; return 1; }
    cd glib-2.80.0
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    meson setup build --prefix="$PREFIX" --default-library=static \
        -Dtests=false -Dselinux=disabled -Dlibmount=disabled -Dsysprof=disabled \
        >/dev/null 2>&1 \
        && ninja -C build install >/dev/null 2>&1 \
        || { spin_fail "Build glib thất bại"; return 1; }
    spin_stop "glib xong"

    # ── QEMU 11.0.0-rc3 ─────────────────────────────────────────
    spin_start "Tải QEMU 11.0.0-rc3..."
    cd "$BUILD"
    wget -c -qO- https://download.qemu.org/qemu-11.0.0-rc3.tar.xz | tar xJ \
        || { spin_fail "Tải QEMU source thất bại"; return 1; }
    spin_stop "Tải QEMU source xong"

    cd "$BUILD/qemu-11.0.0-rc3"

    # libslirp (subproject)
    spin_start "Clone libslirp..."
    mkdir -p subprojects
    git clone -q https://gitlab.freedesktop.org/slirp/libslirp.git subprojects/libslirp \
        || { spin_fail "Clone libslirp thất bại"; return 1; }
    spin_stop "libslirp OK"

    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

    spin_start "Configure QEMU no-root..."
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
        --disable-vnc \
        --disable-libusb \
        --disable-capstone \
        --extra-cflags="-I${PREFIX}/include" \
        --extra-ldflags="-L${PREFIX}/lib64 -L${PREFIX}/lib" \
        >/tmp/qemu-noroot-configure.log 2>&1 \
        || { spin_fail "Configure QEMU no-root thất bại"
             tail -20 /tmp/qemu-noroot-configure.log >&2
             return 1; }
    spin_stop "Configure xong"

    spin_start "Build QEMU no-root (có thể mất 20-40 phút)..."
    make -j"$(nproc)" >/tmp/qemu-noroot-build.log 2>&1 \
        || { spin_fail "Build QEMU thất bại"
             tail -30 /tmp/qemu-noroot-build.log >&2
             return 1; }
    make install >/dev/null 2>&1 \
        || { spin_fail "Install QEMU thất bại"; return 1; }
    strip "$PREFIX/bin/qemu-system-x86_64" 2>/dev/null || true
    spin_stop "Build QEMU no-root xong"

    export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:$PREFIX/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    echo "🔥 QEMU no-root: $("$QEMU_BIN" --version 2>/dev/null | head -1)"
}

# ════════════════════════════════════════════════════════════════
#  BUILD QEMU
# ════════════════════════════════════════════════════════════════
choice=$(ask "👉 Build QEMU tối ưu LLVM? (y/n): " "n")

if [[ "$choice" == "y" ]]; then
    # ── No-root: bỏ qua apt, build toàn bộ từ source ────────────
    if [[ "$NO_ROOT" == "1" ]]; then
        build_qemu_noroot || die "Build QEMU no-root thất bại"
    elif [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then  # không no-root
        echo "⚡ QEMU đã có — skip build"
        export PATH="/opt/qemu-optimized/bin:$PATH"
    else
        echo ""
        echo "🚀 Build QEMU bắt đầu..."
        OS_ID="$(. /etc/os-release && echo "$ID")"
        OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

        spin_start "Cài gói cơ bản..."
        priv apt-get update -qq >/dev/null 2>&1 || true
        priv apt-get install -y -qq \
            wget curl gnupg ca-certificates build-essential ninja-build git \
            python3 python3-venv python3-pip \
            libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev \
            pkg-config aria2 ovmf >/dev/null 2>&1 || true
        priv apt-get install -y -qq meson >/dev/null 2>&1 || true
        spin_stop "Cài gói xong"

        echo "🔎 Thiết lập compiler LLVM..."
        setup_llvm "$OS_ID" "$OS_VER"
        export CC CXX

        echo "🐍 Python venv + meson..."
        python3 -m venv ~/qemu-env
        source ~/qemu-env/bin/activate
        spin_start "Cài meson/ninja trong venv..."
        pip install -q --upgrade pip >/dev/null 2>&1
        pip install -q meson ninja tomli packaging >/dev/null 2>&1
        spin_stop "Cài meson venv xong"
        VENV_MESON="$(command -v meson)"
        export MESON="$VENV_MESON"

        echo "🔎 Kiểm tra glib..."
        ensure_glib "$VENV_MESON"
        export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
        export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

        spin_start "Tải QEMU v11.0.0 (git clone)..."
        rm -rf /tmp/qemu-src /tmp/qemu-build
        git clone -q --depth 1 --branch v11.0.0 \
            https://gitlab.com/qemu-project/qemu.git /tmp/qemu-src 2>/dev/null \
            || { spin_fail "Clone QEMU thất bại"; die "Không clone được QEMU"; }
        spin_stop "Tải QEMU xong"

        mkdir -p /tmp/qemu-build && cd /tmp/qemu-build

        if [[ "$LLD_AVAILABLE" == "1" ]]; then
            OPT_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full \
-ffast-math -fuse-ld=lld -fno-rtti -fno-exceptions \
-fmerge-all-constants -fno-semantic-interposition -fno-plt \
-fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables \
-fno-stack-protector -funsafe-math-optimizations -ffinite-math-only \
-fno-math-errno -fstrict-aliasing -funroll-loops -finline-functions \
-finline-hint-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=3097152"
            OPT_LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"
            LTO_FLAG="--enable-lto"
            echo "✅ Build: Ofast + LTO + lld"
        else
            OPT_CFLAGS="-O2 -march=native -mtune=native -pipe \
-fmerge-all-constants -fno-semantic-interposition \
-fomit-frame-pointer -fstrict-aliasing \
-DDEFAULT_TCG_TB_SIZE=3097152"
            OPT_LDFLAGS="-Wl,-O2"
            LTO_FLAG=""
            echo "⚠️  Build: O2 (không có lld)"
        fi

        : "${CC:=gcc}"; : "${CXX:=g++}"; : "${LD:=ld}"
        spin_start "Configure QEMU..."
        CC="$CC" CXX="$CXX" LD="$LD" \
        CFLAGS="$OPT_CFLAGS" CXXFLAGS="$OPT_CFLAGS" LDFLAGS="$OPT_LDFLAGS" \
        /tmp/qemu-src/configure \
            --prefix=/opt/qemu-optimized \
            --target-list=x86_64-softmmu \
            --enable-tcg \
            --enable-slirp \
            ${LTO_FLAG:+$LTO_FLAG} \
            --enable-coroutine-pool \
            --disable-kvm \
            --disable-mshv \
            --disable-debug-info \
            --disable-xen \
            --disable-gtk \
            --disable-sdl \
            --disable-spice \
            --disable-vnc \
            --disable-plugins \
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
            >/tmp/qemu-configure.log 2>&1 \
            || { spin_fail "Configure thất bại"; cat /tmp/qemu-configure.log >&2; die "QEMU configure lỗi — xem log trên"; }
        spin_stop "Configure xong"

        spin_start "Build QEMU (có thể mất 10-30 phút)..."
        ulimit -n 65535 2>/dev/null || true
        ninja -j"$(nproc)" qemu-system-x86_64 qemu-img \
            >/tmp/qemu-build.log 2>&1 \
            || { spin_fail "Build QEMU thất bại"; tail -30 /tmp/qemu-build.log >&2; die "ninja build lỗi"; }
        spin_stop "Build QEMU xong"

        spin_start "Cài QEMU vào /opt/qemu-optimized..."
        priv ninja install >/dev/null 2>&1 \
            || { spin_fail "Install thất bại"; die "ninja install lỗi"; }
        spin_stop "Cài xong"

        export PATH="/opt/qemu-optimized/bin:$PATH"
        qemu-system-x86_64 --version
        echo "🔥 Build xong!"
    fi
else
    echo "⚡ Bỏ qua build QEMU."
fi

# ── Đảm bảo PATH cho cả 2 mode ──────────────────────────────────
[ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ] && \
    export PATH="/opt/qemu-optimized/bin:$PATH"
[ -x "$HOME/qemu-static/bin/qemu-system-x86_64" ] && \
    export PATH="$HOME/qemu-static/bin:$HOME/python-local/bin:$PATH"

command -v qemu-system-x86_64 >/dev/null 2>&1 || \
    die "Không tìm thấy qemu-system-x86_64. Build QEMU hoặc: apt install qemu-system-x86"
command -v qemu-img >/dev/null 2>&1 || \
    die "Không tìm thấy qemu-img. Cần cài qemu-utils."

# ════════════════════════════════════════════════════════════════
#  MENU CHÍNH
# ════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════"
echo "🖥️  WINDOWS VM MANAGER  [v9.3]"
echo "════════════════════════════════════"
echo "1️⃣  Tạo Windows VM"
echo "2️⃣  Quản lý VM đang chạy"
echo "════════════════════════════════════"
read -rp "👉 [1-2]: " main_choice

if [[ "$main_choice" == "2" ]]; then
    echo ""
    echo -e "\033[1;36m🚀 ===== RUNNING VMs =====\033[0m"
    found=0
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        found=1
        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
        vcpu=$(echo "$cmd" | grep -oP '(?<=-smp )\S+' | head -1 || echo "?")
        ram=$(echo  "$cmd" | grep -oP '(?<=-m )\S+'   | head -1 || echo "?")
        pcpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "?")
        pmem=$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ' || echo "?")
        echo -e "🆔 PID:\033[1;33m${pid}\033[0m  vCPU:\033[1;34m${vcpu}\033[0m  RAM:\033[1;34m${ram}\033[0m  CPU%:\033[1;32m${pcpu}\033[0m  MEM%:\033[1;35m${pmem}\033[0m"
    done < <(pgrep -f 'qemu-system-x86_64' 2>/dev/null || true)
    [ "$found" -eq 0 ] && echo "❌ Không có VM nào đang chạy"
    echo -e "\033[1;36m══════════════════════════════\033[0m"
    read -rp "🆔 PID muốn tắt (Enter bỏ qua): " kill_pid
    if [[ -n "$kill_pid" && "$kill_pid" =~ ^[0-9]+$ && -d "/proc/$kill_pid" ]]; then
        kill "$kill_pid" 2>/dev/null && echo "✅ Đã tắt VM PID $kill_pid" || echo "⚠️  Không tắt được"
    fi
    exit 0
fi

# ════════════════════════════════════════════════════════════════
#  CHỌN WINDOWS
# ════════════════════════════════════════════════════════════════
echo ""
echo "🪟 Chọn phiên bản Windows:"
echo "1️⃣  Windows Server 2012 R2 x64"
echo "2️⃣  Windows Server 2022 x64"
echo "3️⃣  Windows 11 LTSB x64"
echo "4️⃣  Windows 10 LTSB 2015 x64"
echo "5️⃣  Windows 10 LTSC 2023 x64"
read -rp "👉 [1-5]: " win_choice

case "$win_choice" in
    1) WIN_NAME="Windows Server 2012 R2"
       WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"
       USE_UEFI="no"  NET_DEV="virtio" ;;
    2) WIN_NAME="Windows Server 2022"
       WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img"
       USE_UEFI="no"  NET_DEV="virtio" ;;
    3) WIN_NAME="Windows 11 LTSB"
       WIN_URL="https://archive.org/download/win_20260203/win.img"
       USE_UEFI="yes" NET_DEV="virtio" ;;
    4) WIN_NAME="Windows 10 LTSB 2015"
       WIN_URL="https://archive.org/download/win_20260208/win.img"
       USE_UEFI="no"  NET_DEV="e1000e" ;;
    5) WIN_NAME="Windows 10 LTSC 2023"
       WIN_URL="https://archive.org/download/win_20260215/win.img"
       USE_UEFI="no"  NET_DEV="virtio" ;;
    *) WIN_NAME="Windows Server 2012 R2"
       WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"
       USE_UEFI="no"  NET_DEV="virtio" ;;
esac

case "$win_choice" in
    3|4|5) RDP_USER="Admin";         RDP_PASS="Tam255Z" ;;
    *)     RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
esac

if [[ ! -f win.img ]]; then
    spin_start "Đang tải $WIN_NAME (aria2c)..."
    aria2c -x16 -s16 --continue --file-allocation=none \
        --console-log-level=error --summary-interval=0 \
        "$WIN_URL" -o win.img \
        || { spin_fail "Tải image thất bại"; die "Tải image thất bại"; }
    spin_stop "Tải $WIN_NAME xong"
else
    echo "✅ win.img đã có — bỏ qua tải"
fi

read -rp "📦 Mở rộng đĩa thêm bao nhiêu GB (default 20)? " extra_gb
extra_gb="${extra_gb:-20}"
if [[ "$extra_gb" =~ ^[0-9]+$ ]] && [ "$extra_gb" -gt 0 ]; then
    qemu-img resize win.img "+${extra_gb}G" >/dev/null
    echo "✅ Mở rộng +${extra_gb}GB"
fi

# ════════════════════════════════════════════════════════════════
#  CẤU HÌNH VM
# ════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════"
echo "⚙  CHẾ ĐỘ CẤU HÌNH VM"
echo "════════════════════════════════════"
echo "1️⃣  Auto (khuyên dùng)"
echo "2️⃣  Thủ công"
echo "════════════════════════════════════"
read -rp "👉 [1-2]: " cfg_mode

if [[ "$cfg_mode" == "1" ]]; then
    echo "🧠 Auto detect..."
    detect_cpu; detect_ram
    echo "🖥️  CPU: ${CPU_PHYS} physical | ${CPU_USABLE} usable"
    echo "💾 RAM: total=${RAM_TOTAL_GB}GB | available=${RAM_AVAIL_GB}GB | auto=${RAM_AUTO_GB}GB"
    cpu_core=$CPU_USABLE
    ram_size=$RAM_AUTO_GB
    echo "⚙  Auto: CPU=${cpu_core} | RAM=${ram_size}GB"
else
    read -rp "⚙  CPU cores (default 4): " cpu_core
    cpu_core="${cpu_core:-4}"
    [[ "$cpu_core" =~ ^[0-9]+$ ]] || cpu_core=4
    [ "$cpu_core" -lt 1 ] && cpu_core=1
    read -rp "💾 RAM GB (default 4): " ram_size
    ram_size="${ram_size:-4}"
    [[ "$ram_size" =~ ^[0-9]+$ ]] || ram_size=4
    [ "$ram_size" -lt 1 ] && ram_size=1
fi

detect_hugepage

TCG_TB_MB=$ram_size
[ "$TCG_TB_MB" -lt 1 ] && TCG_TB_MB=1
[ "$TCG_TB_MB" -gt 4 ] && TCG_TB_MB=4
TCG_TB_BYTES=$(( TCG_TB_MB * 1024 * 1024 ))
echo "⚡ TCG TB: ${TCG_TB_MB}MB"

detect_cpu_flags
CPU_MODEL="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse${CPU_EXTRA_FLAGS},model-id=${CPU_HOST_MODEL}"

case "$NET_DEV" in
    e1000e) NET_DEVICE="-device e1000e,netdev=n0" ;;
    *)      NET_DEVICE="-device virtio-net-pci,netdev=n0" ;;
esac

BIOS_OPT=""
if [[ "$USE_UEFI" == "yes" ]]; then
    for f in /usr/share/qemu/OVMF.fd \
              /usr/share/ovmf/OVMF.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd; do
        if [ -f "$f" ]; then
            BIOS_OPT="-bios $f"; echo "✅ UEFI: $f"; break
        fi
    done
    [ -z "$BIOS_OPT" ] && echo "⚠️  Không tìm thấy OVMF — bỏ UEFI"
fi

# ════════════════════════════════════════════════════════════════
#  KHỞI ĐỘNG VM
# ════════════════════════════════════════════════════════════════
echo ""
echo "🚀 Khởi động VM..."

# BUG FIX 1: Kill VM cũ đang dùng win.img hoặc port 3389 trước khi launch mới
#            Tránh lỗi "Failed to get write lock" và "Could not set up hostfwd"
_old_pids=$(pgrep -f "qemu-system-x86_64.*win\.img" 2>/dev/null || true)
if [[ -n "$_old_pids" ]]; then
    echo "⚠️  Phát hiện VM cũ đang dùng win.img — đang tắt..."
    echo "$_old_pids" | xargs -r kill 2>/dev/null || true
    sleep 2
    # Force kill nếu vẫn còn
    echo "$_old_pids" | xargs -r kill -9 2>/dev/null || true
    sleep 1
fi

QEMU_START_LOG=$(mktemp /tmp/qemu-start-XXXXXX.log)

qemu-system-x86_64 \
    -machine q35,hpet=off \
    -cpu "$CPU_MODEL" \
    -smp "$cpu_core" \
    -m "${ram_size}G" \
    ${HUGEPAGE_OPT:+$HUGEPAGE_OPT} \
    -accel tcg,thread=multi,tb-size=${TCG_TB_BYTES} \
    -rtc base=localtime \
    ${BIOS_OPT:+$BIOS_OPT} \
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
    >"$QEMU_START_LOG" 2>&1
QEMU_EXIT=$?

if [ "$QEMU_EXIT" -ne 0 ]; then
    echo "❌ QEMU khởi động thất bại (exit $QEMU_EXIT):"
    cat "$QEMU_START_LOG" >&2
    rm -f "$QEMU_START_LOG"
    exit 1
fi
rm -f "$QEMU_START_LOG"

spin_start "Chờ VM khởi động..."
sleep 5
spin_stop "VM khởi động xong"

# BUG FIX 2: kiểm tra VM thực sự đang chạy bằng cách tìm PID live,
#            loại bỏ zombie (stat Z) — pgrep -f rộng quá bắt cả defunct
_vm_pid=$(pgrep -f "qemu-system-x86_64.*win\.img" 2>/dev/null | while read -r p; do
    [[ "$(cat /proc/$p/status 2>/dev/null | awk '/^State:/{print $2}')" != "Z" ]] && echo "$p"
done | head -1)

if [[ -n "$_vm_pid" ]]; then
    echo "✅ VM đang chạy (PID: $_vm_pid)"
else
    echo "⚠️  VM chưa chạy — kiểm tra lại cấu hình"
fi

# ════════════════════════════════════════════════════════════════
#  TUNNEL RDP
# ════════════════════════════════════════════════════════════════
use_rdp=$(ask "🛰️  Mở tunnel RDP? (y/n): " "n")

if [[ "$use_rdp" == "y" ]]; then
    spin_start "Cài tmux..."
    priv apt-get install -y -qq tmux >/dev/null 2>&1 || true
    spin_stop "tmux sẵn sàng"

    if [[ ! -f ./kami-tunnel ]]; then
        spin_start "Tải kami-tunnel..."
        local_tag=$(curl -fsSL "https://api.github.com/repos/kami2k1/tunnel/releases/latest" \
            2>/dev/null | grep '"tag_name"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        local_tag="${local_tag:-3.0.3}"
        kami_url="https://github.com/kami2k1/tunnel/releases/download/${local_tag}/kami-tunnel-linux-amd64.tar.gz"
        if command -v wget &>/dev/null; then
            wget -q -O /tmp/kami.tar.gz "$kami_url" \
                || { spin_fail "Tải kami-tunnel thất bại"; die "Không tải được kami-tunnel"; }
        else
            curl -fsSL -o /tmp/kami.tar.gz "$kami_url" \
                || { spin_fail "Tải kami-tunnel thất bại"; die "Không tải được kami-tunnel"; }
        fi
        tar -xzf /tmp/kami.tar.gz -C . 2>/dev/null \
            || tar -xzf /tmp/kami.tar.gz 2>/dev/null || true
        chmod +x ./kami-tunnel 2>/dev/null || true
        spin_stop "Tải kami-tunnel xong (v${local_tag})"
    else
        echo "✅ kami-tunnel đã có"
    fi

    tmux kill-session -t kami 2>/dev/null || true
    tmux new-session -d -s kami "./kami-tunnel -target 127.0.0.1:3389"

    spin_start "Chờ tunnel kết nối..."
    PUBLIC=""
    for _i in $(seq 1 25); do
        sleep 1
        PUBLIC=$(tmux capture-pane -p -t kami 2>/dev/null \
            | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
            | grep -i 'Public:' \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' \
            | head -1 || true)
        [[ -n "$PUBLIC" ]] && break
    done
    spin_stop "Tunnel sẵn sàng"
    [[ -z "$PUBLIC" ]] && PUBLIC="chưa lấy được — chạy: tmux attach -t kami"

    echo ""
    echo "══════════════════════════════════════════════"
    echo "🚀 WINDOWS VM DEPLOYED  [v9.3]"
    echo "══════════════════════════════════════════════"
    printf "🪟 OS           : %s\n"   "$WIN_NAME"
    printf "⚙  CPU Cores    : %s\n"   "$cpu_core"
    printf "💾 RAM          : %sGB\n" "$ram_size"
    printf "🧠 CPU Host     : %s\n"   "$CPU_HOST_MODEL"
    printf "⚡ TCG TB Cache  : %sMB\n" "$TCG_TB_MB"
    printf "📄 HugePages    : %s\n"   "$HP_INFO"
    echo "──────────────────────────────────────────────"
    printf "📡 RDP Address  : %s\n"   "$PUBLIC"
    printf "👤 Username     : %s\n"   "$RDP_USER"
    printf "🔑 Password     : %s\n"   "$RDP_PASS"
    echo "══════════════════════════════════════════════"
    echo "🟢 Status       : RUNNING  |  Headless / RDP"
    echo "══════════════════════════════════════════════"
fi
