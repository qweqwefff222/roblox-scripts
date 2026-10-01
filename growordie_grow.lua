--[[
    生长或死亡 · 自动生长 v1.0
    ============ 机制(已实测) ============
    - 你就是花, 站在盆位原地生长
    - SetGrowing(true, 朝灯方向) = BASK 对灯生长(实测有效, 高度上涨)
    - Gardener(园丁)巡逻, 看到有人对灯就杀(Hunt属性=被追杀者的Slot)
    ============ 功能 ============
    [自动生长] 对着最近的灯持续 BASK
    [猎人规避] 园丁面向你的盆(视锥内)或正在追杀你 → 立刻停止动作装没事
    面板: 开关 + 实时状态(当前高度/纪录/猎人距离与状态)
    单例守护
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local RS = game.ReplicatedStorage
local SetGrowing = RS:WaitForChild("Remotes"):WaitForChild("SetGrowing")

-- ================= 单例守护 =================
if getgenv()._GD_INST and typeof(getgenv()._GD_INST.kill) == "function" then
    pcall(function() getgenv()._GD_INST.kill() end)
end
local INST = { alive = true, conns = {} }
getgenv()._GD_INST = INST
local function bind(c) table.insert(INST.conns, c) end

-- ================= 配置 =================
local state = {
    grow = true,        -- 自动生长
    avoid = true,       -- 猎人规避
    dangerRange = 30,   -- 园丁视距(米)
    dangerCone = 55,    -- 园丁视锥半角(度)
    losCheck = true,    -- 视线遮挡检测(架子挡住=安全)
    graceTime = 1,      -- 危险解除后的缓冲秒数
}
-- ========================================

-- ---------- 日志 ----------
local logBuf = {}
local function log(msg)
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg))
    table.insert(logBuf, line)
    if #logBuf > 150 then
        local keep = {}
        for i = #logBuf - 99, #logBuf do keep[#keep + 1] = logBuf[i] end
        logBuf = keep
    end
    getgenv()._GD_LOG = logBuf
    pcall(function()
        if writefile then
            local old = ""
            if isfile and isfile("growordie_log.txt") then
                old = readfile("growordie_log.txt")
                if #old > 100000 then old = "" end
            end
            writefile("growordie_log.txt", old .. line .. "\n")
        end
    end)
end

-- ---------- 面板 ----------
if lp.PlayerGui:FindFirstChild("_gd_panel") then
    lp.PlayerGui._gd_panel:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "_gd_panel"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 200, 0, 270)
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
title.Text = "生长或死亡 自动生长"
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
    btn.Size = UDim2.new(1, -16, 0, 28)
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


makeToggle("自动生长", 28, function() return state.grow end, function(v)
    state.grow = v
end)

makeToggle("猎人规避", 58, function() return state.avoid end, function(v)
    state.avoid = v
end)

makeSlider(92, "园丁视距: %.0f米", 10, 60, state.dangerRange, 5, function(v)
    state.dangerRange = v
end)

makeSlider(124, "园丁视锥: %.0f°", 20, 90, state.dangerCone, 5, function(v)
    state.dangerCone = v
end)

makeToggle("视线遮挡检测", 156, function() return state.losCheck end, function(v)
    state.losCheck = v
end)

status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 74)
status.Position = UDim2.new(0, 8, 0, 186)
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
local function mySlot()
    return tonumber(lp:GetAttribute("Slot"))
end

local function myPot()
    local slot = mySlot()
    local pots = game.Workspace.Greenhouse and game.Workspace.Greenhouse:FindFirstChild("Pots")
    if not pots then return nil end
    local p = pots:FindFirstChild("Pot_" .. string.format("%02d", slot or 0)) or pots:FindFirstChild("Pot_" .. tostring(slot))
    if p then return p end
    -- 兜底: 数字匹配
    for _, c in ipairs(pots:GetChildren()) do
        if c.Name:find(tostring(slot)) then return c end
    end
    return nil
end

local function nearestLampPos(body)
    local gh = game.Workspace:FindFirstChild("Greenhouse")
    local lamps = gh and gh:FindFirstChild("GrowLamps")
    if not lamps then return nil end
    local bestD, bestL = math.huge, nil
    for _, l in ipairs(lamps:GetChildren()) do
        local tube = l:FindFirstChild("Tube")
        if tube then
            local d = (Vector2.new(tube.Position.X, tube.Position.Z) - Vector2.new(body.Position.X, body.Position.Z)).Magnitude
            if d < bestD then bestD, bestL = d, tube end
        end
    end
    return bestL and bestL.Position or nil
end

local function curHeight()
    local gui = lp.PlayerGui:FindFirstChild("GrowGui")
    if not gui then return -1 end
    for _, d in ipairs(gui:GetDescendants()) do
        if d:IsA("TextLabel") and d.Name == "H" and d.Visible then
            return tonumber(d.Text) or -1
        end
    end
    return -1
end

local function maxH()
    local ls = lp:FindFirstChild("leaderstats")
    local v = ls and ls:FindFirstChild("Max Height")
    return v and tonumber(v.Value) or -1
end

-- ---------- 主循环 ----------
task.spawn(function()
    local safeAt = 0 -- 危险解除时间
    local wasDanger = false
    local lampPos = nil
    local lampSlot = nil
    while INST.alive do
        local ok, err = pcall(function()
            local char = lp.Character
            if not char then
                setStatus("无角色(重生中)")
                return
            end
            local slot = mySlot()
            local pot = myPot()
            if not pot then
                setStatus("找不到我的盆(slot=" .. tostring(slot) .. ")")
                return
            end
            local body = pot:FindFirstChild("Body") or pot:FindFirstChildWhichIsA("BasePart", true)
            if not body then
                setStatus("盆没有Body")
                return
            end
            local potPos = body.Position

            -- 灯(跟随slot缓存)
            if lampSlot ~= slot then
                lampPos = nearestLampPos(body)
                lampSlot = slot
            end

            -- 猎人判定: 视距 + 视锥 + 视线遮挡
            local danger = false
            local hunted = false
            local gDist = -1
            local dangerWhy = ""
            local gardener = game.Workspace:FindFirstChild("Gardener")
            if gardener then
                hunted = (gardener:GetAttribute("Hunt") == slot)
                local gp = gardener:GetPivot().Position
                local flat = Vector3.new(gp.X - potPos.X, 0, gp.Z - potPos.Z)
                gDist = flat.Magnitude
                if hunted then danger = true; dangerWhy = "追杀" end
                if state.avoid and not danger and gDist < state.dangerRange then
                    -- 园丁朝向(优先Head)
                    local gLook
                    local head = gardener:FindFirstChild("Head", true)
                    if head and head:IsA("BasePart") then
                        gLook = head.CFrame.LookVector
                    else
                        gLook = gardener:GetPivot().LookVector
                    end
                    local gLookFlat = Vector3.new(gLook.X, 0, gLook.Z)
                    if gLookFlat.Magnitude > 0.01 then
                        gLookFlat = gLookFlat.Unit
                        local toMe = flat.Unit
                        local coneDot = math.cos(math.rad(state.dangerCone))
                        if gLookFlat:Dot(toMe) > coneDot then
                            danger = true
                            dangerWhy = string.format("视锥内(距%.0f)", gDist)
                        end
                    end
                    -- 视线遮挡: 架子/墙挡住 = 安全
                    if danger and state.losCheck then
                        local params = RaycastParams.new()
                        params.FilterType = Enum.RaycastFilterType.Exclude
                        params.FilterDescendantsInstances = {gardener, char}
                        local eye = gp + Vector3.new(0, 2, 0)
                        local hit = workspace:Raycast(eye, potPos - eye, params)
                        if hit then
                            danger = false
                            dangerWhy = ""
                        end
                    end
                end
            end

            -- 危险解除缓冲
            if wasDanger and not danger then
                safeAt = os.clock() + state.graceTime
            end
            wasDanger = danger
            if not danger and os.clock() < safeAt then
                danger = true -- 缓冲期继续装没事
            end

            -- 发意图
            local look
            if danger then
                -- 装没事: 朝向远离灯的方向
                look = lampPos and ((potPos - lampPos).Unit) or Vector3.new(0, 0, -1)
                if look.Y ~= 0 then look = Vector3.new(look.X, 0, look.Z).Unit end
                SetGrowing:FireServer(false, look)
            elseif state.grow and lampPos then
                look = (lampPos - potPos).Unit
                SetGrowing:FireServer(true, look)
            else
                SetGrowing:FireServer(false, Vector3.new(0, 0, -1))
            end

            -- 状态
            local h = curHeight()
            local mh = maxH()
            if danger then
                setStatus(string.format("⚠ 园丁在看! %s%s | 停止动作装没事", dangerWhy, hunted and " | 正在追杀你!" or ""))
            elseif hunted then
                setStatus(string.format("⚠ 被追杀! 距%.0f米 | 立刻离开灯的方向", gDist))
            elseif state.grow then
                setStatus(string.format("生长中 | 高%.1f (纪录%.1f)", h, mh))
            else
                setStatus(string.format("自动生长已关 | 高%.1f (纪录%.1f)", h, mh))
            end
        end)
        if not ok then
            log("主循环异常: " .. tostring(err))
        end
        task.wait(0.12)
    end
end)

print("[GrowOrDie v1.0] 自动生长已加载 | 单例守护")

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
