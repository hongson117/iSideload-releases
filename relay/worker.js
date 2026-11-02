// Optional self-hosted manifest relay for iSideload certificate installs (Cloudflare Worker, free tier).
// GET /?bundleid=..&name=..&version=..&fetchurl=http://127.0.0.1:PORT/app.ipa  -> manifest.plist
// Set its URL in iSideload > Cài đặt > Relay manifest.
const esc = s => String(s ?? "").replace(/[<>&'"]/g, c => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&apos;", '"': "&quot;" }[c]));
export default {
  async fetch(req) {
    const q = new URL(req.url).searchParams;
    const url = q.get("fetchurl") || "";
    if (!/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\//.test(url)) return new Response("fetchurl must be localhost", { status: 400 });
    const body = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>items</key><array><dict>
<key>assets</key><array><dict><key>kind</key><string>software-package</string><key>url</key><string>${esc(url)}</string></dict></array>
<key>metadata</key><dict><key>bundle-identifier</key><string>${esc(q.get("bundleid"))}</string>
<key>bundle-version</key><string>${esc(q.get("version") || "1.0")}</string><key>kind</key><string>software</string>
<key>title</key><string>${esc(q.get("name") || "App")}</string></dict></dict></array></dict></plist>`;
    return new Response(body, { headers: { "content-type": "application/xml" } });
  },
};
