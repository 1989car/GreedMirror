-- GreedMirror 贪婪镜 - Scan.lua
-- 唯一与“成就比较单位”接口打交道的文件。
--
--   SetAchievementComparisonUnit(unit)
--   → 事件 INSPECT_ACHIEVEMENT_READY(guid)
--   → GetComparisonStatistic(1044 / 1043 / 932)
--   → ClearAchievementComparisonUnit()
--
-- 同一时刻只允许一个请求在途；悬停请求防抖并受最小间隔限制；
-- 手动命令（/greed target）可以插队，战斗中仍允许手动查询；
-- 不调用 NotifyInspect / InspectAchievements，也不注册受限事件。
--
-- 结构：
--   machine  —— 全部可变状态收在一张表里（可整体快照/替换，见 Scan.machine）；
--   effects  —— 客户端副作用出口（时间、战斗、窗口占用、比较接口、隐藏面板），
--               测试可整体替换，逻辑不用打桩；
--   Transition —— 状态机的唯一入口：request / tick / ready / timeout / cancel。
local ADDON, GM = ...

local Scan = {}
GM.Scan = Scan

GM.Require("Scan", { "Stats", "DB", "Rate" })

local Stats, DB = GM.Stats, GM.DB

-- ------------------------------------------------------------ 状态机
local machine = {
    state = "IDLE",     -- IDLE | INFLIGHT
    pending = nil,      -- 防抖中的请求（还没发出比较请求）
    inflight = nil,     -- 已发出比较请求、等待事件的请求
    queue = {},         -- 排队中的请求
    lastSet = nil,      -- 上次 SetAchievementComparisonUnit 的时刻
    farUntil = {},      -- guid -> “距离过远”冷却截止时刻
    ownsComparison = false,
    inCall = false,     -- comparisonCall 期间为 true（我们自己的调用不触发外部抢占）
    externalUntil = 0,  -- 外部抢占（别的插件改了比较单位）后的冷却截止
    hooks = {},         -- hooksecurefunc 是否已挂
}
Scan.machine = machine

-- ------------------------------------------------------------ 副作用出口
local effects = {
    now = function()
        if GetTime then return GetTime() end
        return time and time() or 0
    end,
    inCombat = function()
        if type(InCombatLockdown) ~= "function" then return false end
        -- 战斗状态不可读时按“战斗中”处理（宁可不查，也不要在受保护状态下乱调接口）。
        local ok, locked = Stats.SafeCall(InCombatLockdown)
        return (not ok) or (locked and true or false)
    end,
    busy = function()
        local af = AchievementFrame
        return af and af.IsShown and af:IsShown() and true or false
    end,
    setUnit = SetAchievementComparisonUnit,
    clearUnit = ClearAchievementComparisonUnit,
    hasAPI = function()
        return type(SetAchievementComparisonUnit) == "function"
            and type(ClearAchievementComparisonUnit) == "function"
            and type(GetComparisonStatistic) == "function"
    end,
    hidePanel = HideUIPanel,
    hooksecure = hooksecurefunc,
}
Scan.effects = effects

Scan.listeners = {}

local frame = CreateFrame("Frame")
Scan.frame = frame
Scan.timeouts = 0
Scan.lastGuid = nil

local function secret(value)
    return Stats.IsSecret(value)
end

function Scan.HasAPI()
    return effects.hasAPI()
end

-- fn(guid, row|nil, status)
function Scan.OnReady(fn)
    if type(fn) == "function" then Scan.listeners[#Scan.listeners + 1] = fn end
end

local function notify(guid, row, status)
    for _, fn in ipairs(Scan.listeners) do pcall(fn, guid, row, status) end
end

function Scan.State() return machine.state end
function Scan.QueueSize() return #machine.queue end

function Scan.Get(guid)
    local row = DB.CacheGet(guid)
    if row and DB.CacheFresh(guid) then return row end
    return nil
end

function Scan.Status(guid)
    if secret(guid) or type(guid) ~= "string" then return nil end
    if machine.inflight and machine.inflight.guid == guid then return "PENDING" end
    if machine.pending and machine.pending.guid == guid then return "PENDING" end
    for _, item in ipairs(machine.queue) do
        if item.guid == guid then return "PENDING" end
    end
    if machine.farUntil[guid] and machine.farUntil[guid] > effects.now() then return "FAR" end
    return nil
end

-- 原生成就窗口自己也在监听同一个事件；请求期间临时静音，结束后恢复。
local function quietNative(entry)
    local cmp = AchievementFrameComparison
    if not cmp or type(cmp.IsEventRegistered) ~= "function"
        or type(cmp.UnregisterEvent) ~= "function" then
        return
    end
    local ok, registered = pcall(cmp.IsEventRegistered, cmp, "INSPECT_ACHIEVEMENT_READY")
    if ok and registered then
        if pcall(cmp.UnregisterEvent, cmp, "INSPECT_ACHIEVEMENT_READY") then
            entry.mutedNative = true
        end
    end
end

local function restoreNative(entry)
    if not entry or not entry.mutedNative then return end
    entry.mutedNative = nil
    local cmp = AchievementFrameComparison
    if cmp and type(cmp.RegisterEvent) == "function" then
        pcall(cmp.RegisterEvent, cmp, "INSPECT_ACHIEVEMENT_READY")
    end
end

local function comparisonCall(fn, ...)
    machine.inCall = true
    local ok, result = pcall(fn, ...)
    machine.inCall = false
    return ok, result
end

local function releaseComparison()
    if machine.ownsComparison then
        machine.ownsComparison = false
        if type(effects.clearUnit) == "function" then
            comparisonCall(effects.clearUnit)
        end
    end
end

-- 别的插件或原生成就窗口改动了比较单位 → 放弃我们的请求，绝不读别人的结果。
function Scan.WatchComparison()
    if type(effects.hooksecure) ~= "function" then return false end
    local function changed()
        if machine.inCall then return end
        machine.ownsComparison = false
        machine.externalUntil = effects.now() + 5
        Scan.Cancel("BUSY")
    end
    for _, name in ipairs({ "SetAchievementComparisonUnit", "ClearAchievementComparisonUnit" }) do
        if not machine.hooks[name] and type(_G[name]) == "function" then
            machine.hooks[name] = pcall(effects.hooksecure, name, changed)
        end
        if not machine.hooks[name] then return false end
    end
    return true
end

local function settle()
    if machine.pending or machine.inflight or #machine.queue > 0 then
        frame:SetScript("OnUpdate", Scan.Tick)
    else
        frame:SetScript("OnUpdate", nil)
    end
end

local function enqueue(unit, identity, opts)
    if #machine.queue >= GM.SCAN.queueMax then return false end
    local item = {
        unit = unit,
        guid = identity.guid,
        name = identity.name,
        realm = identity.realm,
        level = identity.level,
        class = identity.class,
        race = identity.race,
        at = effects.now(),
        manual = opts.manual and true or false,
    }
    if opts.front then
        table.insert(machine.queue, 1, item)
    else
        machine.queue[#machine.queue + 1] = item
    end
    settle()
    return true
end

-- 请求一次统计。返回 row, "READY"；或 nil, status
-- status: PENDING | READY | FAR | TIMEOUT | COMBAT | NOAPI | BUSY | HIDDEN | NPC | NODATA | SELF | FACTION
local function doRequest(unit, opts)
    opts = opts or {}
    if not GM.IsEnabled() then return nil, "NOAPI" end
    local identity, why = Stats.UnitIdentity(unit)
    if not identity then
        if why == "npc" then return nil, "NPC" end
        if why == "enemy" then return nil, "FACTION" end
        return nil, "HIDDEN"
    end
    if identity.isSelf then return nil, "SELF" end

    local cached = DB.CacheGet(identity.guid)
    if cached and DB.CacheFresh(identity.guid) and not opts.force then
        return cached, "READY"
    end

    if not Scan.HasAPI() or not Scan.WatchComparison() then
        return nil, "NOAPI"
    end

    -- 战斗中：被动悬停不发起请求（只显示缓存），手动命令仍然可以查。
    if effects.inCombat() and not opts.manual then
        return nil, "COMBAT"
    end
    if effects.busy() or effects.now() < machine.externalUntil then
        return nil, "BUSY"
    end
    local status = Scan.Status(identity.guid)
    if status then return nil, status end
    if not enqueue(unit, identity, opts) then return nil, "BUSY" end
    return nil, "PENDING"
end

-- 取消请求。keepManual=true 时保留手动请求（鼠标快速切换目标时用）。
local function doCancel(status, keepManual)
    local entry, waiting = machine.inflight, machine.pending
    frame:UnregisterEvent("INSPECT_ACHIEVEMENT_READY")
    releaseComparison()
    restoreNative(entry)
    machine.inflight, machine.pending, machine.state = nil, nil, "IDLE"
    local queuedItems = machine.queue
    machine.queue = {}
    settle()

    local function cancelled(item)
        if not item then return end
        notify(item.guid, nil, status or "CANCELLED")
    end
    if entry and not (keepManual and entry.manual) then cancelled(entry) end
    if waiting and not (keepManual and waiting.manual) then cancelled(waiting) end
    for _, item in ipairs(queuedItems) do
        if not (keepManual and item.manual) then cancelled(item) end
    end
end

-- 鼠标切换目标时，丢弃未完成的悬停请求（手动请求保留）。
function Scan.CancelHover()
    if machine.inflight and not machine.inflight.manual then Scan.Cancel("CANCELLED", true) end
    if machine.pending and not machine.pending.manual then machine.pending = nil end
    local kept = {}
    for _, item in ipairs(machine.queue) do
        if item.manual then kept[#kept + 1] = item end
    end
    machine.queue = kept
    settle()
end

local function finish(row, status)
    local entry = machine.inflight
    frame:UnregisterEvent("INSPECT_ACHIEVEMENT_READY")
    releaseComparison()
    restoreNative(entry)
    machine.state = "IDLE"
    machine.inflight = nil

    if entry and not entry.frameWasShown and AchievementFrame
        and AchievementFrame.IsShown and AchievementFrame:IsShown() then
        -- 我们的请求把原生成就窗口顶了出来，隐藏掉，别留在屏幕上。
        if type(effects.hidePanel) == "function" then pcall(effects.hidePanel, AchievementFrame) end
    end

    if entry and status == "READY" and row and not Stats.RowReadable(row) then
        status = "NODATA"
    end

    if entry and row then
        row.name = entry.name
        row.realm = entry.realm
        row.level = entry.level
        row.class = entry.class
        row.race = entry.race
        row.at = time and time() or 0
        row.source = "scan"
    end

    if entry and status == "READY" and row then
        DB.CachePut(entry.guid, row)
        Scan.lastGuid = entry.guid
        notify(entry.guid, row, "READY")
    elseif entry then
        if status == "TIMEOUT" then Scan.timeouts = Scan.timeouts + 1 end
        -- NODATA 时保留 row（带着 quality），提示框才能说明“缺哪一项、为什么”；
        -- 读不到的行不写缓存，避免下次命中缓存却拿不到原因。
        notify(entry.guid, status == "NODATA" and row or nil, status)
    end
    settle()
end

local function fire(entry)
    machine.lastSet = effects.now()
    entry.frameWasShown = effects.busy()
    quietNative(entry)
    machine.state, machine.inflight, machine.ownsComparison = "INFLIGHT", entry, true
    entry.started = effects.now()
    frame:RegisterEvent("INSPECT_ACHIEVEMENT_READY")
    local ok, result = comparisonCall(effects.setUnit, entry.unit)
    if not ok or secret(result) or result == false then
        machine.farUntil[entry.guid] = effects.now() + GM.SCAN.farTTL
        if machine.inflight == entry then finish(nil, "FAR") end
        return
    end
    settle()
end

local function doTick()
    local current = effects.now()

    if machine.state == "INFLIGHT" then
        if machine.inflight and not machine.inflight.manual and effects.inCombat() then
            Scan.Cancel("COMBAT", true)
            return
        end
        if machine.inflight then
            local limit = machine.inflight.manual and GM.SCAN.manualTimeout or GM.SCAN.hoverTimeout
            if current - machine.inflight.started > limit then
                finish(nil, "TIMEOUT")
            else
                return
            end
        end
    end

    if not machine.pending then
        if #machine.queue == 0 then
            settle()
            return
        end
        machine.pending = table.remove(machine.queue, 1)
        machine.pending.at = current
    end

    if current - machine.pending.at < GM.SCAN.debounce then return end
    if machine.lastSet and current - machine.lastSet < GM.SCAN.floor then return end

    -- 发出前再确认一次目标仍然是玩家（鼠标可能已经移开）。
    if Stats.PlayerGate(machine.pending.unit) ~= "player" then
        local entry = machine.pending
        machine.pending = nil
        notify(entry.guid, nil, "CANCELLED")
        settle()
        return
    end
    local identity = Stats.UnitIdentity(machine.pending.unit)
    if not identity or secret(identity.guid) or identity.guid ~= machine.pending.guid
        or not identity.isPlayer or identity.isSelf then
        local entry = machine.pending
        machine.pending = nil
        notify(entry.guid, nil, "CANCELLED")
        settle()
        return
    end
    if effects.busy() or current < machine.externalUntil then
        local entry = machine.pending
        machine.pending = nil
        notify(entry.guid, nil, "BUSY")
        settle()
        return
    end
    local pending = machine.pending
    pending.name = identity.name or pending.name
    pending.realm = identity.realm or pending.realm
    pending.level = identity.level or pending.level
    pending.class = identity.class or pending.class
    pending.race = identity.race or pending.race
    machine.pending = nil
    fire(pending)
end

-- INSPECT_ACHIEVEMENT_READY：收割在途请求的结果。
local function doReady(guid)
    if machine.state ~= "INFLIGHT" or not machine.inflight then return end
    local inflight = machine.inflight
    if secret(guid) or type(guid) ~= "string" or guid ~= inflight.guid or not machine.ownsComparison then
        return
    end
    local limit = inflight.manual and GM.SCAN.manualTimeout or GM.SCAN.hoverTimeout
    if effects.now() - inflight.started > limit then
        finish(nil, "TIMEOUT")
        return
    end
    local identity = Stats.UnitIdentity(inflight.unit)
    if not identity or identity.guid ~= guid then
        Scan.Cancel("CANCELLED", true)
        return
    end
    local row = Stats.ComparisonRow()
    finish(row, "READY")
end

-- ------------------------------------------------------------ 状态机入口
-- 事件 → 动作的唯一分派点；测试与排障从这里驱动整个扫描机。
--   request {unit, opts} → row, status（同 Scan.Request）
--   ready guid           → 收割 INSPECT_ACHIEVEMENT_READY
--   tick                 → 防抖/超时/出队推进（frame OnUpdate 即 Scan.Tick）
--   timeout              → 在途请求按超时收割
--   cancel {status, keepManual} → 取消在途与排队请求
function Scan.Transition(event, payload)
    if event == "request" then return doRequest(payload and payload.unit, payload and payload.opts) end
    if event == "ready" then doReady(payload) return end
    if event == "tick" then doTick() return end
    if event == "timeout" then
        if machine.state == "INFLIGHT" then finish(nil, "TIMEOUT") end
        return
    end
    if event == "cancel" then
        doCancel(payload and payload.status, payload and payload.keepManual)
        return
    end
    error("Scan.Transition: 未知事件 " .. tostring(event), 0)
end

function Scan.Request(unit, opts)
    return Scan.Transition("request", { unit = unit, opts = opts })
end

function Scan.Cancel(status, keepManual)
    Scan.Transition("cancel", { status = status, keepManual = keepManual })
end

function Scan.Tick()
    Scan.Transition("tick")
end

frame:SetScript("OnEvent", function(_, event, guid)
    if event == "INSPECT_ACHIEVEMENT_READY" then
        Scan.Transition("ready", guid)
    end
end)

-- 手动扫描 5 人小队成员（只处理 party1-4；团队不做自动扫描）。
function Scan.ScanParty(force)
    if type(GetNumGroupMembers) ~= "function" or (GetNumGroupMembers() or 0) <= 0 then
        return 0, 0
    end
    if type(IsInRaid) == "function" and IsInRaid() then
        return 0, 0
    end
    local requested, ready = 0, 0
    for i = 1, 4 do
        local unit = "party" .. i
        local existsOk, exists = Stats.SafeCall(UnitExists, unit)
        if existsOk and exists then
            local row, status = Scan.Request(unit, { force = force, manual = true })
            if row and status == "READY" then
                ready = ready + 1
            elseif status == "PENDING" then
                requested = requested + 1
            end
        end
    end
    return requested, ready
end

function Scan.Init()
    Scan.WatchComparison()
end

function Scan.Debug()
    return {
        state = machine.state,
        queue = #machine.queue,
        pending = machine.pending and machine.pending.guid or nil,
        inflight = machine.inflight and machine.inflight.guid or nil,
        api = Scan.HasAPI(),
        timeouts = Scan.timeouts,
        cache = DB.CacheCount(),
    }
end
