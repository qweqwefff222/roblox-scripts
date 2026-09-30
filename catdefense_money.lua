--[[
    猫的防御 · 货币漏洞利用 v1.0
    ============ 已验证漏洞 ============
    MoneyEvent:FireServer(任意金额) → 金币直接增加, 服务器无校验
    ExpEvent:FireServer(任意经验)  → 经验直接增加, 服务器无校验
    ============ 功能 ============
    [自动刷金币] 开 + 金额滑条(步进500) + 间隔滑条
    [自动刷经验] 开 + 经验滑条(步进100)
    状态栏实时显示 Coins/Exp/Level
    ⚠ 服务器可见你发了多少: 金额/频率自己把握, 官方随时可能修复/回档/封号
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local MoneyEvent = game.ReplicatedStorage:WaitForChild("Events"):WaitForChild("MoneyEvent")
local ExpEvent = game.ReplicatedStorage:WaitForChild("Events"):WaitForChild("ExpEvent")

-- ================= 单例守护 =================
if getgenv()._CDM_INST and typeof(getgenv()._CDM_INST.kill) == "function" then
    pcall(function() getgenv()._CDM_INST.kill() end)
end
local INST = { alive = true, conns = {} }
getgenv()._CDM_INST = INST
local function bind(c) table.insert(INST.conns, c) end

-- ================= 配置 =================
local state = {
    money = true,       -- 自动刷金币
    moneyAmount = 5000, -- 每笔金额
    exp = false,        -- 自动刷经验
    expAmount = 1000,   -- 每笔经验
    interval = 2,       -- 发放间隔(秒)
}
-- ========================================

-- ---------- 面板 ----------
if lp.PlayerGui:FindFirstChild("_cdm_panel") then
    lp.PlayerGui._cdm_panel:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "_cdm_panel"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 210, 0, 262)
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
title.Text = "猫的防御 货币漏洞刷取"
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

local function makeSlider(y, labelFmt, minV, maxV, init, step, onSet)
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
        local raw = minV + rel * (maxV - minV)
        local v = math.floor(raw / step + 0.5) * step
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

makeToggle("自动刷金币", 28, function() return state.money end, function(v)
    state.money = v
end)

makeSlider(58, "每笔金额: %d", 500, 50000, state.moneyAmount, 500, function(v)
    state.moneyAmount = v
end)

makeToggle("自动刷经验", 92, function() return state.exp end, function(v)
    state.exp = v
end)

makeSlider(122, "每笔经验: %d", 100, 10000, state.expAmount, 100, function(v)
    state.expAmount = v
end)

makeSlider(156, "发放间隔: %.1f秒", 0.5, 10, state.interval, 0.5, function(v)
    state.interval = v
end)

status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 56)
status.Position = UDim2.new(0, 8, 0, 190)
status.BackgroundTransparency = 1
status.Text = "状态: 等待..."
status.TextColor3 = Color3.fromRGB(150, 200, 150)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextWrapped = true
status.Parent = frame

-- ---------- 主循环 ----------
local rounds = 0
task.spawn(function()
    while INST.alive do
        pcall(function()
            local didSomething = false
            if state.money then
                MoneyEvent:FireServer(state.moneyAmount)
                didSomething = true
            end
            if state.exp then
                ExpEvent:FireServer(state.expAmount)
                didSomething = true
            end
            if didSomething then
                rounds = rounds + 1
                local coins = lp:GetAttribute("Coins")
                local exp = lp:GetAttribute("Exp")
                local lvl = lp.leaderstats and lp.leaderstats:FindFirstChild("Level")
                setStatus(string.format(
                    "已发放 %d 轮 | Coins=%s | Exp=%s | Lv=%s",
                    rounds, tostring(coins), tostring(exp), lvl and tostring(lvl.Value) or "?"))
            else
                setStatus("全部关闭")
            end
        end)
        task.wait(state.interval)
    end
end)

print("[CDM v1.0] 货币漏洞刷取已加载 | 单例守护")

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
