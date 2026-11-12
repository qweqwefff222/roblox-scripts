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
    SilentFOV = 300,
    SilentHeadOnly = true,
    SilentWallCheck = false,
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

    -- 穿墙子弹
    WallBang = false,
    WallBangOffset = 6,      -- 起点前移距离

}

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
local ballisticFn = nil
pcall(function()
    local vx = RS:FindFirstChild("Voxel")
    local B = vx and vx:FindFirstChild("Ballistics")
    if B then
        local ok, mod = pcall(require, B)
        if ok and type(mod) == "table" then
            Ballistics = mod
            if type(mod.launch) == "function" then
                ballisticFn = mod.launch
            end
        end
    end
end)
State.HasBallistics = ballisticFn ~= nil
print("[VF] 弹道模块: " .. tostring(ballisticFn ~= nil))

-- 计算发射方向 (含下坠补偿)
local function computeShotDir(from, to)
    if ballisticFn then
        local ok, dir = pcall(ballisticFn, from, to, State.CurrentBulletSpeed or 2400)
        if ok and typeof(dir) == "Vector3" then
            return dir
        end
    end
    local d = to - from
    return d.Magnitude > 0.1 and d.Unit or Vector3.new(0, 0, -1)
end

-- 弹速自动读取
local bulletSpeed = 1000
local travelTimeFn = nil
pcall(function()
    local vx = RS:FindFirstChild("Voxel")
    local T = vx and vx:FindFirstChild("Tracers")
    if T then
        local ok, mod = pcall(require, T)
        if ok and type(mod) == "table" then
            if type(mod.SPEED) == "number" then bulletSpeed = mod.SPEED end
            if type(mod.travelTime) == "function" then travelTimeFn = mod.travelTime end
        end
    end
end)
State.BulletSpeed = bulletSpeed
State.CurrentBulletSpeed = bulletSpeed

-- 动态读当前武器弹速 (每 0.5 秒)
task.spawn(function()
    while true do
        task.wait(0.5)
        pcall(function()
            local char = LP.Character
            if not char then return end
            local tool = char:FindFirstChildOfClass("Tool")
            if not tool then return end
            -- 从武器 Client 脚本推断: 步枪类 2400, DMR 1500, 狙击 1600-2000
            local nm = tool.Name
            local speed = bulletSpeed
            local n = string.lower(nm)
            if string.find(n, "sniper") then speed = 1900
            elseif string.find(n, "dmr") then speed = 1500
            elseif string.find(n, "smg") then speed = 1700
            elseif string.find(n, "lmg") then speed = 1700
            elseif string.find(n, "pistol") then speed = 1700
            elseif string.find(n, "shotgun") then speed = 1500
            else speed = 2400 end   -- 步枪类默认 2400
            State.CurrentBulletSpeed = speed
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

    -- 飞行时间: 优先官方函数, 否则 距离/弹速
    local flight
    if travelTimeFn then
        local ok, t = pcall(travelTimeFn, origin, part.Position)
        flight = (ok and type(t) == "number") and t or (dist / bulletSpeed)
    else
        flight = dist / bulletSpeed
    end
    flight = math.clamp(flight, 0, State.PredictMaxTime)

    -- 敌人速度
    local rec = velTrack[m]
    local vel = rec and rec.vel or Vector3.new(0, 0, 0)

    return part.Position + vel * flight
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
    rp.FilterDescendantsInstances = { LP.Character, ignoreModel, Camera }
    rp.IgnoreWater = true
    local hit = Workspace:Raycast(fromPos, toPos - fromPos, rp)
    return hit == nil
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

            local inFov = screenDist <= State.SilentFOV
            if inFov and worldDist <= 1000 then
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

-- 目标缓存
local cachedTarget, cachedPos, predictedPos = nil, nil, nil
local shotDirCache = nil
local vehiclePos = nil
task.spawn(function()
    while true do
        task.wait(0.04)
        if State.SilentEnabled then
            local ok, t = pcall(pickTarget)
            cachedTarget = ok and t or nil
            cachedPos = (ok and t) and t.part.Position or nil
            -- 预计算预测位置 (在后台算, hook 里只读)
            if ok and t then
                local pok, pp = pcall(predictPos, t)
                predictedPos = (pok and pp) or cachedPos
            else
                predictedPos = nil
            end

            -- ★ 预计算射击方向 (含弹道下坠补偿)
            shotDirCache = nil
            if predictedPos and Camera then
                local from = Camera.CFrame.Position
                pcall(function()
                    shotDirCache = computeShotDir(from, predictedPos)
                end)
            end
            State.cachedTarget = cachedTarget
            State.cachedPos = cachedPos
            State.predictedPos = predictedPos

            -- 缓存载具位置 (供 hook 里做角度换算, 避免重入)
            local vp = nil
            pcall(function()
                local c = LP.Character
                if not c then return end
                local hrp = c:FindFirstChild("HumanoidRootPart")
                if hrp and LP:GetAttribute("InVehicle") then
                    vp = hrp.Position
                end
            end)
            vehiclePos = vp
            State.vehiclePos = vp
        else
            cachedTarget, cachedPos = nil, nil
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
    if namecallInstalled then return end
    local ok = pcall(function()
        local mt = getrawmetatable(game)
        local old = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            local method = getnamecallmethod()
            -- 只处理 FireServer, 其它一律原样透传 (零改动)
            if method ~= "FireServer" then
                return old(self, ...)
            end
            if not State.SilentEnabled then
                return old(self, ...)
            end
            if typeof(self) ~= "Instance" then
                return old(self, ...)
            end

            local nm = self.Name
            local args = table.pack(...)

            -- ① 步兵枪械: (origin, direction, serverTime)
            if FIRE_NAMES[nm] then
                local a1, a2 = args[1], args[2]
                if typeof(a1) == "Vector3" and typeof(a2) == "Vector3" then
                    -- ★ 用预计算的含下坠方向; 没有则退回直线
                    local dir = shotDirCache
                    if not dir then
                        local tp = predictedPos or cachedPos
                        if tp then
                            local d = tp - a1
                            if d.Magnitude > 1 then dir = d.Unit end
                        end
                    end
                    if dir then
                        -- ★ 穿墙: 把起点移到目标附近, 服务端射线绕开墙体
                        if State.WallBang then
                            local tp = predictedPos or cachedPos
                            if tp then
                                local gap = (tp - a1).Magnitude
                                if gap > (State.WallBangOffset + 2) then
                                    args[1] = tp - dir * State.WallBangOffset
                                end
                            end
                        end
                        args[2] = dir
                        State.RedirectCount = (State.RedirectCount or 0) + 1
                    end
                end
                return old(self, table.unpack(args, 1, args.n))
            end

            -- ② 直升机机炮: (id, "gun", hitPos)  → 改第3参数
            if nm == "HeliFire" and State.VehicleAim then
                local aimPos = predictedPos or cachedPos
                if aimPos and args[2] == "gun" and typeof(args[3]) == "Vector3" then
                    args[3] = aimPos
                    State.RedirectCount = (State.RedirectCount or 0) + 1
                    State.LastVehicleRedirect = os.clock()
                end
                return old(self, table.unpack(args, 1, args.n))
            end

            -- ③ 坦克: (id, yaw, pitch, [弹种]) → 角度换算
            if nm == "TankFire" and State.VehicleAim then
                local tp = predictedPos or cachedPos
                local org = vehiclePos
                if tp and org then
                    local d = tp - org
                    local flat = Vector3.new(d.X, 0, d.Z)
                    if flat.Magnitude > 0.5 then
                        -- ★ 复刻游戏 DeathCam 公式: yaw=atan2(X,Z), pitch 弧度+clamp
                        args[2] = math.atan2(d.X, d.Z)
                        args[3] = math.clamp(
                            math.atan2(d.Y, flat.Magnitude),
                            0.13962634015954636,
                            1.3089969389957472
                        )
                        State.RedirectCount = (State.RedirectCount or 0) + 1
                    end
                end
                return old(self, table.unpack(args, 1, args.n))
            end

            -- ④ 直升机瞄准同步: (id, yaw, pitch, spin)
            if nm == "HeliGunAim" and State.VehicleAim then
                local tp = predictedPos or cachedPos
                local org = vehiclePos
                if tp and org then
                    local d = tp - org
                    local flat = Vector3.new(d.X, 0, d.Z)
                    if flat.Magnitude > 0.5 then
                        -- ★ 游戏公式: yaw=atan2(X,Z)
                        args[2] = math.atan2(d.X, d.Z)
                        args[3] = math.atan2(d.Y, flat.Magnitude)
                    end
                end
                return old(self, table.unpack(args, 1, args.n))
            end

            -- 未匹配: 原样透传
            return old(self, ...)
        end)
        setreadonly(mt, true)
        namecallInstalled = true
        print("[VF] __namecall 挂钩完成 (静默瞄准)")
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
fovCircle.BackgroundTransparency = 1
fovCircle.Visible = false
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
        fovCircle.Position = UDim2.new(0.5, -State.SilentFOV, 0.5, -State.SilentFOV)
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
    Value = { Min = 50, Max = 1200, Default = 300 },
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
    Title = "穿墙子弹 (WallBang)",
    Value = false,
    Callback = function(s) State.WallBang = s end,
})
AimTab:Slider({
    Title = "穿墙起点前移",
    Value = { Min = 2, Max = 20, Default = 6 },
    Callback = function(v) State.WallBangOffset = v end,
})

AimTab:Toggle({
    Title = "载具武器静默 (直升机/坦克)",
    Value = true,
    Callback = function(s) State.VehicleAim = s end,
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
