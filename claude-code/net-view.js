#!/usr/bin/env node
// netradar view — "кто откуда" на сети. Приватно по умолчанию:
//   node net-view.js            -> LAN + внешние соединения, обогащение только rDNS
//   node net-view.js --whois    -> дополнительно запросить whois (org/страна) [внешние запросы!]
// Производитель по MAC берётся из локального ~/.claude/statusbar/oui.txt если он есть.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const WHOIS = process.argv.includes("--whois");
const dir = path.join(os.homedir(), ".claude", "statusbar");
const ouiPath = path.join(dir, "oui.txt");

const C = { g: "\x1b[32m", c: "\x1b[36m", y: "\x1b[33m", r: "\x1b[31m", dim: "\x1b[90m", b: "\x1b[1m", x: "\x1b[0m" };
const sh = (cmd) => { try { return cp.execSync(cmd, { encoding: "utf8", timeout: 8000, stdio: ["ignore", "pipe", "ignore"] }); } catch { return ""; } };
const norm = (m) => m.toLowerCase().split(":").map((o) => (o.length === 1 ? "0" + o : o)).join(":");
const isNonUnicast = (m) => m.startsWith("01:00:5e") || m.startsWith("33:33") || m.startsWith("ff:ff:ff") || m === "00:00:00:00:00:00";

// OUI (vendor) lookup from local file: lines "AABBCC<TAB>Vendor" (first 3 octets, no separators)
let OUI = null;
function vendor(mac) {
  if (OUI === null) {
    OUI = new Map();
    try {
      for (const line of fs.readFileSync(ouiPath, "utf8").split("\n")) {
        const m = line.match(/^([0-9A-Fa-f]{6})\s+(.+)$/);
        if (m) OUI.set(m[1].toUpperCase(), m[2].trim());
      }
    } catch {}
  }
  const key = mac.replace(/:/g, "").slice(0, 6).toUpperCase();
  return OUI.get(key) || "";
}

const rdnsCache = new Map();
function rdns(ip) {
  if (rdnsCache.has(ip)) return rdnsCache.get(ip);
  const out = sh(`host -W 2 ${ip}`);
  const m = out.match(/pointer\s+(.+?)\.?\s*$/m);
  const name = m ? m[1] : "";
  rdnsCache.set(ip, name);
  return name;
}

function whoisOrg(ip) {
  const out = sh(`whois ${ip}`);
  const org = (out.match(/(?:OrgName|org-name|Organization|descr):\s*(.+)/i) || [])[1] || "";
  const country = (out.match(/Country:\s*([A-Z]{2})/i) || [])[1] || "";
  return [org.trim(), country.trim()].filter(Boolean).join(", ");
}

// ---- LAN devices ----
function lanDevices() {
  const rows = [];
  for (const line of sh("arp -an").split("\n")) {
    const m = line.match(/\(([\d.]+)\)\s+at\s+([0-9a-f:]+)/i);
    if (!m) continue;
    const ip = m[1], mac = norm(m[2]);
    if (/^(224\.|239\.|255\.)/.test(ip) || ip.endsWith(".255") || isNonUnicast(mac)) continue;
    rows.push({ ip, mac, vendor: vendor(mac), host: rdns(ip) });
  }
  return rows;
}

// ---- external connections ----
function externalConns() {
  const listen = new Set();
  for (const line of sh("lsof -nP -iTCP -sTCP:LISTEN").split("\n")) {
    const m = line.match(/TCP\s+(\S+):(\d+)\s+\(LISTEN\)/);
    if (m && !["127.0.0.1", "[::1]", "localhost"].includes(m[1])) listen.add(m[2]);
  }
  const rows = [];
  for (const line of sh("lsof -nP -iTCP -sTCP:ESTABLISHED").split("\n")) {
    const m = line.match(/^(\S+)\s+\d+\s.*\bTCP\s+(\S+):(\d+)->(\S+):(\d+)\s+\(ESTABLISHED\)/);
    if (!m) continue;
    const proc = m[1], lport = m[3], rip = m[4], rport = m[5];
    if (["127.0.0.1", "[::1]", "localhost"].includes(rip)) continue;
    const dir = listen.has(lport) ? "IN" : "out";
    rows.push({ proc, lport, rip, rport, dir, host: rdns(rip), org: WHOIS ? whoisOrg(rip) : "" });
  }
  // входящие сверху
  return rows.sort((a, b) => (a.dir === b.dir ? 0 : a.dir === "IN" ? -1 : 1));
}

// ---- render ----
const pad = (s, n) => { s = String(s || ""); return s.length >= n ? s.slice(0, n) : s + " ".repeat(n - s.length); };

const lan = lanDevices();
console.log(`${C.b}${C.c}LAN DEVICES${C.x} ${C.dim}(${lan.length})${C.x}`);
console.log(C.dim + pad("IP", 16) + pad("MAC", 19) + pad("VENDOR", 16) + "HOST" + C.x);
for (const d of lan) {
  console.log(C.g + pad(d.ip, 16) + C.x + pad(d.mac, 19) + pad(d.vendor || "-", 16) + (d.host || C.dim + "-" + C.x));
}

const ext = externalConns();
console.log("");
console.log(`${C.b}${C.c}EXTERNAL CONNECTIONS${C.x} ${C.dim}(${ext.length})${C.x}`);
console.log(C.dim + pad("DIR", 5) + pad("PROC", 14) + pad("REMOTE", 22) + pad("RDNS", 34) + (WHOIS ? "ORG" : "") + C.x);
for (const e of ext) {
  const dirc = e.dir === "IN" ? C.r + C.b + pad(e.dir, 5) + C.x : C.dim + pad(e.dir, 5) + C.x;
  console.log(dirc + pad(e.proc, 14) + C.y + pad(`${e.rip}:${e.rport}`, 22) + C.x + pad(e.host || "-", 34) + (WHOIS ? (e.org || "-") : ""));
}
if (!WHOIS) console.log(`\n${C.dim}подсказка: добавь --whois для org/страны (будут внешние whois-запросы).${C.x}`);
