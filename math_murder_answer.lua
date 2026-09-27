--[[
    数学谋杀案 · 自动答题 v1.1
    ============ v1.1 修复 ============
    1. 单例守护: 重复执行自动杀掉旧实例(不再叠加副本)
    2. 回合门控: 只在收到服务器 Answering(轮到你) 时答题,
       别人的题目绝不提交 -> 修复"算别人的题"和莫名秒死
    3. 固定延迟 / 随机延迟 拆成两个独立开关
       - 只开一个 = 用它; 两个都开 = 每题随机二选一; 都关 = 立即提交
    4. 倒计时期间: 死亡/回合结束/题目轮换/关闭开关 都会自动取消提交
    5. 状态栏显示实时倒计时(延迟肉眼可见)
    ==================================
    协议: GameEvent:FireServer("updateAnswer", ans) → ("submitAnswer", ans)
    等价于键盘输入+回车提交
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local GameEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("GameEvent")

-- ================= 单例守护 =================
if getgenv()._MMA_INST and typeof(getgenv()._MMA_INST.kill) == "function" then
    pcall(function() getgenv()._MMA_INST.kill() end)
end
local INST = { alive = true, conns = {} }
getgenv()._MMA_INST = INST
local function bind(c) table.insert(INST.conns, c) end

-- ================= 配置 =================
local state = {
    enabled = true,    -- 自动答题总开关
    fixedOn = true,    -- 固定延迟开关
    randomOn = false,  -- 随机延迟开关
    fixedDelay = 2.5,  -- 固定延迟(1-5)
    rMin = 1,          -- 随机下限
    rMax = 5,          -- 随机上限
}
-- ========================================

-- ---------- 题目屏幕 ----------
local txtContainer = workspace:WaitForChild("Map"):WaitForChild("Functional")
    :WaitForChild("Screen"):WaitForChild("SurfaceGui"):WaitForChild("MainFrame")
    :WaitForChild("MainGameContainer"):WaitForChild("MainTxtContainer")
local questionText = txtContainer:WaitForChild("QuestionText")
local typingText = txtContainer:WaitForChild("TypingText")

-- ---------- 算式解析 ----------
local ops = {
    ["+"] = function(a, b) return a + b end,
    ["-"] = function(a, b) return a - b end,
    ["*"] = function(a, b) return a * b end,
    ["x"] = function(a, b) return a * b end,
    ["X"] = function(a, b) return a * b end,
    ["/"] = function(a, b) return a / b end,
}

local function parseMath(q)
    -- 归一化双字节运算符: × → *, ÷ → /
    q = q:gsub("\195\151", "*"):gsub("\195\183", "/")
    local a, op, b = string.match(q, "^%s*(%-?%d+%.?%d*)%s*([%+%-%*xX/])%s*(%-?%d+%.?%d*)%s*=%s*$")
    if not a then return nil end
    local f = ops[op]
    if not f then return nil end
    local na, nb = tonumber(a), tonumber(b)
    if not na or not nb then return nil end
    return string.format("%g", f(na, nb))
end

-- ---------- 回合状态 ----------
local myTurn = false
local gen = 0 -- 取消代计数(任何中断都+1使在途提交失效)

-- ---------- 延迟 ----------
local function randomDelay()
    local lo = math.min(state.rMin, state.rMax)
    local hi = math.max(state.rMin, state.rMax)
    return math.floor((lo + math.random() * (hi - lo)) * 10 + 0.5) / 10
end

local function pickDelay()
    if state.fixedOn and state.randomOn then
        if math.random() < 0.5 then
            return state.fixedDelay, "固定"
        end
        return randomDelay(), "随机"
    elseif state.fixedOn then
        return state.fixedDelay, "固定"
    elseif state.randomOn then
        return randomDelay(), "随机"
    end
    return 0, "立即"
end

-- ---------- 面板 ----------
if lp.PlayerGui:FindFirstChild("_mma_autoanswer") then
    lp.PlayerGui._mma_autoanswer:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "_mma_autoanswer"
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
title.Text = "数学谋杀案 自动答题 v1.1"
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
    gen = gen + 1 -- 取消在途提交
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
status.Text = "状态: 等待你的回合..."
status.TextColor3 = Color3.fromRGB(150, 200, 150)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextWrapped = true
status.Parent = frame

-- ---------- 答题主逻辑 ----------
local submitCount = 0

local function tryAnswer(q)
    if not state.enabled then
        setStatus("自动答题已关闭")
        return
    end
    if not myTurn then return end
    if q == nil or q == "" then return end
    local ans = parseMath(q)
    if not ans then
        setStatus("未识别题目: " .. q)
        return
    end
    local myGen = gen
    task.spawn(function()
        local delay, tag = pickDelay()
        setStatus(string.format("计算: %s = %s | %s延迟 %.1fs", q, ans, tag, delay))
        local t0 = os.clock()
        while os.clock() - t0 < delay do
            if not INST.alive or not state.enabled or not myTurn or gen ~= myGen or questionText.Text ~= q then
                return -- 已取消(死亡/回合结束/题目轮换/关闭)
            end
            setStatus(string.format("倒计时 %.1fs (%s延迟)", delay - (os.clock() - t0), tag))
            task.wait(0.1)
        end
        if not INST.alive or not state.enabled or not myTurn or gen ~= myGen or questionText.Text ~= q then
            return
        end
        typingText.Text = ans
        pcall(function()
            local tb = lp.PlayerGui.MainGui.GameFrame.PCTextBoxContainer.TextBox
            if tb then tb.Text = ans end
        end)
        GameEvent:FireServer("updateAnswer", string.lower(ans))
        task.wait(0.15)
        if not INST.alive or gen ~= myGen or questionText.Text ~= q then return end
        GameEvent:FireServer("submitAnswer", string.lower(ans))
        submitCount = submitCount + 1
        setStatus(string.format("已提交: %s%s (第%d题)", q, ans, submitCount))
    end)
end

-- ---------- 服务器指令监听(回合门控核心) ----------
bind(GameEvent.OnClientEvent:Connect(function(cmd)
    if not INST.alive then return end
    if cmd == "Answering" then
        -- 轮到你了(该事件只发给正在作答的玩家)
        myTurn = true
        gen = gen + 1
        setStatus("轮到你作答")
        task.spawn(function()
            task.wait(0.15)
            if INST.alive and myTurn then
                tryAnswer(questionText.Text)
            end
        end)
    elseif cmd == "StopAnswering" then
        myTurn = false
        gen = gen + 1
        setStatus("回合结束")
    elseif cmd == "Died" then
        myTurn = false
        gen = gen + 1
        setStatus("已死亡, 自动答题暂停")
    elseif cmd == "CorrectAnswer" then
        setStatus("上次答对了 ✓")
    elseif cmd == "IncorrectAnswer" then
        setStatus("上次答错了 ✗")
    end
end))

-- ---------- 题目变化(仅自己回合内处理新题) ----------
local lastSeen = questionText.Text
bind(questionText:GetPropertyChangedSignal("Text"):Connect(function()
    if not INST.alive then return end
    local q = questionText.Text
    if q ~= lastSeen then
        lastSeen = q
        if myTurn then
            tryAnswer(q)
        end
    end
end))

-- ---------- kill ----------
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

print("[MathMurder AutoAnswer v1.1] 已加载: 回合门控+单例守护 | 固定" .. tostring(state.fixedOn) .. " / 随机" .. tostring(state.randomOn))
