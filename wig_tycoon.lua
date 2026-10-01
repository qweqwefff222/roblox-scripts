--[[
    剃头卖假发大亨 · 自动助手 v1.3 零等待+升级版
    ============ 协议(实测) ============
    - 收集: RequestItemCollect:InvokeServer(rarity, false) → "match"=成功
      ✅ 无距离校验, 全图任意位置隔空收集(实测73米+)
    - 上架: 货架 "Stock Shelf" 提示(靠近才生成) → fireproximityprompt
    - 收钱: "Collect Cash" 提示(靠近才生成)
    - 抽奖: RequestTimerRoll:InvokeServer() → table=成功 / false=冷却中(3分钟)
    ============ 功能(独立开关) ============
    [自动收集假发] 每0.8s全稀有度隔空收集(最快速度, 不用动)
    [自动上架+收钱] 靠近tycoon时自动触发货架/收钱提示
    [自动免费抽奖] 每30秒尝试一次 RequestTimerRoll, 成功后冷却3分钟
    单例守护 + 落盘日志
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local TE = game.ReplicatedStorage:WaitForChild("Events"):WaitForChild("TycoonEvents")
local CollectRemote = TE:WaitForChild("RequestItemCollect")
local RollRemote = game.ReplicatedStorage:WaitForChild("Events"):WaitForChild("Rewards"):WaitForChild("RequestTimerRoll")

-- ================= 单例守护 =================
if getgenv()._WT_INST and typeof(getgenv()._WT_INST.kill) == "function" then
    pcall(function() getgenv()._WT_INST.kill() end)
end
local INST = { alive = true, conns = {} }
getgenv()._WT_INST = INST
local function bind(c) table.insert(INST.conns, c) end

-- ================= 配置 =================
local state = {
    collect = true,   -- 自动收集假发(零等待极限速度)
    shelf = true,     -- 自动上架(Stock Shelf)
    cash = true,      -- 自动收钱(Collect Cash, 隔空)
    roll = true,      -- 自动免费抽奖
    buy = true,       -- 自动买建筑(只买现金, 跳过宝石)
    fix = true,       -- 自动修理
    upgrade = true,   -- 自动升级机器
}
-- ========================================

-- ---------- 日志 ----------
local logBuf = {}
local function log(msg)
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg))
    table.insert(logBuf, line)
    if #logBuf > 200 then
        local keep = {}
        for i = #logBuf - 99, #logBuf do keep[#keep + 1] = logBuf[i] end
        logBuf = keep
    end
    getgenv()._WT_LOG = logBuf
    pcall(function()
        if writefile then
            local old = ""
            if isfile and isfile("wig_tycoon_log.txt") then
                old = readfile("wig_tycoon_log.txt")
                if #old > 100000 then old = "" end
            end
            writefile("wig_tycoon_log.txt", old .. line .. "\n")
        end
    end)
end

-- ---------- 面板 ----------
if lp.PlayerGui:FindFirstChild("_wt_panel") then
    lp.PlayerGui._wt_panel:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "_wt_panel"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 200, 0, 278)
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
title.Text = "假发大亨 自动助手"
title.TextColor3 = Color3.fromRGB(235, 235, 245)
title.Font = Enum.Font.GothamBold
title.TextSize = 12
title.Parent = frame

local status
local function setStatus(t)
    if status then status.Text = t end
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

makeToggle("自动收集假发(极速)", 28, function() return state.collect end, function(v)
    state.collect = v
end)

makeToggle("自动上架", 58, function() return state.shelf end, function(v)
    state.shelf = v
end)

makeToggle("自动收钱", 88, function() return state.cash end, function(v)
    state.cash = v
end)

makeToggle("自动免费抽奖", 118, function() return state.roll end, function(v)
    state.roll = v
end)

makeToggle("自动买建筑(非宝石)", 148, function() return state.buy end, function(v)
    state.buy = v
end)

makeToggle("自动修理机器", 178, function() return state.fix end, function(v)
    state.fix = v
end)

makeToggle("自动升级机器", 208, function() return state.upgrade end, function(v)
    state.upgrade = v
end)

status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 42)
status.Position = UDim2.new(0, 8, 0, 238)
status.BackgroundTransparency = 1
status.Text = "状态: 等待..."
status.TextColor3 = Color3.fromRGB(150, 200, 150)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextWrapped = true
status.Parent = frame

-- ---------- 收集(极限速度专职线程) ----------
local collected = 0
local collectRate = 0
task.spawn(function()
    while INST.alive do
        if state.collect then
            local cycleGot, t0 = 0, os.clock()
            for r = 1, 6 do
                if not INST.alive then break end
                local ok, res = pcall(function()
                    return CollectRemote:InvokeServer(r, false)
                end)
                if ok and res == "match" then
                    cycleGot = cycleGot + 1
                    collected = collected + 1
                end
            end
            local dt = os.clock() - t0
            if dt > 0.3 then
                collectRate = cycleGot / dt
            end
            if cycleGot == 0 then
                task.wait(0.25)
            else
                task.wait() -- 零等待, 背靠背极限速度(物理上限=RTT)
            end
        else
            task.wait(0.5)
        end
    end
end)

-- ---------- 上架+收钱(靠近tycoon时生效) ----------
local function findMyTycoon()
    for _, t in ipairs(game.Workspace.TycoonSystem.Tycoons:GetChildren()) do
        local o = t:FindFirstChild("Data") and t.Data:FindFirstChild("Owner")
        if o and o.Value == lp then return t end
    end
    return nil
end

-- 提示缓存: 20秒重建一次(全树扫描很贵, tycoon有上千实例)
local promptCache = {}
local promptCacheAt = 0
local function refreshPromptCache()
    promptCache = {}
    local myTy = findMyTycoon()
    if myTy then
        for _, d in ipairs(myTy:GetDescendants()) do
            if d:IsA("ProximityPrompt") then
                table.insert(promptCache, d)
            end
        end
    end
    promptCacheAt = os.clock()
end

-- 遍历缓存(便宜: 只读属性, 不扫树)
local function firePrompts()
    if os.clock() - promptCacheAt > 20 then
        refreshPromptCache()
    end
    local shelfN, cashN, buyN, upN, fixN = 0, 0, 0, 0, 0
    for _, d in ipairs(promptCache) do
        if not INST.alive then break end
        if d.Parent and d.Enabled then
            local act = d.ActionText or ""
            local hit = false
            if state.shelf and act == "Stock Shelf" then
                shelfN = shelfN + 1; hit = true
            elseif state.cash and act == "Collect Cash" then
                cashN = cashN + 1; hit = true
            elseif state.buy and act:match("^Buy: %$%d") then
                buyN = buyN + 1; hit = true
            elseif state.upgrade and act:match("^Upgrade") then
                upN = upN + 1; hit = true
            elseif state.fix and act == "Fix" then
                fixN = fixN + 1; hit = true
            end
            if hit then
                pcall(function() fireproximityprompt(d) end)
                task.wait(0.12)
            end
        end
    end
    return shelfN, cashN, buyN, upN, fixN
end

-- ---------- 抽奖 ----------
local rollOk = 0
local nextRollTry = 0

-- ---------- 主循环 ----------
task.spawn(function()
    while INST.alive do
        local ok, err = pcall(function()
            local now = os.clock()
            -- 全部提示处理(上架/收钱/买建筑/升级/修理, 用缓存不扫树)
            if now - (INST.lastSell or 0) >= 0.8 then
                INST.lastSell = now
                local sn, cn, bn, un, fn = firePrompts()
                if sn + cn + bn + un + fn > 0 then
                    log(string.format("上架%d 收钱%d 买%d 升级%d 修%d", sn, cn, bn, un, fn))
                end
            end
            -- 抽奖
            if state.roll and now >= nextRollTry then
                nextRollTry = now + 30
                local okr, res = pcall(function()
                    return RollRemote:InvokeServer()
                end)
                if okr and res ~= false then
                    rollOk = rollOk + 1
                    nextRollTry = now + 185 -- 3分钟冷却+5秒余量
                    log("免费抽奖成功 x" .. rollOk)
                end
            end
            -- 状态
            local cd = math.max(0, nextRollTry - now)
            setStatus(string.format("收集%d (%.1f/s) | 抽奖%d 冷却%.0fs", collected, collectRate, rollOk, cd))
        end)
        if not ok then
            log("主循环异常: " .. tostring(err))
        end
        task.wait(0.25)
    end
end)

log("[WigTycoon v1.2] 加载")
print("[WigTycoon v1.0] 自动助手已加载 | 单例守护")

-- ---------- kill ----------
INST.kill = function()
    INST.alive = false
    for _, c in ipairs(INST.conns) do
        pcall(function() c:Disconnect() end)
    end
    if gui then
        pcall(function() gui:Destroy() end)
    end
end
