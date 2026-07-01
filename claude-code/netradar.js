#!/usr/bin/env node
// Network radar daemon for the Claude Code statusline.
//   netradar.js start   -> spawn the daemon once (SessionStart hook), never hangs
//   netradar.js daemon  -> the long-running monitor loop

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const dir = path.join(os.homedir(), ".claude", "statusbar");
const sessDir = path.join(dir, "sessions.d");
const netPath = path.join(dir, "net.json");
const basePath = path.join(dir, "net-baseline.json");
const SELF = __filename;
const NODE = process.execPath;
const INTERVAL_MS = 10000;
const EMPTY_TICKS_TO_EXIT = 3; // ~30s of no active sessions -> stop

const sh = (cmd) => {
  try { return cp.execSync(cmd, { encoding: "utf8", timeout: 8000, stdio: ["ignore", "pipe", "ignore"] }); }
  catch { return ""; }
};

const norm = (mac) =>
  mac.toLowerCase().split(":").map((o) => (o.length === 1 ? "0" + o : o)).join(":");

const isNonUnicast = (mac) =>
  mac.startsWith("01:00:5e") || mac.startsWith("33:33") ||
  mac.startsWith("ff:ff:ff") || mac === "00:00:00:00:00:00";

// --- snapshot helpers -------------------------------------------------------

function lanDevices() {
  const out = sh("arp -an");
  const devs = [];
  const seen = new Set();
  for (const line of out.split("\n")) {
    const m = line.match(/\(([\d.]+)\)\s+at\s+([0-9a-f:]+)/i);
    if (!m) continue;
    const ip = m[1];
    if (/^(224\.|239\.|255\.)/.test(ip) || ip.endsWith(".255")) continue;
    const mac = norm(m[2]);
    if (isNonUnicast(mac) || seen.has(mac)) continue;
    seen.add(mac);
    devs.push({ ip, mac });
  }
  return devs;
}

const alertedPath = path.join(dir, "net-alerted.json");
function loadAlerted() { try { return new Set(JSON.parse(fs.readFileSync(alertedPath, "utf8"))); } catch { return new Set(); } }
function saveAlerted(set) { try { writeJson(alertedPath, [...set]); } catch {} }

// macOS notification + sound (no repeats: caller debounces per MAC)
function notify(title, msg) {
  try {
    cp.execFile("/usr/bin/osascript", ["-e",
      `display notification ${JSON.stringify(msg)} with title ${JSON.stringify(title)} sound name "Glass"`],
      { timeout: 5000 }, () => {});
  } catch {}
}

function inboundIps() {
  // externally-reachable listening ports (not bound only to loopback)
  const listen = sh("lsof -nP -iTCP -sTCP:LISTEN");
  const ports = new Set();
  for (const line of listen.split("\n")) {
    const m = line.match(/TCP\s+(\S+):(\d+)\s+\(LISTEN\)/);
    if (!m) continue;
    const host = m[1];
    if (host === "127.0.0.1" || host === "[::1]" || host === "localhost") continue;
    ports.add(m[2]);
  }
  if (ports.size === 0) return [];
  const est = sh("lsof -nP -iTCP -sTCP:ESTABLISHED");
  const ips = [];
  for (const line of est.split("\n")) {
    const m = line.match(/TCP\s+\S+:(\d+)->(\S+):\d+\s+\(ESTABLISHED\)/);
    if (!m) continue;
    const localPort = m[1];
    const foreign = m[2];
    if (!ports.has(localPort)) continue;
    if (foreign === "127.0.0.1" || foreign === "[::1]" || foreign === "localhost") continue;
    if (!ips.includes(foreign)) ips.push(foreign);
  }
  return ips;
}

// --- auto-block (opt-in: only when autoblock.on flag exists, set by net-guard.sh setup) ---
const guardPath = path.join(dir, "net-guard.sh");
const flagPath = path.join(dir, "autoblock.on");
const allowPath = path.join(dir, "net-allow.json");
const blockedPath = path.join(dir, "net-blocked.json");
function loadSet(p) { try { return new Set(JSON.parse(fs.readFileSync(p, "utf8"))); } catch { return new Set(); } }
function saveSet(p, s) { try { writeJson(p, [...s]); } catch {} }
function autoBlockInbound(ips) {
  if (!fs.existsSync(flagPath) || !ips.length) return;
  const allow = loadSet(allowPath), blocked = loadSet(blockedPath);
  const fresh = ips.filter((ip) => !allow.has(ip) && !blocked.has(ip));
  if (!fresh.length) return;
  for (const ip of fresh) {
    cp.execFile("/bin/sh", [guardPath, "block", ip], { timeout: 8000 }, () => {});
    blocked.add(ip);
  }
  saveSet(blockedPath, blocked);
  notify("NetRadar: авто-блок входящего", fresh.join(", "));
}

function baseline() {
  try { return new Set(JSON.parse(fs.readFileSync(basePath, "utf8"))); }
  catch { return null; }
}

function writeJson(p, obj) {
  const tmp = p + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(obj));
  fs.renameSync(tmp, p);
}

function activeSessions() {
  try { return fs.readdirSync(sessDir).length; } catch { return 0; }
}

// --- daemon loop ------------------------------------------------------------

function tick(state) {
  const devs = lanDevices();
  const macs = new Set(devs.map((d) => d.mac));
  let base = baseline();
  if (!base) { base = new Set(macs); writeJson(basePath, [...base]); saveAlerted(new Set()); } // first run = baseline
  const newDevs = devs.filter((d) => !base.has(d.mac));

  // alert once per newly-seen device
  const alerted = loadAlerted();
  const fresh = newDevs.filter((d) => !alerted.has(d.mac));
  if (fresh.length) {
    const list = fresh.map((d) => `${d.ip} (${d.mac})`).join(", ");
    notify("NetRadar: новое устройство", fresh.length === 1 ? list : `${fresh.length} новых — ${list}`);
    for (const d of fresh) alerted.add(d.mac);
    saveAlerted(alerted);
  }

  const inbIps = inboundIps();
  autoBlockInbound(inbIps);
  writeJson(netPath, { lan: macs.size, new: newDevs.length, inbound: inbIps.length, ts: Math.floor(Date.now() / 1000) });

  if (activeSessions() === 0) {
    if (++state.empty >= EMPTY_TICKS_TO_EXIT) process.exit(0);
  } else state.empty = 0;
}

function runDaemon() {
  fs.mkdirSync(dir, { recursive: true });
  const state = { empty: 0 };
  try { tick(state); } catch {}
  setInterval(() => { try { tick(state); } catch {} }, INTERVAL_MS);
}

// --- start (hook entry) -----------------------------------------------------

function alreadyRunning() {
  try { cp.execSync(`pgrep -f "netradar.js daemon"`, { stdio: "ignore" }); return true; }
  catch { return false; }
}

function start() {
  if (alreadyRunning()) return;
  const child = cp.spawn(NODE, [SELF, "daemon"], { detached: true, stdio: "ignore" });
  child.unref();
}

const mode = process.argv[2] || "start";
if (mode === "daemon") runDaemon();
else { try { start(); } catch {} process.exit(0); }
