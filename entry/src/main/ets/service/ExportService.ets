/**
 * 模块职责：CSV 导出服务（架构 T03 / 6.5 时序 ⑤，v1.1 R8 三态化）。
 * - buildCsv：纯字符串拼装，UTF-8 BOM（Excel 兼容，F-6.1 硬要求），字段转义
 * - exportViaPicker：沙箱临时文件 → DocumentViewPicker.save（免权限）→ 拷贝 → 清理
 * - 三态语义（架构 R8）：saved / cancelled / failed + failurePoint；
 *   用户取消 = save 返回空数组（不再走 catch 混淆）；异常 = failed + LogUtil.e 留痕
 * - CSV 字段顺序（F-6.2）：日期,时间,类型,金额,分类,一级分类,账户,备注,账本
 *   金额规则：支出带负号 / 收入带正号，单位元两位小数（只经 MoneyUtil）
 * 性能：分类/账户名称一次性装载为 Map，避免逐行回查数据库。
 */
import { picker } from '@kit.CoreFileKit';
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { DatabaseManager } from './DatabaseManager';
import { Tables } from './SchemaConstants';
import { Transaction } from '../model/Transaction';
import { Account } from '../model/Account';
import { Category } from '../model/Category';
import { CategoryService } from './CategoryService';
import { AccountService } from './AccountService';
import { LedgerService } from './LedgerService';
import { SettingsService } from './SettingsService';
import { TxType } from '../constants/AppConstants';
import { DateUtil } from '../utils/DateUtil';
import { MoneyUtil } from '../utils/MoneyUtil';
import { FileUtil } from '../utils/FileUtil';
import { LogUtil } from '../utils/LogUtil';

/** 导出状态三态（架构 R8）：数据结构上可区分，不靠布尔值凑 */
export enum ExportStatus {
  SAVED = 'saved',
  CANCELLED = 'cancelled',
  FAILED = 'failed'
}

/** 导出结果（ViewModel 转换为 Result 后供页面提示；备份导出复用同一结构） */
export class ExportOutcome {
  /** 结果状态：saved=已保存 / cancelled=用户取消（静默）/ failed=失败 */
  public status: ExportStatus = ExportStatus.CANCELLED;
  /** 失败点：'temp_file' | 'picker' | 'copy'；成功/取消时为空串 */
  public failurePoint: string = '';
  /** 保存目标 URI */
  public uri: string = '';
  /** 导出条数 */
  public count: number = 0;
  /** 失败详情：BusinessError.code + message，供页面 AlertDialog 精确展示 */
  public detail: string = '';
}

/** CSV 生成结果：文本 + 实际记录条数（字段内可含换行，按行 split 计数会失真） */
export class CsvBuildResult {
  /** CSV 文本（含表头，不含 BOM） */
  public csv: string = '';
  /** 实际导出的流水条数 */
  public count: number = 0;
}

export class ExportService {
  private static readonly TAG: string = 'ExportService';
  private static readonly CSV_BOM: Uint8Array = new Uint8Array([0xEF, 0xBB, 0xBF]);

  /**
   * 生成 CSV 文本与实际条数（含表头；BOM 由写文件阶段前置，文本本身不带）。
   * @param monthKey 'yyyy-MM' 或 'ALL'（全部）
   */
  public static async buildCsv(monthKey: string): Promise<CsvBuildResult> {
    const store: relationalStore.RdbStore = DatabaseManager.getInstance().getStore();
    // 导出范围 = 当前账本（F-2.6 账本隔离在导出链路的体现）
    const ledgerId: number = SettingsService.getCurrentLedgerId();
    const currentLedger = await LedgerService.resolveCurrent();
    let resultSet: relationalStore.ResultSet;
    if (monthKey === 'ALL') {
      resultSet = await store.querySql(
        'SELECT * FROM ' + Tables.TRANSACTION + ' WHERE ledger_id = ? ORDER BY tx_date ASC',
        [ledgerId]);
    } else {
      const start: number = DateUtil.monthKeyToStart(monthKey);
      const end: number = DateUtil.endOfMonth(start);
      resultSet = await store.querySql(
        'SELECT * FROM ' + Tables.TRANSACTION +
        ' WHERE ledger_id = ? AND tx_date >= ? AND tx_date < ? ORDER BY tx_date ASC',
        [ledgerId, start, end]);
    }
    const txList: Transaction[] = ExportService.readTx(resultSet);
    const result: CsvBuildResult = new CsvBuildResult();
    result.csv = await ExportService.buildCsvFromList(txList, currentLedger.name);
    result.count = txList.length;
    return result;
  }

  /** 由流水列表拼 CSV（名称映射一次装载，1 万条下避免逐行回查） */
  public static async buildCsvFromList(txList: Transaction[], ledgerName: string): Promise<string> {
    const categoryMap: Map<number, Category> = await CategoryService.loadNameMap();
    const accounts: Account[] = await AccountService.listAll(true);
    const accountNameById: Map<number, string> = new Map();
    for (let i = 0; i < accounts.length; i++) {
      accountNameById.set(accounts[i].id, accounts[i].name);
    }

    const lines: string[] = [];
    lines.push('日期,时间,类型,金额,分类,一级分类,账户,备注,账本');
    for (let i = 0; i < txList.length; i++) {
      const tx: Transaction = txList[i];
      // 金额：数据库恒为正整数分；支出带负号、收入带正号，两位小数
      let fen: number = tx.amount;
      if (tx.type === TxType.EXPENSE) {
        fen = -tx.amount;
      }
      const amountText: string = MoneyUtil.formatNoGroup(fen, tx.type === TxType.INCOME);
      let categoryName: string = '';
      if (tx.type !== TxType.TRANSFER && tx.categoryId > 0) {
        const category: Category | undefined = categoryMap.get(tx.categoryId);
        if (category !== undefined) {
          categoryName = category.name;
        }
      }
      let accountName: string = '';
      const accountNameValue: string | undefined = accountNameById.get(tx.accountId);
      if (accountNameValue !== undefined) {
        accountName = accountNameValue;
      }
      const fields: string[] = [
        DateUtil.formatDate(tx.txDate),
        DateUtil.formatTime(tx.txDate),
        ExportService.typeText(tx.type),
        // 金额列是 MoneyUtil 格式化产物（支出带负号），不参与公式注入防护
        amountText,
        // 以下 5 列均为用户可控文本（备份恢复可引入他人文件），需防 CSV 公式注入
        ExportService.guardCsvText(categoryName),
        ExportService.guardCsvText(categoryName),
        ExportService.guardCsvText(accountName),
        ExportService.guardCsvText(tx.note),
        ExportService.guardCsvText(ledgerName)
      ];
      lines.push(ExportService.joinRow(fields));
    }
    return lines.join('\r\n');
  }

  /**
   * 完整导出链路（架构 1.3 三态落地）：
   * 数据 → CSV → 沙箱临时文件（失败 failurePoint='temp_file'）
   *   → 系统保存面板（空数组=cancelled；异常=failed/'picker'）
   *   → 拷贝（失败=failed/'copy'）→ 清理。
   * 全程零权限（DocumentViewPicker 由系统授予临时写权限）。
   */
  public static async exportViaPicker(context: common.UIAbilityContext, monthKey: string): Promise<ExportOutcome> {
    LogUtil.timeStart(ExportService.TAG + '/exportViaPicker');
    const outcome: ExportOutcome = new ExportOutcome();

    // 数据生成阶段（查库 + 拼 CSV）单独捕获：它不在后续 try 内，
    // 一旦抛错会冒泡成泛化失败且无 failurePoint，无法定位卡在哪一步。
    let csv: string = '';
    try {
      const built: CsvBuildResult = await ExportService.buildCsv(monthKey);
      csv = built.csv;
      // 条数取实际记录数，字段内换行不再污染统计
      outcome.count = built.count;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogUtil.e(ExportService.TAG, 'export failed at build: ' +
        (err.message ? err.message : (e as Error).message));
      outcome.status = ExportStatus.FAILED;
      outcome.failurePoint = 'build';
      outcome.detail = (err.code !== undefined && err.code !== null ? String(err.code) : '?') + ': ' + err.message;
      return outcome;
    }
    const fileName: string = monthKey === 'ALL' ? '轻账本_全部.csv' : '轻账本_' + monthKey + '.csv';

    // 先写沙箱（磁盘不足可提前暴露），拷贝是原子性更好的操作（架构 6.5 要点）
    const sandboxFile: string = FileUtil.sandboxPath(context, 'export', fileName);
    const encoder: util.TextEncoder = new util.TextEncoder();
    const body: Uint8Array = encoder.encodeInto(csv);
    const bytes: Uint8Array = new Uint8Array(ExportService.CSV_BOM.length + body.length);
    bytes.set(ExportService.CSV_BOM, 0);
    bytes.set(body, ExportService.CSV_BOM.length);
    try {
      FileUtil.writeBytes(context, sandboxFile, bytes);
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      LogUtil.e(ExportService.TAG, 'export failed at temp_file: ' + err.message);
      outcome.status = ExportStatus.FAILED;
      outcome.failurePoint = 'temp_file';
      outcome.detail = (err.code !== undefined && err.code !== null ? String(err.code) : '?') + ': ' + err.message;
      return outcome;
    }

    try {
      const pickerInstance: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const saveOptions: picker.DocumentSaveOptions = {
        newFileNames: [fileName],
        fileSuffixChoices: ['.csv']
      };
      const uris: Array<string> = await pickerInstance.save(saveOptions);
      if (uris.length === 0) {
        // 用户取消（返回空数组）：显式三态 cancelled，静默无 Toast（架构 R8）
        LogUtil.d(ExportService.TAG, 'export cancelled by user');
        outcome.status = ExportStatus.CANCELLED;
        return outcome;
      }
      try {
        FileUtil.copyToUri(context, sandboxFile, uris[0]);
      } catch (e) {
        const err: BusinessError = e as BusinessError;
        LogUtil.e(ExportService.TAG, 'export failed at copy: ' + err.message);
        outcome.status = ExportStatus.FAILED;
        outcome.failurePoint = 'copy';
        outcome.detail = (err.code !== undefined && err.code !== null ? String(err.code) : '?') + ': ' + err.message;
        return outcome;
      }
      outcome.status = ExportStatus.SAVED;
      outcome.uri = uris[0];
    } catch (e) {
      // save 抛非取消异常：failed + 留痕，不得再静默成取消（架构 R8）
      const err: BusinessError = e as BusinessError;
      LogUtil.e(ExportService.TAG, 'export failed at picker: ' + err.message);
      outcome.status = ExportStatus.FAILED;
      outcome.failurePoint = 'picker';
      outcome.detail = (err.code !== undefined && err.code !== null ? String(err.code) : '?') + ': ' + err.message;
      return outcome;
    } finally {
      // 临时文件无论成败都清理，避免沙箱残留
      FileUtil.deleteFile(sandboxFile);
      LogUtil.timeEnd(ExportService.TAG + '/exportViaPicker');
    }
    return outcome;
  }

  /**
   * CSV 公式注入防护：用户可控文本以 = + - @ Tab 回车 开头时前置单引号，
   * 使 Excel/WPS 将其按纯文本显示而非执行公式（业界公认做法）。
   * 仅用于备注/分类名/账户名/账本名；金额列由 MoneyUtil 产出，不走此防护。
   */
  private static guardCsvText(value: string): string {
    if (value.length === 0) {
      return value;
    }
    const first: string = value.charAt(0);
    if (first === '=' || first === '+' || first === '-' || first === '@' ||
      first === '\t' || first === '\r') {
      return "'" + value;
    }
    return value;
  }

  /** 行拼装：含逗号/引号/换行/回车的字段加引号并转义内部引号（RFC4180） */
  private static joinRow(fields: string[]): string {
    const escaped: string[] = [];
    for (let i = 0; i < fields.length; i++) {
      let value: string = fields[i];
      if (value.indexOf(',') >= 0 || value.indexOf('"') >= 0 ||
        value.indexOf('\n') >= 0 || value.indexOf('\r') >= 0) {
        value = '"' + value.split('"').join('""') + '"';
      }
      escaped.push(value);
    }
    return escaped.join(',');
  }

  /** 类型文案（导出列：支出/收入/转账；与 string.json 分类口径一致） */
  private static typeText(type: number): string {
    if (type === TxType.EXPENSE) {
      return '支出';
    }
    if (type === TxType.INCOME) {
      return '收入';
    }
    return '转账';
  }

  /** 读取整个游标并统一 close */
  private static readTx(resultSet: relationalStore.ResultSet): Transaction[] {
    const list: Transaction[] = [];
    try {
      while (resultSet.goToNextRow()) {
        list.push(Transaction.fromRow(resultSet));
      }
    } finally {
      resultSet.close();
    }
    return list;
  }
}
