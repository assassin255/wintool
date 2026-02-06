#!/usr/bin/env bash
set -e
#1
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

if [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then
LLVM_VER=19
else
LLVM_VER=15
fi

silent sudo apt update
silent sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools ovmf

export PATH="/usr/lib/llvm-$LLVM_VER/bin:$PATH"
export CC="clang-$LLVM_VER"
export CXX="clang++-$LLVM_VER"
export LD="lld-$LLVM_VER"

python3 -m venv ~/qemu-env
source ~/qemu-env/bin/activate
silent pip install --upgrade pip tomli packaging

rm -rf /tmp/qemu-src /tmp/qemu-build
cd /tmp
silent git clone --depth 1 --branch v10.2.0 https://gitlab.com/qemu-project/qemu.git qemu-src
mkdir /tmp/qemu-build
cd /tmp/qemu-build

EXTRA_CFLAGS="-Ofast -march=native -mtune=native -pipe -flto=full -ffast-math -fuse-ld=lld -fno-rtti -fno-exceptions -fmerge-all-constants -fno-semantic-interposition -fno-plt -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector -funsafe-math-optimizations -ffinite-math-only -fno-math-errno -fstrict-aliasing -funroll-loops -finline-functions -finline-hint-functions -DNDEBUG -DDEFAULT_TCG_TB_SIZE=2097152"
LDFLAGS="-flto=full -fuse-ld=lld -Wl,--lto-O3 -Wl,--gc-sections -Wl,--icf=all -Wl,-O3"

echo "🔁 Đang Biên Dịch..."
silent ../qemu-src/configure \
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
CC="$CC" CXX="$CXX" LD="$LD" CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS"

echo "🕧 QEMU đang được build vui lòng đợi..."
echo "💣Nếu trong quá trình build bị lỗi hãy thử ulimit -n 84857"
ninja -j"$(nproc)"
sudo ninja install

export PATH="/opt/qemu-optimized/bin:$PATH"
qemu-system-x86_64 --version
echo "🔥 QEMU LLVM đã build xong"
fi
else
echo "⚡ Bỏ qua build QEMU."
fi

echo ""
echo "════════════════════════════════════"
echo "🖥️  WINDOWS VM MANAGER"
echo "════════════════════════════════════"
echo "1️⃣  Tạo Windows VM"
echo "2️⃣  Quản Lý Windows VM"
echo "════════════════════════════════════"
read -rp "👉 Nhập lựa chọn [1-2]: " main_choice

case "$main_choice" in
1)
;;
2)
echo ""
echo -e "\033[1;36m🚀 ===== MANAGE RUNNING VM ===== 🚀\033[0m"

VM_LIST=$(pgrep -f '^qemu-system')

if [[ -z "$VM_LIST" ]]; then
  echo "❌ Không có VM nào đang chạy"
else
  for pid in $VM_LIST; do
    cmd=$(tr '\0' ' ' < /proc/$pid/cmdline)
    vcpu=$(echo "$cmd" | sed -n 's/.*-smp \([^ ,]*\).*/\1/p')
    ram=$(echo "$cmd" | sed -n 's/.*-m \([^ ]*\).*/\1/p')
    cpu=$(ps -p $pid -o %cpu=)
    mem=$(ps -p $pid -o %mem=)

    echo -e "🆔 PID: \033[1;33m$pid\033[0m  |  🔢 vCPU: \033[1;34m${vcpu}\033[0m  |  📦 VM RAM: \033[1;34m${ram}\033[0m  |  🧠 CPU: \033[1;32m${cpu}%\033[0m  |  💾 Host RAM: \033[1;35m${mem}%\033[0m"
  done
fi

echo -e "\033[1;36m==================================\033[0m"
read -rp "🆔 Nhập PID VM muốn tắt (hoặc Enter để bỏ qua): " kill_pid

if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
  kill "$kill_pid" 2>/dev/null || true
  echo "✅ Đã gửi tín hiệu tắt VM PID $kill_pid"
fi
;;
esac

echo ""
echo "🪟 Chọn phiên bản Windows muốn tải:"
echo "1️⃣ Windows Server 2012 R2"
echo "2️⃣ Windows Server 2022"
echo "3️⃣ Windows 11 LTSB"
read -rp "👉 Nhập số [1-3]: " win_choice

case "$win_choice" in
1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
2) WIN_NAME="Windows Server 2022"; WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img"; USE_UEFI="no" ;;
3) WIN_NAME="Windows 11 LTSB"; WIN_URL="https://archive.org/download/win_20260203/win.img"; USE_UEFI="yes" ;;
*) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no" ;;
esac

if [[ "$win_choice" == "3" ]]; then
RDP_USER="Admin"
RDP_PASS="Tam255Z"
else
RDP_USER="administrator"
RDP_PASS="Tamnguyenyt@123"
fi

echo "🪟 Đang Tải $WIN_NAME..."
if [[ ! -f win.img ]]; then
silent aria2c -x16 -s16 --continue --file-allocation=none "$WIN_URL" -o win.img
fi

read -rp "📦 Mở rộng đĩa thêm bao nhiêu GB (default 20)? " extra_gb
extra_gb="${extra_gb:-20}"
silent qemu-img resize win.img "+${extra_gb}G"

cpu_host=$(grep -m1 "model name" /proc/cpuinfo | sed 's/^.*: //')
cpu_model="qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse,model-id=${cpu_host}"

read -rp "⚙ CPU core (default 4): " cpu_core
cpu_core="${cpu_core:-4}"

read -rp "💾 RAM GB (default 4): " ram_size
ram_size="${ram_size:-4}"

if [[ "$USE_UEFI" == "yes" ]]; then
BIOS_OPT="-bios /usr/share/qemu/OVMF.fd"
else
BIOS_OPT=""
fi

qemu-system-x86_64 \
-machine q35,hpet=off,pit=off \
-cpu "$cpu_model" \
-smp "$cpu_core" \
-m "${ram_size}G" \
-accel tcg,thread=multi,tb-size=2097152 \
-rtc base=localtime \
$BIOS_OPT \
-drive file=win.img,if=virtio,cache=unsafe,aio=threads,format=raw \
-netdev user,id=n0,hostfwd=tcp::3389-:3389 \
-device virtio-net-pci,netdev=n0 \
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

use_rdp=$(ask "🛰️ Tiếp tục mở port để kết nối đến VM? (y/n): " "n")
echo "⌛ Đang Tạo VM với cấu hình bạn đã nhập vui lòng đợi..."

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
echo "🚀 WINDOWS VM DEPLOYED SUCCESSFULLY"
echo "══════════════════════════════════════════════"
echo "🪟 OS          : $WIN_NAME"
echo "⚙ CPU Cores   : $cpu_core"
echo "💾 RAM         : ${ram_size} GB"
echo "🧠 CPU Host    : $cpu_host"
echo "──────────────────────────────────────────────"
echo "📡 RDP Address : $PUBLIC"
echo "👤 Username    : $RDP_USER"
echo "🔑 Password    : $RDP_PASS"
echo "══════════════════════════════════════════════"
echo "🟢 Status      : RUNNING"
echo "⏱ GUI Mode   : Headless / RDP"
echo "══════════════════════════════════════════════"
fi
