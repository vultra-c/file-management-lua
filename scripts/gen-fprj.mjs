/**
 * 生成表盘工程文件 FileManager.fprj
 *
 * 小米的表盘编译器（Compiler.exe）只认 UTF-16LE 编码的 FaceProject XML，
 * 手写很容易踩编码坑，所以用脚本生成，保证可复现。
 *
 * 用法：node scripts/gen-fprj.mjs
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

const PROJECT = 'FileManager'
const DEVICE_TYPE = '362' // 与 LuaDevTemplate 保持一致，LuaVGL 运行时
const TITLE = '文件管理'
const WIDTH = 336 // 小米手环 9 Pro
const HEIGHT = 480
const BITMAP = 'preview.png'
const ENTRY = 'app_lua%2Fmain.lua' // 编译器用 URL 编码表示 app/lua/main.lua

const xml = `<?xml version="1.0" encoding="utf-16" ?>
<FaceProject DeviceType="${DEVICE_TYPE}">
    <Screen Title="${TITLE}" Bitmap="${BITMAP}">
        <Widget Shape="34" Name="${ENTRY}" X="0" Y="0" Width="${WIDTH}" Height="${HEIGHT}" Alpha="0" />
    </Screen>
</FaceProject>
`

const target = path.join(ROOT, 'watchface', 'fprj', `${PROJECT}.fprj`)
fs.mkdirSync(path.dirname(target), { recursive: true })
// UTF-16LE 必须带 BOM（编译器按 0xFF 0xFE 识别编码）
fs.writeFileSync(target, Buffer.from('﻿' + xml, 'utf16le'))
console.log('generated', path.relative(ROOT, target))
