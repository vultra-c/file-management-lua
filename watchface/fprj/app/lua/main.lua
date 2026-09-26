--[[
    文件管理 · Lua 表盘特权后端
    =====================================================================
    小米 Vela 轻应用运行在三重沙箱里，@system.file 只能访问
    internal://files/ ，看不到 /data、/system 等真实路径。
    而 Lua 表盘运行在 Vela OS 的 Lua 运行时，具备 io / os.execute /
    lvgl.fs 能力 —— 这就是「较高权限」。

    本文件把 Lua 表盘当作文件操作后端，通过一次性令牌 + JSON 文件
    通道把真实文件系统的能力借给轻应用：

        轻应用 --读--> fm_guard.json      拿到一次性令牌
        轻应用 --写--> fm_request.json     带上令牌发起操作
        本文件 --执行--> 真实 io / lvgl.fs 操作
        本文件 --写--> fm_result.json      返回结果并立即轮换令牌

    令牌每次请求后轮换，校验失败的请求会被直接删除，
    因此外部进程无法伪造请求。与 Shell++ 的实现原理一致。

    版面：336 x 480（小米手环 9 Pro）
    风格：纯黑背景 + 深灰圆角卡片 + 蓝色主操作（对齐 Vela 快应用）
]]

-- =====================================================================
-- 1. 配置
-- =====================================================================

local APP_PACKAGE = 'com.vultra.fmanager'

-- 候选工作目录：轻应用沙箱目录（internal://files/ 的真实路径）
local CANDIDATE_DIRS = {
    '/data/quickapp/files/' .. APP_PACKAGE .. '/',   -- 小米手环 9 Pro / 手表 S4
    '/data/data/' .. APP_PACKAGE .. '/',              -- 小米手环 10 Pro
    '/data/files/' .. APP_PACKAGE .. '/'              -- 小米手环 10 Pro 兜底
}

local TARGET_DIR = CANDIDATE_DIRS[1]
local PRODUCT_NAME = 'Xiaomi Smart Band 9 Pro'
local MODEL_NAME = '-'

-- 离线测试钩子：scripts/test-lua-backend.lua 会在加载前设置这两个全局变量，
-- 真机运行时无人设置，走下面的默认探测逻辑。
if type(_G.FM_TEST) == 'table' then
    if _G.FM_TEST.targetDir then
        CANDIDATE_DIRS = { _G.FM_TEST.targetDir }
        TARGET_DIR = _G.FM_TEST.targetDir
    end
    if _G.FM_TEST.product then
        PRODUCT_NAME = tostring(_G.FM_TEST.product)
    end
end

local GUARD_FILE = 'fm_guard.json'
local REQUEST_FILE = 'fm_request.json'
local RESULT_FILE = 'fm_result.json'
local HEARTBEAT_FILE = 'fm_heartbeat.json'

local POLL_MS = 500          -- IPC 轮询周期
local HEARTBEAT_MS = 5000    -- 心跳周期
local TEXT_LIMIT_MAX = 16384
local HEX_LIMIT_MAX = 2048
local SEARCH_MAX = 200       -- 搜索结果上限
local SEARCH_DEPTH = 6       -- 搜索最大深度
local IMAGE_MAX = 3 * 1024 * 1024
local WRITE_MAX = 64 * 1024
local COPY_CHUNK = 8192

-- 视觉规范（与 src/common/style.css 一致）
local UI_BG = 0x000000
local UI_CARD = 0x262626
local UI_PRIMARY = 0x0D6EFF
local UI_DANGER = 0xD93A2F
local UI_TEXT = 0xFFFFFF
local UI_DIM = 0x888888
local UI_TERM = 0xD6D6D6

local UI_GAP = 12
local UI_RADIUS = 24
local UI_TOPBAR = 56

local SCREEN_W = lvgl.HOR_RES()
local SCREEN_H = lvgl.VER_RES()

-- 像素精灵网格（表盘装饰，复刻 Shell++ 的方块动画手感）
local SPRITE_COLS = 14
local SPRITE_ROWS = 12
local SPRITE_CELL = 20

-- 运行期状态
local serviceRunning = false
local busy = false
local guardToken = ''
local guardSeq = 0
local writeSeq = 0
local lastPreviewPath = nil
local logBuffer = {}
local stats = {
    requests = 0,
    rejected = 0,
    lastAction = '-',
    lastStatus = '-',
    lastPath = '-'
}

-- =====================================================================
-- 2. JSON
-- =====================================================================

local function jsonEscape(str)
    local out = str:gsub('\\', '\\\\')
    out = out:gsub('"', '\\"')
    out = out:gsub('\n', '\\n')
    out = out:gsub('\r', '\\r')
    out = out:gsub('\t', '\\t')
    out = out:gsub('[%z\1-\31]', function(c)
        return string.format('\\u%04x', string.byte(c))
    end)
    return out -- UTF-8 多字节序列原样透传
end

local function jsonEncode(val)
    local t = type(val)
    if t == 'string' then
        return '"' .. jsonEscape(val) .. '"'
    elseif t == 'number' then
        if val ~= val or val == math.huge or val == -math.huge then return 'null' end
        if val == math.floor(val) and math.abs(val) < 4503599627370496 then
            return string.format('%d', val)
        end
        return string.format('%.14g', val)
    elseif t == 'boolean' then
        return tostring(val)
    elseif t == 'nil' then
        return 'null'
    elseif t == 'table' then
        local count, maxNum = 0, 0
        for k in pairs(val) do
            count = count + 1
            if type(k) == 'number' and k > maxNum then maxNum = k end
        end
        if count == 0 then return '{}' end
        local parts = {}
        if maxNum == count then
            for i = 1, count do parts[#parts + 1] = jsonEncode(val[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(val) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for i = 1, #keys do
            parts[#parts + 1] = jsonEncode(keys[i]) .. ':' .. jsonEncode(val[keys[i]])
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return 'null'
end

local function jsonDecode(str)
    if type(str) ~= 'string' then return nil end
    if str:sub(1, 3) == '\239\187\191' then str = str:sub(4) end
    str = str:gsub('^%s+', ''):gsub('%s+$', '')
    if str == '' then return nil end

    local pos, len = 1, #str

    local function fail()
        error('json parse error at ' .. pos, 0)
    end

    local function skipWs()
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == ' ' or c == '\t' or c == '\n' or c == '\r' then
                pos = pos + 1
            else
                break
            end
        end
    end

    local function parseString()
        if str:sub(pos, pos) ~= '"' then fail() end
        pos = pos + 1
        local buf = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(buf)
            elseif c == '\\' then
                local esc = str:sub(pos + 1, pos + 1)
                if esc == 'n' then buf[#buf + 1] = '\n'
                elseif esc == 't' then buf[#buf + 1] = '\t'
                elseif esc == 'r' then buf[#buf + 1] = '\r'
                elseif esc == 'b' then buf[#buf + 1] = '\b'
                elseif esc == 'f' then buf[#buf + 1] = '\f'
                elseif esc == '/' then buf[#buf + 1] = '/'
                elseif esc == '"' then buf[#buf + 1] = '"'
                elseif esc == '\\' then buf[#buf + 1] = '\\'
                elseif esc == 'u' then
                    local code = tonumber(str:sub(pos + 2, pos + 5), 16)
                    if not code then fail() end
                    if code < 0x80 then
                        buf[#buf + 1] = string.char(code)
                    elseif code < 0x800 then
                        buf[#buf + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
                    else
                        buf[#buf + 1] = string.char(0xE0 + math.floor(code / 0x1000),
                            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
                    end
                    pos = pos + 4
                else
                    fail()
                end
                pos = pos + 2
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        fail()
    end

    local function parseNumber()
        local s, e = str:find('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
        if not s then fail() end
        local n = tonumber(str:sub(s, e))
        if not n then fail() end
        pos = e + 1
        return n
    end

    local function parseValue()
        skipWs()
        local c = str:sub(pos, pos)
        if c == '{' then
            pos = pos + 1
            local obj = {}
            skipWs()
            if str:sub(pos, pos) == '}' then
                pos = pos + 1
                return obj
            end
            while true do
                skipWs()
                local key = parseString()
                skipWs()
                if str:sub(pos, pos) ~= ':' then fail() end
                pos = pos + 1
                obj[key] = parseValue()
                skipWs()
                local sep = str:sub(pos, pos)
                if sep == ',' then
                    pos = pos + 1
                elseif sep == '}' then
                    pos = pos + 1
                    return obj
                else
                    fail()
                end
            end
        elseif c == '[' then
            pos = pos + 1
            local arr = {}
            skipWs()
            if str:sub(pos, pos) == ']' then
                pos = pos + 1
                return arr
            end
            while true do
                arr[#arr + 1] = parseValue()
                skipWs()
                local sep = str:sub(pos, pos)
                if sep == ',' then
                    pos = pos + 1
                elseif sep == ']' then
                    pos = pos + 1
                    return arr
                else
                    fail()
                end
            end
        elseif c == '"' then
            return parseString()
        elseif str:sub(pos, pos + 3) == 'true' then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == 'false' then
            pos = pos + 5
            return false
        elseif str:sub(pos, pos + 3) == 'null' then
            pos = pos + 4
            return nil
        else
            return parseNumber()
        end
    end

    local ok, result = pcall(function()
        local v = parseValue()
        skipWs()
        return v
    end)
    if not ok then return nil end
    return result
end

-- =====================================================================
-- 3. 基础 IO
-- =====================================================================

local function readFile(path)
    local ok, f = pcall(io.open, path, 'r')
    if not ok or not f then return nil end
    local content = f:read('*all')
    pcall(f.close, f)
    return content
end

local function writeFile(path, content)
    local ok, f = pcall(io.open, path, 'w')
    if not ok or not f then return false end
    local written = pcall(f.write, f, content)
    pcall(f.close, f)
    return written
end

local function fileExists(path)
    local ok, f = pcall(io.open, path, 'r')
    if ok and f then
        pcall(f.close, f)
        return true
    end
    return false
end

local function fileSize(path)
    local ok, f = pcall(io.open, path, 'rb')
    if not ok or not f then return 0 end
    local seekOk, size = pcall(f.seek, f, 'end')
    pcall(f.close, f)
    if not seekOk then return 0 end
    return tonumber(size) or 0
end

local function isDir(path)
    local ok, dir = pcall(lvgl.fs.open_dir, path)
    if ok and dir then
        pcall(dir.close, dir)
        return true
    end
    return false
end

local function mkdirp(path)
    if not path or path == '' then return false end
    if path:find('[;&|`"\\$()]') then return false end
    local ok, code = pcall(os.execute, 'mkdir -p "' .. path .. '"')
    return ok and (code == true or code == 0)
end

--- 递归删除：目录先删子项再删自身，文件直接删。
-- 必须先判 isDir：部分 libc 的 io.open 对目录也能打开，
-- 用 fileExists 判断会误把目录当文件，导致 os.remove 失败后静默返回。
local function removeRecursive(path)
    if not isDir(path) then
        local ok, removed = pcall(os.remove, path)
        return ok and removed == true
    end

    local ok, dir = pcall(lvgl.fs.open_dir, path)
    if not ok or not dir then
        local rm, code = pcall(os.execute, 'rm -rf "' .. path .. '"')
        return rm and (code == true or code == 0)
    end
    local children = {}
    while true do
        local readOk, entry = pcall(dir.read, dir)
        if not readOk or not entry or entry == '' then break end
        if entry ~= '.' and entry ~= '..' then
            children[#children + 1] = entry
        end
    end
    pcall(dir.close, dir)

    -- open_dir 的目录项带前导 '/'，剥掉后再拼，否则会丢分隔符拼出错误路径
    local prefix = path
    if string.sub(prefix, -1) ~= '/' then prefix = prefix .. '/' end
    for i = 1, #children do
        local name = children[i]
        if string.sub(name, 1, 1) == '/' then name = string.sub(name, 2) end
        removeRecursive(prefix .. name)
    end
    local rmdir, code = pcall(os.execute, 'rmdir "' .. path .. '"')
    return rmdir and (code == true or code == 0)
end

local function addLog(line)
    table.insert(logBuffer, 1, line)
    while #logBuffer > 6 do table.remove(logBuffer) end
end

--- 原子写：先写 .tmp 再 mv，避免轻应用读到半截 JSON
local function atomicWrite(name, data)
    data._seq = writeSeq
    writeSeq = writeSeq + 1
    mkdirp(TARGET_DIR)
    local tmp = TARGET_DIR .. '.' .. name .. '.tmp'
    local path = TARGET_DIR .. name
    if not writeFile(tmp, jsonEncode(data)) then return false end
    pcall(os.remove, path)
    local ok, code = pcall(os.execute, 'mv "' .. tmp .. '" "' .. path .. '"')
    return ok and (code == true or code == 0)
end

-- =====================================================================
-- 4. 路径工具
-- =====================================================================

--- 规范化路径：补前导 /、折叠 . 与 ..，防止越权访问
local function normalizePath(path)
    path = tostring(path or '/')
    if path == '' then path = '/' end
    if string.sub(path, 1, 1) ~= '/' then path = '/' .. path end
    local out = {}
    for seg in path:gmatch('[^/]+') do
        if seg == '.' then
            -- 跳过
        elseif seg == '..' then
            if #out > 0 then table.remove(out) end
        else
            out[#out + 1] = seg
        end
    end
    if #out == 0 then return '/' end
    return '/' .. table.concat(out, '/')
end

local function basenameOf(path)
    path = normalizePath(path)
    if path == '/' then return '/' end
    return path:match('([^/]+)$') or path
end

--- 取父目录。
-- 注意：这里必须用 '^(.*)/[^/]+$' 这样的实捕获组，
-- 写成 '()'（空捕获）时 Lua 返回的是匹配位置而不是父路径。
local function parentOf(path)
    path = normalizePath(path)
    if path == '/' then return '' end
    local parent = path:match('^(.*)/[^/]+$')
    if not parent or parent == '' then return '/' end
    return parent
end

local function joinPath(base, name)
    base = normalizePath(base)
    if base == '/' then return '/' .. name end
    return base .. '/' .. name
end

--- 拒绝危险名称（含 / \ 空白、. 与 ..）
local function isSafeName(name)
    name = tostring(name or '')
    if name == '' or #name > 120 then return false end
    if name == '.' or name == '..' then return false end
    if name:find('/', 1, true) or name:find('\\', 1, true) then return false end
    if name:find('%c') then return false end
    return true
end

--- 读取目录原始条目；open_dir 用前导 '/' 区分目录项
local function rawList(path)
    local ok, dir = pcall(lvgl.fs.open_dir, path)
    if not ok or not dir then return nil, '目录不可读' end
    local entries = {}
    while true do
        local readOk, entry = pcall(dir.read, dir)
        if not readOk or not entry or entry == '' then break end
        entries[#entries + 1] = entry
    end
    pcall(dir.close, dir)
    return entries, nil
end

local function splitEntry(entry)
    if string.byte(entry, 1) == 47 then
        return string.sub(entry, 2), true
    end
    return entry, false
end

-- 部分固件的 Lua 没有 os.stat，缺失时 mtime 退化为 0（前端按「-」显示）
local hasOsStat = (type(os.stat) == 'function')

local function mtimeOf(path)
    if not hasOsStat then return 0 end
    local ok, st = pcall(os.stat, path)
    if not ok or type(st) ~= 'table' then return 0 end
    return tonumber(st.mtime) or tonumber(st.modified) or 0
end

-- =====================================================================
-- 5. 文件操作
-- =====================================================================

local function listDir(path)
    path = normalizePath(path)
    local entries, err = rawList(path)
    if not entries then
        return { status = 'error', code = 'list_fail', message = err or '目录不可读' }
    end
    local items = {}
    for i = 1, #entries do
        local name, isDirEntry = splitEntry(entries[i])
        if name ~= '' and name ~= '.' and name ~= '..' then
            local full = joinPath(path, name)
            items[#items + 1] = {
                name = name,
                path = full,
                isDir = isDirEntry,
                sizeBytes = isDirEntry and 0 or fileSize(full),
                mtime = mtimeOf(full)
            }
        end
    end
    table.sort(items, function(a, b)
        if a.isDir ~= b.isDir then return a.isDir end
        return a.name < b.name
    end)
    return { status = 'ok', data = { path = path, items = items, count = #items } }
end

local function statFile(path)
    path = normalizePath(path)
    local dir = isDir(path)
    if not dir and not fileExists(path) then
        return { status = 'error', code = 'not_found', message = '目标不存在' }
    end
    return {
        status = 'ok',
        data = {
            path = path,
            name = basenameOf(path),
            isDir = dir,
            sizeBytes = dir and 0 or fileSize(path),
            mtime = mtimeOf(path)
        }
    }
end

--- 控制字符替换成 '.'，避免破坏 UI
local function sanitizeText(text)
    text = tostring(text or '')
    local out = {}
    for i = 1, #text do
        local b = string.byte(text, i)
        if b == 9 or b == 10 or b == 13 or b >= 32 then
            out[#out + 1] = string.char(b)
        else
            out[#out + 1] = '.'
        end
    end
    return table.concat(out)
end

local function readTextFile(path, limit)
    path = normalizePath(path)
    limit = tonumber(limit) or 4096
    if limit < 256 then limit = 256 end
    if limit > TEXT_LIMIT_MAX then limit = TEXT_LIMIT_MAX end
    local ok, f = pcall(io.open, path, 'r')
    if not ok or not f then
        return { status = 'error', code = 'read_fail', message = '文件不可读' }
    end
    local content = f:read(limit) or ''
    pcall(f.close, f)
    local total = fileSize(path)
    return {
        status = 'ok',
        data = { path = path, content = sanitizeText(content), totalBytes = total, truncated = total > limit }
    }
end

local function readHexFile(path, offset, length)
    path = normalizePath(path)
    offset = tonumber(offset) or 0
    length = tonumber(length) or 256
    if offset < 0 then offset = 0 end
    if length < 16 then length = 16 end
    if length > HEX_LIMIT_MAX then length = HEX_LIMIT_MAX end

    local ok, f = pcall(io.open, path, 'rb')
    if not ok or not f then
        return { status = 'error', code = 'read_fail', message = '文件不可读' }
    end
    local seekOk = pcall(f.seek, f, 'set', offset)
    local bytes = ''
    if seekOk then
        bytes = f:read(length) or ''
    end
    pcall(f.close, f)

    local lines = {}
    local line = string.format('%08X  ', offset)
    for i = 1, #bytes do
        line = line .. string.format('%02X ', string.byte(bytes, i))
        if i % 8 == 0 then
            lines[#lines + 1] = line
            line = string.format('%08X  ', offset + i)
        end
    end
    if #bytes % 8 ~= 0 or #bytes == 0 then
        lines[#lines + 1] = line
    end
    return {
        status = 'ok',
        data = { path = path, offset = offset, content = table.concat(lines, '\n'), totalBytes = fileSize(path) }
    }
end

local function writeTextFile(path, content)
    path = normalizePath(path)
    if not isSafeName(basenameOf(path)) then
        return { status = 'error', code = 'bad_name', message = '文件名非法' }
    end
    content = tostring(content or '')
    if #content > WRITE_MAX then
        return { status = 'error', code = 'too_large', message = '内容超过 64 KiB 限制' }
    end
    local ok, f = pcall(io.open, path, 'w')
    if not ok or not f then
        return { status = 'error', code = 'write_fail', message = '写入失败：无法创建文件' }
    end
    local wrote = pcall(f.write, f, content)
    pcall(f.close, f)
    if not wrote then
        return { status = 'error', code = 'write_fail', message = '写入失败' }
    end
    return { status = 'ok', data = { path = path, sizeBytes = fileSize(path) } }
end

local function makeDirectory(path)
    path = normalizePath(path)
    if not isSafeName(basenameOf(path)) then
        return { status = 'error', code = 'bad_name', message = '目录名非法' }
    end
    if isDir(path) or fileExists(path) then
        return { status = 'error', code = 'exists', message = '同名项目已存在' }
    end
    if not mkdirp(path) then
        return { status = 'error', code = 'mkdir_fail', message = '创建目录失败' }
    end
    return { status = 'ok', data = { path = path, name = basenameOf(path) } }
end

local function copyFileRaw(src, dst)
    local okIn, input = pcall(io.open, src, 'rb')
    if not okIn or not input then return false end
    local okOut, output = pcall(io.open, dst, 'wb')
    if not okOut or not output then
        pcall(input.close, input)
        return false
    end
    local ok = true
    while true do
        local readOk, chunk = pcall(input.read, input, COPY_CHUNK)
        if not readOk or not chunk or chunk == '' then break end
        local writeOk = pcall(output.write, output, chunk)
        if not writeOk then
            ok = false
            break
        end
    end
    pcall(input.close, input)
    pcall(output.close, output)
    return ok
end

--- 递归复制：目录 -> mkdir + 逐项复制；文件 -> 分块拷贝
local function copyRecursive(src, dst)
    if not isDir(src) then return copyFileRaw(src, dst) end
    if not mkdirp(dst) then return false end
    local entries = rawList(src)
    if not entries then return false end
    for i = 1, #entries do
        local name = splitEntry(entries[i])
        if name ~= '' and name ~= '.' and name ~= '..' then
            if not copyRecursive(joinPath(src, name), joinPath(dst, name)) then return false end
        end
    end
    return true
end

--- 目标重名时自动加 (1)(2)… 后缀
local function uniqueDest(destDir, name)
    local candidate = joinPath(destDir, name)
    if not fileExists(candidate) and not isDir(candidate) then return candidate end
    local stem, suffix = name:match('^(.*)(%.[^.]*)$')
    if not stem then stem, suffix = name, '' end
    for i = 1, 200 do
        candidate = joinPath(destDir, stem .. '(' .. i .. ')' .. suffix)
        if not fileExists(candidate) and not isDir(candidate) then return candidate end
    end
    return nil
end

local function copyItem(path, dest)
    path = normalizePath(path)
    dest = normalizePath(dest or '/')
    if not fileExists(path) and not isDir(path) then
        return { status = 'error', code = 'not_found', message = '源不存在' }
    end
    if not isDir(dest) then
        return { status = 'error', code = 'bad_dest', message = '目标目录不存在' }
    end
    local finalDest = uniqueDest(dest, basenameOf(path))
    if not finalDest then
        return { status = 'error', code = 'name_conflict', message = '无法生成可用文件名' }
    end
    if not copyRecursive(path, finalDest) then
        return { status = 'error', code = 'copy_fail', message = '复制失败' }
    end
    return { status = 'ok', data = { path = path, dest = finalDest } }
end

--- 优先 rename（快）；跨设备/只读时退化为复制 + 删除
local function tryRename(src, dst)
    if not os or type(os.rename) ~= 'function' then return false end
    local ok, result = pcall(os.rename, src, dst)
    return ok and result ~= false
end

local function moveItem(path, dest)
    path = normalizePath(path)
    dest = normalizePath(dest or '/')
    if not fileExists(path) and not isDir(path) then
        return { status = 'error', code = 'not_found', message = '源不存在' }
    end
    if not isDir(dest) then
        return { status = 'error', code = 'bad_dest', message = '目标目录不存在' }
    end
    local finalDest = uniqueDest(dest, basenameOf(path))
    if not finalDest then
        return { status = 'error', code = 'name_conflict', message = '无法生成可用文件名' }
    end
    if not tryRename(path, finalDest) then
        if not copyRecursive(path, finalDest) then
            return { status = 'error', code = 'move_fail', message = '移动失败' }
        end
        removeRecursive(path)
    end
    return { status = 'ok', data = { path = path, dest = finalDest } }
end

local function renameItem(path, name)
    path = normalizePath(path)
    if not isSafeName(name) then
        return { status = 'error', code = 'bad_name', message = '名称非法' }
    end
    if not fileExists(path) and not isDir(path) then
        return { status = 'error', code = 'not_found', message = '目标不存在' }
    end
    local newPath = joinPath(parentOf(path), name)
    if newPath == path then
        return { status = 'ok', data = { path = path, name = name } }
    end
    if fileExists(newPath) or isDir(newPath) then
        return { status = 'error', code = 'exists', message = '同名文件已存在' }
    end
    if not tryRename(path, newPath) then
        if not copyRecursive(path, newPath) then
            return { status = 'error', code = 'rename_fail', message = '重命名失败' }
        end
        removeRecursive(path)
    end
    return { status = 'ok', data = { path = newPath, name = name } }
end

local function deleteItem(path)
    path = normalizePath(path)
    if path == '/' then
        return { status = 'error', code = 'forbidden', message = '拒绝删除根目录' }
    end
    if not fileExists(path) and not isDir(path) then
        return { status = 'error', code = 'not_found', message = '目标不存在' }
    end
    if not removeRecursive(path) then
        return { status = 'error', code = 'delete_fail', message = '删除失败' }
    end
    return { status = 'ok', data = { path = path } }
end

--- 递归搜索：目录优先、深度受限、结果数封顶
local function searchTree(root, keyword, results, depth)
    if depth > SEARCH_DEPTH or #results >= SEARCH_MAX then return false end
    local entries = rawList(root)
    if not entries then return true end
    for i = 1, #entries do
        if #results >= SEARCH_MAX then return false end
        local name = splitEntry(entries[i])
        if name ~= '' and name ~= '.' and name ~= '..' then
            local full = joinPath(root, name)
            local dir = isDir(full)
            if string.find(string.lower(name), keyword, 1, true) then
                results[#results + 1] = {
                    name = name,
                    path = full,
                    isDir = dir,
                    sizeBytes = dir and 0 or fileSize(full),
                    mtime = mtimeOf(full)
                }
            end
            if dir then
                searchTree(full, keyword, results, depth + 1)
            end
        end
    end
    return true
end

local function searchFiles(root, keyword)
    root = normalizePath(root)
    keyword = string.lower(tostring(keyword or ''))
    if keyword == '' then
        return { status = 'error', code = 'bad_keyword', message = '关键字为空' }
    end
    if not isDir(root) then
        return { status = 'error', code = 'bad_root', message = '搜索范围不存在' }
    end
    local results = {}
    searchTree(root, keyword, results, 1)
    return { status = 'ok', data = { items = results, count = #results, truncated = #results >= SEARCH_MAX } }
end

--- 设备/存储信息（能取到就报，取不到只报设备型号）
local function storageInfo()
    return {
        status = 'ok',
        data = {
            product = PRODUCT_NAME,
            model = MODEL_NAME,
            targetDir = TARGET_DIR,
            mtimeSupported = hasOsStat
        }
    }
end

--- 图片预览：沙箱内文件直接给 internal:// uri，外部文件复制一份进沙箱
local function imagePreview(path, seq)
    path = normalizePath(path)
    local ext = string.lower(path:match('%.([%w]+)$') or '')
    local allowed = { png = true, jpg = true, jpeg = true, bmp = true }
    if not allowed[ext] then
        return { status = 'error', code = 'bad_type', message = '仅支持 PNG/JPEG/BMP' }
    end
    local size = fileSize(path)
    if size <= 0 or size > IMAGE_MAX then
        return { status = 'error', code = 'bad_size', message = '图片为空或超过 3 MiB' }
    end

    local marker = path:find('/' .. APP_PACKAGE .. '/', 1, true)
    if marker then
        local relative = path:sub(marker + #APP_PACKAGE + 2)
        if relative:match('^[%w_/%.-]+$') and not relative:find('..', 1, true) then
            return { status = 'ok', data = { path = path, uri = 'internal://files/' .. relative } }
        end
    end

    local folder = TARGET_DIR .. 'preview/'
    mkdirp(folder)
    local name = 'img_' .. tostring(seq or 0):gsub('[^%w_-]', '') .. '.' .. ext
    local staged = folder .. name
    if not copyFileRaw(path, staged) then
        return { status = 'error', code = 'preview_fail', message = '预览缓存写入失败' }
    end
    if lastPreviewPath and lastPreviewPath ~= staged then
        pcall(os.remove, lastPreviewPath)
    end
    lastPreviewPath = staged
    return { status = 'ok', data = { path = path, uri = 'internal://files/preview/' .. name } }
end

-- =====================================================================
-- 6. IPC 服务
-- =====================================================================

--- 读取轻应用写入的 device_info.json，据此确定工作目录
local function resolveTargetDir()
    for i = 1, #CANDIDATE_DIRS do
        local info = jsonDecode(readFile(CANDIDATE_DIRS[i] .. 'device_info.json') or '')
        if type(info) == 'table' and info.product then
            PRODUCT_NAME = tostring(info.product)
            MODEL_NAME = tostring(info.model or '-')
            TARGET_DIR = CANDIDATE_DIRS[i]
            return true
        end
    end
    for i = 1, #CANDIDATE_DIRS do
        if isDir(CANDIDATE_DIRS[i]) then
            TARGET_DIR = CANDIDATE_DIRS[i]
            return true
        end
    end
    return false
end

local function randomHex(n)
    local f = io.open('/dev/urandom', 'rb')
    if f then
        local bytes = f:read(n)
        pcall(f.close, f)
        if bytes and #bytes == n then
            local hex = ''
            for i = 1, n do
                hex = hex .. string.format('%02x', string.byte(bytes, i))
            end
            return hex
        end
    end
    local r = ''
    for _ = 1, n do
        r = r .. string.format('%02x', math.random(0, 255))
    end
    return r
end

--- 轮换一次性令牌：轻应用必须在下次请求前重新读取
local function rotateGuard()
    guardSeq = guardSeq + 1
    guardToken = tostring(os.time()) .. '-' .. randomHex(8)
    atomicWrite(GUARD_FILE, {
        type = 'ipc_guard',
        seq = guardSeq,
        token = guardToken,
        timestamp = os.time()
    })
end

local function writeHeartbeat()
    atomicWrite(HEARTBEAT_FILE, {
        type = 'heartbeat',
        timestamp = os.time(),
        product = PRODUCT_NAME,
        model = MODEL_NAME,
        targetDir = TARGET_DIR,
        running = serviceRunning,
        requests = stats.requests,
        rejected = stats.rejected,
        lastAction = stats.lastAction,
        lastStatus = stats.lastStatus,
        mtimeSupported = hasOsStat
    })
end

local function writeResult(req, result)
    result = result or {}
    result.type = 'fm_result'
    result.seq = req and req.seq or -1
    result.action = req and req.action or ''
    result.timestamp = os.date('%H:%M:%S')
    atomicWrite(RESULT_FILE, result)
    pcall(os.remove, TARGET_DIR .. REQUEST_FILE)
end

--- 读取并校验请求；令牌不匹配直接丢弃并回错误
local function readRequest()
    local raw = readFile(TARGET_DIR .. REQUEST_FILE)
    if not raw or raw == '' then return nil end

    local req = jsonDecode(raw)
    if not req then
        -- 可能正写到一半，等一个极短拍再试
        req = jsonDecode(readFile(TARGET_DIR .. REQUEST_FILE) or '')
        if not req then return nil end
    end
    if type(req) ~= 'table' or not req.seq or not req.action then return nil end

    if guardToken == '' or req.guard ~= guardToken then
        stats.rejected = stats.rejected + 1
        addLog('拒绝伪造请求')
        pcall(os.remove, TARGET_DIR .. REQUEST_FILE)
        writeResult(req, { status = 'error', code = 'guard_expired', message = '令牌校验失败，请重试' })
        rotateGuard()
        return nil
    end
    return req
end

local function executeRequest(req)
    local action = tostring(req.action)
    local path = normalizePath(req.path)

    if action == 'list' then return listDir(path) end
    if action == 'info' then return statFile(path) end
    if action == 'text' then return readTextFile(path, req.limit) end
    if action == 'hex' then return readHexFile(path, req.offset, req.length) end
    if action == 'write' then return writeTextFile(path, req.content) end
    if action == 'mkdir' then return makeDirectory(path) end
    if action == 'rename' then return renameItem(path, req.name) end
    if action == 'copy' then return copyItem(path, req.dest) end
    if action == 'move' then return moveItem(path, req.dest) end
    if action == 'delete' then return deleteItem(path) end
    if action == 'search' then return searchFiles(path, req.keyword) end
    if action == 'image' then return imagePreview(path, req.seq) end
    if action == 'storage' then return storageInfo() end
    return { status = 'error', code = 'unknown_action', message = '未知操作：' .. action }
end

local pollTimer = nil
local heartbeatTimer = nil

local function checkRequest()
    if busy or not serviceRunning then return end

    local req = readRequest()
    if not req then return end

    busy = true
    local ok, result = pcall(executeRequest, req)
    if not ok then
        result = { status = 'error', code = 'exception', message = tostring(result) }
    end

    stats.requests = stats.requests + 1
    stats.lastAction = tostring(req.action or '-')
    stats.lastStatus = result.status or 'error'
    stats.lastPath = tostring(req.path or '-')
    addLog(tostring(req.action or '?') .. ' ' .. stats.lastStatus)

    writeResult(req, result)
    rotateGuard()
    writeHeartbeat()
    busy = false
end

local function startService()
    if serviceRunning then return end
    if not resolveTargetDir() then
        addLog('未找到轻应用目录')
    end
    mkdirp(TARGET_DIR)
    serviceRunning = true
    rotateGuard()
    writeHeartbeat()

    if not pollTimer then
        pollTimer = lvgl.Timer({ period = POLL_MS, repeat_count = -1, cb = function() checkRequest() end })
        pollTimer:resume()
    end
    if not heartbeatTimer then
        heartbeatTimer = lvgl.Timer({
            period = HEARTBEAT_MS,
            repeat_count = -1,
            cb = function() if serviceRunning then writeHeartbeat() end end
        })
        heartbeatTimer:resume()
    end
    addLog('服务已启动')
end

local function stopService()
    if not serviceRunning then return end
    serviceRunning = false
    if pollTimer then pollTimer:pause() end
    if heartbeatTimer then heartbeatTimer:pause() end
    addLog('服务已停止')
end

-- =====================================================================
-- 7. 表盘 UI
-- =====================================================================

local root = lvgl.Object(nil, {
    x = 0, y = 0,
    w = SCREEN_W, h = SCREEN_H,
    bg_color = UI_BG,
    border_width = 0,
    pad_all = 0
})
root:clear_flag(lvgl.FLAG.SCROLLABLE)
root:add_flag(lvgl.FLAG.EVENT_BUBBLE)

local currentPage = 'home'
local timeLabel = nil
local spriteCells = nil
local spriteFrame = 0
local statusCard = nil
local logArea = nil
local toggleBtn = nil
local toggleLabel = nil

-- 表盘像素精灵：文件夹轮廓 + 逐行扫描高光
local SPRITE_MAP = {
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
}

local function spriteLit(row, col)
    local line = SPRITE_MAP[row]
    if not line then return false end
    return string.sub(line, col, col) == 'O'
end

local function buildSprite(box)
    spriteCells = {}
    local spanW = SPRITE_COLS * SPRITE_CELL
    local spanH = SPRITE_ROWS * SPRITE_CELL
    local originX = math.floor((SCREEN_W - spanW) / 2)
    local originY = math.floor((math.floor(SCREEN_H / 2) - spanH) / 2)
    for r = 1, SPRITE_ROWS do
        for c = 1, SPRITE_COLS do
            local cell = lvgl.Object(box, {
                x = originX + (c - 1) * SPRITE_CELL,
                y = originY + (r - 1) * SPRITE_CELL,
                w = SPRITE_CELL, h = SPRITE_CELL,
                bg_color = UI_PRIMARY,
                bg_opa = 0,
                border_width = 0,
                radius = 0,
                pad_all = 0
            })
            cell:clear_flag(lvgl.FLAG.SCROLLABLE)
            cell:add_flag(lvgl.FLAG.EVENT_BUBBLE)
            spriteCells[(r - 1) * SPRITE_COLS + c] = cell
        end
    end
end

local function renderSprite()
    if not spriteCells then return end
    local scan = (math.floor(spriteFrame / 2) % SPRITE_ROWS) + 1
    for i = 1, #spriteCells do
        local cell = spriteCells[i]
        if cell then
            local row = math.floor((i - 1) / SPRITE_COLS) + 1
            local col = ((i - 1) % SPRITE_COLS) + 1
            local opa = 0
            if spriteLit(row, col) then
                opa = (row == scan) and 55 or 100
            end
            cell:set({ bg_opa = opa })
        end
    end
end

local function updateClock()
    if timeLabel then
        timeLabel:set({ text = os.date('%H:%M') })
    end
end

--- 深灰圆角卡片：可选副标题、可点击
local function makeCard(parent, x, y, w, h, title, subtitle, bgColor, cb)
    local card = lvgl.Object(parent, {
        x = x, y = y, w = w, h = h,
        bg_color = bgColor or UI_CARD,
        radius = UI_RADIUS,
        border_width = 0,
        pad_all = 0
    })
    card:clear_flag(lvgl.FLAG.SCROLLABLE)
    if cb then
        card:add_flag(lvgl.FLAG.CLICKABLE)
        card:onevent(lvgl.EVENT.CLICKED, cb)
    end

    local titleY = subtitle and 12 or math.floor((h - 34) / 2)
    local titleLabel = lvgl.Label(card, {
        x = 18, y = titleY, w = w - 36, h = 34,
        text = title or '',
        text_font = lvgl.Font('MiSans-Regular', 26),
        text_color = UI_TEXT
    })
    titleLabel:add_flag(lvgl.FLAG.EVENT_BUBBLE)

    if subtitle and subtitle ~= '' then
        local subLabel = lvgl.Label(card, {
            x = 18, y = titleY + 34, w = w - 36, h = 26,
            text = subtitle,
            text_font = lvgl.Font('MiSans-Regular', 18),
            text_color = UI_DIM
        })
        subLabel:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    end
    return card
end

--- 胶囊按钮，返回按钮对象与内部标签（便于动态改文案/配色）
local function makePill(parent, x, y, w, h, text, bgColor, cb)
    local btn = lvgl.Object(parent, {
        x = x, y = y, w = w, h = h,
        bg_color = bgColor or UI_CARD,
        radius = math.floor(h / 2),
        border_width = 0,
        pad_all = 0
    })
    btn:clear_flag(lvgl.FLAG.SCROLLABLE)
    btn:add_flag(lvgl.FLAG.CLICKABLE)
    local label = lvgl.Label(btn, {
        align = lvgl.ALIGN.CENTER,
        text = text or '',
        text_font = lvgl.Font('MiSans-Regular', 26),
        text_color = UI_TEXT
    })
    label:add_flag(lvgl.FLAG.EVENT_BUBBLE)
    if cb then
        btn:onevent(lvgl.EVENT.CLICKED, cb)
    end
    return btn, label
end

local buildHomePage, buildServicePage

buildHomePage = function()
    currentPage = 'home'
    statusCard, logArea, toggleBtn, toggleLabel = nil, nil, nil, nil
    root:clean()

    timeLabel = lvgl.Label(root, {
        x = 0, y = math.floor((math.floor(SCREEN_H / 2) - 110) / 2),
        text = os.date('%H:%M'),
        text_font = lvgl.Font('MiSans-Regular', 120),
        text_color = UI_TEXT,
        align = lvgl.ALIGN.TOP_MID
    })

    local box = lvgl.Object(root, {
        x = 0, y = math.floor(SCREEN_H / 2),
        w = SCREEN_W, h = math.floor(SCREEN_H / 2),
        bg_opa = 0, border_width = 0, pad_all = 0
    })
    box:clear_flag(lvgl.FLAG.SCROLLABLE)
    box:add_flag(lvgl.FLAG.CLICKABLE)
    box:onevent(lvgl.EVENT.CLICKED, function() buildServicePage() end)

    buildSprite(box)
    spriteFrame = 0
    renderSprite()
    updateClock()
end

buildServicePage = function()
    currentPage = 'service'
    timeLabel, spriteCells = nil, nil
    root:clean()

    makePill(root, UI_GAP, UI_GAP, 44, 44, '‹', UI_CARD, function()
        buildHomePage()
    end)

    lvgl.Label(root, {
        x = 0, y = 18, w = SCREEN_W, h = 34,
        text = '文件后端',
        text_font = lvgl.Font('MiSans-Regular', 30),
        text_color = UI_TEXT,
        align = lvgl.ALIGN.TOP_MID
    })

    local cardY = UI_TOPBAR + UI_GAP
    local cardH = 128
    statusCard = makeCard(root, UI_GAP, cardY, SCREEN_W - UI_GAP * 2, cardH,
        serviceRunning and '运行中' or '已停止',
        PRODUCT_NAME,
        serviceRunning and UI_CARD or UI_DANGER)

    local rowW = math.floor((SCREEN_W - UI_GAP * 3) / 2)
    local rowsY = cardY + cardH + UI_GAP
    makeCard(root, UI_GAP, rowsY, rowW, 96, '已处理', tostring(stats.requests), UI_CARD)
    makeCard(root, UI_GAP * 2 + rowW, rowsY, rowW, 96, '已拒绝', tostring(stats.rejected), UI_CARD)

    local logY = rowsY + 96 + UI_GAP
    local btnH = 48
    local logH = SCREEN_H - logY - UI_GAP - btnH - UI_GAP
    logArea = lvgl.Textarea(root, {
        x = UI_GAP, y = logY,
        w = SCREEN_W - UI_GAP * 2, h = logH,
        text = '',
        bg_color = UI_CARD,
        radius = UI_RADIUS,
        text_font = lvgl.Font('MiSans-Regular', 18),
        text_color = UI_TERM,
        border_width = 0,
        pad_all = 12
    })
    logArea:add_flag(lvgl.FLAG.SCROLLABLE)
    if #logBuffer > 0 then
        logArea:set({ text = table.concat(logBuffer, '\n') })
    end

    local btnY = SCREEN_H - UI_GAP - btnH
    toggleBtn, toggleLabel = makePill(root, UI_GAP, btnY, rowW, btnH,
        serviceRunning and 'STOP' or 'START',
        serviceRunning and UI_DANGER or UI_PRIMARY,
        function()
            if serviceRunning then stopService() else startService() end
            if toggleLabel then
                toggleLabel:set({ text = serviceRunning and 'STOP' or 'START' })
            end
            if toggleBtn then
                toggleBtn:set({ bg_color = serviceRunning and UI_DANGER or UI_PRIMARY })
            end
            if statusCard then
                statusCard:set({ bg_color = serviceRunning and UI_CARD or UI_DANGER })
            end
        end)

    makePill(root, UI_GAP * 2 + rowW, btnY, rowW, btnH, '清空', UI_CARD, function()
        logBuffer = {}
        if logArea then logArea:set({ text = '' }) end
    end)
end

-- =====================================================================
-- 8. 启动
-- =====================================================================

math.randomseed(os.time())

local clockTimer = lvgl.Timer({
    period = 1000,
    repeat_count = -1,
    cb = function() updateClock() end
})
clockTimer:resume()

local spriteTimer = lvgl.Timer({
    period = 450,
    repeat_count = -1,
    cb = function()
        if currentPage ~= 'home' or not spriteCells then return end
        spriteFrame = spriteFrame + 1
        renderSprite()
    end
})
spriteTimer:resume()

resolveTargetDir()
buildHomePage()
startService()

--- 亮屏时重置动画：表盘回到前台
function ScreenStateChangedCB(pre, now, reason)
    if pre ~= 'ON' and now == 'ON' and currentPage == 'home' then
        spriteFrame = 0
        renderSprite()
        updateClock()
    end
end

-- ====== 测试钩子 =====
-- 仅在 scripts/test-lua-backend.lua 设置了 _G.FM_TEST 时导出，
-- 让离线用例能直接驱动内部函数；真机运行不挂任何全局。

if type(_G.FM_TEST) == 'table' then
    local api = {
        jsonEncode = jsonEncode,
        jsonDecode = jsonDecode,
        normalize = normalizePath,
        list = listDir,
        stat = statFile,
        text = readTextFile,
        hex = readHexFile,
        write = writeTextFile,
        mkdir = makeDirectory,
        copy = copyItem,
        move = moveItem,
        rename = renameItem,
        delete = deleteItem,
        search = searchFiles,
        image = imagePreview,
        storage = storageInfo,
        isDir = isDir,
        exists = fileExists,
        size = fileSize,
        rotateGuard = rotateGuard,
        checkRequest = checkRequest,
        stats = stats,
        targetDir = function() return TARGET_DIR end
    }
    _G.__fm = api
end
