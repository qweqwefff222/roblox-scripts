--[[
    51区存活真相 · 武器MOD v1.2
    功能: 无限子弹(带伤害) + 射速提升 + 强制全自动 + 秒换单
    原理:
      - 服务器自己维护 _ammo 计数, 超发子弹没伤害
        → 每0.1s监视服务器 _ammo, 低于原版弹匣一半立即发 Reload 远程补满
      - rateOfFire 属性放大 = 射速提升(射击间隔=60/rateOfFire, 客户端实时读)
      - fireMode 属性强制 Auto + 按住鼠标按射速反复 Activate() 双保险
      - reloadTime 属性改小 = 客户端秒换单
    建议: 重进游戏后再注入(干净状态, 无旧版残留)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer

-- ================= 配置 =================
local RATE_MULT = 3         -- 射速倍率(原射速 x3, 想更快改大, 太快可能被服务器丢弃)
local RELOAD_TIME = 0.05    -- 客户端装弹耗时(秒换单)
local REFILL_RATIO = 0.5    -- 服务器弹药低于原版弹匣的此比例时自动补
local REFILL_POLL = 0.1     -- 服务器弹药轮询间隔(秒)
local REFILL_COOLDOWN = 0.6 -- 每把枪两次补弹请求最小间隔(秒)
-- ========================================

local orig = {}       -- [tool] = {mag=, rof=}
local lastRefill = {} -- [tool] = os.clock()

local function isBlaster(tool)
    return typeof(tool) == "Instance"
        and tool:IsA("Tool")
        and tool:GetAttribute("fireMode") ~= nil
        and tool:GetAttribute("damage") ~= nil
end

local function cacheOrig(tool)
    if orig[tool] then return end
    local mag = tool:GetAttribute("magazineSize")
    local rof = tool:GetAttribute("rateOfFire")
    orig[tool] = {
        -- magazineSize 若被旧版本改成 999999 视为未知, 回退 10
        mag = (typeof(mag) == "number" and mag > 0 and mag < 100000) and mag or 10,
        rof = (typeof(rof) == "number" and rof > 0) and rof or 300,
    }
end

local function apply(tool)
    if not isBlaster(tool) then return end
    cacheOrig(tool)
    tool:SetAttribute("fireMode", "Auto")            -- 强制全自动(控制器分支)
    tool:SetAttribute("reloadTime", RELOAD_TIME)     -- 客户端秒换单
    tool:SetAttribute("rateOfFire", orig[tool].rof * RATE_MULT) -- 射速提升
end

-- ---------- 服务器弹药保活(核心: 让每发子弹都有伤害) ----------
local function refillStep()
    local ch = lp.Character
    if not ch then return end
    local now = os.clock()
    for _, t in ipairs(ch:GetChildren()) do
        if isBlaster(t) and orig[t] then
            local ammo = t:GetAttribute("_ammo")
            local threshold = math.max(1, math.floor(orig[t].mag * REFILL_RATIO))
            if typeof(ammo) == "number"
                and ammo <= threshold
                and now - (lastRefill[t] or 0) >= REFILL_COOLDOWN then
                lastRefill[t] = now
                ReplicatedStorage.Remotes.Reload:FireServer(t)
            end
        end
    end
end

task.spawn(function()
    while true do
        pcall(refillStep)
        task.wait(REFILL_POLL)
    end
end)

-- ---------- 强制全自动保底: 按住鼠标按当前射速反复 Activate ----------
local mouseHeld = false
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        mouseHeld = true
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        mouseHeld = false
    end
end)

task.spawn(function()
    while true do
        if mouseHeld then
            local ch = lp.Character
            local t = ch and ch:FindFirstChildOfClass("Tool")
            if isBlaster(t) then
                cacheOrig(t)
                local rof = orig[t].rof * RATE_MULT
                t:Activate() -- 已全自动的枪会自行循环, 重复调用无害
                task.wait(math.max(60 / math.max(rof, 1), 0.05))
            else
                task.wait(0.1)
            end
        else
            task.wait(0.05)
        end
    end
end)

-- ---------- 武器挂接 ----------
local function sweep()
    for _, t in ipairs(lp.Backpack:GetChildren()) do apply(t) end
    local ch = lp.Character
    if ch then
        for _, t in ipairs(ch:GetChildren()) do apply(t) end
    end
end

lp.Backpack.ChildAdded:Connect(function(c) task.defer(apply, c) end)

local function hookCharacter(ch)
    ch.ChildAdded:Connect(function(c) task.defer(apply, c) end)
    for _, t in ipairs(ch:GetChildren()) do apply(t) end
end
if lp.Character then hookCharacter(lp.Character) end
lp.CharacterAdded:Connect(hookCharacter)

task.spawn(function()
    while true do
        sweep()
        task.wait(2)
    end
end)

sweep()
print("[Area51 GunMod v1.2] 已加载: 无限子弹(带伤害) + 射速x" .. RATE_MULT .. " + 强制全自动 + 秒换单")
