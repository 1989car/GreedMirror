-- GreedMirror 贪婪镜 - Stats.lua
-- 读取三个累计统计：1044=需求次数 N、1043=贪婪次数 G、932=进入 5 人副本次数 E。
--
-- 取数链路（客户端只有这一条能读别人）：
--   SetAchievementComparisonUnit(unit) → INSPECT_ACHIEVEMENT_READY(guid)
--   → GetComparisonStatistic(id) → ClearAchievementComparisonUnit()
--
-- 读自己的统计用 GetStatistic(id)。注意 GetStatistic 的第二个返回值 skip 只是
-- “该统计项不在默认 UI 中显示”的标志，并不是“不可读”，因此这里只取 value。
local ADDON, GM = ...

local Stats = {}
GM.Stats = Stats

local DASH = "\226\128\148" -- em dash

local function isCount(v)
    return type(v) == "number" and v == v and v >= 0 and v < math.huge and v == math.floor(v)
end
Stats.IsCount = isCount

-- ------------------------------------------------------------ 安全调用

local function isSecret(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(issecretvalue, value)
    return (not ok) or (secret and true or false)
end
Stats.IsSecret = isSecret

-- 调用暴雪接口；返回值受保护或调用失败时返回 false（调用方一律按“不可读”处理）。
function Stats.SafeCall(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, a, b, c = pcall(fn, ...)
    if not ok or isSecret(a) or isSecret(b) or isSecret(c) then return false end
    return true, a, b, c
end

-- ------------------------------------------------------------ 数值解析

local function trim(text)
    return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 返回 count, quality；quality: readable | unreported | unknown | restricted | format
function Stats.ParseCount(value)
    if isSecret(value) then return nil, "restricted" end
    if type(value) == "number" then
        if value ~= value or value < 0 or value == math.huge or value ~= math.floor(value) then
            return nil, "format"
        end
        return value, "readable"
    end
    if type(value) ~= "string" then return nil, "unknown" end
    local text = trim(value)
    if text == "" or text == "-" or text == "--" or text == DASH then
        return nil, "unreported"
    end
    -- 只接受纯数字或严格的千分位分组（"1,234"）；"1.000" 之类的含义不确定，拒绝。
    if text:find(",", 1, true) then
        local first, rest = text:match("^(%d%d?%d?)(,.*)$")
        if not first then return nil, "format" end
        while #rest > 0 do
            local group, tail = rest:match("^,(%d%d%d)(.*)$")
            if not group then return nil, "format" end
            first, rest = first .. group, tail
        end
        text = first
    end
    if text:match("^%d+$") then
        local count = tonumber(text)
        if count and count >= 0 and count < math.huge and count == math.floor(count) then
            return count, "readable"
        end
    end
    return nil, "format"
end

-- 读取单个统计项。getter 可以是 GetStatistic 或 GetComparisonStatistic。
-- 第二个返回值 skip 被刻意忽略：它只表示“默认 UI 不显示”，不是不可读标志。
function Stats.ReadOne(getter, id)
    if type(getter) ~= "function" then return nil, "api" end
    local ok, value = pcall(getter, id)
    if not ok then return nil, "error" end
    if isSecret(value) then return nil, "restricted" end
    return Stats.ParseCount(value)
end

-- 三个字段各自独立读取，保留各自的 quality。
function Stats.ReadRow(getter)
    local ids = Stats.CurrentIDs()
    local row = { at = time and time() or 0, quality = {}, source = "scan" }
    row.need, row.quality.need = Stats.ReadOne(getter, ids.need)
    row.greed, row.quality.greed = Stats.ReadOne(getter, ids.greed)
    row.dungeons, row.quality.dungeons = Stats.ReadOne(getter, ids.dungeons)
    return row
end

-- 三个字段是否都读到了（任意一个读不到就是“数据不可读”，绝不用 0 代替）。
function Stats.RowReadable(row)
    if type(row) ~= "table" then return false end
    for _, field in ipairs({ "need", "greed", "dungeons" }) do
        local value = row[field]
        local quality = row.quality and row.quality[field]
        if not Stats.IsCount(value) then return false end
        if quality ~= nil and quality ~= "readable" then return false end
    end
    return true
end

-- ------------------------------------------------------------ 身份解析

-- 廉价的前置判断：NPC / 宠物 / 场景物件 / 受保护单位一律不进入后续读取。
-- 返回 "player" | "npc" | "unknown"
function Stats.PlayerGate(unit)
    if isSecret(unit) or type(unit) ~= "string" or unit == "" then return "unknown" end
    local existsOk, exists = Stats.SafeCall(UnitExists, unit)
    if not existsOk or isSecret(exists) or not exists then return "unknown" end
    local playerOk, isPlayer = Stats.SafeCall(UnitIsPlayer, unit)
    if not playerOk or isSecret(isPlayer) or isPlayer == nil then return "unknown" end
    return isPlayer and "player" or "npc"
end

-- 单位相对玩家的阵营：friendly | hostile
-- 无限（camelot）客户端 UnitFactionGroup 返回英文 token（Horde/Alliance/Neutral），
-- 第二个返回值是本地化名称；UnitIsEnemy 在战争地带与敌对状态下最准。
-- 两者任一判定为敌对就算 hostile（插件只对同阵营玩家生效）。
function Stats.FactionRelation(unit)
    local enemyOk, isEnemy = Stats.SafeCall(UnitIsEnemy, unit, "player")
    if enemyOk and isEnemy == true then return "hostile" end
    local myOk, myGroup = Stats.SafeCall(UnitFactionGroup, "player")
    if myOk and type(myGroup) == "string" and myGroup ~= "" and myGroup ~= "player" then
        local groupOk, group = Stats.SafeCall(UnitFactionGroup, unit)
        if groupOk and type(group) == "string" and group ~= "" and group ~= "player"
            and group ~= myGroup then
            return "hostile"
        end
    end
    return "friendly"
end

-- 返回 identity 或 nil, reason("npc" | "hidden" | "enemy")
function Stats.UnitIdentity(unit)
    local gate = Stats.PlayerGate(unit)
    if gate ~= "player" then return nil, gate == "npc" and "npc" or "hidden" end
    -- 只对同阵营玩家生效：对立阵营玩家一律排除（不查询、不显示、不写名单）
    if Stats.FactionRelation(unit) == "hostile" then return nil, "enemy" end

    local guidOk, guid = Stats.SafeCall(UnitGUID, unit)
    if not guidOk or isSecret(guid) or type(guid) ~= "string" or guid == "" then
        return nil, "hidden"
    end
    local nameOk, name, realm = Stats.SafeCall(UnitName, unit)
    if not nameOk or type(name) ~= "string" or name == "" then return nil, "hidden" end
    if type(realm) ~= "string" or realm == "" then
        local realmOk, current = Stats.SafeCall(GetRealmName)
        realm = (realmOk and type(current) == "string") and current or nil
    end
    local levelOk, level = Stats.SafeCall(UnitLevel, unit)
    if not levelOk or type(level) ~= "number" or level < 0 or level ~= math.floor(level) then
        level = nil
    end
    local selfOk, isSelf = Stats.SafeCall(UnitIsUnit, unit, "player")
    if not selfOk or isSelf == nil then return nil, "hidden" end
    local classOk, class = Stats.SafeCall(UnitClass, unit)
    if not classOk then class = nil end
    -- 种族：无限（camelot）客户端 UnitRace 存在，返回本地化种族名（如「牛头人」）
    local raceOk, race = Stats.SafeCall(UnitRace, unit)
    if not raceOk or type(race) ~= "string" or race == "" then race = nil end

    return {
        guid = guid,
        name = name,
        realm = realm,
        level = level,
        class = class,
        race = race,
        isPlayer = true,
        isSelf = isSelf and true or false,
    }
end

-- 按角色名反查单位 token。
-- 无限（camelot）等客户端的 GameTooltip:GetUnit() 返回的是角色名而不是单位 token
-- （SetUnit("player") 之后返回的是玩家名字），直接拿它去 UnitExists / UnitIsPlayer
-- 一律失败，提示框就永远画不出内容。这里在常用单位里按名字反查一次。
function Stats.ResolveUnitToken(name)
    if type(name) ~= "string" or name == "" then return nil end
    local candidates = { "mouseover", "target", "focus", "player" }
    for i = 1, 4 do candidates[#candidates + 1] = "party" .. i end
    for i = 1, 40 do candidates[#candidates + 1] = "raid" .. i end
    for i = 1, 40 do candidates[#candidates + 1] = "nameplate" .. i end
    for _, unit in ipairs(candidates) do
        local existsOk, exists = Stats.SafeCall(UnitExists, unit)
        if existsOk and exists == true then
            local nameOk, unitName = Stats.SafeCall(UnitName, unit)
            if nameOk and type(unitName) == "string" and not Stats.IsSecret(unitName) and unitName == name then
                return unit
            end
        end
    end
    return nil
end

-- ------------------------------------------------------------ 统计项 ID 自检

-- 名称关键词（中文 / 英文）。用于确认三个 ID 没有互换。
Stats.KEYWORDS = {
    need = { "需求", "需要", "想要", "need", "want" },
    greed = { "贪婪", "greed" },
    dungeons = { "副本", "地下城", "dungeon", "instance" },
}

-- 返回 "need" | "greed" | "dungeons" | "conflict" | nil
function Stats.ClassifyName(name)
    if type(name) ~= "string" or name == "" then return nil end
    local lowered = string.lower(name)
    local hits = {}
    for field, words in pairs(Stats.KEYWORDS) do
        for _, word in ipairs(words) do
            if string.find(lowered, string.lower(word), 1, true) then
                hits[field] = true
                break
            end
        end
    end
    local count = 0
    for _ in pairs(hits) do count = count + 1 end
    if count == 0 then return nil end
    if count > 1 then return "conflict" end
    for field in pairs(hits) do return field end
    return nil
end

-- 取某个统计项的本地化名称（兼容不同客户端的返回值顺序）。
function Stats.StatName(id)
    if type(GetAchievementInfo) ~= "function" then return nil end
    local ok, a, b = pcall(GetAchievementInfo, id)
    if not ok then return nil end
    if type(a) == "number" and type(b) == "string" then return b end
    if type(a) == "string" and type(b) == "number" then return a end
    if type(a) == "string" then return a end
    if type(b) == "string" then return b end
    return nil
end

-- 遍历统计分类，建立 id -> name 索引（按需构建，结果缓存在模块内）。
function Stats.BuildStatIndex()
    if Stats.statIndex then return Stats.statIndex end
    local index = { byId = {}, entries = {} }
    Stats.statIndex = index
    if type(GetStatisticsCategoryList) ~= "function"
        or type(GetCategoryNumAchievements) ~= "function"
        or type(GetAchievementInfo) ~= "function" then
        return index
    end
    local ok, categories = pcall(GetStatisticsCategoryList)
    if not ok or type(categories) ~= "table" then return index end
    local budget = 4000
    for _, category in ipairs(categories) do
        if budget <= 0 then break end
        local countOk, count = pcall(GetCategoryNumAchievements, category)
        if countOk and type(count) == "number" and count > 0 then
            count = math.min(count, 400)
            for index_ = 1, count do
                if budget <= 0 then break end
                budget = budget - 1
                local infoOk, id, name = pcall(GetAchievementInfo, category, index_)
                if infoOk then
                    if type(id) ~= "number" and type(name) == "number" then id, name = name, id end
                    if type(id) == "number" and type(name) == "string" and name ~= "" then
                        index.byId[id] = name
                        index.entries[#index.entries + 1] = { id = id, name = name, category = category }
                    end
                end
            end
        end
    end
    return index
end

-- 按名称关键词自动发现三个统计项 ID。
function Stats.DiscoverIDs()
    local index = Stats.BuildStatIndex()
    local found = {}
    for _, entry in ipairs(index.entries) do
        local field = Stats.ClassifyName(entry.name)
        if field and field ~= "conflict" and not found[field] then
            found[field] = { id = entry.id, name = entry.name }
        end
    end
    return found
end

-- 校验一组 ID：每个字段返回 "ok" | "conflict" | "unknown" | "none"
function Stats.VerifyIDs(ids)
    local result = {}
    for _, field in ipairs({ "need", "greed", "dungeons" }) do
        local id = ids[field]
        local name = Stats.StatName(id)
        if type(name) ~= "string" or name == "" then
            result[field] = "none"
        else
            local field2 = Stats.ClassifyName(name)
            if field2 == nil then
                result[field] = "unknown"
            elseif field2 == "conflict" then
                result[field] = "conflict"
            elseif field2 == field then
                result[field] = "ok"
            else
                result[field] = "conflict"
            end
        end
    end
    return result
end

-- 决定实际使用的三个 ID：默认 ID 通过校验就用默认，否则按名称自动发现。
function Stats.ResolveIDs()
    if GM.STAT_RESOLVED then return GM.STAT_RESOLVED end
    local ids = { need = GM.STAT.need, greed = GM.STAT.greed, dungeons = GM.STAT.dungeons }
    local verify = Stats.VerifyIDs(ids)
    local conflicted = false
    for _, field in ipairs({ "need", "greed", "dungeons" }) do
        if verify[field] == "conflict" then conflicted = true end
    end
    local resolved = { ids = ids, verify = verify, source = "default", conflicted = conflicted }
    if conflicted then
        local discovered = Stats.DiscoverIDs()
        if discovered.need and discovered.greed and discovered.dungeons then
            local newIds = {
                need = discovered.need.id,
                greed = discovered.greed.id,
                dungeons = discovered.dungeons.id,
            }
            resolved = { ids = newIds, verify = Stats.VerifyIDs(newIds),
                source = "discovered", conflicted = false,
                names = { need = discovered.need.name, greed = discovered.greed.name,
                    dungeons = discovered.dungeons.name } }
        end
    end
    GM.STAT_RESOLVED = resolved
    return resolved
end

function Stats.CurrentIDs()
    return Stats.ResolveIDs().ids
end

-- 读取自己时若三项全部读不到，再尝试一次按名称自动发现（并重新读取）。
function Stats.SelfRow()
    local identity = Stats.UnitIdentity("player")
    if not identity then return nil end
    local row = Stats.ReadRow(GetStatistic)
    if row.need == nil and row.greed == nil and row.dungeons == nil then
        local resolved = Stats.ResolveIDs()
        if resolved.source == "default" then
            local discovered = Stats.DiscoverIDs()
            if discovered.need and discovered.greed and discovered.dungeons then
                GM.STAT_RESOLVED = {
                    ids = { need = discovered.need.id, greed = discovered.greed.id,
                        dungeons = discovered.dungeons.id },
                    verify = Stats.VerifyIDs({
                        need = discovered.need.id, greed = discovered.greed.id,
                        dungeons = discovered.dungeons.id }),
                    source = "discovered", conflicted = false,
                }
                row = Stats.ReadRow(GetStatistic)
            end
        end
    end
    row.name, row.realm = identity.name, identity.realm
    row.level, row.class = identity.level, identity.class
    row.race = identity.race
    row.source = "self"
    row.self = true
    return row
end

function Stats.ComparisonRow()
    return Stats.ReadRow(GetComparisonStatistic)
end
