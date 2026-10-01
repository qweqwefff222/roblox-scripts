--[[
    绑架和监禁 · 杀戮光环 v1.1
    ============ 功能 ============
    [杀戮光环] 开: 8格内出现敌队玩家 → 自动转身面对 + 按0.8秒服务器冷却连续横扫
    (武器参数直接读游戏自己的 Shared.Config: BatRange=8 BatCooldown=0.8 BatWidth=6)
    敌人靠近就倒地, 换人追打全自动
    单例守护
]]

local Players = game:GetService("Players")

local lp = Players.LocalPlayer
local Action = game.ReplicatedStorage:WaitForChild("KidnapAndJail"):WaitForChild("Action")
local Config = require(game.ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

-- ================= 单例守护 =================
if getgenv()._KD_INST and typeof(getgenv()._KD_INST.kill) == "function" then
    pcall(function() getgenv()._KD_INST.kill() end)
end
local INST = { alive = true, conns = {} }
getgenv()._KD_INST = INST
local function bind(c) table.insert(INST.conns, c) end

-- ================= 配置 =================
local state = {
    aura = false,      -- 杀戮光环(默认关)
}
-- ========================================

-- ---------- 面板 ----------
if lp.PlayerGui:FindFirstChild("_kd_panel") then
    lp.PlayerGui._kd_panel:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "_kd_panel"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 200, 0, 100)
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
title.Text = "绑架和监禁 杀戮光环"
title.TextColor3 = Color3.fromRGB(235, 235, 245)
title.Font = Enum.Font.GothamBold
title.TextSize = 12
title.Parent = frame

local status
local function setStatus(t)
    if status then status.Text = t end
end

local btn = Instance.new("TextButton")
btn.Size = UDim2.new(1, -16, 0, 28)
btn.Position = UDim2.new(0, 8, 0, 30)
btn.Font = Enum.Font.Gotham
btn.TextSize = 12
btn.BorderSizePixel = 0
btn.Parent = frame
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
local function refresh()
    btn.Text = "杀戮光环: " .. (state.aura and "开" or "关")
    btn.BackgroundColor3 = state.aura and Color3.fromRGB(60, 130, 90) or Color3.fromRGB(55, 58, 70)
    btn.TextColor3 = Color3.fromRGB(240, 240, 245)
end
btn.MouseButton1Click:Connect(function()
    state.aura = not state.aura
    refresh()
end)
refresh()

status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 42)
status.Position = UDim2.new(0, 8, 0, 62)
status.BackgroundTransparency = 1
status.Text = "状态: 等待..."
status.TextColor3 = Color3.fromRGB(150, 200, 150)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextWrapped = true
status.Parent = frame

-- ---------- 工具 ----------
local function nearestEnemy()
    local char = lp.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil end
    local best, bestDist = nil, math.huge
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= lp and pl.Team ~= lp.Team then
            local c = pl.Character
            local h = c and c:FindFirstChildOfClass("Humanoid")
            local ehrp = c and c:FindFirstChild("HumanoidRootPart")
            if h and h.Health > 0 and ehrp then
                local d = (ehrp.Position - hrp.Position).Magnitude
                if d < bestDist then
                    best, bestDist = pl, d
                end
            end
        end
    end
    return best, bestDist
end

-- ---------- 杀戮光环主循环 ----------
task.spawn(function()
    local lastSwing = 0
    local swings = 0
    while INST.alive do
        local ok, err = pcall(function()
            if not state.aura then
                setStatus("杀戮光环: 关")
                return
            end
            local char = lp.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if not hrp then
                setStatus("无角色(重生中)")
                return
            end
            local enemy, dist = nearestEnemy()
            if not enemy or dist > (Config.BatRange + 1) then
                setStatus(string.format("光环待机(范围%d) | 已挥%d次", Config.BatRange, swings))
                return
            end
            -- 转身面对最近敌人(客户端权威旋转)
            local ehrp = enemy.Character:FindFirstChild("HumanoidRootPart")
            if ehrp then
                local pos = ehrp.Position
                hrp.CFrame = CFrame.new(hrp.Position, Vector3.new(pos.X, hrp.Position.Y, pos.Z))
            end
            -- 极限连发: 不走客户端冷却, 0.12s/次; 服务器限速时自动降速
            local now = os.clock()
            local gap = INST.throttle or 0.12
            if now - lastSwing >= gap then
                lastSwing = now
                Action:FireServer("Primary")
                swings = swings + 1
            end
            setStatus(string.format("⚔ 攻击 %s (距%.0f) | x%d 速率1/%.2fs", enemy.Name, dist, swings, gap))
        end)
        if not ok then
            setStatus("异常: " .. tostring(err):sub(1, 40))
        end
        task.wait(0.1)
    end
end)

-- 服务器限速警告监听: 收到冷却/稍等类通知 → 节流翻倍(上限1.5s)
bind(game.ReplicatedStorage.KidnapAndJail.Notice.OnClientEvent:Connect(function(msg)
    if type(msg) == "string" and (msg:lower():find("cool") or msg:find("冷却") or msg:find("wait") or msg:find("稍候") or msg:find("稍等")) then
        INST.throttle = math.min((INST.throttle or 0.12) * 2, 1.5)
    end
end))

print("[Kidnap v1.2] 杀戮光环(极限连发+自动降速)已加载 | 单例守护")

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
