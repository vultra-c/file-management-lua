/**
 * 提权桥接层（Vela 侧客户端）
 * ============================================================
 * 小米 Vela 轻应用受三重沙箱限制，`@system.file` 只能读写
 * `internal://files/` 沙箱目录，无法访问 /data、/system 等真实路径。
 *
 * Lua 表盘运行在 Vela OS 的 Lua 运行时里，拥有 io / os.execute /
 * lvgl.fs 能力，即「较高权限」。因此把 Lua 表盘当作特权后端：
 *
 *   1. Lua 表盘周期性把一次性令牌写进 fm_guard.json
 *   2. 轻应用读取令牌，写入 fm_request.json
 *   3. Lua 表盘 500ms 轮询取走请求、执行真实的文件操作、
 *      把结果写进 fm_result.json，并立即轮换令牌
 *   4. 轻应用轮询 fm_result.json，按 seq 匹配结果
 *
 * 令牌每次请求后都会轮换，且 Lua 侧会拒绝并删除令牌不匹配的请求，
 * 因此外部进程无法伪造请求（原理与 Shell++ 的 internal://files IPC 一致）。
 *
 * 所有方法统一返回 Promise，失败时 reject 一个带 code 的普通对象。
 */
import file from '@system.file'

export const URI = {
  guard: 'internal://files/fm_guard.json',
  request: 'internal://files/fm_request.json',
  result: 'internal://files/fm_result.json',
  heartbeat: 'internal://files/fm_heartbeat.json'
}

// 表盘 500ms 轮询一次，客户端 100ms 轮询结果；8s 未响应视为后端失联
const POLL_MS = 100
const DEFAULT_TIMEOUT_MS = 8000
const GUARD_RETRY = 3
const BACKEND_OFFLINE_MS = 12000

let seq = 0
let inflight = false
let lastResultSeq = 0
let heartbeatAt = 0
let heartbeatInfo = null
let backendOnline = false

function now() {
  return Date.now()
}

function readText(uri) {
  return new Promise(function (resolve, reject) {
    file.readText({
      uri: uri,
      success: function (r) {
        resolve(r && typeof r.text === 'string' ? r.text : '')
      },
      fail: function (msg, code) {
        reject({ code: 'read_fail:' + code, message: String(msg || '') })
      }
    })
  })
}

function writeText(uri, text) {
  return new Promise(function (resolve, reject) {
    file.writeText({
      uri: uri,
      text: text,
      append: false,
      success: function () {
        resolve(true)
      },
      fail: function (msg, code) {
        reject({ code: 'write_fail:' + code, message: String(msg || '') })
      }
    })
  })
}

function parseJson(text) {
  if (!text) return null
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

function sleep(ms) {
  return new Promise(function (resolve) {
    setTimeout(resolve, ms)
  })
}

/** 读取一次性令牌；表盘刚轮换时可能短暂读空，重试即可 */
async function readGuardToken() {
  let lastErr = null
  for (let i = 0; i < GUARD_RETRY; i++) {
    try {
      const guard = parseJson(await readText(URI.guard))
      if (guard && typeof guard.token === 'string' && guard.token) {
        return guard.token
      }
      lastErr = { code: 'guard_missing', message: '后端安全令牌未就绪' }
    } catch (e) {
      lastErr = e
    }
    await sleep(60)
  }
  throw lastErr || { code: 'guard_missing', message: '后端安全令牌未就绪' }
}

/** 轮询结果文件直到 seq 命中或超时 */
async function awaitResult(mySeq, timeoutMs) {
  const deadline = now() + timeoutMs
  while (now() < deadline) {
    let payload = null
    try {
      payload = parseJson(await readText(URI.result))
    } catch (e) {
      payload = null
    }
    if (payload && payload.seq === mySeq) {
      lastResultSeq = mySeq
      return payload
    }
    await sleep(POLL_MS)
  }
  throw { code: 'timeout', message: '请求超时，请确认 Lua 表盘正在运行' }
}

/** 刷新后端在线状态（读取表盘心跳） */
export async function refreshBackend() {
  let info = null
  try {
    info = parseJson(await readText(URI.heartbeat))
  } catch (e) {
    info = null
  }
  if (info && info.timestamp) {
    heartbeatInfo = info
    heartbeatAt = now()
    backendOnline = true
  } else if (backendOnline && now() - heartbeatAt > BACKEND_OFFLINE_MS) {
    backendOnline = false
  }
  return { online: backendOnline, info: heartbeatInfo }
}

export function backendState() {
  return {
    online: backendOnline && now() - heartbeatAt <= BACKEND_OFFLINE_MS,
    info: heartbeatInfo
  }
}

/**
 * 发送一次文件操作请求。
 * @param {string} action list/info/text/hex/write/mkdir/rename/copy/move/delete/search/image/storage
 * @param {Object} params 额外参数（path/dest/name/content/offset/limit/keyword ...）
 * @param {number} timeoutMs
 * @returns {Promise<Object>} 后端返回的 result.data
 */
export async function request(action, params, timeoutMs) {
  if (inflight) {
    throw { code: 'busy', message: '请求进行中，请稍候' }
  }
  inflight = true
  try {
    seq += 1
    const mySeq = seq
    const token = await readGuardToken()

    const req = {
      seq: mySeq,
      action: action,
      guard: token,
      timestamp: Math.floor(now() / 1000),
      path: '/'
    }
    if (params) {
      for (const key in params) {
        if (Object.prototype.hasOwnProperty.call(params, key) && params[key] !== undefined) {
          req[key] = params[key]
        }
      }
    }
    req.seq = mySeq
    req.guard = token

    await writeText(URI.request, JSON.stringify(req))
    const result = await awaitResult(mySeq, timeoutMs || DEFAULT_TIMEOUT_MS)

    if (result.status === 'error') {
      throw { code: result.code || 'backend_error', message: result.message || '文件操作失败' }
    }
    return result.data || {}
  } finally {
    inflight = false
  }
}

// ====== 语义化封装 ======

export function list(path) {
  return request('list', { path: path })
}

export function info(path) {
  return request('info', { path: path })
}

export function text(path, limit) {
  return request('text', { path: path, limit: limit || 4096 })
}

export function hex(path, offset, length) {
  return request('hex', { path: path, offset: offset || 0, length: length || 256 })
}

export function write(path, content) {
  return request('write', { path: path, content: content || '' })
}

export function mkdir(path) {
  return request('mkdir', { path: path })
}

export function rename(path, name) {
  return request('rename', { path: path, name: name })
}

export function copy(path, dest) {
  return request('copy', { path: path, dest: dest })
}

export function move(path, dest) {
  return request('move', { path: path, dest: dest })
}

export function remove(path) {
  return request('delete', { path: path })
}

export function search(root, keyword) {
  return request('search', { path: root, keyword: keyword })
}

export function image(path) {
  return request('image', { path: path })
}

export function storage() {
  return request('storage', { path: '/' })
}

export default {
  request: request,
  list: list,
  info: info,
  text: text,
  hex: hex,
  write: write,
  mkdir: mkdir,
  rename: rename,
  copy: copy,
  move: move,
  remove: remove,
  search: search,
  image: image,
  storage: storage,
  refreshBackend: refreshBackend,
  backendState: backendState
}
