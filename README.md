# 文件管理 · 小米手环 9 Pro

给 **小米手环 9 Pro** 做的文件管理器，由两部分组成：

| 部件 | 技术 | 作用 |
| --- | --- | --- |
| `src/` | Vela 轻应用（hapjs，JS + .ux） | 用户界面：浏览、新建、重命名、复制、移动、删除、搜索、预览 |
| `watchface/` | Lua 表盘（LVGL / LuaVGL） | **特权后端**：真正读写文件系统，绕过轻应用沙箱 |

界面风格参考 [Snapnotes](https://github.com/vultra-c/Snapnotes) 的中心应用，
表盘配色与 Shell++ 保持一致（纯黑背景 + 深灰圆角卡片 + 蓝色主操作）。

---

## 一、原理：为什么需要 Lua 表盘

Vela 轻应用跑在三重沙箱里，`@system.file` 只能访问 `internal://files/`，
看不到 `/data`、`/system` 这些真实路径——**一个真正的文件管理器因此不可能只靠轻应用实现**。

而 Lua 表盘跑在 Vela OS 的 Lua 运行时里，能用 `io.open` / `os.execute` / `lvgl.fs`，
权限明显更高。于是把 **Lua 表盘当作文件操作后端**，轻应用只负责画界面。

参考实现是仓库里的 Shell++（`com.shell.liangyi`），本项目沿用同一套原理。

### 通信流程

轻应用沙箱目录 `internal://files/` 就是 Lua 侧的 `/data/quickapp/files/<包名>/`，
两个世界靠四个 JSON 文件握手：

```
  Lua 表盘（特权）                      Vela 轻应用（沙箱）
       │                                      │
       │  ① 写 fm_guard.json（一次性令牌）      │
       ├─────────────────────────────────────►│ ② 读令牌
       │                                      │
       │  ③ 读 fm_request.json（带令牌）       │
       │◄─────────────────────────────────────┤ ④ 写请求
       │
       │  ⑤ 执行真实文件操作
       │
       │  ⑥ 写 fm_result.json + 轮换令牌       │
       ├─────────────────────────────────────►│ ⑦ 按 seq 取结果
```

- **500 ms**：Lua 侧轮询周期
- **令牌一次性**：每次请求后立即轮换；校验失败的请求会被直接删除并计入 `rejected`
- **原子写**：先写 `.tmp` 再 `mv`，轻应用不会读到半截 JSON
- **同目录段**：一次只处理一个请求，避免并发写坏 IPC 文件

### 安全边界

令牌从 `/dev/urandom` 取 8 字节 + 时间戳，每次请求后轮换。
外部进程无法读到沙箱目录，也就无法构造合法令牌，因此这条通道只对装了本轻应用的设备开放。
路径在 Lua 侧统一 `normalizePath`（折叠 `..`、重复斜杠），并拒绝含 `/`、`\`、控制字符的
文件名，删除根目录被显式禁止。

---

## 二、功能

| 页面 | 能力 |
| --- | --- |
| 首页 | 后端在线状态条、���备存储 / 我的文件 / 继续浏览入口、搜索与新建悬浮按钮 |
| 文件浏览 | 目录列表、面包屑路径条、名称/大小/时间三种排序、新建、粘贴、返回上级 |
| 文件详情 | 名称/大小/修改时间/类型、文本预览、Hex 查看、图片预览、复制、移动、重命名、两步确认删除 |
| 文本编辑 | 追加 / 覆盖两种模式，看板软键盘输入并保存 |
| 搜索 | 按关键字递归搜索（限深 6 层、限 200 条），可在 /data 与应用目录间切换范围 |
| 设置 | 后端状态、排序方式、键盘震动、剪贴板、关于 |
| 关于 | 版本信息与工作原理说明 |

Lua 表盘侧：点表盘进入「文件后端」页，可查看运行状态、已处理/已拒绝请求数、
实时日志，并手动启停服务。

---

## 三、目录结构

```
src/                       Vela 轻应用
  manifest.json            包名 / 权限 / 路由
  app.ux                   入口，暴露 $app.$def.bridge
  common/
    style.css              视觉规范（对齐 Snapnotes）
    clock.js               全局单例时钟
    utils/bridge.js        ★ 提权桥接客户端
    utils/pageAnim.js      固件同款转场动画
    utils/appState.js      跨页面状态
    utils/format.js        体积/时间/路径格式化
  pages/                   index / files / fileInfo / textEditor / newItem / search / settings / about
  components/InputMethod/  看板软键盘（取自 Snapnotes）

watchface/                 Lua 表盘
  fprj/FileManager.fprj    表盘工程（UTF-16LE，由脚本生成）
  fprj/app/lua/main.lua    ★ 表盘特权后端
  fprj/images/preview.png  表盘预览图

scripts/                   构建与测试脚本
docs/ipc-protocol.md       IPC 协议字段说明
```

---

## 四、构建

### 依赖

- Node.js ≥ 16
- `npm ci`
- 轻应用：`aiot-toolkit`（已在 `package.json` 中）
- 表盘：Windows 环境，或任意装了 .NET Framework 的机器

### 全部产物

```sh
npm ci
sh ./scripts/build-all.sh
```

产物：

- `dist/com.vultra.fmanager.release.<版本>.rpk`
- `bin/FileManager` 与 `watchface/data/resource.bin`

### 分开构建

```sh
npx aiot release --enable-jsc        # 只出轻应用 .rpk
sh ./scripts/build-face.sh           # 只出表盘 .face
```

### 本地跑模拟器

```sh
npm start      # aiot server --watch --open-nuttx
```

### 运行 Lua 后端单测

Lua 侧逻辑可以脱离真机跑（用桩件模拟 LVGL 与文件系统）：

```sh
sudo apt-get install -y lua5.3
lua5.3 scripts/test-lua-backend.lua
```

覆盖 JSON 编解码、路径规范化、目录浏览、增删改查、递归复制/删除、搜索，
以及 IPC 令牌的签发、校验、轮换与重放拒绝。

---

## 五、签名

**仓库不提交任何签名材料。** `aiot release`（PRODUCTION 模式）按以下顺序找证书：

1. `sign/release/private.pem` + `sign/release/certificate.pem`
2. `sign/private.pem` + `sign/certificate.pem`
3. 都没有则回退到 toolkit 内置的调试证书

私钥必须是 **PKCS#1**（`-----BEGIN RSA PRIVATE KEY-----`），因为签名走的是
`crypto.createSign('RSA-SHA256')`。

本地生成一套自签名：

```sh
sh ./scripts/gen-signing.sh
```

CI 上通过 Secrets 还原（见 `.github/workflows/build.yml`）：

| Secret | 内容 |
| --- | --- |
| `FM_KEY` | PKCS#1 私钥全文 |
| `FM_CERT` | X.509 证书全文 |

未配置时流水线自动回退到自签名，保证始终能产出可安装包。

---

## 六、安装到设备

1. 从 CI 产物或本地 `dist/` 取 `.rpk`，用小米穿戴设备的「安装应用 / 测连应用」推送
2. 把 `watchface/data/resource.bin`（或 `bin/FileManager`）推到表盘目录：
   ```
   /data/app/watchface/market/<表盘ID>/resource.bin
   ```
3. 在手环上启用该表盘，回到桌面打开「文件管理」
4. 首页状态条变绿即表示后端已连通

> 表盘 ID 写在 `watchface.config.json` 的 `watchfaceId`（10 位以内、Int32 范围），
> 也可用环境变量 `WATCHFACE_ID` 覆盖。

---

## 七、已知限制

- 搜索深度 6 层、结果 200 条封顶，避免表盘上长时间无响应
- 单文件写入上限 64 KiB，文本预览上限 16 KiB
- 图片预览限 PNG/JPEG/BMP 且不超过 3 MiB
- 表盘里的移动时间依赖固件的 `os.stat`，缺失时列表「按时间」排序会退化为原序
- 跨文件系统的移动会退化为「复制 + 删除」，大文件会偏慢

---

## 八、参考

- [Snapnotes](https://github.com/vultra-c/Snapnotes) —— 界面风格与页面转场
- [LuaDevTemplate](https://github.com/FangAiden/LuaDevTemplate) —— Lua 表盘工程与编译器
- 仓库内的 Shell++ `.rpk` —— 提权 IPC 的原始实现
