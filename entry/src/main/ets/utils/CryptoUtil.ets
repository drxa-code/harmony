/**
 * 模块职责：摘要与随机数（架构 1.1 选型：@kit.CryptoArchitectureKit cryptoFramework）。
 * 用途：应用锁 PIN 的加盐哈希（sha256(salt + pin)），零权限、纯本地。
 * 本文件不持有状态，所有方法均为纯函数式调用。
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { LogUtil } from './LogUtil';

export class CryptoUtil {
  /** 随机盐字节长度（十六进制串为其 2 倍长） */
  static readonly SALT_BYTES: number = 16;

  /**
   * 计算文本的 SHA-256 十六进制摘要。
   * 抛出的异常由调用方（AppLockService / 设置页）捕获并转为业务结果。
   */
  public static async sha256Hex(text: string): Promise<string> {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const bytes: Uint8Array = encoder.encodeInto(text);
    const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
    await md.update({ data: bytes });
    const digest: cryptoFramework.DataBlob = await md.digest();
    return CryptoUtil.toHex(digest.data);
  }

  /**
   * 生成指定字节长度的随机盐（十六进制串）。
   * 使用系统密码学安全随机源，不涉及任何设备标识符。
   */
  public static async randomHex(byteLength: number): Promise<string> {
    const rand: cryptoFramework.Random = cryptoFramework.createRandom();
    const blob: cryptoFramework.DataBlob = await rand.generateRandom(byteLength);
    return CryptoUtil.toHex(blob.data);
  }

  /**
   * PIN 加盐哈希：sha256(salt + pin)。
   * 盐与哈希分别存储于 Preferences，数据库中不留任何明文。
   */
  public static async hashPin(pin: string, salt: string): Promise<string> {
    return await CryptoUtil.sha256Hex(salt + pin);
  }

  /** 校验随机数生成等系统能力是否可用（供设置页做能力预检） */
  public static isCryptoAvailable(): boolean {
    try {
      cryptoFramework.createMd('SHA256');
      return true;
    } catch (e) {
      LogUtil.w('CryptoUtil', 'crypto capability check failed');
      return false;
    }
  }

  /** Uint8Array → 十六进制小写串 */
  private static toHex(bytes: Uint8Array): string {
    const hexChars: string = '0123456789abcdef';
    let result: string = '';
    for (let i = 0; i < bytes.length; i++) {
      const b: number = bytes[i];
      result += hexChars.charAt((b >> 4) & 0x0F);
      result += hexChars.charAt(b & 0x0F);
    }
    return result;
  }
}
