/**
 * 模块职责：hilog 封装 + 耗时打点（架构 T01/T02）。
 * - 统一 domain/tag 前缀，release 包可通过 hilog 关闭 debug 级别
 * - timeStart/timeEnd 供 StatsService 等验证「统计页 < 300ms」指标（架构 4.7）
 * - errMsg：把任意抛出对象压成一行可读文本，避免调用处到处 JSON.stringify
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

/** 可导出的最小诊断日志单元，不记录账本明细或用户输入。 */
export class LogEntry {
  public time: number = 0;
  public level: string = '';
  public tag: string = '';
  public message: string = '';
}

export class LogUtil {
  /** 自定义 domain，方便在 hilog 工具中过滤本应用日志 */
  static readonly DOMAIN: number = 0x5B67;
  private static readonly DEFAULT_TAG: string = 'LifeLedger';
  private static readonly MAX_DIAGNOSTIC_ENTRIES: number = 200;
  private static entries: LogEntry[] = [];
  /** 耗时打点表（工具级缓存，不含业务状态） */
  private static readonly timers: Map<string, number> = new Map();

  public static d(tag: string, msg: string): void {
    LogUtil.append('DEBUG', tag, msg);
    hilog.debug(LogUtil.DOMAIN, LogUtil.tagOf(tag), '%{public}s', msg);
  }

  public static i(tag: string, msg: string): void {
    LogUtil.append('INFO', tag, msg);
    hilog.info(LogUtil.DOMAIN, LogUtil.tagOf(tag), '%{public}s', msg);
  }

  public static w(tag: string, msg: string): void {
    LogUtil.append('WARN', tag, msg);
    hilog.warn(LogUtil.DOMAIN, LogUtil.tagOf(tag), '%{public}s', msg);
  }

  public static e(tag: string, msg: string): void {
    LogUtil.append('ERROR', tag, msg);
    hilog.error(LogUtil.DOMAIN, LogUtil.tagOf(tag), '%{public}s', msg);
  }

  /**
   * 开始一次耗时打点。
   * @param key 打点标识，同一 key 重复调用会覆盖上一次起点
   */
  public static timeStart(key: string): void {
    LogUtil.timers.set(key, Date.now());
  }

  /**
   * 结束耗时打点并返回毫秒数（同时输出 info 日志）。
   * 未调用过 timeStart 时返回 -1。
   */
  public static timeEnd(key: string): number {
    const start: number | undefined = LogUtil.timers.get(key);
    if (start === undefined) {
      return -1;
    }
    const cost: number = Date.now() - start;
    LogUtil.timers.delete(key);
    LogUtil.i('Perf', key + ' cost ' + cost.toString() + 'ms');
    return cost;
  }

  /** 异常对象 → 可读文本 */
  public static errMsg(e: Object | undefined | null): string {
    if (e === undefined || e === null) {
      return 'unknown error';
    }
    const err: Object = e as Object;
    try {
      return JSON.stringify(err);
    } catch (ex) {
      return err.toString();
    }
  }

  /** 返回副本，诊断导出不能修改进程内日志。 */
  public static snapshot(): LogEntry[] {
    const copy: LogEntry[] = [];
    for (let i = 0; i < LogUtil.entries.length; i++) {
      const source: LogEntry = LogUtil.entries[i];
      const item: LogEntry = new LogEntry();
      item.time = source.time;
      item.level = source.level;
      item.tag = source.tag;
      // 原始异常文本可能包含文件路径或外部输入；诊断文件只保留事件元信息。
      item.message = '';
      copy.push(item);
    }
    return copy;
  }

  private static append(level: string, tag: string, message: string): void {
    const entry: LogEntry = new LogEntry();
    entry.time = Date.now();
    entry.level = level;
    entry.tag = LogUtil.sanitize(tag, 64);
    entry.message = LogUtil.sanitize(message, 240);
    LogUtil.entries.push(entry);
    if (LogUtil.entries.length > LogUtil.MAX_DIAGNOSTIC_ENTRIES) {
      LogUtil.entries.shift();
    }
  }

  /** 日志仅保留单行、定长技术信息，降低误带入用户输入的风险。 */
  private static sanitize(value: string, maxLength: number): string {
    const singleLine: string = value.split('\n').join(' ').split('\r').join(' ');
    return singleLine.length > maxLength ? singleLine.substring(0, maxLength) : singleLine;
  }

  /** 统一 tag 前缀，便于日志检索 */
  private static tagOf(tag: string): string {
    return LogUtil.DEFAULT_TAG + '/' + tag;
  }
}
