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
#  BUILD QEMU  (y chang v3)
# ════════════════════════════════════════════════════════════════
choice=$(ask "👉 Bạn có muốn build QEMU để tạo VM với tăng tốc LLVM không ? (y/n): " "n")

if [[ "$choice" == "y" ]]; then
    if [[ "$NO_ROOT" == "1" ]]; then
        build_qemu_noroot || die "Build QEMU no-root thất bại"
    elif [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
        echo "⚡ QEMU ULTRA đã tồn tại — skip build"
        export PATH="/opt/qemu-optimized/bin:$PATH"
    else
        echo "🚀 Đang Tải Các Apt Cần Thiết..."

        OS_ID="$(. /etc/os-release && echo "$ID")"
        OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

        spin_start "apt update + cài gói..."
        priv apt-get update -qq >/dev/null 2>&1 || true
        priv apt-get install -y -qq wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf >/dev/null 2>&1 || true
        spin_stop "Cài gói xong"

        if [[ "$OS_ID" == "ubuntu" ]]; then
            echo "🔥 Detect Ubuntu → Cài LLVM 21 từ apt.llvm.org"
            wget -q https://apt.llvm.org/llvm.sh -O /tmp/llvm.sh
            chmod +x /tmp/llvm.sh
            priv /tmp/llvm.sh 21
            LLVM_VER=21
        else
            if [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
                LLVM_VER=19
            else
                LLVM_VER=15
            fi
            priv apt-get install -y -qq clang-${LLVM_VER} lld-${LLVM_VER} llvm-${LLVM_VER} llvm-${LLVM_VER}-dev llvm-${LLVM_VER}-tools >/dev/null 2>&1 || true
        fi

        export PATH="/usr/lib/llvm-${LLVM_VER}/bin:$PATH"
        export CC="clang-${LLVM_VER}"
        export CXX="clang++-${LLVM_VER}"
        export LD="lld-${LLVM_VER}"

        python3 -m venv ~/qemu-env
        source ~/qemu-env/bin/activate
        pip install --upgrade pip tomli packaging >/dev/null 2>&1

        spin_start "Tải QEMU v11.0.0..."
        rm -rf /tmp/qemu-src /tmp/qemu-build
        cd /tmp
        git clone -q --depth 1 --branch v11.0.0 https://gitlab.com/qemu-project/qemu.git qemu-src 2>/dev/null \
            || { spin_fail "Clone QEMU thất bại"; die "Không clone được QEMU"; }
        mkdir -p /tmp/qemu-build
        cd /tmp/qemu-build
        spin_stop "Tải QEMU xong"

        EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -ffast-math -fuse-ld=lld -fno-rtti -fno-exceptions -fmerge-all-constants -fno-semantic-interposition -fno-plt -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector -funsafe-math-optimizations -ffinite-math-only -fno-math-errno -fstrict-aliasing -funroll-loops -finline-functions -finline-hint-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=3097152"
        LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"

        echo "🔁 Đang Biên Dịch..."
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
            CC="$CC" CXX="$CXX" LD="$LD" CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS" \
            >/tmp/qemu-configure.log 2>&1 \
            || { cat /tmp/qemu-configure.log >&2; die "QEMU configure lỗi — xem log trên"; }

        echo "🕧 QEMU đang được build vui lòng đợi..."
        echo "💣 Nếu trong quá trình build bị lỗi hãy thử ulimit -n 84857"
        ulimit -n 84857 2>/dev/null || true
        ninja -j"$(nproc)" >/tmp/qemu-build.log 2>&1 \
            || { tail -30 /tmp/qemu-build.log >&2; die "ninja build lỗi"; }
        priv ninja install >/dev/null 2>&1 \
            || die "ninja install lỗi"

        export PATH="/opt/qemu-optimized/bin:$PATH"
        qemu-system-x86_64 --version
        echo "🔥 QEMU LLVM đã build xong"
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
detect_hugepage

TCG_TB_MB=$ram_size
[ "$TCG_TB_MB" -lt 1 ] && TCG_TB_MB=1
[ "$TCG_TB_MB" -gt 4 ] && TCG_TB_MB=4
TCG_TB_BYTES=$(( TCG_TB_MB * 1024 * 1024 ))
echo "⚡ TCG TB: ${TCG_TB_MB}MB"

detect_cpu_flags
CPU_MODEL="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${CPU_HOST_MODEL}"

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
echo "════════════════════════════════════"
echo "🖥️  WINDOWS VM MANAGER  v8"
echo "════════════════════════════════════"
echo "1️⃣  Tạo Windows VM"
echo "2️⃣  Quản Lý Windows VM"
echo "════════════════════════════════════"
read -rp "👉 Nhập lựa chọn [1-2]: " main_choice

case "$main_choice" in
2)
    echo ""
    echo -e "\033[1;36m🚀 ===== MANAGE RUNNING VM ===== 🚀\033[0m"

    if pgrep -f 'qemu-system-x86_64' >/dev/null; then
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
            vcpu=$(sed -n 's/.*-smp \([^ ,]*\).*/\1/p' <<< "$cmd")
            ram=$(sed -n 's/.*-m \([^ ]*\).*/\1/p' <<< "$cmd")
            cpu=$(ps -p "$pid" -o %cpu=)
            mem=$(ps -p "$pid" -o %mem=)
            echo -e "🆔 PID: \033[1;33m$pid\033[0m  |  🔢 vCPU: \033[1;34m${vcpu}\033[0m  |  📦 VM RAM: \033[1;34m${ram}\033[0m  |  🧠 CPU: \033[1;32m${cpu}%\033[0m  |  💾 Host RAM: \033[1;35m${mem}%\033[0m"
        done < <(pgrep -f 'qemu-system-x86_64')
    else
        echo "❌ Không có VM nào đang chạy"
    fi

    echo -e "\033[1;36m==================================\033[0m"
    read -rp "🆔 Nhập PID VM muốn tắt (hoặc Enter để bỏ qua): " kill_pid
    if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
        kill "$kill_pid" 2>/dev/null || true
        echo "✅ Đã gửi tín hiệu tắt VM PID $kill_pid"
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
1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
2) WIN_NAME="Windows Server 2022";    WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img";   USE_UEFI="no" ;;
3) WIN_NAME="Windows 11 LTSB";        WIN_URL="https://archive.org/download/win_20260203/win.img";       USE_UEFI="yes" ;;
4) WIN_NAME="Windows 10 LTSB 2015";   WIN_URL="https://archive.org/download/win_20260208/win.img";       USE_UEFI="no" ;;
5) WIN_NAME="Windows 10 LTSC 2023";   WIN_URL="https://archive.org/download/win_20260215/win.img";       USE_UEFI="no" ;;
*) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
esac

case "$win_choice" in
3|4|5) RDP_USER="Admin";         RDP_PASS="Tam255Z" ;;
*)     RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
esac

echo "🪟 Đang tải $WIN_NAME..."
if [[ ! -f win.img ]]; then
    silent aria2c -x16 -s16 --continue --file-allocation=none "$WIN_URL" -o win.img
fi

read -rp "📦 Mở rộng đĩa thêm bao nhiêu GB (default 20)? " extra_gb
extra_gb="${extra_gb:-20}"
silent qemu-img resize win.img "+${extra_gb}G"

# ════════════════════════════════════════════════════════════════
#  CHẾ ĐỘ CẤU HÌNH VM: AUTO hoặc MANUAL (từ v7)
# ════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════"
echo "⚙  CHỌN CHẾ ĐỘ CẤU HÌNH VM"
echo "════════════════════════════════════"
echo "1️⃣  Auto cấu hình (khuyên dùng)"
echo "2️⃣  Tự chọn thủ công"
echo "════════════════════════════════════"
read -rp "👉 Nhập lựa chọn [1-2]: " cfg_mode

if [[ "$cfg_mode" == "1" ]]; then
    echo ""
    echo "🧠 AUTO DETECT HOST RESOURCE..."

    # --- AUTO DETECT CPU ---
    cpu_v=$(nproc 2>/dev/null)
    cpu_u=$cpu_v

    # Hỗ trợ cgroup v2 và v1
    if [ -f /sys/fs/cgroup/cpu.max ]; then
        IFS=" " read -r cq cp < /sys/fs/cgroup/cpu.max
        if [ "$cq" != "max" ] 2>/dev/null; then
            cpu_u=$(awk "BEGIN{printf \"%.0f\",$cq/$cp}")
        fi
    elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        cq=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        cp=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
        if [ "$cq" != "-1" ] 2>/dev/null; then
            cpu_u=$(awk "BEGIN{printf \"%.0f\",$cq/$cp}")
        fi
    fi

    [ "$cpu_u" -lt 1 ] && cpu_u=1

    # --- AUTO DETECT RAM ---
    mem_total_gb=$(awk '/MemTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo)
    mem_auto_gb=$(awk "BEGIN{printf \"%d\", ($mem_total_gb*0.85)+0.5}")

    echo "🖥️  CPU: thấy=${cpu_v} cores | usable=${cpu_u} cores"
    echo "💾 RAM: total=${mem_total_gb}GB | auto=${mem_auto_gb}GB"

    cpu_core=$cpu_u
    ram_size=$mem_auto_gb

    # Giới hạn an toàn
    [ "$ram_size" -lt 2 ]                   && ram_size=2
    [ "$cpu_core" -gt "$cpu_v" ]             && cpu_core=$cpu_v
    max_ram=$((mem_total_gb - 1))
    [ "$ram_size" -gt "$max_ram" ]           && ram_size=$max_ram

    echo ""
    echo "⚙  AUTO CONFIG:"
    echo "   CPU cores : $cpu_core"
    echo "   RAM       : ${ram_size} GB"
else
    echo ""
    read -rp "⚙  CPU core (default 4): " cpu_core
    cpu_core="${cpu_core:-4}"
    read -rp "💾 RAM GB (default 4): " ram_size
    ram_size="${ram_size:-4}"
fi

# --- AUTO DETECT HUGEPAGE (từ v7) ---
detect_hugepage

# --- AUTO TCG TB SIZE theo RAM VM (từ v7) ---
TCG_TB_MB=$((ram_size))
[ "$TCG_TB_MB" -lt 1 ] && TCG_TB_MB=1
[ "$TCG_TB_MB" -gt 4 ] && TCG_TB_MB=4
TCG_TB_BYTES=$((TCG_TB_MB * 1024 * 1024))
echo "⚡ TCG TB cache: ${TCG_TB_MB}MB (auto theo ${ram_size}GB RAM VM)"

# --- AUTO DETECT CPU FLAGS từ host (từ v7) ---
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

# --- Network device ---
if [[ "$win_choice" == "4" ]]; then
    NET_DEVICE="-device e1000e,netdev=n0"
else
    NET_DEVICE="-device virtio-net-pci,netdev=n0"
fi

# --- BIOS/UEFI ---
if [[ "$USE_UEFI" == "yes" ]]; then
    BIOS_OPT="-bios /usr/share/qemu/OVMF.fd"
else
    BIOS_OPT=""
fi

# ════════════════════════════════════════════════════════════════
#  KHỞI ĐỘNG VM (cấu trúc v3 stable + hugepage opt từ v7)
# ════════════════════════════════════════════════════════════════
echo "🚀 Đang khởi tạo VM..."

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

# ════════════════════════════════════════════════════════════════
#  MỞ PORT TUNNEL RDP
# ════════════════════════════════════════════════════════════════
use_rdp=$(ask "🛰️  Tiếp tục mở port để kết nối đến VM? (y/n): " "n")
echo "⌛ Đang tạo VM với cấu hình bạn đã nhập, vui lòng đợi..."

if [[ "$use_rdp" == "y" ]]; then
    silent wget https://github.com/kami2k1/tunnel/releases/latest/download/kami-tunnel-linux-amd64.tar.gz
    silent tar -xzf kami-tunnel-linux-amd64.tar.gz
    silent chmod +x kami-tunnel
    silent sudo apt install -y tmux

    tmux kill-session -t kami 2>/dev/null || true
    tmux new-session -d -s kami "./kami-tunnel 3389"
    sleep 4

    PUBLIC=$(tmux capture-pane -pt kami -p | sed 's/\x1b\[[0-9;]*m//g' | grep -i 'public' | grep -oE '[a-zA-Z0-9\.\-]+:[0-9]+' | head -n1)

    echo ""
    echo "══════════════════════════════════════════════"
    echo "🚀 WINDOWS VM DEPLOYED SUCCESSFULLY  [v8]"
    echo "══════════════════════════════════════════════"
    echo "🪟 OS           : $WIN_NAME"
    echo "⚙  CPU Cores    : $cpu_core"
    echo "💾 RAM          : ${ram_size} GB"
    echo "🧠 CPU Host     : $cpu_host"
    echo "⚡ TCG TB Cache  : ${TCG_TB_MB}MB"
    echo "📄 HugePages    : $HP_INFO"
    echo "──────────────────────────────────────────────"
    echo "📡 RDP Address  : $PUBLIC"
    echo "👤 Username     : $RDP_USER"
    echo "🔑 Password     : $RDP_PASS"
    echo "══════════════════════════════════════════════"
    echo "🟢 Status       : RUNNING"
    echo "⏱  GUI Mode     : Headless / RDP"
    echo "══════════════════════════════════════════════"
fi
