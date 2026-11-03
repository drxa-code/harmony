# 轻账本（LifeLedger）项目长期备忘

## 项目定位
- HarmonyOS NEXT 原生 ArkTS 记账 App「轻账本」，纯本地、零第三方依赖；代码 E:\workset\harmony
- 权限口径（v1.1 起）：「默认零权限，唯一例外记账提醒 PUBLISH_AGENT_REMINDER（system_grant）」；导出/备份一律走系统 Picker 免权限
- 上架合规红线：禁「理财」类金融敏感词（收入分类已改名「利息」）；隐私政策禁「只申请必要权限」话术；纯本地可免 APP 备案

## 工程铁律（团队 SOP 沉淀）
- 分层：Service 只 throw → ViewModel 收 Result → Page 三态（Loading/Error/Content）+ palette(isDark) 主题
- 金额恒 INTEGER 分（÷100 只在 MoneyUtil）、时间恒 UTC 毫秒（换算只在 DateUtil）
- 多币种（2026-09-10）：库中恒存基础货币 ¥ 分；展示一律 MoneyUtil.display()，录入一律 displayFenToBaseFen 换回基础货币；外币汇率手动维护（设置页可改）；CSV 导出保持基础货币原值
- 多表写必须 DatabaseManager.runInTransaction；写库/切账本/切货币/改汇率/恢复后 DataBus.bump()（service 层触发）
- 页面刷新模式：@StorageLink(DATA_VERSION) @Watch 挂声明行（贴方法上无效）；长加载页用 loadSeq 序号令牌防乱序响应；loading 初始值 true 不得与防重入守卫同用（死锁）
- @Builder 禁止传响应式对象/布尔参数（按值传参冻结 UI），必须无参引用 this.xxx!
- RouteConstants 与 main_pages.json 严格同步；string.json base/zh_CN 成对增删（en_US 仅删不补）
- ArkTS：禁 any、全显式类型、禁解构、throw 只能 new Error(msg)

## 构建环境（本机已打通）
- DevEco Studio 在 E:\DevEco Studio，hvigor 构建四要素：DEVECO_SDK_HOME + PATH 里 jbr 最前 + NODE_HOME + hvigorw.bat --no-daemon（详细配方见 2026-09-09 日志 19:00 条目）
- hvigor-config.json5 dependencies 必须是空对象 {}（不能删键、不能写具体版本）
- targetSdkVersion 格式必须 x.y.z(api) 如 "6.0.0(20)"
- 沙箱会拦截批量删除（SAFE_DELETE_BULK_CONFIRM_REQUIRED）→ **勿跑 hvigorw clean**（GenerateLoaderJson 的批量删除被拦 → CompileArkTS 跑不到）；增量 assembleHap 现 GenerateLoaderJson 已 UP-TO-DATE 可跳过，能正常跑到 CompileArkTS 验证编译
- **Bash 工具里环境变量转义**：路径含空格（E:/DevEco Studio）必须用反斜杠空格 `E:/DevEco\ Studio`，**不能**用双引号（JSON 传输会把 `"E:/DevEco Studio/..."` 拆坏成 `$E:...`）；hvigorw 用字面量 `"E:/DevEco Studio/tools/hvigor/bin/hvigorw.bat"` 整体引号即可
- **PackageHap 在沙箱原生崩**（exit 3221226505，app_packing_tool.jar 子进程被拦），与代码无关；手动跑同一条 app_packing_tool.jar 命令即出 HAP（entry-default-unsigned.hap / signed 均成功）
- **本 SDK 的 @kit.ArkUI 未导出 IDataSource / DataChangeListener**（会报 10505001 has no exported member）→ LazyForEach 数据源用「本地 interface + 结构体」满足结构类型，不要 import 框架类型；LazyDataSource 已落地此写法（entry/src/main/ets/utils/LazyDataSource.ets）

## v1.1 已交付（2026-09-09）
- 多账本（LedgerManagePage + LedgerSwitcher bindSheet 弹层）、备份恢复（BackupService JSON 五项校验+单事务整库替换）、记账提醒（ReminderService+ReminderSettingPage）、导出三态修复；意见反馈入口已删除
- 文档：docs/PRD-v1.1.md（F-10.x）、docs/ARCHITECTURE-v1.1.md（R1~R12）
- 发版前待办：真机冒烟（备份→清库→恢复→条数比对、通知关闭时提醒表现）

## 关键项目背景（2026-09-10 确认）
- **用户尚未在 AppGallery Connect 创建「轻账本」项目** → 任何华为开放能力（含代理提醒）都没有配额
- 因此「每日记账提醒」在调试/未上架阶段必然 1700002（代理提醒配额=0），此为平台限制、非代码 bug
- 代码侧已做到：publish 前 cancelCurrent（先 cancelAllReminders 再按 id cancel）+ addSlot 注册渠道 + 固定 notificationId=1001 + 1700002 专属中文提示
- 提醒功能可正常工作的前置条件：去 AGC 开项目并申请「代理提醒」开放能力，审核通过后重签安装

## 发布签名与上架（2026-09-10 收尾）
- 根 `build-profile.json5` 已预置 `release` 发布签名占位模板（material 为 `REPLACE_WITH_*` 占位，待填 AGC 正式证书）；`release` 产品已建并接入 entry 模块。debug 用 `default`（自动调试签名）不受影响
- 上架 SOP：`docs/上架打包SOP.md`（发布签名配置 / 构建命令 / 版本号规则 / 合规红线 / 提审清单 / 多环境对照）
- 最终签名出 .app 必须在 DevEco IDE 完成（沙箱 PackageHap 被拦），命令行仅验证编译
