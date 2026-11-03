/**
 * 模块职责：应用入口 Ability（架构 2.4 / 5.1 / T01）。
 * 核心职责（按生命周期顺序）：
 * ① onCreate：SettingsService（Preferences）初始化 —— 必须先于 RDB，
 *    隐私同意状态在数据库初始化之前就要能读到（架构 1.3 关键顺序约束）；
 *    ThemeStore 初始化：读主题模式并应用 colorMode；
 * ② onWindowStageCreate：隐私弹窗前置路由 —— 依据 Preferences 的同意状态决定
 *    loadContent('pages/PrivacyPage') 还是 'pages/Index'；
 *    未同意时数据库完全不初始化，杜绝「先渲染主界面再补弹窗」的绕过口子；
 * ③ onForeground / onBackground：应用锁 30 秒超时重锁（AppStorage 'locked'）。
 *    重锁前先把 router 页面栈收敛回 Index 根页——PinLockOverlay 只挂在 Index
 *    根 Stack 内，若顶层停留在子页面则锁层挡不住账目内容（安全修复 S2）；
 * ④ onConfigurationUpdate：系统深浅色变化时同步主题。
 */
import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { router, Router, window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppConstants, AppStorageKeys } from '../constants/AppConstants';
import { RouteConstants } from '../constants/RouteConstants';
import { SettingsService } from '../service/SettingsService';
import { DatabaseManager } from '../service/DatabaseManager';
import { AppLockService } from '../service/AppLockService';
import { ThemeStore } from '../viewmodel/ThemeStore';
import { WindowUtil } from '../utils/WindowUtil';
import { LogUtil } from '../utils/LogUtil';

export default class EntryAbility extends UIAbility {
  private static readonly TAG: string = 'EntryAbility';
  /** 最近一次切后台的时间戳（应用锁超时判断） */
  private lastBackgroundAt: number = 0;
  /** 窗口句柄：重锁前收敛页面栈时需要取主窗 UIContext 的 router */
  private windowStage?: window.WindowStage;

  /** ① 创建：初始化 Preferences 与主题（顺序不可颠倒） */
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    LogUtil.i(EntryAbility.TAG, 'onCreate');
    // AppStorage 全局键预置，保证首帧前全部就绪
    AppStorage.setOrCreate(AppStorageKeys.DATA_VERSION, 0);
    AppStorage.setOrCreate(AppStorageKeys.LOCKED, false);
    AppStorage.setOrCreate(AppStorageKeys.IS_DARK, false);
    AppStorage.setOrCreate(AppStorageKeys.ACTIVE_TAB, 0);
    // Preferences 先行（不依赖 RDB）
    SettingsService.init(this.context);
    // 主题随后：读 themeMode → setColorMode → 写 isDark
    ThemeStore.init(this.context);
  }

  /** ② 窗口就绪：隐私前置路由 */
  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    LogUtil.i(EntryAbility.TAG, 'onWindowStageCreate');
    this.windowStage = windowStage;
    await WindowUtil.setImmersive(windowStage);

    // 应用锁冷启动判定：已开启应用锁时直接进入锁定态（PinLockOverlay 覆盖）
    if (SettingsService.isLockEnabled() && SettingsService.hasPin()) {
      AppStorage.setOrCreate(AppStorageKeys.LOCKED, true);
    }

    const agreed: boolean = SettingsService.isPrivacyAgreed();
    if (!agreed) {
      // 首次启动：只加载隐私页。数据库初始化延后到 PrivacyPage「同意并继续」时执行，
      // 保证不同意退出前不产生任何数据落盘
      try {
        await windowStage.loadContent(RouteConstants.PRIVACY);
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        hilog.error(0x5B67, 'EntryAbility', 'loadContent privacy failed: %{public}s', err.message);
      }
      return;
    }

    // 已同意：先初始化数据库（建表/迁移/预置），成功后再进主界面
    try {
      await DatabaseManager.getInstance().init(this.context);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogUtil.e(EntryAbility.TAG, 'database init failed: ' + err.message);
      // 初始化失败仍进入主界面，由页面自身的 ErrorState 呈现重试入口，避免白屏
    }
    try {
      await windowStage.loadContent(RouteConstants.INDEX);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      hilog.error(0x5B67, 'EntryAbility', 'loadContent index failed: %{public}s', err.message);
    }
  }

  onWindowStageDestroy(): void {
    LogUtil.i(EntryAbility.TAG, 'onWindowStageDestroy');
    this.windowStage = undefined;
  }

  /** ④ 切前台：超过 LOCK_TIMEOUT_MS 则先收敛页面栈再重锁 */
  onForeground(): void {
    LogUtil.d(EntryAbility.TAG, 'onForeground');
    // 判定口径与冷启动一致（isLockEnabled && hasPin），避免开关开着但无 PIN 时误锁
    if (!AppLockService.isEnabled()) {
      return;
    }
    if (this.lastBackgroundAt <= 0) {
      return;
    }
    const awayMs: number = Date.now() - this.lastBackgroundAt;
    if (awayMs > AppConstants.LOCK_TIMEOUT_MS) {
      // 先回 Index 根页：PinLockOverlay 只挂在 Index 根 Stack 内，
      // 顶层停在子页面时锁层盖不住账目内容；导航失败也必须置锁（安全优先）
      try {
        this.popPageStackToRoot();
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        LogUtil.e(EntryAbility.TAG, 'pop page stack failed: ' + err.message);
      }
      AppLockService.lock();
    }
  }

  /**
   * 收敛页面栈：循环 back 直到只剩 Index 根页（栈长 <= 1）。
   * router 依赖 UI 上下文，Ability 内优先走 windowStage 主窗的 UIContext.router，
   * 窗口句柄缺失时退回模块级 router；栈长用 getLength()（返回字符串，上限 32），
   * 循环加守卫上限，防止 back 失效时死循环。
   */
  private popPageStackToRoot(): void {
    const GUARD_MAX: number = 32;
    let guard: number = 0;
    const stage: window.WindowStage | undefined = this.windowStage;
    if (stage !== undefined) {
      const uiRouter: Router = stage.getMainWindowSync().getUIContext().getRouter();
      while (parseInt(uiRouter.getLength(), 10) > 1 && guard < GUARD_MAX) {
        uiRouter.back();
        guard++;
      }
      return;
    }
    while (parseInt(router.getLength(), 10) > 1 && guard < GUARD_MAX) {
      router.back();
      guard++;
    }
  }

  /** ③ 切后台：记录时间戳供 onForeground 判定 */
  onBackground(): void {
    LogUtil.d(EntryAbility.TAG, 'onBackground');
    this.lastBackgroundAt = Date.now();
  }

  /** 系统配置变化：深浅色跟随系统时重算主题 */
  onConfigurationUpdate(newConfig: Configuration): void {
    ThemeStore.onConfigurationUpdate(newConfig);
  }

  onDestroy(): void {
    LogUtil.i(EntryAbility.TAG, 'onDestroy');
    DatabaseManager.getInstance().close();
  }
}
