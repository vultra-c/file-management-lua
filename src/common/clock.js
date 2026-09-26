/**
 * 闪念小抄 - 全局单例时钟
 * 所有页面共享一个 setInterval，避免 5 个定时器同时运行
 * 每秒检测一次，但仅在时间字符串实际变化时才通知回调（每分钟最多一次渲染）
 */

let _time = ''
let _listeners = []
let _timer = null

function _tick() {
  const now = new Date()
  const h = String(now.getHours()).padStart(2, '0')
  const m = String(now.getMinutes()).padStart(2, '0')
  const t = h + ':' + m
  if (t === _time) return                 // 分钟未变，跳过通知
  _time = t
  _listeners.forEach(function (fn) { fn(_time) })
}

function _start() {
  if (_timer) return
  _tick()
  _timer = setInterval(_tick, 1000)
}

function _stop() {
  if (_timer) {
    clearInterval(_timer)
    _timer = null
  }
}

/**
 * 注册时间变化回调
 * @param {Function} fn - 回调函数，参数 `time` 为 "HH:MM" 格式
 */
export function onTimeChange(fn) {
  _listeners.push(fn)
  if (_time) fn(_time)                 // 立即回放当前时间
  _start()
}

/**
 * 取消回调
 * @param {Function} fn - 之前注册的回调
 */
export function offTimeChange(fn) {
  _listeners = _listeners.filter(function (f) { return f !== fn })
  if (_listeners.length === 0) _stop()
}
