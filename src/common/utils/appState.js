/**
 * 文件管理 - 跨页面共享状态
 *
 * Vela 没有可靠的全局对象（部分固件的 globalThis 行为不一致），
 * 这里用模块缓存 + this.$app.$def 暴露的方式在页面间传递状态。
 */

const state = {
  // 页面返回动画标记：子页面 router.back() 前由 pageAnim.markBack() 置位，
  // 父页面 onShow() 中 pageAnim.playReturn() 消费
  returnAnim: '',

  // 后端（Lua 表盘）在线状态与心跳信息
  backendOnline: false,
  backendInfo: null,

  // 上一次成功浏览的目录，首页「继续浏览」用
  lastPath: '/',

  // 剪贴板：选中的源文件 + 待执行的操作（copy / move）
  clipboardSource: '',
  clipboardMode: '',

  // 列表排序：0 名称 / 1 大小 / 2 时间
  sortIndex: 0,

  // 删除/移动成功后回到列表需要强制刷新
  needRefreshList: false,

  // 待粘贴动作：fileInfo 页发起 -> files 页执行
  pendingPaste: null
}

export function getState() {
  return state
}

export function setBackend(online, info) {
  state.backendOnline = !!online
  state.backendInfo = info || null
}

export function setLastPath(path) {
  state.lastPath = path || '/'
}

export function setClipboard(source, mode) {
  state.clipboardSource = source || ''
  state.clipboardMode = mode || ''
}

export function clearClipboard() {
  state.clipboardSource = ''
  state.clipboardMode = ''
  state.pendingPaste = null
}

export function requestRefresh() {
  state.needRefreshList = true
}

export default state
