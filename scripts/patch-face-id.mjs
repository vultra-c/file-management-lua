/**
 * 把表盘 ID 写进编译产物的头部。
 *
 * 小米表盘二进制以 0x5A 0xA5 0x34 0x12 开头，
 * 偏移 40 处是 10 字节的 ASCII ID 槽位，偏移 5 存槽位长度。
 * LuaDevTemplate 的 set_face_id.ps1 就是干这个的，这里用 Node 重写一份，
 * 便于在 Linux CI 上跑（PowerShell 只在 Windows 有）。
 *
 * 用法：node scripts/patch-face-id.mjs <face 文件> <数字 ID>
 */
import fs from 'node:fs'

const MAGIC = [0x5a, 0xa5, 0x34, 0x12]
const ID_OFFSET = 40
const ID_SIZE = 10

const [, , facePath, rawId] = process.argv

if (!facePath || !rawId) {
  console.error('用法: node scripts/patch-face-id.mjs <face 文件> <数字 ID>')
  process.exit(2)
}
if (!/^[0-9]+$/.test(rawId)) {
  console.error(`表盘 ID 必须是纯数字: ${rawId}`)
  process.exit(2)
}

const bytes = fs.readFileSync(facePath)
if (bytes.length < ID_OFFSET + ID_SIZE) {
  console.error(`表盘文件过小，拒绝写入: ${facePath} (${bytes.length} 字节)`)
  process.exit(1)
}
for (let i = 0; i < MAGIC.length; i++) {
  if (bytes[i] !== MAGIC[i]) {
    console.error('表盘头部魔数不匹配，拒绝写入（可能不是 .face 文件）')
    process.exit(1)
  }
}

const idBytes = Buffer.from(rawId, 'ascii')
if (idBytes.length > ID_SIZE) {
  console.error(`表盘 ID 超过 ${ID_SIZE} 字节槽位: ${rawId}`)
  process.exit(1)
}

bytes[5] = ID_SIZE
for (let i = 0; i < ID_SIZE; i++) {
  bytes[ID_OFFSET + i] = i < idBytes.length ? idBytes[i] : 0
}
fs.writeFileSync(facePath, bytes)
console.log(`已写入表盘 ID ${rawId} -> ${facePath}`)
