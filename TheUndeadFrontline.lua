--[[
    ══════════════════════════════════════════════════════════
    The Undead Frontline — 解卡中枢脚本 v13.1
    ══════════════════════════════════════════════════════════
--]]

--[[
    静默瞄准核心 v3 — 投射物方向改写 (最终方案)
    ────────────────────────────────────────────
    原理（从游戏源码逆向得出）：
      1. 开火 → Shoot.CreateProjectile 创建投射物 Part
         并 SetAttribute("direction", v1.direction)
      2. ProjectileManager 每帧:
           Unit = part:GetAttribute("direction").Unit
           v8   = Unit * velocity * dt
           hit  = shared.Raycast.fromProjectile(Position, v8, filter)
           if hit.result then
               require(Shoot.Hit)(hit, player, tool, config)   ← 生成真实命中
           end
      3. Shoot.Hit 把命中累积进 buffer，flush 时发 "DamageBatch"

    → 只要把投射物的 direction 属性改成指向僵尸头部，
      整条链就会自动算成真实命中，服务端收到的是合法数据。
      不伪造封包、不钩元表，反作弊完全无感。

    历史教训（都试过，都失败）：
      ✗ hookfunction(RemoteEvent.FireServer) → C 方法, 钩不持久
      ✗ hookmetamethod("__namecall") → 全局拦截, Adonis 心跳超时踢人 (267)
      ✗ 改 Shoot 的 direction → 客户端本地 raycast 已经先跑完了, 太晚
--]]

local SilentAim = {}
SilentAim.Enabled       = false
SilentAim.FOV           = 600
SilentAim.HeadOnly      = true
SilentAim.WallCheck     = false
SilentAim.ShowFOV       = false
SilentAim.ShowIndicator = false
SilentAim.LastTarget    = nil
SilentAim.LastDist      = 0
SilentAim.RedirectCount = 0
-- 优先目标模式: "hpLow" | "hpHigh" | "near" | "far"
SilentAim.Priority = "near"

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LP = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

-- ============================================================
-- 僵尸识别
-- ============================================================
local ZOMBIE_KEYWORDS = {
    "Shambler", "Runner", "Spitter", "Bomber", "Brute", "Crawler",
    "Zombie", "zombie", "Skeleton", "Ghoul", "Infected", "Walker",
    "Engineer", "Igniter", "Cavalry", "Hallow", "Wendigo", "Tank",
}

local function isZombie(m)
    if not m or not m:IsA("Model") then return false end
    local hum = m:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    if Players:GetPlayerFromCharacter(m) then return false end
    local n = m.Name
    for _, k in ipairs(ZOMBIE_KEYWORDS) do
        if string.find(n, k) then return true end
    end
    local p = m.Parent
    if p and (p.Name == "Entities" or p.Name == "Zombies"
              or p.Name == "Enemies" or p.Name == "Mobs") then
        return true
    end
    return false
end

local function getZombies()
    local list, seen = {}, {}
    local g = Workspace:FindFirstChild("Game")
    local containers = {}
    if g then
        for _, n in ipairs({"Entities", "Zombies", "Enemies", "Mobs"}) do
            local c = g:FindFirstChild(n)
            if c then table.insert(containers, c) end
        end
    end
    for _, c in ipairs(containers) do
        for _, m in ipairs(c:GetChildren()) do
            if isZombie(m) and not seen[m] then
                seen[m] = true
                table.insert(list, m)
            end
        end
    end
    if #list == 0 then
        for _, m in ipairs(Workspace:GetChildren()) do
            if isZombie(m) and not seen[m] then
                seen[m] = true
                table.insert(list, m)
            end
        end
    end
    return list
end

local function getTargetPart(z)
    if SilentAim.HeadOnly then
        return z:FindFirstChild("Head") or z:FindFirstChild("HumanoidRootPart")
    end
    return z:FindFirstChild("HumanoidRootPart") or z:FindFirstChild("Head")
end

local function visible(fromPos, toPos, ignoreModel)
    -- 射线检测：从相机到目标，排除自己角色、相机、目标本身
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = {
        LP.Character or LP,
        ignoreModel,
        Camera,
        Workspace:FindFirstChild("Game") and Workspace.Game:FindFirstChild("Debris") or nil,
    }
    rp.CollisionGroup = "ProjectileRay"
    rp.IgnoreWater = true
    local hit = Workspace:Raycast(fromPos, toPos - fromPos, rp)
    return hit == nil, hit
end

SilentAim.visible = visible

local function scoreTarget(z, part, screenDist, worldDist)
    local prio = SilentAim.Priority or "near"
    if prio == "near" then
        return worldDist
    elseif prio == "far" then
        return -worldDist
    elseif prio == "hpLow" then
        local hum = z:FindFirstChildOfClass("Humanoid")
        local hp = hum and hum.Health or 99999
        -- 血量低优先；同血量时近的优先
        return hp * 10 + worldDist * 0.01
    elseif prio == "hpHigh" then
        local hum = z:FindFirstChildOfClass("Humanoid")
        local hp = hum and hum.Health or -99999
        return -hp * 10 + worldDist * 0.01
    end
    return worldDist
end

local function pickTarget()
    local zombies = getZombies()
    if #zombies == 0 then return nil end
    local center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local originPos = Camera.CFrame.Position
    local best, bestScore = nil, math.huge
    local prio = SilentAim.Priority or "near"

    for _, z in ipairs(zombies) do
        local part = getTargetPart(z)
        if part then
            local sp = Camera:WorldToViewportPoint(part.Position)
            local screenDist = (Vector2.new(sp.X, sp.Y) - center).Magnitude
            local worldDist = (part.Position - originPos).Magnitude
            local inFov = (screenDist <= SilentAim.FOV) or (prio == "far")
            if inFov and worldDist <= 1500 then
                local ok = true
                if SilentAim.WallCheck then
                    ok = visible(originPos, part.Position, z)
                end
                if ok then
                    local sc = scoreTarget(z, part, screenDist, worldDist)
                    if sc < bestScore then
                        best, bestScore = z, sc
                    end
                end
            end
        end
    end
    return best
end

SilentAim.scoreTarget = scoreTarget
SilentAim.pickTarget = pickTarget
getgenv().SilentAimPickTarget = pickTarget
getgenv().SilentAimGetZombies = getZombies

-- ============================================================
-- 目标缓存（每 40ms 算一次，投射物回调只读）
-- ============================================================
SilentAim.cachedTarget = nil
SilentAim.cachedPos = nil

task.spawn(function()
    while true do
        task.wait(0.04)
        if SilentAim.Enabled then
            local ok, z = pcall(pickTarget)
            SilentAim.cachedTarget = ok and z or nil
            if ok and z then
                local p = getTargetPart(z)
                SilentAim.cachedPos = p and p.Position or nil
                SilentAim.LastTarget = z
            else
                SilentAim.cachedPos = nil
            end
        else
            SilentAim.cachedTarget = nil
            SilentAim.cachedPos = nil
        end
    end
end)

-- ============================================================
-- 核心: 投射物制导 (每帧修正 + 下坠补偿 + 移动预判)
--
-- 基础原理（逆向自 ProjectileManager）：
--   ProjectileManager 每帧读 part:GetAttribute("direction").Unit，
--   用它算 raycast → 命中即调用 Shoot.Hit 生成真实伤害。
--
-- ★ 精度改进（v3.1）：
--   1) 不只创建时改一次，而是**每帧持续修正方向** → 追踪制导
--   2) 补偿弹道下坠 BulletDrop（Config.ProjectileSettings.BulletDrop）
--   3) 预判目标移动（按僵尸速度 × 飞行时间提前量）
--   4) 修正时保持速度大小不变（只改方向）
-- ============================================================
local Projectiles = nil
local watchedContainer = nil
local myName = LP.Name
local tracked = {}          -- [part] = { spawnedAt, config }

local function findProjectiles()
    local g = Workspace:FindFirstChild("Game")
    if not g then return nil end
    local d = g:FindFirstChild("Debris")
    if not d then return nil end
    return d:FindFirstChild("Projectiles")
end

-- 读取投射物对应武器的下坠系数
local function getBulletDrop(part)
    local ok, drop = pcall(function()
        local toolVal = part:FindFirstChild("Tool")
        local tool = toolVal and toolVal.Value
        if not tool then return 0.65 end
        local cfgObj = tool:FindFirstChild("Config")
        if not cfgObj then return 0.65 end
        local cfg = require(cfgObj)
        local ps = cfg and cfg.ProjectileSettings
        return (ps and ps.BulletDrop) or 0.65
    end)
    return (ok and drop) or 0.65
end

-- 目标移动预判
local lastTargetPos = {}
local function predictTarget(z, part, bulletSpeed, dist)
    local key = z
    local now = os.clock()
    local prev = lastTargetPos[key]
    local vel = Vector3.new(0, 0, 0)
    if prev then
        local dt = now - prev.t
        if dt > 0.001 and dt < 0.5 then
            vel = (part.Position - prev.p) / dt
            -- 限制异常速度
            if vel.Magnitude > 120 then vel = Vector3.new(0, 0, 0) end
        end
    end
    lastTargetPos[key] = { p = part.Position, t = now }

    if bulletSpeed <= 1 then return part.Position end
    local flight = dist / bulletSpeed
    -- 最多预判 0.35 秒，避免甩飞
    flight = math.min(flight, 0.35)
    return part.Position + vel * flight
end

-- 单个投射物的每帧修正
local function guideOne(part)
    if not SilentAim.Enabled then return false end
    if not part or not part.Parent then return false end

    -- 只处理自己发射的
    local creator = part:GetAttribute("creator")
    if creator ~= myName then return false end

    local target = SilentAim.cachedTarget
    local targetPos = SilentAim.cachedPos
    if not target or not targetPos then return false end
    if not target.Parent then return false end

    local pos = part.Position
    local delta = targetPos - pos
    local dist = delta.Magnitude
    if dist < 2 or dist > 900 then return false end

    -- 拿到弹速与下坠
    local info = tracked[part]
    if not info then
        local speed = 1400
        local drop = 0.65
        pcall(function()
            local toolVal = part:FindFirstChild("Tool")
            local tool = toolVal and toolVal.Value
            local cfgObj = tool and tool:FindFirstChild("Config")
            if cfgObj then
                local cfg = require(cfgObj)
                local ps = cfg and cfg.ProjectileSettings
                speed = (ps and ps.Velocity) or 1400
                drop = (ps and ps.BulletDrop) or 0.65
            end
        end)
        info = { speed = speed, drop = drop, dist0 = dist }
        tracked[part] = info
    end

    -- ★ 下坠补偿：飞行时间越长，提前抬得越高
    local flight = dist / math.max(info.speed, 1)
    local dropAmount = 0.5 * Workspace.Gravity * info.drop * flight * flight
    local aimPos = targetPos + Vector3.new(0, dropAmount, 0)

    -- ★ 移动预判
    local head = target:FindFirstChild("Head") or target:FindFirstChild("HumanoidRootPart")
    if head then
        aimPos = predictTarget(target, head, info.speed, dist)
        aimPos = aimPos + Vector3.new(0, dropAmount, 0)
    end

    local newDelta = aimPos - pos
    if newDelta.Magnitude < 1 then return false end

    -- ★ 只改方向，保持速度大小（ProjectileManager 用 direction.Unit 做速度方向）
    part:SetAttribute("direction", newDelta.Unit)
    SilentAim.RedirectCount = SilentAim.RedirectCount + 1
    SilentAim.LastDist = dist
    return true
end

-- 每帧制导循环（~60fps，但降频到 30fps 省性能）
local accrued = 0
game:GetService("RunService").Heartbeat:Connect(function(dt)
    if not SilentAim.Enabled then return end
    if not Projectiles or not Projectiles.Parent then return end
    accrued = accrued + dt
    if accrued < 0.016 then return end
    accrued = 0

    -- 遍历容器（数量通常 < 100）
    for _, part in ipairs(Projectiles:GetChildren()) do
        pcall(guideOne, part)
    end
    -- 清理已消失的
    for part in pairs(tracked) do
        if not part.Parent then tracked[part] = nil end
    end
end)

local function ensureWatch()
    local c = findProjectiles()
    if c == nil then return end
    if c == watchedContainer then return end
    watchedContainer = c
    Projectiles = c
    print("[SilentAim] Projectiles 已接管 (每帧制导)")
end

task.spawn(function()
    for _ = 1, 120 do
        ensureWatch()
        if watchedContainer then break end
        task.wait(1)
    end
    while true do
        task.wait(3)
        if not watchedContainer or not watchedContainer.Parent then
            watchedContainer = nil
            Projectiles = nil
            ensureWatch()
        end
    end
end)

-- ============================================================
-- Network 模块获取（运行时查找，避免静态 require 分析报错）
-- ============================================================
local _netCache = nil
local function getNetwork()
    if _netCache then return _netCache end
    local ok, result = pcall(function()
        local RS = game:GetService("ReplicatedStorage")
        local modules = RS:FindFirstChild("Modules")
        if not modules then return nil end
        local lib = modules:FindFirstChild("Library")
        if not lib then return nil end
        local glob = lib:FindFirstChild("Global")
        if not glob then return nil end
        local netMod = glob:FindFirstChild("Network")
        if not netMod then return nil end
        return require(netMod)
    end)
    if ok and type(result) == "table" then
        _netCache = result
        return result
    end
    return nil
end

SilentAim.getNetwork = getNetwork

-- ============================================================
-- 无限体力
--   游戏: ReplicatedStorage.Modules.Client.Character.Locomotion
--     跳跃: stamina -= 20 (line 108)
--     限制: stamina < 20 时禁止跳跃 (line 238)
--   stamina 是纯客户端属性, 即时回补即可
-- ============================================================
SilentAim.InfiniteStaminaEnabled = false

local STAMINA_MAX = 100
local staminaConn = nil

local function keepStaminaFull(char)
    if not char then return end
    local cur = char:GetAttribute("stamina")
    if cur == nil or cur < STAMINA_MAX then
        char:SetAttribute("stamina", STAMINA_MAX)
    end
end

local function attachStamina(char)
    if staminaConn then staminaConn:Disconnect() staminaConn = nil end
    keepStaminaFull(char)
    -- ★ 属性一变立刻回补, 避免体力条抖动
    staminaConn = char:GetAttributeChangedSignal("stamina"):Connect(function()
        if SilentAim.InfiniteStaminaEnabled then
            keepStaminaFull(char)
        end
    end)
end

-- 角色切换时重新挂
LP.CharacterAdded:Connect(function(char)
    task.wait(0.5)
    if SilentAim.InfiniteStaminaEnabled then attachStamina(char) end
end)

task.spawn(function()
    local lastChar = nil
    while true do
        task.wait(0.15)
        if SilentAim.InfiniteStaminaEnabled then
            local char = LP.Character
            if char and char ~= lastChar then
                lastChar = char
                pcall(attachStamina, char)
            elseif char then
                pcall(keepStaminaFull, char)
            end
        else
            lastChar = nil
        end
    end
end)

-- ============================================================
-- ESP — Highlight 版本 (参考 CombatSuite)
--   去掉名字显示, 只留 距离 + 血量
--   普通 Shambler 不标记, 只标特殊兵种
--   防叠加: 每轮 ClearAllChildren + 清旧实例
-- ============================================================
SilentAim.ESPEnabled = false
SilentAim.ESPOnlySpecial = true

local ESP_FOLDER_NAME = "SilentAim_ESP_System"
local oldEsp = game:GetService("CoreGui"):FindFirstChild(ESP_FOLDER_NAME)
if oldEsp then oldEsp:Destroy() end

local espFolder = Instance.new("Folder")
espFolder.Name = ESP_FOLDER_NAME
espFolder.Parent = game:GetService("CoreGui")

-- 特殊兵种中文名
local ZOMBIE_NAMES = {
    Runner    = "红眼",
    Spitter   = "喷吐者",
    Bomber    = "自爆兵",
    Brute     = "巨兽",
    Crawler   = "爬行者",
    Engineer  = "工兵",
    Igniter   = "焚火者",
    Cavalry   = "骑兵",
    Hallow    = "万圣节",
    Wendigo   = "温迪戈",
    Tank      = "坦克",
    Skeleton  = "骷髅",
    Ghoul     = "食尸鬼",
    Infected  = "感染者",
    Warden    = "典狱长",
}

local function isSpecialZombie(z)
    local t = z:GetAttribute("Type") or z.Name
    return t ~= "Shambler"
end

local function displayName(z)
    local t = z:GetAttribute("Type") or z.Name
    return ZOMBIE_NAMES[t] or ZOMBIE_NAMES[z.Name] or t
end

-- 距离/血量标签的容器 (挂在 CoreGui 的 ScreenGui)
local labelGui = Instance.new("ScreenGui")
labelGui.Name = "SilentAim_ESP_Labels"
labelGui.ResetOnSpawn = false
labelGui.IgnoreGuiInset = true
labelGui.DisplayOrder = 996
labelGui.Parent = (getgenv and getgenv().gethui and getgenv().gethui()) or LP:WaitForChild("PlayerGui")

local labelCache = {}

task.spawn(function()
    while true do
        task.wait(0.3)
        espFolder:ClearAllChildren()

        -- 清标签
        for z, lbl in pairs(labelCache) do
            if lbl then lbl:Destroy() end
        end
        labelCache = {}

        if SilentAim.ESPEnabled then
            local zombies = getZombies()
            for _, v in ipairs(zombies) do
                local hum = v:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0 then
                    if (not SilentAim.ESPOnlySpecial) or isSpecialZombie(v) then
                        -- ① Highlight
                        local hl = Instance.new("Highlight")
                        hl.Adornee = v
                        hl.FillColor = Color3.fromRGB(255, 50, 50)
                        hl.FillTransparency = 0.6
                        hl.OutlineColor = Color3.fromRGB(255, 90, 90)
                        hl.OutlineTransparency = 0
                        hl.Parent = espFolder

                        -- ② 距离 + 血量 标签
                        local lbl = Instance.new("TextLabel")
                        lbl.BackgroundTransparency = 1
                        lbl.Size = UDim2.new(0, 120, 0, 14)
                        lbl.Font = Enum.Font.GothamBold
                        lbl.TextSize = 11
                        lbl.TextColor3 = Color3.fromRGB(255, 90, 90)
                        lbl.TextStrokeTransparency = 0.3
                        lbl.Text = ""
                        lbl.Parent = labelGui
                        labelCache[v] = lbl
                    end
                end
            end
        end
    end
end)

-- 每帧更新标签位置
game:GetService("RunService").RenderStepped:Connect(function()
    if not SilentAim.ESPEnabled then
        for z, lbl in pairs(labelCache) do
            if lbl then lbl.Visible = false end
        end
        return
    end
    for z, lbl in pairs(labelCache) do
        local hum = z:FindFirstChildOfClass("Humanoid")
        local part = z:FindFirstChild("Head") or z:FindFirstChild("HumanoidRootPart")
        if hum and hum.Health > 0 and part and lbl then
            local sp = Camera:WorldToViewportPoint(part.Position)
            local dist = (part.Position - Camera.CFrame.Position).Magnitude
            if sp.X > -200 and sp.X < Camera.ViewportSize.X + 200 then
                local name = displayName(z)
                lbl.Text = string.format("%s %dm %d HP", name, math.floor(dist / 3.5), math.floor(hum.Health))
                lbl.Position = UDim2.new(0, sp.X - 60, 0, sp.Y - 30)
                lbl.Visible = true
            else
                lbl.Visible = false
            end
        elseif lbl then
            lbl.Visible = false
        end
    end
end)


-- ============================================================
-- 自动挣脱红眼 (精确版)
--
-- 逆向自 EscapeMinigame.attempt() (line 708):
--   判定: u85 - u96/2 - 0.015 <= u95 <= u85 + u96/2 + 0.015
--     u95 = 指针位置 (Indicator.Position.X.Scale)
--     u85 = 判定区位置 (TargetZone.Position.X.Scale)
--     u96 = 判定区宽度 (TargetZone.Size.X.Scale)
--   ★ 只在指针落入判定区时才点 → 100% 命中, 4 次后游戏自己 win()
--   惩罚: 0.3s 内点 5 次 → 冷却 0.45s; 每次成功 0.12s 冷却
-- ============================================================
SilentAim.AutoEscapeEnabled = false
SilentAim.EscapeHits = 0
SilentAim.EscapeLastClick = 0

local _escapeMod = nil
local function getEscapeMod()
    if _escapeMod then return _escapeMod end
    local ok, m = pcall(function()
        local RS = game:GetService("ReplicatedStorage")
        local mods = RS:FindFirstChild("Modules")
        local cl = mods and mods:FindFirstChild("Client")
        local ui = cl and cl:FindFirstChild("UI")
        local em = ui and ui:FindFirstChild("EscapeMinigame")
        if not em then return nil end
        return require(em)
    end)
    if ok and type(m) == "table" then
        _escapeMod = m
        return m
    end
    return nil
end

local function getEscapeGui()
    local pg = LP:FindFirstChild("PlayerGui")
    return pg and pg:FindFirstChild("EscapeMinigame")
end

local function isTackled()
    local char = LP.Character
    if not char then return false end
    if char:GetAttribute("isTackled") == true then return true end
    if char:GetAttribute("isGrabbed") == true then return true end
    local gui = getEscapeGui()
    return gui ~= nil and gui.Enabled == true
end

local function readZone()
    local gui = getEscapeGui()
    if not gui then return nil end
    local cont = gui:FindFirstChild("Container")
    local bar = cont and cont:FindFirstChild("BarBackground")
    if not bar then return nil end
    local tz = bar:FindFirstChild("TargetZone")
    local ind = bar:FindFirstChild("Indicator")
    if not (tz and ind) then return nil end
    return { indPos = ind.Position.X.Scale, zonePos = tz.Position.X.Scale, zoneW = tz.Size.X.Scale }
end

local function inZone(z)
    if not z then return false end
    local half = z.zoneW / 2
    local tol = 0.015
    return z.indPos >= (z.zonePos - half - tol) and z.indPos <= (z.zonePos + half + tol)
end

task.spawn(function()
    while true do
        task.wait(0.02)
        if SilentAim.AutoEscapeEnabled and isTackled() then
            local now = os.clock()
            local z = readZone()
            if z and inZone(z) then
                if (now - SilentAim.EscapeLastClick) > 0.14 then
                    local m = getEscapeMod()
                    if m and type(m.attempt) == "function" then
                        pcall(function() m.attempt() end)
                        SilentAim.EscapeLastClick = now
                        SilentAim.EscapeHits = SilentAim.EscapeHits + 1
                    end
                end
            end
        else
            if not isTackled() then
                SilentAim.EscapeHits = 0
            end
        end
    end
end)

-- ============================================================
-- 僵尸数量 HUD (右上角)
-- ============================================================
SilentAim.HUDEnabled = false

local hudGui = Instance.new("ScreenGui")
hudGui.Name = "SilentAimHUD"
hudGui.ResetOnSpawn = false
hudGui.IgnoreGuiInset = true
hudGui.DisplayOrder = 995
hudGui.Parent = (getgenv and getgenv().gethui and getgenv().gethui()) or LP:WaitForChild("PlayerGui")

local hudFrame = Instance.new("Frame")
hudFrame.Size = UDim2.new(0, 190, 0, 0)
hudFrame.Position = UDim2.new(1, -200, 0, 80)
hudFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
hudFrame.BackgroundTransparency = 0.25
hudFrame.BorderSizePixel = 0
hudFrame.Visible = false
hudFrame.Parent = hudGui
Instance.new("UICorner", hudFrame).CornerRadius = UDim.new(0, 8)

local hudTitle = Instance.new("TextLabel")
hudTitle.Size = UDim2.new(1, -10, 0, 20)
hudTitle.Position = UDim2.new(0, 5, 0, 4)
hudTitle.BackgroundTransparency = 1
hudTitle.Text = "僵尸统计"
hudTitle.TextColor3 = Color3.fromRGB(255, 200, 200)
hudTitle.Font = Enum.Font.GothamBold
hudTitle.TextSize = 13
hudTitle.TextXAlignment = Enum.TextXAlignment.Left
hudTitle.Parent = hudFrame

local hudList = Instance.new("Frame")
hudList.Size = UDim2.new(1, -10, 0, 0)
hudList.Position = UDim2.new(0, 5, 0, 26)
hudList.BackgroundTransparency = 1
hudList.Parent = hudFrame
local hudLayout = Instance.new("UIListLayout")
hudLayout.Padding = UDim.new(0, 2)
hudLayout.Parent = hudList

local HUD_NAMES = {
    Shambler = "普通", Runner = "红眼", Spitter = "喷吐者", Bomber = "自爆兵",
    Brute = "巨兽", Crawler = "爬行者", Engineer = "工兵", Igniter = "焚火者",
    Cavalry = "骑兵", Warden = "典狱长",
}

local hudRows = {}
local function updateHUD()
    if not SilentAim.HUDEnabled then
        hudFrame.Visible = false
        return
    end
    local counts, total = {}, 0
    for _, z in ipairs(getZombies()) do
        local h = z:FindFirstChildOfClass("Humanoid")
        if h and h.Health > 0 then
            local t = z:GetAttribute("Type") or z.Name
            counts[t] = (counts[t] or 0) + 1
            total = total + 1
        end
    end
    local rows = {}
    for k, v in pairs(counts) do
        table.insert(rows, { name = HUD_NAMES[k] or k, count = v, key = k })
    end
    table.sort(rows, function(a, b) return a.count > b.count end)
    hudTitle.Text = string.format("僵尸统计 (共 %d)", total)
    for i = 1, math.min(#rows, 10) do
        local r = rows[i]
        local row = hudRows[i]
        if not row then
            row = Instance.new("TextLabel")
            row.Size = UDim2.new(1, 0, 0, 16)
            row.BackgroundTransparency = 1
            row.Font = Enum.Font.Gotham
            row.TextSize = 12
            row.TextXAlignment = Enum.TextXAlignment.Left
            row.Parent = hudList
            hudRows[i] = row
        end
        row.Text = string.format("  %s  x%d", r.name, r.count)
        row.TextColor3 = (r.key == "Shambler") and Color3.fromRGB(170,170,170) or Color3.fromRGB(255,120,120)
        row.Visible = true
    end
    for i = #rows + 1, #hudRows do hudRows[i].Visible = false end
    hudFrame.Size = UDim2.new(0, 190, 0, 30 + math.min(#rows, 10) * 18 + 6)
    hudFrame.Visible = true
end

task.spawn(function()
    while true do
        task.wait(0.3)
        pcall(updateHUD)
    end
end)

-- ============================================================
-- 夜视增亮 (Night Vision)
--   游戏 Lighting 默认: Ambient 0.118/0.098/0.078, ClockTime 16.5
--   夜间/黄昏视野极差 → 提亮环境光
--   保存原始值, 关闭时精确还原
-- ============================================================
SilentAim.NightVisionEnabled = false
local _origLighting = nil

local function saveLighting()
    if _origLighting then return end
    local L = game:GetService("Lighting")
    _origLighting = {
        Ambient = L.Ambient,
        OutdoorAmbient = L.OutdoorAmbient,
        Brightness = L.Brightness,
        EnvironmentDiffuseScale = L.EnvironmentDiffuseScale,
        EnvironmentSpecularScale = L.EnvironmentSpecularScale,
        ExposureCompensation = L.ExposureCompensation,
    }
end

local function applyNightVision(on)
    local L = game:GetService("Lighting")
    if on then
        saveLighting()
        L.Ambient = Color3.fromRGB(150, 145, 135)
        L.OutdoorAmbient = Color3.fromRGB(160, 160, 165)
        L.Brightness = 5
        L.EnvironmentDiffuseScale = 1
        L.EnvironmentSpecularScale = 1
        L.ExposureCompensation = 0.5
    elseif _origLighting then
        L.Ambient = _origLighting.Ambient
        L.OutdoorAmbient = _origLighting.OutdoorAmbient
        L.Brightness = _origLighting.Brightness
        L.EnvironmentDiffuseScale = _origLighting.EnvironmentDiffuseScale
        L.EnvironmentSpecularScale = _origLighting.EnvironmentSpecularScale
        L.ExposureCompensation = _origLighting.ExposureCompensation
        _origLighting = nil
    end
end

-- ============================================================
-- 去雾 / 去雨
--   游戏 Atmosphere: Density 0.45, Haze 3.5 (浓雾)
--   Lighting: FogEnd 900, FogStart 120
-- ============================================================
SilentAim.NoFogEnabled = false
local _origAtmos = nil

local function saveAtmosphere()
    if _origAtmos then return end
    local L = game:GetService("Lighting")
    local atmos = L:FindFirstChildOfClass("Atmosphere")
    _origAtmos = {
        fogEnd = L.FogEnd,
        fogStart = L.FogStart,
        atmos = atmos,
        density = atmos and atmos.Density,
        haze = atmos and atmos.Haze,
        glare = atmos and atmos.Glare,
    }
end

local function applyNoFog(on)
    local L = game:GetService("Lighting")
    if on then
        saveAtmosphere()
        L.FogEnd = 100000
        L.FogStart = 100000
        local atmos = L:FindFirstChildOfClass("Atmosphere")
        if atmos then
            atmos.Density = 0
            atmos.Haze = 0
            atmos.Glare = 0
        end
    elseif _origAtmos then
        L.FogEnd = _origAtmos.fogEnd
        L.FogStart = _origAtmos.fogStart
        local atmos = L:FindFirstChildOfClass("Atmosphere")
        if atmos and _origAtmos.density then
            atmos.Density = _origAtmos.density
            atmos.Haze = _origAtmos.haze
            atmos.Glare = _origAtmos.glare
        end
        _origAtmos = nil
    end
end

task.spawn(function()
    local lastNV, lastNF = nil, nil
    while true do
        task.wait(0.2)
        if SilentAim.NightVisionEnabled ~= lastNV then
            pcall(applyNightVision, SilentAim.NightVisionEnabled)
            lastNV = SilentAim.NightVisionEnabled
        end
        if SilentAim.NoFogEnabled ~= lastNF then
            pcall(applyNoFog, SilentAim.NoFogEnabled)
            lastNF = SilentAim.NoFogEnabled
        end
    end
end)

-- ============================================================
-- 数据统计
--   本局击杀 / 爆头 / 伤害 / 存活时间
--   数据来源: 监听伤害事件 + 僵尸死亡
-- ============================================================
SilentAim.StatsEnabled = false
SilentAim.StatKills = 0
SilentAim.StatHeadshots = 0
SilentAim.StatDamage = 0
SilentAim.StatShots = 0
SilentAim.StatHits = 0
SilentAim.StatStartTime = os.clock()

local _knownZombies = {}

-- 监控僵尸死亡 → 统计击杀
task.spawn(function()
    while true do
        task.wait(0.5)
        if SilentAim.StatsEnabled then
            local zombies = getZombies()
            local alive = {}
            for _, z in ipairs(zombies) do
                alive[z] = true
                local h = z:FindFirstChildOfClass("Humanoid")
                if h then
                    local k = tostring(z)
                    _knownZombies[k] = _knownZombies[k] or { hp = h.Health }
                    _knownZombies[k].hp = h.Health
                end
            end
            for k, v in pairs(_knownZombies) do
                if not alive[k] and v.hp > 0 then
                    -- 消失了, 记为击杀
                    SilentAim.StatKills = SilentAim.StatKills + 1
                    _knownZombies[k] = nil
                end
            end
        end
    end
end)

-- 统计 HUD
local statGui = Instance.new("ScreenGui")
statGui.Name = "SilentAimStats"
statGui.ResetOnSpawn = false
statGui.IgnoreGuiInset = true
statGui.DisplayOrder = 994
statGui.Parent = (getgenv and getgenv().gethui and getgenv().gethui()) or LP:WaitForChild("PlayerGui")

local statFrame = Instance.new("Frame")
statFrame.Size = UDim2.new(0, 200, 0, 0)
statFrame.Position = UDim2.new(0, 10, 0, 400)
statFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 20)
statFrame.BackgroundTransparency = 0.25
statFrame.BorderSizePixel = 0
statFrame.Visible = false
statFrame.Parent = statGui
Instance.new("UICorner", statFrame).CornerRadius = UDim.new(0, 8)

local statTitle = Instance.new("TextLabel")
statTitle.Size = UDim2.new(1, -10, 0, 20)
statTitle.Position = UDim2.new(0, 5, 0, 4)
statTitle.BackgroundTransparency = 1
statTitle.Text = "本局数据"
statTitle.TextColor3 = Color3.fromRGB(180, 220, 255)
statTitle.Font = Enum.Font.GothamBold
statTitle.TextSize = 13
statTitle.TextXAlignment = Enum.TextXAlignment.Left
statTitle.Parent = statFrame

local statList = Instance.new("Frame")
statList.Size = UDim2.new(1, -10, 0, 0)
statList.Position = UDim2.new(0, 5, 0, 26)
statList.BackgroundTransparency = 1
statList.Parent = statFrame
local statLayout = Instance.new("UIListLayout")
statLayout.Padding = UDim.new(0, 2)
statLayout.Parent = statList

local STAT_ROWS = {
    { key = "StatKills",     label = "击杀数" },
    { key = "StatHeadshots", label = "爆头数" },
    { key = "StatDamage",    label = "总伤害" },
    { key = "StatShots",     label = "射击次数" },
    { key = "StatHits",      label = "命中次数" },
}

local statRowWidgets = {}
for i, r in ipairs(STAT_ROWS) do
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 16)
    lbl.BackgroundTransparency = 1
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 12
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextColor3 = Color3.fromRGB(200, 220, 240)
    lbl.Parent = statList
    statRowWidgets[i] = lbl
end

local timeRow = Instance.new("TextLabel")
timeRow.Size = UDim2.new(1, 0, 0, 16)
timeRow.BackgroundTransparency = 1
timeRow.Font = Enum.Font.Gotham
timeRow.TextSize = 12
timeRow.TextXAlignment = Enum.TextXAlignment.Left
timeRow.TextColor3 = Color3.fromRGB(200, 220, 240)
timeRow.Parent = statList

task.spawn(function()
    while true do
        task.wait(1)
        if SilentAim.StatsEnabled then
            local elapsed = os.clock() - SilentAim.StatStartTime
            local mm = math.floor(elapsed / 60)
            local ss = math.floor(elapsed % 60)
            for i, r in ipairs(STAT_ROWS) do
                local val = SilentAim[r.key] or 0
                local extra = ""
                if r.key == "StatHits" and SilentAim.StatShots > 0 then
                    extra = string.format(" (%.0f%%)", SilentAim.StatHits / SilentAim.StatShots * 100)
                end
                statRowWidgets[i].Text = string.format("  %s: %d%s", r.label, val, extra)
            end
            timeRow.Text = string.format("  存活: %02d:%02d", mm, ss)
            statFrame.Size = UDim2.new(0, 200, 0, 30 + (#STAT_ROWS + 1) * 18 + 6)
            statFrame.Visible = true
        else
            statFrame.Visible = false
        end
    end
end)

-- 重置统计
getgenv().SA_ResetStats = function()
    SilentAim.StatKills = 0
    SilentAim.StatHeadshots = 0
    SilentAim.StatDamage = 0
    SilentAim.StatShots = 0
    SilentAim.StatHits = 0
    SilentAim.StatStartTime = os.clock()
end


-- ============================================================
-- FOV 圈 + 目标指示器
-- ============================================================
local overlay = Instance.new("ScreenGui")
overlay.Name = "SilentAimOverlay"
overlay.ResetOnSpawn = false
overlay.IgnoreGuiInset = true
overlay.DisplayOrder = 998
overlay.Parent = (getgenv and getgenv().gethui and getgenv().gethui()) or LP:WaitForChild("PlayerGui")

-- FOV 圈
local fovCircle = Instance.new("Frame")
fovCircle.BackgroundTransparency = 1
fovCircle.BorderSizePixel = 0
fovCircle.Visible = false
fovCircle.Parent = overlay
local fovStroke = Instance.new("UIStroke")
fovStroke.Thickness = 1.5
fovStroke.Color = Color3.fromRGB(0, 255, 190)
fovStroke.Transparency = 0.45
fovStroke.Parent = fovCircle
Instance.new("UICorner", fovCircle).CornerRadius = UDim.new(1, 0)

-- 中心准星
local cross = Instance.new("Frame")
cross.Size = UDim2.new(0, 3, 0, 3)
cross.Position = UDim2.new(0.5, -1.5, 0.5, -1.5)
cross.BackgroundColor3 = Color3.fromRGB(0, 255, 190)
cross.BackgroundTransparency = 0.2
cross.BorderSizePixel = 0
cross.Parent = overlay
Instance.new("UICorner", cross).CornerRadius = UDim.new(1, 0)

-- 目标指示圈
local ind = Instance.new("Frame")
ind.BackgroundTransparency = 1
ind.Size = UDim2.new(0, 30, 0, 30)
ind.Visible = false
ind.Parent = overlay
local indStroke = Instance.new("UIStroke")
indStroke.Thickness = 2
indStroke.Color = Color3.fromRGB(255, 45, 45)
indStroke.Parent = ind
Instance.new("UICorner", ind).CornerRadius = UDim.new(1, 0)

local indDot = Instance.new("Frame")
indDot.Size = UDim2.new(0, 3, 0, 3)
indDot.Position = UDim2.new(0.5, -1.5, 0.5, -1.5)
indDot.BackgroundColor3 = Color3.fromRGB(255, 45, 45)
indDot.BorderSizePixel = 0
indDot.Parent = ind
Instance.new("UICorner", indDot).CornerRadius = UDim.new(1, 0)

local indLabel = Instance.new("TextLabel")
indLabel.BackgroundTransparency = 1
indLabel.Size = UDim2.new(1, 40, 0, 14)
indLabel.Position = UDim2.new(0.5, -20, 1, 2)
indLabel.Font = Enum.Font.GothamBold
indLabel.TextSize = 11
indLabel.TextColor3 = Color3.fromRGB(255, 45, 45)
indLabel.TextStrokeTransparency = 0.3
indLabel.Text = ""
indLabel.Parent = ind

local function updateOverlay()
    local on = SilentAim.Enabled
    fovCircle.Visible = on and (SilentAim.ShowFOV ~= false)
    cross.Visible = on
    if not on then
        ind.Visible = false
        return
    end

    -- FOV 圈尺寸
    local size = SilentAim.FOV * 2
    fovCircle.Size = UDim2.new(0, size, 0, size)
    fovCircle.Position = UDim2.new(0.5, -SilentAim.FOV, 0.5, -SilentAim.FOV)

    if SilentAim.ShowIndicator == false then
        ind.Visible = false
        return
    end

    local z = SilentAim.cachedTarget or pickTarget()
    if not z then
        ind.Visible = false
        return
    end
    local part = z:FindFirstChild("Head") or z:FindFirstChild("HumanoidRootPart")
    if not part then
        ind.Visible = false
        return
    end
    local sp = Camera:WorldToViewportPoint(part.Position)
    if sp.X < -200 or sp.X > Camera.ViewportSize.X + 200 then
        ind.Visible = false
        return
    end
    local wd = (part.Position - Camera.CFrame.Position).Magnitude
    local dia = math.clamp(4000 / math.max(wd, 10), 16, 70)
    ind.Size = UDim2.new(0, dia, 0, dia)
    ind.Position = UDim2.new(0, sp.X - dia / 2, 0, sp.Y - dia / 2)
    indLabel.Text = string.format("%d m", math.floor(wd / 3.5))
    ind.Visible = true
end

task.spawn(function()
    while true do
        task.wait(0.05)
        pcall(updateOverlay)
    end
end)


-- 导出
-- ============================================================
getgenv().SilentAim = SilentAim
getgenv().SilentAimUpdateOverlay = updateOverlay
getgenv().SilentAimPickTarget = pickTarget
getgenv().SilentAimOverlay = overlay
getgenv().SilentAimGetZombies = getZombies

print("[SilentAim] 核心 v2 已加载 (Shoot 方向改写)")


local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local camera = workspace.CurrentCamera
local lp = Players.LocalPlayer
local loadStartTime = tick()

local COPY_UID_TEXT = "UID:3493104875211423"
local GUI_NAME = "HLlinfeng"

local I18N = {
    en = {
        ForceResetChar = "Force Reset Character",
        Advanced = "Advanced Features",
        LockGui = "Lock GUI",
        ResetUIPos = "Reset UI Position",
        HideUI = "Hide UI (Long Press to Open)",
        SpeedValue = "Speed Value",
        PlayerESP = "Player ESP",
        BarrelESP = "Barrel ESP",
        RedEyeESP = "Red Eye ESP",
        EngineerZombieESP = "Engineer Zombie ESP",
        FireZombieESP = "Igniter Zombie ESP",
        CavalryZombieESP = "Cavalry Zombie ESP",
        HalloweenESP = "Halloween Event ESP",
        TrajectoryESP = "Bullet Trajectory Display",
        AlwaysHeadshot = "Always Headshot",
        HeadshotAssist = "Headshot Assist",
        BlockBarrel = "Block Hit Barrel",
        AutoPlay = "Auto Play",
        NoBlood = "No Blood Splatter",
        AntiGrab = "Anti Grab",
        SimpleAI = "Simplify Zombie AI",
        AlwaysShowInv = "Always Show Inventory",
        FixFireBtn = "Fix Fire Button Display",
        ModifySpeed = "Modify Speed",
        HighlightScreen = "Highlight Screen",
        HealMove = "Move While Healing",
        NoFall = "No Fall Damage",
        CannonLine = "Cannon Aim Line",
        AttackFriend = "Allow Attack Friends",
        AutoRepair = "Auto Repair Buildings",
        AutoWood = "Auto Place Wood",
        FixFireLag = "Fix Igniter Fire Lag",
        SimpleESP = "Simplify ESP Display",
        TestZombie = "Test Map Summon Zombie",
        TempUnlock = "Temp Unlock Achievement",
        AutoLoot = "Auto Pickup Loot",
        Spectator = "Spectator Mode",
        FastReload = "Rifle Fast Reload",
        HandCannonPred = "Hand Cannon Prediction",
        BreakDoor = "Break Doors and Windows",
        HorizontalFix = "Horizontal View Correction",
        ShowAimPoint = "Show Aim Point",
        Accuracy = "Increase Accuracy",
        TeamCheck = "Team Check",
        WallCheck = "Wall Check",
        ShowFOV = "FOV Crosshair",
        Copied = "Copied",
    },
    cn = {
        ForceResetChar = "强制重置人物",
        Advanced = "高级功能",
        LockGui = "锁定Gui",
        ResetUIPos = "重置界面位置",
        HideUI = "隐藏界面(长按打开)",
        SpeedValue = "速度值",
        PlayerESP = "玩家透视",
        BarrelESP = "炸药桶透视",
        RedEyeESP = "红眼透视",
        EngineerZombieESP = "工兵僵尸透视",
        FireZombieESP = "焚火者透视",
        CavalryZombieESP = "骑兵僵尸透视",
        HalloweenESP = "万圣节活动透视",
        TrajectoryESP = "弹道轨迹显示",
        AlwaysHeadshot = "始终爆头",
        HeadshotAssist = "爆头辅助",
        BlockBarrel = "阻止击中炸药桶",
        AutoPlay = "自动演奏",
        NoBlood = "近战没有血液溅射",
        AntiGrab = "防抓取",
        SimpleAI = "简化僵尸 AI",
        AlwaysShowInv = "始终显示物品栏",
        FixFireBtn = "修复开火键显示",
        ModifySpeed = "修改速度",
        HighlightScreen = "高亮画面",
        HealMove = "治疗时可移动",
        NoFall = "无摔落伤害",
        CannonLine = "大炮瞄准线",
        AttackFriend = "允许攻击好友",
        AutoRepair = "自动修复建筑",
        AutoWood = "自动放置木头",
        FixFireLag = "修复焚火者火焰卡顿",
        SimpleESP = "简化透视显示",
        TestZombie = "测试地图召唤僵尸",
        TempUnlock = "临时解锁成就军团",
        AutoLoot = "自动拾取战利品",
        Spectator = "旁观模式",
        FastReload = "来福枪快速换弹",
        HandCannonPred = "手炮弹道预测",
        BreakDoor = "破坏门和窗",
        HorizontalFix = "水平视角矫正",
        ShowAimPoint = "显示瞄准点",
        Accuracy = "提高精准度",
        TeamCheck = "队伍检测",
        WallCheck = "墙体检测",
        ShowFOV = "FOV准星",
        Copied = "复制成功",
    }
}

local currentLang = "en"

local function T(key)
    local lang = I18N[currentLang]
    return (lang and lang[key]) or key
end

local function applyI18N(el, key)
    if not el or not key then return end
    el:SetAttribute("I18NKey", key)
    el.Text = T(key)
end

local S = {
    DeviceType = (function()
        local sc = camera.ViewportSize
        local a = sc.X / sc.Y
        return (a >= 1.3 and sc.X >= 900) and "Desktop" or ((a < 1.3 and sc.X >= 600) and "Tablet" or "Mobile")
    end)(),
    Features = {
        espPlayer = false, espBarrel = false, espRedEye = false, espEngineer = false,
        espFire = false, espCavalry = false, espHalloween = false, espTrajectory = false,
        alwaysHeadshot = false, headshotAssist = false, blockBarrel = false, autoPlay = false,
        noBlood = false, antiGrabCombat = false, simpleAI = false, killAura = false,
        alwaysShowInv = false, fixFireBtn = false, modifySpeed = false, highlightScreen = false,
        healMove = false, noFall = false, cannonLine = false, attackFriend = false,
        autoRepair = false, autoWood = false, fixFireLag = false, simpleESP = false,
        testZombie = false, tempUnlock = false, autoLoot = false, spectator = false,
        pvpAim = false, showAimPoint = false, accuracy = false, fastReload = false,
        handCannonPred = false, breakDoor = false, horizontalFix = false,
        refreshList = false, userIdOrName = false, inGame = false,
        resetChar = false, advanced = false, speedVal = 16,
        blackGun = false, smartMode = false, enhancedJudgment = false, backpackFire = false,
        autoReload = false, heightCheck = true,
        meleePVE = false, meleeSkipExplosive = true, meleeHeadshot = false, meleeSkipSpawn = true,
        killAnim = false, autoElbow = false, meleePVP = false, meleePVPHeadshot = false,
        bayonet = false, bayonetPVP = false,
        pvpShoot = false, bulletTrack = false, pvpRage = false, pvpAutoShoot = true, pvpShowBeam = true,
        rageBot = false,
        autoJump = false, infiniteJump = false, flyThunder = false, flyMode = false, noSlow = false,
        showFOV = true, wallCheck = true, teamCheck = true,
        fogRemove = false, infectionRemove = false,
        espAxe = false, espEye = false, espSword = false, espBarrelType = false, espFTorso = false,
        espHeadlessKnight = false, espDracula = false, espPlayerPVP = false, espBarrelShow = false,
        fallProtect = false, antiGrabProtect = false, invis = false,
        autoRepairBuilding = false,
        horseDance = false, zapperAnim = false,
        lockGui = false,
    },
    UI = {ScreenGui = nil, Main = nil, MinFrame = nil, Panels = {}, PanelOrigins = {}, PanelsVisible = true, SettingPanels = {}},
    Running = false, LoopThread = nil, Modules = {},
}

local CFG = ({
    Mobile = { MainW=60, MainH=156, SubW=60, BtnH=22, TitleH=34, MinSize=32, Font={Main=10,Sub=11,Title=12,Min=18}, Space=6, Scale=1.0 },
    Tablet = { MainW=85, MainH=200, SubW=85, BtnH=30, TitleH=40, MinSize=40, Font={Main=12,Sub=13,Title=14,Min=20}, Space=7, Scale=1.3 },
    Desktop = { MainW=110, MainH=260, SubW=110, BtnH=36, TitleH=48, MinSize=48, Font={Main=14,Sub=15,Title=16,Min=24}, Space=10, Scale=1.7 }
})[S.DeviceType]

local TITLE_CORNER = UDim.new(0, 8)
local MAIN_BOTTOM_CORNER = UDim.new(0, 8)
local INNER_TOP_PAD = math.max(1, math.floor(2 * CFG.Scale))
local INNER_BOTTOM_PAD = math.max(2, math.floor(5 * CFG.Scale))
local CLOSE_BTN_CORNER = math.max(8, math.floor(6 * CFG.Scale))
local ITEM_GAP = math.floor(4 * CFG.Scale)
local BOTTOM_CORNER_PX = 8
local BLACK_EXTRA_H = math.max(1, math.floor(2 * CFG.Scale))

local COPY_FEEDBACK_TIME = 0.8
local LANG_TEXT = Color3.fromRGB(255, 60, 60)
local LANG_TEXT_HOVER = Color3.fromRGB(255, 110, 110)

local function cornerToPx(frame, corner)
    local minDim = math.min(frame.AbsoluteSize.X, frame.AbsoluteSize.Y)
    if minDim <= 0 then
        minDim = math.max(frame.Size.X.Offset, frame.Size.Y.Offset)
    end
    return math.max(1, math.floor(minDim * corner.Scale + corner.Offset + 0.5))
end

local function safe(ctx, fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, r = pcall(fn, ...)
    if not ok then warn(string.format("[MYQFUI-ERROR] %s | %s", ctx, tostring(r))) end
    return ok, r
end

function RegModule(name, mod)
    S.Modules[name] = mod
end

local function startLoop()
    if S.Running then return end
    S.Running = true
    S.LoopThread = task.spawn(function()
        while S.Running do
            task.wait(0.05)
            for n, m in pairs(S.Modules) do
                local f = S.Features[n]
                if f == true and m.Loop then
                    safe(n .. ".Loop", m.Loop)
                elseif type(f) == "table" and f.Enabled and m.Loop then
                    safe(n .. ".Loop", m.Loop)
                end
            end
        end
    end)
end

local function stopAll()
    S.Running = false
    if S.LoopThread then task.cancel(S.LoopThread) end
    for n, m in pairs(S.Modules) do if m.Stop then safe(n .. ".Stop", m.Stop) end end
end

local SUB = {
    Title    = Color3.fromRGB(55, 55, 60),
    Body     = Color3.fromRGB(15, 15, 20),
    Content  = Color3.fromRGB(15, 15, 20),
    Btn      = Color3.fromRGB(35, 35, 40),
    BtnHover = Color3.fromRGB(45, 45, 50),
    Green    = Color3.fromRGB(0, 255, 0),
    Red      = Color3.fromRGB(255, 0, 0),
    White    = Color3.fromRGB(255, 255, 255),
    Stroke   = Color3.fromRGB(0, 0, 0),
    Black    = Color3.fromRGB(0, 0, 0),
}

local C = {
    Title = SUB.Title, Panel = SUB.Body, Content = SUB.Content,
    Btn = SUB.Btn, BtnHover = SUB.BtnHover, MainPanel = SUB.Body,
    MinFrame = Color3.fromRGB(72,72,78), White = SUB.White,
    Red = SUB.Red, Green = SUB.Green,
    Stroke = SUB.Stroke,
    SliderBg = SUB.Btn, SliderFill = SUB.BtnHover, SliderKnob = SUB.White,
}

local MYQ = {
    Btn   = SUB.Btn,
    Hover = SUB.BtnHover,
    Press = Color3.fromRGB(25, 25, 30),
    KnobImage = "rbxassetid://6755657357",
}

local function detectArceusXContainer()
    local ok, found = pcall(function()
        local children = CoreGui:GetChildren()
        for _, v in pairs(children) do
            if v:IsA("ScreenGui") then
                if v.ClipToDeviceSafeArea == true and v.DisplayOrder == 0
                   and v.Enabled == true
                   and v.ResetOnSpawn == true
                   and v.AutoLocalize == true then
                    local subChildren = v:GetChildren()
                    if #subChildren == 1 then
                        return v
                    end
                end
            end
        end
        return nil
    end)
    if ok and found then return found end
    return nil
end

local function getExecutorContainer()
    local arceus = detectArceusXContainer()
    if arceus then return arceus end

    if type(gethui) == "function" then
        local ok, res = pcall(gethui)
        if ok and res then return res end
    end
    if type(get_hidden_gui) == "function" then
        local ok, res = pcall(get_hidden_gui)
        if ok and res then return res end
    end
    if type(getgenv) == "function" then
        local ok, genv = pcall(getgenv)
        if ok and genv then
            if type(genv.gethui) == "function" then
                local ok2, res = pcall(genv.gethui)
                if ok2 and res then return res end
            end
            if type(genv.get_hidden_gui) == "function" then
                local ok2, res = pcall(genv.get_hidden_gui)
                if ok2 and res then return res end
            end
        end
    end
    return CoreGui
end

local targetParent = getExecutorContainer()

if targetParent:FindFirstChild(GUI_NAME) then
    targetParent:FindFirstChild(GUI_NAME):Destroy()
end

local Nanoka = Instance.new("ScreenGui")
Nanoka.Name = GUI_NAME
Nanoka.Parent = targetParent
Nanoka.ResetOnSpawn = false
Nanoka.IgnoreGuiInset = true
Nanoka.DisplayOrder = 1000
Nanoka.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
Nanoka.Enabled = false
S.UI.ScreenGui = Nanoka

local container = Instance.new("Frame")
container.Name = "Frame"
container.Parent = Nanoka
container.Size = UDim2.new(1, 0, 1, 0)
container.Position = UDim2.new(0, 0, 0, 0)
container.BackgroundTransparency = 1
container.BorderSizePixel = 0
container.Active = false
container.ClipsDescendants = false
container.ZIndex = 0

local minF
local pvpAimSettingPanel

local function switchLanguage()
    currentLang = (currentLang == "en") and "cn" or "en"
    for _, d in ipairs(Nanoka:GetDescendants()) do
        local k = d:GetAttribute("I18NKey")
        if k and (d:IsA("TextLabel") or d:IsA("TextButton")) then
            local val = d:GetAttribute("I18NValue")
            if val ~= nil then
                d.Text = T(k) .. " [" .. tostring(val) .. "]"
            else
                d.Text = T(k)
            end
        end
    end
end

UserInputService.InputBegan:Connect(function(i, g) if g then return end if i.KeyCode == Enum.KeyCode.P then Nanoka.Enabled = not Nanoka.Enabled end end)

local function styleButton(btn, text, col)
    btn.Size = UDim2.new(1, 0, 0, CFG.BtnH); btn.BackgroundColor3 = SUB.Btn; btn.Text = text
    btn.TextColor3 = col or SUB.White; btn.Font = Enum.Font.Gotham; btn.TextSize = CFG.Font.Sub
    btn.TextWrapped = true; btn.TextScaled = true; btn.AutoButtonColor = false
    btn.TextXAlignment = Enum.TextXAlignment.Center; btn.TextYAlignment = Enum.TextYAlignment.Center
    btn.TextStrokeColor3 = SUB.Stroke; btn.TextStrokeTransparency = 0.2; btn.Active = true
    btn.BorderSizePixel = 0
end

local function CreateButton(text, parent, onClick, palette)
    palette = palette or SUB
    local b = Instance.new("TextButton"); b.Parent = parent
    styleButton(b, "")
    applyI18N(b, text)
    b.BackgroundColor3 = palette.Btn
    b.MouseEnter:Connect(function() b.BackgroundColor3 = palette.BtnHover end)
    b.MouseLeave:Connect(function() b.BackgroundColor3 = palette.Btn end)
    if onClick then b.MouseButton1Click:Connect(function() safe("Btn."..text, onClick) end) end
    return b
end

-- ★ 所有 toggle 的同步器 (供配置加载时刷新按钮颜色)
getgenv().SA_ToggleSync = getgenv().SA_ToggleSync or {}

local function CreateToggle(text, parent, featureKey, callback, palette)
    palette = palette or SUB
    local on = S.Features[featureKey] or false
    local b = CreateButton(text, parent, nil, palette)
    b.TextColor3 = on and palette.Green or palette.Red
    b.MouseLeave:Connect(function() b.BackgroundColor3 = palette.Btn; b.TextColor3 = on and palette.Green or palette.Red end)
    b.MouseButton1Click:Connect(function()
        on = not on; S.Features[featureKey] = on
        b.TextColor3 = on and palette.Green or palette.Red
        if callback then safe("Toggle."..featureKey, callback, on) end
    end)
    -- ★ 注册刷新器: 外部改状态后可同步按钮显示
    getgenv().SA_ToggleSync[featureKey] = {
        refresh = function(newVal)
            on = not not newVal
            b.TextColor3 = on and palette.Green or palette.Red
        end,
        get = function() return on end,
    }
    return b
end

local function createLangSwitchButton(parent, onAfterHide)
    local b = Instance.new("TextButton")
    b.Parent = parent
    b.Size = UDim2.new(1, 0, 0, CFG.BtnH)
    b.BackgroundColor3 = SUB.Btn
    b.BorderSizePixel = 0
    b.Text = "语言切换\n到中文"
    b.TextColor3 = LANG_TEXT
    b.Font = Enum.Font.Gotham
    b.TextSize = CFG.Font.Sub
    b.TextWrapped = true
    b.TextScaled = true
    b.AutoButtonColor = false
    b.TextXAlignment = Enum.TextXAlignment.Center
    b.TextYAlignment = Enum.TextYAlignment.Center
    b.TextStrokeColor3 = SUB.Stroke
    b.TextStrokeTransparency = 0.2
    b.Active = true

    b.MouseEnter:Connect(function()
        b.BackgroundColor3 = SUB.BtnHover
        b.TextColor3 = LANG_TEXT_HOVER
    end)
    b.MouseLeave:Connect(function()
        b.BackgroundColor3 = SUB.Btn
        b.TextColor3 = LANG_TEXT
    end)

    b.MouseButton1Click:Connect(function()
        b.Visible = false
        if onAfterHide then safe("LangRecalc", onAfterHide) end
        safe("SwitchLanguage", switchLanguage)
    end)
    return b
end

local function createMYQButton(text, parent, onClick, radiusPx, maskTop)
    radiusPx = radiusPx or 5
    local b = Instance.new("TextButton")
    b.Parent = parent
    b.Size = UDim2.new(1, 0, 0, CFG.BtnH)
    b.BackgroundColor3 = MYQ.Btn
    b.BorderSizePixel = 0
    b.Text = ""
    b.AutoButtonColor = false
    b.Active = true
    b.ZIndex = 5
    if radiusPx > 0 then
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, radiusPx)
    end

    local topMask = nil
    if maskTop and radiusPx > 0 then
        topMask = Instance.new("Frame", b)
        topMask.Size = UDim2.new(1, 0, 0, radiusPx)
        topMask.Position = UDim2.new(0, 0, 0, 0)
        topMask.BackgroundColor3 = MYQ.Btn
        topMask.BorderSizePixel = 0
        topMask.ZIndex = 6
        topMask.Active = false
    end

    local lbl = Instance.new("TextLabel")
    lbl.Parent = b
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    applyI18N(lbl, text)
    lbl.TextColor3 = SUB.White
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = CFG.Font.Sub
    lbl.TextScaled = true
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Center
    lbl.TextYAlignment = Enum.TextYAlignment.Center
    lbl.TextStrokeColor3 = SUB.Stroke
    lbl.TextStrokeTransparency = 0.2
    lbl.Active = false
    lbl.ZIndex = 7

    local function applyColor(c)
        b.BackgroundColor3 = c
        if topMask then topMask.BackgroundColor3 = c end
    end

    b.MouseEnter:Connect(function() applyColor(MYQ.Hover) end)
    b.MouseLeave:Connect(function() applyColor(MYQ.Btn) end)
    b.MouseButton1Down:Connect(function() applyColor(MYQ.Press) end)
    b.MouseButton1Up:Connect(function() applyColor(MYQ.Hover) end)

    if onClick then b.MouseButton1Click:Connect(function() safe("MYQBtn."..text, onClick) end) end
    return b
end

local function createCloseGUIButton(parent, onClose)
    local btn = Instance.new("TextButton")
    btn.Parent = parent
    btn.Size = UDim2.new(1, 0, 0, CFG.BtnH)
    btn.BackgroundColor3 = MYQ.Btn
    btn.BorderSizePixel = 0
    btn.Text = ""
    btn.AutoButtonColor = false
    btn.Active = true
    btn.ZIndex = 5
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, CLOSE_BTN_CORNER)

    local topMask = Instance.new("Frame", btn)
    topMask.Size = UDim2.new(1, 0, 0, CLOSE_BTN_CORNER)
    topMask.Position = UDim2.new(0, 0, 0, 0)
    topMask.BackgroundColor3 = MYQ.Btn
    topMask.BorderSizePixel = 0
    topMask.ZIndex = 6
    topMask.Active = false

    local lbl = Instance.new("TextLabel", btn)
    lbl.Size = UDim2.new(1, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = "Close GUI"
    lbl.TextColor3 = SUB.White
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = CFG.Font.Sub
    lbl.TextScaled = true
    lbl.TextWrapped = true
    lbl.TextXAlignment = Enum.TextXAlignment.Center
    lbl.TextYAlignment = Enum.TextYAlignment.Center
    lbl.TextStrokeColor3 = SUB.Stroke
    lbl.TextStrokeTransparency = 0.2
    lbl.Active = false
    lbl.ZIndex = 7

    local function applyColor(c)
        btn.BackgroundColor3 = c
        topMask.BackgroundColor3 = c
    end

    btn.MouseEnter:Connect(function() applyColor(MYQ.Hover) end)
    btn.MouseLeave:Connect(function() applyColor(MYQ.Btn) end)
    btn.MouseButton1Down:Connect(function() applyColor(MYQ.Press) end)
    btn.MouseButton1Up:Connect(function() applyColor(MYQ.Hover) end)

    btn.MouseButton1Click:Connect(function()
        if onClose then safe("CloseGUI", onClose) end
    end)

    return btn
end

local function CreateSlider(text, parent, featureKey, minVal, maxVal, callback)
    minVal = minVal or 0
    maxVal = maxVal or 100
    local defaultVal = S.Features[featureKey]
    if type(defaultVal) ~= "number" then defaultVal = minVal end
    defaultVal = math.clamp(defaultVal, minVal, maxVal)

    local container = Instance.new("Frame")
    container.Parent = parent
    container.Size = UDim2.new(1, 0, 0, CFG.BtnH + 5)
    container.BackgroundTransparency = 1
    container.BorderSizePixel = 0
    container.Active = false

    local sliderFrame = Instance.new("Frame")
    sliderFrame.Parent = container
    sliderFrame.BackgroundColor3 = SUB.Btn
    sliderFrame.Size = UDim2.new(1, 0, 1, 0)
    sliderFrame.BorderSizePixel = 0
    sliderFrame.ZIndex = 10
    Instance.new("UICorner", sliderFrame).CornerRadius = UDim.new(0, 5)

    local sliderLabel = Instance.new("TextLabel")
    sliderLabel.Parent = sliderFrame
    sliderLabel.TextScaled = true
    sliderLabel.BackgroundColor3 = SUB.Btn
    sliderLabel:SetAttribute("I18NKey", text)
    sliderLabel:SetAttribute("I18NValue", defaultVal)
    sliderLabel.Text = T(text) .. " [" .. tostring(defaultVal) .. "]"
    sliderLabel.TextColor3 = SUB.White
    sliderLabel.Size = UDim2.new(1, 0, 0.7, 0)
    sliderLabel.Font = Enum.Font.Gotham
    sliderLabel.BorderSizePixel = 0
    sliderLabel.ZIndex = 10

    local sliderTrack = Instance.new("Frame")
    sliderTrack.Parent = sliderFrame
    sliderTrack.BackgroundColor3 = SUB.White
    sliderTrack.Size = UDim2.new(0.9, 0, 0.05, 0)
    sliderTrack.Position = UDim2.new(0.05, 0, 0.8, 0)
    sliderTrack.BorderSizePixel = 0
    sliderTrack.ZIndex = 10

    local sliderKnob = Instance.new("ImageLabel")
    sliderKnob.Parent = sliderTrack
    sliderKnob.AnchorPoint = Vector2.new(0.5, 0.5)
    sliderKnob.BackgroundTransparency = 1
    sliderKnob.Size = UDim2.new(0.055, 0, 5, 0)
    sliderKnob.Position = UDim2.new(0, 0, 0.5, 0)
    sliderKnob.Image = MYQ.KnobImage
    sliderKnob.BorderSizePixel = 0
    sliderKnob.ZIndex = 12

    local clickCatcher = Instance.new("TextButton")
    clickCatcher.Parent = sliderFrame
    clickCatcher.BackgroundTransparency = 1
    clickCatcher.Text = ""
    clickCatcher.TextTransparency = 1
    clickCatcher.Size = UDim2.new(1, 0, 1, 0)
    clickCatcher.AutoButtonColor = false
    clickCatcher.ZIndex = 35
    clickCatcher.Active = true

    local cur = defaultVal
    local dragging = false

    local function setValue(value)
        value = math.clamp(value, minVal, maxVal)
        local roundedVal = math.floor(value + 0.5)
        local percent = (value - minVal) / (maxVal - minVal)
        sliderKnob.Position = UDim2.new(percent, 0, 0.5, 0)
        sliderLabel:SetAttribute("I18NValue", roundedVal)
        sliderLabel.Text = T(text) .. " [" .. tostring(roundedVal) .. "]"
        if roundedVal ~= cur then
            cur = roundedVal
            S.Features[featureKey] = cur
            if callback then safe("Slider."..text, callback, cur) end
        end
    end

    local function updateFromScreenX(screenX)
        local ap = sliderTrack.AbsolutePosition
        local as = sliderTrack.AbsoluteSize
        if as.X <= 0 then return end
        local pct = (screenX - ap.X) / as.X
        setValue(minVal + pct * (maxVal - minVal))
    end

    clickCatcher.MouseButton1Down:Connect(function()
        dragging = true
        local m = UserInputService:GetMouseLocation()
        updateFromScreenX(m.X)
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
            local m = UserInputService:GetMouseLocation()
            updateFromScreenX(m.X)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    local initPercent = (cur - minVal) / (maxVal - minVal)
    sliderKnob.Position = UDim2.new(initPercent, 0, 0.5, 0)

    return {Container = container, GetValue = function() return cur end}
end

local function maskFrameBottom(frame, corner)
    local px = cornerToPx(frame, corner)
    local mask = Instance.new("Frame", frame)
    mask.Size = UDim2.new(1, 0, 0, px)
    mask.Position = UDim2.new(0, 0, 1, -px)
    mask.BackgroundColor3 = frame.BackgroundColor3
    mask.BorderSizePixel = 0
    mask.ZIndex = 0
end

local function maskFrameTop(frame, corner)
    local px = cornerToPx(frame, corner)
    local mask = Instance.new("Frame", frame)
    mask.Size = UDim2.new(1, 0, 0, px)
    mask.Position = UDim2.new(0, 0, 0, 0)
    mask.BackgroundColor3 = frame.BackgroundColor3
    mask.BorderSizePixel = 0
    mask.ZIndex = 0
end








-- ============================================================
-- 主控小窗 + 多个独立浮动面板 (MYQF 结构)
-- ============================================================
-- 主控小窗已删除, 直接创建面板
local mainPos = UDim2.new(0, 6 * CFG.Scale, 0, 65 * CFG.Scale)
local mainGap = math.max(3, math.floor(4 * CFG.Scale))
local y0 = INNER_TOP_PAD
local sp = CFG.BtnH + mainGap

local function stroke(lbl) lbl.TextStrokeColor3 = SUB.Stroke; lbl.TextStrokeTransparency = 0.2 end

-- ============================================================
-- 面板创建函数 (仿 MYQF CreatePanel)
-- ============================================================
local panelOrigins = {}

-- ★ 前向声明: 悬浮球在按钮回调里被引用, 必须先声明否则是 nil
local minF = nil

local function CreatePanel(titleText)
    local f = Instance.new("Frame")
    f.Parent = container
    f.Name = "Frame" .. titleText
    f.Size = UDim2.new(0, CFG.SubW, 0, CFG.TitleH)
    f.BackgroundColor3 = SUB.Title
    f.BorderSizePixel = 0
    f.Active = true
    f.Draggable = true
    Instance.new("UICorner", f).CornerRadius = TITLE_CORNER
    maskFrameBottom(f, TITLE_CORNER)

    local title = Instance.new("TextLabel", f)
    title.Size = UDim2.new(1, 0, 1, 0)
    title.BackgroundTransparency = 1
    title.Text = titleText
    title.TextColor3 = SUB.White
    title.Font = Enum.Font.GothamBold
    title.TextSize = CFG.Font.Title
    title.TextScaled = true
    title.TextXAlignment = Enum.TextXAlignment.Center
    title.TextYAlignment = Enum.TextYAlignment.Center
    title.Active = false
    -- ★ 限制最大字号, 否则中文标题会被 TextScaled 撑爆
    local tsc = Instance.new("UITextSizeConstraint")
    tsc.MaxTextSize = CFG.Font.Title
    tsc.MinTextSize = 8
    tsc.Parent = title

    local bodyBg = Instance.new("Frame", f)
    bodyBg.Name = "Body"
    bodyBg.Size = UDim2.new(1, 0, 0, 0)
    bodyBg.Position = UDim2.new(0, 0, 1, 0)
    bodyBg.BackgroundColor3 = SUB.Body
    bodyBg.BorderSizePixel = 0
    bodyBg.Active = true
    Instance.new("UICorner", bodyBg).CornerRadius = TITLE_CORNER
    maskFrameTop(bodyBg, TITLE_CORNER)

    local separator = Instance.new("Frame", bodyBg)
    separator.Name = "Separator"
    separator.Size = UDim2.new(1, 0, 0, 1)
    separator.Position = UDim2.new(0, 0, 0, 0)
    separator.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    separator.BorderSizePixel = 0
    separator.ZIndex = 2

    local content = Instance.new("Frame", bodyBg)
    content.Name = "Content"
    content.Size = UDim2.new(1, -4 * CFG.Scale, 0, 0)
    content.Position = UDim2.new(0, 2 * CFG.Scale, 0, INNER_TOP_PAD)
    content.BackgroundColor3 = SUB.Content
    content.BorderSizePixel = 0
    content.ClipsDescendants = true
    local layout = Instance.new("UIListLayout", content)
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.Padding = UDim.new(0, mainGap)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center

    -- ★ 关键: MYQF 的做法是"创建后立刻算一次尺寸"，并挂监听自动重算
    local function recalc()
        task.defer(function()
            local h = layout.AbsoluteContentSize.Y
            if h < 10 then h = 10 end
            content.Size = UDim2.new(1, -4 * CFG.Scale, 0, h)
            bodyBg.Size = UDim2.new(1, 0, 0, INNER_TOP_PAD + h + INNER_BOTTOM_PAD)
            -- ★ 关键: 绝不修改 f.Size
            --   f 只占标题高度, Body 从 f 底部往下延伸(MYQF 原版做法)
            --   若拉高 f, Body 会被推到最底部, 标题区被撑成整块面板

        end)
    end

    f:SetAttribute("recalc", true)
    table.insert(S.UI.Panels, f)
    return f, recalc
end

local mainPos = UDim2.new(0, 6 * CFG.Scale, 0, 65 * CFG.Scale)

local function mkButton(text, parent, onClick, color)
    local b = Instance.new("TextButton")
    b.Parent = parent
    b.Size = UDim2.new(1, 0, 0, CFG.BtnH)
    b.BackgroundColor3 = color or SUB.Btn
    b.Text = text
    b.TextColor3 = SUB.White
    b.Font = Enum.Font.Gotham
    b.TextSize = CFG.Font.Main
    b.TextScaled = true
    b.BorderSizePixel = 0
    b.AutoButtonColor = false
    b.TextStrokeColor3 = SUB.Stroke
    b.TextStrokeTransparency = 0.2
    b.Active = true
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
    b.MouseEnter:Connect(function() b.BackgroundColor3 = SUB.BtnHover end)
    b.MouseLeave:Connect(function() b.BackgroundColor3 = color or SUB.Btn end)
    if onClick then b.MouseButton1Click:Connect(onClick) end
    return b
end

-- ============================================================
-- 面板 1: 界面
-- ============================================================
local uiPanel, uiRecalc = CreatePanel("界面")
local uiContent = uiPanel.Body.Content

-- ★「隐藏/显示面板」= MYQF 的 Hide/Show
--   只隐藏/显示「其他面板」, 界面面板本身永远保留(作为恢复入口)
mkButton("隐藏/显示面板", uiContent, function()
    S.UI.PanelsVisible = not S.UI.PanelsVisible
    for _, p in ipairs(S.UI.Panels) do
        if p ~= uiPanel then
            p.Visible = S.UI.PanelsVisible
        end
    end
    -- 子设置面板也一起隐藏
    for _, sp in pairs(S.UI.SettingPanels) do
        sp.Visible = S.UI.PanelsVisible and sp.Visible or false
    end
end)

-- ★「最小化」= MYQF 的 HideUI
--   整个 UI 隐藏, 只留小方块; 长按小方块 0.7s 恢复
mkButton("最小化", uiContent, function()
    for _, p in ipairs(S.UI.Panels) do p.Visible = false end
    for _, sp in pairs(S.UI.SettingPanels) do sp.Visible = false end
    S.UI.PanelsVisible = true      -- 恢复时应全开
    if minF then minF.Visible = true end
end)

mkButton("重置界面位置", uiContent, function()
    local ti = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    for _, p in ipairs(S.UI.Panels) do
        local o = panelOrigins[p]
        if o then TweenService:Create(p, ti, {Position = o}):Play() end
    end
end)

mkButton("关闭界面", uiContent, function()
    local SA = getgenv().SilentAim
    if SA then
        SA.Enabled = false        SA.ESPEnabled = false
        SA.AutoEscapeEnabled = false
        SA.InfiniteStaminaEnabled = false
    end
    Nanoka:Destroy()
end, Color3.fromRGB(120, 40, 45))

uiRecalc()
task.delay(0.15, uiRecalc)

-- ============================================================
-- 面板 3: 静默瞄准
-- ============================================================
local aimPanel, aimRecalc = CreatePanel("静默瞄准")
local aimContent = aimPanel.Body.Content

local aimToggle = CreateToggle("静默瞄准", aimContent, "silentAim", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.Enabled = on end
end, SUB)

local headToggle = CreateToggle("只瞄头部", aimContent, "headOnly", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.HeadOnly = on end
end, SUB)

local wallToggle = CreateToggle("穿墙检测", aimContent, "wallCheck", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.WallCheck = on end
end, SUB)

local fovToggle = CreateToggle("显示 FOV 圈", aimContent, "showFOV", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.ShowFOV = on end
end, SUB)

local indToggle = CreateToggle("目标指示圈", aimContent, "showIndicator", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.ShowIndicator = on end
end, SUB)

-- 优先目标 (点击弹出独立设置子面板, 仿 MYQF pvpAimSettingPanel)
local prioBtn = CreateButton("优先目标设置", aimContent, nil, SUB)
prioBtn.LayoutOrder = 90
prioBtn.TextColor3 = SUB.White

local prioPanel = nil
local PRIO_MODES = {
    { key = "near",   text = "最近" },
    { key = "far",    text = "最远" },
    { key = "hpLow",  text = "血少" },
    { key = "hpHigh", text = "血多" },
}
local prioBtns = {}

local function buildPrioPanel()
    if prioPanel then return prioPanel end
    local titleH = CFG.TitleH * 0.8
    local f = Instance.new("Frame")
    f.Name = "PrioSettings"
    f.Parent = container
    f.BackgroundColor3 = SUB.Title
    f.BorderSizePixel = 0
    f.Size = UDim2.new(0, CFG.SubW, 0, titleH)
    f.Visible = false
    f.ZIndex = 10
    f.Active = true
    f.Draggable = true
    Instance.new("UICorner", f).CornerRadius = TITLE_CORNER
    maskFrameBottom(f, TITLE_CORNER)

    local t = Instance.new("TextLabel", f)
    t.Size = UDim2.new(1, 0, 1, 0)
    t.BackgroundTransparency = 1
    t.Text = "优先目标"
    t.TextColor3 = SUB.White
    t.Font = Enum.Font.GothamBold
    t.TextSize = CFG.Font.Sub
    t.TextXAlignment = Enum.TextXAlignment.Center
    t.TextYAlignment = Enum.TextYAlignment.Center
    t.Active = false

    local body = Instance.new("Frame", f)
    body.Name = "Body"
    body.Size = UDim2.new(1, 0, 0, 0)
    body.Position = UDim2.new(0, 0, 1, 0)
    body.BackgroundColor3 = SUB.Body
    body.BorderSizePixel = 0
    body.Active = true
    Instance.new("UICorner", body).CornerRadius = TITLE_CORNER
    maskFrameTop(body, TITLE_CORNER)

    local content = Instance.new("Frame", body)
    content.Name = "Content"
    content.Size = UDim2.new(1, -4 * CFG.Scale, 0, 0)
    content.Position = UDim2.new(0, 2 * CFG.Scale, 0, INNER_TOP_PAD)
    content.BackgroundColor3 = SUB.Body
    content.BorderSizePixel = 0
    local layout = Instance.new("UIListLayout", content)
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.Padding = UDim.new(0, mainGap)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center

    -- 4 个选项按钮
    for i, m in ipairs(PRIO_MODES) do
        local b = Instance.new("TextButton")
        b.Parent = content
        b.Size = UDim2.new(1, 0, 0, CFG.BtnH)
        b.BackgroundColor3 = SUB.Btn
        b.Text = m.text
        b.TextColor3 = SUB.White
        b.Font = Enum.Font.Gotham
        b.TextSize = CFG.Font.Main
        b.TextScaled = true
        b.BorderSizePixel = 0
        b.AutoButtonColor = false
        b.LayoutOrder = i
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5)
        local st = Instance.new("UIStroke")
        st.Thickness = 1.5
        st.Color = Color3.fromRGB(90,90,95)
        st.Transparency = 0.5
        st.Parent = b
        prioBtns[m.key] = { btn = b, stroke = st, text = m.text }

        b.MouseEnter:Connect(function() b.BackgroundColor3 = SUB.BtnHover end)
        b.MouseLeave:Connect(function()
            local SA = getgenv().SilentAim
            if SA and SA.Priority == m.key then
                b.BackgroundColor3 = Color3.fromRGB(0, 90, 130)
            else
                b.BackgroundColor3 = SUB.Btn
            end
        end)
        b.MouseButton1Click:Connect(function()
            local SA = getgenv().SilentAim
            if SA then SA.Priority = m.key end
            for k, item in pairs(prioBtns) do
                if k == m.key then
                    item.stroke.Color = Color3.fromRGB(0, 200, 255)
                    item.stroke.Transparency = 0
                    item.btn.BackgroundColor3 = Color3.fromRGB(0, 90, 130)
                else
                    item.stroke.Color = Color3.fromRGB(90,90,95)
                    item.stroke.Transparency = 0.5
                    item.btn.BackgroundColor3 = SUB.Btn
                end
            end
        end)
    end

    task.wait(0.05)
    local h = layout.AbsoluteContentSize.Y
    if h < 10 then h = 10 end
    content.Size = UDim2.new(1, -4 * CFG.Scale, 0, h)
    body.Size = UDim2.new(1, 0, 0, INNER_TOP_PAD + h + INNER_BOTTOM_PAD)
    -- ★ 不改 f.Size, 保持标题栏高度, Body 向下延伸

    table.insert(S.UI.SettingPanels, f)
    prioPanel = f
    return f
end

-- 点击按钮 → 弹出/收起设置面板
prioBtn.MouseButton1Click:Connect(function()
    local f = buildPrioPanel()
    if not f then return end
    if not f.Position or f.Position == UDim2.new(0,0,0,0) then
        -- 放在静默瞄准面板右侧
        local px = aimPanel.Position.X.Offset + aimPanel.AbsoluteSize.X + 4
        local py = aimPanel.Position.Y.Offset
        f.Position = UDim2.new(0, px, 0, py)
    end
    f.Visible = not f.Visible
    prioBtn.TextColor3 = f.Visible and SUB.Green or SUB.White
end)

-- 默认高亮当前模式
task.defer(function()
    local SA = getgenv().SilentAim
    local cur = SA and SA.Priority or "near"
    local item = prioBtns[cur]
    if item then
        item.stroke.Color = Color3.fromRGB(0, 200, 255)
        item.stroke.Transparency = 0
        item.btn.BackgroundColor3 = Color3.fromRGB(0, 90, 130)
    end
end)


local fovSlider = CreateSlider("FOV 范围", aimContent, "fovSize", 50, 1400, function(v)
    local SA = getgenv().SilentAim
    if SA then SA.FOV = math.floor(v) end
end)
fovSlider.Container.LayoutOrder = 99

-- ============================================================
-- 面板 4: 战斗
-- ============================================================
local combatPanel, combatRecalc = CreatePanel("战斗")
local combatContent = combatPanel.Body.Content

local staminaToggle = CreateToggle("无限体力", combatContent, "infiniteStamina", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.InfiniteStaminaEnabled = on end
end, SUB)

local statsToggle = CreateToggle("数据统计", combatContent, "statsOn", function(on)
    local SA = getgenv().SilentAim
    if SA then
        SA.StatsEnabled = on
        if on then
            local f = getgenv().SA_ResetStats
            if f then f() end
        end
    end
end, SUB)

mkButton("重置统计", combatContent, function()
    local f = getgenv().SA_ResetStats
    if f then f() end
end)

local hudToggle = CreateToggle("僵尸数量HUD", combatContent, "zombieHUD", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.HUDEnabled = on end
end, SUB)

local escapeToggle = CreateToggle("自动挣脱红眼", combatContent, "autoEscape", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.AutoEscapeEnabled = on end
end, SUB)

-- ============================================================
-- 面板 5: 透视
-- ============================================================
local espPanel, espRecalc = CreatePanel("透视")
local espContent = espPanel.Body.Content

local nightToggle = CreateToggle("夜视增亮", espContent, "nightVision", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.NightVisionEnabled = on end
end, SUB)

local fogToggle = CreateToggle("去雾去霾", espContent, "noFog", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.NoFogEnabled = on end
end, SUB)

local espToggle = CreateToggle("特殊兵种ESP", espContent, "espSpecial", function(on)
    local SA = getgenv().SilentAim
    if SA then SA.ESPEnabled = on end
end, SUB)

-- ============================================================
-- 面板 5: 配置
-- ============================================================
local configPanel, configRecalc = CreatePanel("配置")
local configContent = configPanel.Body.Content

-- 配置存储: 写到执行器工作区
local CONFIG_FILE = "silent_aim_config.json"

local function getConfigDir()
    return "SilentAim/"
end

local function serializeConfig()
    local SA = getgenv().SilentAim
    if not SA then return nil end
    local t = {}
    t.Enabled = SA.Enabled
    t.AutoFireEnabled = SA.AutoFireEnabled
    t.AutoFireInterval = SA.AutoFireInterval
    t.ESPEnabled = SA.ESPEnabled
    t.ESPOnlySpecial = SA.ESPOnlySpecial
    t.AutoEscapeEnabled = SA.AutoEscapeEnabled
    t.HeadOnly = SA.HeadOnly
    t.WallCheck = SA.WallCheck
    t.ShowFOV = SA.ShowFOV
    t.ShowIndicator = SA.ShowIndicator
    t.FOV = SA.FOV
    t.Priority = SA.Priority
    t.HUDEnabled = SA.HUDEnabled
    return t
end

local function applyConfig(t, silent)
    local SA = getgenv().SilentAim
    if not SA or type(t) ~= "table" then return false end
    for k, v in pairs(t) do
        if SA[k] ~= nil or type(v) == "boolean" or type(v) == "number" or type(v) == "string" then
            SA[k] = v
        end
    end
    -- ★ 同步 UI 开关显示 (闭包内 on 变量也要同步, 否则按钮颜色不变)
    if S and S.Features then
        local MAP = {
            silentAim     = SA.Enabled,
            autoFire      = SA.AutoFireEnabled,            espSpecial    = SA.ESPEnabled,
            espAll        = (SA.ESPOnlySpecial == false),
            autoEscape    = SA.AutoEscapeEnabled,
            infiniteStamina = SA.InfiniteStaminaEnabled,
            headOnly      = SA.HeadOnly,
            wallCheck     = SA.WallCheck,
            showFOV       = SA.ShowFOV,
            showIndicator = SA.ShowIndicator,
            zombieHUD     = SA.HUDEnabled,
        }
        local sync = getgenv().SA_ToggleSync or {}
        for key, val in pairs(MAP) do
            S.Features[key] = val
            local item = sync[key]
            if item and item.refresh then
                pcall(item.refresh, val)
            end
        end
    end
    if not silent then
        pcall(function()
            StarterGui:SetCore("SendNotification", {
                Title = "配置",
                Text = "已应用",
                Duration = 2
            })
        end)
    end
    return true
end

local function saveConfig()
    local t = serializeConfig()
    if not t then return "无配置" end
    local ok = pcall(function()
        if writefile then
            writefile(CONFIG_FILE, game:GetService("HttpService"):JSONEncode(t))
        end
    end)
    return ok and "已保存" or "保存失败"
end

local function loadConfig()
    local ok, content = pcall(function()
        if isfile and isfile(CONFIG_FILE) then
            return readfile(CONFIG_FILE)
        end
        return nil
    end)
    if not ok or not content then return "无配置文件" end
    local ok2, t = pcall(function()
        return game:GetService("HttpService"):JSONDecode(content)
    end)
    if not ok2 or type(t) ~= "table" then return "解析失败" end
    applyConfig(t)
    return "已加载"
end

-- 配置操作按钮
mkButton("保存当前配置", configContent, function()
    local msg = saveConfig()
    pcall(function()
        StarterGui:SetCore("SendNotification", {Title="配置", Text=msg, Duration=2})
    end)
end)

mkButton("加载配置", configContent, function()
    local msg = loadConfig()
    pcall(function()
        StarterGui:SetCore("SendNotification", {Title="配置", Text=msg, Duration=2})
    end)
end)

mkButton("重置为默认", configContent, function()
    applyConfig({
        Enabled = false, AutoFireEnabled = false, ESPEnabled = false,
        AutoEscapeEnabled = false, HeadOnly = true,
        WallCheck = false, ShowFOV = false, ShowIndicator = false,
        FOV = 600, Priority = "near", ESPOnlySpecial = true,
    })
end)


-- ★ 所有面板内容构建完毕, 统一重算尺寸 (MYQF 做法)
task.delay(0.2, function()
    for _, r in ipairs({uiRecalc, configRecalc, aimRecalc, combatRecalc, espRecalc}) do
        pcall(r)
    end
end)
task.delay(0.8, function()
    for _, r in ipairs({uiRecalc, configRecalc, aimRecalc, combatRecalc, espRecalc}) do
        pcall(r)
    end
end)

-- ============================================================
-- 最小化悬浮球 (长按恢复)
-- ============================================================
minF = Instance.new("Frame")
minF.Parent = container
minF.Name = "Frame"
minF.Size = UDim2.new(0, CFG.MinSize, 0, CFG.MinSize)
minF.BackgroundColor3 = SUB.Title
minF.Visible = false
minF.BorderSizePixel = 0
minF.Active = true
minF.Draggable = true
Instance.new("UICorner", minF).CornerRadius = TITLE_CORNER

local minL = Instance.new("TextLabel", minF)
minL.Size = UDim2.new(1, 0, 1, 0)
minL.BackgroundTransparency = 1
minL.Text = "SA"
minL.TextColor3 = SUB.White
minL.Font = Enum.Font.GothamBold
minL.TextSize = CFG.Font.Min
minL.TextXAlignment = Enum.TextXAlignment.Center
minL.TextYAlignment = Enum.TextYAlignment.Center
stroke(minL)
minL.Active = false

local holdTask, pressPos
minF.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    if holdTask then task.cancel(holdTask) end
    pressPos = Vector2.new(input.Position.X, input.Position.Y)
    holdTask = task.delay(0.7, function()
        if minF and minF.Visible and pressPos then
            minF.Visible = false
            S.UI.PanelsVisible = true     -- ★ 恢复时强制打开面板
            for _, p in ipairs(S.UI.Panels) do p.Visible = true end
        end
        holdTask = nil; pressPos = nil
    end)
end)
minF.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        if pressPos then
            local cur = Vector2.new(input.Position.X, input.Position.Y)
            if (cur - pressPos).Magnitude > 5 then
                if holdTask then task.cancel(holdTask); holdTask = nil end
                pressPos = nil
            end
        end
    end
end)
minF.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if holdTask then task.cancel(holdTask); holdTask = nil end
        pressPos = nil
    end
end)

S.UI.MinFrame = minF

-- ============================================================
-- 布局: 并排排列 (主控 + 4 面板)
-- ============================================================
local sx = 6 * CFG.Scale
local sy = ((S.DeviceType == "Tablet") and (45 * CFG.Scale) or (65 * CFG.Scale)) - 1
mainPos = UDim2.new(0, sx, 0, sy)

-- 面板自动换行排列（避免超出屏幕宽度）
local gap = math.max(2, math.floor(3 * CFG.Scale))
local viewW = camera.ViewportSize.X
local curX = sx          -- ★ 从最左侧开始, 界面面板排第一
local curY = sy
local rowH = 0

for _, p in ipairs(S.UI.Panels) do
    pcall(function() if p.GetAttribute and p:GetAttribute('recalc') then end end)
    local pw = p.Size.X.Offset
    local ph = p.Size.Y.Offset
    if curX + pw > viewW - 8 then
        curX = sx
        curY = curY + rowH + gap
        rowH = 0
    end
    panelOrigins[p] = UDim2.new(0, curX, 0, curY)
    p.Position = panelOrigins[p]
    curX = curX + pw + gap
    if ph > rowH then rowH = ph end
end

minF.Position = UDim2.new(0, 12 * CFG.Scale, 0, 65 * CFG.Scale)


-- 面板循环重算尺寸
task.spawn(function()
    task.wait(0.3)
    while true do
        task.wait(1.5)
        for _, p in ipairs(S.UI.Panels) do
            pcall(function() if p.GetAttribute and p:GetAttribute('recalc') then end end)
        end
    end
end)
task.defer(function()
    task.wait(0.4)
    for _, p in ipairs(S.UI.Panels) do pcall(function() if p.GetAttribute and p:GetAttribute('recalc') then end end) end
end)

-- 默认选中"最近"
task.defer(function()
    local it = prioBtns["near"]
    if it then
        it.stroke.Color = Color3.fromRGB(0, 200, 255); it.stroke.Transparency = 0
        it.btn.BackgroundColor3 = Color3.fromRGB(0, 90, 130)
    end
end)

-- ★ 开启 GUI
Nanoka.Enabled = true

safe("StartLoop", startLoop)

pcall(function()
    StarterGui:SetCore("SendNotification", {
        Title = "大不列颠脚本中心-tuf加载成功",
        Text = "老东西们享用脚本去吧",
        Duration = 3
    })
end)
