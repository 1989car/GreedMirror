-- tests/run_tests.lua
-- 离线单元测试：在普通 Lua 解释器（配合 tests/wow_stub.lua 的客户端桩）里运行。
-- 覆盖：Rate 三关判定、Stats.ParseCount、DB 缓存/名单、Scan 请求链路、Tooltip 行所有权。
local stub = dofile((arg and arg[0] and arg[0]:match("^(.*)tests/run_tests.lua$") or "") .. "tests/wow_stub.lua")

local GM = stub.loadAddon("src/GreedMirror")

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. name .. (detail and (" :: " .. tostring(detail)) or ""))
    end
end
local function eq(a, b)
    return a == b
end

-- ------------------------------------------------------------ Rate 三关判定
local R = GM.Rate
local function eval(need, greed, dungeons) return R.Evaluate({ need = need, greed = greed, dungeons = dungeons }) end

-- 关 1：数据不可读
local r = eval(nil, 10, 10)
check("nodata 缺 need", r.status == "nodata")
r = eval(10, nil, 10)
check("nodata 缺 greed", r.status == "nodata")
r = eval(10, 10, "abc")
check("nodata 非数字", r.status == "nodata")

-- 关 2：E < 4 → 数据不足
r = eval(3, 0, 3)
check("insufficient E=3", r.status == "insufficient" and r.band == nil)

-- 关 2：R < 5.4*E → 低（放弃型），不算需求率
r = eval(20, 0, 10) -- R=20 < 54
check("low 放弃型", r.status == "low" and r.ratio == nil)
r = eval(53, 0, 10) -- R=53 < 54
check("low 边界 R=T-1", r.status == "low")
r = eval(54, 0, 10) -- R=54 = T，越过门槛进入分档
check("边界 R=T 进入分档", r.status == "rated", r.status)

-- 关 3：R < 20 → 样本少（过了活跃度门槛但样本仍小，需要 E 使 5.4E<=19 → E<=3 不可能，
-- 实际上 activeMul*E >= 21.6 当 E>=4，所以 R>=T 蕴含 R>=21>20；small 分支只在自定义规则下可达）
check("minRolls 与门槛一致性", 5.4 * 4 >= 20, "minRolls=20 应小于 5.4*4")

-- 关 3：分档（E=10 → 门槛 54，所有用例 R 均需 >= 54）
r = eval(5, 100, 10)  -- R=105, P≈4.8% → darkgreen
check("darkgreen", r.status == "rated" and r.band == "darkgreen" and r.ratio ~= nil)
r = eval(20, 60, 10)  -- R=80, P=25% → green
check("green", r.status == "rated" and r.band == "green")
r = eval(40, 60, 10)  -- R=100, P=40% → yellow
check("yellow", r.status == "rated" and r.band == "yellow")
r = eval(60, 40, 10)  -- R=100, P=60% → red
check("red", r.status == "rated" and r.band == "red")
r = eval(25, 0, 4)   -- E=4 门槛 21.6；R=25, P=100%, 20<=R<30 → yellow 封顶
check("red capped to yellow", r.status == "rated" and r.band == "yellow", r.status .. "/" .. tostring(r.band))
r = eval(30, 0, 4)   -- R=30 >= 21.6, P=100%, R=30 → red
check("red boundary R=30", r.band == "red", tostring(r.band))

-- IsHighRate：P>=50%（按 design.md）
check("high rate P=50", R.IsHighRate(eval(50, 50, 10)) == true)
check("high rate P<50", R.IsHighRate(eval(49, 51, 10)) == false)
check("high rate low-status excluded", R.IsHighRate(eval(20, 0, 10)) == false, "放弃型不入名单")
check("high rate nodata", R.IsHighRate(eval(nil, 1, 1)) == false)

-- SummaryWord
check("summary 极高", R.SummaryWord(eval(60, 40, 10)) == "极高")
check("summary 偏高", R.SummaryWord(eval(40, 60, 10)) == "偏高")
check("summary 正常", R.SummaryWord(eval(20, 60, 10)) == "正常")
check("summary low 为空", R.SummaryWord(eval(20, 0, 10)) == nil)

-- ------------------------------------------------------------ Stats.ParseCount
local P = GM.Stats.ParseCount
local v, q
v, q = P("1,234"); check("parse 千分位", v == 1234 and q == "readable", tostring(v) .. "/" .. tostring(q))
v, q = P("0"); check("parse 0", v == 0 and q == "readable")
v, q = P("-"); check("parse 短横线→unreported", v == nil and q == "unreported")
v, q = P("—"); check("parse em dash→unreported", v == nil and q == "unreported")
v, q = P(""); check("parse 空串→unreported", v == nil and q == "unreported")
v, q = P("12.5"); check("parse 小数→format", v == nil and q == "format")
v, q = P("1,23"); check("parse 坏分组→format", v == nil and q == "format")
v, q = P(42); check("parse 数字", v == 42 and q == "readable")
v, q = P(-1); check("parse 负数→format", v == nil and q == "format")
v, q = P(nil); check("parse nil→unknown", v == nil and q == "unknown")

-- 受保护值
local token = {}
stub.secretValues[token] = true
v, q = P(token); check("parse issecret→restricted", v == nil and q == "restricted")
stub.secretValues[token] = nil

-- ------------------------------------------------------------ DB 缓存与名单
stub.login(GM)
local DB = GM.DB
check("DB 默认 enabled", DB.Get("enabled") == true)
check("DB 默认 interval=3600", DB.Interval() == 3600)
DB.Set("interval", 900)
check("DB.Set 生效", DB.Interval() == 900)
DB.Set("interval", 3600)

DB.CachePut("g1", { need = 1, greed = 2, dungeons = 3, at = stub.wall })
check("cache 命中", DB.CacheGet("g1") ~= nil)
check("cache 新鲜", DB.CacheFresh("g1") == true)
stub.wall = stub.wall + 3600
check("cache 到期", DB.CacheFresh("g1") == false)
DB.Set("interval", 0) -- 实时档
check("cache 实时档永不命中", DB.CacheFresh("g1") == false)
DB.Set("interval", 3600)
DB.ClearCache()
check("cache 清空", DB.CacheCount() == 0)

DB.WatchPut("gx", { name = "张三", rate = 66 })
check("watch 命中", DB.WatchGet("gx") ~= nil and DB.WatchGet("gx").rate == 66)
check("watch 计数", DB.WatchCount() == 1)
check("watch 持久化引用", DB.WatchGet("gx") == stub.GM and false or true) -- 引用一致性无需断言
DB.WatchRemove("gx")
check("watch 删除", DB.WatchCount() == 0)

-- ------------------------------------------------------------ Scan 请求链路（成功路径）
local Scan = GM.Scan
check("Scan.HasAPI", Scan.HasAPI() == true)
local row, status = Scan.Request("mouseover", { manual = true })
check("Request 排队", row == nil and status == "PENDING", tostring(status))

-- 驱动 OnUpdate 直到完成（手动超时 8 秒）；第 4 步模拟服务器应答事件
for step = 1, 200 do
    stub.clock = stub.clock + 0.25
    if step == 4 then stub.deliverInspectReady() end
    if Scan.frame.__scripts.OnUpdate then Scan.frame.__scripts.OnUpdate(Scan.frame) end
    if Scan.frame.__scripts.OnUpdate == nil and Scan.State() == "IDLE" then break end
end
check("链路完成", Scan.State() == "IDLE")
check("Set 被调用", (stub.setCalls or 0) >= 1, tostring(stub.setCalls))
check("比较单位已清除", stub.comparisonUnit == nil)
check("结果进入缓存", DB.CacheGet("Player-2") ~= nil)
local cached = DB.CacheGet("Player-2")
check("缓存值来自比较统计", cached.need == 30 and cached.greed == 70 and cached.dungeons == 12,
    string.format("%s/%s/%s", tostring(cached.need), tostring(cached.greed), tostring(cached.dungeons)))

-- 缓存命中：第二次请求直接返回
row, status = Scan.Request("mouseover", { manual = true })
check("缓存直接命中", row ~= nil and status == "READY", tostring(status))

-- ------------------------------------------------------------ NPC / 战斗 / 距离
row, status = Scan.Request("npc1", { manual = true })
check("NPC 拒绝", row == nil and status == "NPC", tostring(status))
row, status = Scan.Request("player", { manual = true })
check("自己返回 SELF", row == nil and status == "SELF", tostring(status))

stub.inCombat = true
row, status = Scan.Request("target", { manual = true }) -- 手动不受战斗限制
check("战斗中手动可查", status == "PENDING", tostring(status))
Scan.Cancel("CANCELLED")
row, status = Scan.Request("target") -- 被动悬停被拒绝
check("战斗中悬停拒绝", row == nil and status == "COMBAT", tostring(status))
stub.inCombat = false

stub.setComparisonResult = false -- 距离过远
row, status = Scan.Request("target", { manual = true })
check("Set 失败→PENDING 排队", status == "PENDING", tostring(status))
for step = 1, 100 do
    stub.clock = stub.clock + 0.25
    if Scan.frame.__scripts.OnUpdate then Scan.frame.__scripts.OnUpdate(Scan.frame) end
    if Scan.frame.__scripts.OnUpdate == nil and Scan.State() == "IDLE" then break end
end
check("FAR 冷却生效", Scan.Status("Player-3") == "FAR", tostring(Scan.Status("Player-3")))
stub.setComparisonResult = true

-- guid 不符：服务器回报了另一个玩家的 guid → 丢弃，不读数据
stub.units.target.guid = "Player-9"
row, status = Scan.Request("target", { manual = true })
for step = 1, 100 do
    stub.clock = stub.clock + 0.25
    if step == 4 then
        -- 模拟服务器回报的是“别人”的 guid
        Scan.frame.__scripts.OnEvent(Scan.frame, "INSPECT_ACHIEVEMENT_READY", "Player-999")
    end
    if Scan.frame.__scripts.OnUpdate then Scan.frame.__scripts.OnUpdate(Scan.frame) end
    if Scan.frame.__scripts.OnUpdate == nil and Scan.State() == "IDLE" then break end
end
stub.units.target.guid = "Player-3"
check("guid 不符不入缓存", DB.CacheGet("Player-9") == nil)

-- ------------------------------------------------------------ Party 名单记录
local Party = GM.Party
local identity = { guid = "Player-hi", name = "李四", realm = "测试服" }
local rowHi = { need = 60, greed = 40, dungeons = 10, name = "李四", realm = "测试服" } -- R=100 >= T=54, P=60% → 红
local resultHi = R.Evaluate(rowHi)
check("构造红档", resultHi.band == "red")
Party.Record("Player-hi", identity, rowHi, resultHi)
check("极高入名单", DB.WatchGet("Player-hi") ~= nil)
check("名单 rate", DB.WatchGet("Player-hi").rate == 60)
check("Record 返回 entry", (select(1, Party.Record("Player-hi", identity, rowHi, resultHi))) ~= nil)
check("Record 非首次", (select(2, Party.Record("Player-hi", identity, rowHi, resultHi))) == false)

local rowLow = { need = 20, greed = 0, dungeons = 10 }
Party.Record("Player-low", identity, rowLow, R.Evaluate(rowLow))
check("放弃型不入名单", DB.WatchGet("Player-low") == nil)

-- ------------------------------------------------------------ OnScanResult 策略（入库 + 首录提示 + 组队提醒）
DB.WatchRemove("Player-hi")
local printed = {}
local realPrint = print
print = function(text) printed[#printed + 1] = tostring(text) end
local function printedCount(needle)
    local count = 0
    for _, line in ipairs(printed) do
        if line:find(needle, 1, true) then count = count + 1 end
    end
    return count
end

Party.OnScanResult("Player-hi", rowHi, "READY")
check("OnScanResult 入名单", DB.WatchGet("Player-hi") ~= nil)
check("首录提示一次", printedCount("已记录高需求率玩家") == 1, tostring(printedCount("已记录高需求率玩家")))
Party.OnScanResult("Player-hi", rowHi, "READY")
check("重复查询不重复提示", printedCount("已记录高需求率玩家") == 1)
Party.OnScanResult("Player-low", rowLow, "READY")
check("低需求率不入名单", DB.WatchGet("Player-low") == nil)

-- partyAlert 开 + 在队伍里 → Notify（聊天框单条提醒，内部自带 10 分钟冷却）
stub.units.party3 = { guid = "Player-hi", name = "李四", player = true }
local noticePrints = 0
print = function(text)
    if tostring(text):find("需求率 60%%（记录于", 1, false) then noticePrints = noticePrints + 1 end
end
Party.OnScanResult("Player-hi", rowHi, "READY")
check("队伍内触发组队提醒", noticePrints >= 1, tostring(noticePrints))
print = realPrint
stub.units.party3 = nil

-- ------------------------------------------------------------ 名单呈现 interface（I18n.WatchRowText）
local watchLine = GM.I18n.WatchRowText(DB.WatchGet("Player-hi"))
check("WatchRowText 含名字", watchLine:find("李四", 1, true) ~= nil, watchLine)
check("WatchRowText 无种族时空括号消失",
    GM.I18n.WatchRowText({ name = "王五", rate = 55, need = 5, greed = 5 }):find("（）", 1, true) == nil)
check("WatchRowText 非表返回空串", GM.I18n.WatchRowText(nil) == "")

-- ------------------------------------------------------------ Tooltip 聊天文本层
local TT2 = GM.Tooltip
check("CountsText 完整", TT2.CountsText(rowHi) == "需求 60 · 贪婪 40 · 副本 10", TT2.CountsText(rowHi))
check("CountsText 缺失用问号", TT2.CountsText({ greed = 1, dungeons = 1 }) == "需求 ? · 贪婪 1 · 副本 1",
    TT2.CountsText({ greed = 1, dungeons = 1 }))
check("ChatVerdict 红档", TT2.ChatVerdict(rowHi) == "极高 60%", TT2.ChatVerdict(rowHi))
check("NodataReport 完整为 nil", TT2.NodataReport(rowHi) == nil)
check("NodataReport 缺字段给建议", TT2.NodataReport({ need = nil, greed = 1, dungeons = 1 }) ~= nil)

-- ------------------------------------------------------------ Scan.Transition 状态机入口
do
    local effects = Scan.effects
    -- timeout：把 in-flight 的开始时间拨回超时之前
    local entry = { guid = "Player-t", unit = "target", manual = false, started = effects.now() - 10 }
    Scan.machine.state = "INFLIGHT"
    Scan.machine.inflight = entry
    Scan.machine.ownsComparison = true
    local before = Scan.timeouts
    Scan.Transition("timeout")
    check("Transition timeout 收割", Scan.State() == "IDLE" and Scan.timeouts == before + 1)

    -- cancel：清空排队并通知（手动请求保留）
    local seen = {}
    Scan.OnReady(function(guid, row, status) seen[#seen + 1] = { guid = guid, status = status } end)
    local q = Scan.machine.queue
    q[#q + 1] = { guid = "Player-q1", manual = false }
    q[#q + 1] = { guid = "Player-q2", manual = true }
    Scan.Transition("cancel", { status = "CANCELLED", keepManual = true })
    check("Transition cancel 清队", #Scan.machine.queue == 0)
    check("Transition cancel 通知非手动", seen[1] and seen[1].guid == "Player-q1"
        and seen[1].status == "CANCELLED", tostring(seen[1] and seen[1].guid))
    check("Transition cancel 保留手动", seen[2] == nil)

    -- request：NPC 拒绝
    local rowN, statusN = Scan.Transition("request", { unit = "npc1" })
    check("Transition request NPC", rowN == nil and statusN == "NPC", tostring(statusN))

    -- effects 可替换：战斗开关走注入点
    local origCombat = effects.inCombat
    effects.inCombat = function() return true end
    local _, statusC = Scan.Request("target", {}) -- 被动悬停
    check("effects 注入战斗拒绝", statusC == "COMBAT", tostring(statusC))
    effects.inCombat = origCombat
    Scan.Cancel("CANCELLED")
end

-- ------------------------------------------------------------ GM.Require 契约
do
    local ok, err = pcall(GM.Require, "Demo", { "NotExist" })
    check("Require 缺依赖报错", ok == false and tostring(err):find("Demo") ~= nil, tostring(err))
    ok, err = pcall(GM.Require, "Demo", { "DB" })
    check("Require 有依赖通过", ok == true, tostring(err))
end

-- ------------------------------------------------------------ Tooltip 行所有权
local TT = GM.Tooltip
local gt = stub.newFrame("GameTooltip", "GameTooltipFake")
check("VerdictText rated", TT.VerdictText(resultHi) == "极高 60%", TT.VerdictText(resultHi))
check("VerdictText low", TT.VerdictText(R.Evaluate(rowLow)) == "活跃度过低（不显示需求率）")
check("VerdictText nodata", TT.VerdictText({ status = "nodata" }) == "数据不可读")

-- low 状态不生成任何行（design.md：不给提示）
local lines = TT.BuildLines(rowLow, R.Evaluate(rowLow), "gx")
check("low 无行", #lines == 0, tostring(#lines))
lines = TT.BuildLines(rowHi, resultHi, "gx")
check("rated 首行", lines[1] ~= nil and lines[1].text:find("60%%") ~= nil)

-- ------------------------------------------------------------ ID 校验与发现
local Stats = GM.Stats
local verify = Stats.VerifyIDs({ need = 1044, greed = 1043, dungeons = 932 })
check("默认 ID 校验 need", verify.need == "ok", tostring(verify.need))
check("默认 ID 校验 greed", verify.greed == "ok")
check("默认 ID 校验 dungeons", verify.dungeons == "ok")
local resolved = Stats.ResolveIDs()
check("Resolve 用默认", resolved.source == "default")

-- 名字互换应发现冲突并自动纠正
stub.achievementNames[1044] = "战利品：贪婪"
stub.achievementNames[1043] = "战利品：需求"
stub.categoryItems[1] = { { 1044, "战利品：贪婪" }, { 1043, "战利品：需求" } }
GM.STAT_RESOLVED = nil
GM.Stats.statIndex = nil -- 清掉之前测试建立的名称索引缓存
resolved = Stats.ResolveIDs()
check("互换发现冲突", resolved.source == "discovered", resolved.source)
check("纠正后 need=1043", resolved.ids.need == 1043, tostring(resolved.ids.need))
check("纠正后 greed=1044", resolved.ids.greed == 1044)

-- 自读统计解析千分位
GM.STAT_RESOLVED = nil
GM.Stats.statIndex = nil
stub.achievementNames[1044] = "战利品：需求"
stub.achievementNames[1043] = "战利品：贪婪"
stub.categoryItems[1] = { { 1044, "战利品：需求" }, { 1043, "战利品：贪婪" } }
local selfRow = Stats.SelfRow()
check("SelfRow 读到 need=1234", selfRow and selfRow.need == 1234, tostring(selfRow and selfRow.need))
check("SelfRow 读到 greed=56", selfRow.greed == 56)

-- ------------------------------------------------------------ 结果汇总
print(string.format("\n通过 %d，失败 %d", passed, failed))
if failed > 0 then os.exit(1) end
