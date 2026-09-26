# IPC 协议

轻应用（沙箱）与 Lua 表盘（特权）之间的全部通信，都走轻应用沙箱目录里的四个 JSON 文件。

真实路径 = `internal://files/` ⇔ `/data/quickapp/files/com.vultra.fmanager/`

| 文件 | 方向 | 写入方 | 说明 |
| --- | --- | --- | --- |
| `fm_guard.json` | 表盘 → 轻应用 | Lua | 一次性令牌，Lua 每 500 ms 检查一次是否被请求消耗 |
| `fm_request.json` | 轻应用 → 表盘 | JS | 一次操作请求，Lua 处理完立即删除 |
| `fm_result.json` | 表盘 → 轻应用 | Lua | 操作结果，按 `seq` 匹配 |
| `fm_heartbeat.json` | 表盘 → 轻应用 | Lua | 心跳，5 s 一次，用于判断后端在线 |

## 时序

```
Lua                                      轻应用
 │                                         │
 │ rotateGuard()                           │
 │   写 fm_guard.json {seq, token}         │
 ├────────────────────────────────────────►│
 │                                         │ 读 fm_guard.json 取 token
 │                                         │ 写 fm_request.json {seq, action, guard, …}
 │◄────────────────────────────────────────┤
 │ 轮询命中（500 ms）                        │
 │ 校验 guard：                              │
 │   不符 → 删除请求 + 回 guard_expired      │
 │   相符 → 轮换令牌                        │
 │ 执行文件操作                              │
 │ 写 fm_result.json {seq, status, data}    │
 │ 删除 fm_request.json                     │
 ├────────────────────────────────────────►│ 轮询 fm_result.json，按 seq 匹配
```

## 通用字段

### 请求 `fm_request.json`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `seq` | number | 自增序号，用于匹配结果 |
| `action` | string | 操作名，见下表 |
| `guard` | string | 必填，当前一次性令牌 |
| `timestamp` | number | Unix 秒 |
| `path` | string | 目标路径，缺省 `/` |
| `dest` | string | 目标目录，仅 `copy` / `move` |
| `name` | string | 新名称，仅 `rename` |
| `content` | string | 文本内容，仅 `write` |
| `offset` | number | 读偏移，仅 `hex` |
| `length` | number | 读长度，仅 `hex` |
| `limit` | number | 读字节上限，仅 `text` |
| `keyword` | string | 搜索关键字，仅 `search` |

### 结果 `fm_result.json`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `type` | string | 固定 `fm_result` |
| `seq` | number | 原样回传请求的 `seq` |
| `action` | string | 原样回传 |
| `status` | string | `ok` 或 `error` |
| `code` | string | 失败时的错误码 |
| `message` | string | 失败时的中文提示，直接给用户看 |
| `data` | object | 成功时的载荷，字段见下表 |
| `timestamp` | string | `HH:MM:SS` |

### 心跳 `fm_heartbeat.json`

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `timestamp` | number | Unix 秒，轻应用据此判断后端是否失联（12 s 阈值） |
| `product` / `model` | string | 设备型号 |
| `targetDir` | string | 实际使用的工作目录 |
| `running` | boolean | 服务是否在跑 |
| `requests` / `rejected` | number | 累计请求数 / 被拒数（表盘「文件后端」页展示） |
| `lastAction` / `lastStatus` | string | 最近一次操作 |
| `mtimeSupported` | boolean | 固件的 Lua 是否提供 `os.stat`，决定列表能否显示修改时间 |

## 操作一览

| action | 额外请求字段 | `data` 返回 |
| --- | --- | --- |
| `list` | `path` | `path`、`items[]`、`count` |
| `info` | `path` | `path`、`name`、`isDir`、`sizeBytes`、`mtime` |
| `text` | `path`、`limit` | `path`、`content`、`totalBytes`、`truncated` |
| `hex` | `path`、`offset`、`length` | `path`、`offset`、`content`、`totalBytes` |
| `write` | `path`、`content` | `path`、`sizeBytes` |
| `mkdir` | `path` | `path`、`name` |
| `rename` | `path`、`name` | `path`（新路径）、`name` |
| `copy` | `path`、`dest` | `path`、`dest`（实际落点，重名时带 `(1)` 后缀） |
| `move` | `path`、`dest` | `path`、`dest` |
| `delete` | `path` | `path` |
| `search` | `path`、`keyword` | `items[]`、`count`、`truncated` |
| `image` | `path` | `path`、`uri`（`internal://files/...`） |
| `storage` | — | `product`、`model`、`targetDir`、`mtimeSupported` |

`items[]` 每一项：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `name` | string | 文件名 |
| `path` | string | 绝对路径 |
| `isDir` | boolean | 是否目录 |
| `sizeBytes` | number | 字节数，目录为 0 |
| `mtime` | number | Unix 秒，不支持时为 0 |

## 错误码

| code | 含义 |
| --- | --- |
| `guard_expired` | 令牌不匹配或已轮换，请求被丢弃 |
| `list_fail` | 目录不可读 |
| `read_fail` | 文件不可读 |
| `write_fail` | 写入失败 |
| `not_found` | 目标不存在 |
| `bad_name` | 文件名含 `/`、`\`、控制字符，或为 `.` / `..` |
| `exists` | 同名文件/目录已存在 |
| `mkdir_fail` / `delete_fail` / `copy_fail` / `move_fail` / `rename_fail` | 对应操作失败 |
| `forbidden` | 试图删除根目录 |
| `bad_dest` | 目标目录不存在 |
| `name_conflict` | 连续 200 次重名，无法生成可用文件名 |
| `bad_keyword` / `bad_root` | 关键字为空 / 搜索范围不存在 |
| `bad_type` / `bad_size` / `preview_fail` | 图片类型、大小或缓存写入失败 |
| `too_large` | 写入内容超过 64 KiB |
| `unknown_action` | 未注册的操作 |
| `exception` | Lua 侧执行异常，兜底返回 |

## 约束

| 项 | 值 |
| --- | --- |
| 轮询周期 | 500 ms（Lua 侧） |
| 结果轮询 | 100 ms（轻应用侧），超时 8 s |
| 令牌重试 | 3 次，间隔 60 ms |
| 后端失联阈值 | 12 s 无心跳 |
| 并发 | 同时只允许一个在途请求 |
| 写入上限 | 64 KiB |
| 文本读取上限 | 16 KiB |
| Hex 读取上限 | 2 KiB/页 |
| 搜索 | 深 6 层、200 条 |
| 图片预览 | ≤ 3 MiB，PNG/JPEG/BMP |
