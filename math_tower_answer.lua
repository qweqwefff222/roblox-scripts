--[[
    数学塔赛 · 自动答题 v1.0
    ============ 功能 ============
    - 监视 RoundControlFolder.TopicControl.TopicName 变化 → 按 TopicType 解析并本地计算答案
    - 支持题型: add/sub/mul/div 加减乘除, exp 幂运算, algebra 未知数方程,
      seq_arithmetic/seq_geometric 数列, odd_or_even 奇偶, rounding 四舍五入,
      fractions/fractionToPercent/percentageToFraction 分数转换,
      simpleComparison/fractionComparison 比较, analogToDigitalTime 时钟,
      perimeterOfShape 周长, areaOfShape 面积, identifyHowMuchMoney 数钱
      (identifyAngleType/identifyAngleLines 图形角度暂不支持, 自动跳过)
    - 安全策略: 计算结果必须与 4 个选项之一精确匹配才提交, 匹配不到绝不乱交
    - 固定延迟 / 随机延迟 两个独立开关(同款UI): 只开一个用它, 都开每题二选一, 都关立即提交
    - 单例守护: 重复执行自动杀旧实例
    提交协议: Remotes.SubmitAnswerRemote:InvokeServer(选项值 .. "  ", "Selection_Mouse")
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local SubmitAnswerRemote = Remotes:WaitForChild("SubmitAnswerRemote")
local RC = ReplicatedStorage:WaitForChild("RoundControlFolder")
local TopicControl = RC:WaitForChild("TopicControl")
local TopicName = TopicControl:WaitForChild("TopicName")
local TopicType = TopicControl:WaitForChild("TopicType")
local AnswerControl = RC:WaitForChild("AnswerControl")
local SpecialControl = TopicControl:WaitForChild("SpecialControl")

-- ================= 单例守护 =================
if getgenv()._MTA_INST and typeof(getgenv()._MTA_INST.kill) == "function" then
    pcall(function() getgenv()._MTA_INST.kill() end)
end
local INST = { alive = true, conns = {} }
getgenv()._MTA_INST = INST
local function bind(c) table.insert(INST.conns, c) end

-- ================= 配置 =================
local state = {
    enabled = true,
    fixedOn = true,
    randomOn = false,
    fixedDelay = 2.0,
    rMin = 1,
    rMax = 5,
}
-- ========================================

-- ================= 日志(落盘 + 内存缓冲) =================
local LOG_FILE = "math_tower_log.txt"
local logBuf = {}
local function log(msg)
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg))
    table.insert(logBuf, line)
    if #logBuf > 300 then
        local keep = {}
        for i = #logBuf - 199, #logBuf do keep[#keep + 1] = logBuf[i] end
        logBuf = keep
    end
    getgenv()._MTA_LOG = logBuf
    pcall(function()
        if writefile then
            local old = ""
            if isfile and isfile(LOG_FILE) then
                old = readfile(LOG_FILE)
                if #old > 150000 then old = "" end -- 超限重置
            end
            writefile(LOG_FILE, old .. line .. "\n")
        end
    end)
end

-- ---------- 工具 ----------
local function fmt(n)
    if n == math.floor(n) then return tostring(math.floor(n)) end
    return string.format("%g", n)
end

local function gcd(a, b)
    while b ~= 0 do a, b = b, a % b end
    return a
end

local function fracStr(a, b)
    if b == 0 then return nil end
    local g = gcd(math.abs(a), math.abs(b))
    a, b = a / g, b / g
    if b < 0 then a, b = -a, -b end
    return a .. "/" .. b
end

local VULGAR = {
    ["\u{00BC}"] = {1,4}, ["\u{00BD}"] = {1,2}, ["\u{00BE}"] = {3,4},
    ["\u{2153}"] = {1,3}, ["\u{2154}"] = {2,3},
    ["\u{2155}"] = {1,5}, ["\u{2156}"] = {2,5}, ["\u{2157}"] = {3,5}, ["\u{2158}"] = {4,5},
    ["\u{2159}"] = {1,6}, ["\u{215A}"] = {5,6},
    ["\u{215B}"] = {1,8}, ["\u{215C}"] = {3,8}, ["\u{215D}"] = {5,8}, ["\u{215E}"] = {7,8},
    ["\u{2150}"] = {1,7}, ["\u{2151}"] = {1,9}, ["\u{2152}"] = {1,10},
}
local VULGAR_BY_VALUE = {}
for k, v in pairs(VULGAR) do
    VULGAR_BY_VALUE[v[1] / v[2]] = k
end

-- 把任意选项/答案文本解析成数值(尽量)
local function toNumber(s)
    if typeof(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$") -- trim
    if s == "" then return nil end
    -- 百分比
    local pct = s:match("^(%-?%d+%.?%d*)%%$")
    if pct then return tonumber(pct), "pct" end
    -- 普通分数 a/b
    local a, b = s:match("^(%-?%d+)%s*/%s*(%-?%d+)$")
    if a and b and tonumber(b) ~= 0 then return tonumber(a) / tonumber(b), "frac" end
    -- 竖式分数(unicode)
    if VULGAR[s] then return VULGAR[s][1] / VULGAR[s][2], "frac" end
    -- 金钱 $x.xx
    local money = s:match("^%$%s*(%-?%d+%.?%d*)$") or s:match("^(%-?%d+%.?%d*)%s*¢$") or s:match("^(%-?%d+%.?%d*)%s*cents$")
    if money then return tonumber(money), "money" end
    -- 纯数字
    local n = tonumber(s)
    if n then return n, "num" end
    return nil
end

-- ---------- 方程求解: 4 x ? = 40 / ? + 5 = 12 / 3 + 4 = ??? ----------
local OPSF = {
    ["+"] = function(x, y) return x + y end,
    ["-"] = function(x, y) return x - y end,
    ["*"] = function(x, y) return x * y end,
    ["/"] = function(x, y) return x / y end,
}
local function solveEquation(s)
    -- 形式A: a op b = ??? (无未知数, 纯计算)
    local a, op, b = s:match("^%s*(%-?%d+%.?%d*)%s*([%+%-%*xX/])%s*(%-?%d+%.?%d*)%s*=%s*%?+")
    if a then
        if op == "x" or op == "X" then op = "*" end
        local f = OPSF[op]
        if f then
            local n = f(tonumber(a), tonumber(b))
            if n then return {text = fmt(n), num = n} end
        end
    end
    -- 形式B: ? 在左: ? op b = r
    local q1, op1, b1, r1 = s:match("^%s*([%?%d]+%.?%d*)%s*([%+%-%*xX/])%s*(%-?%d+%.?%d*)%s*=%s*(%-?%d+%.?%d*)")
    if q1 and (q1:find("?") or q1:find("\u{FF1F}")) then
        if op1 == "x" or op1 == "X" then op1 = "*" end
        local nb, nr = tonumber(b1), tonumber(r1)
        local n
        if op1 == "+" then n = nr - nb
        elseif op1 == "-" then n = nr + nb
        elseif op1 == "*" and nb ~= 0 then n = nr / nb
        elseif op1 == "/" then n = nr * nb
        end
        if n then return {text = fmt(n), num = n} end
    end
    -- 形式C: ? 在中: a op ? = r
    local a2, op2, q2, r2 = s:match("^%s*(%-?%d+%.?%d*)%s*([%+%-%*xX/])%s*([%?%d]+%.?%d*)%s*=%s*(%-?%d+%.?%d*)")
    if a2 and q2 and (q2:find("?") or q2:find("\u{FF1F}")) then
        if op2 == "x" or op2 == "X" then op2 = "*" end
        local na, nr = tonumber(a2), tonumber(r2)
        local n
        if op2 == "+" then n = nr - na
        elseif op2 == "-" then n = na - nr
        elseif op2 == "*" and na ~= 0 then n = nr / na
        elseif op2 == "/" then n = na / nr
        end
        if n then return {text = fmt(n), num = n} end
    end
    return nil
end

-- ---------- 各题型解析: 返回 {text=答案文本, num=数值} 或 nil ----------
local function parseQuestion(qtype, q)
    if typeof(q) ~= "string" or q == "" then return nil end
    -- 统一归一化
    local s = q:gsub("\u{00D7}", "*"):gsub("\u{00F7}", "/"):gsub("\u{2212}", "-")

    local function twoNumOp(opf)
        local a, op, b = s:match("^%s*(%-?%d+%.?%d*)%s*([%+%-%*xX/])%s*(%-?%d+%.?%d*)")
        if not a then return nil end
        if op == "x" or op == "X" then op = "*" end
        if op ~= "+" and op ~= "-" and op ~= "*" and op ~= "/" then return nil end
        local f = ({["+"] = function(x,y) return x+y end, ["-"] = function(x,y) return x-y end,
            ["*"] = function(x,y) return x*y end, ["/"] = function(x,y) return x/y end})[op]
        if opf then return opf(f, tonumber(a), tonumber(b)) end
        return f(tonumber(a), tonumber(b))
    end

    local isBasicPro = (qtype == "add" or qtype == "sub" or qtype == "mul" or qtype == "div")
        or (qtype:find("^pro_") == 1 and (qtype:find("add") or qtype:find("sub") or qtype:find("mul") or qtype:find("div")))
    if isBasicPro then
        local n = twoNumOp()
        if n then return {text = fmt(n), num = n} end
        -- pro_ 系列是 ? 方程(? + 12 = 1 等), 走方程求解
        return solveEquation(s)

    elseif qtype == "exp" or qtype:find("^pro_exp") == 1 then
        -- 9² / 2³ / 1³ = ? / 9^2  (上标字符双字节, 先归一化成 ^n 再匹配)
        s = s
            :gsub("\u{00B2}", "^2"):gsub("\u{00B3}", "^3"):gsub("\u{00B9}", "^1")
            :gsub("\u{2070}", "^0"):gsub("\u{2074}", "^4"):gsub("\u{2075}", "^5")
            :gsub("\u{2076}", "^6"):gsub("\u{2077}", "^7"):gsub("\u{2078}", "^8")
            :gsub("\u{2079}", "^9")
        local base, ex = s:match("(%d+)%s*%^%s*(%d+)")
        if base and ex then
            local n = tonumber(base) ^ tonumber(ex)
            return {text = fmt(n), num = n}
        end

    elseif qtype == "algebra" or qtype:find("algebra") == 1 then
        return solveEquation(s)

    elseif qtype == "seq_arithmetic" or qtype == "seq_geometric" or qtype == "seq" then
        -- 数列: 2, 4, 6, ? / 3, 9, ?, 81 (? 可在任意位置)
        local known = {}
        local missingIdx = nil
        local idx = 0
        for tok in s:gmatch("[^,]+") do
            idx = idx + 1
            local n = tonumber(tok:match("(%-?%d+%.?%d*)"))
            if n then
                known[#known + 1] = {i = idx, v = n}
            else
                missingIdx = idx
            end
        end
        if missingIdx and #known >= 2 then
            -- 等差
            local d, ok = nil, true
            for k = 2, #known do
                local dd = (known[k].v - known[k-1].v) / (known[k].i - known[k-1].i)
                if d == nil then d = dd
                elseif math.abs(dd - d) > 1e-6 then ok = false break end
            end
            if ok and d then
                local base = known[1]
                local n = base.v + d * (missingIdx - base.i)
                return {text = fmt(n), num = n}
            end
            -- 等比(需全正数)
            local allPos = true
            for _, kv in ipairs(known) do
                if kv.v <= 0 then allPos = false break end
            end
            if allPos then
                local r, ok2 = nil, true
                for k = 2, #known do
                    local rr = (known[k].v / known[k-1].v) ^ (1 / (known[k].i - known[k-1].i))
                    if r == nil then r = rr
                    elseif math.abs(rr - r) > 1e-6 then ok2 = false break end
                end
                if ok2 and r then
                    local base = known[1]
                    local n = base.v * r ^ (missingIdx - base.i)
                    return {text = fmt(n), num = n}
                end
            end
        end

    elseif qtype == "odd_or_even" then
        local n = tonumber(s:match("(%-?%d+)"))
        if n then
            return {text = (n % 2 == 0) and "even" or "odd", num = nil}
        end

    elseif qtype == "rounding" then
        -- 2.6 → 3 / Round 2.6
        local n = tonumber(s:match("(%-?%d+%.?%d*)"))
        if n then
            local r = math.floor(n + 0.5)
            return {text = fmt(r), num = r}
        end

    elseif qtype == "fractions" or qtype == "fractionToPercent" then
        -- ½ = ?% 或 1/2 = ?%
        local a, b
        a, b = s:match("(%d+)%s*/%s*(%d+)")
        if not a then
            for k, v in pairs(VULGAR) do
                if s:find(k, 1, true) then a, b = v[1], v[2] break end
            end
        end
        if a then
            local pct = a / b * 100
            local txt = fmt(pct)
            return {text = txt, num = pct, pctText = txt .. "%"}
        end

    elseif qtype == "percentageToFraction" then
        -- 50% = ? / 33.3% = ?  → 找最接近的小分母分数(33.3% → 1/3)
        local p = tonumber(s:match("(%-?%d+%.?%d*)%s*%%"))
        if p then
            local target = p / 100
            local bestN, bestD, bestErr = nil, nil, 1e9
            for den = 1, 16 do
                local num = math.floor(target * den + 0.5)
                local err = math.abs(num / den - target)
                if err < bestErr then
                    bestErr, bestN, bestD = err, num, den
                end
            end
            if bestN and bestN > 0 and bestErr <= 0.005 then
                local f = fracStr(bestN, bestD)
                if f then return {text = f, num = target, tol = 0.005} end
            end
        end

    elseif qtype == "simpleComparison" or qtype == "fractionComparison" then
        -- 格式1: A [?] B → 填 < = >
        -- 格式2: A > B → true/false
        local function sideVal(t)
            t = t:match("^%s*(.-)%s*$")
            local n = tonumber(t)
            if n then return n end
            if VULGAR[t] then return VULGAR[t][1] / VULGAR[t][2] end
            local a, b = t:match("(%d+)%s*/%s*(%d+)")
            if a and tonumber(b) ~= 0 then return tonumber(a) / tonumber(b) end
            return nil
        end
        local l, r = s:match("^%s*(%S+)%s*%[%?%]%s*(%S+)%s*$")
        if l then
            local lv, rv = sideVal(l), sideVal(r)
            if lv and rv then
                local sym = (lv > rv) and ">" or (lv < rv) and "<" or "="
                return {text = sym, kind = "compare"}
            end
        else
            local l2, op, r2 = s:match("^%s*(%S+)%s*([<>])%s*(%S+)%s*$")
            if l2 then
                local lv, rv = sideVal(l2), sideVal(r2)
                if lv and rv then
                    local isTrue = (op == ">" and lv > rv) or (op == "<" and lv < rv)
                    return {text = isTrue and "true" or "false", kind = "bool"}
                end
            end
        end

    elseif qtype == "analogToDigitalTime" then
        local ac = SpecialControl:FindFirstChild("AnalogControl")
        local r1 = ac and ac:FindFirstChild("Rotation1")
        local r2 = ac and ac:FindFirstChild("Rotation2")
        if r1 and r2 then
            local hourRot = tonumber(r1.Value) or 0
            local minRot = tonumber(r2.Value) or 0
            -- 判定哪个是时针: 分针角/6=分钟(整数), 时针角/30=小时(带小数)
            local hour, minute
            if minRot % 30 == 0 and hourRot % 30 ~= 0 then
                minute = minRot / 6
                hour = math.floor(hourRot / 30) % 12
            else
                hour = math.floor(hourRot / 30) % 12
                minute = minRot / 6
            end
            if hour == 0 then hour = 12 end
            if minute then
                local txt = string.format("%d:%02d", hour, minute)
                return {text = txt, num = hour * 60 + minute, time = true}
            end
        end

    elseif qtype == "perimeterOfShape" or qtype == "areaOfShape" then
        local sc = SpecialControl:FindFirstChild("ShapeControl")
        local shape = sc and sc:FindFirstChild("Shape")
        local s1 = sc and sc:FindFirstChild("Side1")
        local s2 = sc and sc:FindFirstChild("Side2")
        if shape and s1 then
            local sh = tostring(shape.Value):lower()
            local a = tonumber(s1.Value)
            local b = s2 and tonumber(s2.Value)
            local n
            if sh == "square" then
                n = (qtype == "perimeterOfShape") and a * 4 or a * a
            elseif sh == "rectangle" and b then
                n = (qtype == "perimeterOfShape") and (a + b) * 2 or a * b
            elseif sh == "triangle" then
                local s3 = sc:FindFirstChild("Side3")
                local c = s3 and tonumber(s3.Value)
                if qtype == "areaOfShape" then
                    -- 三角形面积 = 底 × 高 × 1/2 (Side1=底, Side2=高)
                    if b then n = a * b / 2 end
                elseif c then
                    n = a + b + c
                end
            end
            if n then return {text = fmt(n), num = n} end
        end

    elseif qtype == "identifyHowMuchMoney" then
        local mc = SpecialControl:FindFirstChild("MoneyControl")
        local disp = mc and mc:FindFirstChild("Display")
        if disp then
            local values = {Penny = 1, Nickel = 5, Dime = 10, Quarter = 25, HalfDollar = 50, Dollar = 100}
            local cents = 0
            for coin in tostring(disp.Value):gmatch("[%a]+") do
                local v = values[coin] or values[coin:lower():gsub("^%l", string.upper)]
                if v then cents = cents + v end
            end
            if cents > 0 then
                return {text = fmt(cents), num = cents, cents = cents}
            end
        end
    elseif qtype == "identifyAngleType" or qtype == "identifyAngleLines" then
        -- 角度/线型: 从 TopicGui.AngleFrame 里读预置图形两条线的 Rotation 差来分类
        local ac = SpecialControl:FindFirstChild("AngleControl")
        local shape = ac and ac:FindFirstChild("Shape")
        if shape then
            local tg = lp.PlayerGui.Gameplay:FindFirstChild("TopicGui")
            local af = tg and tg:FindFirstChildWhichIsA("Frame")
            local angleFrame = nil
            local function findAF(d)
                if angleFrame then return end
                if d.Name == "AngleFrame" and d:IsA("Frame") then angleFrame = d return end
                for _, c in ipairs(d:GetChildren()) do findAF(c) end
            end
            if tg then findAF(tg) end
            local f = angleFrame and angleFrame:FindFirstChild(tostring(shape.Value))
            if f then
                local r1, r2
                for _, c in ipairs(f:GetChildren()) do
                    if c.Name == "ANGLE1" then r1 = c.Rotation
                    elseif c.Name == "ANGLE2" then r2 = c.Rotation end
                end
                if r1 and r2 then
                    local d = math.abs(r1 - r2) % 360
                    if d > 180 then d = 360 - d end
                    if qtype == "identifyAngleType" then
                        local kind
                        if math.abs(d - 90) < 0.5 then kind = "right"
                        elseif math.abs(d - 180) < 0.5 then kind = "straight"
                        elseif d < 90 then kind = "acute"
                        else kind = "obtuse" end
                        return {text = kind, kind = "angle", deg = d}
                    else
                        local kind
                        if math.abs(d) < 0.5 then kind = "parallel"
                        elseif math.abs(d - 90) < 0.5 then kind = "perpendicular"
                        else kind = "intersecting" end
                        return {text = kind, kind = "lines"}
                    end
                end
            end
        end

    end

    return nil
end

-- ---------- 选项匹配 ----------
local KIND_KEYWORDS = {
    angle = {
        acute = {"尖锐", "锐角", "acute"},
        obtuse = {"奥图斯", "钝角", "obtuse"},
        ["right"] = {"直角", "对", "right"},
        straight = {"平角", "straight"},
        reflex = {"优角", "反角", "reflex"},
    },
    lines = {
        parallel = {"平行", "parallel"},
        perpendicular = {"垂直", "perpendicular"},
        intersecting = {"相交", "intersect"},
    },
    compare = {
        [">"] = {">"},
        ["<"] = {"<"},
        ["="] = {"=", "=="},
    },
    bool = {
        ["true"] = {"true", "yes", "correct", "是", "对"},
        ["false"] = {"false", "no", "incorrect", "否", "错"},
    },
}

local function findOption(ans)
    local best = nil
    for i = 1, 4 do
        local v = AnswerControl:FindFirstChild("Answer" .. i)
        if v then
            local opt = tostring(v.Value)
            if opt ~= "" then
                -- 精确文本(忽略大小写/空格)
                if opt:lower():gsub("%s", "") == ans.text:lower():gsub("%s", "") then
                    return opt
                end
                -- 语义分类匹配(角度/线型的本地化选项)
                if ans.kind and KIND_KEYWORDS[ans.kind] then
                    local kws = KIND_KEYWORDS[ans.kind][ans.text]
                    if kws then
                        local optLow = opt:lower()
                        for _, kw in ipairs(kws) do
                            if optLow:find(kw:lower(), 1, true) then
                                return opt
                            end
                        end
                    end
                end
                -- 数值匹配
                local ov, kind = toNumber(opt)
                if ov then
                    if ans.num ~= nil and math.abs(ov - ans.num) < 1e-6 then
                        return opt
                    end
                    -- 百分比选项 vs 小数值
                    if kind == "pct" and ans.num ~= nil and math.abs(ov - ans.num * 100) < 1e-6 then
                        return opt
                    end
                    -- 百分比答案文本 vs 数值选项
                    if ans.pctText and kind == "num" and math.abs(ov - ans.num) < 1e-6 then
                        return opt
                    end
                    -- 金钱: 分/元两算
                    if ans.cents then
                        if (kind == "money" and math.abs(ov - ans.cents / 100) < 1e-6)
                            or (kind == "num" and math.abs(ov - ans.cents) < 1e-6) then
                            return opt
                        end
                    end
                    -- 时间: 分钟数
                    if ans.time and kind == "num" and math.abs(ov - ans.num) < 1e-6 then
                        return opt
                    end
                end
                -- 时间文本匹配
                if ans.time and opt:match("^%d+:%d%d$") then
                    local h, m = opt:match("(%d+):(%d%d)")
                    if tonumber(h) * 60 + tonumber(m) == ans.num then return opt end
                end
            end
        end
    end
    return best
end

-- ---------- 延迟 ----------
local function randomDelay()
    local lo = math.min(state.rMin, state.rMax)
    local hi = math.max(state.rMin, state.rMax)
    return math.floor((lo + math.random() * (hi - lo)) * 10 + 0.5) / 10
end

local function pickDelay()
    if state.fixedOn and state.randomOn then
        if math.random() < 0.5 then return state.fixedDelay, "固定" end
        return randomDelay(), "随机"
    elseif state.fixedOn then
        return state.fixedDelay, "固定"
    elseif state.randomOn then
        return randomDelay(), "随机"
    end
    return 0, "立即"
end

-- ---------- 面板 ----------
if lp.PlayerGui:FindFirstChild("_mta_autoanswer") then
    lp.PlayerGui._mta_autoanswer:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "_mta_autoanswer"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 200, 0, 262)
frame.Position = UDim2.new(0, 20, 0, 140)
frame.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 24)
title.BackgroundTransparency = 1
title.Text = "数学塔赛 自动答题 v1.0"
title.TextColor3 = Color3.fromRGB(235, 235, 245)
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.Parent = frame

local status
local function setStatus(text)
    if status then status.Text = text end
end

local function makeToggle(name, y, get, set)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -16, 0, 26)
    btn.Position = UDim2.new(0, 8, 0, y)
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 12
    btn.BorderSizePixel = 0
    btn.Parent = frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    local function refresh()
        local on = get()
        btn.Text = name .. (on and ": 开" or ": 关")
        btn.BackgroundColor3 = on and Color3.fromRGB(60, 130, 90) or Color3.fromRGB(55, 58, 70)
        btn.TextColor3 = Color3.fromRGB(240, 240, 245)
    end
    btn.MouseButton1Click:Connect(function()
        set(not get())
        refresh()
    end)
    refresh()
    return btn
end

local function makeSlider(y, labelFmt, minV, maxV, init, onSet)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -16, 0, 28)
    row.Position = UDim2.new(0, 8, 0, y)
    row.BackgroundTransparency = 1
    row.Parent = frame
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 13)
    lbl.BackgroundTransparency = 1
    lbl.Text = ""
    lbl.TextColor3 = Color3.fromRGB(200, 205, 215)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 11
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row
    local track = Instance.new("TextButton")
    track.Size = UDim2.new(1, 0, 0, 11)
    track.Position = UDim2.new(0, 0, 0, 16)
    track.BackgroundColor3 = Color3.fromRGB(55, 58, 70)
    track.Text = ""
    track.BorderSizePixel = 0
    track.AutoButtonColor = false
    track.Parent = row
    Instance.new("UICorner", track).CornerRadius = UDim.new(0, 5)
    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0.5, 0, 1, 0)
    fill.BackgroundColor3 = Color3.fromRGB(90, 160, 110)
    fill.BorderSizePixel = 0
    fill.Parent = track
    Instance.new("UICorner", fill).CornerRadius = UDim.new(0, 5)
    local function setFromX(x)
        local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        local v = math.floor((minV + rel * (maxV - minV)) * 10 + 0.5) / 10
        fill.Size = UDim2.new(rel, 0, 1, 0)
        lbl.Text = string.format(labelFmt, v)
        onSet(v)
    end
    local dragging = false
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            setFromX(input.Position.X)
        end
    end)
    track.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    bind(UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            setFromX(input.Position.X)
        end
    end))
    fill.Size = UDim2.new((init - minV) / (maxV - minV), 0, 1, 0)
    lbl.Text = string.format(labelFmt, init)
end

makeToggle("自动答题", 28, function() return state.enabled end, function(v)
    state.enabled = v
    INST.gen = (INST.gen or 0) + 1
end)

makeToggle("固定延迟", 58, function() return state.fixedOn end, function(v)
    state.fixedOn = v
end)

makeToggle("随机延迟", 88, function() return state.randomOn end, function(v)
    state.randomOn = v
end)

makeSlider(120, "固定延迟: %.1f 秒", 1, 5, state.fixedDelay, function(v)
    state.fixedDelay = v
end)

makeSlider(152, "随机下限: %.1f 秒", 1, 5, state.rMin, function(v)
    state.rMin = v
end)

makeSlider(184, "随机上限: %.1f 秒", 1, 5, state.rMax, function(v)
    state.rMax = v
end)

status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 44)
status.Position = UDim2.new(0, 8, 0, 214)
status.BackgroundTransparency = 1
status.Text = "状态: 等待题目..."
status.TextColor3 = Color3.fromRGB(150, 200, 150)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextWrapped = true
status.Parent = frame

-- ---------- 答题主逻辑 ----------
local submitCount = 0

local function handleTopic()
    if not INST.alive or not state.enabled then return end
    local q = tostring(TopicName.Value)
    if q == "" then return end
    local qtype = tostring(TopicType.Value)
    -- 数据快照(诊断特殊题型)
    local snapParts = {}
    for _, d in ipairs(SpecialControl:GetDescendants()) do
        if d:IsA("ValueBase") then
            table.insert(snapParts, d.Name .. "=" .. tostring(d.Value))
        end
    end
    local ansOpts = {}
    for i = 1, 4 do
        local v = AnswerControl:FindFirstChild("Answer" .. i)
        table.insert(ansOpts, v and tostring(v.Value) or "?")
    end
    log(string.format("题目 | 类型=%s | 题=%s | 选项=[%s] | Special=[%s] | Timer=%s",
        qtype, q, table.concat(ansOpts, ","), table.concat(snapParts, ","), tostring(TopicControl.TimerValue and TopicControl.TimerValue.Value or "?")))
    local ans = parseQuestion(qtype, q)
    if not ans then
        log("解析失败 | 类型=" .. qtype .. " | 题=" .. q)
        setStatus("不支持的题型: " .. qtype .. " | " .. q)
        return
    end
    log(string.format("解析成功 | 计算=%s num=%s kind=%s", tostring(ans.text), tostring(ans.num), tostring(ans.kind)))
    local opt = findOption(ans)
    if not opt then
        log(string.format("无匹配选项 | 计算=%s | 选项=[%s]", ans.text, table.concat(ansOpts, ",")))
        setStatus(string.format("答案[%s]无匹配选项, 跳过 | %s", ans.text, q))
        return
    end
    local myGen = INST.gen
    task.spawn(function()
        local delay, tag = pickDelay()
        -- 按题目剩余时间截短延迟, 避免交上去已超时(返回 rate_limit)
        local tv = TopicControl:FindFirstChild("TimerValue")
        local remain = tv and tonumber(tv.Value) or nil
        if remain and remain < delay + 1 then
            if remain < 1.2 then
                log(string.format("跳过(剩余%.0fs不足) | %s", remain, q))
                setStatus(string.format("剩余时间不足(%.0fs), 跳过", remain))
                return
            end
            delay = math.max(0.2, remain - 1)
            tag = tag .. "-截短"
            log(string.format("延迟按剩余时间截短为%.1fs | %s", delay, q))
        end
        setStatus(string.format("%s %s = %s | %s延迟%.1fs", q, "→", opt, tag, delay))
        local t0 = os.clock()
        while os.clock() - t0 < delay do
            if not INST.alive or not state.enabled or INST.gen ~= myGen or tostring(TopicName.Value) ~= q then
                log("提交取消(题目轮换/关闭) | " .. q)
                return
            end
            setStatus(string.format("倒计时 %.1fs (%s延迟)", delay - (os.clock() - t0), tag))
            task.wait(0.1)
        end
        if not INST.alive or not state.enabled or INST.gen ~= myGen or tostring(TopicName.Value) ~= q then
            log("提交取消(延迟到期题目已变) | " .. q)
            return
        end
        local ok, result = pcall(function()
            return SubmitAnswerRemote:InvokeServer(opt .. "  ", "Selection_Mouse")
        end)
        if not ok then
            log("提交异常: " .. tostring(result))
            setStatus("提交异常: " .. tostring(result))
            return
        end
        submitCount = submitCount + 1
        if type(result) == "table" then
            log(string.format("提交 %s | correct=%s | 正确答案=%s | 返回字段=%s", opt, tostring(result.correct), tostring(result.answer), tostring(result.answer ~= nil and "有answer" or "无answer")))
            if result.correct then
                setStatus(string.format("已提交 %s ✓ 答对! (第%d题)", opt, submitCount))
            else
                setStatus(string.format("已提交 %s ✗ 正确:%s (第%d题)", opt, tostring(result.answer), submitCount))
            end
        else
            log("提交 " .. opt .. " | 返回=" .. tostring(result))
            setStatus(string.format("已提交 %s (第%d题)", opt, submitCount))
        end
    end)
end

-- ---------- 题目监视 ----------
local lastSeen = tostring(TopicName.Value)
bind(TopicName:GetPropertyChangedSignal("Value"):Connect(function()
    if not INST.alive then return end
    local q = tostring(TopicName.Value)
    if q == lastSeen then return end
    lastSeen = q
    if q ~= "" then
        -- 题目落地稍等选项同步
        task.spawn(function()
            task.wait(0.2)
            if INST.alive then handleTopic() end
        end)
    else
        INST.gen = (INST.gen or 0) + 1
        setStatus("等待题目...")
    end
end))

-- 初始已有题目也处理
task.spawn(function()
    task.wait(1)
    if INST.alive and tostring(TopicName.Value) ~= "" then
        handleTopic()
    end
end)

-- ---------- kill ----------
INST.gen = 0
INST.gui = gui
INST.kill = function()
    INST.alive = false
    for _, c in ipairs(INST.conns) do
        pcall(function() c:Disconnect() end)
    end
    if INST.gui then
        pcall(function() INST.gui:Destroy() end)
    end
end

log("[MathTower AutoAnswer v1.1] 脚本加载 | 单例守护已接管")
