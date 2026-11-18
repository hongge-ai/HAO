#!/usr/bin/env node
// 客户端本地可选压测工具（Node.js >= 18，零第三方依赖）：
// 模拟 Chrome 浏览器建立 1 条持久的 HTTP/2 加密代理长连接，并在同一连接上
// 同时向 10 个不同海外核心域名发起并发 CONNECT 隧道与真实 HTTPS 请求。
//
// 用法（在客户端电脑运行）:
//   node science/scripts/bench-h2.mjs --credentials-file ./httpsproxy.txt

import { open } from 'node:fs/promises';
import http2 from 'node:http2';
import tls from 'node:tls';

const [option, credentialPath, ...extra] = process.argv.slice(2);
if (option !== '--credentials-file' || !credentialPath || extra.length) {
  console.error('用法: node bench-h2.mjs --credentials-file ./httpsproxy.txt');
  process.exit(1);
}

async function readProxyCredentials(path) {
  const file = await open(path, 'r');
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > 64 * 1024) {
      throw new Error('请提供客户端连接说明文件。');
    }
    if (process.platform !== 'win32' && (stat.mode & 0o077) !== 0) {
      throw new Error('请先用 chmod 600 限制客户端连接说明的权限。');
    }
    const contents = await file.readFile('utf8');
    const fields = /^https ([A-Za-z0-9.-]+) ([0-9]{1,5}) ([^\s:]+) ([^\r\n]+)\r?$/m.exec(contents);
    if (!fields) {
      throw new Error('客户端连接说明应包含 HTTPS 速查行。');
    }
    const [, host, port, username, password] = fields;
    if (Number(port) < 1 || Number(port) > 65535) {
      throw new Error('代理端口超出范围。');
    }
    const proxyUrl = new URL(`https://${host}:${port}`);
    const auth = 'Basic ' + Buffer.from(`${username}:${password}`).toString('base64');
    return { proxyUrl, auth };
  } finally {
    await file.close();
  }
}

const { proxyUrl, auth } = await readProxyCredentials(credentialPath).catch((error) => {
  const message = error.code === 'ERR_INVALID_URL' ? '代理域名无效。' : error.message;
  console.error(`读取代理凭据失败。 ${message}`);
  process.exit(1);
});

const TARGETS = [
  ['www.google.com', '/generate_204'],
  ['www.gstatic.com', '/generate_204'],
  ['fonts.googleapis.com', '/css?family=Roboto'],
  ['www.youtube.com', '/generate_204'],
  ['i.ytimg.com', '/generate_204'],
  ['github.com', '/favicon.ico'],
  ['github.githubassets.com', '/favicons/favicon.svg'],
  ['cp.cloudflare.com', '/generate_204'],
  ['cdn.jsdelivr.net', '/npm/jquery@3.7.1/package.json'],
  ['www.wikipedia.org', '/'],
];

const tSession = performance.now();
const client = http2.connect(proxyUrl.origin, { ALPNProtocols: ['h2'] });
const timeoutMs = 15000;

const connected = await new Promise((resolve) => {
  const timer = setTimeout(() => client.destroy(new Error('建立代理连接超时')), timeoutMs);
  client.once('connect', () => {
    clearTimeout(timer);
    resolve(true);
  });
  client.on('error', (error) => {
    clearTimeout(timer);
    console.error(`代理连接失败。 ${error.message}`);
    resolve(false);
  });
});
if (!connected) process.exit(1);

const alpn = client.socket.alpnProtocol;
console.log(`H2 长连接建立耗时: ${(performance.now() - tSession).toFixed(0)}ms | ALPN=${alpn} | TLS=${client.socket.getProtocol()}`);
if (alpn !== 'h2') {
  console.error('警告: 服务端未协商出 h2（实际为 ' + alpn + '），请检查 sing-box >= 1.15.0 且配置了 alpn: ["h2", "http/1.1"]');
  client.close();
  process.exit(2);
}

const tBatch = performance.now();
const results = await Promise.all(
  TARGETS.map(([host, path]) => new Promise((resolve) => {
    const t0 = performance.now();
    const req = client.request({
      ':method': 'CONNECT',
      ':authority': `${host}:443`,
      'proxy-authorization': auth,
    });
    const timer = setTimeout(() => req.destroy(new Error('请求超时')), timeoutMs);
    const finish = (result) => {
      clearTimeout(timer);
      resolve({ host, ...result });
    };
    req.once('close', () => finish({ err: '代理隧道结束前未收到完整响应' }));
    req.once('response', (headers) => {
      const status = headers[':status'];
      if (status !== 200) {
        finish({ err: `Proxy HTTP ${status}` });
        req.close();
        return;
      }
      const tConn = performance.now() - t0;
      let response = '';
      const sock = tls.connect({ socket: req, servername: host, ALPNProtocols: ['http/1.1'] }, () => {
        sock.write(`GET ${path} HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\nUser-Agent: Mozilla/5.0\r\n\r\n`);
        sock.on('data', (chunk) => {
          response += chunk.toString('latin1');
          const endOfLine = response.indexOf('\r\n');
          if (endOfLine < 0 && response.length < 1024) return;

          const tTtfb = performance.now() - t0;
          const statusLine = endOfLine < 0 ? '' : response.slice(0, endOfLine);
          const result = /^HTTP\/1\.[01] [23][0-9]{2}(?: |$)/.test(statusLine)
            ? { tConn, tTtfb, statusLine }
            : { err: '目标未返回 2xx 或 3xx 状态' };
          finish(result);
          sock.destroy();
        });
      });
      sock.once('error', (error) => finish({ err: error.message }));
    });
    req.once('error', (error) => finish({ err: error.message }));
  }))
);

const wallMs = performance.now() - tBatch;
client.close();

let okCount = 0;
for (const r of results) {
  if (r.err) {
    console.log(`  [FAIL] ${r.host.padEnd(24)} -> ${r.err}`);
  } else {
    okCount++;
    console.log(`  [OK]   ${r.host.padEnd(24)} CONNECT=${r.tConn.toFixed(0).padStart(3)}ms | TTFB=${r.tTtfb.toFixed(0).padStart(4)}ms | ${r.statusLine}`);
  }
}

console.log(`\n==> 汇总: ${okCount}/${TARGETS.length} 域名成功 | 单连接并发总耗时: ${wallMs.toFixed(0)}ms`);
process.exit(okCount === TARGETS.length ? 0 : 1);
