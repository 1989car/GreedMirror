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
local ADDON, GM = ...

local Scan = {}
GM.Scan = Scan

local Stats, DB, Rate = GM.Stats, GM.DB, GM.Rate

local state = "IDLE"
local pending = nil
local inflight = nil
local queue = {}
local lastSet = nil
local farUntil = {}
local listeners = {}
local ownsComparison = false
local inCall = false
local externalUntil = 0
local hooks = {}

local frame = CreateFrame("Frame")
Scan.frame = frame
Scan.timeouts = 0
Scan.lastGuid = nil

local function now()
    if GetTime then return GetTime() end
    return time and time() or 0
end

local function secret(value)
    return Stats.IsSecret(value)
end

function Scan.HasAPI()
    return type(SetAchievementComparisonUnit) == "function"
        and type(ClearAchievementComparisonUnit) == "function"
        and type(GetComparisonStatistic) == "function"
end

-- fn(guid, row|nil, status)
function Scan.OnReady(fn)
    if type(fn) == "function" then listeners[#listeners + 1] = fn end
end

local function notify(guid, row, status)
    for _, fn in ipairs(listeners) do pcall(fn, guid, row, status) end
end

function Scan.State() return state end
function Scan.QueueSize() return #queue end

function Scan.Get(guid)
    local row = DB.CacheGet(guid)
    if row and DB.CacheFresh(guid) then return row end
    return nil
end

function Scan.Status(guid)
    if secret(guid) or type(guid) ~= "string" then return nil end
    if inflight and inflight.guid == guid then return "PENDING" end
    if pending and pending.guid == guid then return "PENDING" end
    for _, item in ipairs(queue) do
        if item.guid == guid then return "PENDING" end
    end
    if farUntil[guid] and farUntil[guid] > now() then return "FAR" end
    return nil
end

local function busy()
    local af = AchievementFrame
    return af and af.IsShown and af:IsShown() and true or false
end

-- 战斗状态不可读时按“战斗中”处理（宁可不查，也不要在受保护状态下乱调接口）。
local function inCombat()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = Stats.SafeCall(InCombatLockdown)
    return (not ok) or (locked and true or false)
end

local function settle()
    if pending or inflight or #queue > 0 then
        frame:SetScript("OnUpdate", Scan.Tick)
    else
        frame:SetScript("OnUpdate", nil)
    end
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
    inCall = true
    local ok, result = pcall(fn, ...)
    inCall = false
    return ok, result
end

local function releaseComparison()
    if ownsComparison then
        ownsComparison = false
        if type(ClearAchievementComparisonUnit) == "function" then
            comparisonCall(ClearAchievementComparisonUnit)
        end
    end
end

-- 别的插件或原生成就窗口改动了比较单位 → 放弃我们的请求，绝不读别人的结果。
function Scan.WatchComparison()
    if type(hooksecurefunc) ~= "function" then return false end
    local function changed()
        if inCall then return end
        ownsComparison = false
        externalUntil = now() + 5
        Scan.Cancel("BUSY")
    end
    for _, name in ipairs({ "SetAchievementComparisonUnit", "ClearAchievementComparisonUnit" }) do
        if not hooks[name] and type(_G[name]) == "function" then
            hooks[name] = pcall(hooksecurefunc, name, changed)
        end
        if not hooks[name] then return false end
    end
    return true
end

local function enqueue(unit, identity, opts)
    if #queue >= GM.SCAN.queueMax then return false end
    local item = {
        unit = unit,
        guid = identity.guid,
        name = identity.name,
        realm = identity.realm,
        level = identity.level,
        class = identity.class,
        race = identity.race,
        at = now(),
        manual = opts.manual and true or false,
    }
    if opts.front then
        table.insert(queue, 1, item)
    else
        queue[#queue + 1] = item
    end
    settle()
    return true
end

-- 请求一次统计。返回 row, "READY"；或 nil, status
-- status: PENDING | READY | FAR | TIMEOUT | COMBAT | NOAPI | BUSY | HIDDEN | NPC | NODATA | SELF | FACTION
function Scan.Request(unit, opts)
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
    if inCombat() and not opts.manual then
        return nil, "COMBAT"
    end
    if busy() or now() < externalUntil then
        return nil, "BUSY"
    end
    local status = Scan.Status(identity.guid)
    if status then return nil, status end
    if not enqueue(unit, identity, opts) then return nil, "BUSY" end
    return nil, "PENDING"
end

-- 取消请求。keepManual=true 时保留手动请求（鼠标快速切换目标时用）。
function Scan.Cancel(status, keepManual)
    local entry, waiting = inflight, pending
    frame:UnregisterEvent("INSPECT_ACHIEVEMENT_READY")
    releaseComparison()
    restoreNative(entry)
    inflight, pending, state = nil, nil, "IDLE"
    local queuedItems = queue
    queue = {}
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
    if inflight and not inflight.manual then Scan.Cancel("CANCELLED", true) end
    if pending and not pending.manual then pending = nil end
    local kept = {}
    for _, item in ipairs(queue) do
        if item.manual then kept[#kept + 1] = item end
    end
    queue = kept
    settle()
end

local function finish(row, status)
    local entry = inflight
    frame:UnregisterEvent("INSPECT_ACHIEVEMENT_READY")
    releaseComparison()
    restoreNative(entry)
    state = "IDLE"
    inflight = nil

    if entry and not entry.frameWasShown and AchievementFrame
        and AchievementFrame.IsShown and AchievementFrame:IsShown() then
        -- 我们的请求把原生成就窗口顶了出来，隐藏掉，别留在屏幕上。
        pcall(HideUIPanel, AchievementFrame)
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
    lastSet = now()
    entry.frameWasShown = busy()
    quietNative(entry)
    state, inflight, ownsComparison = "INFLIGHT", entry, true
    entry.started = now()
    frame:RegisterEvent("INSPECT_ACHIEVEMENT_READY")
    local ok, result = comparisonCall(SetAchievementComparisonUnit, entry.unit)
    if not ok or secret(result) or result == false then
        farUntil[entry.guid] = now() + GM.SCAN.farTTL
        if inflight == entry then finish(nil, "FAR") end
        return
    end
    settle()
end

function Scan.Tick()
    local current = now()

    if state == "INFLIGHT" then
        if inflight and not inflight.manual and inCombat() then
            Scan.Cancel("COMBAT", true)
            return
        end
        if inflight then
            local limit = inflight.manual and GM.SCAN.manualTimeout or GM.SCAN.hoverTimeout
            if current - inflight.started > limit then
                finish(nil, "TIMEOUT")
            else
                return
            end
        end
    end

    if not pending then
        if #queue == 0 then
            settle()
            return
        end
        pending = table.remove(queue, 1)
        pending.at = current
    end

    if current - pending.at < GM.SCAN.debounce then return end
    if lastSet and current - lastSet < GM.SCAN.floor then return end

    -- 发出前再确认一次目标仍然是玩家（鼠标可能已经移开）。
    if Stats.PlayerGate(pending.unit) ~= "player" then
        local entry = pending
        pending = nil
        notify(entry.guid, nil, "CANCELLED")
        settle()
        return
    end
    local identity = Stats.UnitIdentity(pending.unit)
    if not identity or secret(identity.guid) or identity.guid ~= pending.guid
        or not identity.isPlayer or identity.isSelf then
        local entry = pending
        pending = nil
        notify(entry.guid, nil, "CANCELLED")
        settle()
        return
    end
    if busy() or current < externalUntil then
        local entry = pending
        pending = nil
        notify(entry.guid, nil, "BUSY")
        settle()
        return
    end
    pending.name = identity.name or pending.name
    pending.realm = identity.realm or pending.realm
    pending.level = identity.level or pending.level
    pending.class = identity.class or pending.class
    pending.race = identity.race or pending.race
    local entry = pending
    pending = nil
    fire(entry)
end

frame:SetScript("OnEvent", function(_, event, guid)
    if event ~= "INSPECT_ACHIEVEMENT_READY" or state ~= "INFLIGHT" or not inflight then
        return
    end
    if secret(guid) or type(guid) ~= "string" or guid ~= inflight.guid or not ownsComparison then
        return
    end
    local limit = inflight.manual and GM.SCAN.manualTimeout or GM.SCAN.hoverTimeout
    if now() - inflight.started > limit then
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
        state = state,
        queue = #queue,
        pending = pending and pending.guid or nil,
        inflight = inflight and inflight.guid or nil,
        api = Scan.HasAPI(),
        timeouts = Scan.timeouts,
        cache = DB.CacheCount(),
    }
end
