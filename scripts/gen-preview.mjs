/**
 * 生成表盘预览图 watchface/fprj/images/preview.png
 *
 * 预览图会写进 .fprj 的 Bitmap 属性，出现在表盘市场列表里。
 * 这里用纯 Node 实现 PNG 编码，不依赖任何三方库或字体，
 * 画面与真机一致：纯黑底 + 大号时间 + 蓝色像素文件夹 + 扫描高光。
 *
 * 用法：node scripts/gen-preview.mjs
 */
import zlib from 'node:zlib'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const OUT = path.join(ROOT, 'watchface', 'fprj', 'images', 'preview.png')

const W = 336
const H = 480

const BG = [0x00, 0x00, 0x00]
const BLUE = [0x0d, 0x6e, 0xff]
const WHITE = [0xff, 0xff, 0xff]
const DIM = [0x33, 0x33, 0x33]

// 与 watchface/fprj/app/lua/main.lua 的 SPRITE_MAP 保持一致
const SPRITE = [
  '..............',
  '..OOOOOOOOOO..',
  '.OOOOOOOOOOOO.',
  '.OOOOOOOOOOOO.',
  '.OO........OO.',
  '.OO........OO.',
  '.OOOOOOOOOOOO.',
  '.OOOOOOOOOOOO.',
  '.OO........OO.',
  '.OO........OO.',
  '..OOOOOOOOOO..',
  '..............'
]

const COLS = SPRITE[0].length
const ROWS = SPRITE.length
const CELL = 20
const SCAN_ROW = 5

// ====== PNG 编码 ======

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

function encodePng(rgb) {
  const raw = Buffer.alloc(H * (W * 3 + 1))
  for (let y = 0; y < H; y++) {
    raw[y * (W * 3 + 1)] = 0
    rgb.copy(raw, y * (W * 3 + 1) + 1, y * W * 3, (y + 1) * W * 3)
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(W, 0)
  ihdr.writeUInt32BE(H, 4)
  ihdr[8] = 8
  ihdr[9] = 2 // truecolor RGB
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0))
  ])
}

// ====== 绘制 ======

const canvas = Buffer.alloc(W * H * 3)
for (let i = 0; i < W * H; i++) {
  canvas[i * 3] = BG[0]
  canvas[i * 3 + 1] = BG[1]
  canvas[i * 3 + 2] = BG[2]
}

function setPx(x, y, color) {
  if (x < 0 || y < 0 || x >= W || y >= H) return
  const i = (y * W + x) * 3
  canvas[i] = color[0]
  canvas[i + 1] = color[1]
  canvas[i + 2] = color[2]
}

function fillRect(x, y, w, h, color) {
  for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) setPx(x + i, y + j, color)
}

// 像素精灵：与真机 renderSprite() 同一套坐标
const spanW = COLS * CELL
const spanH = ROWS * CELL
const originX = Math.floor((W - spanW) / 2)
const originY = Math.floor((Math.floor(H / 2) - spanH) / 2)
for (let r = 0; r < ROWS; r++) {
  for (let c = 0; c < COLS; c++) {
    if (SPRITE[r][c] !== 'O') continue
    const color = r + 1 === SCAN_ROW ? [0x37, 0x8c, 0xff] : BLUE
    fillRect(originX + c * CELL, originY + r * CELL, CELL, CELL, color)
  }
}

// 时间：MiSans 粗体的点阵字形（0-9 与冒号），120px -> 每笔 9x9 格
const GLYPHS = {
  '0': ['011111110', '110000011', '110000011', '110000011', '110000011', '110000011', '110000011', '110000011', '011111110'],
  '1': ['000001100', '000011100', '110001100', '000001100', '000001100', '000001100', '000001100', '110011111', '000000000'],
  '2': ['011111110', '110000011', '000000011', '000001100', '000011000', '000110000', '001100000', '011000000', '111111111'],
  '3': ['111111110', '000000011', '000000011', '000111110', '000000011', '000000011', '000000011', '110000011', '011111110'],
  '4': ['000001100', '000011100', '000110100', '001100100', '011000100', '111111111', '000000100', '000000100', '000000100'],
  '5': ['111111111', '110000000', '110000000', '110111110', '000000011', '000000011', '000000011', '110000011', '011111110'],
  '6': ['001111110', '011000000', '110000000', '110111110', '110000011', '110000011', '110000011', '110000011', '011111110'],
  '7': ['111111111', '000000011', '000000110', '000001100', '000011000', '000110000', '001100000', '001100000', '001100000'],
  '8': ['011111110', '110000011', '110000011', '011111110', '110000011', '110000011', '110000011', '110000011', '011111110'],
  '9': ['011111110', '110000011', '110000011', '110000011', '011111111', '000000011', '000000110', '011111000', '011111100'],
  ':': ['000000000', '000000000', '000011000', '000011000', '000000000', '000011000', '000011000', '000000000', '000000000']
}

function drawClock(text, centerY) {
  const unit = 9
  const gap = 4
  const glyphW = 9 * unit
  const totalW = text.length * glyphW + (text.length - 1) * gap
  let x = Math.floor((W - totalW) / 2)
  for (const ch of text) {
    const g = GLYPHS[ch]
    if (g) {
      for (let r = 0; r < 9; r++) {
        for (let c = 0; c < 9; c++) {
          if (g[r][c] === '1') fillRect(x + c * unit, centerY + r * unit, unit, unit, WHITE)
        }
      }
    }
    x += glyphW + gap
  }
}

drawClock('10:08', Math.floor((Math.floor(H / 2) - 81) / 2))

// 底部一行说明文案（用细横线示意，避免依赖字体）
fillRect(Math.floor(W / 2) - 60, H - 56, 120, 3, DIM)

fs.mkdirSync(path.dirname(OUT), { recursive: true })
fs.writeFileSync(OUT, encodePng(canvas))
console.log('generated', path.relative(ROOT, OUT), `${W}x${H}`)
