// dsh-lan-access — host-plane plugin row.
//
// Injects a secure-context shim into every served index.html before the app
// bundle runs, and prints the LAN URL once the server is bound.
//
// Root cause it fixes (deepseek-ai/deepseek-harness discussion #4209):
// the web client's mintRpcId() calls `crypto.randomUUID()` directly. That
// method only exists in secure contexts (https, or http://localhost), so on
// a phone browser hitting http://<lan-ip>:<port> it is undefined and the
// entire client RPC layer fails to boot. We polyfill it from
// `crypto.getRandomValues()`, which browsers expose on insecure origins too.
//
// The polyfill only activates when the native function is missing, so
// localhost/secure contexts keep the platform implementation.

import { networkInterfaces } from "node:os";

/** Stable Cordis plugin name (must match the row id in cordis.patch.yml). */
const name = "dsh-lan-access";
/** Services required before this row can mount. */
const inject = ["webServer"];

/**
 * Browser-side shim, injected verbatim into <head> of every index response.
 * Must be self-contained and must not contain the literal string "</script>".
 */
const SECURE_CONTEXT_SHIM = `(() => {
  var cryptoObj = globalThis.crypto;
  if (!cryptoObj || typeof cryptoObj.randomUUID === "function") return;
  var getRandomValues = cryptoObj.getRandomValues && cryptoObj.getRandomValues.bind(cryptoObj);
  if (typeof getRandomValues !== "function") return;
  function uuidV4() {
    var bytes = getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var hex = "";
    for (var i = 0; i < 16; i++) hex += bytes[i].toString(16).padStart(2, "0");
    return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20);
  }
  try {
    cryptoObj.randomUUID = uuidV4;
  } catch (error) {
    // Some browsers disallow writing the own property; the prototype arm below
    // usually still lands.
  }
  try {
    if (globalThis.Crypto && typeof globalThis.Crypto.prototype.randomUUID !== "function") {
      globalThis.Crypto.prototype.randomUUID = uuidV4;
    }
  } catch (error) {
    // Non-secure context without a writable prototype — nothing else to do.
  }
})();`;

/** Non-internal IPv4 addresses of this machine, for the LAN URL line. */
function lanIPv4() {
  const ifaces = Object.values(networkInterfaces()).flat();
  return ifaces.filter((i) => i !== void 0 && i.family === "IPv4" && !i.internal).map((i) => i.address);
}

/**
 * Insert the shim right after the opening <head> tag so it runs before the
 * deferred module bundle (classic inline scripts execute during parsing).
 * @param html - the raw index.html body produced by the webserver.
 * @returns the html with the shim script injected.
 */
function injectShim(html) {
  const script = `<script>${SECURE_CONTEXT_SHIM}<\/script>`;
  const head = /<head(?:\s[^>]*)?>/i.exec(html);
  if (head === null) return script + html;
  return `${html.slice(0, head.index + head[0].length)}${script}${html.slice(head.index + head[0].length)}`;
}

/**
 * Mount the row: register the index tap and announce the LAN URL once the
 * tree (and therefore the webserver bind) settles.
 * @param ctx - the composed host context.
 */
function apply(ctx) {
  ctx.effect(() => ctx.webServer.tapIndex(injectShim), "dsh-lan-access.indexTap");

  const announce = () => {
    const port = ctx.webServer.port;
    if (port === void 0) return;
    const lan = lanIPv4();
    if (lan.length === 0) return;
    const urls = lan.map((ip) => `http://${ip}:${String(port)}`).join(", ");
    console.log(`dsh-lan-access: LAN-ready on ${urls} (trusted home network only; do not expose publicly)`);
  };
  const settled = ctx.get("loader")?.await();
  if (settled === void 0) announce();
  else settled.then(() => {
    if (ctx.get("webServer") !== void 0) announce();
  }, () => {});
}

export { apply, inject, name };
