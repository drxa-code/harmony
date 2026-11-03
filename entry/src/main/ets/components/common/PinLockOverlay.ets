/**
 * 模块职责：应用锁全屏 PIN 覆盖层（架构 T01 骨架 + 2.4 叠加层）。
 * - 覆盖于 Index 根 Stack 最上层（zIndex 最高），locked=true 时渲染
 * - PIN 校验通过回调交给宿主页完成（components 禁止调用 Service，架构 3.1）
 * - 错误仅提示（架构 2.4：不做锁定惩罚）
 * - 忘记密码：明确提示需清空全部数据以重置（文案走 string.json）
 */
import { palette } from '../../constants/ThemeConstants';
import { AppConstants, AppStorageKeys } from '../../constants/AppConstants';
import { ToastUtil } from '../../utils/ToastUtil';

@Component
export struct PinLockOverlay {
  @StorageLink(AppStorageKeys.IS_DARK) isDark: boolean = false;
  /** 已输入的 PIN（组件内状态） */
  @State private inputPin: string = '';
  /** 是否处于错误抖动提示态 */
  @State private showError: boolean = false;
  /** PIN 校验回调：返回 true 表示校验通过（宿主页实现解锁） */
  onSubmit?: (pin: string) => Promise<boolean>;
  /** 忘记密码回调（宿主页弹出确认并走清空数据重置流程） */
  onForgot?: () => void;

  build() {
    Column({ space: 16 }) {
      Blank().height(64)

      Text($r('app.string.lock_title'))
        .fontSize($r('app.float.font_title'))
        .fontWeight(FontWeight.Medium)
        .fontColor(palette(this.isDark).textPrimary)

      Text($r('app.string.lock_subtitle'))
        .fontSize($r('app.float.font_aux'))
        .fontColor(palette(this.isDark).textSecondary)

      // 密码圆点
      Row({ space: 16 }) {
        ForEach(this.dotIndexes(), (item: number) => {
          Circle()
            .width(14)
            .height(14)
            .fill(this.inputPin.length > item ?
            palette(this.isDark).primary : palette(this.isDark).divider)
        }, (item: number) => 'dot_' + item.toString())
      }
      .height(24)

      if (this.showError) {
        Text($r('app.string.lock_error'))
          .fontSize($r('app.float.font_aux'))
          .fontColor(palette(this.isDark).danger)
      }

      // 数字键盘
      Column({ space: 12 }) {
        ForEach(this.keyRows(), (row: string[]) => {
          Row({ space: 12 }) {
            ForEach(row, (key: string) => {
              if (key === '') {
                // 占位空键
                Blank()
                  .width(64)
                  .height(64)
              } else if (key === 'del') {
                Text('⌫')
                  .fontSize(22)
                  .fontColor(palette(this.isDark).textPrimary)
                  .width(64)
                  .height(64)
                  .textAlign(TextAlign.Center)
                  .onClick(() => {
                    this.onDeleteKey();
                  })
              } else {
                Text(key)
                  .fontSize(24)
                  .fontColor(palette(this.isDark).textPrimary)
                  .width(64)
                  .height(64)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(palette(this.isDark).bgElevated)
                  .borderRadius($r('app.float.radius_circle'))
                  .onClick(() => {
                    this.onDigitKey(key);
                  })
              }
            }, (key: string) => 'key_' + key)
          }
        }, (row: string[], index: number) => 'row_' + index.toString())
      }
      .margin({ top: 16 })

      Blank()

      Text($r('app.string.lock_forgot'))
        .fontSize($r('app.float.font_aux'))
        .fontColor(palette(this.isDark).textSecondary)
        .padding(12)
        .onClick(() => {
          if (this.onForgot !== undefined) {
            this.onForgot();
          }
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(palette(this.isDark).bgPage)
    .alignItems(HorizontalAlign.Center)
  }

  /** 数字键输入 */
  private onDigitKey(digit: string): void {
    if (this.inputPin.length >= AppConstants.PIN_LENGTH) {
      return;
    }
    this.showError = false;
    this.inputPin = this.inputPin + digit;
    if (this.inputPin.length === AppConstants.PIN_LENGTH) {
      this.verify();
    }
  }

  /** 退格 */
  private onDeleteKey(): void {
    if (this.inputPin.length > 0) {
      this.inputPin = this.inputPin.substring(0, this.inputPin.length - 1);
      this.showError = false;
    }
  }

  /** 校验：通过回调交给宿主页，失败仅提示（不做锁定惩罚） */
  private async verify(): Promise<void> {
    if (this.onSubmit === undefined) {
      return;
    }
    const pin: string = this.inputPin;
    let passed: boolean = false;
    try {
      passed = await this.onSubmit(pin);
    } catch (e) {
      passed = false;
    }
    if (passed) {
      this.inputPin = '';
      return;
    }
    this.inputPin = '';
    this.showError = true;
    ToastUtil.showRes($r('app.string.lock_error'));
  }

  /** 圆点下标 */
  private dotIndexes(): number[] {
    const dots: number[] = [];
    for (let i = 0; i < AppConstants.PIN_LENGTH; i++) {
      dots.push(i);
    }
    return dots;
  }

  /** 键盘 3 行布局（第二行中间留空键位对齐） */
  private keyRows(): string[][] {
    return [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'del']
    ];
  }
}
