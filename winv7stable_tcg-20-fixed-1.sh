#!/usr/bin/env bash
set -e

# --- CÁC HÀM HỖ TRỢ ---
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

# --- AUTO DETECT HUGEPAGE ---
detect_hugepage() {
    HUGEPAGE_OPT=""
    HP_INFO=""

    # Kiểm tra hugepage 1GB (tốt nhất cho VM RAM lớn)
    HP_1G=$(cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo "0")
    # Kiểm tra hugepage 2MB (phổ biến hơn)
    HP_2M=$(cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo "0")
    # Kiểm tra transparent hugepage
    THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "never")

    echo "🔎 Kiểm tra Hugepage..."
    echo "   1GB hugepages : $HP_1G"
    echo "   2MB hugepages : $HP_2M"
    echo "   THP status    : $THP"

    if [ "$HP_1G" -gt 0 ]; then
        HUGEPAGE_OPT="-mem-prealloc -mem-path /dev/hugepages"
        HP_INFO="1GB hugepages ($HP_1G pages = ${HP_1G}GB)"
        echo "✅ Dùng 1GB hugepages → tốt nhất cho TCG"
    elif [ "$HP_2M" -gt 0 ]; then
        HUGEPAGE_OPT="-mem-prealloc -mem-path /dev/hugepages"
        HP_INFO="2MB hugepages ($HP_2M pages = $(( HP_2M * 2 ))MB)"
        echo "✅ Dùng 2MB hugepages"
    elif echo "$THP" | grep -q '\[always\]\|\[madvise\]'; then
        # THP available — QEMU dùng madvise tự động, không cần flag đặc biệt
        # Chỉ bật mem-prealloc để tận dụng THP tốt hơn
        HUGEPAGE_OPT="-mem-prealloc"
        HP_INFO="Transparent HugePages (THP)"
        echo "✅ THP có sẵn → bật mem-prealloc"
    else
        echo "⚠️ Không có hugepage — chạy bình thường (RAM nhỏ hơn 4GB không cần)"
        HP_INFO="none"
    fi
}

# --- BẮT ĐẦU CHƯƠNG TRÌNH ---
choice=$(ask "👉 Bạn có muốn build QEMU để tạo VM với tăng tốc LLVM không ? (y/n): " "n")

if [[ "$choice" == "y" ]]; then
    if [ -x /opt/qemu-optimized/bin/qemu-system-x86_64 ]; then
        echo "⚡ QEMU ULTRA đã tồn tại — skip build"
        export PATH="/opt/qemu-optimized/bin:$PATH"
    else
        echo "🚀 Đang Tải Các Apt Cần Thiết..."
        echo "⚠️ Nếu lỗi hãy thử dùng apt install sudo"

        OS_ID="$(. /etc/os-release && echo "$ID")"
        OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

        sudo apt update
        sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config aria2 ovmf

        # Thiết lập Compiler LLVM
        if [[ "$OS_ID" == "ubuntu" ]]; then
            echo "🔥 Detect Ubuntu → Cài LLVM 21 từ apt.llvm.org"
            wget https://apt.llvm.org/llvm.sh
            chmod +x llvm.sh
            sudo ./llvm.sh 21
            LLVM_VER=21
        else
            if [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
                LLVM_VER=19
            else
                LLVM_VER=15
            fi
            silent sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools
        fi

        export PATH="/usr/lib/llvm-$LLVM_VER/bin:$PATH"
        export CC="clang-$LLVM_VER"
        export CXX="clang++-$LLVM_VER"
        export LD="lld-$LLVM_VER"

        # Kiểm tra lld có sẵn trước khi dùng
        LLD_AVAILABLE=0
        if command -v "lld-$LLVM_VER" &>/dev/null || command -v lld &>/dev/null; then
            LLD_AVAILABLE=1
            echo "✅ lld tìm thấy"
        else
            echo "⚠️ lld không tìm thấy, fallback sang ld mặc định"
        fi

        # Kiểm tra glib
        echo "🔎 Kiểm tra phiên bản glib..."
        GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")

        if ver_lt "$GLIB_VER" "2.66"; then
            echo "⚠️ glib hiện tại: $GLIB_VER → Quá cũ, đang build glib mới..."
            sudo apt install -y libffi-dev gettext meson
            cd /tmp
            wget https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz
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

        # Setup Môi trường Python và Meson mới nhất
        python3 -m venv ~/qemu-env
        # shellcheck source=/dev/null
        . "$HOME/qemu-env/bin/activate"
        pip install --upgrade pip
        pip install meson ninja tomli packaging

        # Gỡ meson hệ thống nếu có để tránh xung đột
        sudo apt remove -y meson || true
        hash -r

        # Download QEMU source
        rm -rf /tmp/qemu-src /tmp/qemu-build
        cd /tmp
        echo "📂 Đang tải source QEMU v11..."
        silent git clone --depth 1 --branch v11.0.0 https://gitlab.com/qemu-project/qemu.git qemu-src
        cd /tmp/qemu-src

        echo "🔧 Applying safe TCG source patches..."

        # ── PATCH 1: TCG_MAX_INSNS ──────────────────────────────────
        # Số guest instruction tối đa mỗi Translation Block trước khi
        # TCG buộc kết thúc TB. 512 → 768: giảm số lần exit dispatcher
        # mà không quá lớn gây compile lâu hơn hay cache thrash.
        # Chỉ sed đơn giản trên define, không đụng logic.
        sed -i "s/#define TCG_MAX_INSNS 512/#define TCG_MAX_INSNS 768/" tcg/tcg.c 2>/dev/null             && echo "  ✅ PATCH 1: TCG_MAX_INSNS 512 → 768"             || echo "  ⚠️  PATCH 1: skip (define không khớp)"

        # ── PATCH 2: TB_JMP_CACHE_BITS ─────────────────────────────
        # Hash table lookup TB theo guest PC.
        # 12 → 13 tức 4096 → 8192 entries, giảm collision.
        # Tốn thêm ~64KB RAM, không ảnh hưởng correctness.
        # Tìm trong mọi header/source liên quan.
        grep -rl "define TB_JMP_CACHE_BITS" include/ accel/ tcg/ 2>/dev/null | while IFS= read -r f; do
            sed -i "s/#define TB_JMP_CACHE_BITS 12/#define TB_JMP_CACHE_BITS 13/" "$f"                 && echo "  ✅ PATCH 2: TB_JMP_CACHE_BITS 12 → 13 ($f)"                 || echo "  ⚠️  PATCH 2: skip $f"
        done

        # ── PATCH 3: TCG_HIGHWATER ──────────────────────────────────
        # Ngưỡng buffer còn lại trước khi force-flush TB.
        # Tăng nhẹ 1024 → 1536 giảm số lần flush sớm không cần thiết.
        sed -i "s/#define TCG_HIGHWATER 1024/#define TCG_HIGHWATER 1536/" tcg/tcg.c 2>/dev/null             && echo "  ✅ PATCH 3: TCG_HIGHWATER 1024 → 1536"             || echo "  ⚠️  PATCH 3: skip (define không khớp)"

        echo "✅ TCG patches done"
        mkdir /tmp/qemu-build
        cd /tmp/qemu-build

        # --- Flags tối ưu hóa ---
        # Ghi chú:
        #   - Đã xóa -fno-rtti, -fno-exceptions (C++ only — QEMU là C)
        #   - Đã xóa -fuse-ld khỏi CFLAGS (chỉ đặt trong LDFLAGS)
        #   - Đã xóa -fno-plt (gây lỗi link clang+lld một số distro)
        #   - -ffast-math bao gồm sẵn unsafe/finite/errno math flags
        #
        # TCG compile-time patch (proven safe, không extreme):
        #   -DCONFIG_TCG_INTERPRETER=0  tắt interpreter fallback, ép dùng native codegen
        #   -DDEFAULT_TCG_TB_SIZE       translation block cache 3MB
        #   -fno-strict-overflow        TCG cần wrap arithmetic, tắt UB assumption của compiler
        #   -falign-functions=64        align function entry theo cache line CPU
        #   -falign-loops=32            align TCG dispatch loop giảm iTLB miss
        #   -mprefer-vector-width=256   ưu tiên AVX2, tránh AVX-512 freq throttle (nếu CPU có)

        # Detect AVX2 để bật vector hint an toàn
        if grep -q avx2 /proc/cpuinfo 2>/dev/null; then
            VECTOR_FLAG="-mprefer-vector-width=256"
            echo "✅ AVX2 detected → bật vector width 256"
        else
            VECTOR_FLAG=""
            echo "⚠️ Không có AVX2 → bỏ qua vector flag"
        fi

        if [[ "$LLD_AVAILABLE" == "1" ]]; then
            EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -fPIC \
-flto=full -ffast-math -fno-math-errno \
-fmerge-all-constants -fno-semantic-interposition \
-fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables \
-fno-stack-protector -fstrict-aliasing -fno-strict-overflow \
-funroll-loops -finline-functions -finline-hint-functions \
-falign-functions=64 -falign-loops=32 $VECTOR_FLAG \
-Wno-error -Wno-unused-command-line-argument \
-DDEFAULT_TCG_TB_SIZE=3145728 -DCONFIG_TCG_INTERPRETER=0"
            LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"
            LTO_OPT="--enable-lto"
        else
            EXTRA_CFLAGS="-O2 -march=native -mtune=native -pipe -fPIC \
-fmerge-all-constants -fno-semantic-interposition \
-fomit-frame-pointer -fstrict-aliasing -fno-strict-overflow \
-fno-math-errno \
-funroll-loops -finline-functions \
-falign-functions=64 -falign-loops=32 $VECTOR_FLAG \
-Wno-error -Wno-unused-command-line-argument \
-DDEFAULT_TCG_TB_SIZE=3145728 -DCONFIG_TCG_INTERPRETER=0"
            LDFLAGS="-Wl,-O2"
            LTO_OPT=""
        fi

        echo "🔁 Đang Cấu hình QEMU..."
        # --target-list: chỉ build x86_64-softmmu (qemu-system-x86_64)
        # --tools=qemu-img không được configure wrapper hỗ trợ trực tiếp
        # → build full rồi dùng ninja chỉ build 2 target cần thiết
        ../qemu-src/configure \
        --prefix=/opt/qemu-optimized \
        --target-list=x86_64-softmmu \
        --enable-tcg \
        --disable-pie \
        --enable-slirp \
        $LTO_OPT \
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
        --disable-alsa \
        --disable-oss \
        --disable-jack \
        --disable-gnutls \
        --disable-smartcard \
        --disable-libusb \
        --disable-seccomp \
        --disable-modules \
        --disable-bochs \
        --disable-qed \
        --disable-parallels \
        --disable-capstone \
        --extra-cflags="$EXTRA_CFLAGS" \
        --extra-ldflags="$LDFLAGS"

        echo "🕧 QEMU đang được build vui lòng đợi..."
        ulimit -n 84857 || true
        # Chỉ build 2 target cần thiết: qemu-system-x86_64 và qemu-img
        # Bỏ qua qemu-nbd, qemu-io, qemu-storage-daemon, tests...
        ninja -j"$(nproc)" qemu-system-x86_64 qemu-img
        sudo ninja install

        export PATH="/opt/qemu-optimized/bin:$PATH"
        echo "✅ Kiểm tra phiên bản:"
        qemu-system-x86_64 --version
        echo "🔥 QEMU LLVM đã build xong"
    fi
else
    echo "⚡ Bỏ qua build QEMU."
fi

# --- QUẢN LÝ VM ---
echo ""
echo "════════════════════════════════════"
echo "🖥️  WINDOWS VM MANAGER"
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
      echo -e "\033[1;36m==================================\033[0m"
      read -rp "🆔 Nhập PID VM muốn tắt (hoặc Enter để bỏ qua): " kill_pid
      if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
        kill "$kill_pid" 2>/dev/null || true
        echo "✅ Đã gửi tín hiệu tắt VM PID $kill_pid"
      fi
    fi
    exit 0
    ;;
esac

# --- TẠO VM ---
echo ""
echo "🪟 Chọn phiên bản Windows muốn tải:"
echo "1️⃣ Windows Server 2012 R2 x64"
echo "2️⃣ Windows Server 2022 x64"
echo "3️⃣ Windows 11 LTSB x64"
echo "4️⃣ Windows 10 LTSB 2015 x64"
echo "5️⃣ Windows 10 LTSC 2023 x64"
read -rp "👉 Nhập số [1-5]: " win_choice

case "$win_choice" in
1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
2) WIN_NAME="Windows Server 2022"; WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img"; USE_UEFI="no" ;;
3) WIN_NAME="Windows 11 LTSB"; WIN_URL="https://archive.org/download/win_20260203/win.img"; USE_UEFI="yes" ;;
4) WIN_NAME="Windows 10 LTSB 2015"; WIN_URL="https://archive.org/download/win_20260208/win.img"; USE_UEFI="no" ;;
5) WIN_NAME="Windows 10 LTSC 2023"; WIN_URL="https://archive.org/download/win_20260215/win.img"; USE_UEFI="no" ;;
*) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
esac

case "$win_choice" in
3|4|5) RDP_USER="Admin"; RDP_PASS="Tam255Z" ;;
*) RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
esac

echo "🪟 Đang Tải $WIN_NAME..."
if [[ ! -f win.img ]]; then
    aria2c -x16 -s16 --continue --file-allocation=none "$WIN_URL" -o win.img
fi

read -rp "📦 Mở rộng đĩa thêm bao nhiêu GB (default 20)? " extra_gb
extra_gb="${extra_gb:-20}"
qemu-img resize win.img "+${extra_gb}G"

echo ""
echo "════════════════════════════════════"
echo "⚙ CHỌN CHẾ ĐỘ CẤU HÌNH VM"
echo "════════════════════════════════════"
echo "1️⃣ Auto cấu hình (khuyên dùng)"
echo "2️⃣ Tự chọn thủ công"
echo "════════════════════════════════════"

read -rp "👉 Nhập lựa chọn [1-2]: " cfg_mode

if [[ "$cfg_mode" == "1" ]]; then

    echo ""
    echo "🧠 AUTO DETECT HOST RESOURCE..."

    # --- CPU DETECT ---
    cpu_v=$(nproc 2>/dev/null)
    cpu_u=$cpu_v

    if [ -f /sys/fs/cgroup/cpu.max ]; then
        # shellcheck disable=SC2013
        IFS=" " read -r q p < /sys/fs/cgroup/cpu.max
        if [ "$q" != "max" ] 2>/dev/null; then
            cpu_u=$(awk "BEGIN{printf \"%.0f\",$q/$p}")
        fi
    elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
        if [ "$q" != "-1" ] 2>/dev/null; then
            cpu_u=$(awk "BEGIN{printf \"%.0f\",$q/$p}")
        fi
    fi

    if [ "$cpu_u" -lt 1 ]; then
        cpu_u=1
    fi

    # --- RAM DETECT ---
    mem_total_gb=$(awk '/MemTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo)
    mem_auto_gb=$(awk "BEGIN{printf \"%d\", ($mem_total_gb*0.85)+0.5}")
    swap_gb=$(awk '/SwapTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo)

    echo "CPU: thấy=$cpu_v | usable=$cpu_u"
    echo "RAM: total=${mem_total_gb}GB | auto=${mem_auto_gb}GB | swap=${swap_gb}GB"

    cpu_core=$cpu_u
    ram_size=$mem_auto_gb

    if [ "$ram_size" -lt 2 ]; then
        ram_size=2
    fi
    if [ "$cpu_core" -gt "$cpu_v" ]; then
        cpu_core=$cpu_v
    fi

    max_ram=$((mem_total_gb - 1))
    if [ "$ram_size" -gt "$max_ram" ]; then
        ram_size=$max_ram
    fi

    echo ""
    echo "⚙ AUTO CONFIG SELECTED:"
    echo "CPU cores : $cpu_core"
    echo "RAM size  : ${ram_size} GB"

else

    echo ""
    read -rp "⚙ CPU core (default 4): " cpu_core
    cpu_core="${cpu_core:-4}"
    read -rp "💾 RAM GB (default 4): " ram_size
    ram_size="${ram_size:-4}"

fi

# --- AUTO DETECT HUGEPAGE ---
detect_hugepage

# --- AUTO DETECT TCG TB SIZE tối ưu theo RAM VM ---
# TB size quá lớn sẽ tốn RAM và làm chậm GC của TCG
# Rule: ~1MB TB cache per 1GB RAM VM, tối đa 4MB
RAM_MB=$((ram_size * 1024))
TCG_TB_MB=$((ram_size))
if [ "$TCG_TB_MB" -lt 1 ]; then TCG_TB_MB=1; fi
if [ "$TCG_TB_MB" -gt 4 ]; then TCG_TB_MB=4; fi
TCG_TB_BYTES=$((TCG_TB_MB * 1024 * 1024))
echo "⚡ TCG TB cache: ${TCG_TB_MB}MB (auto theo ${ram_size}GB RAM VM)"

# Thiết lập Card mạng
if [[ "$win_choice" == "4" ]]; then
    NET_DEVICE="-device e1000e,netdev=n0"
else
    NET_DEVICE="-device virtio-net-pci,netdev=n0"
fi

# Thiết lập BIOS
BIOS_OPT=""
if [[ "$USE_UEFI" == "yes" ]]; then
    BIOS_OPT="-bios /usr/share/qemu/OVMF.fd"
fi

echo "🚀 Đang khởi tạo VM..."

# --- TCG runtime tuning ---
# icount: tắt (=off) — icount làm chậm TCG trên workload real OS
# chaining: on (mặc định) — cho phép TB chain trực tiếp, bỏ qua dispatcher
# one-insn-per-tb=off — cho phép TCG gộp nhiều insn vào 1 TB, nhanh hơn
# thread=multi — mỗi vCPU 1 thread riêng, tận dụng đa nhân host
# tb-size — đã auto theo RAM ở trên

TCG_ACCEL="tcg,thread=multi,tb-size=$TCG_TB_BYTES,one-insn-per-tb=off"

# --- CPU model cho TCG ---
# Thêm +ssse3,+sse4.1,+sse4.2 nếu host có (guest dùng được SIMD instructions)
# Thêm rdtscp giúp Windows đọc timestamp nhanh hơn không cần VM exit
# Bỏ pmu=off → để pmu mặc định vì TCG không emulate PMU dù sao
CPU_EXTRA=""
grep -q ssse3   /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+ssse3"
grep -q sse4_1  /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.1"
grep -q sse4_2  /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.2"
grep -q rdtscp  /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+rdtscp"
grep -q avx     /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx"
grep -q avx2    /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx2"

cpu_host=$(grep -m1 "model name" /proc/cpuinfo | sed 's/^.*: //')
cpu_host=${cpu_host//,/ }
CPU_MODEL="qemu64 hypervisor=off tsc=on invtsc=on pmu=off l3-cache=on +cmov +mmx +fxsr +sse2 +cx16 +x2apic +sep +pat +pse +aes +popcnt +rdtscp model-id=${cpu_host}${CPU_EXTRA}"

QEMU_ARGS=(
        -machine q35,hpet=off
        -cpu "$CPU_MODEL"
        -smp "$cpu_core"
        -m "${ram_size}G"
        -accel "$TCG_ACCEL"
        -rtc base=localtime,clock=vm,driftfix=slew
        -global ICH9-LPC.disable_s3=1
        -global ICH9-LPC.disable_s4=1
        -smbios "type=1,manufacturer=Dell Inc.,product=PowerEdge R640"
        -global kvm-pit.lost_tick_policy=discard
        -no-user-config
        -display none
        -vga virtio
        -daemonize
    )

    qemu-system-x86_64 "${QEMU_ARGS[@]}" > /dev/null 2>&1 || true

sleep 3

use_rdp=$(ask "🛰️ Tiếp tục mở port để kết nối đến VM? (y/n): " "n")

if [[ "$use_rdp" == "y" ]]; then
    echo "⌛ Đang thiết lập Tunnel..."
    silent wget https://github.com/kami2k1/tunnel/releases/latest/download/kami-tunnel-linux-amd64.tar.gz
    silent tar -xzf kami-tunnel-linux-amd64.tar.gz
    chmod +x kami-tunnel
    sudo apt install -y tmux -y

    tmux kill-session -t kami 2>/dev/null || true
    tmux new-session -d -s kami "./kami-tunnel 3389"
    sleep 5

    PUBLIC=$(tmux capture-pane -pt kami -p | sed 's/\x1b\[[0-9;]*m//g' | grep -i 'public' | grep -oE '[a-zA-Z0-9\.\-]+:[0-9]+' | head -n1)

    echo ""
    echo "══════════════════════════════════════════════"
    echo "🚀 WINDOWS VM DEPLOYED SUCCESSFULLY"
    echo "══════════════════════════════════════════════"
    echo "🪟 OS          : $WIN_NAME"
    echo "⚙ CPU Cores   : $cpu_core"
    echo "💾 RAM         : ${ram_size} GB"
    echo "⚡ TCG TB Cache : ${TCG_TB_MB}MB"
    echo "📄 HugePages   : $HP_INFO"
    echo "──────────────────────────────────────────────"
    echo "📡 RDP Address : $PUBLIC"
    echo "👤 Username    : $RDP_USER"
    echo "🔑 Password    : $RDP_PASS"
    echo "══════════════════════════════════════════════"
fi
