/**
 * 页面转场动画工具（复刻小米固件 SCR_LOAD_ANIM 屏幕转场，依据 ai-use 仓库逆向资料）
 *
 * - 压栈进入 OVER_LEFT ：translateX(40px) -> 0，opacity 0 -> 1，320ms cubic-bezier(0.2,0,0,1)
 * - 返回     OVER_RIGHT：translateX(-40px) -> 0，opacity 0 -> 1，320ms cubic-bezier(0.2,0,0,1)
 * - 对话框   FADE_IN   ：opacity 0 -> 1，240ms（固件 fade 档，用于删除确认/新建文件夹等弹层页）
 * - 列表按下反馈       ：背景色加深，180ms（固件 fast 档，配合 LVGL 对象动画手感）
 * - 文件夹内容入场     ：打开文件夹后列表项 opacity 淡入，280ms/项（固件 lv 档），40ms 步进错峰
 *
 * 用法（每个 .ux 页面）：
 *   1. import pageAnim from '../../common/utils/pageAnim.js'
 *   2. private 中加：animStyle: pageAnim.enterStyle
 *   3. 根节点 style 绑定：style="flex-direction: column;{{animStyle}}"
 *   4. 所有 router.back() 之前调用 pageAnim.markBack()
 *   5. onShow() 开头调用 pageAnim.playReturn(this)
 *
 * 列表项入场（subfolder 等列表页，打开文件夹时内容错峰淡入）：
 *   1. 数据就绪后：if (pageAnim.markReveal(this, items)) { pageAnim.playReveal(this, items) }
 *   2. 模板 list-item 上绑定：class="item {{$item.enter && !$item.revealed ? 'item--enter' : ''}} {{$item.enter && $item.revealed ? 'item--shown' : ''}}"
 *   3. style.css 的 .item 已带 opacity transition（280ms），无需额外样式
 *
 * 说明：Vela 的 @keyframes 结束后元素回落到基础态（即 100% 帧），
 * 因此动画结束后把 animStyle 清空即可，不会产生回跳；清空后 animation-name 消失，
 * 下次返回时从 '' 切到 vela-page-in-right 才能重新触发动画。
 * 另外 Vela transition 不支持 transform，所以按下/入场反馈统一用 opacity / background-color。
 */
import appState from './appState.js'

var ANIM_ENTER = 'animation-name: vela-page-in-left; animation-duration: 320ms; animation-timing-function: cubic-bezier(0.2, 0, 0, 1);'
var ANIM_RIGHT = 'animation-name: vela-page-in-right; animation-duration: 320ms; animation-timing-function: cubic-bezier(0.2, 0, 0, 1);'
// 对话框淡入（固件 FADE_IN，240ms fade 档）
var ANIM_FADE = 'animation-name: vela-page-fade; animation-duration: 240ms; animation-timing-function: cubic-bezier(0.2, 0, 0, 1);'
// 动画结束后延迟清空 animStyle（略大于动画时长）
var CLEANUP_MS = 380

// 列表行按下到跳转的延迟：让按下反馈（180ms 背景过渡）先被看到，再进入新页面
var PRESS_MS = 120
// 文件夹内容入场：单项淡入 280ms（固件 lv 档），每项错峰 40ms，首屏参与错峰的项数
var REVEAL_ITEM_MS = 280
var REVEAL_STEP_MS = 40
var REVEAL_FIRST = 8

export default {
  enterStyle: ANIM_ENTER,
  rightStyle: ANIM_RIGHT,
  fadeStyle: ANIM_FADE,
  pressMs: PRESS_MS,

  // 在 router.back() 之前调用，标记即将返回上一层
  markBack: function() {
    appState.returnAnim = 'right'
  },

  // 在页面 onShow() 开头调用：若刚被返回（子页面 markBack 过），播放 OVER_RIGHT 进入动画
  playReturn: function(page) {
    if (appState.returnAnim !== 'right') {
      return
    }
    appState.returnAnim = ''
    page.animStyle = ANIM_RIGHT
    setTimeout(function() {
      if (page.$valid) {
        page.animStyle = ''
      }
    }, CLEANUP_MS)
  },

  /**
   * 标记列表项是否需要错峰入场（仅页面实例第一次加载时生效）。
   * 返回 true 表示本次需要入场动画，随后应调用 playReveal。
   * 之后 onShow 重进页面时返回 false，内容直接显示、不重复播放动画。
   */
  markReveal: function(page, items) {
    if (page.__listRevealed) {
      return false
    }
    page.__listRevealed = true
    for (var i = 0; i < items.length && i < REVEAL_FIRST; i++) {
      if (items[i]) {
        items[i].enter = true
        items[i].revealed = false
      }
    }
    return true
  },

  /**
   * 播放错峰入场：每 40ms 把一项的 revealed 置为 true，
   * 配合 .item 上的 opacity transition 完成淡入；首屏之外的项立即可见。
   */
  playReveal: function(page, items) {
    for (var i = 0; i < items.length && i < REVEAL_FIRST; i++) {
      ;(function(page, items, i) {
        setTimeout(function() {
          if (!page.$valid) return
          if (items[i]) {
            items[i].revealed = true
          }
          // 重新赋值数组引用以触发列表重渲染
          page.visibleItems = page.visibleItems.concat([])
        }, i * REVEAL_STEP_MS)
      })(page, items, i)
    }
    for (var j = REVEAL_FIRST; j < items.length; j++) {
      if (items[j]) {
        items[j].enter = false
        items[j].revealed = true
      }
    }
  }
}
