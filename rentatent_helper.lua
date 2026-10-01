--[[
    租赁帐篷大亨 · 自动助手 v1.0
    ============ 功能(独立开关) ============
    [自动收钱+消费] 合并功能: 自动触发所有
      Collect $(收银机/小费罐) + Let In(放访客进来)
      + Give Blanket/Hot Drink(给客人物资) + Prepare Food/Blanket/Hot Drink(备货)
    [自动箱子上架] 自动触发 Take Box / Place Delivery(工业货架)
    [自动清理帐篷] 自动触发 Clean(脏帐篷) 
    原理: 游戏的交互提示只在玩家靠近时出现, 本脚本轮询并隔空触发
          所有已启用的匹配提示(不传送, 人站营地即可全自动)
    单例守护
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer

-- ================= 单例守护 =================
if getgenv()._RT_INST and typeof(getgenv()._RT_INST.kill) == "function" then
    pcall(function() getgenv()._RT_INST.kill() end)
end
local INST = { alive = true, conns = {} }
getgenv()._RT_INST = INST
local function bind(c) table.insert(INST.conns, c) end

-- ================= 配置 =================
local state = {
    money = true,   -- 自动收钱+消费(合并)
    boxes = false,  -- 自动箱子上架
    clean = false,  -- 自动清理帐篷
    gap = 2,        -- 全图扫描间隔(事件触发是实时的)
}
-- 触发规则: {动作文本匹配, 归属开关}
local RULES = {
    {pat = "^Collect %$", key = "money"},
    {pat = "^Let In$", key = "money"},
    {pat = "^Give Blanket$", key = "money"},
    {pat = "^Give Hot Drink$", key = "money"},
    {pat = "^Prepare Food$", key = "money"},
    {pat = "^Prepare Blanket$", key = "money"},
    {pat = "^Prepare Hot Drink$", key = "money"},
    {pat = "^Take Box$", key = "boxes"},
    {pat = "^Place Delivery$", key = "boxes"},
    {pat = "^Clean$", key = "clean"},
}
-- ========================================

-- ---------- 面板 ----------
if lp.PlayerGui:FindFirstChild("_rt_panel") then
    lp.PlayerGui._rt_panel:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "_rt_panel"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 200, 0, 160)
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
title.Text = "租赁帐篷 全图助手"
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

makeToggle("自动收钱+消费", 28, function() return state.money end, function(v)
    state.money = v
end)

makeToggle("自动箱子上架", 58, function() return state.boxes end, function(v)
    state.boxes = v
end)

makeToggle("自动清理帐篷", 88, function() return state.clean end, function(v)
    state.clean = v
end)

status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 42)
status.Position = UDim2.new(0, 8, 0, 118)
status.BackgroundTransparency = 1
status.Text = "状态: 等待..."
status.TextColor3 = Color3.fromRGB(150, 200, 150)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextWrapped = true
status.Parent = frame

-- ---------- 匹配函数 ----------
local function matchRule(prompt)
    local act = prompt.ActionText
    if not act or act == "" then return nil end
    for _, rule in ipairs(RULES) do
        if state[rule.key] and act:find(rule.pat) then
            return rule.key
        end
    end
    return nil
end

local function tryFire(prompt)
    local key = matchRule(prompt)
    if not key then return nil end
    local ok = pcall(function() fireproximityprompt(prompt) end)
    if ok then
        if key == "money" then INST.cMoney = (INST.cMoney or 0) + 1
        elseif key == "boxes" then INST.cBoxes = (INST.cBoxes or 0) + 1
        else INST.cClean = (INST.cClean or 0) + 1 end
    end
    return key, ok
end

-- ---------- 事件驱动: 全图任何位置生成匹配提示立刻触发(抢在销毁前) ----------
bind(game.Workspace.DescendantAdded:Connect(function(d)
    if not INST.alive then return end
    if d.ClassName == "ProximityPrompt" then
        task.defer(function()
            if INST.alive and d.Parent then
                tryFire(d)
            end
        end)
    end
end))

-- ---------- 主循环 ----------
task.spawn(function()
    while INST.alive do
        local ok, err = pcall(function()
            local anyOn = state.money or state.boxes or state.clean
            if not anyOn then
                setStatus("全部关闭")
                return
            end
            -- 全图扫描(带节点上限防卡死)
            local scanned = 0
            local fired = 0
            for _, d in ipairs(game.Workspace:GetDescendants()) do
                scanned = scanned + 1
                if scanned > 30000 then break end -- 防卡死保险
                if not INST.alive then return end
                if d.ClassName == "ProximityPrompt" then
                    local key = matchRule(d)
                    if key and d.Enabled then
                        pcall(function() fireproximityprompt(d) end)
                        fired = fired + 1
                        task.wait(0.08)
                    end
                end
            end
            local cM, cB, cC = INST.cMoney or 0, INST.cBoxes or 0, INST.cClean or 0
            if fired > 0 then
                setStatus(string.format("全图触发%d个 | 累计: 钱%d 箱%d 清%d", fired, cM, cB, cC))
            else
                setStatus(string.format("全图无匹配 | 累计: 钱%d 箱%d 清%d", cM, cB, cC))
            end
        end)
        if not ok then
            setStatus("异常: " .. tostring(err):sub(1, 40))
        end
        task.wait(state.gap)
    end
end)

print("[RentATent v1.0] 自动助手已加载 | 单例守护")

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
