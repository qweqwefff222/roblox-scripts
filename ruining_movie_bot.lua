--[[
    Ruining a Movie · 自动捣乱 v1.0
    ============ 功能 ============
    [自动捣乱] (默认开)
      - 读服务器当前背包段(Phone/Loud Food/Drink), 自动发对应动作刷捣乱度
      - 手机: 0.4s连点(尊重 PhoneTapMinInterval + PhoneReadyAt)
      - 大声食物: 0.4s一咬(尊重 FoodCompleting)
      - 饮料: Begin→1.2s→End 循环
    [智能焦虑管控] (默认开)
      - 焦虑(CinemaAnxiety 0-1)超过暂停阈值 或 引座员正在查你(CinemaAnxietyDanger)
        → 立刻停止动作 + 强制看向电影屏幕(服务器看相机朝向降焦虑)
      - 焦虑降到恢复阈值以下且危险解除 → 继续捣乱
    [面板] 同款样式: 开关 + 阈值滑条 + 实时状态
    安全策略: 只在 Phase==MOVIE、未被抓、存活时动作
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local BackpackAction = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CinemaGearRemotes"):WaitForChild("BackpackAction")
local Phase = ReplicatedStorage:WaitForChild("CinemaRoundState"):WaitForChild("Phase")
local GameConfig = ReplicatedStorage:WaitForChild("Config"):WaitForChild("CinemaGameConfig")
local Screen = workspace:WaitForChild("CinemaFoundation"):WaitForChild("Architecture"):WaitForChild("ScreenStage"):WaitForChild("Screen")

-- ================= 单例守护 =================
if getgenv()._RMB_INST and typeof(getgenv()._RMB_INST.kill) == "function" then
    pcall(function() getgenv()._RMB_INST.kill() end)
end
local INST = { alive = true, conns = {} }
getgenv()._RMB_INST = INST
local function bind(c) table.insert(INST.conns, c) end

-- ================= 配置 =================
local state = {
    enabled = true,     -- 自动捣乱
    smart = true,       -- 智能焦虑管控
    lookScreen = true,  -- 冷却期自动看屏幕
    pauseTh = 0.65,     -- 焦虑暂停阈值
    resumeTh = 0.30,    -- 焦虑恢复阈值
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
    getgenv()._RMB_LOG = logBuf
    pcall(function()
        if writefile then
            local old = ""
            if isfile and isfile("ruining_movie_log.txt") then
                old = readfile("ruining_movie_log.txt")
                if #old > 120000 then old = "" end
            end
            writefile("ruining_movie_log.txt", old .. line .. "\n")
        end
    end)
end

-- ---------- 面板 ----------
if lp.PlayerGui:FindFirstChild("_rmb_panel") then
    lp.PlayerGui._rmb_panel:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "_rmb_panel"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 200, 0, 232)
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
title.Text = "Ruining a Movie 自动捣乱"
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
        local v = math.floor((minV + rel * (maxV - minV)) * 100 + 0.5) / 100
        fill.Size = UDim2.new(rel, 0, 1, 0)
        lbl.Text = string.format(labelFmt, v * 100)
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
    lbl.Text = string.format(labelFmt, init * 100)
end

makeToggle("自动捣乱", 28, function() return state.enabled end, function(v)
    state.enabled = v
end)

makeToggle("智能焦虑管控", 58, function() return state.smart end, function(v)
    state.smart = v
end)

makeToggle("冷却期看屏幕", 88, function() return state.lookScreen end, function(v)
    state.lookScreen = v
end)

makeSlider(120, "焦虑暂停阈值: %.0f%%", 0.4, 0.9, state.pauseTh, function(v)
    state.pauseTh = v
end)

makeSlider(152, "焦虑恢复阈值: %.0f%%", 0.1, 0.5, state.resumeTh, function(v)
    state.resumeTh = v
end)

status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 44)
status.Position = UDim2.new(0, 8, 0, 184)
status.BackgroundTransparency = 1
status.Text = "状态: 等待开场..."
status.TextColor3 = Color3.fromRGB(150, 200, 150)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextWrapped = true
status.Parent = frame

-- ---------- 主逻辑 ----------
local function getPhoneTapInterval()
    local n = GameConfig:FindFirstChild("PhoneTapMinInterval")
    if n and n:IsA("NumberValue") and tonumber(n.Value) then
        return math.max(0.2, tonumber(n.Value))
    end
    return 0.34
end

local function equippedBackpack()
    local ch = lp.Character
    if not ch then return false end
    for _, t in ipairs(ch:GetChildren()) do
        if t:IsA("Tool") and t:GetAttribute("CinemaBackpackTool") == true then
            return true
        end
    end
    return false
end

local function canAct()
    if not INST.alive or not state.enabled then return false end
    if lp:GetAttribute("InCinemaGameplay") ~= true then return false end
    if Phase.Value:upper() ~= "MOVIE" then return false end
    if lp:GetAttribute("CinemaCaught") == true then return false end
    if lp:GetAttribute("CinemaMenuOpen") == true then return false end
    if lp:GetAttribute("CinemaAnxietyDanger") == true then return false end
    if not equippedBackpack() then return false end
    return true
end

local function segmentAllowed(seg)
    if lp:GetAttribute("CinemaBackpackState") ~= "Misbehaving" then return false end
    return lp:GetAttribute("CinemaMisbehaviorSegment") == seg
end

-- 冷却期强制看屏幕
local LOOK_NAME = "_RMB_LOOK_SCREEN"
RunService:UnbindFromRenderStep(LOOK_NAME)
local looking = false
local function setLooking(on)
    if on == looking then return end
    looking = on
    if on then
        RunService:BindToRenderStep(LOOK_NAME, Enum.RenderPriority.Camera.Value + 2, function()
            if not INST.alive or not state.lookScreen then return end
            local cam = workspace.CurrentCamera
            if cam and Screen and Screen.Parent then
                cam.CFrame = CFrame.lookAt(cam.CFrame.Position, Screen.Position)
            end
        end)
    else
        RunService:UnbindFromRenderStep(LOOK_NAME)
    end
end

-- 饮料状态机
local drinking = false
local drinkEndAt = 0
local drinkCd = 0

-- 主循环
task.spawn(function()
    local lastPhone = 0
    local lastFood = 0
    local paused = false
    while INST.alive do
        local ok, err = pcall(function()
            local phase = Phase.Value:upper()
            local anx = tonumber(lp:GetAttribute("CinemaAnxiety")) or 0
            local danger = lp:GetAttribute("CinemaAnxietyDanger") == true
            local seg = tostring(lp:GetAttribute("CinemaMisbehaviorSegment") or "Phone")

            if phase ~= "MOVIE" then
                paused = false
                setLooking(false)
                setStatus("阶段: " .. phase .. " (非放映中)")
                return
            end
            if lp:GetAttribute("CinemaCaught") == true then
                paused = false
                setLooking(false)
                setStatus("已被抓!")
                return
            end
            if not state.enabled then
                setStatus("自动捣乱已关闭")
                return
            end

            -- 智能焦虑管控
            if state.smart then
                if danger or anx >= state.pauseTh then
                    paused = true
                elseif anx <= state.resumeTh and not danger then
                    paused = false
                end
            else
                paused = false
            end

            if paused then
                setLooking(state.lookScreen)
                setStatus(string.format("暂停捣乱 | 焦虑%.0f%%%s | 看屏幕降焦虑中", anx * 100, danger and " | 引座员查你!" or ""))
                return
            end
            setLooking(false)

            if not canAct() then
                setStatus("未进入游戏/未装备背包")
                return
            end

            -- 按当前段执行动作
            local now = os.clock()
            if seg == "Phone" and segmentAllowed("Phone") then
                local ch = lp.Character
                local readyAt = ch and ch:GetAttribute("CinemaPhoneReadyAt")
                local phoneReady = (typeof(readyAt) ~= "number") or (readyAt <= workspace:GetServerTimeNow())
                if phoneReady and now - lastPhone >= getPhoneTapInterval() then
                    lastPhone = now
                    BackpackAction:FireServer("PhoneTap")
                    setStatus(string.format("捣乱中: 手机连点 | 焦虑%.0f%%", anx * 100))
                end
            elseif seg == "Loud Food" and segmentAllowed("Loud Food") then
                if lp:GetAttribute("CinemaFoodCompleting") ~= true and now - lastFood >= 0.4 then
                    lastFood = now
                    BackpackAction:FireServer("FoodBite", workspace:GetServerTimeNow())
                    setStatus(string.format("捣乱中: 吃爆米花 | 焦虑%.0f%%", anx * 100))
                end
            elseif seg == "Drink" and segmentAllowed("Drink") then
                if not drinking and now >= drinkCd then
                    drinking = true
                    drinkEndAt = now + 1.2
                    BackpackAction:FireServer("DrinkBegin")
                    setStatus(string.format("捣乱中: 喝饮料 | 焦虑%.0f%%", anx * 100))
                elseif drinking and now >= drinkEndAt then
                    drinking = false
                    drinkCd = now + 0.8
                    BackpackAction:FireServer("DrinkEnd")
                end
            else
                setStatus("当前段: " .. seg .. " (暂不支持自动)")
            end
        end)
        if not ok then
            log("主循环异常: " .. tostring(err))
        end
        task.wait(0.15)
    end
end)

log("[Ruining a Movie Auto v1.0] 加载")
print("[RMB v1.0] 自动捣乱已加载 | 单例守护")

-- ---------- kill ----------
INST.kill = function()
    INST.alive = false
    RunService:UnbindFromRenderStep(LOOK_NAME)
    for _, c in ipairs(INST.conns) do
        pcall(function() c:Disconnect() end)
    end
    if gui then
        pcall(function() gui:Destroy() end)
    end
end
