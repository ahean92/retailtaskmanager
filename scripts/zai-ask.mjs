#!/usr/bin/env node
// zai-ask — one-shot prompt → answer (text or JSON) via the Z.AI coding-plan
// subscription using the API key stored by the ZCode desktop app.
//
// Usage:
//   node zai-ask.mjs "prompt"                 answer as plain text
//   node zai-ask.mjs --json "prompt"          full JSON response body
//   echo "prompt" | node zai-ask.mjs          prompt from stdin
// Options:
//   --json                print the raw JSON response instead of text
//   --model <id>          model id (default: GLM-5.3)
//   --max-tokens <n>      response budget (default: 4096)
//   --system <text>       optional system prompt
//   --thinking            keep the model's reasoning blocks in text output
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import https from 'node:https';

const args = process.argv.slice(2);
function opt(name) {
  const i = args.indexOf(name);
  if (i < 0) return undefined;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
}
const wantJson = args.includes('--json') && args.splice(args.indexOf('--json'), 1).length > 0;
const keepThinking = args.includes('--thinking') && args.splice(args.indexOf('--thinking'), 1).length > 0;
const model = opt('--model') ?? 'GLM-5.3';
const maxTokens = Number(opt('--max-tokens') ?? 4096);
const system = opt('--system');

let prompt = args.join(' ').trim();
if (!prompt && !process.stdin.isTTY) prompt = fs.readFileSync(0, 'utf8').trim();
if (!prompt) {
  console.error('usage: node zai-ask.mjs [--json] [--model <id>] [--max-tokens <n>] [--system <text>] "prompt"');
  process.exit(2);
}

const credPath = path.join(os.homedir(), '.zcode', 'v2', 'credentials.json');
const raw = JSON.parse(fs.readFileSync(credPath, 'utf8'));
const SECRET = process.env.ZCODE_CREDENTIAL_SECRET?.trim()
  ?? `zcode-credential-fallback:${os.platform()}:${os.homedir()}:${os.userInfo().username}`;
const cipherKey = crypto.createHash('sha256').update(SECRET).digest();

function decrypt(v) {
  if (typeof v !== 'string' || !v.startsWith('enc:v1:')) return v;
  const [iv, tag, data] = v.slice('enc:v1:'.length).split('.');
  const d = crypto.createDecipheriv('aes-256-gcm', cipherKey, Buffer.from(iv, 'base64url'));
  d.setAuthTag(Buffer.from(tag, 'base64url'));
  return Buffer.concat([d.update(Buffer.from(data, 'base64url')), d.final()]).toString('utf-8');
}

// any coding-plan API key entry; not tied to one account id
const keyEntry = Object.entries(raw).find(([k, v]) => k.endsWith(':api-key') && k.includes('coding-plan'));
if (!keyEntry) { console.error('zai-ask: no coding-plan API key found in ' + credPath); process.exit(1); }
let apiKey = decrypt(keyEntry[1]);
try { apiKey = JSON.parse(apiKey).apiKey ?? apiKey; } catch { /* plain string */ }

// agent:false — no keep-alive sockets left behind; plain fetch() trips a libuv
// assertion at exit on Windows (src\win\async.c UV_HANDLE_CLOSING).
function postJson(body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const req = https.request({
      hostname: 'api.z.ai',
      path: '/api/anthropic/v1/messages',
      method: 'POST',
      agent: false,
      headers: {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(data),
        'anthropic-version': '2023-06-01',
        authorization: `Bearer ${apiKey}`,
      },
    }, (res) => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    req.end(data);
  });
}

const { status, text } = await postJson({
  model,
  max_tokens: maxTokens,
  messages: [{ role: 'user', content: prompt }],
  ...(system ? { system } : {}),
});

if (status < 200 || status >= 300) {
  console.error(`zai-ask: HTTP ${status}: ${text.slice(0, 500)}`);
  process.exit(1);
}

if (wantJson) { console.log(text); process.exit(0); }

const res = JSON.parse(text);
const parts = (res.content ?? [])
  .filter(b => b.type === 'text' || (keepThinking && b.type === 'thinking'))
  .map(b => b.text ?? '');
console.log(parts.join('\n').trim() || JSON.stringify(res).slice(0, 400));
