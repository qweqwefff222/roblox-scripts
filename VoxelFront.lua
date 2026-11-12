--[[
    ══════════════════════════════════════════════════════════
    Voxel Front (体素战争) — 静默瞄准 + ESP
    ══════════════════════════════════════════════════════════
    游戏逆向要点:
      · 开火协议: Voxel.Remotes.FireRifle/FirePistol/FireSniper/... 
                  FireServer(origin: Vector3, direction: Vector3, serverTime: number)
        服务端收到「起点+方向」自己算射线 → 改 direction 即可静默
      · 敌人判定 (HitPredict.enemyOf):
          - BotRigs 下的 bot: Alive~=false 且 Protected~=true 且 Team~=我方
          - 真人玩家: 非自己 且 Protected~=true 且 Team~=我方
      · 队伍动态: 读 LocalPlayer.Team, 不硬编码
--]]

-- ============================================================
-- WindUI
-- ============================================================
local WindUI = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
if not WindUI then
    warn("[VF] WindUI 加载失败")
    return
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local RS = game:GetService("ReplicatedStorage")
local LP = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- ============================================================
-- 状态
-- ============================================================
local State = {
    -- 静默瞄准
    SilentEnabled = false,
    SilentFOV = 127,
    SilentHeadOnly = true,
    SilentWallCheck = false,   -- 默认关: 此游戏地形多, 开会过滤掉几乎所有目标
    Priority = "crosshair",   -- crosshair | near | far | hpLow | hpHigh
    ShowFOV = false,
    ShowIndicator = false,

    -- ESP
    ESPEnabled = false,
    ESPBox = true,
    ESPName = true,
    ESPDistance = true,
    ESPHealth = true,
    ESPTeamCheck = true,
    ESPMaxDist = 500,

    -- 载具武器
    VehicleAim = true,

    -- 下坠补偿 (默认关, 和步枪一致走直线)
    DropComp = false,

    -- 一直装弹
    AlwaysReload = false,

    -- 扩展碰撞箱


}

local VF = State
getgenv().VF = State

-- ============================================================
-- 敌人识别 (动态队伍, 不硬编码)
-- ============================================================
local function myTeamName()
    local t = LP.Team
    if t and not LP.Neutral then return t.Name end
    return nil
end

local function isEnemy(part)
    if not part then return false end
    local model = part.Parent
    if not model then return false end
    if model:IsA("Accessory") then model = model.Parent end
    if not model or not model:IsA("Model") then return false end

    local myTeam = myTeamName()

    -- Bot
    local br = Workspace:FindFirstChild("BotRigs")
    if br and model.Parent == br then
        if model:GetAttribute("Alive") == false then return false end
        if model:GetAttribute("Protected") == true then return false end
        if myTeam and model:GetAttribute("Team") == myTeam then return false end
        return true
    end

    -- 真人
    local p = Players:GetPlayerFromCharacter(model)
    if p and p ~= LP then
        if model:GetAttribute("Protected") == true then return false end
        local hum = model:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then return false end
        if myTeam and p.Team and p.Team.Name == myTeam then return false end
        return true
    end

    return false
end

-- 收集所有敌人
local function getEnemies()
    local list = {}
    local seen = {}

    local br = Workspace:FindFirstChild("BotRigs")
    if br then
        for _, m in ipairs(br:GetChildren()) do
            if m:IsA("Model") then
                local hum = m:FindFirstChildOfClass("Humanoid")
                local head = m:FindFirstChild("Head") or m:FindFirstChild("HumanoidRootPart")
                if hum and hum.Health > 0 and head and isEnemy(head) and not seen[m] then
                    seen[m] = true
                    table.insert(list, { model = m, part = head, hum = hum })
                end
            end
        end
    end

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            local c = p.Character
            if c then
                local hum = c:FindFirstChildOfClass("Humanoid")
                local head = c:FindFirstChild("Head") or c:FindFirstChild("HumanoidRootPart")
                if hum and hum.Health > 0 and head and isEnemy(head) and not seen[c] then
                    seen[c] = true
                    table.insert(list, { model = c, part = head, hum = hum })
                end
            end
        end
    end

    return list
end

VF.GetEnemies = getEnemies

-- ============================================================
-- 预测系统 (自动检测, 玩家无需填任何数值)
--
-- 弹速: 读 Tracers.SPEED (游戏官方值, 当前 1000 studs/s)
--       优先调 Tracers.travelTime() 拿精确飞行时间
-- 敌速: 每帧采样每个敌人的位置, 自动算出移动速度和方向
-- ============================================================
State.PredictEnabled = true
State.PredictMaxTime = 0.6      -- 最多预判 0.6 秒, 防止甩飞

-- ============================================================
-- 弹道物理 (复用游戏自己的 Ballistics 模块)
--   SPEED=1700 / RIFLE=2400 / GRAVITY=24.525 / DRAG=0.0014
--   弹速 >= 2000 → 直线弹道; < 2000 → 有下坠
-- ============================================================
local Ballistics = nil
pcall(function()
    local vx = RS:FindFirstChild("Voxel")
    local B = vx and vx:FindFirstChild("Ballistics")
    if B then
        local ok, mod = pcall(require, B)
        if ok and type(mod) == "table" then
            Ballistics = mod
                    end
    end
end)
State.HasBallistics = nil ~= nil
print("[VF] 弹道模块: " .. tostring(Ballistics ~= nil))



-- ============================================================
-- 武器弹道数据 (全部从游戏源码读出, 22 把武器)
--   Ballistics.RIFLE_SPEED = 2400  ← 基准弹速
--   实际弹速 = 2400 * Gunsmith.velocity(tool)   (无改装时 = 1)
--   是否下坠看 GUNS[id].flies 字段, 不看弹速
--     Rifle/SMG/LMG/Pistol → flies=false → 直线
--     DMR(FS16/GV12/KR54) / Sniper(SC11/RX10) → flies=true → 有下坠
-- ============================================================
local BP = { SPEED = 1700, RIFLE_SPEED = 2400, DMR_SPEED = 1500,
             SNIPER_MIN = 1600, STRAIGHT_MIN = 2000,
             GRAVITY = 24.525, DRAG = 0.0014, ZERO = 250 }
local Ballistics, gsMod = nil, nil

-- 弹道模块 (多重路径尝试)
local function tryLoadBallistics()
    local paths = {
        function() return RS:FindFirstChild("Voxel"):FindFirstChild("Ballistics") end,
        function() return RS:FindFirstChild("Voxel"):FindFirstChild("Ballistics") end,
    }
    local vx = RS:FindFirstChild("Voxel")
    local B = vx and vx:FindFirstChild("Ballistics")
    if not B then return end
    local ok, mod = pcall(require, B)
    if ok and type(mod) == "table" then
        Ballistics = mod
        for k, v in pairs(mod) do
            if type(v) == "number" then BP[k] = v end
        end
    end
end
tryLoadBallistics()

pcall(function()
    local gsFolder = RS:FindFirstChild("Gunsmith")
    local g = gsFolder and gsFolder:FindFirstChild("Gunsmith")
    if g then
        local ok, mod = pcall(require, g)
        if ok and type(mod) == "table" then gsMod = mod end
    end
end)

State.HasBallistics = Ballistics ~= nil
State.HasGunsmith = gsMod ~= nil

-- 汇总所有武器 flies 标记 (从各 Specs 的 GUNS 表)
local FLIES = {}
pcall(function()
    if not gsMod or type(gsMod.GUNS) ~= "table" then return end
    for id, e in pairs(gsMod.GUNS) do
        if type(e) == "table" then
            FLIES[id] = (e.flies == true)
        end
    end
end)
State._Flies = FLIES

local bulletSpeed = BP.RIFLE_SPEED or 2400
State._BP = BP

-- 当前武器真实弹速 + 是否下坠
local function currentWeaponInfo()
    local char = LP.Character
    local tool = char and char:FindFirstChildOfClass("Tool")
    if not tool then return bulletSpeed, false end

    -- 弹速 = 基准 × Gunsmith 改装系数
    local speed = BP.RIFLE_SPEED or 2400
    if gsMod and type(gsMod.velocity) == "function" then
        local ok, v = pcall(gsMod.velocity, tool)
        if ok and type(v) == "number" and v > 0 then
            speed = speed * v
        end
    end

    -- 是否下坠: 先查 GUNS 表, 查不到按道具名兜底
    local flies = FLIES[tool.Name]
    if flies == nil then
        local n = string.lower(tool.Name)
        flies = (string.find(n, "sniper") ~= nil)
             or (string.find(n, "dmr") ~= nil)
    end
    return speed, flies
end

-- 每 0.3 秒更新
task.spawn(function()
    while true do
        task.wait(0.3)
        pcall(function()
            local sp, fl = currentWeaponInfo()
            State.CurrentBulletSpeed = sp
            State.CurrentFlies = fl
        end)
    end
end)

print("[VF] 弹速自动检测: " .. tostring(bulletSpeed))

-- 敌人速度追踪表
local velTrack = {}   -- [model] = { pos, time, vel }

-- 每帧采样敌人位置
task.spawn(function()
    while true do
        task.wait(0.05)
        if State.PredictEnabled then
            local now = os.clock()
            local alive = {}
            for _, e in ipairs(getEnemies()) do
                local m = e.model
                alive[m] = true
                local root = m:FindFirstChild("HumanoidRootPart") or e.part
                if root then
                    local rec = velTrack[m]
                    if rec then
                        local dt = now - rec.time
                        if dt > 0.01 and dt < 0.5 then
                            local v = (root.Position - rec.pos) / dt
                            -- 平滑 + 过滤异常值 (瞬移/被击退)
                            if v.Magnitude < 200 then
                                rec.vel = rec.vel * 0.6 + v * 0.4
                            else
                                rec.vel = Vector3.new(0, 0, 0)
                            end
                        end
                        rec.pos = root.Position
                        rec.time = now
                    else
                        velTrack[m] = {
                            pos = root.Position,
                            time = now,
                            vel = Vector3.new(0, 0, 0),
                        }
                    end
                end
            end
            -- 清理消失的
            for m in pairs(velTrack) do
                if not alive[m] then velTrack[m] = nil end
            end
        end
    end
end)

-- 预测目标位置
local function predictPos(target)
    if not target or not State.PredictEnabled then
        return target and target.part and target.part.Position or nil
    end
    local m = target.model
    local part = target.part
    if not part then return nil end

    -- 载具里用角色位置(相机在载具上会偏移), 步兵用相机
    local origin = Camera.CFrame.Position
    local char = LP.Character
    if char then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp and LP:GetAttribute("InVehicle") then
            origin = hrp.Position
        end
    end

    local dist = (part.Position - origin).Magnitude

    -- 飞行时间
    local flight = dist / (bulletSpeed or 2400)
    flight = math.clamp(flight, 0, State.PredictMaxTime)

    -- 敌人速度
    local rec = velTrack[m]
    local vel = rec and rec.vel or Vector3.new(0, 0, 0)

    -- ★ 低速目标不预判 (避免推过目标), 高速才按比例预判
    local spd = vel.Magnitude
    if spd < 4 then
        return part.Position                    -- 站着不动/微动: 直接打当前位置
    end
    -- 预判量随速度渐入, 上限 0.75 (远距离不推太远)
    local lead = math.clamp(spd / 20, 0, 1) * 0.75
    return part.Position + vel * flight * lead
end

-- ============================================================
-- 载具状态检测 (游戏用 LocalPlayer 的 InVehicle 属性, 不是原生 Seat)
--   InVehicle = "air"    → 直升机/飞机
--   InVehicle = "ground" → 坦克/车辆
-- ============================================================
local function getVehicleState()
    local v = LP:GetAttribute("InVehicle")
    return v  -- "air" | "ground" | nil
end

VF.GetVehicleState = getVehicleState
VF.IsInVehicle = function() return getVehicleState() ~= nil end

-- 载具类型
VF.IsInAirVehicle = function() return getVehicleState() == "air" end
VF.IsInGroundVehicle = function() return getVehicleState() == "ground" end

VF.PredictPos = predictPos
VF.GetVelocity = function(model)
    local rec = velTrack[model]
    return rec and rec.vel or Vector3.new(0, 0, 0)
end

-- ============================================================
-- 选目标
-- ============================================================
local function visible(fromPos, toPos, ignoreModel)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    -- 排除自己和目标本身；不排除相机（相机不是物理体）
    rp.FilterDescendantsInstances = { LP.Character, ignoreModel }
    rp.IgnoreWater = true
    local dir = toPos - fromPos
    local dist = dir.Magnitude
    if dist < 1 then return true end
    local hit = Workspace:Raycast(fromPos, dir, rp)
    if not hit then return true end
    -- 命中点非常接近目标（<3 米）视为可见，避免擦边误判
    if hit.Distance >= dist - 3 then return true end
    return false
end

local function pickTarget()
    local enemies = getEnemies()
    if #enemies == 0 then return nil end

    local center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local origin = Camera.CFrame.Position
    local best, bestScore = nil, math.huge
    local prio = State.Priority

    for _, e in ipairs(enemies) do
        local part = State.SilentHeadOnly and (e.model:FindFirstChild("Head") or e.part) or e.part
        if part then
            local sp = Camera:WorldToViewportPoint(part.Position)
            local screenDist = (Vector2.new(sp.X, sp.Y) - center).Magnitude
            local worldDist = (part.Position - origin).Magnitude

            local inFront = sp.Z > 0
            local inFov = inFront and screenDist <= State.SilentFOV
            if inFov and worldDist <= 1500 then
                local pass = true
                if State.SilentWallCheck then
                    pass = visible(origin, part.Position, e.model)
                end
                if pass then
                    local score
                    if prio == "near" then score = worldDist
                    elseif prio == "far" then score = -worldDist
                    elseif prio == "hpLow" then score = e.hum.Health * 10 + worldDist * 0.01
                    elseif prio == "hpHigh" then score = -e.hum.Health * 10 + worldDist * 0.01
                    else score = screenDist end
                    if score < bestScore then
                        best, bestScore = { model = e.model, part = part, hum = e.hum }, score
                    end
                end
            end
        end
    end
    return best
end

VF.PickTarget = pickTarget
VF.IsVisible = visible

-- 目标缓存 (原始版本)
local cachedTarget, cachedPos, predictedPos = nil, nil, nil

task.spawn(function()
    local lastGood = 0
    while true do
        task.wait(0.03)
        if State.SilentEnabled then
            local ok, t = pcall(pickTarget)
            if ok and t then
                cachedTarget = t
                cachedPos = t.part.Position
                predictedPos = cachedPos
                lastGood = os.clock()
                State.cachedTarget = cachedTarget
                State.cachedPos = cachedPos
                State.cacheMiss = 0
            else
                -- ★ 关键: 失败时保留上次有效值 0.5 秒, 避免开枪瞬间缓存为空
                State.cacheMiss = (State.cacheMiss or 0) + 1
                if os.clock() - lastGood > 0.5 then
                    cachedTarget, cachedPos, predictedPos = nil, nil, nil
                    State.cachedTarget = nil
                    State.cachedPos = nil
                end
            end
        else
            cachedTarget, cachedPos, predictedPos = nil, nil, nil
            lastGood = 0
            State.cachedTarget = nil
            State.cachedPos = nil
        end
    end
end)

-- ============================================================
-- 静默瞄准: Hook 所有 Fire* Remote 的 direction
-- ============================================================
local FIRE_NAMES = {
    FireRifle = true, FirePistol = true, FireSniper = true, FireSMG = true,
    FireLMG = true, FireDMR = true, FireShotgun = true, FireMinigun = true,
    FireHandCannon = true, FireRocket = true, FireFlame = true, FireAA = true,
}

local hookedCount = 0

task.spawn(function()
    local voxel = RS:FindFirstChild("Voxel")
    if not voxel then return end
    local remotes = voxel:FindFirstChild("Remotes")
    if not remotes then return end

    for _, r in ipairs(remotes:GetChildren()) do
        if r:IsA("RemoteEvent") and FIRE_NAMES[r.Name] then
            local wrapped = false
            pcall(function()
                local mt = getrawmetatable(game)
                -- 用 __namecall 无法区分实例, 改用 hook function
                -- hookfunction 对 RemoteEvent.FireServer 无效 (C 方法每次新闭包)
                -- → 用 hookmetamethod 会拖垮心跳
                -- → 改用: 替换 Remote 的 FireServer 通过 setreadonly + rawset
                if not r:GetAttribute("__vfHooked") then
                    r:SetAttribute("__vfHooked", true)
                    wrapped = true
                end
            end)
            if wrapped then hookedCount = hookedCount + 1 end
        end
    end
end)

-- 真正可用的方案: hookmetamethod 但只在目标 Remote 上改写, 并保护心跳
local namecallInstalled = false
local function installNamecall()
    local ok = pcall(function()
        local mt = getrawmetatable(game)
        -- ★ 先还原到「真正的原始 __namecall」, 消除重复部署叠加
        local pure = getgenv().__VF_ORIG_NC
        if pure == nil then
            -- 第一次挂钩: 记录原始并保存
            pure = rawget(mt, "__namecall")
            getgenv().__VF_ORIG_NC = pure
            getgenv().__VF_NC_DEPTH = 0
        end
        local old = pure
        setreadonly(mt, false)
mt.__namecall = newcclosure(function(self, ...)
            local method = getnamecallmethod()
            if method ~= "FireServer" then return old(self, ...) end
            if not State.SilentEnabled then return old(self, ...) end
            local nm = self.Name
            if not FIRE_NAMES[nm] then
                return old(self, ...)
            end

            local args = table.pack(...)
            local a1, a2 = args[1], args[2]
            if typeof(a1) == "Vector3" and typeof(a2) == "Vector3" then
                local tp = cachedPos
                if tp then
                    local d = tp - a1
                    if d.Magnitude > 1 then
                        args[2] = d.Unit
                        State.RedirectCount = (State.RedirectCount or 0) + 1
                    end
                end
            end
            return old(self, table.unpack(args, 1, args.n))
        end)
        setreadonly(mt, true)
        namecallInstalled = true
        getgenv().__VF_NC_DEPTH = (getgenv().__VF_NC_DEPTH or 0) + 1
        print("[VF] __namecall 挂钩完成 (静默瞄准) 层级=" .. tostring(getgenv().__VF_NC_DEPTH))
    end)
    return ok
end

installNamecall()

-- ============================================================
-- ESP
-- ============================================================
local espFolder = Instance.new("Folder")
espFolder.Name = "VF_ESP"
espFolder.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")

local function createBox(model)
    local hl = Instance.new("Highlight")
    hl.Name = "VF_HL"
    hl.Adornee = model
    hl.FillColor = Color3.fromRGB(255, 60, 60)
    hl.FillTransparency = 0.65
    hl.OutlineColor = Color3.fromRGB(255, 100, 100)
    hl.OutlineTransparency = 0
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.Parent = espFolder
    return hl
end

local espCache = {}

task.spawn(function()
    while true do
        task.wait(0.25)
        if State.ESPEnabled then
            local enemies = getEnemies()
            local alive = {}
            for _, en in ipairs(enemies) do
                local m = en.model
                alive[m] = true
                local e = espCache[m]
                if not e then
                    e = { hl = createBox(m), alive = true }
                    espCache[m] = e
                else
                    e.alive = true
                    if not e.hl or not e.hl.Parent then
                        e.hl = createBox(m)
                    end
                end
            end
            -- 清理不在列表里的
            for m, e in pairs(espCache) do
                if not alive[m] or not m.Parent then
                    if e.hl then e.hl:Destroy() end
                    espCache[m] = nil
                end
            end
        else
            for m, e in pairs(espCache) do
                if e.hl then e.hl:Destroy() end
            end
            espCache = {}
        end
    end
end)

-- 标签 (名字/距离/血量) 用 ScreenGui 画
local labelGui = Instance.new("ScreenGui")
labelGui.Name = "VF_ESP_Labels"
labelGui.ResetOnSpawn = false
labelGui.IgnoreGuiInset = true
labelGui.DisplayOrder = 996
labelGui.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")

local labelCache = {}
RunService.RenderStepped:Connect(function()
    if not State.ESPEnabled then
        for m, lb in pairs(labelCache) do lb.Visible = false end
        return
    end
    local alive = {}
    for _, en in ipairs(getEnemies()) do
        local m = en.model
        alive[m] = true
        local lb = labelCache[m]
        if not lb then
            lb = Instance.new("TextLabel")
            lb.BackgroundTransparency = 1
            lb.Size = UDim2.new(0, 160, 0, 30)
            lb.Font = Enum.Font.GothamBold
            lb.TextSize = 11
            lb.TextColor3 = Color3.fromRGB(255, 100, 100)
            lb.TextStrokeTransparency = 0.3
            lb.TextYAlignment = Enum.TextYAlignment.Top
            lb.Parent = labelGui
            labelCache[m] = lb
        end
        local part = en.part
        local sp = Camera:WorldToViewportPoint(part.Position)
        local dist = (part.Position - Camera.CFrame.Position).Magnitude
        -- ★ 关键: sp.Z > 0 表示在相机前方, 否则是镜像坐标(假的)
        local inFront = sp.Z > 0
        if inFront and sp.X > -100 and sp.X < Camera.ViewportSize.X + 100
           and sp.Y > -100 and sp.Y < Camera.ViewportSize.Y + 100
           and dist <= State.ESPMaxDist then
            local lines = {}
            if State.ESPName then table.insert(lines, m.Name) end
            if State.ESPDistance then table.insert(lines, string.format("%dm", math.floor(dist / 3.5))) end
            if State.ESPHealth then table.insert(lines, string.format("%d HP", math.floor(en.hum.Health))) end
            lb.Text = table.concat(lines, " | ")
            lb.Position = UDim2.new(0, sp.X - 80, 0, sp.Y - 40)
            lb.Visible = true
        else
            lb.Visible = false
        end
    end
    for m, lb in pairs(labelCache) do
        if not alive[m] or not m.Parent then
            lb:Destroy()
            labelCache[m] = nil
        end
    end
end)

-- ============================================================
-- FOV 圈 + 指示器
-- ============================================================
local ovGui = Instance.new("ScreenGui")
ovGui.Name = "VF_Overlay"
ovGui.ResetOnSpawn = false
ovGui.IgnoreGuiInset = true
ovGui.DisplayOrder = 998
ovGui.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")

local fovCircle = Instance.new("Frame")
fovCircle.Name = "FOVCircle"
fovCircle.BackgroundTransparency = 1
fovCircle.BorderSizePixel = 0
fovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
fovCircle.Visible = false
fovCircle.ZIndex = 10
fovCircle.Parent = ovGui
local fovStroke = Instance.new("UIStroke")
fovStroke.Thickness = 1.5
fovStroke.Color = Color3.fromRGB(0, 255, 190)
fovStroke.Transparency = 0.5
fovStroke.Parent = fovCircle
Instance.new("UICorner", fovCircle).CornerRadius = UDim.new(1, 0)

local indCircle = Instance.new("Frame")
indCircle.BackgroundTransparency = 1
indCircle.Size = UDim2.new(0, 30, 0, 30)
indCircle.Visible = false
indCircle.Parent = ovGui
local indStroke = Instance.new("UIStroke")
indStroke.Thickness = 2
indStroke.Color = Color3.fromRGB(255, 60, 60)
indStroke.Parent = indCircle
Instance.new("UICorner", indCircle).CornerRadius = UDim.new(1, 0)

RunService.RenderStepped:Connect(function()
    local on = State.SilentEnabled
    fovCircle.Visible = on and State.ShowFOV
    if on and State.ShowFOV then
        local s = State.SilentFOV * 2
        fovCircle.Size = UDim2.new(0, s, 0, s)
        fovCircle.Position = UDim2.new(0.5, 0, 0.5, 0)
    end

    if on and State.ShowIndicator and cachedPos then
        local sp = Camera:WorldToViewportPoint(cachedPos)
        if sp.X > -200 and sp.X < Camera.ViewportSize.X + 200 then
            local d = (cachedPos - Camera.CFrame.Position).Magnitude
            local dia = math.clamp(4000 / math.max(d, 10), 16, 70)
            indCircle.Size = UDim2.new(0, dia, 0, dia)
            indCircle.Position = UDim2.new(0, sp.X - dia / 2, 0, sp.Y - dia / 2)
            indCircle.Visible = true
        else
            indCircle.Visible = false
        end
    else
        indCircle.Visible = false
    end
end)

-- ============================================================
local RELOAD_MAP = {
    AssaultRifle = "ReloadRifle", K433 = "ReloadRifle", BT762 = "ReloadRifle",
    MX65 = "ReloadRifle", SK556 = "ReloadRifle", RN545 = "ReloadRifle", GX36 = "ReloadRifle",
    SMG = "ReloadSMG", HM45 = "ReloadSMG", SP44 = "ReloadSMG", TK17 = "ReloadSMG",
    PD46 = "ReloadSMG", KP50 = "ReloadSMG",
    LMG = "ReloadLMG", MG60 = "ReloadLMG", HX83 = "ReloadLMG", BX110 = "ReloadLMG",
    Sniper = "ReloadSniper", SC11 = "ReloadSniper", RX10 = "ReloadSniper",
    DMR = "ReloadDMR", FS16 = "ReloadDMR", QS9 = "ReloadDMR", GV12 = "ReloadDMR", KR54 = "ReloadDMR",
    Pistol = "ReloadPistol", ZK10 = "ReloadPistol", SV20 = "ReloadPistol",
    Shotgun = "ReloadShotgun", HandCannon = "ReloadHandCannon", RocketLauncher = "ReloadRocket",
}

local function getTool()
    local c = LP.Character
    return c and c:FindFirstChildOfClass("Tool") or nil
end

local function rageVisible(fromPos, tp, tmodel)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = { LP.Character, tmodel }
    rp.IgnoreWater = true
    local dir = tp - fromPos
    local dist = dir.Magnitude
    if dist < 1 then return true end
    local hit = Workspace:Raycast(fromPos, dir, rp)
    if not hit then return true end
    return hit.Distance >= dist - 1.5
end

local function tryReload()
    local tool = getTool()
    if not tool then return end
    local rname = RELOAD_MAP[tool.Name]
    if not rname then return end
    pcall(function()
        local vx = RS:FindFirstChild("Voxel")
        local rem = vx and vx:FindFirstChild("Remotes")
        local r = rem and rem:FindFirstChild(rname)
        if r then
            r:FireServer()
            State.ReloadCount = (State.ReloadCount or 0) + 1
        end
    end)
end
VF.TryReload = tryReload

-- 实例代次: 新脚本加载会递增, 旧的循环自动退出
local MY_GEN = getgenv().__VF_GEN or 0   -- 本实例的代次(由文件顶部统一设置)

-- 一直装弹
task.spawn(function()
    local lastShotSeen = 0
    local lastCount = 0
    while true do
        task.wait(0.2)
        -- ★ 代次不符说明有更新的实例加载了, 主动退出

        if State.AlwaysReload and getgenv().VF == State then
            local cur = State.RedirectCount or 0
            if cur ~= lastCount then
                lastCount = cur
                lastShotSeen = os.clock()
            elseif os.clock() - lastShotSeen > 0.6 then
                pcall(tryReload)
                lastShotSeen = os.clock()
            end
        end
    end
end)

-- ============================================================
-- WindUI 界面
-- ============================================================
local Window = WindUI:CreateWindow({
    Title = "体素战争 · 解卡中枢",
    Icon = "crosshair",
    Size = UDim2.fromOffset(560, 420),
    Theme = "Dark",
})

-- Tab: 瞄准
local AimTab = Window:Tab({ Title = "瞄准", Icon = "crosshair" })
AimTab:Section({ Title = "静默瞄准", Icon = "target" })
AimTab:Toggle({
    Title = "启用静默瞄准",
    Value = false,
    Callback = function(s) State.SilentEnabled = s end,
})
AimTab:Toggle({
    Title = "只打头部",
    Value = true,
    Callback = function(s) State.SilentHeadOnly = s end,
})
AimTab:Toggle({
    Title = "穿墙检测",
    Value = false,
    Callback = function(s) State.SilentWallCheck = s end,
})
AimTab:Slider({
    Title = "FOV 范围",
    Value = { Min = 50, Max = 2400, Default = 127 },
    Callback = function(v) State.SilentFOV = v end,
})
AimTab:Toggle({
    Title = "显示 FOV 圈",
    Value = false,
    Callback = function(s) State.ShowFOV = s end,
})
AimTab:Toggle({
    Title = "显示目标指示",
    Value = false,
    Callback = function(s) State.ShowIndicator = s end,
})
AimTab:Toggle({
    Title = "载具武器静默 (直升机/坦克)",
    Value = true,
    Callback = function(s) State.VehicleAim = s end,
})

AimTab:Section({ Title = "装弹", Icon = "refresh-cw" })
AimTab:Toggle({
    Title = "一直装弹 (无条件)",
    Value = false,
    Callback = function(s) State.AlwaysReload = s end,
})

AimTab:Dropdown({
    Title = "优先目标",
    Values = { "准星最近", "距离最近", "距离最远", "血量最低", "血量最高" },
    Value = "准星最近",
    Callback = function(v)
        local map = {
            ["准星最近"] = "crosshair", ["距离最近"] = "near",
            ["距离最远"] = "far", ["血量最低"] = "hpLow", ["血量最高"] = "hpHigh",
        }
        State.Priority = map[v] or "crosshair"
    end,
})

-- Tab: ESP
local EspTab = Window:Tab({ Title = "ESP", Icon = "eye" })
EspTab:Section({ Title = "透视", Icon = "scan-eye" })
EspTab:Toggle({
    Title = "启用 ESP",
    Value = false,
    Callback = function(s) State.ESPEnabled = s end,
})
EspTab:Toggle({
    Title = "显示名字",
    Value = true,
    Callback = function(s) State.ESPName = s end,
})
EspTab:Toggle({
    Title = "显示距离",
    Value = true,
    Callback = function(s) State.ESPDistance = s end,
})
EspTab:Toggle({
    Title = "显示血量",
    Value = true,
    Callback = function(s) State.ESPHealth = s end,
})
EspTab:Toggle({
    Title = "队伍检查",
    Value = true,
    Callback = function(s) State.ESPTeamCheck = s end,
})
EspTab:Slider({
    Title = "最大距离",
    Value = { Min = 50, Max = 2000, Default = 500 },
    Callback = function(v) State.ESPMaxDist = v end,
})

-- Tab: 信息
local InfoTab = Window:Tab({ Title = "信息", Icon = "info" })
InfoTab:Section({ Title = "状态", Icon = "activity" })
local statusLabel = InfoTab:Paragraph({ Title = "运行状态", Desc = "等待初始化…" })

task.spawn(function()
    while true do
        task.wait(1)
        pcall(function()
            local myTeam = myTeamName() or "无队伍"
            local enemies = #getEnemies()
            local tgt = cachedTarget and cachedTarget.model.Name or "无"
            statusLabel:SetDesc(string.format(
                "我方: %s | 敌人: %d | 目标: %s | 重定向: %d",
                myTeam, enemies, tgt, State.RedirectCount or 0))
        end)
    end
end)

-- Tab: 关于
local AboutTab = Window:Tab({ Title = "关于", Icon = "user" })
AboutTab:Section({ Title = "作者", Icon = "user-round" })
AboutTab:Paragraph({
    Title = "B站：英吉利超入_",
    Desc = "脚本作者",
})

-- ============================================================
-- 快捷键 + 悬浮按钮 (解决最小化后找不到窗口)
--   RightShift  → 显示/隐藏窗口
--   RightCtrl   → 快速开关静默瞄准
--   屏幕左上角小圆点 → 点击展开窗口
-- ============================================================
local UIS = game:GetService("UserInputService")

-- 找 WindUI 主窗口: ScreenGui "WindUI" → Folder "Window" → Frame(560x420)
-- 找 WindUI 的 ScreenGui (整层开关最可靠)
-- 悬浮按钮 (窗口隐藏时的恢复入口)
local floatGui = Instance.new("ScreenGui")
floatGui.Name = "VF_FloatBtn"
floatGui.ResetOnSpawn = false
floatGui.IgnoreGuiInset = true
floatGui.DisplayOrder = 999
floatGui.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")

local floatingBtn = Instance.new("TextButton")
floatingBtn.Size = UDim2.new(0, 44, 0, 44)
floatingBtn.Position = UDim2.new(0, 12, 0, 90)
floatingBtn.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
floatingBtn.BackgroundTransparency = 0.15
floatingBtn.Text = "VF"
floatingBtn.TextColor3 = Color3.fromRGB(120, 200, 255)
floatingBtn.Font = Enum.Font.GothamBold
floatingBtn.TextSize = 15
floatingBtn.BorderSizePixel = 0
floatingBtn.Visible = false
floatingBtn.Parent = floatGui
Instance.new("UICorner", floatingBtn).CornerRadius = UDim.new(1, 0)
local fbStroke = Instance.new("UIStroke")
fbStroke.Color = Color3.fromRGB(0, 180, 255)
fbStroke.Thickness = 1.5
fbStroke.Parent = floatingBtn

local function getWindGui()
    local ok, hui = pcall(function() return gethui() end)
    local container = (ok and hui) or LP:WaitForChild("PlayerGui")
    for _, d in ipairs(container:GetChildren()) do
        if d:IsA("ScreenGui") and d.Name == "WindUI" then
            return d
        end
    end
    return nil
end

local uiHidden = false
local function toggleWindow()
    local gui = getWindGui()

    if not gui then
        if floatingBtn then floatingBtn.Visible = true end
        return
    end
    uiHidden = not uiHidden
    gui.Enabled = not uiHidden
    if floatingBtn then floatingBtn.Visible = uiHidden end
end

VF.ToggleWindow = toggleWindow

floatingBtn.MouseButton1Click:Connect(function()
    toggleWindow()
end)

-- 快捷键
UIS.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        toggleWindow()
    elseif input.KeyCode == Enum.KeyCode.RightControl then
        State.SilentEnabled = not State.SilentEnabled
WindUI:Notify({
            Title = "静默瞄准",
            Content = State.SilentEnabled and "已开启" or "已关闭",
            Duration = 1.5,
        })
    elseif input.KeyCode == Enum.KeyCode.RightAlt then
        State.ESPEnabled = not State.ESPEnabled
        WindUI:Notify({
            Title = "ESP",
            Content = State.ESPEnabled and "已开启" or "已关闭",
            Duration = 1.5,
        })
    end
end)

WindUI:Notify({
    Title = "快捷键",
    Content = "RightShift 显示/隐藏窗口 | RightCtrl 静默 | RightAlt ESP",
    Duration = 5,
})

WindUI:Notify({
    Title = "体素战争",
    Content = "脚本已加载",
    Duration = 3,
})

print("[VF] 加载完成")
