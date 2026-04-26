#!/usr/bin/env bash
set -e

# ════════════════════════════════════════════════════════════════
#  WINDOWS VM TOOL v8
#  Base: v3 (stable) + Features: v7 (auto detect RAM/CPU/hugepage/glib)
# ════════════════════════════════════════════════════════════════

# --- HÀM HỖ TRỢ ---
silent() {
    "$@" > /dev/null 2>&1
}

ask() {
    read -rp "$1" ans
    ans="${ans,,}"
    if [[ -z "$ans" ]]; then
        echo "$2"
    else
        echo "$ans"
    fi
}

ver_lt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

# --- AUTO DETECT HUGEPAGE (từ v7) ---
detect_hugepage() {
    HUGEPAGE_OPT=""
    HP_INFO="none"

    HP_1G=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo "0")
    HP_2M=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo "0")
    THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "never")

    echo ""
    echo "🔎 Kiểm tra HugePages..."
    echo "   1GB hugepages : $HP_1G"
    echo "   2MB hugepages : $HP_2M"
    echo "   THP status    : $THP"

    if [ "$HP_1G" -gt 0 ]; then
        HUGEPAGE_OPT="-mem-prealloc -mem-path /dev/hugepages"
        HP_INFO="1GB hugepages (${HP_1G} pages = ${HP_1G}GB)"
        echo "✅ Dùng 1GB hugepages → tối ưu nhất cho TCG"
    elif [ "$HP_2M" -gt 0 ]; then
        HUGEPAGE_OPT="-mem-prealloc -mem-path /dev/hugepages"
        HP_INFO="2MB hugepages (${HP_2M} pages = $(( HP_2M * 2 ))MB)"
        echo "✅ Dùng 2MB hugepages"
    elif echo "$THP" | grep -q '\[always\]\|\[madvise\]'; then
        HUGEPAGE_OPT="-mem-prealloc"
        HP_INFO="Transparent HugePages (THP)"
        echo "✅ THP có sẵn → bật mem-prealloc"
    else
        echo "⚠️  Không có hugepage — chạy bình thường"
    fi
}

# ════════════════════════════════════════════════════════════════
#  BUILD QEMU (giữ nguyên logic v3, bổ sung auto-detect glib từ v7)
# ════════════════════════════════════════════════════════════════
choice=$(ask "👉 Bạn có muốn build QEMU để tạo VM với tăng tốc LLVM không? (y/n): " "n")

if [[ "$choice" == "y" ]]; then
    if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
        echo "⚡ QEMU ULTRA đã tồn tại — skip build"
        export PATH="/opt/qemu-optimized/bin:$PATH"
    else
        echo "🚀 Đang cài các gói cần thiết..."
        echo "⚠️  Nếu lỗi hãy thử: sudo apt install sudo"

        OS_ID="$(. /etc/os-release && echo "$ID")"
        OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

        sudo apt update
        sudo apt install -y wget gnupg build-essential ninja-build git \
            python3 python3-venv python3-pip \
            libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev \
            pkg-config meson aria2 ovmf

        # --- Thiết lập LLVM (không dùng llvm.sh, tránh lỗi add-apt-repository trong container) ---
        install_llvm_direct() {
            local ver=$1
            echo "📦 Thử cài clang-${ver} từ apt mặc định..."
            if sudo apt install -y clang-${ver} lld-${ver} llvm-${ver} llvm-${ver}-dev llvm-${ver}-tools 2>/dev/null; then
                echo "✅ Cài LLVM ${ver} thành công"
                LLVM_VER=$ver
                return 0
            fi
            return 1
        }

        install_llvm_from_repo() {
            local ver=$1
            echo "📦 Thử thêm repo apt.llvm.org thủ công (không dùng llvm.sh)..."
            # Cài prerequisite trước
            sudo apt install -y wget gnupg ca-certificates lsb-release software-properties-common 2>/dev/null || true
            # Thêm key và repo thủ công (không cần add-apt-repository)
            wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | sudo tee /etc/apt/trusted.gpg.d/llvm-snapshot.asc > /dev/null
            CODENAME=$(lsb_release -cs 2>/dev/null || echo "bookworm")
            echo "deb https://apt.llvm.org/${CODENAME}/ llvm-toolchain-${CODENAME}-${ver} main" \
                | sudo tee /etc/apt/sources.list.d/llvm-${ver}.list > /dev/null
            sudo apt update -qq
            if sudo apt install -y clang-${ver} lld-${ver} llvm-${ver} llvm-${ver}-dev llvm-${ver}-tools 2>/dev/null; then
                echo "✅ Cài LLVM ${ver} từ repo thành công"
                LLVM_VER=$ver
                return 0
            fi
            return 1
        }

        LLVM_VER=""

        # Chọn version mục tiêu theo OS
        if [[ "$OS_ID" == "ubuntu" ]]; then
            TARGET_LLVM_VERS=(21 20 19 18 17)
        elif [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
            TARGET_LLVM_VERS=(19 18 17)
        else
            TARGET_LLVM_VERS=(17 16 15)
        fi

        # Thử cài từng version: apt mặc định trước, rồi repo thủ công
        for ver in "${TARGET_LLVM_VERS[@]}"; do
            if install_llvm_direct "$ver"; then
                break
            fi
        done

        # Nếu vẫn chưa có, thử repo thủ công với version cao nhất
        if [[ -z "$LLVM_VER" ]]; then
            for ver in "${TARGET_LLVM_VERS[@]}"; do
                if install_llvm_from_repo "$ver"; then
                    break
                fi
            done
        fi

        # Fallback cuối: dùng clang mặc định không có version suffix
        if [[ -z "$LLVM_VER" ]]; then
            echo "⚠️  Không cài được LLVM có version — thử dùng clang mặc định..."
            sudo apt install -y clang lld llvm 2>/dev/null || true
            if command -v clang &>/dev/null; then
                # Tìm version thực tế
                LLVM_VER=$(clang --version 2>/dev/null | grep -oP 'version \K[0-9]+' | head -1 || echo "")
                export CC="clang"
                export CXX="clang++"
                export LD="lld"
                echo "✅ Dùng clang mặc định (version: ${LLVM_VER:-unknown})"
                LLVM_VER="default"
            else
                echo "❌ Không tìm được clang — build sẽ dùng gcc"
                export CC="gcc"
                export CXX="g++"
                LLVM_VER="gcc"
            fi
        fi

        # Thiết lập PATH và CC/CXX/LD dựa vào kết quả cài LLVM
        if [[ "$LLVM_VER" =~ ^[0-9]+$ ]]; then
            export PATH="/usr/lib/llvm-$LLVM_VER/bin:$PATH"
            export CC="clang-$LLVM_VER"
            export CXX="clang++-$LLVM_VER"
            export LD="lld-$LLVM_VER"
            echo "🔥 Dùng LLVM ${LLVM_VER}"
        elif [[ "$LLVM_VER" == "default" ]]; then
            echo "🔥 Dùng clang mặc định"
        else
            echo "🔥 Dùng gcc fallback"
        fi

        # Kiểm tra lld
        if command -v lld &>/dev/null || ( [[ "$LLVM_VER" =~ ^[0-9]+$ ]] && command -v "lld-${LLVM_VER}" &>/dev/null ); then
            LLD_AVAILABLE=1
            echo "✅ lld tìm thấy"
        else
            LLD_AVAILABLE=0
            echo "⚠️  lld không tìm thấy, fallback sang ld mặc định"
        fi

        # --- AUTO DETECT & BUILD GLIB (từ v7) ---
        echo ""
        echo "🔎 Kiểm tra phiên bản glib..."
        GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")

        if ver_lt "$GLIB_VER" "2.66"; then
            echo "⚠️  glib hiện tại: $GLIB_VER → Quá cũ, đang build glib 2.76.6..."
            sudo apt install -y libffi-dev gettext
            cd /tmp
            wget -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz
            tar -xf glib-2.76.6.tar.xz
            cd glib-2.76.6
            meson setup build --prefix=/usr/local
            ninja -C build
            sudo ninja -C build install
            export PKG_CONFIG_PATH="/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"
            export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:$LD_LIBRARY_PATH"
            echo "✅ glib mới: $(pkg-config --modversion glib-2.0)"
        else
            echo "✅ glib đủ yêu cầu: $GLIB_VER"
        fi

        # --- Python venv + meson mới nhất ---
        python3 -m venv ~/qemu-env
        source ~/qemu-env/bin/activate
        silent pip install --upgrade pip tomli packaging
        silent pip install meson ninja
        sudo apt remove -y meson 2>/dev/null || true
        hash -r

        # --- Download QEMU source ---
        rm -rf /tmp/qemu-src /tmp/qemu-build
        cd /tmp
        echo "📂 Đang tải source QEMU v11.0.0..."
        silent git clone --depth 1 --branch v11.0.0 \
            https://gitlab.com/qemu-project/qemu.git qemu-src
        mkdir /tmp/qemu-build
        cd /tmp/qemu-build

        # --- Flags tối ưu: bật lld/lto nếu có, fallback an toàn nếu không ---
        BASE_CFLAGS="-Ofast -march=native -mtune=native -pipe \
-ffast-math -fmerge-all-constants -fno-semantic-interposition \
-fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables \
-fno-stack-protector -funsafe-math-optimizations \
-ffinite-math-only -fno-math-errno -fstrict-aliasing \
-funroll-loops -finline-functions -finline-hint-functions \
-DNDEBUG -DDEFAULT_TCG_TB_SIZE=3097152"

        if [[ "$LLD_AVAILABLE" == "1" ]]; then
            EXTRA_CFLAGS="$BASE_CFLAGS -flto=full -fuse-ld=lld"
            LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"
            LTO_FLAG="--enable-lto"
            echo "✅ Bật LTO + lld"
        else
            EXTRA_CFLAGS="$BASE_CFLAGS"
            LDFLAGS="-Wl,-O2"
            LTO_FLAG=""
            echo "⚠️  Không có lld — build không LTO (vẫn nhanh)"
        fi

        echo "🔁 Đang biên dịch QEMU..."
        echo "💣 Nếu lỗi trong quá trình build, thử: ulimit -n 84857"

        ../qemu-src/configure \
            --prefix=/opt/qemu-optimized \
            --target-list=x86_64-softmmu \
            --enable-tcg \
            --enable-slirp \
            $LTO_FLAG \
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
            CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS"

        echo "🕧 QEMU đang được build, vui lòng đợi..."
        ulimit -n 84857 || true
        ninja -j"$(nproc)"
        sudo ninja install

        export PATH="/opt/qemu-optimized/bin:$PATH"
        qemu-system-x86_64 --version
        echo "🔥 QEMU LLVM build xong!"
    fi
else
    echo "⚡ Bỏ qua build QEMU."
fi

# Đảm bảo qemu-system-x86_64 tìm thấy
if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
    export PATH="/opt/qemu-optimized/bin:$PATH"
fi

# ════════════════════════════════════════════════════════════════
#  MENU CHÍNH
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
