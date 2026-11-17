-- tests/wow_stub.lua
-- 离线的暴雪客户端 API 桩，用于在普通 Lua 解释器里跑插件逻辑的单元测试。
-- 只实现插件真正用到的接口，未实现的接口一律返回 nil / false，
-- 这样测试不会因为“桩太宽松”而掩盖真实行为。

local stub = {}

-- ------------------------------------------------------------ 控件桩
local proto = {}
proto.__index = proto

local function newFrame(kind, name)
    local frame = setmetatable({ __kind = kind, __name = name, __shown = false,
        __events = {}, __scripts = {}, __hooks = {} }, proto)
    return frame
end
stub.newFrame = newFrame

function proto:SetText(text) self.__text = text end
function proto:GetText() return self.__text end
function proto:SetTextColor(r, g, b) self.__color = { r, g, b } end
function proto:GetTextColor() return self.__color end
function proto:Show() self.__shown = true end
function proto:Hide() self.__shown = false end
function proto:IsShown() return self.__shown end
function proto:SetPoint() end
function proto:SetSize() end
function proto:SetScale() end
function proto:SetJustifyH() end
function proto:SetWidth() end
function proto:SetHeight() end
function proto:SetToplevel() end
function proto:SetFrameStrata() end
function proto:SetChecked(v) self.__checked = v end
function proto:GetChecked() return self.__checked end
function proto:Raise() end
function proto:ClearLines() self.__lines = 0 end
function proto:RegisterEvent(event) self.__events[event] = true end
function proto:UnregisterEvent(event) self.__events[event] = nil end
function proto:IsEventRegistered(event) return self.__events[event] == true end
function proto:SetScript(key, fn) self.__scripts[key] = fn end
function proto:GetScript(key) return self.__scripts[key] end
function proto:HookScript(key, fn) self.__hooks[key] = fn end
function proto:UnhookScript(key, fn)
    if self.__hooks[key] == fn then self.__hooks[key] = nil end
end
function proto:EnableMouse() end
function proto:EnableMouseWheel() end
function proto:SetShown(v) self.__shown = v and true or false end
function proto:ClearAllPoints() end
function proto:SetAllPoints() end
function proto:CreateFontString() return newFrame("FontString") end
function proto:SetParent(parent) self.__parent = parent end
function proto:GetParent() return self.__parent end

-- GameTooltip 专用
function proto:AddLine(text)
    self.__lines = (self.__lines or 0) + 1
    local index = self.__lines
    local fs = newFrame("FontString")
    fs.__text = text
    fs.__shown = true
    _G["GameTooltipTextLeft" .. tostring(index)] = fs
    _G["GameTooltipTextRight" .. tostring(index)] = newFrame("FontString")
    return fs
end

function proto:NumLines() return self.__lines or 0 end

function proto:SetUnit(unit)
    self.__unit = unit
    self.__lines = 0
end

function proto:GetUnit() return self.__unit end

-- ------------------------------------------------------------ 时钟
stub.clock = 1000.0     -- GetTime()：秒，带小数
stub.wall = 1700000000  -- time()：秒，整数

-- ------------------------------------------------------------ 单位
stub.units = {
    player = { guid = "Player-1", name = "我", realm = "测试服", level = 70, class = "WARRIOR", player = true },
    mouseover = { guid = "Player-2", name = "队友甲", realm = "测试服", level = 68, class = "MAGE", player = true },
    target = { guid = "Player-3", name = "队友乙", realm = "测试服", level = 65, class = "ROGUE", player = true },
    party1 = { guid = "Player-4", name = "队友丙", realm = "测试服", level = 60, class = "PRIEST", player = true },
    party2 = { guid = "Player-5", name = "队友丁", realm = "测试服", level = 60, class = "SHAMAN", player = true },
    npc1 = { guid = "NPC-1", name = "商人", realm = nil, level = 60, class = "MERCHANT", player = false },
}

-- ------------------------------------------------------------ 统计数据
stub.statistics = {
    [1044] = "1,234",  -- 需求
    [1043] = "56",     -- 贪婪
    [932] = "10",      -- 副本
}
stub.comparison = {
    [1044] = "30",
    [1043] = "70",
    [932] = "12",
}
stub.achievementNames = {
    [1044] = "战利品：需求",
    [1043] = "战利品：贪婪",
    [932] = "进入 5 人副本",
}
stub.categories = { 1, 2 }
stub.categoryItems = {
    [1] = { { 1044, "战利品：需求" }, { 1043, "战利品：贪婪" } },
    [2] = { { 932, "进入 5 人副本" } },
}

stub.setComparisonResult = true   -- SetAchievementComparisonUnit 的返回值
stub.inCombat = false
stub.inRaid = false
stub.groupMembers = 3
stub.secretValues = {}             -- 让 issecretvalue 返回 true 的值

-- ------------------------------------------------------------ 全局接口
function _G.CreateFrame(kind, name, parent, template)
    local frame = newFrame(kind, name)
    frame.__template = template
    frame.__parent = parent
    return frame
end

_G.UIParent = newFrame("Frame", "UIParent")
_G.GameTooltip = newFrame("GameTooltip", "GameTooltip")
_G.AchievementFrameComparison = newFrame("Frame", "AchievementFrameComparison")
_G.AchievementFrame = nil

function _G.GetTime() return stub.clock end
function _G.time() return stub.wall end
function _G.GetRealmName() return "测试服" end

function _G.UnitExists(unit) return stub.units[unit] ~= nil end
function _G.UnitIsPlayer(unit)
    local info = stub.units[unit]
    return info and info.player == true
end
function _G.UnitGUID(unit)
    local info = stub.units[unit]
    return info and info.guid
end
function _G.UnitName(unit)
    local info = stub.units[unit]
    if not info then return nil end
    return info.name, info.realm
end
function _G.UnitLevel(unit)
    local info = stub.units[unit]
    return info and info.level
end
function _G.UnitClass(unit)
    local info = stub.units[unit]
    return info and info.class
end
function _G.UnitIsUnit(unit, other) return unit == other end

function _G.GetStatistic(id)
    local value = stub.statistics[id]
    if value == nil then return nil end
    return value, false, id
end

function _G.GetComparisonStatistic(id)
    local value = stub.comparison[id]
    if value == nil then return nil end
    return value
end

function _G.GetAchievementInfo(a, b)
    if type(b) == "number" then
        local items = stub.categoryItems[a] or {}
        local item = items[b]
        if not item then return nil end
        return item[1], item[2]
    end
    local name = stub.achievementNames[a]
    if not name then return nil end
    return a, name
end

function _G.GetStatisticsCategoryList() return stub.categories end

function _G.GetCategoryNumAchievements(category)
    local items = stub.categoryItems[category] or {}
    return #items
end

-- hooksecurefunc 桩：记录钩子，被钩的函数被调用时触发。
stub.secureHooks = {}
function _G.hooksecurefunc(name, fn)
    if type(name) ~= "string" then return end
    stub.secureHooks[name] = stub.secureHooks[name] or {}
    table.insert(stub.secureHooks[name], fn)
end

local function fireSecureHooks(name)
    for _, fn in ipairs(stub.secureHooks[name] or {}) do pcall(fn) end
end
stub.fireSecureHooks = fireSecureHooks

-- 成就比较链路：真实客户端会在服务器应答后触发 INSPECT_ACHIEVEMENT_READY 事件；
-- 桩里由测试通过 stub.deliverInspectReady() 模拟服务器应答。
function stub.deliverInspectReady()
    local GM = stub.GM
    if not (GM and GM.Scan and GM.Scan.frame) then return end
    local unit = stub.comparisonUnit
    local info = unit and stub.units[unit]
    if not info then return end
    GM.Scan.frame.__scripts.OnEvent(GM.Scan.frame, "INSPECT_ACHIEVEMENT_READY", info.guid)
end

function _G.SetAchievementComparisonUnit(unit)
    stub.comparisonUnit = unit
    stub.setCalls = (stub.setCalls or 0) + 1
    local result = stub.setComparisonResult
    fireSecureHooks("SetAchievementComparisonUnit")
    return result
end

function _G.ClearAchievementComparisonUnit()
    stub.comparisonUnit = nil
    fireSecureHooks("ClearAchievementComparisonUnit")
    return true
end

function _G.InCombatLockdown() return stub.inCombat end
function _G.IsInRaid() return stub.inRaid end
function _G.GetNumGroupMembers() return stub.groupMembers end
function _G.HideUIPanel() end
function _G.issecretvalue(value) return stub.secretValues[value] == true end

_G.SlashCmdList = {}

-- 时区/日历
function _G.date(fmt, t) return os.date(fmt, t) end
function _G.IsLoggedIn() return false end

-- 定时器桩：After 只登记不触发，避免测试中无限制的回调链
stub.timers = {}
_G.C_Timer = {
    After = function(delay, fn) stub.timers[#stub.timers + 1] = { delay = delay, fn = fn } end,
}

-- 阵营相关：默认无敌对关系
function _G.UnitFactionGroup(unit) return "Alliance", "联盟" end
function _G.UnitIsEnemy(unit, other) return false end
function _G.UnitRace(unit)
    local info = stub.units[unit]
    return info and info.race
end

-- ------------------------------------------------------------ 装载插件
-- 按 TOC 顺序加载，返回共享的 GM 表。
function stub.loadAddon(root)
    local GM = {}
    local order = { "Core", "I18n", "DB", "Rate", "Stats", "Scan", "Tooltip", "Settings", "Party", "Probe" }
    for _, name in ipairs(order) do
        local path = root .. "/" .. name .. ".lua"
        local chunk, err = loadfile(path)
        if not chunk then error("无法加载 " .. path .. ": " .. tostring(err)) end
        chunk("GreedMirror", GM)
    end
    stub.GM = GM
    return GM
end

-- 让插件完成启动（ADDON_LOADED / PLAYER_LOGIN）。
function stub.login(GM)
    local frame = GM.frame
    frame.__scripts.OnEvent(frame, "ADDON_LOADED", "GreedMirror")
end

return stub
