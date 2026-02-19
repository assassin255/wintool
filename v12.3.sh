#!/usr/bin/env bash
set -e

# QEMU 10.2.1 TCG + LLVM Extreme Build (V12.3 - Final Tested Version)
# Improvements in V12.3:
#   - Full restoration of 50 extreme performance patches.
#   - Verified qemu-img functionality (Fixed "command not found").
#   - Enhanced VM startup logic (Added multi-path BIOS detection).
#   - Real-time error reporting (Displays log if VM fails to start).
#   - Optimized PATH handling for both built and system binaries.

silent() { "$@" > /dev/null 2>&1; }
ask() { read -rp "$1" ans; ans="${ans,,}"; echo "${ans:-$2}"; }

# Fix Python apt_pkg issue
if [ -f /usr/lib/python3/dist-packages/apt_pkg.cpython-310-x86_64-linux-gnu.so ] && [ ! -f /usr/lib/python3/dist-packages/apt_pkg.so ]; then
    sudo ln -sf /usr/lib/python3/dist-packages/apt_pkg.cpython-310-x86_64-linux-gnu.so /usr/lib/python3/dist-packages/apt_pkg.so
fi

choice=$(ask "Build QEMU with LLVM TCG optimization? (y/n): " "n")

if [[ "$choice" != "y" ]]; then
    echo "Skipping build. Checking for existing installation..."
    if [ -x /opt/qemu-llvm/bin/qemu-system-x86_64 ]; then
        export PATH="/opt/qemu-llvm/bin:$PATH"
    else
        echo "[!] QEMU not found in /opt/qemu-llvm. Installing system version..."
        sudo apt update && sudo apt install -y qemu-system-x86 qemu-utils aria2 ovmf
    fi
else
if [ -x /opt/qemu-llvm/bin/qemu-system-x86_64 ] && [ -x /opt/qemu-llvm/bin/qemu-img ]; then
    echo "[OK] QEMU LLVM already installed"
    export PATH="/opt/qemu-llvm/bin:$PATH"
else

echo "=== [1/6] Dependencies ==="
sudo apt update
sudo apt install -y lsb-release software-properties-common wget gnupg build-essential \
    ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev \
    zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf liburing-dev libjemalloc-dev \
    qemu-utils 2>/dev/null || true

OS_ID="$(. /etc/os-release && echo "$ID")"
if [[ "$OS_ID" == "ubuntu" ]]; then
    wget -q https://apt.llvm.org/llvm.sh && chmod +x llvm.sh
    sudo ./llvm.sh 21
    LLVM_VER=21
    sudo apt install -y llvm-$LLVM_VER-tools 2>/dev/null || true
else
    LLVM_VER=15
    sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER \
        llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools 2>/dev/null || true
fi

export CC="clang-$LLVM_VER"
export CXX="clang++-$LLVM_VER"
export LD="lld-$LLVM_VER"

echo "=== [2/6] Cloning QEMU 10.2.1 ==="
rm -rf /tmp/qemu-src /tmp/qemu-build
cd /tmp
silent git clone --depth 1 --branch v10.2.1 https://gitlab.com/qemu-project/qemu.git qemu-src

echo "=== [3/6] V12.3 Patches (50 total) ==="
cd /tmp/qemu-src
# TCG Optimizations
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
BASE="-O3 -march=native -mtune=native -pipe -fno-strict-aliasing -fmerge-all-constants -fno-semantic-interposition -fno-plt -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector -funroll-loops -finline-functions -DNDEBUG"
POLLY="-mllvm -polly -mllvm -polly-vectorizer=stripmine"
INLINE="-mllvm -inline-threshold=500 -mllvm -inlinehint-threshold=1000"
mkdir -p /tmp/qemu-build && cd /tmp/qemu-build
../qemu-src/configure --prefix=/opt/qemu-llvm --target-list=x86_64-softmmu --enable-tcg --enable-slirp --enable-coroutine-pool --enable-lto --disable-kvm --disable-gtk --disable-sdl --disable-vnc CC=$CC CXX=$CXX CFLAGS="$BASE $POLLY $INLINE -flto=full" LDFLAGS="-fuse-ld=lld -flto=full -Wl,--lto-O3"

echo "=== [5/6] Build ==="
ulimit -n 65535 || true
ninja -j"$(nproc)" qemu-system-x86_64 qemu-img

echo "=== [6/6] Installing ==="
sudo mkdir -p /opt/qemu-llvm/bin /opt/qemu-llvm/share/qemu
sudo cp qemu-system-x86_64 qemu-img /opt/qemu-llvm/bin/
sudo cp /tmp/qemu-src/pc-bios/*.bin /opt/qemu-llvm/share/qemu/ 2>/dev/null || true
sudo cp /tmp/qemu-src/pc-bios/*.rom /opt/qemu-llvm/share/qemu/ 2>/dev/null || true
sudo cp /tmp/qemu-src/pc-bios/*.img /opt/qemu-llvm/share/qemu/ 2>/dev/null || true
sudo cp /tmp/qemu-src/pc-bios/*.fd /opt/qemu-llvm/share/qemu/ 2>/dev/null || true
export PATH="/opt/qemu-llvm/bin:$PATH"
echo "BUILD COMPLETE (V12.3)"
fi
fi

# VM MANAGER
echo "========================================"
echo "  WINDOWS VM MANAGER (V12.3)"
echo "========================================"
echo "1) Create/Start Windows VM"
echo "2) Kill Running VMs"
read -rp "Choice: " main_choice
[[ "$main_choice" == "2" ]] && pkill -f qemu-system-x86_64 && echo "Killed." && exit 0

echo "Select Windows (1-5): "
read -rp "Choice: " wc
case "$wc" in
1) WN="WinSrv2012R2"; WU="https://archive.org/download/tamnguyen-2012r2/2012.img"; UE=no ;;
2) WN="WinSrv2022"; WU="https://archive.org/download/tamnguyen-2022/2022.img"; UE=no ;;
3) WN="Win11LTSB"; WU="https://archive.org/download/win_20260203/win.img"; UE=yes ;;
4) WN="Win10LTSB2015"; WU="https://archive.org/download/win_20260208/win.img"; UE=no ;;
5) WN="Win10LTSC2023"; WU="https://archive.org/download/win_20260215/win.img"; UE=no ;;
*) WN="WinSrv2012R2"; WU="https://archive.org/download/tamnguyen-2012r2/2012.img"; UE=no ;;
esac

[[ ! -f win.img ]] && aria2c -x16 -s16 "$WU" -o win.img
read -rp "Expand disk GB (20): " eg; eg="${eg:-20}"

# Find qemu-img reliably
QIMG=$(command -v qemu-img || echo "/opt/qemu-llvm/bin/qemu-img")
if ! command -v "$QIMG" &> /dev/null; then
    sudo apt update && sudo apt install -y qemu-utils
    QIMG=$(command -v qemu-img)
fi
$QIMG resize win.img "+${eg}G"

read -rp "Cores (4): " cc; cc="${cc:-4}"
read -rp "RAM GB (4): " rs; rs="${rs:-4}"

# Find QEMU binary reliably
QBIN=$(command -v qemu-system-x86_64 || echo "/opt/qemu-llvm/bin/qemu-system-x86_64")
BO=""; [[ "$UE" == "yes" ]] && BO="-bios /opt/qemu-llvm/share/qemu/OVMF.fd"

echo "Starting VM... (Check /tmp/qemu_error.log if it fails)"
# Added multiple BIOS paths for maximum compatibility
$QBIN \
    -L /opt/qemu-llvm/share/qemu \
    -L /usr/share/qemu \
    -L /usr/share/ovmf \
    -L /usr/lib/ipxe/qemu \
    -machine q35,hpet=off \
    -cpu qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on \
    -smp $cc,sockets=1,cores=$cc,threads=1 \
    -m ${rs}G \
    -accel tcg,thread=multi \
    -rtc base=localtime $BO \
    -drive file=win.img,if=virtio,cache=unsafe,format=raw \
    -netdev user,id=n0,hostfwd=tcp::3389-:3389 -device virtio-net-pci,netdev=n0 \
    -display none -vga virtio -daemonize 2>/tmp/qemu_error.log

sleep 4
if pgrep -f qemu-system-x86_64 > /dev/null; then
    echo "SUCCESS: VM Deployed! Access via RDP on port 3389."
else
    echo "CRITICAL ERROR: VM failed to start."
    echo "Detailed Error Log:"
    cat /tmp/qemu_error.log
fi
