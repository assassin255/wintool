#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
#  WINDOWS VM TOOL v8.5
#  Base: v8-4 + Fixed: meson/venv order, set -e safety, spinner
# ════════════════════════════════════════════════════════════════

# ── set -e chỉ bật sau khi setup xong để tránh abort sớm ────────
set -uo pipefail

# ── HELPER: chạy lệnh với quyền cao (sudo nếu có, không thì trực tiếp nếu root) ─
_PRIV=""
if command -v sudo &>/dev/null; then
    _PRIV="sudo"
elif [ "$(id -u)" -eq 0 ]; then
    _PRIV=""   # đang là root, không cần sudo
else
    echo "⚠️  Không có sudo và không phải root — một số bước có thể thất bại" >&2
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

die() {
    spin_fail "$*"
    echo "❌ $*" >&2
    exit 1
}

ver_lt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

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

# ── DETECT RAM (ưu tiên cgroup limit trong container) ────────────
detect_ram() {
    local proc_total_kb proc_avail_kb
    proc_total_kb=$(awk '/^MemTotal:/{print $2}'    /proc/meminfo 2>/dev/null || echo 0)
    proc_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)

    # ── Đọc giới hạn cgroup (bytes) ──────────────────────────────
    local cg_limit_bytes=0 cg_usage_bytes=0 cg_avail_bytes=0

    # cgroup v2
    local cg2_max cg2_cur
    cg2_max=$(cat /sys/fs/cgroup/memory.max     2>/dev/null || echo "max")
    cg2_cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo "0")
    if [[ "$cg2_max" != "max" && "$cg2_max" =~ ^[0-9]+$ ]]; then
        cg_limit_bytes=$cg2_max
        cg_usage_bytes=${cg2_cur:-0}
    fi

    # cgroup v1 (nếu v2 không có)
    if [[ "$cg_limit_bytes" -eq 0 ]]; then
        local cg1_lim cg1_use
        cg1_lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo 0)
        cg1_use=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0)
        # cgroup v1 trả về giá trị rất lớn (~2^63) nếu không có limit
        if [[ "$cg1_lim" =~ ^[0-9]+$ && "$cg1_lim" -lt 9000000000000 ]]; then
            cg_limit_bytes=$cg1_lim
            cg_usage_bytes=$cg1_use
        fi
    fi

    # ── Tính total / avail thực tế ───────────────────────────────
    local total_kb avail_kb
    if [[ "$cg_limit_bytes" -gt 0 ]]; then
        # Có cgroup limit → dùng làm total
        total_kb=$(( cg_limit_bytes / 1024 ))
        cg_avail_bytes=$(( cg_limit_bytes - cg_usage_bytes ))
        [ "$cg_avail_bytes" -lt 0 ] && cg_avail_bytes=0
        avail_kb=$(( cg_avail_bytes / 1024 ))
        # Không để avail vượt quá MemAvailable thật (kernel còn cần bộ nhớ)
        [ "$avail_kb" -gt "$proc_avail_kb" ] && avail_kb=$proc_avail_kb
    else
        total_kb=$proc_total_kb
        avail_kb=$proc_avail_kb
    fi

    local total_gb avail_gb auto_gb max_gb
    total_gb=$(( total_kb / 1024 / 1024 ))
    avail_gb=$(( avail_kb / 1024 / 1024 ))

    auto_gb=$(( avail_gb * 80 / 100 ))
    [ "$auto_gb" -lt 2 ] && auto_gb=2

    max_gb=$(( total_gb - 1 ))
    [ "$max_gb" -lt 2 ] && max_gb=2
    [ "$auto_gb" -gt "$max_gb" ] && auto_gb=$max_gb

    RAM_TOTAL_GB=$total_gb
    RAM_AVAIL_GB=$avail_gb
    RAM_AUTO_GB=$auto_gb

    # Thông báo nếu đang chạy trong container có limit
    if [[ "$cg_limit_bytes" -gt 0 ]]; then
        echo "🐳 Container RAM limit: ${total_gb}GB (cgroup)"
    fi
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

    CPU_PHYS=$cpu_phys
    CPU_USABLE=$cpu_limit
}

# ── DETECT CPU FLAGS ─────────────────────────────────────────────
detect_cpu_flags() {
    local flags=""
    local cpuflags
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

# ── CÀI LLVM ─────────────────────────────────────────────────────
# FIX: không dùng set -e bên trong, dùng || true để không abort
setup_llvm() {
    local os_id="$1" os_ver="$2"
    CC="gcc"; CXX="g++"; LD=""
    LLD_AVAILABLE=0
    LLVM_VER=""

    local versions
    if   [[ "$os_id" == "ubuntu" ]];                          then versions=(21 20 19 18 17)
    elif [[ "$os_id" == "debian" && "$os_ver" == "13" ]];     then versions=(19 18 17)
    else                                                            versions=(17 16 15)
    fi

    # Bước 1: thử apt thường
    local v
    for v in "${versions[@]}"; do
        if priv apt-get install -y -qq \
            "clang-${v}" "lld-${v}" "llvm-${v}" "llvm-${v}-dev" "llvm-${v}-tools" \
            >/dev/null 2>&1; then
            LLVM_VER="$v"
            echo "✅ LLVM ${v} — apt thường"
            break
        fi
    done

    # Bước 2: repo apt.llvm.org thủ công
    if [[ -z "$LLVM_VER" ]]; then
        echo "📦 Thêm repo apt.llvm.org..."
        priv apt-get install -y -qq wget curl gnupg ca-certificates >/dev/null 2>&1 || true
        # FIX: fallback curl nếu không có wget
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
                LLVM_VER="$v"
                echo "✅ LLVM ${v} — repo llvm.org"
                break
            fi
        done
    fi

    # Bước 3: fallback clang không version
    if [[ -z "$LLVM_VER" ]]; then
        echo "⚠️  Fallback clang mặc định..."
        priv apt-get install -y -qq clang lld llvm >/dev/null 2>&1 || true
        if command -v clang &>/dev/null; then
            CC="clang"; CXX="clang++"
            if command -v lld &>/dev/null; then LD="lld"; LLD_AVAILABLE=1; fi
            echo "✅ clang mặc định"
            return 0
        fi
    fi

    # Bước 4: fallback gcc
    if [[ -z "$LLVM_VER" ]]; then
        echo "⚠️  Fallback gcc"
        CC="gcc"; CXX="g++"; LD=""
        LLD_AVAILABLE=0
        return 0
    fi

    export PATH="/usr/lib/llvm-${LLVM_VER}/bin:$PATH"
    CC="clang-${LLVM_VER}"
    CXX="clang++-${LLVM_VER}"
    LD="lld-${LLVM_VER}"
    LLD_AVAILABLE=1
    echo "🔥 CC=$CC | LD=$LD"
}

# ── BUILD GLIB NẾU QUÁ CŨ ────────────────────────────────────────
# FIX: nhận MESON_BIN làm tham số để dùng đúng meson từ venv
ensure_glib() {
    local meson_bin="${1:-meson}"
    local cur
    cur=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")
    if ver_lt "$cur" "2.66"; then
        echo "⚠️  glib ${cur} quá cũ → build 2.76.6..."
        priv apt-get install -y -qq libffi-dev gettext >/dev/null 2>&1 || true

        spin_start "Tải glib 2.76.6..."
        # FIX: thử wget trước, fallback curl
        if command -v wget &>/dev/null; then
            wget -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz -O /tmp/glib-2.76.6.tar.xz \
                || { spin_fail "wget glib thất bại"; return 1; }
        else
            curl -fsSL https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz -o /tmp/glib-2.76.6.tar.xz \
                || { spin_fail "curl glib thất bại"; return 1; }
        fi
        spin_stop "Tải glib xong"

        cd /tmp
        tar -xf glib-2.76.6.tar.xz
        cd glib-2.76.6

        # FIX: install vào /opt/glib-local để không cần sudo
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
        # FIX: export đầy đủ các path từ prefix của glib
        local glib_pc_dirs=()
        for d in "${GLIB_PREFIX}/lib/x86_64-linux-gnu/pkgconfig" \
                  "${GLIB_PREFIX}/lib/pkgconfig" \
                  "${GLIB_PREFIX}/lib64/pkgconfig"; do
            [ -d "$d" ] && glib_pc_dirs+=("$d")
        done
        local pc_add
        pc_add=$(IFS=:; echo "${glib_pc_dirs[*]}")
        export PKG_CONFIG_PATH="${pc_add}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        export LD_LIBRARY_PATH="${GLIB_PREFIX}/lib/x86_64-linux-gnu:${GLIB_PREFIX}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export PATH="${GLIB_PREFIX}/bin:$PATH"
        echo "✅ glib $(pkg-config --modversion glib-2.0 2>/dev/null || echo 'installed')"
    else
        echo "✅ glib ${cur}"
    fi
}

# ════════════════════════════════════════════════════════════════
#  BUILD QEMU
# ════════════════════════════════════════════════════════════════
choice=$(ask "👉 Build QEMU tối ưu LLVM? (y/n): " "n")

if [[ "$choice" == "y" ]]; then
    if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
        echo "⚡ QEMU đã có — skip build"
        export PATH="/opt/qemu-optimized/bin:$PATH"
    else
        echo ""
        echo "🚀 Build QEMU bắt đầu..."

        OS_ID="$(. /etc/os-release && echo "$ID")"
        OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

        # FIX: spinner khi cài apt packages
        spin_start "Cài gói cơ bản..."
        priv apt-get update -qq >/dev/null 2>&1 || true
        priv apt-get install -y -qq \
            wget curl gnupg ca-certificates build-essential ninja-build git \
            python3 python3-venv python3-pip \
            libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev \
            pkg-config aria2 ovmf >/dev/null 2>&1 || true
        # FIX: cài meson hệ thống riêng để dùng tạm nếu cần, nhưng KHÔNG remove trước khi build
        priv apt-get install -y -qq meson >/dev/null 2>&1 || true
        spin_stop "Cài gói xong"

        echo "🔎 Thiết lập compiler LLVM..."
        setup_llvm "$OS_ID" "$OS_VER"
        export CC CXX

        # FIX: tạo venv VÀ kích hoạt TRƯỚC khi gọi ensure_glib/configure
        echo "🐍 Python venv + meson..."
        python3 -m venv ~/qemu-env
        # shellcheck source=/dev/null
        source ~/qemu-env/bin/activate

        spin_start "Cài meson/ninja trong venv..."
        pip install -q --upgrade pip >/dev/null 2>&1
        pip install -q meson ninja tomli packaging >/dev/null 2>&1
        spin_stop "Cài meson venv xong"

        # FIX: lấy đường dẫn tuyệt đối của meson trong venv, truyền vào ensure_glib
        VENV_MESON="$(command -v meson)"
        export MESON="$VENV_MESON"

        # FIX: KHÔNG remove meson hệ thống trước — chỉ ưu tiên venv qua PATH
        # (venv đã được kích hoạt, PATH đã trỏ đúng)

        echo "🔎 Kiểm tra glib..."
        ensure_glib "$VENV_MESON"
        # PKG_CONFIG_PATH và LD_LIBRARY_PATH đã được ensure_glib set nếu cần build glib
        # Chỉ khởi tạo nếu chưa có để tránh unbound variable
        export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
        export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

        # FIX: spinner khi clone QEMU
        spin_start "Tải QEMU v11.0.0 (git clone)..."
        rm -rf /tmp/qemu-src /tmp/qemu-build
        git clone -q --depth 1 --branch v11.0.0 \
            https://gitlab.com/qemu-project/qemu.git /tmp/qemu-src 2>/dev/null \
            || { spin_fail "Clone QEMU thất bại"; die "Không clone được QEMU"; }
        spin_stop "Tải QEMU xong"

        mkdir -p /tmp/qemu-build
        cd /tmp/qemu-build

        # Flags
        if [[ "$LLD_AVAILABLE" == "1" ]]; then
            OPT_CFLAGS="-Ofast -march=native -mtune=native -pipe \
-ffast-math -fmerge-all-constants -fno-semantic-interposition \
-fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables \
-fno-stack-protector -fstrict-aliasing \
-funroll-loops -finline-functions \
-DDEFAULT_TCG_TB_SIZE=3097152 \
-flto=full -fuse-ld=lld"
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

        # FIX: spinner khi configure
        # FIX: truyền CC/CXX tường minh vào configure để tránh undetected compiler
        # Nếu CC chưa set hoặc rỗng thì fallback gcc
        : "${CC:=gcc}"
        : "${CXX:=g++}"
        spin_start "Configure QEMU..."
        CC="$CC" CXX="$CXX" /tmp/qemu-src/configure \
            --cc="$CC" \
            --cxx="$CXX" \
            --prefix=/opt/qemu-optimized \
            --target-list=x86_64-softmmu \
            --enable-tcg \
            --enable-slirp \
            --enable-coroutine-pool \
            ${LTO_FLAG:+$LTO_FLAG} \
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
            --disable-bochs \
            --disable-qed \
            --disable-parallels \
            --disable-pa \
            --disable-alsa \
            --disable-oss \
            --disable-jack \
            --disable-gnutls \
            --disable-smartcard \
            --disable-libusb \
            --disable-seccomp \
            --disable-modules \
            --extra-cflags="$OPT_CFLAGS" \
            --extra-ldflags="$OPT_LDFLAGS" \
            >/tmp/qemu-configure.log 2>&1 \
            || { spin_fail "Configure thất bại"; cat /tmp/qemu-configure.log >&2; die "QEMU configure lỗi — xem log trên"; }
        spin_stop "Configure xong"

        # FIX: spinner khi build (lâu nhất)
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

# Đảm bảo PATH
[ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ] && \
    export PATH="/opt/qemu-optimized/bin:$PATH"

command -v qemu-system-x86_64 >/dev/null 2>&1 || \
    die "Không tìm thấy qemu-system-x86_64. Build QEMU hoặc: apt install qemu-system-x86"

command -v qemu-img >/dev/null 2>&1 || \
    die "Không tìm thấy qemu-img. Cần cài qemu-utils."

# ════════════════════════════════════════════════════════════════
#  MENU CHÍNH
# ════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════"
echo "🖥️  WINDOWS VM MANAGER  [v8.5]"
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

# FIX: spinner khi tải image (có thể rất lâu)
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
    detect_cpu
    detect_ram
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

# HugePage
detect_hugepage

# TCG TB size
TCG_TB_MB=$ram_size
[ "$TCG_TB_MB" -lt 1 ] && TCG_TB_MB=1
[ "$TCG_TB_MB" -gt 4 ] && TCG_TB_MB=4
TCG_TB_BYTES=$(( TCG_TB_MB * 1024 * 1024 ))
echo "⚡ TCG TB: ${TCG_TB_MB}MB"

# CPU flags
detect_cpu_flags
CPU_MODEL="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+cx16,+x2apic,+sep,+pat,+pse${CPU_EXTRA_FLAGS},model-id=${CPU_HOST_MODEL}"

# Network
case "$NET_DEV" in
    e1000e) NET_DEVICE="-device e1000e,netdev=n0" ;;
    *)      NET_DEVICE="-device virtio-net-pci,netdev=n0" ;;
esac

# BIOS/UEFI
BIOS_OPT=""
if [[ "$USE_UEFI" == "yes" ]]; then
    for f in /usr/share/qemu/OVMF.fd \
              /usr/share/ovmf/OVMF.fd \
              /usr/share/edk2/ovmf/OVMF_CODE.fd; do
        if [ -f "$f" ]; then
            BIOS_OPT="-bios $f"
            echo "✅ UEFI: $f"
            break
        fi
    done
    [ -z "$BIOS_OPT" ] && echo "⚠️  Không tìm thấy OVMF — bỏ UEFI"
fi

# ════════════════════════════════════════════════════════════════
#  KHỞI ĐỘNG VM
# ════════════════════════════════════════════════════════════════
echo ""
echo "🚀 Khởi động VM..."

# FIX: bỏ -vga virtio khi -display none (vô dụng + tốn RAM)
# FIX: thêm -serial none -parallel none để tránh warning
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
    -serial none \
    -parallel none \
    -global ICH9-LPC.disable_s3=1 \
    -global ICH9-LPC.disable_s4=1 \
    -smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640" \
    -global kvm-pit.lost_tick_policy=discard \
    -no-user-config \
    -display none \
    -daemonize \
    >/dev/null 2>&1 || true

# FIX: spinner khi chờ VM khởi động
spin_start "Chờ VM khởi động..."
sleep 5
spin_stop "VM khởi động xong"

if pgrep -f "qemu-system-x86_64" >/dev/null 2>&1; then
    echo "✅ VM đang chạy"
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

    # FIX: bỏ `local` ngoài function (syntax error), dùng biến thường
    # FIX: lấy tag mới nhất qua API thay vì dùng /latest/download (redirect không ổn định)
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
        # FIX: extract thẳng ra thư mục hiện tại, tar chỉ chứa file `kami-tunnel`
        tar -xzf /tmp/kami.tar.gz -C . 2>/dev/null \
            || tar -xzf /tmp/kami.tar.gz 2>/dev/null || true
        chmod +x ./kami-tunnel 2>/dev/null || true
        spin_stop "Tải kami-tunnel xong (v${local_tag})"
    else
        echo "✅ kami-tunnel đã có"
    fi

    # FIX: dùng -target host:port (flag đúng của kami-tunnel v3)
    tmux kill-session -t kami 2>/dev/null || true
    tmux new-session -d -s kami "./kami-tunnel -target 127.0.0.1:3389"

    # FIX: retry lấy địa chỉ public, tmux capture trả ra "Public: IP:PORT" cùng dòng Status
    spin_start "Chờ tunnel kết nối..."
    PUBLIC=""
    for _i in $(seq 1 25); do
        sleep 1
        PUBLIC=$(tmux capture-pane -pt kami -p 2>/dev/null \
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
    echo "🚀 WINDOWS VM DEPLOYED  [v8.5]"
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
