/**
 * 生成文件管理器所需的扁平图标（纯 Node 实现，不依赖任何三方库）。
 *
 * 设计约束与 src/common/style.css 对齐：
 *   - 纯黑底 + 深灰卡片 + 蓝色主操作（#0D6EFF）
 *   - 圆角、无描边、扁平色块，不与列表文字抢视觉层级
 *
 * 用法：node scripts/gen-icons.mjs
 */
import zlib from 'node:zlib'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const OUT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../src/common/images')

const SIZE = 64

// ---------- PNG 编码 ----------

const CRC_TABLE = (() => {
  const t = new Int32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    t[n] = c
  }
  return t
})()

function crc32(buf) {
  let c = -1
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8)
  return (c ^ -1) >>> 0
}

function chunk(type, data) {
  const len = Buffer.alloc(4)
  len.writeUInt32BE(data.length, 0)
  const body = Buffer.concat([Buffer.from(type, 'latin1'), data])
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(body), 0)
  return Buffer.concat([len, body, crc])
}

/** rgba: Uint8Array(SIZE*SIZE*4) -> PNG Buffer */
function encodePng(rgba) {
  const raw = Buffer.alloc(SIZE * (SIZE * 4 + 1))
  for (let y = 0; y < SIZE; y++) {
    raw[y * (SIZE * 4 + 1)] = 0 // filter: none
    rgba.copy
      ? Buffer.from(rgba.buffer, y * SIZE * 4, SIZE * 4).copy(raw, y * (SIZE * 4 + 1) + 1)
      : null
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(SIZE, 0)
  ihdr.writeUInt32BE(SIZE, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 6 // color type RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))
  ])
}

// ---------- 画布 ----------

function canvas() {
  return new Uint8Array(SIZE * SIZE * 4)
}

function px(c, x, y, [r, g, b, a = 255]) {
  if (x < 0 || y < 0 || x >= SIZE || y >= SIZE) return
  const i = (y * SIZE + x) * 4
  const src = a / 255
  const dst = c[i + 3] / 255
  const out = src + dst * (1 - src)
  if (out <= 0) return
  c[i] = Math.round((r * src + c[i] * dst * (1 - src)) / out)
  c[i + 1] = Math.round((g * src + c[i + 1] * dst * (1 - src)) / out)
  c[i + 2] = Math.round((b * src + c[i + 2] * dst * (1 - src)) / out)
  c[i + 3] = Math.round(out * 255)
}

/** 圆角矩形的有符号距离场：<=0 在内部 */
function roundRect(x, y, w, h, r) {
  const dx = Math.max(x - (w - r), -(x - r), 0)
  const dy = Math.max(y - (h - r), -(y - r), 0)
  return Math.sqrt(dx * dx + dy * dy) - r
}

/** 用 2x2 超采样填充圆角矩形，得到抗锯齿边缘 */
function fillRoundRect(c, ox, oy, w, h, r, color) {
  for (let y = Math.floor(oy) - 1; y < Math.ceil(oy + h) + 1; y++) {
    for (let x = Math.floor(ox) - 1; x < Math.ceil(ox + w) + 1; x++) {
      let hits = 0
      for (let sy = 0; sy < 2; sy++) {
        for (let sx = 0; sx < 2; sx++) {
          if (roundRect(x + 0.25 + sx * 0.5 - ox, y + 0.25 + sy * 0.5 - oy, w, h, r) <= 0) hits++
        }
      }
      if (hits) px(c, x, y, [color[0], color[1], color[2], Math.round((color[3] ?? 255) * (hits / 4))])
    }
  }
}

function hex(h) {
  const n = parseInt(h.slice(1), 16)
  return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]
}

const BLUE = hex('#0D6EFF')
const DIM = hex('#6E7681')
const GREEN = hex('#2FBF71')
const AMBER = hex('#E8A33D')
const PURPLE = hex('#8B7BFF')
const WHITE = hex('#FFFFFF')

// ---------- 图标 ----------

/** 文件夹：后置标签 + 主体 */
function folder(color) {
  const c = canvas()
  fillRoundRect(c, 6, 14, 24, 10, 5, color)
  fillRoundRect(c, 4, 22, 56, 34, 8, color)
  return c
}

/** 文档：折角 + 底部留白表示可写 */
function file(color) {
  const c = canvas()
  fillRoundRect(c, 14, 6, 36, 52, 7, color)
  // 折角：右上三角挖空成背景色（透明）
  for (let y = 6; y < 20; y++) {
    for (let x = 38; x < 50; x++) {
      if (y - 6 + (x - 38) < 12) px(c, x, y, [0, 0, 0, 0])
    }
  }
  // 三条文本线
  fillRoundRect(c, 22, 30, 20, 4, 2, WHITE)
  fillRoundRect(c, 22, 38, 20, 4, 2, WHITE)
  fillRoundRect(c, 22, 46, 12, 4, 2, WHITE)
  return c
}

/** 图片：文档 + 山峰/太阳 */
function image() {
  const c = file(DIM)
  fillRoundRect(c, 22, 44, 6, 6, 1, AMBER)
  for (let y = 0; y < 12; y++) {
    for (let x = 0; x < 26; x++) {
      if (y >= 12 - Math.round(x / 2.2) - 1) px(c, 22 + x, 40 + (11 - y), GREEN)
    }
  }
  return c
}

/** 父目录：文件夹 + 向上箭头 */
function parent() {
  const c = folder(DIM)
  for (let y = 0; y < 12; y++) {
    const half = Math.min(y, 11 - y)
    for (let x = -half; x <= half; x++) px(c, 32 + x, 34 + y, WHITE)
  }
  fillRoundRect(c, 29, 40, 6, 12, 3, WHITE)
  return c
}

/** 存储根：圆角方框 + 内部横杠 */
function root() {
  const c = canvas()
  fillRoundRect(c, 8, 20, 48, 28, 8, PURPLE)
  fillRoundRect(c, 18, 30, 28, 4, 2, WHITE)
  return c
}

const ICONS = {
  'ic_folder.png': folder(BLUE),
  'ic_file.png': file(DIM),
  'ic_image.png': image(),
  'ic_parent.png': parent(),
  'ic_root.png': root()
}

fs.mkdirSync(OUT_DIR, { recursive: true })
for (const [name, canvasData] of Object.entries(ICONS)) {
  const buf = Buffer.from(canvasData.buffer)
  fs.writeFileSync(path.join(OUT_DIR, name), encodePng(buf))
  console.log('generated', name)
}
