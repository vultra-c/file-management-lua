/**
 * 展示层格式化工具：文件大小、日期、路径裁剪。
 * 手环屏幕只有 336x480，所有文本都要提前截断，避免撑破卡片。
 */

/** 字节数 -> 人类可读 */
export function formatSize(bytes) {
  const n = Number(bytes)
  if (!isFinite(n) || n < 0) return '-'
  if (n < 1024) return n + ' B'
  if (n < 1024 * 1024) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + ' KB'
  return (n / (1024 * 1024)).toFixed(n < 10 * 1024 * 1024 ? 1 : 0) + ' MB'
}

/** Unix 秒 -> MM-DD HH:MM */
export function formatTime(unix) {
  const n = Number(unix)
  if (!isFinite(n) || n <= 0) return '-'
  const d = new Date(n * 1000)
  const p = function (v) {
    return v < 10 ? '0' + v : '' + v
  }
  return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes())
}

/** 取父目录，根目录返回 '' */
export function parentOf(path) {
  const p = normalize(path)
  if (p === '/') return ''
  const idx = p.lastIndexOf('/')
  if (idx <= 0) return '/'
  return p.slice(0, idx)
}

/** 拼接路径，自动处理根目录与尾部斜杠 */
export function join(base, name) {
  const b = normalize(base)
  const n = String(name || '')
  if (b === '/') return '/' + n
  return b + '/' + n
}

/** 规范化路径：补前导 /、去掉尾部 /（根目录除外） */
export function normalize(path) {
  let p = String(path || '/')
  if (p === '') p = '/'
  if (p.charAt(0) !== '/') p = '/' + p
  while (p.length > 1 && p.charAt(p.length - 1) === '/') p = p.slice(0, -1)
  return p
}

/** 路径末段名称 */
export function basename(path) {
  const p = normalize(path)
  if (p === '/') return '/'
  return p.slice(p.lastIndexOf('/') + 1)
}

/** 列表副标题里显示的短路径：/data/quickapp/…/x.json */
export function shortPath(path) {
  const p = normalize(path)
  if (p.length <= 26) return p
  return '…' + p.slice(p.length - 25)
}

/** 扩展名（小写，不含点），无扩展名返回 '' */
export function extname(name) {
  const s = String(name || '')
  const idx = s.lastIndexOf('.')
  if (idx <= 0 || idx === s.length - 1) return ''
  return s.slice(idx + 1).toLowerCase()
}

/** 依据扩展名判断文件类型，决定列表图标与详情页默认动作 */
export function fileKind(name) {
  const e = extname(name)
  if (['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'].indexOf(e) >= 0) return 'image'
  if (['txt', 'md', 'json', 'log', 'lua', 'xml', 'csv', 'ini', 'conf', 'cfg', 'js', 'css', 'yml', 'yaml', 'sh', 'prop'].indexOf(e) >= 0) {
    return 'text'
  }
  return 'binary'
}

/** 文件名合法性校验（用于新建文件夹 / 重命名） */
export function isValidName(name) {
  const s = String(name || '').trim()
  if (!s || s.length > 60) return false
  return s.indexOf('/') < 0 && s.indexOf('\\') < 0 && s !== '.' && s !== '..'
}

/** 生成不重名的新名字：a.txt -> a(1).txt */
export function uniqueName(name, taken) {
  const s = String(name || '')
  if (!taken || !taken[s]) return s
  const idx = s.lastIndexOf('.')
  const stem = idx > 0 ? s.slice(0, idx) : s
  const suffix = idx > 0 ? s.slice(idx) : ''
  for (let i = 1; i < 200; i++) {
    const candidate = stem + '(' + i + ')' + suffix
    if (!taken[candidate]) return candidate
  }
  return stem + '-' + Date.now() + suffix
}
