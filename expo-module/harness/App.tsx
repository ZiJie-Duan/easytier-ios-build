// E2E harness for the EasyTier Expo module (see .github/workflows/expo-module-ios.yml).
//
// On launch it drives the native module directly (no JS wrapper): validateConfig,
// start, onStatusChange events, getStatus polling until the hub (10.144.144.50) shows
// up as a route, then fetch() through the port forward 127.0.0.1:18081 ->
// 10.144.144.50:8080, then stop. The result is POSTed as JSON to the CI collector on
// the host (http://127.0.0.1:18999/result; the simulator shares the host's loopback),
// logged with console.error (visible in Release builds via `log stream`) and rendered.
import { requireNativeModule } from 'expo';
import { useEffect, useState } from 'react';
import { ScrollView, Text } from 'react-native';

type NativeStatus = { instanceName?: string; running: boolean; infoJson?: string; error?: string };
type EasyTierNative = {
  isFrameworkLinked: boolean;
  features?: string[];
  validateConfig(toml: string, redactions: string[]): Promise<void>;
  start(toml: string, instanceName: string, pollIntervalMs: number, redactions: string[]): Promise<{ kept?: boolean } | void>;
  restart(): Promise<void>;
  setLaunchConfig(toml: string | null, instanceName: string | null): Promise<void>;
  stop(): Promise<void>;
  getStatus(): Promise<NativeStatus>;
  addListener(event: 'onStatusChange', cb: (s: NativeStatus) => void): { remove(): void };
};

const HUB_IP = '10.144.144.50';
const COLLECTOR = 'http://127.0.0.1:18999/result';
const SECRET = 'smoke-secret';
const TOML = `instance_name = "trinity"
hostname = "expo-e2e"
ipv4 = "10.144.144.149/24"
dhcp = false
listeners = []

[network_identity]
network_name = "trinity-smoke"
network_secret = "${SECRET}"

[[peer]]
uri = "tcp://127.0.0.1:11010"

[[port_forward]]
bind_addr = "127.0.0.1:18081"
dst_addr = "10.144.144.50:8080"
proto = "tcp"

[flags]
bind_device = false
disable_upnp = true
no_tun = true
`;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function ipOf(inet: any): string | null {
  const addr = inet?.address?.addr;
  if (typeof addr !== 'number') return null;
  return [addr >>> 24, (addr >>> 16) & 255, (addr >>> 8) & 255, addr & 255].join('.');
}

function routeIps(info: any): string[] {
  const out: string[] = [];
  for (const p of info?.peer_route_pairs ?? []) {
    const ip = ipOf(p?.route?.ipv4_addr);
    if (ip) out.push(ip);
  }
  for (const r of info?.routes ?? []) {
    const ip = ipOf(r?.ipv4_addr);
    if (ip && !out.includes(ip)) out.push(ip);
  }
  return out;
}

async function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  return Promise.race([p, sleep(ms).then(() => Promise.reject(new Error(`${what} timed out after ${ms} ms`)))]);
}

async function run(log: (s: string) => void): Promise<Record<string, unknown>> {
  const r: Record<string, unknown> = { checks: {} as Record<string, boolean> };
  const checks = r.checks as Record<string, boolean>;
  const t0 = Date.now();
  const mod = requireNativeModule<EasyTierNative>('EasyTier');
  r.isFrameworkLinked = mod.isFrameworkLinked;
  checks.frameworkLinked = mod.isFrameworkLinked === true;
  log(`isFrameworkLinked=${mod.isFrameworkLinked}`);

  // validateConfig: good config passes, bad config rejects with a redacted message.
  await mod.validateConfig(TOML, [SECRET]);
  checks.validateGood = true;
  try {
    await mod.validateConfig(TOML.replace('dhcp = false', 'dhcp = = ='), [SECRET]);
    checks.validateBadRejects = false;
  } catch (e: any) {
    r.validateBadError = String(e?.message ?? e).slice(0, 400);
    checks.validateBadRejects = true;
    checks.validateBadRedacted = !String(e?.message ?? e).includes(SECRET);
  }

  const events: NativeStatus[] = [];
  const sub = mod.addListener('onStatusChange', (s) => events.push(s));

  await mod.start(TOML, 'trinity', 1000, [SECRET]);
  checks.start = true;
  log('started');

  let info: any = null;
  let routes: string[] = [];
  let sawHubAt = -1;
  const tStart = Date.now();
  while (Date.now() - tStart < 45000) {
    const st = await mod.getStatus();
    r.lastStatusMeta = { instanceName: st.instanceName, running: st.running, error: st.error ?? null };
    if (st.infoJson) {
      info = JSON.parse(st.infoJson);
      routes = routeIps(info);
      if (routes.includes(HUB_IP)) {
        sawHubAt = (Date.now() - tStart) / 1000;
        break;
      }
    }
    await sleep(500);
  }
  r.routes = routes;
  r.sawHubAfterSec = sawHubAt;
  r.myVirtualIp = ipOf(info?.my_node_info?.virtual_ipv4);
  r.version = info?.my_node_info?.version ?? null;
  r.infoRunning = info?.running ?? null;
  r.infoErrorMsg = info?.error_msg ?? null;
  checks.hubPeer = sawHubAt >= 0;
  checks.myIp = r.myVirtualIp === '10.144.144.149';
  log(`routes=${JSON.stringify(routes)} sawHubAfter=${sawHubAt}`);

  // HTTP round trip through the port forward (JS fetch -> 127.0.0.1:18081 -> overlay -> hub -> 127.0.0.1:8080).
  let body: string | null = null;
  for (let i = 0; i < 10 && body === null; i++) {
    try {
      const res = await withTimeout(fetch(`http://127.0.0.1:18081/hello?attempt=${i}`), 10000, 'fetch');
      r.fetchStatus = res.status;
      body = await res.text();
    } catch (e: any) {
      r.fetchError = String(e?.message ?? e);
      await sleep(1000);
    }
  }
  r.fetchBody = body;
  checks.roundTrip = typeof body === 'string' && body.includes('hello-from-hub');
  log(`fetch body=${body}`);

  // v2.6.4-4 (Trinity M22-6): features, same config kept, native restart.
  r.features = mod.features ?? null;
  checks.features = ['nativeRestart', 'pathRestart', 'launchStart', 'keepSameConfig', 'lowerPeerId'].every((f) => mod.features?.includes(f));
  const peerBefore = info?.my_node_info?.peer_id ?? null;
  const again = await mod.start(TOML, 'trinity', 1000, [SECRET]);
  checks.keptSameConfig = !!again && (again as { kept?: boolean }).kept === true;
  const stKept = await mod.getStatus();
  checks.keptSamePeer = !!stKept.infoJson && JSON.parse(stKept.infoJson)?.my_node_info?.peer_id === peerBefore;
  const tRestart = Date.now();
  await mod.restart();
  let back = false;
  while (!back && Date.now() - tRestart < 20000) {
    try {
      const res = await withTimeout(fetch(`http://127.0.0.1:18081/hello?after=restart`), 5000, 'fetch');
      back = (await res.text()).includes('hello-from-hub');
    } catch {
      await sleep(50);
    }
  }
  r.restartRecoverSec = back ? (Date.now() - tRestart) / 1000 : null;
  checks.restart = back;
  // M22-7: the new instance must take a lower peer id (the hub keeps the lowest one per credential).
  const stAfter = await mod.getStatus();
  const peerAfter = stAfter.infoJson ? JSON.parse(stAfter.infoJson)?.my_node_info?.peer_id ?? null : null;
  r.peerIds = { before: peerBefore, after: peerAfter };
  checks.restartLowerPeerId = typeof peerBefore === 'number' && typeof peerAfter === 'number' && peerAfter < peerBefore;
  await mod.setLaunchConfig(TOML, 'trinity');
  await mod.setLaunchConfig(null, null);
  checks.launchConfig = true;
  log(`restart: back after ${r.restartRecoverSec}s`);

  await sleep(2500); // let a couple of 1 s poll events arrive
  r.eventCount = events.length;
  r.lastEvent = events.length ? { ...events[events.length - 1], infoJson: undefined } : null;
  checks.events = events.length > 0 && events.some((e) => !!e.infoJson);
  sub.remove();

  await mod.stop();
  const after = await mod.getStatus();
  r.statusAfterStop = after;
  checks.stop = !after.running;
  r.elapsedSec = (Date.now() - t0) / 1000;
  r.pass = Object.values(checks).every(Boolean);
  return r;
}

async function report(result: Record<string, unknown>) {
  const json = JSON.stringify(result);
  console.error(`EASYTIER_E2E_RESULT ${json}`);
  for (let i = 0; i < 5; i++) {
    try {
      await fetch(COLLECTOR, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: json });
      return;
    } catch {
      await sleep(1000);
    }
  }
}

export default function App() {
  const [lines, setLines] = useState<string[]>(['EasyTier e2e running...']);
  useEffect(() => {
    const log = (s: string) => {
      console.error(`EASYTIER_E2E ${s}`);
      setLines((l) => [...l, s]);
    };
    run(log)
      .catch((e) => ({ pass: false, fatal: String(e?.stack ?? e?.message ?? e) }))
      .then(async (result) => {
        setLines((l) => [...l, JSON.stringify(result, null, 1)]);
        await report(result);
      });
  }, []);
  return (
    <ScrollView contentContainerStyle={{ padding: 16, paddingTop: 64 }}>
      {lines.map((l, i) => (
        <Text key={i} style={{ fontFamily: 'Menlo', fontSize: 11 }}>
          {l}
        </Text>
      ))}
    </ScrollView>
  );
}
