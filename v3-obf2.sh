#!/usr/bin/env bash
set -euo pipefail

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
RESET='\033[0m'

QEMU_PREFIX='/opt/qemu-optimized'
QEMU_BIN="$QEMU_PREFIX/bin/qemu-system-x86_64"
QEMU_IMG="$QEMU_PREFIX/bin/qemu-img"
QEMU_LOG='/dev/shm/v3-obf2-qemu.log'
DASHBOARD_PORT=8080
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_DIR="$SCRIPT_DIR/vm-dashboard"
DASHBOARD_SERVER="$DASHBOARD_DIR/server.py"
DASHBOARD_LOG='/dev/shm/v3-obf2-dashboard.log'
DASHBOARD_URL="http://127.0.0.1:${DASHBOARD_PORT}"
PUBLIC_TUNNEL_URL=""
TUNNEL_PID_FILE="/dev/shm/v3-obf2-lt.pid"
TB_SIZE='3097152'
TCG_CPU_BASE='qemu64,hypervisor=off,tsc=on,invtsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+ssse3,+sse4.1,+sse4.2,+popcnt,+aes,+cx16,+x2apic,+sep,+pat,+pse'

silent() { "$@" > /dev/null 2>&1; }

ROOTLESS_MODE=0

setup_rootless_mode() {
  if [[ $(id -u) -ne 0 ]]; then
    ROOTLESS_MODE=1
    warn "Môi trường ko có root, VM sẽ chậm vì dùng proot"
    local freeroot_dir="$HOME/freeroot"
    if [[ ! -d "$freeroot_dir" ]]; then
      git clone https://github.com/foxytouxxx/freeroot.git "$freeroot_dir"
    fi
    (cd "$freeroot_dir" && printf 'YES\n' | bash root.sh)
  fi
}

write_dashboard_server() {
  mkdir -p "$DASHBOARD_DIR"
  cat > "$DASHBOARD_SERVER" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(os.environ.get("VM_ROOT", "/home/workspace"))
SCRIPT = Path(os.environ.get("VM_SCRIPT", str(ROOT / "v3-obf2.sh")))
LOG_FILE = Path(os.environ.get("VM_LOG", "/dev/shm/v3-obf2-launch.log"))
LOCK = threading.Lock()
LAUNCHING = False

PROFILE = {
    "os": "Windows 11 LTSB",
    "cpu_cores": 4,
    "ram_gb": 4,
    "cpu_id": "host",
    "username": "Admin",
    "password": "Tam255Z",
}


def run_shell(cmd: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["bash", "-lc", cmd], capture_output=True, text=True)


def qemu_pids() -> list[dict[str, str]]:
    res = run_shell(r"pgrep -af 'qemu-system-x86_64.*win\.img|qemu-system-x86_64' || true")
    out: list[dict[str, str]] = []
    for line in res.stdout.strip().splitlines():
        if not line.strip():
            continue
        parts = line.split(maxsplit=1)
        out.append({"pid": parts[0], "cmd": parts[1] if len(parts) > 1 else ""})
    return out


def current_cpu_id() -> str:
    res = run_shell(r"awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo")
    return (res.stdout or "").strip() or "host"


def tailscale_status() -> dict[str, str | bool]:
    res = run_shell("tailscale status 2>&1 || true")
    text = (res.stdout or "") + (res.stderr or "")
    logged_in = bool(text.strip()) and "Logged out" not in text and "Log in at:" not in text
    ip = run_shell("tailscale ip -4 2>/dev/null | head -n1 || true").stdout.strip()
    return {"raw": text.strip(), "logged_in": logged_in, "ip": ip}


def vm_status() -> dict:
    pids = qemu_pids()
    ts = tailscale_status()
    return {
        "running": bool(pids),
        "launching": LAUNCHING,
        "script_present": SCRIPT.exists(),
        "script": str(SCRIPT),
        "qemu": pids,
        "tailscale": ts,
        "rootless_note": "If launched without root, the script switches to freeroot/proot and may be slower.",
        "profile": {**PROFILE, "cpu_id": current_cpu_id()},
    }


def launch_vm(authkey: str) -> tuple[bool, str]:
    global LAUNCHING
    authkey = authkey.strip()
    if not authkey:
        return False, "Missing auth key"
    with LOCK:
        if LAUNCHING:
            return False, "Launch already in progress"
        if qemu_pids():
            return False, "VM is already running"
        LAUNCHING = True
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        log = open(LOG_FILE, "ab", buffering=0)
        proc = subprocess.Popen(["bash", str(SCRIPT)], cwd=str(ROOT), stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT)
        payload = "\n".join(["1", "3", "20", "4", "4", "y", authkey, ""]) + "\n"
        assert proc.stdin is not None
        proc.stdin.write(payload.encode())
        proc.stdin.close()
        return True, "VM launch started"
    except Exception as e:
        return False, f"Launch failed: {e}"
    finally:
        def clear_flag() -> None:
            global LAUNCHING
            time.sleep(1)
            with LOCK:
                LAUNCHING = False
        threading.Thread(target=clear_flag, daemon=True).start()


def stop_vm() -> tuple[bool, str]:
    run_shell(r"pkill -f 'qemu-system-x86_64.*win\.img' || true")
    if qemu_pids():
        return False, "Stop signal sent, but VM still appears running"
    return True, "VM stopped"


def html_page() -> str:
    return """<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>VM Control Center</title>
  <style>
    :root { color-scheme: dark; --bg1:#050816; --bg2:#0b1220; --card:rgba(17,24,39,.78); --line:rgba(255,255,255,.1); --txt:#e5e7eb; --muted:#94a3b8; --accent:#7c3aed; --danger:#ef4444; }
    * { box-sizing: border-box; }
    body { margin:0; font-family:ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; color:var(--txt); background:radial-gradient(circle at top left, rgba(124,58,237,.35), transparent 32%), radial-gradient(circle at top right, rgba(34,197,94,.18), transparent 28%), linear-gradient(180deg,var(--bg1),var(--bg2)); min-height:100vh; }
    .wrap { max-width:1140px; margin:0 auto; padding:32px 18px 40px; }
    .hero { display:grid; grid-template-columns:1.4fr 1fr; gap:18px; align-items:stretch; }
    .panel,.status,.log { background:var(--card); border:1px solid var(--line); border-radius:22px; box-shadow:0 20px 60px rgba(0,0,0,.35); backdrop-filter:blur(16px); }
    .panel { padding:26px; }
    h1 { margin:0 0 8px; font-size:40px; line-height:1.05; }
    .sub { color:var(--muted); font-size:15px; line-height:1.5; }
    .badge { display:inline-flex; align-items:center; gap:8px; padding:8px 12px; border-radius:999px; background:rgba(124,58,237,.16); border:1px solid rgba(124,58,237,.35); color:#ddd6fe; font-weight:700; font-size:12px; letter-spacing:.02em; margin-bottom:14px; }
    .grid { display:grid; grid-template-columns:repeat(3, 1fr); gap:14px; margin-top:18px; }
    .grid2 { display:grid; grid-template-columns:repeat(2, 1fr); gap:14px; margin-top:14px; }
    .stat { padding:16px; border-radius:18px; background:rgba(255,255,255,.04); border:1px solid var(--line); min-height:92px; }
    .label { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.12em; }
    .value { font-size:18px; font-weight:800; margin-top:8px; word-break:break-word; }
    .actions { display:flex; gap:12px; flex-wrap:wrap; margin-top:20px; }
    button,input { border:0; outline:none; font:inherit; border-radius:16px; padding:14px 16px; }
    input { width:100%; background:rgba(255,255,255,.06); color:var(--txt); border:1px solid var(--line); }
    .primary { background:linear-gradient(135deg, var(--accent), #4f46e5); color:white; font-weight:800; }
    .danger { background:linear-gradient(135deg, #f87171, var(--danger)); color:white; font-weight:800; }
    .ghost { background:rgba(255,255,255,.06); color:var(--txt); border:1px solid var(--line); font-weight:700; }
    .status,.log { padding:20px; margin-top:18px; }
    .status-title { display:flex; justify-content:space-between; align-items:center; gap:12px; margin-bottom:12px; }
    .pill { display:inline-flex; align-items:center; gap:8px; padding:8px 12px; border-radius:999px; font-size:12px; font-weight:800; letter-spacing:.04em; }
    .ok { background:rgba(34,197,94,.15); color:#86efac; border:1px solid rgba(34,197,94,.35); }
    .warn { background:rgba(245,158,11,.14); color:#fcd34d; border:1px solid rgba(245,158,11,.35); }
    .bad { background:rgba(239,68,68,.14); color:#fca5a5; border:1px solid rgba(239,68,68,.35); }
    pre { white-space:pre-wrap; word-break:break-word; margin:0; line-height:1.5; color:#cbd5e1; font-size:13px; }
    .footer { margin-top:16px; color:var(--muted); font-size:12px; }
    code { color:#ddd6fe; }
    @media (max-width:900px) { .hero { grid-template-columns:1fr; } .grid,.grid2 { grid-template-columns:1fr; } h1 { font-size:32px; } }
  </style>
</head>
<body>
  <div class=\"wrap\">
    <div class=\"hero\">
      <div class=\"panel\">
        <div class=\"badge\">VM Control Center</div>
        <h1>Start and stop your Windows VM</h1>
        <p class=\"sub\">Beautiful dashboard on port 8080. Launch the VM, then grab the Tailscale IPv4, user, pass, OS, CPU, RAM and CPU ID from one screen.</p>
        <div class=\"grid\">
          <div class=\"stat\"><div class=\"label\">VM status</div><div class=\"value\" id=\"vmStatus\">Loading…</div></div>
          <div class=\"stat\"><div class=\"label\">Tailscale</div><div class=\"value\" id=\"tsStatus\">Loading…</div></div>
          <div class=\"stat\"><div class=\"label\">Launch mode</div><div class=\"value\" id=\"modeStatus\">Loading…</div></div>
        </div>
        <div class=\"grid2\">
          <div class=\"stat\"><div class=\"label\">Operating system</div><div class=\"value\" id=\"osStatus\">Loading…</div></div>
          <div class=\"stat\"><div class=\"label\">CPU / RAM</div><div class=\"value\" id=\"cpuRamStatus\">Loading…</div></div>
          <div class=\"stat\"><div class=\"label\">CPU ID</div><div class=\"value\" id=\"cpuIdStatus\">Loading…</div></div>
          <div class=\"stat\"><div class=\"label\">Credentials</div><div class=\"value\" id=\"credStatus\">Loading…</div></div>
        </div>
        <div style=\"margin-top:18px\">
          <div class=\"label\" style=\"margin-bottom:8px\">Tailscale auth key</div>
          <input id=\"authKey\" type=\"password\" placeholder=\"tskey-auth-...\" autocomplete=\"off\" />
        </div>
        <div class=\"actions\">
          <button class=\"primary\" id=\"startBtn\">Start VM</button>
          <button class=\"danger\" id=\"stopBtn\">Stop VM</button>
          <button class=\"ghost\" id=\"refreshBtn\">Refresh</button>
        </div>
        <div class=\"footer\">The dashboard launches <code>v3-obf2.sh</code> in the workspace and keeps a live status view.</div>
      </div>
      <div class=\"status\">
        <div class=\"status-title\"><strong>Live details</strong><span id=\"headlinePill\" class=\"pill warn\">Idle</span></div>
        <pre id=\"details\">Loading…</pre>
      </div>
    </div>
    <div class=\"log\">
      <div class=\"status-title\"><strong>Recent log</strong><span class=\"pill ok\">/dev/shm/v3-obf2-launch.log</span></div>
      <pre id=\"logText\">Loading…</pre>
    </div>
  </div>
  <script>
    async function api(path, method = 'GET', body = null) {
      const res = await fetch(path, {
        method,
        headers: body ? {'Content-Type': 'application/json', 'Accept': 'application/json'} : {'Accept': 'application/json'},
        body: body ? JSON.stringify(body) : null,
      });
      return await res.json();
    }
    function setPill(text, cls) { const pill = document.getElementById('headlinePill'); pill.textContent = text; pill.className = 'pill ' + cls; }
    async function refresh() {
      const s = await api('/api/status');
      document.getElementById('vmStatus').textContent = s.running ? 'Running' : (s.launching ? 'Launching' : 'Stopped');
      document.getElementById('tsStatus').textContent = s.tailscale.logged_in ? (s.tailscale.ip || 'Logged in') : 'Logged out';
      document.getElementById('modeStatus').textContent = s.rootless_note ? 'Rootless aware' : 'Normal';
      document.getElementById('osStatus').textContent = s.profile.os;
      document.getElementById('cpuRamStatus').textContent = `${s.profile.cpu_cores} CPU / ${s.profile.ram_gb} GB`;
      document.getElementById('cpuIdStatus').textContent = s.profile.cpu_id;
      document.getElementById('credStatus').textContent = `${s.profile.username} / ${s.profile.password}`;
      setPill(s.running ? 'Running' : (s.launching ? 'Launching' : 'Idle'), s.running ? 'ok' : 'warn');
      document.getElementById('details').textContent = JSON.stringify(s, null, 2);
      document.getElementById('logText').textContent = await fetch('/api/log').then(r => r.text());
    }
    async function startVm() { const authkey = document.getElementById('authKey').value.trim(); const res = await api('/api/start', 'POST', {authkey}); alert(res.message || res.error || 'done'); await refresh(); }
    async function stopVm() { const res = await api('/api/stop', 'POST', {}); alert(res.message || res.error || 'done'); await refresh(); }
    document.getElementById('startBtn').onclick = startVm;
    document.getElementById('stopBtn').onclick = stopVm;
    document.getElementById('refreshBtn').onclick = refresh;
    refresh(); setInterval(refresh, 5000);
  </script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def _json(self, code: int, payload: dict) -> None:
        raw = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _text(self, code: int, payload: str, content_type: str = 'text/html; charset=utf-8') -> None:
        raw = payload.encode()
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == '/':
            self._text(200, html_page())
            return
        if path == '/api/status':
            self._json(200, vm_status())
            return
        if path == '/api/log':
            text = LOG_FILE.read_text(errors='ignore')[-12000:] if LOG_FILE.exists() else '(log file not created yet)'
            self._text(200, text, 'text/plain; charset=utf-8')
            return
        self._json(404, {'error': 'not found'})

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        length = int(self.headers.get('content-length', '0') or '0')
        body = self.rfile.read(length).decode() if length else ''
        data = {}
        if body:
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                data = {}
        if path == '/api/start':
            authkey = str(data.get('authkey', '')).strip()
            ok, msg = launch_vm(authkey)
            self._json(200 if ok else 400, {'ok': ok, 'message': msg})
            return
        if path == '/api/stop':
            ok, msg = stop_vm()
            self._json(200 if ok else 400, {'ok': ok, 'message': msg})
            return
        self._json(404, {'error': 'not found'})

    def log_message(self, fmt: str, *args) -> None:
        return


def main() -> None:
    port = int(os.environ.get('PORT', '8080'))
    server = ThreadingHTTPServer(('0.0.0.0', port), Handler)
    print(f'dashboard listening on http://0.0.0.0:{port}')
    server.serve_forever()


if __name__ == '__main__':
    main()
PY
  chmod +x "$DASHBOARD_SERVER"
}

start_web_dashboard() {
  write_dashboard_server
  if ! pgrep -f "$DASHBOARD_SERVER" >/dev/null 2>&1; then
    nohup env PORT="$DASHBOARD_PORT" VM_ROOT="$SCRIPT_DIR" VM_SCRIPT="$SCRIPT_DIR/v3-obf2.sh" VM_LOG='/dev/shm/v3-obf2-launch.log' python3 "$DASHBOARD_SERVER" >/dev/shm/v3-obf2-dashboard.log 2>&1 &
    sleep 1
  fi
}


start_http_tunnel() {
  if [[ -f "$TUNNEL_PID_FILE" ]] && kill -0 "$(cat "$TUNNEL_PID_FILE")" 2>/dev/null; then
    return 0
  fi
  if ! command -v lt >/dev/null 2>&1; then
    if command -v npx >/dev/null 2>&1; then
      nohup npx --yes localtunnel --port "$DASHBOARD_PORT" > /dev/shm/v3-obf2-lt.log 2>&1 &
    else
      warn "localtunnel không khả dụng"
      return 1
    fi
  else
    nohup lt --port "$DASHBOARD_PORT" > /dev/shm/v3-obf2-lt.log 2>&1 &
  fi
  echo $! > "$TUNNEL_PID_FILE"
  sleep 4
  PUBLIC_TUNNEL_URL=$(grep -m1 -oE 'https://[^[:space:]]+\.loca\.lt|https://[^[:space:]]+\.localtunnel\.me' /dev/shm/v3-obf2-lt.log || true)
  if [[ -z "$PUBLIC_TUNNEL_URL" ]]; then
    PUBLIC_TUNNEL_URL=$(grep -m1 -oE 'https://[^[:space:]]+' /dev/shm/v3-obf2-lt.log || true)
  fi
}
ask() {
  read -rp "$1" ans
  ans="${ans,,}"
  [[ -z "$ans" ]] && printf '%s\n' "$2" || printf '%s\n' "$ans"
}

line() { printf '%b\n' "${CYAN}╔════════════════════════════════════════════════════════════════════╗${RESET}"; }
midline() { printf '%b\n' "${CYAN}╠════════════════════════════════════════════════════════════════════╣${RESET}"; }
footer() { printf '%b\n' "${CYAN}╚════════════════════════════════════════════════════════════════════╝${RESET}"; }

header() {
  if [[ -t 1 ]] && command -v clear >/dev/null 2>&1; then
    clear || true
  fi
  line
  printf '%b\n' "${CYAN}║${RESET}                    ${CYAN}WIN TOOL PROFESSIONAL${RESET}                    ${CYAN}║${RESET}"
  printf '%b\n' "${CYAN}║${RESET}          ${BLUE}Windows VM Manager • Auto KVM • Clean UI${RESET}          ${CYAN}║${RESET}"
  footer
}

info() { printf '%b\n' "${BLUE}▶${RESET} $1"; }
ok() { printf '%b\n' "${GREEN}✔${RESET} $1"; }
warn() { printf '%b\n' "${YELLOW}⚠${RESET} $1"; }
fail() { printf '%b\n' "${RED}✘${RESET} $1"; }

cpu_host_name() { awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo; }

build_tcg_cpu_model() {
  printf '%s,model-id=%s' "$TCG_CPU_BASE" "$(cpu_host_name)"
}

have_kvm() {
  [[ "$(uname -m)" == "x86_64" ]] || return 1
  if command -v kvm-ok >/dev/null 2>&1; then
    kvm-ok >/dev/null 2>&1 && return 0
  fi
  [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]
}

build_accel_opts() {
  if have_kvm; then
    ACCEL_LABEL='KVM'
    ACCEL_OPTS=(-accel kvm -cpu host)
  else
    ACCEL_LABEL='TCG opt'
    ACCEL_OPTS=(-accel "tcg,thread=multi,tb-size=${TB_SIZE}" -cpu "$(build_tcg_cpu_model)")
  fi
}

ensure_qemu() {

  if [[ "$ROOTLESS_MODE" == "1" ]]; then
    warn "Rootless/proot mode: bỏ qua build QEMU, dùng qemu hệ thống nếu có"
    return 1
  fi

  if [[ -x "$QEMU_BIN" && -x "$QEMU_IMG" ]]; then
    export PATH="$QEMU_PREFIX/bin:$PATH"
    ok "QEMU đã có sẵn tại $QEMU_PREFIX"
    return 0
  fi

  local choice
  choice=$(ask "👉 Bạn có muốn build QEMU tối ưu để chạy VM? (y/n): " "n")
  [[ "$choice" == "y" ]] || { warn "Bỏ qua build QEMU, sẽ dùng qemu-system-x86_64 của hệ thống"; return 1; }

  info "Đang cài phụ thuộc build..."
  OS_ID="$(. /etc/os-release && echo "$ID")"
  OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"

  sudo apt update
  sudo apt install -y wget gnupg build-essential ninja-build git python3 python3-venv python3-pip libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev pkg-config meson aria2 ovmf cpu-checker

  if [[ "$OS_ID" == "ubuntu" ]]; then
    info "Detect Ubuntu → cài LLVM 21 từ apt.llvm.org"
    wget -q https://apt.llvm.org/llvm.sh
    chmod +x llvm.sh
    sudo ./llvm.sh 21
    LLVM_VER=21
  else
    if [[ "$OS_ID" == "debian" && "$OS_VER" == "13" ]]; then LLVM_VER=19; else LLVM_VER=15; fi
    silent sudo apt install -y clang-$LLVM_VER lld-$LLVM_VER llvm-$LLVM_VER llvm-$LLVM_VER-dev llvm-$LLVM_VER-tools
  fi

  export PATH="/usr/lib/llvm-$LLVM_VER/bin:$PATH"
  export CC="clang-$LLVM_VER"
  export CXX="clang++-$LLVM_VER"
  export LD="lld-$LLVM_VER"

  python3 -m venv ~/qemu-env
  source ~/qemu-env/bin/activate
  silent pip install --upgrade pip tomli packaging

  rm -rf /tmp/qemu-src /tmp/qemu-build
  cd /tmp
  silent git clone --depth 1 --branch v11.0.0-rc2 https://gitlab.com/qemu-project/qemu.git qemu-src
  mkdir /tmp/qemu-build
  cd /tmp/qemu-build

  EXTRA_CFLAGS='-O2 -pipe -march=native -mtune=native -DNDEBUG'

  info "Configuring QEMU..."
  ../qemu-src/configure \
    --prefix=/opt/qemu-optimized \
    --target-list=x86_64-softmmu \
    --enable-tcg \
    --enable-slirp \
    --enable-coroutine-pool \
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
    CC="$CC" CXX="$CXX" LD="$LD" CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS"

  info "Đang build QEMU..."
  ninja -j"$(nproc)"
  sudo ninja install
  export PATH="$QEMU_PREFIX/bin:$PATH"
  qemu-system-x86_64 --version
  ok "QEMU LLVM build xong"
  return 0
}

show_running_vms() {
  midline
  printf '%b\n' "${CYAN}                        RUNNING VM MANAGER${RESET}"
  midline

  VM_LIST=$(pgrep -f '^qemu-system' || true)
  if [[ -z "$VM_LIST" ]]; then
    fail "Không có VM nào đang chạy"
    return 0
  fi

  for pid in $VM_LIST; do
    [[ -r "/proc/$pid/cmdline" ]] || continue
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
    vcpu=$(echo "$cmd" | sed -n 's/.*-smp \([^ ,]*\).*/\1/p')
    ram=$(echo "$cmd" | sed -n 's/.*-m \([^ ]*\).*/\1/p')
    cpu=$(ps -p "$pid" -o %cpu= | tr -d ' ')
    mem=$(ps -p "$pid" -o %mem= | tr -d ' ')
    printf '%b\n' "${MAGENTA}PID${RESET} ${YELLOW}$pid${RESET} ${CYAN}|${RESET} ${BLUE}vCPU${RESET} ${GREEN}${vcpu:-?}${RESET} ${CYAN}|${RESET} ${BLUE}RAM${RESET} ${GREEN}${ram:-?}${RESET} ${CYAN}|${RESET} ${BLUE}CPU${RESET} ${GREEN}${cpu:-?}%${RESET} ${CYAN}|${RESET} ${BLUE}HostRAM${RESET} ${GREEN}${mem:-?}%${RESET}"
  done

  midline
  read -rp "Nhập PID muốn tắt (Enter để bỏ qua): " kill_pid
  if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
    kill "$kill_pid" 2>/dev/null || true
    ok "Đã gửi tín hiệu dừng PID $kill_pid"
  fi
}

select_windows_image() {
  line
  printf '%b\n' "${CYAN}                          CHOOSE WINDOWS IMAGE${RESET}"
  line
  printf '%b\n' "  ${YELLOW}1)${RESET} Windows Server 2012 R2"
  printf '%b\n' "  ${YELLOW}2)${RESET} Windows Server 2022"
  printf '%b\n' "  ${YELLOW}3)${RESET} Windows 11 LTSB"
  printf '%b\n' "  ${YELLOW}4)${RESET} Windows 10 LTSB 2015"
  printf '%b\n' "  ${YELLOW}5)${RESET} Windows 10 LTSC 2023"
  midline
  read -rp "Chọn [1-5]: " win_choice
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
}

launch_vm() {
  line
  printf '%b\n' "${CYAN}                       CREATE WINDOWS VM${RESET}"
  line

  start_web_dashboard
  start_http_tunnel || true
  info "Dashboard    : ${DASHBOARD_URL}"
  [[ -n "$PUBLIC_TUNNEL_URL" ]] && info "Public URL   : ${PUBLIC_TUNNEL_URL}"
  info "Host CPU: $(cpu_host_name)"
  build_accel_opts
  info "Acceleration: ${ACCEL_LABEL}"

  ensure_qemu || true
  if [[ -x "$QEMU_BIN" ]]; then
    export PATH="$QEMU_PREFIX/bin:$PATH"
    QEMU_CMD="$QEMU_BIN"
  else
    QEMU_CMD="qemu-system-x86_64"
    command -v "$QEMU_CMD" >/dev/null 2>&1 || { fail "Không tìm thấy qemu-system-x86_64"; exit 1; }
  fi

  select_windows_image

  if [[ "$win_choice" == "3" ]]; then
    if [[ ! -f /usr/share/qemu/OVMF.fd ]]; then
      fail "Windows 11 cần OVMF/UEFI nhưng không tìm thấy /usr/share/qemu/OVMF.fd"
      exit 1
    fi
    info "Windows 11 sẽ boot bằng UEFI/OVMF"
  fi

  RDP_LOCAL_PORT=3389
  info "RDP local port: ${RDP_LOCAL_PORT}"

  info "Đang tải: $WIN_NAME"
  if [[ ! -f win.img ]]; then
    silent aria2c -x16 -s16 --continue --file-allocation=none "$WIN_URL" -o win.img
  fi

  read -rp "Mở rộng đĩa thêm bao nhiêu GB [20]: " extra_gb
  extra_gb="${extra_gb:-20}"
  silent "$QEMU_IMG" resize win.img "+${extra_gb}G" || silent qemu-img resize win.img "+${extra_gb}G"

  read -rp "CPU core [4]: " cpu_core
  cpu_core="${cpu_core:-4}"
  read -rp "RAM GB [4]: " ram_size
  ram_size="${ram_size:-4}"

  if [[ "$win_choice" == "4" ]]; then
    NET_DEVICE=(-device e1000e,netdev=n0)
  else
    NET_DEVICE=(-device virtio-net-pci,netdev=n0)
  fi

  if [[ "$USE_UEFI" == "yes" ]]; then
    BIOS_OPT=(-bios /usr/share/qemu/OVMF.fd)
  else
    BIOS_OPT=()
  fi

  info "Khởi động VM bằng ${ACCEL_LABEL}..."
  "$QEMU_CMD" \
    -machine q35,hpet=off \
    -smp "$cpu_core" \
    -m "${ram_size}G" \
    "${ACCEL_OPTS[@]}" \
    -rtc base=localtime \
    "${BIOS_OPT[@]}" \
    -drive file=win.img,if=virtio,cache=unsafe,aio=threads,format=raw \
    -netdev user,id=n0,hostfwd=tcp:0.0.0.0:${RDP_LOCAL_PORT}-:3389 \
    "${NET_DEVICE[@]}" \
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
    > "$QEMU_LOG" 2>&1 || true

  sleep 3
  local rdp_ready="no"
  for _ in $(seq 1 120); do
    if (exec 3<>/dev/tcp/127.0.0.1/${RDP_LOCAL_PORT}) >/dev/null 2>&1; then
      exec 3<&- 3>&-
      rdp_ready="yes"
      break
    fi
    sleep 2
  done
  if [[ "$rdp_ready" != "yes" ]]; then
    fail "QEMU/RDP chưa mở cổng ${RDP_LOCAL_PORT}; thường là do guest chưa boot xong"
    [[ -s "$QEMU_LOG" ]] && { echo ""; warn "QEMU log:"; tail -n 40 "$QEMU_LOG"; }
    exit 1
  fi

  use_rdp=$(ask "Dùng Tailscale để vào VM? (y/n): " "n")
  [[ "$use_rdp" == "y" ]] || { ok "VM đã khởi động xong"; return 0; }

  read -rsp "Nhập Tailscale auth token: " TAILSCALE_AUTHKEY
  echo
  info "Đang cài và kết nối Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh && tailscaled --tun=userspace-networking & sleep 2 && tailscale up --authkey "$TAILSCALE_AUTHKEY"
  sleep 3
  TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)

  line
  printf '%b\n' "${GREEN}                    WINDOWS VM DEPLOYED SUCCESSFULLY${RESET}"
  line
  printf '%b\n' "${CYAN}Dashboard  ${RESET}: ${DASHBOARD_URL}"
  printf '%b\n' "${CYAN}OS         ${RESET}: ${WIN_NAME}"
  printf '%b\n' "${CYAN}Mode       ${RESET}: ${ACCEL_LABEL}"
  printf '%b\n' "${CYAN}CPU Cores  ${RESET}: ${cpu_core}"
  printf '%b\n' "${CYAN}RAM        ${RESET}: ${ram_size} GB"
  printf '%b\n' "${CYAN}CPU Host   ${RESET}: $(cpu_host_name)"
  printf '%b\n' "${CYAN}Tailscale  ${RESET}: ${TS_IP:-unavailable}"
  printf '%b\n' "${CYAN}Username   ${RESET}: ${RDP_USER}"
  printf '%b\n' "${CYAN}Password   ${RESET}: ${RDP_PASS}"
  footer
}

main_menu() {
  start_web_dashboard
  start_http_tunnel || true
  header
  if have_kvm; then
    ok "KVM detected → sẽ dùng -accel kvm và -cpu host"
  else
    warn "Không có KVM usable → fallback TCG"
  fi

  line
  printf '%b\n' "${CYAN}║${RESET} ${YELLOW}1${RESET}. Create Windows VM                                   ${CYAN}║${RESET}"
  printf '%b\n' "${CYAN}║${RESET} ${YELLOW}2${RESET}. Manage Running VM                                   ${CYAN}║${RESET}"
  printf '%b\n' "${CYAN}║${RESET} ${YELLOW}3${RESET}. Exit                                                 ${CYAN}║${RESET}"
  footer

  read -rp "Chọn [1-3]: " main_choice
  case "$main_choice" in
    1) launch_vm ;;
    2) show_running_vms ;;
    3) exit 0 ;;
    *) warn "Lựa chọn không hợp lệ" ;;
  esac
}

setup_rootless_mode
main_menu
