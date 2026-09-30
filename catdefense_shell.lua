--[[
    猫的防御 · 自动拾取装填 v2.1
    ============ 功能 ============
    [自动拾取炮弹] 开: fireclickdetector 点最近炮弹堆(原地, 无视距离)
    [自动填充炮+储存区] 开: 轮询全图所有 "LOAD SHELL" 交互点
        (每门炮的 InsertShellPrompt + InsertPart 储存口, 含 ReplicateWork 自己的炮位)
        → 逐个传送过去触发插入; 被服务器拒绝的(不是你的炮)自动跳过下一个
        → 炮弹用掉就自动再拾取, 循环
    单例守护 + 落盘日志
    注: 检测炮位已按需求移除, 现在无脑填所有炮(服务器自动校验归属)
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local RS = game.ReplicatedStorage
local DroppedShell = RS:WaitForChild("Events"):WaitForChild("DroppedShell")

-- ================= 单例守护 =================
if getgenv()._CD_INST and typeof(getgenv()._CD_INST.kill) == "function" then
    pcall(function() getgenv()._CD_INST.kill() end)
end
local INST = { alive = true, conns = {} }
getgenv()._CD_INST = INST
local function bind(c) table.insert(INST.conns, c) end

-- ================= 配置 =================
local state = {
    pickup = true,    -- 自动拾取
    fill = true,      -- 自动填充所有炮+储存区
    fillGap = 0.8,    -- 每个交互点停留时长
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
    getgenv()._CD_LOG = logBuf
    pcall(function()
        if writefile then
            local old = ""
            if isfile and isfile("catdefense_log.txt") then
                old = readfile("catdefense_log.txt")
                if #old > 120000 then old = "" end
            end
            writefile("catdefense_log.txt", old .. line .. "\n")
        end
    end)
end

-- ---------- 面板 ----------
if lp.PlayerGui:FindFirstChild("_cd_panel") then
    lp.PlayerGui._cd_panel:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "_cd_panel"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 210, 0, 132)
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
title.Text = "猫的防御 自动拾取装填 v2.1"
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

makeToggle("自动拾取炮弹", 28, function() return state.pickup end, function(v)
    state.pickup = v
end)

makeToggle("自动填充所有炮", 58, function() return state.fill end, function(v)
    state.fill = v
end)

status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 42)
status.Position = UDim2.new(0, 8, 0, 88)
status.BackgroundTransparency = 1
status.Text = "状态: 等待..."
status.TextColor3 = Color3.fromRGB(150, 200, 150)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextWrapped = true
status.Parent = frame

-- ---------- 工具函数 ----------
local function getHasShell()
    local ch = lp.Character
    return ch and ch:GetAttribute("HasShell") == true
end

local function pickupShell()
    local myPos = lp.Character and lp.Character.HumanoidRootPart and lp.Character.HumanoidRootPart.Position
    local best, bestDist
    for _, d in ipairs(game.Workspace:GetChildren()) do
        if d:IsA("Model") and d.Name == "ShellPile" then
            local cd = d:FindFirstChildWhichIsA("ClickDetector", true)
            if cd then
                if not myPos then return cd end
                local p = d:FindFirstChildWhichIsA("BasePart", true)
                local dist = p and (p.Position - myPos).Magnitude or math.huge
                if not bestDist or dist < bestDist then
                    best, bestDist = cd, dist
                end
            end
        end
    end
    if best then
        return pcall(fireclickdetector, best)
    end
    return false
end

-- 收集全图 LOAD SHELL 交互点(炮+储存口)
local function collectLoadPrompts()
    local list = {}
    local containers = {}
    local rw = game.Workspace:FindFirstChild("ReplicateWork")
    if rw then table.insert(containers, rw) end
    local cf = game.Workspace:FindFirstChild("Cannons")
    if cf then table.insert(containers, cf) end
    local cn = game.Workspace:FindFirstChild("Cannon")
    if cn then table.insert(containers, cn) end
    for _, container in ipairs(containers) do
        for _, d in ipairs(container:GetDescendants()) do
            if d:IsA("ProximityPrompt") and d.ActionText == "LOAD SHELL" and d.Enabled then
                table.insert(list, d)
            end
        end
    end
    return list
end

local function tpNear(prompt, char)
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    local pos = prompt.Parent and prompt.Parent.Position or prompt.Position
    local off = hrp.Position - pos
    off = Vector3.new(off.X, 0, off.Z)
    if off.Magnitude < 0.1 then off = Vector3.new(5, 0, 0) end
    off = off.Unit * 4
    -- 向下找地面
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = {char}
    local hit = workspace:Raycast(pos + off + Vector3.new(0, 12, 0), Vector3.new(0, -60, 0), params)
    local target = hit and (hit.Position + Vector3.new(0, 3.5, 0)) or (pos + off + Vector3.new(0, 3, 0))
    char:PivotTo(CFrame.new(target))
    hrp.AssemblyLinearVelocity = Vector3.zero
    return true
end

-- ---------- 主循环 ----------
local picked = 0
local filled = 0
local preferred = {}
local rejected = {}

task.spawn(function()
    local promptIdx = 1
    while INST.alive do
        local ok, err = pcall(function()
            local now = os.clock()
            if now - (INST.lastAct or 0) < state.fillGap then return end

            local char = lp.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if not char or not hrp then
                setStatus("无角色(重生中)")
                return
            end
            local hasShell = getHasShell()

            -- 填充模式: 轮询所有 LOAD SHELL 交互点(成功的优先, 被拒的进60s冷却)
            if state.fill then
                local prompts = collectLoadPrompts()
                if #prompts == 0 then
                    setStatus("没找到任何 LOAD SHELL 交互点")
                    return
                end
                local n = #prompts
                local chosen
                for i = 1, n do
                    local idx = (promptIdx - 1 + i) % n + 1
                    local p = prompts[idx]
                    if p.Enabled then
                        local rejectUntil = rejected[p]
                        if preferred[p] or not rejectUntil or now >= rejectUntil then
                            chosen = idx
                            break
                        end
                    end
                end
                if not chosen then
                    rejected = {}
                    promptIdx = 1
                    return
                end
                promptIdx = chosen
                local prompt = prompts[promptIdx]
                tpNear(prompt, char)
                task.wait(0.35)
                local had = getHasShell()
                pcall(function() fireproximityprompt(prompt) end)
                task.wait(0.4)
                local after = getHasShell()
                if had and not after then
                    filled = filled + 1
                    preferred[prompt] = true
                    rejected[prompt] = nil
                    setStatus(string.format("填充 [%d/%d] ✓ (已填%d) | 拾取%d", promptIdx, n, filled, picked))
                    log(string.format("填充成功: %s", prompt.Parent and prompt.Parent:GetFullName() or "?"))
                elseif had and after then
                    rejected[prompt] = now + 60
                    setStatus(string.format("填充 [%d/%d] 被拒(冷却60s) | 已填%d", promptIdx, n, filled))
                end
                promptIdx = promptIdx + 1
                INST.lastAct = os.clock()
                return
            end

            -- 仅拾取模式
            if state.pickup and not hasShell then
                if pickupShell() then
                    picked = picked + 1
                    if getHasShell() then
                        setStatus(string.format("拾取成功 x%d (原地)", picked))
                        log("拾取成功")
                    end
                else
                    setStatus("拾取失败(炮堆空了?)")
                end
                INST.lastAct = os.clock()
                return
            end

            if hasShell and not state.fill then
                setStatus("扛着炮弹(填充已关) | 拾取" .. picked)
                return
            end
            setStatus("待命 | 拾取" .. picked)
        end)
        if not ok then
            log("主循环异常: " .. tostring(err))
        end
        task.wait(0.2)
    end
end)

log("[CatDefense v2.1] 加载")
print("[CatDefense v2.1] 自动拾取+填充所有炮 已加载 | 单例守护")

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
