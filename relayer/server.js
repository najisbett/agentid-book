/**
 * AgentID Book relayer.
 *
 * Users sign an EIP-712 Bind message with the wallet their Agent ID resolves to.
 * This server submits that signature to the contract and pays the gas, so binding
 * costs a holder nothing but a signature.
 */
const http = require("http");
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const PORT = Number(process.env.PORT || 8099);
const RPC = process.env.BSC_RPC || "https://bsc-dataseed.binance.org";
const CONTRACT = process.env.CONTRACT;
const PK = process.env.RELAYER_PK;
const SITE = path.join(__dirname, "..", "site");
const LOG = path.join(__dirname, "bind.log");

if (!CONTRACT || !PK) { console.error("CONTRACT and RELAYER_PK are required"); process.exit(1); }

const provider = new ethers.JsonRpcProvider(RPC, 56, { staticNetwork: true });
const wallet = new ethers.Wallet(PK, provider);
const book = new ethers.Contract(CONTRACT, [
  "function idOfHandle(string) pure returns (bytes32)",
  "function resolveHandle(string) view returns (address)",
  "function idOf(address) view returns (bytes32)",
  "function handleOf(address) view returns (string)",
  "function entryOf(bytes32) view returns (address,uint64,string)",
  "function agentCount() view returns (uint256)",
  "function agentAt(uint256) view returns (address)",
  "function bind(bytes32,address,string,uint256,bytes)",
], wallet);

const seen = new Set();
const recent = [];           // {t} for a simple 10/min cap
const WINDOW_MS = 60_000, MAX_PER_WINDOW = 30;

function log(line) { fs.appendFileSync(LOG, `${new Date().toISOString()} ${line}\n`); }

function json(res, code, body) {
  const s = JSON.stringify(body);
  res.writeHead(code, { "content-type": "application/json", "access-control-allow-origin": "*", "cache-control": "no-store" });
  res.end(s);
}

function normalise(h) { return String(h || "").trim().toLowerCase().replace(/\.ai$/, ""); }

async function agentsList() {
  const n = Number(await book.agentCount());
  const out = [];
  for (let i = 0; i < n && i < 200; i++) {
    const owner = await book.agentAt(i);
    const id = await book.idOf(owner);
    const e = await book.entryOf(id);
    if (e[0] !== ethers.ZeroAddress) out.push({ owner, handle: e[2], boundAt: Number(e[1]) });
  }
  return out;
}

async function handleBind(body, res) {
  const now = Date.now();
  while (recent.length && now - recent[0] > WINDOW_MS) recent.shift();
  if (recent.length >= MAX_PER_WINDOW) return json(res, 429, { ok: false, error: "relayer busy, try again in a minute" });
  recent.push(now);

  const handle = normalise(body.handle);
  const owner = String(body.owner || "");
  const deadline = Number(body.deadline);
  const signature = String(body.signature || "");
  const id = String(body.id || "");

  if (!handle || handle.length > 64) return json(res, 400, { ok: false, error: "bad handle" });
  if (!ethers.isAddress(owner)) return json(res, 400, { ok: false, error: "bad owner" });
  if (!Number.isFinite(deadline) || deadline * 1000 < now) return json(res, 400, { ok: false, error: "signature expired" });
  if (!/^0x[0-9a-fA-F]{130}$/.test(signature)) return json(res, 400, { ok: false, error: "bad signature" });

  const expected = await book.idOfHandle(handle);
  if (id.toLowerCase() !== expected.toLowerCase()) return json(res, 400, { ok: false, error: "id does not match handle" });

  const recovered = ethers.verifyTypedData(
    { name: "AgentIDBook", version: "1", chainId: 56, verifyingContract: CONTRACT },
    { Bind: [ { name: "id", type: "bytes32" }, { name: "owner", type: "address" }, { name: "handle", type: "string" }, { name: "deadline", type: "uint256" } ] },
    { id, owner, handle, deadline }, signature);
  if (ethers.getAddress(recovered) !== ethers.getAddress(owner)) return json(res, 400, { ok: false, error: "signature is not from that address", recovered });

  const bound = await book.idOf(owner);
  if (bound !== ethers.ZeroHash) return json(res, 409, { ok: false, error: "this address already holds an Agent ID here" });
  const existing = await book.entryOf(id);
  if (existing[0] !== ethers.ZeroAddress) return json(res, 409, { ok: false, error: "that handle is already bound" });

  const key = `${owner.toLowerCase()}:${id.toLowerCase()}`;
  if (seen.has(key)) return json(res, 409, { ok: false, error: "already submitted" });
  seen.add(key);

  try {
    const tx = await book.bind(id, owner, handle, deadline, signature, { gasLimit: 180000 });
    log(`bind ${handle} owner=${owner} tx=${tx.hash}`);
    json(res, 200, { ok: true, tx: tx.hash, hash: tx.hash });
  } catch (e) {
    seen.delete(key);
    const msg = (e.shortMessage || e.message || "transaction failed").slice(0, 200);
    log(`bind failed ${handle} owner=${owner}: ${msg}`);
    json(res, 500, { ok: false, error: msg });
  }
}

http.createServer(async (req, res) => {
  const u = new URL(req.url, `http://localhost:${PORT}`);
  if (req.method === "OPTIONS") { res.writeHead(204, { "access-control-allow-origin": "*", "access-control-allow-headers": "content-type", "access-control-allow-methods": "GET,POST,OPTIONS" }); return res.end(); }
  try {
    if (u.pathname === "/id") return json(res, 200, { id: await book.idOfHandle(normalise(u.searchParams.get("handle"))) });
    if (u.pathname === "/resolve") return json(res, 200, { address: await book.resolveHandle(normalise(u.searchParams.get("handle"))) });
    if (u.pathname === "/agents") return json(res, 200, { agents: await agentsList() });
    if (u.pathname === "/health") return json(res, 200, { ok: true, contract: CONTRACT, relayer: wallet.address, balance: ethers.formatEther(await provider.getBalance(wallet.address)) });
    if (u.pathname === "/bind" && req.method === "POST") {
      let raw = ""; for await (const c of req) { raw += c; if (raw.length > 20000) return json(res, 413, { ok: false, error: "too large" }); }
      let body = {}; try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: "bad json" }); }
      return await handleBind(body, res);
    }
    // static site
    const file = u.pathname === "/" ? "index.html" : u.pathname.slice(1);
    const p = path.join(SITE, file);
    if (!p.startsWith(SITE) || !fs.existsSync(p)) { res.writeHead(404); return res.end("not found"); }
    res.writeHead(200, { "content-type": p.endsWith(".html") ? "text/html; charset=utf-8" : "application/octet-stream" });
    fs.createReadStream(p).pipe(res);
  } catch (e) {
    json(res, 500, { ok: false, error: String(e.message || e).slice(0, 200) });
  }
}).listen(PORT, "0.0.0.0", () => console.log(`AgentID Book relayer on :${PORT} contract=${CONTRACT} relayer=${wallet.address}`));