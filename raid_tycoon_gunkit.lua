--[[
    2人突袭大亨 · 枪械KIT v1.1
    ============ 功能 ============
    [枪械MOD] (默认开)
      - 射速提升: ShotCooldown / 3
      - 强制全自动: FireMode = "Automatic"
      - 零散布: MinSpread/MaxSpread = 0
      - 秒换弹: ReloadTime = 0.1 (无此字段则新增)
      - 无伤害衰减: FullDamageDistance/ZeroDamageDistance = 99999
      - 无限弹药: 本地 CurrentAmmo 顶满 + 统计射弹数,
                  达到弹匣60%时主动发 WeaponReloadRequest 保持服务器弹药
    [枪械杀戮光环] (默认关, 面板开关)
      - 自动锁定最近目标(其他玩家 + NPC人形), 相机瞄准头部
      - 自动从背包取枪装备, 敌人靠近自动开火(消耗弹药, 走真实射击管线)
      - 距离限制默认250, 有视线检测, 面板显示实时状态
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local Network = ReplicatedStorage:WaitForChild("WeaponsSystem"):WaitForChild("Network")
local ReloadRequest = Network:WaitForChild("WeaponReloadRequest")

-- ================= 配置 =================
local COOLDOWN_DIV = 3        -- 射速倍率(除以ShotCooldown)
local KILLAURA_RANGE = 250    -- 杀戮光环索敌距离
local REFILL_AT = 0.6         -- 已射弹匣比例达到此值时请求服务器补弹
local REFILL_COOLDOWN = 1.5   -- 每把枪补弹请求间隔
-- ========================================

local state = {
    mod = true,
    aura = false,
}

local orig = {}        -- [tool] = {cd=, cap=}
local shots = {}       -- [tool] = 自上次补弹以来的射弹数
local lastRefill = {}  -- [tool] = os.clock()
local currentTarget = nil

local function isWeapon(tool)
    return typeof(tool) == "Instance"
        and tool:IsA("Tool")
        and tool:FindFirstChild("HitDamage") ~= nil
end

local function getOrAdd(tool, cls, name, value)
    local v = tool:FindFirstChild(name)
    if not v then
        v = Instance.new(cls)
        v.Name = name
        v.Value = value
        v.Parent = tool
    end
    return v
end

local function applyMod(tool)
    if not isWeapon(tool) then return end
    if not orig[tool] then
        local cd = tool:FindFirstChild("ShotCooldown")
        local capV = tool:FindFirstChild("AmmoCapacity")
        orig[tool] = {
            cd = (cd and tonumber(cd.Value) or 0.2),
            cap = (capV and tonumber(capV.Value) or 30),
        }
        -- 射弹计数: 监视 CurrentAmmo 本地下降
        local ammo = tool:FindFirstChild("CurrentAmmo")
        if ammo then
            shots[tool] = 0
            local last = ammo.Value
            ammo:GetPropertyChangedSignal("Value"):Connect(function()
                local a = ammo.Value
                if a < last then
                    shots[tool] = (shots[tool] or 0) + (last - a)
                end
                last = a
            end)
        end
    end
    -- 射速
    local cd = tool:FindFirstChild("ShotCooldown")
    if cd and orig[tool].cd then
        cd.Value = orig[tool].cd / COOLDOWN_DIV
    end
    -- 全自动
    getOrAdd(tool, "StringValue", "FireMode", "Automatic").Value = "Automatic"
    -- 零散布
    local ms = tool:FindFirstChild("MinSpread")
    local xs = tool:FindFirstChild("MaxSpread")
    if ms then ms.Value = 0 end
    if xs then xs.Value = 0 end
    -- 秒换弹
    getOrAdd(tool, "NumberValue", "ReloadTime", 0.1).Value = 0.1
    -- 无伤害衰减
    local fd = tool:FindFirstChild("FullDamageDistance")
    local zd = tool:FindFirstChild("ZeroDamageDistance")
    if fd then fd.Value = 99999 end
    if zd then zd.Value = 99999 end
end

-- ---------- 弹药: 本地顶满 + 服务器补弹 ----------
local function ammoStep()
    local ch = lp.Character
    if not ch then return end
    local now = os.clock()
    for _, t in ipairs(ch:GetChildren()) do
        if isWeapon(t) then
            local ammo = t:FindFirstChild("CurrentAmmo")
            local cap = t:FindFirstChild("AmmoCapacity")
            if ammo and cap and tonumber(cap.Value) then
                local c = cap.Value
                if ammo.Value < c then
                    ammo.Value = c -- 客户端无限弹药
                end
                local cap0 = orig[t].cap or c
                if (shots[t] or 0) >= math.max(1, math.floor(cap0 * REFILL_AT))
                    and now - (lastRefill[t] or 0) >= REFILL_COOLDOWN then
                    lastRefill[t] = now
                    shots[t] = 0
                    ReloadRequest:FireServer(t) -- 保持服务器弹匣
                end
            end
        end
    end
end

task.spawn(function()
    while true do
        pcall(ammoStep)
        task.wait(0.15)
    end
end)

-- ---------- 目标缓存: 事件驱动(零扫描开销) ----------
local humanoidCache = {} -- [humanoid] = model

local function tryCache(d)
    if d:IsA("Humanoid") and d.Parent then
        local m = d.Parent
        if m ~= lp.Character and not Players:GetPlayerFromCharacter(m) then
            humanoidCache[d] = m
        end
    end
end

-- 初始快照: Soldiers 文件夹(守卫NPC)
task.spawn(function()
    local sold = game.Workspace:FindFirstChild("Soldiers")
    if sold then
        for _, d in ipairs(sold:GetDescendants()) do
            pcall(tryCache, d)
        end
        sold.ChildAdded:Connect(function(c)
            task.defer(function()
                for _, d in ipairs(c:GetDescendants()) do
                    pcall(tryCache, d)
                end
            end)
        end)
    end
end)

-- 动态生成: 任何新 Humanoid 落地即入缓存
game.Workspace.DescendantAdded:Connect(function(d)
    task.defer(pcall, tryCache, d)
end)

-- 周期清理失效缓存
task.spawn(function()
    while true do
        pcall(function()
            for h, m in pairs(humanoidCache) do
                if not h.Parent or not m.Parent or h.Health <= 0 then
                    humanoidCache[h] = nil
                end
            end
        end)
        task.wait(5)
    end
end)

local function collectHumanoids()
    local found = {}
    -- 其他玩家
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp and p.Character then
            local h = p.Character:FindFirstChildOfClass("Humanoid")
            if h and h.Health > 0 then found[h] = p.Character end
        end
    end
    -- 缓存的NPC
    for h, m in pairs(humanoidCache) do
        if h.Parent and h.Health > 0 and m.Parent then
            if not Players:GetPlayerFromCharacter(m) then found[h] = m end
        else
            humanoidCache[h] = nil
        end
    end
    return found
end

-- ---------- 相机自瞄(RenderStep, 优先级在相机之后) ----------
local AIM_NAME = "RTK_GUN_AURA_AIM"
RunService:UnbindFromRenderStep(AIM_NAME)

local function aimPosOf(model)
    local head = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
    if head and head:IsA("BasePart") then
        return head.Position
    end
    local part = model:FindFirstChildWhichIsA("BasePart")
    return part and part.Position or nil
end

local function pickTarget()
    local myhrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    if not myhrp then return nil end
    local best, bestDist = nil, KILLAURA_RANGE
    local camPos = workspace.CurrentCamera.CFrame.Position
    for h, m in pairs(collectHumanoids()) do
        local pos = aimPosOf(m)
        if pos then
            local d = (pos - myhrp.Position).Magnitude
            if d < bestDist then
                -- 视线检测(忽略双方角色)
                local params = RaycastParams.new()
                params.FilterType = Enum.RaycastFilterType.Exclude
                local excl = {lp.Character, m, workspace.CurrentCamera}
                params.FilterDescendantsInstances = excl
                local dir = pos - camPos
                local hit = workspace:Raycast(camPos, dir, params)
                local dist = dir.Magnitude
                if not hit or (hit.Position - camPos).Magnitude >= dist - 2 then
                    best, bestDist = m, d
                end
            end
        end
    end
    return best
end

RunService:BindToRenderStep(AIM_NAME, Enum.RenderPriority.Camera.Value + 1, function()
    if not state.aura then
        if currentTarget then
            currentTarget = nil
            local tool = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
            if tool and tool:IsA("Tool") then pcall(function() tool:Deactivate() end) end
        end
        return
    end
    local target = pickTarget()
    currentTarget = target
    local cam = workspace.CurrentCamera
    if target then
        local pos = aimPosOf(target)
        if pos then
            cam.CFrame = CFrame.lookAt(cam.CFrame.Position, pos)
        end
        local tool = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
        if tool and isWeapon(tool) then
            pcall(function() tool:Activate() end)
        end
    else
        local tool = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
        if tool and isWeapon(tool) then
            pcall(function() tool:Deactivate() end)
        end
    end
end)

-- ---------- 武器挂接 ----------
local function sweep()
    for _, t in ipairs(lp.Backpack:GetChildren()) do
        if state.mod then applyMod(t) end
    end
    local ch = lp.Character
    if ch then
        for _, t in ipairs(ch:GetChildren()) do
            if state.mod then applyMod(t) end
        end
    end
end

lp.Backpack.ChildAdded:Connect(function(c) task.defer(function()
    if state.mod then applyMod(c) end
end, c) end)

local function hookCharacter(ch)
    ch.ChildAdded:Connect(function(c) task.defer(function()
        if state.mod then applyMod(c) end
    end, c) end)
    for _, t in ipairs(ch:GetChildren()) do
        if state.mod then applyMod(t) end
    end
end
if lp.Character then hookCharacter(lp.Character) end
lp.CharacterAdded:Connect(hookCharacter)

task.spawn(function()
    while true do
        if state.mod then sweep() end
        task.wait(2)
    end
end)
sweep()

-- ---------- 迷你面板 ----------
local gui = Instance.new("ScreenGui")
gui.Name = "_rtk_gunkit"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 190, 0, 132)
frame.Position = UDim2.new(0, 20, 0, 160)
frame.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 26)
title.BackgroundTransparency = 1
title.Text = "突袭大亨 枪械KIT"
title.TextColor3 = Color3.fromRGB(235, 235, 245)
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Parent = frame

local function makeToggle(name, y, get, set)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -16, 0, 30)
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

makeToggle("枪械MOD", 32, function() return state.mod end, function(v)
    state.mod = v
    if not v then
        -- 还原射速
        for t, o in pairs(orig) do
            if t.Parent then
                local cd = t:FindFirstChild("ShotCooldown")
                if cd and o.cd then cd.Value = o.cd end
            end
        end
    else
        sweep()
    end
end)

makeToggle("杀戮光环", 70, function() return state.aura end, function(v)
    state.aura = v
end)

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 18)
status.Position = UDim2.new(0, 8, 0, 106)
status.BackgroundTransparency = 1
status.Text = "状态: 待机"
status.TextColor3 = Color3.fromRGB(150, 200, 150)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = frame

-- 状态显示 + 杀戮光环自动取枪
task.spawn(function()
    while true do
        pcall(function()
            if state.aura then
                local tool = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
                if isWeapon(tool) then
                    if currentTarget then
                        status.Text = "状态: 开火中 > " .. tostring(currentTarget.Name)
                        status.TextColor3 = Color3.fromRGB(255, 120, 120)
                    else
                        status.Text = "状态: 索敌中(范围" .. KILLAURA_RANGE .. ")"
                        status.TextColor3 = Color3.fromRGB(150, 200, 150)
                    end
                else
                    -- 自动从背包拿枪
                    local best
                    for _, t in ipairs(lp.Backpack:GetChildren()) do
                        if isWeapon(t) then best = t break end
                    end
                    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
                    if best and hum then
                        pcall(function() hum:EquipTool(best) end)
                        status.Text = "状态: 自动装备 " .. best.Name
                    else
                        status.Text = "状态: 背包无枪械!"
                    end
                    status.TextColor3 = Color3.fromRGB(230, 200, 120)
                end
            else
                status.Text = "状态: 待机"
                status.TextColor3 = Color3.fromRGB(150, 150, 160)
            end
        end)
        task.wait(0.3)
    end
end)

print("[RaidTycoon GunKit v1.1] 已加载: 枪械MOD(开) + 杀戮光环(自动取枪+状态显示)")
