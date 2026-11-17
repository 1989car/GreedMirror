-- GreedMirror 贪婪镜 - Rate.lua
-- 纯函数判定逻辑（可在离线 Lua 中直接单测，不依赖任何暴雪接口）。
--
-- 输入：N=需求次数、G=贪婪次数、E=进入 5 人副本次数。
-- 三道关卡：
--   1) 三个计数任意一个不可读 → 数据不可读（绝不用 0 代替）。
--   2) 活跃度：E < 4 → 数据不足；R=N+G < 5.4*E → 判为“低”（不算需求率）。
--   3) 分档：R < 20 → 样本少（不判档）；否则按 P=N/(N+G) 分档，
--      P>=50% 且 R>=30 → 极高（红），P>=50% 且 20<=R<30 → 偏高（黄）。
local ADDON, GM = ...

local Rate = {}
GM.Rate = Rate

local DEFAULTS = {
    activeMul = 5.4,       -- 活跃度门槛系数：R 必须 >= activeMul * E
    minDungeons = 4,      -- 进本次数下限，不足则“数据不足”
    minRolls = 20,        -- 掷骰总数下限，不足则“样本少”
    redRolls = 30,        -- P>=50% 时，掷骰达到该值才算“极高”
    darkGreenBelow = 0.10,
    greenBelow = 0.30,
    yellowBelow = 0.50,
}

local function rule()
    local r = (GM and GM.RULE) or nil
    if type(r) ~= "table" then return DEFAULTS end
    local out = {}
    for key, fallback in pairs(DEFAULTS) do
        local v = r[key]
        if type(v) ~= "number" then v = fallback end
        out[key] = v
    end
    return out
end

local function isCount(v)
    return type(v) == "number" and v == v and v >= 0 and v < math.huge and v == math.floor(v)
end
Rate.IsCount = isCount

-- 返回结果表：
--   status: nodata | insufficient | low | small | rated
--   band:   darkgreen | green | yellow | red（仅 status == "rated" 时存在）
--   ratio:  需求率 0..1（low 时不给出）
function Rate.Evaluate(row)
    local out = { status = "nodata", need = nil, greed = nil, dungeons = nil }
    if type(row) ~= "table" then return out end

    out.need, out.greed, out.dungeons = row.need, row.greed, row.dungeons
    local missing = {}
    if not isCount(out.need) then missing[#missing + 1] = "need" end
    if not isCount(out.greed) then missing[#missing + 1] = "greed" end
    if not isCount(out.dungeons) then missing[#missing + 1] = "dungeons" end
    if #missing > 0 then
        out.missing = missing
        return out
    end

    local r = rule()
    local N, G, E = out.need, out.greed, out.dungeons
    local rolls = N + G
    out.rolls = rolls
    out.threshold = r.activeMul * E

    if E < r.minDungeons then
        out.status = "insufficient"
        return out
    end

    if rolls < out.threshold then
        out.status = "low"
        return out
    end

    if rolls < r.minRolls then
        out.status = "small"
        out.ratio = rolls > 0 and (N / rolls) or nil
        return out
    end

    out.ratio = N / rolls
    if out.ratio < r.darkGreenBelow then
        out.band = "darkgreen"
    elseif out.ratio < r.greenBelow then
        out.band = "green"
    elseif out.ratio < r.yellowBelow then
        out.band = "yellow"
    elseif rolls >= r.redRolls then
        out.band = "red"
    else
        out.band = "yellow" -- 极高封顶：样本仍偏少
    end
    out.status = "rated"
    return out
end

-- 是否属于“高需求率”名单（design.md：对 P >= 50% 的玩家保存姓名与 guid）。
-- 只统计通过三道关卡（status == "rated"）的玩家：
-- 被判为“低”的放弃型玩家虽然原始 P 也很高，但那是假象，不应入名单。
function Rate.IsHighRate(result)
    if type(result) ~= "table" then return false end
    if result.status ~= "rated" then return false end
    local ratio = result.ratio
    if type(ratio) ~= "number" then return false end
    return ratio >= 0.5
end

-- 档位摘要（返回中文短词，供聊天/屏幕提示使用）。
function Rate.SummaryWord(result)
    if type(result) ~= "table" then return nil end
    if result.status == "rated" then
        if result.band == "red" then return "极高" end
        if result.band == "yellow" then return "偏高" end
        return "正常"
    end
    return nil
end
