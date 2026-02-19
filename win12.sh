#!/usr/bin/env bash
set -e

# QEMU 10.2.1 TCG + LLVM Extreme Build (V11 - Fixed Edition)
# LTO=full + Polly + 44 Hot Path Patches + 6 Fast DBT Patches = 50 total
# Improvements in V11:
#   - Automated dependency installation (lsb-release, software-properties-common)
#   - Python apt_pkg symlink fix for Ubuntu
#   - ulimit -n increase for LTO linking
#   - Complete BIOS/Firmware copy fix
#   - Corrected BIOS path in VM Manager

silent() { "$@" > /dev/null 2>&1; }
ask() { read -rp "$1" ans; ans="${ans,,}"; echo "${ans:-$2}"; }

# Fix Python apt_pkg issue before starting (common on Ubuntu)
if [ -f /usr/lib/python3/dist-packages/apt_pkg.cpython-310-x86_64-linux-gnu.so ] && [ ! -f /usr/lib/python3/dist-packages/apt_pkg.so ]; then
    sudo ln -sf /usr/lib/python3/dist-packages/apt_pkg.cpython-310-x86_64-linux-gnu.so /usr/lib/python3/dist-packages/apt_pkg.so
fi

choice=$(ask "Build QEMU with LLVM TCG optimization? (y/n): " "n")

if [[ "$choice" != "y" ]]; then
    echo "Skipping build."
    [ -x /opt/qemu-llvm/bin/qemu-system-x86_64 ] && export PATH="/opt/qemu-llvm/bin:$PATH"
else
if [ -x /opt/qemu-llvm/bin/qemu-system-x86_64 ]; then
    echo "[OK] QEMU LLVM already installed"
    export PATH="/opt/qemu-llvm/bin:$PATH"
else

echo "=== [1/6] Dependencies ==="
sudo apt update
sudo apt install -y lsb-release software-properties-common wget gnupg build-essential \
    ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev \
    zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf liburing-dev libjemalloc-dev 2>/dev/null || true

OS_ID="$(. /etc/os-release && echo "$ID")"
OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

if [[ "$OS_ID" == "ubuntu" ]]; then
    wget -q https://apt.llvm.org/llvm.sh && chmod +x llvm.sh
    sudo ./llvm.sh 21
    LLVM_VER=21
    sudo apt install -y llvm-$LLVM_VER-tools 2>/dev/null || true
elif [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
    LLVM_VER=19
    sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER \
        llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools 2>/dev/null || true
else
    LLVM_VER=15
    sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER \
        llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools 2>/dev/null || true
fi

export CC="clang-$LLVM_VER"
export CXX="clang++-$LLVM_VER"
export LD="lld-$LLVM_VER"
echo "Compiler: $CC"

echo "=== [2/6] Cloning QEMU 10.2.1 ==="
rm -rf /tmp/qemu-src /tmp/qemu-build
cd /tmp
silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

echo "=== [3/6] V11 Patches (50 total) ==="
cd /tmp/qemu-src

# Apply patches (same as V10)
sed -i '/^int tcg_gen_code(TCGContext \*s, TranslationBlock \*tb/i\/* V10 */ __attribute__((hot, optimize("O3")))' tcg/tcg.c
sed -i '/^static void tcg_reg_alloc_op(TCGContext \*s/i\/* V10 */ __attribute__((hot, flatten))' tcg/tcg.c
sed -i '/^static void tcg_reg_alloc_mov(TCGContext \*s/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
sed -i '/^static TCGReg tcg_reg_alloc(TCGContext \*s, TCGRegSet required_regs/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
sed -i '/^static void tcg_reg_alloc_call(TCGContext \*s, TCGOp \*op)/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
sed -i '/^static void tcg_reg_alloc_dup(TCGContext \*s/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
sed -i '/^static void temp_load(TCGContext \*s, TCGTemp \*ts, TCGRegSet desired/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
sed -i '/^static void temp_sync(TCGContext \*s, TCGTemp \*ts, TCGRegSet allocated/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
sed -i '/^static void temp_save(TCGContext \*s, TCGTemp \*ts, TCGRegSet allocated/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
sed -i '/^static int tcg_out_ldst_finalize(TCGContext \*s)/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
sed -i '/^TranslationBlock \*tcg_tb_alloc(TCGContext \*s)/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
sed -i '/^void tcg_func_start(TCGContext \*s)/i\/* V10 */ __attribute__((hot))' tcg/tcg.c
sed -i '/^void tcg_optimize(TCGContext \*s)/i\/* V10 */ __attribute__((hot, optimize("O3")))' tcg/optimize.c
sed -i '/^static bool tcg_opt_gen_mov(OptContext \*ctx/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
sed -i '/^static bool tcg_opt_gen_movi(OptContext \*ctx/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
sed -i '/^static bool finish_folding(OptContext \*ctx, TCGOp \*op)/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
sed -i '/^static void copy_propagate(OptContext \*ctx/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
sed -i '/^static void init_arguments(OptContext \*ctx/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
sed -i '/^static bool fold_brcond(OptContext \*ctx/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
sed -i '/^static int do_constant_folding_cond(TCGType type/i\/* V10 */ __attribute__((hot))' tcg/optimize.c
sed -i '/^void tcg_gen_exit_tb(const TranslationBlock \*tb/i\/* V10 */ __attribute__((hot))' tcg/tcg-op.c
sed -i '/^void tcg_gen_goto_tb(unsigned idx)/i\/* V10 */ __attribute__((hot))' tcg/tcg-op.c
sed -i '/^void tcg_gen_lookup_and_goto_ptr(void)/i\/* V10 */ __attribute__((hot))' tcg/tcg-op.c
sed -i '/^int cpu_exec(CPUState \*cpu)/i\/* V10 */ __attribute__((hot))' accel/tcg/cpu-exec.c
sed -i 's/static inline TranslationBlock \*tb_lookup(/static inline __attribute__((always_inline)) TranslationBlock *tb_lookup(/' accel/tcg/cpu-exec.c
sed -i '/^static bool tb_lookup_cmp(const void \*p/i\/* V10 */ __attribute__((hot))' accel/tcg/cpu-exec.c
sed -i '/^static TranslationBlock \*tb_htable_lookup/i\/* V10 */ __attribute__((hot))' accel/tcg/cpu-exec.c
sed -i '/^static inline void cpu_loop_exec_tb/i\/* V10 */ __attribute__((hot, flatten))' accel/tcg/cpu-exec.c
sed -i 's/static inline void tb_add_jump(/static inline __attribute__((always_inline)) void tb_add_jump(/' accel/tcg/cpu-exec.c
sed -i 's/static inline bool cpu_handle_interrupt(/static inline __attribute__((always_inline)) bool cpu_handle_interrupt(/' accel/tcg/cpu-exec.c
sed -i 's/static inline bool cpu_handle_exception(/static inline __attribute__((always_inline)) bool cpu_handle_exception(/' accel/tcg/cpu-exec.c
sed -i 's/if (\*tb_exit != TB_EXIT_REQUESTED)/if (__builtin_expect(*tb_exit != TB_EXIT_REQUESTED, 1))/' accel/tcg/cpu-exec.c
sed -i 's/if (phys_pc == -1) {/if (__builtin_expect(phys_pc == -1, 0)) {/' accel/tcg/cpu-exec.c
sed -i 's/if (tb == NULL) {/if (__builtin_expect(tb == NULL, 0)) {/' accel/tcg/cpu-exec.c
sed -i '1i\/* V10 - TLB hot path */' accel/tcg/cputlb.c
sed -i '/^static bool victim_tlb_hit/i\__attribute__((hot, flatten))' accel/tcg/cputlb.c
sed -i 's/static inline bool tlb_hit(uint64_t/static inline __attribute__((always_inline)) bool tlb_hit(uint64_t/' accel/tcg/cputlb.c
sed -i 's/static inline bool tlb_hit_page(uint64_t/static inline __attribute__((always_inline)) bool tlb_hit_page(uint64_t/' accel/tcg/cputlb.c
sed -i 's/static inline uintptr_t tlb_index(/static inline __attribute__((always_inline)) uintptr_t tlb_index(/' accel/tcg/cputlb.c
sed -i 's/static inline CPUTLBEntry \*tlb_entry(/static inline __attribute__((always_inline)) CPUTLBEntry *tlb_entry(/' accel/tcg/cputlb.c
sed -i 's/static inline uint64_t tlb_read_idx(/static inline __attribute__((always_inline)) uint64_t tlb_read_idx(/' accel/tcg/cputlb.c
sed -i '/^static bool tlb_fill_align(/i\/* V10 */ __attribute__((hot))' accel/tcg/cputlb.c
sed -i '/^void tlb_set_page_full(/i\/* V10 */ __attribute__((hot))' accel/tcg/cputlb.c
sed -i 's/static inline void copy_tlb_helper_locked(/static inline __attribute__((always_inline)) void copy_tlb_helper_locked(/' accel/tcg/cputlb.c
sed -i '/^TranslationBlock \*tb_gen_code(CPUState \*cpu/i\/* V10 */ __attribute__((hot))' accel/tcg/translate-all.c
sed -i '/^static bool tb_cmp(const void \*ap/i\/* V10 */ __attribute__((hot))' accel/tcg/tb-maint.c
sed -i '/^void translator_loop(CPUState \*cpu/i\/* V10 */ __attribute__((hot))' accel/tcg/translator.c
sed -i 's/#define TB_JMP_CACHE_BITS 12/#define TB_JMP_CACHE_BITS 13/' accel/tcg/tb-jmp-cache.h
sed -i 's/#define CPU_TEMP_BUF_NLONGS 128/#define CPU_TEMP_BUF_NLONGS 256/' include/tcg/tcg.h
sed -i 's/#define TCG_MAX_TEMPS 512/#define TCG_MAX_TEMPS 1024/' include/tcg/tcg.h

echo "=== [4/6] Configure ==="
BASE="-O3 -march=native -mtune=native -pipe -fno-strict-aliasing"
BASE="$BASE -fmerge-all-constants -fno-semantic-interposition -fno-plt"
BASE="$BASE -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables"
BASE="$BASE -fno-stack-protector -funroll-loops -finline-functions -DNDEBUG"
POLLY="-mllvm -polly -mllvm -polly-vectorizer=stripmine"
INLINE="-mllvm -inline-threshold=500 -mllvm -inlinehint-threshold=1000"
FINAL_CFLAGS="$BASE $POLLY $INLINE -flto=full"
FINAL_LDFLAGS="-fuse-ld=lld -flto=full -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"

mkdir -p /tmp/qemu-build && cd /tmp/qemu-build
../qemu-src/configure \
    --prefix=/opt/qemu-llvm \
    --target-list=x86_64-softmmu \
    --enable-tcg --enable-slirp --enable-coroutine-pool --enable-lto \
    --disable-kvm --disable-mshv --disable-xen \
    --disable-gtk --disable-sdl --disable-spice --disable-vnc \
    --disable-plugins --disable-debug-info --disable-docs --disable-werror \
    --disable-fdt --disable-vdi --disable-vvfat --disable-cloop --disable-dmg \
    --disable-pa --disable-alsa --disable-oss --disable-jack \
    --disable-gnutls --disable-smartcard --disable-libusb \
    --disable-seccomp --disable-modules \
    CC=$CC CXX=$CXX \
    CFLAGS="$FINAL_CFLAGS" CXXFLAGS="$FINAL_CFLAGS" LDFLAGS="$FINAL_LDFLAGS"

echo "=== [5/6] Build (LTO=full + Polly + 50 patches) ==="
# Fix for LTO linking: increase open files limit
ulimit -n 65535 || true
ninja -j"$(nproc)" qemu-system-x86_64

echo "=== [6/6] Installing ==="
sudo mkdir -p /opt/qemu-llvm/bin /opt/qemu-llvm/share/qemu
sudo cp qemu-system-x86_64 /opt/qemu-llvm/bin/
# Fixed BIOS copy: ensure all firmware files are included
sudo cp /tmp/qemu-src/pc-bios/*.bin /opt/qemu-llvm/share/qemu/ 2>/dev/null || true
sudo cp /tmp/qemu-src/pc-bios/*.rom /opt/qemu-llvm/share/qemu/ 2>/dev/null || true
sudo cp /tmp/qemu-src/pc-bios/*.img /opt/qemu-llvm/share/qemu/ 2>/dev/null || true
sudo cp /tmp/qemu-src/pc-bios/*.fd /opt/qemu-llvm/share/qemu/ 2>/dev/null || true
sudo cp -r /tmp/qemu-src/pc-bios/descriptors /opt/qemu-llvm/share/qemu/ 2>/dev/null || true
sudo cp -r /tmp/qemu-src/pc-bios/keymaps /opt/qemu-llvm/share/qemu/ 2>/dev/null || true

export PATH="/opt/qemu-llvm/bin:$PATH"

# Kernel tuning
sudo sysctl -w vm.nr_hugepages=512 2>/dev/null || true
sudo sysctl -w vm.dirty_background_ratio=5 2>/dev/null || true
sudo sysctl -w vm.swappiness=10 2>/dev/null || true

echo "BUILD COMPLETE (V11)"
/opt/qemu-llvm/bin/qemu-system-x86_64 --version
fi
fi

#=========================================================================
# VM MANAGER (V11 Fixed)
#=========================================================================
echo ""
echo "========================================"
echo "  WINDOWS VM MANAGER (V11)"
echo "========================================"
echo "1) Create Windows VM"
echo "2) Manage Running VMs"
read -rp "Choice [1-2]: " main_choice
case "$main_choice" in
2)
    VM_LIST=$(pgrep -f "^qemu-system" || true)
    if [[ -z "$VM_LIST" ]]; then echo "No VMs running"
    else
        for pid in $VM_LIST; do
            cmd=$(tr '\0' ' ' < /proc/$pid/cmdline)
            vcpu=$(echo "$cmd" | sed -n 's/.*-smp \([^ ,]*\).*/\1/p')
            ram=$(echo "$cmd" | sed -n 's/.*-m \([^ ]*\).*/\1/p')
            echo "PID:$pid vCPU:$vcpu RAM:$ram CPU:$(ps -p $pid -o %cpu=)% MEM:$(ps -p $pid -o %mem=)%"
        done
    fi
    read -rp "PID to kill (Enter=skip): " kp
    [[ -n "$kp" && -d "/proc/$kp" ]] && kill "$kp" 2>/dev/null && echo "Killed $kp"
    exit 0 ;;
esac

echo "Select Windows:"
echo "1) Server 2012 R2  2) Server 2022  3) Win 11 LTSB  4) Win 10 LTSB 2015  5) Win 10 LTSC 2023"
read -rp "Choice [1-5]: " wc
case "$wc" in
1) WN="WinSrv2012R2"; WU="https://archive.org/download/tamnguyen-2012r2/2012.img"; UE=no ;;
2) WN="WinSrv2022"; WU="https://archive.org/download/tamnguyen-2022/2022.img"; UE=no ;;
3) WN="Win11LTSB"; WU="https://archive.org/download/win_20260203/win.img"; UE=yes ;;
4) WN="Win10LTSB2015"; WU="https://archive.org/download/win_20260208/win.img"; UE=no ;;
5) WN="Win10LTSC2023"; WU="https://archive.org/download/win_20260215/win.img"; UE=no ;;
*) WN="WinSrv2012R2"; WU="https://archive.org/download/tamnguyen-2012r2/2012.img"; UE=no ;;
esac
case "$wc" in 3|4|5) RU="Admin"; RP="Tam255Z" ;; *) RU="administrator"; RP="Tamnguyenyt@123" ;; esac

echo "Downloading $WN..."
[[ ! -f win.img ]] && aria2c -x16 -s16 --continue --file-allocation=none "$WU" -o win.img
read -rp "Expand disk GB (default 20): " eg; eg="${eg:-20}"
[[ "$eg" != "0" ]] && qemu-img resize win.img "+${eg}G"

cpu_host=$(grep -m1 'model name' /proc/cpuinfo | sed 's/^.*: //')
CM="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"
read -rp "CPU cores (default 4): " cc; cc="${cc:-4}"
read -rp "RAM GB (default 4): " rs; rs="${rs:-4}"

HRK=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TS=$((HRK/4)); [ $TS -gt 2097152 ] && TS=2097152; [ $TS -lt 262144 ] && TS=262144
AIO=threads; [ -f /usr/include/liburing.h ] && AIO=io_uring
[[ "$wc" == "4" ]] && ND="-device e1000e,netdev=n0" || ND="-device virtio-net-pci,netdev=n0"
BO=""; [[ "$UE" == "yes" ]] && BO="-bios /opt/qemu-llvm/share/qemu/OVMF.fd"
JP=""; [ -f /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 ] && JP="LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2"
MP=""; [ -d /dev/hugepages ] && [ "$(cat /proc/sys/vm/nr_hugepages 2>/dev/null)" -gt 0 ] && MP="-mem-path /dev/hugepages -mem-prealloc"

echo "Starting VM: tb=${TS}KB aio=$AIO cores=$cc ram=${rs}G"

# Fixed: Added -L /opt/qemu-llvm/share/qemu to ensure BIOS is found
env $JP /opt/qemu-llvm/bin/qemu-system-x86_64 \
    -L /opt/qemu-llvm/share/qemu \
    -machine q35,hpet=off -cpu "$CM" \
    -smp $cc,sockets=1,cores=$cc,threads=1 -m ${rs}G \
    -accel tcg,thread=multi,tb-size=$TS \
    -rtc base=localtime $BO $MP \
    -drive file=win.img,if=virtio,cache=unsafe,aio=$AIO,format=raw \
    -netdev user,id=n0,hostfwd=tcp::3389-:3389 $ND \
    -device virtio-mouse-pci -device virtio-keyboard-pci \
    -nodefaults -global ICH9-LPC.disable_s3=1 -global ICH9-LPC.disable_s4=1 \
    -smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640" \
    -global kvm-pit.lost_tick_policy=discard \
    -no-user-config -display none -vga virtio -daemonize >/dev/null 2>&1 || true

echo "VM Deployed! Access via RDP on port 3389."
