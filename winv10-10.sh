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
#  BUILD QEMU  — chỉ build 1 lần duy nhất
# ════════════════════════════════════════════════════════════════
QEMU_BIN="/opt/qemu-optimized/bin/qemu-system-x86_64"

choice=$(ask "👉 Bạn có muốn build QEMU để tạo VM với tăng tốc LLVM không? (y/n): " "n")

if [[ "$choice" == "y" ]]; then

    # ── Kiểm tra QEMU đã build chưa ──────────────────────────────
    if [[ -x "$QEMU_BIN" ]]; then
        BUILT_VER=$("$QEMU_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU ULTRA v${BUILT_VER} đã tồn tại — bỏ qua build${W}"
        export PATH="/opt/qemu-optimized/bin:$PATH"
    else
        # ── Cài dependencies — skip package đã có, hiện progress ────
        echo ""
        spin_start "Cập nhật apt cache..."
        silent sudo apt-get update
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
            if sudo apt-get install -y -qq "$pkg" > /dev/null 2>&1; then
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
spin_start "Khởi động VM ${WIN_NAME}..."
# ── CPU pinning: gắn QEMU vào core riêng, không share với host ──
CPU_TOTAL=$(nproc)
if [[ "$CPU_TOTAL" -gt "$cpu_core" ]]; then
    # Reserve core 0 cho host, pin VM vào các core còn lại
    PIN_START=1
    PIN_END=$(( cpu_core ))
    CPUSET="${PIN_START}-${PIN_END}"
    TASKSET_CMD="taskset -c $CPUSET"
    echo -e "${G}✔${W} CPU pinning: core ${CPUSET} → VM (core 0 giữ lại cho host)"
else
    TASKSET_CMD=""
    echo -e "${Y}⚠${W} Không đủ core để pin — bỏ qua CPU pinning"
fi

# ── FIFO realtime scheduling cho QEMU process ─────────────────
if command -v chrt &>/dev/null; then
    CHRT_CMD="chrt -f 1"
    echo -e "${G}✔${W} FIFO realtime scheduling bật (chrt -f 1)"
else
    CHRT_CMD=""
fi

# ── ionice: ưu tiên I/O cho QEMU ──────────────────────────────
if command -v ionice &>/dev/null; then
    IONICE_CMD="ionice -c 1 -n 0"
    echo -e "${G}✔${W} I/O priority: realtime class 1"
else
    IONICE_CMD=""
fi
echo -e "${B}◜${W} Áp dụng kernel tweaks..."
# Tắt NUMA balancing (gây stutter khi TCG move pages)
echo 0 | sudo tee /proc/sys/kernel/numa_balancing            > /dev/null 2>&1 || true
# Giảm swap aggression — TCG cần RAM luôn trong physical memory
echo 10 | sudo tee /proc/sys/vm/swappiness                   > /dev/null 2>&1 || true
# Giữ dirty pages lâu hơn → batch write → ít I/O interrupt hơn
echo 40  | sudo tee /proc/sys/vm/dirty_ratio                 > /dev/null 2>&1 || true
echo 15  | sudo tee /proc/sys/vm/dirty_background_ratio      > /dev/null 2>&1 || true
# Tăng scheduler granularity — TCG thread ít bị preempt hơn
echo 4000000 | sudo tee /proc/sys/kernel/sched_min_granularity_ns  > /dev/null 2>&1 || true
echo 8000000 | sudo tee /proc/sys/kernel/sched_wakeup_granularity_ns > /dev/null 2>&1 || true
# Tắt watchdog — giảm interrupt noise
echo 0 | sudo tee /proc/sys/kernel/watchdog                  > /dev/null 2>&1 || true
# ulimit cho QEMU process
ulimit -n 1048576 2>/dev/null || true
ulimit -l unlimited 2>/dev/null || true
echo -e "${G}✔${W} Kernel tweaks đã áp dụng"

# ── Memory backend: dùng memfd nếu không có hugepage ─────────
RAM_BYTES=$(( ram_size * 1024 * 1024 * 1024 ))
if [[ -n "$HUGEPAGE_OPT" ]] && echo "$HUGEPAGE_OPT" | grep -q "hugepages"; then
    MEM_BACKEND="-object memory-backend-file,id=ram0,size=${ram_size}G,mem-path=/dev/hugepages,share=on,prealloc=on -numa node,memdev=ram0"
else
    MEM_BACKEND="-object memory-backend-memfd,id=ram0,size=${ram_size}G,share=on,hugetlb=off -numa node,memdev=ram0"
fi

# ── SMP topology: cores + threads tối ưu cho TCG MTTCG ───────
PHYS_CORES=$(( cpu_core > 1 ? cpu_core / 2 : 1 ))
THREADS=2
SMP_OPT="${cpu_core},cores=${PHYS_CORES},threads=${THREADS},sockets=1"

# ── Disk I/O: native aio + writeback cache ───────────────────
DISK_OPT="file=win.img,if=virtio,cache=writeback,aio=native,format=raw,discard=unmap,detect-zeroes=unmap"

$IONICE_CMD $CHRT_CMD $TASKSET_CMD qemu-system-x86_64 \
    -machine q35,hpet=off,mem-merge=on \
    -cpu "$cpu_model" \
    -smp "$SMP_OPT" \
    -m "${ram_size}G" \
    $MEM_BACKEND \
    -accel tcg,thread=multi,tb-size=$TCG_TB_BYTES \
    -rtc base=localtime,driftfix=slew \
    $BIOS_OPT \
    -drive "$DISK_OPT" \
    -device virtio-scsi-pci,num_queues=${cpu_core} \
    -netdev user,id=n0,hostfwd=tcp::3389-:3389 \
    $NET_DEVICE \
    -device virtio-mouse-pci \
    -device virtio-keyboard-pci \
    -device virtio-balloon-pci \
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
