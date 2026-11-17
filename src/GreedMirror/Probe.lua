-- GreedMirror 贪婪镜 - Probe.lua
-- /greed probe：自检输出。
-- 目的：确认目标客户端（魔兽世界：无限 / Interface 16001）上
--   1) 暴雪接口是否存在；
--   2) 三个统计 ID（1044 / 1043 / 932）读出来是什么、名字对不对；
--   3) 若 ID 失效，按名称自动发现能否找到替代项；
--   4) 缓存与扫描状态。
local ADDON, GM = ...

local Probe = {}
GM.Probe = Probe

local Stats, DB, Scan = GM.Stats, GM.DB, GM.Scan

local function out(text)
    GM.Print(text)
end

local function mark(ok)
    return ok and "可用" or "缺失"
end

local API_LIST = {
    { name = "GetStatistic", fn = "GetStatistic", note = "读取自己的统计" },
    { name = "GetComparisonStatistic", fn = "GetComparisonStatistic", note = "读取比较对象的统计" },
    { name = "SetAchievementComparisonUnit", fn = "SetAchievementComparisonUnit", note = "设置成就比较对象（读别人的唯一入口）" },
    { name = "ClearAchievementComparisonUnit", fn = "ClearAchievementComparisonUnit", note = "清除比较对象" },
    { name = "GetAchievementInfo", fn = "GetAchievementInfo", note = "取统计项名称（用于校验 ID）" },
    { name = "GetStatisticsCategoryList", fn = "GetStatisticsCategoryList", note = "统计分类列表（用于按名称发现 ID）" },
    { name = "GetCategoryNumAchievements", fn = "GetCategoryNumAchievements", note = "分类下统计项数量" },
    { name = "GetNumGroupMembers", fn = "GetNumGroupMembers", note = "小队人数（/greed party）" },
    { name = "IsInRaid", fn = "IsInRaid", note = "是否团队" },
    { name = "InCombatLockdown", fn = "InCombatLockdown", note = "战斗状态（战斗中不自动查询）" },
}

local function clientInfo()
    out("—— 客户端 ——")
    if type(GetBuildInfo) == "function" then
        local ok, version, build, date, toc = pcall(GetBuildInfo)
        if ok then
            out(string.format("版本 %s（构建 %s，日期 %s，TOC %s）", tostring(version), tostring(build),
                tostring(date), tostring(toc)))
        end
    end
    out("插件版本 " .. tostring(GM.VERSION) .. "，接口号 16001")
end

local function apiInfo()
    out("—— 接口可用性 ——")
    for _, entry in ipairs(API_LIST) do
        out(string.format("  %s：%s（%s）", entry.name, mark(type(_G[entry.fn]) == "function"), entry.note))
    end
    out("  Settings（现代设置页 API）：" .. mark(type(_G.Settings) == "table"))
    out("  TooltipDataProcessor：" .. mark(type(_G.TooltipDataProcessor) == "table"))
    out("  比较链路整体：" .. mark(Scan.HasAPI()))
end

local function statLine(label, id)
    local name = Stats.StatName(id)
    local raw, skip, rawId
    if type(GetStatistic) == "function" then
        local ok, a, b, c = pcall(GetStatistic, id)
        if ok then raw, skip, rawId = a, b, c end
    end
    local value, quality = Stats.ParseCount(raw)
    local valueText = value and tostring(value) or ("不可读(" .. tostring(quality) .. ")")
    out(string.format("  %s：ID %s | 名称 %s | 原始值 %s | 解析 %s | skip %s",
        label, tostring(id), tostring(name or "无"), tostring(raw), valueText, tostring(skip)))
end

local function idsInfo()
    out("—— 三个统计项 ——")
    statLine("需求 N", GM.STAT.need)
    statLine("贪婪 G", GM.STAT.greed)
    statLine("进本 E", GM.STAT.dungeons)

    local resolved = Stats.ResolveIDs()
    out("  ID 来源：" .. tostring(resolved.source)
        .. (resolved.conflicted and "（默认 ID 与名称冲突，已尝试自动发现）" or ""))
    for _, field in ipairs({ "need", "greed", "dungeons" }) do
        out(string.format("  校验 %s：%s", field, tostring(resolved.verify[field])))
    end
    if resolved.source == "discovered" then
        out("  实际使用：" .. string.format("需求 %s / 贪婪 %s / 进本 %s",
            tostring(resolved.ids.need), tostring(resolved.ids.greed), tostring(resolved.ids.dungeons)))
    end
end

local function discoverInfo()
    out("—— 按名称自动发现（兜底）——")
    local index = Stats.BuildStatIndex()
    out("  统计树条目数：" .. tostring(#index.entries))
    local discovered = Stats.DiscoverIDs()
    for _, field in ipairs({ "need", "greed", "dungeons" }) do
        local hit = discovered[field]
        if hit then
            out(string.format("  %s：ID %s（%s）", field, tostring(hit.id), tostring(hit.name)))
        else
            out(string.format("  %s：未找到", field))
        end
    end
end

-- 阵营判定自检：解释「为什么这个玩家插件没反应」
-- 同阵营才生效；敌对玩家会被完全忽略（不查询、不显示、不写名单）
local function factionInfo()
    out("—— 阵营判定 ——")
    local myGroup = "?"
    if type(UnitFactionGroup) == "function" then
        local ok, group = pcall(UnitFactionGroup, "player")
        if ok and type(group) == "string" then myGroup = group end
    end
    out("  我的阵营：" .. tostring(myGroup))
    for _, unit in ipairs({ "player", "target", "mouseover" }) do
        if UnitExists(unit) then
            local _, name = pcall(UnitName, unit)
            local _, group = pcall(UnitFactionGroup, unit)
            local _, isEnemy = pcall(UnitIsEnemy, unit, "player")
            local relation = "friendly"
            if type(Stats.FactionRelation) == "function" then
                relation = Stats.FactionRelation(unit)
            end
            out(string.format("  %s：%s | 阵营 %s | 敌对 %s | 判定 %s",
                unit, tostring(name), tostring(group), tostring(isEnemy), tostring(relation)))
        end
    end
    out("  说明：判定 hostile（敌对）的玩家，插件不会显示提示框、也不会查统计。")
end

local function stateInfo()
    out("—— 运行状态 ——")
    local debug = Scan.Debug()
    out(string.format("  扫描状态 %s | 队列 %d | 超时次数 %d | 缓存条目 %d",
        tostring(debug.state), debug.queue, debug.timeouts, debug.cache))
    out("  查询间隔：" .. tostring(DB.Interval()) .. " 秒")
    out("  名单条目：" .. tostring(DB.WatchCount()))
    out("  设置：" .. string.format("插件=%s 提示框=%s 自身数据=%s 详细=%s 队伍提示=%s",
        tostring(DB.Get("enabled")), tostring(DB.Get("tooltip")), tostring(DB.Get("selfTooltip")),
        tostring(DB.Get("detail")), tostring(DB.Get("partyAlert"))))
end

function Probe.Run()
    out("=== 贪婪镜自检 ===")
    clientInfo()
    apiInfo()
    idsInfo()
    discoverInfo()
    factionInfo()
    stateInfo()
    out("=== 自检结束 ===")
end

function Probe.Init()
end
