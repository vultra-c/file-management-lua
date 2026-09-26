--[[
    Lua 表盘后端的离线冒烟测试
    用最小的 lvgl 桩件在 PC 上跑通 JSON 编解码、一次性令牌校验
    与全部文件操作，无需真机。

    运行：lua5.3 scripts/test-lua-backend.lua
]]

local SCRIPT_DIR = arg[0]:match('^(.*)/[^/]+$') or '.'
local MAIN = SCRIPT_DIR .. '/../watchface/fprj/app/lua/main.lua'
local SANDBOX = '/tmp/fm-sandbox'

-- ====== 断言 ======

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print('  FAIL  ' .. name .. (detail and ('  -> ' .. tostring(detail)) or ''))
    end
end
local function eq(name, got, want)
    check(name, got == want, 'got=' .. tostring(got) .. ' want=' .. tostring(want))
end

-- ====== lvgl 桩件 ======

local timers = {}

_G.lvgl = {
    HOR_RES = function() return 336 end,
    VER_RES = function() return 480 end,
    FLAG = { SCROLLABLE = 1, EVENT_BUBBLE = 2, CLICKABLE = 4 },
    ALIGN = { CENTER = 1, TOP_MID = 2 },
    EVENT = { CLICKED = 1 },
    Font = function(_, size) return { size = size } end,
    Object = function(parent, opts)
        return {
            _opts = opts or {},
            set = function(self, o) for k, v in pairs(o) do self._opts[k] = v end end,
            add_flag = function() end,
            clear_flag = function() end,
            onevent = function() end,
            clean = function() end
        }
    end,
    Timer = function(opts)
        local t = { _opts = opts }
        function t:resume() timers[#timers + 1] = self end
        function t:pause() end
        return t
    end
}
_G.lvgl.Label = _G.lvgl.Object
_G.lvgl.Textarea = _G.lvgl.Object

--- 用 ls -A 模拟 open_dir：目录项按 Shell++ 的约定加前导 '/'
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
_G.lvgl.fs = {
    open_file = function() return nil end,
    open_dir = function(path)
        -- 真机 open_dir 对文件会失败，桩件需先判定是否为目录
        local check = io.popen('test -d ' .. shq(path) .. ' && echo d || echo f', 'r')
        if not check then return nil end
        local isD = check:read('*l')
        check:close()
        if isD ~= 'd' then return nil end

        local f = io.popen('ls -A ' .. shq(path) .. ' 2>/dev/null', 'r')
        if not f then return nil end
        local names = {}
        for line in f:lines() do
            local probe = io.popen('test -d ' .. shq(path .. '/' .. line) .. ' && echo d || echo f', 'r')
            local kind = 'f'
            if probe then
                local r = probe:read('*l')
                probe:close()
                kind = r or 'f'
            end
            names[#names + 1] = (kind == 'd' and '/' or '') .. line
        end
        f:close()
        local i = 0
        local dir = {}
        function dir.read()
            i = i + 1
            return names[i]
        end
        function dir.close() end
        return dir
    end
}

-- ====== 准备沙箱 ======

os.execute('rm -rf ' .. SANDBOX)
os.execute('mkdir -p ' .. SANDBOX .. '/app/docs/nested')
os.execute('mkdir -p ' .. SANDBOX .. '/app/empty')

local HELLO = 'hello lua bridge\nsecond line\n'
local NOTE = 'written by backend'
local fh = assert(io.open(SANDBOX .. '/app/hello.txt', 'w'))
fh:write(HELLO)
fh:close()

fh = assert(io.open(SANDBOX .. '/app/docs/readme.md', 'w'))
fh:write('# docs\n')
fh:close()

fh = assert(io.open(SANDBOX .. '/app/data.bin', 'wb'))
fh:write(string.char(0x48, 0x69, 0x00, 0xFF, 0x0A, 0x41))
fh:close()

-- ====== 加载被测模块 ======

_G.FM_TEST = { targetDir = SANDBOX .. '/ipc/', product = 'Test Device', model = 'T-1' }
assert(loadfile(MAIN))()
local fm = _G.__fm
assert(fm, 'test hooks not exported')

print('target dir = ' .. fm.targetDir())

-- ====== JSON ======

print('== JSON 编解码 ==')
eq('字符串往返', fm.jsonDecode(fm.jsonEncode('a"b\\c\nd')), 'a"b\\c\nd')
eq('中文往返', fm.jsonDecode(fm.jsonEncode('文件管理')), '文件管理')
eq('数字往返', fm.jsonDecode(fm.jsonEncode(1234)), 1234)
eq('浮点往返', fm.jsonDecode(fm.jsonEncode(1.5)), 1.5)
eq('布尔往返', fm.jsonDecode(fm.jsonEncode(true)), true)
eq('nil -> null', fm.jsonEncode(nil), 'null')
eq('数组往返', fm.jsonDecode(fm.jsonEncode({ 1, 2, 3 }))[2], 2)
eq('对象往返', fm.jsonDecode(fm.jsonEncode({ a = 1 })).a, 1)
eq('空表 -> 对象', fm.jsonEncode({}), '{}')
eq('嵌套往返', fm.jsonDecode(fm.jsonEncode({ items = { { name = 'a' } } })).items[1].name, 'a')
eq('控制字符转义', fm.jsonEncode('\1'), '"\\u0001"')
eq('BOM 容错', fm.jsonDecode('\239\187\191{"a":5}').a, 5)
eq('非法 JSON 返回 nil', fm.jsonDecode('{oops'), nil)
eq('空串返回 nil', fm.jsonDecode(''), nil)

-- ====== 路径 ======

print('== 路径规范化 ==')
eq('.. 被折叠', fm.normalize('/data/quickapp/../tmp'), '/data/tmp')
eq('重复斜杠', fm.normalize('/a//b///c'), '/a/b/c')
eq('相对路径补斜杠', fm.normalize('data/x'), '/data/x')
eq('上跳到根', fm.normalize('/..'), '/')
eq('空串为根', fm.normalize(''), '/')
eq('不可逃逸根外', fm.normalize('/../../etc/passwd'), '/etc/passwd')

-- ====== 目录浏览 ======

print('== 目录浏览 ==')
local listing = fm.list(SANDBOX .. '/app')
eq('list ok', listing.status, 'ok')
eq('list 条目数', listing.data.count, 4)
local byName = {}
for _, it in ipairs(listing.data.items) do byName[it.name] = it end
eq('docs 是目录', byName['docs'].isDir, true)
eq('empty 是目录', byName['empty'].isDir, true)
eq('hello.txt 是文件', byName['hello.txt'].isDir, false)
eq('文件大小正确', byName['hello.txt'].sizeBytes, #HELLO)
eq('目录排在最前', listing.data.items[1].isDir, true)
eq('不存在目录报错', fm.list(SANDBOX .. '/nope').status, 'error')

-- ====== 读取 ======

print('== 读取 ==')
local st = fm.stat(SANDBOX .. '/app/hello.txt')
eq('info isDir', st.data.isDir, false)
eq('info size', st.data.sizeBytes, #HELLO)
eq('目录 stat', fm.stat(SANDBOX .. '/app/docs').data.isDir, true)
eq('不存在 stat', fm.stat(SANDBOX .. '/app/nope').code, 'not_found')

local txt = fm.text(SANDBOX .. '/app/hello.txt', 4096)
eq('text 首行', (txt.data.content:gsub('\n.*', '')), 'hello lua bridge')
eq('text 总长', txt.data.totalBytes, #HELLO)
eq('text 截断标记', fm.text(SANDBOX .. '/app/hello.txt', 256).data.truncated, false)

local hx = fm.hex(SANDBOX .. '/app/data.bin', 0, 16)
check('hex 含偏移头', hx.data.content:find('00000000', 1, true) ~= nil, hx.data.content)
check('hex 含 0xFF', hx.data.content:find('FF', 1, true) ~= nil, hx.data.content)
eq('hex 偏移回显', fm.hex(SANDBOX .. '/app/data.bin', 2, 16).data.offset, 2)

-- ====== 写 / 目录 / 改名 / 移动 / 复制 / 删除 ======

print('== 写与目录 ==')
eq('mkdir ok', fm.mkdir(SANDBOX .. '/app/newdir').status, 'ok')
check('目录已创建', fm.isDir(SANDBOX .. '/app/newdir'))
eq('重复 mkdir', fm.mkdir(SANDBOX .. '/app/newdir').code, 'exists')

eq('write ok', fm.write(SANDBOX .. '/app/newdir/notes.txt', NOTE).status, 'ok')
eq('write 后大小', fm.size(SANDBOX .. '/app/newdir/notes.txt'), #NOTE)
eq('write 超长被拒', fm.write(SANDBOX .. '/app/big.txt', string.rep('x', 70000)).code, 'too_large')
eq('write 非法名', fm.write('/app/..', 'x').code, 'bad_name')

print('== 改名 ==')
eq('rename ok', fm.rename(SANDBOX .. '/app/newdir/notes.txt', 'renamed.txt').status, 'ok')
check('新路径存在', fm.exists(SANDBOX .. '/app/newdir/renamed.txt'))
check('旧路径消失', not fm.exists(SANDBOX .. '/app/newdir/notes.txt'))
local clash = assert(io.open(SANDBOX .. '/app/newdir/taken.txt', 'w'))
clash:write('x')
clash:close()
eq('rename 目标重名', fm.rename(SANDBOX .. '/app/newdir/renamed.txt', 'taken.txt').code, 'exists')
eq('rename 同名幂等', fm.rename(SANDBOX .. '/app/newdir/renamed.txt', 'renamed.txt').status, 'ok')
eq('rename 含斜杠', fm.rename(SANDBOX .. '/app/newdir/renamed.txt', 'a/b').code, 'bad_name')
eq('rename 点', fm.rename(SANDBOX .. '/app/newdir/renamed.txt', '..').code, 'bad_name')
eq('rename 空名', fm.rename(SANDBOX .. '/app/newdir/renamed.txt', '').code, 'bad_name')

print('== 复制 / 移动 ==')
local cp = fm.copy(SANDBOX .. '/app/newdir/renamed.txt', SANDBOX .. '/app/docs')
eq('copy ok', cp.status, 'ok')
check('copy 目标带原名', cp.data.dest:find('renamed%.txt$') ~= nil, cp.data.dest)
check('copy 源仍在', fm.exists(SANDBOX .. '/app/newdir/renamed.txt'))
local cp2 = fm.copy(SANDBOX .. '/app/newdir/renamed.txt', SANDBOX .. '/app/docs')
check('copy 重名自动加后缀', cp2.data.dest:find('renamed%(1%)%.txt$') ~= nil, cp2.data.dest)
eq('copy 目标不存在', fm.copy(SANDBOX .. '/app/newdir/renamed.txt', SANDBOX .. '/app/nope').code, 'bad_dest')
eq('copy 源不存在', fm.copy(SANDBOX .. '/app/nope.txt', SANDBOX .. '/app').code, 'not_found')

local mv = fm.move(SANDBOX .. '/app/newdir/renamed.txt', SANDBOX .. '/app/empty')
eq('move ok', mv.status, 'ok')
check('move 源消失', not fm.exists(SANDBOX .. '/app/newdir/renamed.txt'))
check('move 目标出现', fm.exists(SANDBOX .. '/app/empty/renamed.txt'))

print('== 删除 ==')
eq('delete ok', fm.delete(SANDBOX .. '/app/empty/renamed.txt').status, 'ok')
check('delete 后消失', not fm.exists(SANDBOX .. '/app/empty/renamed.txt'))
eq('删除根目录被拒', fm.delete('/').code, 'forbidden')
eq('删除不存在', fm.delete(SANDBOX .. '/app/nope').code, 'not_found')

print('== 递归 ==')
eq('复制目录 ok', fm.copy(SANDBOX .. '/app/docs', SANDBOX .. '/app/empty').status, 'ok')
check('子目录已复制', fm.isDir(SANDBOX .. '/app/empty/docs/nested'))
eq('嵌套文件已复制', fm.stat(SANDBOX .. '/app/empty/docs/nested').status, 'ok')
eq('递归删除 ok', fm.delete(SANDBOX .. '/app/empty/docs').status, 'ok')
check('递归目录已删除', not fm.isDir(SANDBOX .. '/app/empty/docs'))
eq('递归删除新目录', fm.delete(SANDBOX .. '/app/newdir').status, 'ok')
check('新目录已删除', not fm.isDir(SANDBOX .. '/app/newdir'))

-- ====== 搜索 ======

print('== 搜索 ==')
-- 用一棵独立的干净目录树做搜索，避免被前面的用例污染
local TREE = SANDBOX .. '/tree'
os.execute('mkdir -p ' .. TREE .. '/a/b/c')
for _, p in ipairs({ TREE .. '/notes.md', TREE .. '/a/readme.md', TREE .. '/a/b/readme.txt', TREE .. '/a/b/c/deep.txt' }) do
    local f = assert(io.open(p, 'w'))
    f:write('x')
    f:close()
end

eq('搜索命中 2 条', fm.search(TREE, 'readme').data.count, 2)
eq('搜索递归到深层', fm.search(TREE, 'deep').data.count, 1)
eq('搜索大小写不敏感', fm.search(TREE, 'README').data.count, 2)
eq('搜索目录也命中', fm.search(TREE, 'a').data.count >= 1, true)
eq('搜索无结果', fm.search(TREE, 'zzzz').data.count, 0)
eq('空关键字报错', fm.search(TREE, '').code, 'bad_keyword')
eq('范围不存在报错', fm.search(SANDBOX .. '/nope', 'x').code, 'bad_root')

-- ====== IPC 令牌 ======

print('== IPC 令牌校验 ==')
local ipc = fm.targetDir()
os.execute('mkdir -p ' .. ipc)
fm.rotateGuard()

local function readJson(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return fm.jsonDecode(s or '')
end

local function writeJson(path, data)
    local f = assert(io.open(path, 'w'))
    f:write(fm.jsonEncode(data))
    f:close()
end

local guard = readJson(ipc .. 'fm_guard.json')
check('守卫文件已生成', guard ~= nil and type(guard.token) == 'string', guard)
eq('守卫类型', guard.type, 'ipc_guard')

-- 无令牌请求必须被拒绝
writeJson(ipc .. 'fm_request.json', { seq = 1, action = 'list', path = SANDBOX .. '/app' })
fm.checkRequest()
eq('无令牌请求被拒', readJson(ipc .. 'fm_result.json').code, 'guard_expired')
eq('被拒后请求文件已删', readJson(ipc .. 'fm_request.json'), nil)
eq('被拒计数', fm.stats.rejected, 1)

-- 令牌已轮换，旧令牌再试依然被拒
local rotated = readJson(ipc .. 'fm_guard.json')
check('令牌已轮换', rotated.token ~= guard.token)
local token = rotated.token

-- 带正确令牌的请求应成功
writeJson(ipc .. 'fm_request.json', {
    seq = 2, action = 'list', path = SANDBOX .. '/tree', guard = token
})
fm.checkRequest()
local res = readJson(ipc .. 'fm_result.json')
eq('合法请求成功', res.status, 'ok')
eq('结果 seq 匹配', res.seq, 2)
eq('结果含条目', res.data.count, 2)
eq('目录优先排序', res.data.items[1].isDir, true)
eq('已处理计数', fm.stats.requests, 1)

-- 执行后令牌必须再次轮换（旧令牌不可复用）
local after = readJson(ipc .. 'fm_guard.json')
check('执行后令牌轮换', after.token ~= token)
writeJson(ipc .. 'fm_request.json', {
    seq = 3, action = 'list', path = SANDBOX .. '/app', guard = token
})
fm.checkRequest()
eq('重放旧令牌被拒', readJson(ipc .. 'fm_result.json').code, 'guard_expired')
eq('被拒计数递增', fm.stats.rejected, 2)

-- 未知操作
local fresh = readJson(ipc .. 'fm_guard.json')
writeJson(ipc .. 'fm_request.json', {
    seq = 4, action = 'rm -rf /', path = '/', guard = fresh.token
})
fm.checkRequest()
eq('未知操作被拒', readJson(ipc .. 'fm_result.json').code, 'unknown_action')

-- 异常兜底不崩
local fresh2 = readJson(ipc .. 'fm_guard.json')
writeJson(ipc .. 'fm_request.json', { seq = 5, action = 'list', guard = fresh2.token })
fm.checkRequest()
eq('缺 path 走默认根目录', readJson(ipc .. 'fm_result.json').status, 'ok')

-- 坏 JSON 请求不应导致崩溃
local before = fm.stats.requests
local raw = io.open(ipc .. 'fm_request.json', 'w')
raw:write('{ broken')
raw:close()
fm.checkRequest()
eq('坏 JSON 被忽略', fm.stats.requests, before)

-- 心跳
local hb = readJson(ipc .. 'fm_heartbeat.json')
check('心跳已写入', hb ~= nil and hb.type == 'heartbeat', hb)
eq('心跳带设备型号', hb.product, 'Test Device')

-- 图片预览
local info = fm.storage()
eq('storage 产品名', info.data.product, 'Test Device')
eq('非图片被拒', fm.image(SANDBOX .. '/app/hello.txt', 1).code, 'bad_type')

--
print()
print(string.format('通过 %d，失败 %d', passed, failed))
os.exit(failed == 0 and 0 or 1)
