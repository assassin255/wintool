#!/bin/bash
# ============================================================
#  Build HQEMU 2.5.2 with TCG LLVM Backend
#  Tested on: Debian 13 (Trixie) x86_64
#  LLVM:      3.9.1 (pre-built from releases.llvm.org)
#  Build time: ~2 minutes
# ============================================================
set -e

echo "============================================================"
echo "  HQEMU 2.5.2 + LLVM TCG Backend - Build Script"
echo "============================================================"

# ---- 1. Install build dependencies ----
echo "[1/7] Installing build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential pkg-config g++ \
    libglib2.0-dev libpixman-1-dev zlib1g-dev libfdt-dev \
    libncurses-dev xz-utils curl

# ---- 2. Download LLVM 3.9.1 pre-built + libtinfo5 + HQEMU source ----
echo "[2/7] Downloading LLVM 3.9.1, libtinfo5, HQEMU 2.5.2..."
cd /tmp
curl -sSL "https://releases.llvm.org/3.9.1/clang+llvm-3.9.1-x86_64-linux-gnu-ubuntu-16.04.tar.xz" -o llvm39.tar.xz
curl -sSL "https://gist.githubusercontent.com/leper/993220c28aa9b4985fa3f2f47c276c7e/raw/8874b2c5d1acac69f6e9efc0ee3f20ea6955ddf4/hqemu-2.5.2.tar.gz" -o hqemu.tar.gz
curl -sSL "http://archive.ubuntu.com/ubuntu/pool/main/n/ncurses/libtinfo5_6.0+20160213-1ubuntu1_amd64.deb" -o libtinfo5.deb

# ---- 3. Install libtinfo5 (LLVM 3.9 binary depends on it) ----
echo "[3/7] Installing libtinfo5 compatibility library..."
dpkg -x libtinfo5.deb /tmp/nc5
sudo cp /tmp/nc5/lib/x86_64-linux-gnu/libtinfo.so.5* /usr/lib/x86_64-linux-gnu/
sudo ldconfig 2>/dev/null || true

# ---- 4. Extract LLVM 3.9.1 & HQEMU ----
echo "[4/7] Extracting..."
tar xf llvm39.tar.xz
tar xzf hqemu.tar.gz

LLVM_DIR="/tmp/clang+llvm-3.9.1-x86_64-linux-gnu-ubuntu-16.04"

# Create llvm-config wrapper that strips Clang-only flags (GCC doesn't understand them)
python3 -c "
open('/tmp/llvm-config','w').write(
    '#!/bin/bash\n'
    '$LLVM_DIR/bin/llvm-config \"\$@\"'
    ' | sed \"s/-Wcovered-switch-default//g;'
    's/-Wstring-conversion//g;'
    's/-Werror=unguarded-availability-new//g;'
    's/-Wdelete-non-virtual-dtor//g;'
    's/-Wno-nested-anon-types//g;'
    's/-fcolor-diagnostics//g\"\n'
)
"
chmod +x /tmp/llvm-config
export PATH="/tmp:$LLVM_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$LLVM_DIR/lib"
echo "    LLVM version: $(llvm-config --version)"

# ---- 5. Patch HQEMU for modern toolchain ----
echo "[5/7] Patching HQEMU..."
cd /tmp/hqemu-2.5.2
PY=$(which python3)

# 5a. Allow Python 3 in configure (original only supports Python 2)
python3 -c "
c = open('configure').read()
c = c.replace('sys.version_info >= (3,)', 'False')
open('configure','w').write(c)
"

# 5b. Replace Python 2 ordereddict polyfill with stdlib
echo "from collections import OrderedDict" > scripts/ordereddict.py

# 5c. Fix Python 2 syntax in qapi.py
python3 -c "
import re
c = open('scripts/qapi.py').read()
c = c.replace('string.maketrans(', 'str.maketrans(')
c = c.replace('basestring', 'str')
c = re.sub(r'(\w+)\.has_key\(([^)]+)\)', r'\2 in \1', c)
open('scripts/qapi.py','w').write(c)
"

# 5d. Convert remaining Python 2 scripts to Python 3
2to3 -w -n scripts/ tests/ 2>/dev/null | tail -1

# 5e. Fix HQEMU LLVM code:
#     - Comment out setMCJITMemoryManager (uses HQEMU custom shared_ptr, MCJIT default works)
#     - Comment out setHQEMUExitAddr (requires patched LLVM headers)
python3 -c "
import re
c = open('llvm/llvm-opc.cpp').read()
c = c.replace(
    'builder.setMCJITMemoryManager(LLEnv->getMemoryManager());',
    '// MM: using MCJIT default memory manager'
)
c = re.sub(r'MII->setHQEMUExitAddr.*', '// setHQEMUExitAddr: requires patched LLVM', c)
open('llvm/llvm-opc.cpp','w').write(c)
"

# 5f. Add missing #include <cerrno> in PMU header (GCC 14 stricter than old GCC)
python3 -c "
c = open('llvm/include/pmu/pmu-utils.h').read()
if '#include <cerrno>' not in c:
    c = '#include <cerrno>\n' + c
open('llvm/include/pmu/pmu-utils.h','w').write(c)
"

# ---- 6. Configure ----
echo "[6/7] Configuring..."
mkdir -p build && cd build
../configure \
    --enable-llvm \
    --target-list=x86_64-softmmu \
    --python=$PY \
    --disable-werror \
    --disable-docs \
    --disable-guest-agent \
    --extra-ldflags="-lncurses" 

# ---- 7. Build ----
echo "[7/7] Building (make -j$(nproc))..."
make -j$(nproc)

# ---- Done! ----
echo ""
echo "============================================================"
echo "  BUILD SUCCESSFUL!"
echo "============================================================"
LD_LIBRARY_PATH="$LLVM_DIR/lib" ./x86_64-softmmu/qemu-system-x86_64 --version
ls -lh x86_64-softmmu/qemu-system-x86_64
echo ""
echo "  Binary: $(pwd)/x86_64-softmmu/qemu-system-x86_64"
echo ""
echo "  Run with LLVM optimization:"
echo "    export LD_LIBRARY_PATH=$LLVM_DIR/lib"
echo "    export LLVM_MODE=1"
echo "    ./x86_64-softmmu/qemu-system-x86_64 [options]"
echo "============================================================"
