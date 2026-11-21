import crypto from 'node:crypto';
import fs from 'node:fs';
import { canonicalPayload } from '../updater';
import { publicKeyFor } from './pubkey';

export class UpdateVerifyError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'UpdateVerifyError';
  }
}

export function sha256File(p: string): string {
  return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
}

export function sha256(data: Buffer | string): string {
  return crypto.createHash('sha256').update(data).digest('hex');
}

/**
 * 逐字节验签：签名的是**文件原文**，不是解析后的对象。
 *
 * 这一点很关键 —— 用「解析再重新序列化」的方式验签，一旦发布侧和客户端
 * 的 JSON 序列化细节（键顺序、空格、\u 转义）有任何差异就永远验不过。
 */
export function verifyBytes(data: Buffer, signatureB64: string, keyId: string): void {
  const pem = publicKeyFor(keyId);
  if (!pem) {
    throw new UpdateVerifyError('E_UNKNOWN_KEY', `未知签名密钥: ${keyId}`);
  }
  const sig = Buffer.from(String(signatureB64 || '').trim(), 'base64');
  if (sig.length === 0) throw new UpdateVerifyError('E_SIGNATURE', '清单签名为空');
  const ok = crypto.verify(null, data, pem, sig);
  if (!ok) throw new UpdateVerifyError('E_SIGNATURE', '清单签名校验失败（内容被篡改或密钥不匹配）');
}

/** 读一个文件 + 它的 `.sig` 文件并验签；返回原文 */
export function verifySignedFile(filePath: string, sigPath: string, keyId: string): Buffer {
  let data: Buffer;
  let sig: string;
  try {
    data = fs.readFileSync(filePath);
    sig = fs.readFileSync(sigPath, 'utf8');
  } catch (err) {
    throw new UpdateVerifyError('E_IO', `签名文件缺失: ${String((err as Error).message)}`);
  }
  verifyBytes(data, sig, keyId);
  return data;
}

/**
 * 版本目录级清单校验（`manifest.json`）：与 `Updater.verify` 同一套
 * `canonicalPayload(version, files)` 口径，这里只做签名部分。
 */
export function verifyVersionManifest(
  manifestText: Buffer,
  signatureB64: string,
  keyId: string,
): { version: number; files: Record<string, string> } {
  let parsed: { version?: number; files?: Record<string, string>; algo?: string };
  try {
    parsed = JSON.parse(manifestText.toString('utf8')) as typeof parsed;
  } catch {
    throw new UpdateVerifyError('E_MANIFEST', 'manifest.json 不可解析');
  }
  if (!parsed.version || !parsed.files) {
    throw new UpdateVerifyError('E_MANIFEST', 'manifest.json 缺 version/files');
  }
  const pem = publicKeyFor(keyId);
  if (!pem) throw new UpdateVerifyError('E_UNKNOWN_KEY', `未知签名密钥: ${keyId}`);
  const ok = crypto.verify(
    null,
    canonicalPayload(parsed.version, parsed.files),
    pem,
    Buffer.from(String(signatureB64 || '').trim(), 'base64'),
  );
  if (!ok) throw new UpdateVerifyError('E_SIGNATURE', 'manifest.json 签名校验失败');
  return { version: parsed.version, files: parsed.files };
}
