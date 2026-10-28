"""Drives libeasytier_ffi.so the way the iPhone app does (ctypes, the app's TOML) and times recovery.

Scenarios (each prints seconds until an HTTP request through the port forward succeeds again):
  cold         start → first response
  netchange    the live connection to the hub goes silent (no FIN: iptables drops just that flow),
               then the app reacts the way it can: restart (new peer id) / reconnect (same id) / restart with fixed id
  freeze       the hub-side view of a suspended app: process frozen 45 s, then resumed
"""
import ctypes, json, os, subprocess, sys, threading, time, urllib.request

LIB = ctypes.CDLL(os.environ.get("FFI", "/bins/patched/libeasytier_ffi.so"))
LIB.run_network_instance.argtypes = [ctypes.c_char_p]
LIB.retain_network_instance.argtypes = [ctypes.POINTER(ctypes.c_char_p), ctypes.c_size_t]
LIB.get_error_msg.argtypes = [ctypes.POINTER(ctypes.c_char_p)]
HAS_RECONNECT = hasattr(LIB, "reconnect_network_instance")
if HAS_RECONNECT:
    LIB.reconnect_network_instance.argtypes = [ctypes.c_char_p]

KEY = os.environ["CRED"]
HUB = os.environ.get("HUB", "hub")


def toml(peer_id=None):
    extra = f"peer_id = {peer_id}\n" if peer_id else ""
    return f'''instance_name = "trinity"
{extra}hostname = "test-phone"
ipv4 = "10.144.144.123/24"
dhcp = false
listeners = []
socks5_proxy = "socks5://127.0.0.1:19180"

[network_identity]
network_name = "easytier-net"

[secure_mode]
enabled = true
local_private_key = "{KEY}"

# The app also lists an address that is unreachable from here (TEST-NET-1 stands in for it).
[[peer]]
uri = "tcp://192.0.2.1:11010"

[[peer]]
uri = "tcp://{HUB}:11010"

[[port_forward]]
bind_addr = "127.0.0.1:18080"
dst_addr = "10.144.144.50:80"
proto = "tcp"

[flags]
bind_device = false
disable_upnp = true
no_tun = true
'''


def err():
    p = ctypes.c_char_p()
    LIB.get_error_msg(ctypes.byref(p))
    return p.value.decode() if p.value else ""


def start(peer_id=None):
    if LIB.run_network_instance(toml(peer_id).encode()) != 0:
        raise RuntimeError(err())


def stop():
    LIB.retain_network_instance(None, 0)


def restart(peer_id=None):
    stop()
    start(peer_id)


def reconnect():
    if LIB.reconnect_network_instance(b"trinity") != 0:
        raise RuntimeError(err())


def wait_http(limit=60.0):
    """Seconds until GET http://127.0.0.1:18080/ answers. A new attempt every 100 ms (each may hang up to 8 s)."""
    t0 = time.monotonic()
    done = threading.Event()

    def attempt():
        try:
            urllib.request.urlopen("http://127.0.0.1:18080/", timeout=8).read(16)
            done.set()
        except Exception:
            pass

    while not done.is_set() and time.monotonic() - t0 < limit:
        threading.Thread(target=attempt, daemon=True).start()
        done.wait(0.1)
    return round(time.monotonic() - t0, 2) if done.is_set() else None


def hold(seconds=40.0):
    """After recovery: a request every 200 ms (each ≤ 3 s). Returns (failures, longest outage in s)."""
    t_end = time.monotonic() + seconds
    failures, outage_start, longest = 0, None, 0.0
    while time.monotonic() < t_end:
        t = time.monotonic()
        try:
            urllib.request.urlopen("http://127.0.0.1:18080/", timeout=3).read(16)
            if outage_start is not None:
                longest = max(longest, t - outage_start)
                outage_start = None
        except Exception:
            failures += 1
            outage_start = outage_start or t
        time.sleep(max(0, 0.2 - (time.monotonic() - t)))
    if outage_start is not None:
        longest = max(longest, time.monotonic() - outage_start)
    return failures, round(longest, 2)


def hub_flow_ports():
    out = subprocess.run(["ss", "-tnH", "state", "established", "dport", "= :11010"], capture_output=True, text=True).stdout
    return [line.split()[2].rsplit(":", 1)[1] for line in out.splitlines() if line.strip()]


def silence_current_flow():
    """Network change: the current link to the hub dies silently, new connections still work."""
    ports = hub_flow_ports()
    for p in ports:
        subprocess.run(["iptables", "-A", "OUTPUT", "-p", "tcp", "--sport", p, "-j", "DROP"], check=True)
        subprocess.run(["iptables", "-A", "INPUT", "-p", "tcp", "--dport", p, "-j", "DROP"], check=True)
    return ports


def clear_rules():
    subprocess.run(["iptables", "-F"], check=True)


def steady(seconds=8):
    """Let the link idle like a phone in a pocket (heartbeats back off)."""
    assert wait_http(30) is not None, "no steady state"
    time.sleep(seconds)


def run(name, fn):
    try:
        r = fn()
    except Exception as e:  # noqa: BLE001
        r = f"error: {e}"
    print(json.dumps({"scenario": name, "seconds": r}), flush=True)


def main():
    mode = sys.argv[1]
    fixed = int(os.environ["PEER_ID"]) if os.environ.get("PEER_ID") else None
    if mode == "first-request":
        # One request the moment the tunnel starts (before any route): did it hang?
        start(fixed)
        import socket
        while True:  # the moment the forward listens (route usually not there yet)
            try:
                socket.create_connection(("127.0.0.1", 18080), timeout=0.05).close()
                break
            except OSError:
                time.sleep(0.005)
        t0 = time.monotonic()
        try:
            urllib.request.urlopen("http://127.0.0.1:18080/", timeout=15).read(16)
            r = round(time.monotonic() - t0, 2)
        except Exception as e:  # noqa: BLE001
            r = f"failed after {round(time.monotonic() - t0, 2)}s: {e}"
        run("first-request", lambda: r)
        stop()
        return
    if mode == "cold":
        def f():
            t0 = time.monotonic()
            start(fixed)
            w = wait_http()
            return w
        run("cold", f)
        stop()
        return
    elif mode in ("netchange-restart", "netchange-reconnect", "netchange-nothing"):
        start(fixed)
        steady()
        silence_current_flow()
        t0 = time.monotonic()
        if mode == "netchange-restart":
            restart(fixed)
        elif mode == "netchange-reconnect":
            reconnect()
        w = wait_http(90)
        f, longest = hold()
        run(mode, lambda: {"first_ok": w, "failures_40s": f, "longest_outage": longest})
    elif mode in ("freeze-restart", "freeze-reconnect", "freeze-nothing"):
        start(fixed)
        steady()
        # Frozen app: the hub stops hearing from us but the socket stays open (no FIN).
        ports = silence_current_flow()
        time.sleep(45)
        clear_rules()
        if mode == "freeze-restart":
            restart(fixed)
        elif mode == "freeze-reconnect":
            reconnect()
        w = wait_http(90)
        f, longest = hold()
        run(mode, lambda: {"first_ok": w, "failures_40s": f, "longest_outage": longest})
    clear_rules()  # let the close reach the hub: the next run must not meet this node
    stop()
    time.sleep(1)


main()
