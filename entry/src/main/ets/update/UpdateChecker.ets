// UpdateChecker.ets —— 升级元数据检查（对应 Android update.UpdateChecker）。
//
// 拉取 update.json 并解析为 UpdateInfo；失败抛出异常由调用方决定如何提示。
// Android 用 HttpURLConnection + 单线程池，回调在拉取线程触发；鸿蒙 http.createHttp 本身异步，
// 故直接以 Promise 返回，无需线程池与切线程逻辑。
// Android 还实现了「Content-Type 字符集 → UTF-8 → GB18030 回退」的启发式解码：
// 鸿蒙 http 的 STRING 类型按响应字符集解码（服务端为 UTF-8），故不再重复该逻辑。

import { http } from '@kit.NetworkKit';
import { UpdateInfo, UpdateJson } from './UpdateInfo';
import { UpdateVersionPolicy } from './UpdateVersionPolicy';

/** 连接 / 读取超时（毫秒）：元数据为小 JSON，超时宜短，避免启动时长时间阻塞 */
const CONNECT_TIMEOUT_MS: number = 10000;
const READ_TIMEOUT_MS: number = 10000;

export class UpdateChecker {
  /**
   * 检查升级元数据。
   * @param metadataUrl update.json 地址
   * @returns 解析后的 UpdateInfo（已确保通过完整性校验）
   * @throws 网络失败 / HTTP 非 2xx / JSON 解析失败 / 元数据不完整
   */
  static async check(metadataUrl: string): Promise<UpdateInfo> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        usingCache: false,
      };
      const resp: http.HttpResponse = await request.request(metadataUrl, options);
      const code: number = resp.responseCode;
      if (code < 200 || code >= 300) {
        throw new Error(`检查更新失败，HTTP 状态码 ${code}`);
      }
      const text: string = `${resp.result}`;
      const info: UpdateInfo = UpdateInfo.fromJson(JSON.parse(text) as UpdateJson);
      if (!UpdateVersionPolicy.isValidMetadata(info)) {
        throw new Error('升级元数据不完整');
      }
      return info;
    } finally {
      request.destroy();
    }
  }
}
