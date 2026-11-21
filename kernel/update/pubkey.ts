import fs from 'node:fs';

/**
 * 更新签名公钥（编译进程序，**不通过网络下发**）。
 *
 * 轮换方式：新旧两把同时留在表里，清单用 `keyId` 指定用哪把；等所有在线版本都
 * 换过一遍之后，再从表里删掉旧 keyId 对应的公钥。
 *
 * 私钥在发布机（`%USERPROFILE%\.colanas\deploy.pem` 或环境变量
 * `COLANAS_SIGN_KEY` 指向的文件），仓库里只有公钥。`*.pem` 已被 .gitignore 忽略。
 */
const KEYS: Record<string, string> = {
  'k2026a': `-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA0r5+BWYdaGpXHT+rthOnTeWTiLxtOBha/WFIKVRjp3s=
-----END PUBLIC KEY-----
`,
};

/**
 * 取公钥：`COLANAS_UPDATE_PUBKEY`（内联 PEM 或 PEM 文件路径）优先。
 *
 * 只在开发 / 自建分发时用 —— 它让「本机自己发、自己装」不需要改代码，
 * 正式服务端不带这个环境变量。
 */
export function publicKeyFor(keyId: string): string | null {
  const override = (process.env.COLANAS_UPDATE_PUBKEY || '').trim();
  if (override) {
    if (override.includes('BEGIN PUBLIC KEY')) return override;
    try {
      return fs.readFileSync(override, 'utf8');
    } catch {
      /* 读不到就当没配 */
    }
  }
  return KEYS[keyId] ?? null;
}

export function knownKeyIds(): string[] {
  return Object.keys(KEYS);
}

/** 当前默认 keyId（发布侧生成清单时用） */
export function defaultKeyId(): string {
  return (process.env.COLANAS_UPDATE_KEY_ID || 'k2026a').trim();
}
