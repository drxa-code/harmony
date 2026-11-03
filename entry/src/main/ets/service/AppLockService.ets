/**
 * 模块职责：应用锁服务（架构 T03 / 2.4）。
 * - PIN 设置：生成密码学随机盐 → sha256(salt + pin) → 存 Preferences（零权限、纯本地）
 * - 校验 / 锁定态：lock/unlock 只写 AppStorage('locked')，UI 层 PinLockOverlay 响应
 * - 忘记密码：唯一重置途径是清空全部数据（由调用方二次确认后执行）
 * - 错误 5 次仅提示，不做锁定惩罚（PRD 明确）
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { AppConstants, AppStorageKeys } from '../constants/AppConstants';
import { CryptoUtil } from '../utils/CryptoUtil';
import { SettingsService } from './SettingsService';
import { LogUtil } from '../utils/LogUtil';
import { ErrorMessages } from '../constants/ErrorMessages';

export class AppLockService {
  private static readonly TAG: string = 'AppLockService';

  /** 是否已开启应用锁（有开关且已设置 PIN） */
  public static isEnabled(): boolean {
    return SettingsService.isLockEnabled() && SettingsService.hasPin();
  }

  /** 是否处于锁定态 */
  public static isLocked(): boolean {
    const value: boolean | undefined = AppStorage.get<boolean>(AppStorageKeys.LOCKED);
    return value === true;
  }

  /** 是否已解锁 */
  public static isUnlocked(): boolean {
    return !AppLockService.isLocked();
  }

  /**
   * 设置 / 修改 PIN：生成盐 → 哈希 → 持久化 → 开启应用锁。
   * @param pin 4 位数字密码
   */
  public static async setPin(pin: string): Promise<void> {
    if (!AppLockService.isValidPin(pin)) {
      throw new Error(ErrorMessages.PIN_FORMAT_INVALID);
    }
    const salt: string = await CryptoUtil.randomHex(CryptoUtil.SALT_BYTES);
    const hash: string = await CryptoUtil.hashPin(pin, salt);
    SettingsService.setPinSalt(salt);
    SettingsService.setPinHash(hash);
    SettingsService.setLockEnabled(true);
    LogUtil.i(AppLockService.TAG, 'pin updated');
  }

  /** 关闭应用锁（清除凭据） */
  public static disable(): void {
    SettingsService.clearPin();
    AppStorage.setOrCreate(AppStorageKeys.LOCKED, false);
  }

  /**
   * 校验 PIN（PinLockOverlay 回调 / 修改 PIN 流程内旧密码校验）。
   * 恒定时间上不做特殊处理——纯本地场景下时序侧信道不适用，保持简单。
   */
  public static async verifyPin(pin: string): Promise<boolean> {
    if (!SettingsService.hasPin()) {
      return false;
    }
    const salt: string = SettingsService.getPinSalt();
    const stored: string = SettingsService.getPinHash();
    try {
      const hash: string = await CryptoUtil.hashPin(pin, salt);
      return hash === stored;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogUtil.e(AppLockService.TAG, 'verifyPin failed: ' + err.message);
      return false;
    }
  }

  /** 锁定（写 AppStorage，EntryAbility 冷启动 / 前台超时调用） */
  public static lock(): void {
    AppStorage.setOrCreate(AppStorageKeys.LOCKED, true);
  }

  /** 解锁 */
  public static unlock(): void {
    AppStorage.setOrCreate(AppStorageKeys.LOCKED, false);
  }

  /** PIN 格式校验：指定位数的纯数字 */
  public static isValidPin(pin: string): boolean {
    if (pin.length !== AppConstants.PIN_LENGTH) {
      return false;
    }
    for (let i = 0; i < pin.length; i++) {
      const code: number = pin.charCodeAt(i);
      if (code < 48 || code > 57) {
        return false;
      }
    }
    return true;
  }
}
