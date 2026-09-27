--[[
    数学谋杀案 · 自动答题 v1.0
    ============ 功能 ============
    - 自动读取大屏题目(算式), 脚本本地计算答案
    - 固定延迟模式: 1-5秒可调(滑条)
    - 随机延迟模式: 每题在[min,max]范围内随机(默认1-5, 范围可调)
    - 面板: 总开关 + 模式切换 + 3个滑条 + 实时状态
    协议: GameEvent:FireServer("updateAnswer", ans) → ("submitAnswer", ans)
    等价于键盘输入+回车提交
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local GameEvent = ReplicatedStorage:WaitForChild("Events"):WaitForChild("GameEvent")

-- ================= 配置 =================
local state = {
    enabled = true,      -- 总开关
    randomMode = false,  -- false=固定延迟 true=随机延迟
    fixedDelay = 2.5,    -- 固定延迟(1-5)
    rMin = 1,            -- 随机下限
    rMax = 5,            -- 随机上限
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
    ["×"] = function(a, b) return a * b end,
    ["/"] = function(a, b) return a / b end,
    ["÷"] = function(a, b) return a / b end,
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
    local r = f(na, nb)
    return string.format("%g", r)
end

-- ---------- 延迟 ----------
local function computeDelay()
    if state.randomMode then
        local lo = math.min(state.rMin, state.rMax)
        local hi = math.max(state.rMin, state.rMax)
        local v = lo + math.random() * (hi - lo)
        return math.floor(v * 10 + 0.5) / 10
    end
    return state.fixedDelay
end

-- ---------- 面板 ----------
local gui = Instance.new("ScreenGui")
gui.Name = "_mma_autoanswer"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 200, 0, 236)
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
title.Text = "数学谋杀案 自动答题"
title.TextColor3 = Color3.fromRGB(235, 235, 245)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Parent = frame

local function makeToggle(name, y, get, set)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -16, 0, 28)
    btn.Position = UDim2.new(0, 8, 0, y)
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 13
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

local status
local function setStatus(text)
    if status then status.Text = text end
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
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            setFromX(input.Position.X)
        end
    end)
    fill.Size = UDim2.new((init - minV) / (maxV - minV), 0, 1, 0)
    lbl.Text = string.format(labelFmt, init)
end

makeToggle("自动答题", 28, function() return state.enabled end, function(v)
    state.enabled = v
end)

makeToggle("延迟模式", 62, function() return state.randomMode end, function(v)
    state.randomMode = v
end)

makeSlider(96, "固定延迟: %.1f 秒", 1, 5, state.fixedDelay, function(v)
    state.fixedDelay = v
end)

makeSlider(128, "随机下限: %.1f 秒", 1, 5, state.rMin, function(v)
    state.rMin = v
end)

makeSlider(160, "随机上限: %.1f 秒", 1, 5, state.rMax, function(v)
    state.rMax = v
end)

status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 44)
status.Position = UDim2.new(0, 8, 0, 190)
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
local lastSeen = nil
local submitCount = 0

local function handleQuestion(q)
    if q == nil or q == "" then return end
    local ans = parseMath(q)
    if not ans then
        setStatus("未识别题目: " .. q)
        return
    end
    task.spawn(function()
        local delay = computeDelay()
        setStatus(string.format("计算: %s %s | %.1fs后提交", q, ans, delay))
        local t0 = os.clock()
        while os.clock() - t0 < delay do
            if questionText.Text ~= q then return end -- 题目已轮换
            task.wait(0.05)
        end
        if questionText.Text ~= q then return end
        typingText.Text = ans
        -- 同步到本地输入框(视觉一致, 游戏自己的处理器会同步updateAnswer)
        pcall(function()
            local tb = lp.PlayerGui.MainGui.GameFrame.PCTextBoxContainer.TextBox
            if tb then tb.Text = ans end
        end)
        GameEvent:FireServer("updateAnswer", string.lower(ans))
        task.wait(0.15)
        if questionText.Text ~= q then return end
        GameEvent:FireServer("submitAnswer", string.lower(ans))
        submitCount = submitCount + 1
        setStatus(string.format("已提交: %s%s (第%d题)", q, ans, submitCount))
    end)
end

questionText:GetPropertyChangedSignal("Text"):Connect(function()
    local q = questionText.Text
    if q ~= lastSeen then
        lastSeen = q
        if state.enabled then
            handleQuestion(q)
        else
            setStatus("自动答题已关闭")
        end
    end
end)

-- 初始: 若加载时已有题目(且与缓存不同)也作答
task.defer(function()
    task.wait(0.5)
    local q = questionText.Text
    if q ~= lastSeen then
        lastSeen = q
        if state.enabled then handleQuestion(q) end
    end
end)

print("[MathMurder AutoAnswer v1.0] 已加载: 自动计算+提交 | 固定" .. state.fixedDelay .. "s / 随机" .. state.rMin .. "-" .. state.rMax .. "s")
