--[[
	杀戮光环 v1.0 · Obsidian（全中文）
	游戏：巨魔事件：另一个宇宙（placeId 99650242193315）
	机制（实测验证）：武器伤害 = 物理接触(Touched) + 服务器判定，客户端不发命中包
	实现：客户端瞬移武器 Handle（玩家网络所有权，位置会复制到服务器）到敌人身上
	      → 触发服务器 Touched → 扣血 → Handle 拉回
	通用适配：任何带 Humanoid+可定位部件的 Model 都算目标，不硬编码任何角色名
]]

local g = getgenv()
if g._KA_STOP then g._KA_STOP() end

local Players = game:GetService("Players")
local lp = Players.LocalPlayer

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/Library.lua"))()
local Window = Library:CreateWindow({
	Title = "杀戮光环",
	Footer = "v1.0 · 通用杀戮光环",
	ToggleKeybind = Enum.KeyCode.RightControl,
	Center = true,
	AutoShow = true,
})
local TabMain = Window:AddTab("主页", "home")
local TabStat = Window:AddTab("状态", "activity")

local State = {
	Enabled = false,        -- 总开关
	Radius = 25,            -- 光环范围（studs）
	Interval = 0.1,         -- 每轮扫描间隔（秒）
	StayTime = 0.045,       -- Handle 在敌人身上的停留时间（触发 Touched）
	IncludePlayers = true,  -- 包含其他玩家
	IncludeNPCs = true,     -- 包含 NPC/怪物
	AutoEquip = true,       -- 自动装备武器
	AnchorChar = true,      -- 光环期间角色定身（每轮钉回锚点，Handle 复制不受影响）
	Stat = { Hits = 0, Kills = 0, Targets = 0 },
}

local TargetCache = {}    -- 目标缓存（低频扫描维护）
local CacheStamp = 0

-- 拿当前可用武器 Handle（自动装备）
local function getHandle()
	local char = lp.Character
	if not char then return nil end
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool then
		if not State.AutoEquip then return nil end
		local hum = char:FindFirstChildOfClass("Humanoid")
		local bp = lp:FindFirstChild("Backpack")
		if not hum or not bp then return nil end
		local first = bp:FindFirstChildWhichIsA("Tool")
		if not first then return nil end
		hum:EquipTool(first)
		task.wait(0.15)
		tool = char:FindFirstChildOfClass("Tool")
		if not tool then return nil end
	end
	return tool:FindFirstChild("Handle")
end

-- 目标收集（通用适配：任何带 Humanoid 的 Model，按开关过滤玩家/NPC）
local function collectTargets()
	local myChar = lp.Character
	local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
	if not myRoot then return end
	local r2 = State.Radius * State.Radius
	local seen = {}
	local function consider(model)
		if not model or not model:IsA("Model") or seen[model] then return end
		seen[model] = true
		if model == myChar then return end
		local hum = model:FindFirstChildOfClass("Humanoid")
		if not hum or hum.Health <= 0 then return end
		local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
		if not root or not root:IsA("BasePart") then return end
		local isPlayer = Players:GetPlayerFromCharacter(model) ~= nil
		if isPlayer and not State.IncludePlayers then return end
		if not isPlayer and not State.IncludeNPCs then return end
		local d = root.Position - myRoot.Position
		if d:Dot(d) <= r2 then
			TargetCache[#TargetCache + 1] = { hum = hum, root = root, name = model.Name }
		end
	end
	if State.IncludePlayers then
		for _, p in ipairs(Players:GetPlayers()) do
			if p ~= lp then consider(p.Character) end
		end
	end
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("Model") then consider(d) end
	end
end

local function refreshCache()
	TargetCache = {}
	collectTargets()
	State.Stat.Targets = #TargetCache
end

-- ================= UI =================
local grpMain = TabMain:AddLeftGroupbox("总控")
grpMain:AddToggle("Enabled", {
	Text = "杀戮光环（总开关）",
	Default = false,
	Callback = function(v) State.Enabled = v end,
})
grpMain:AddLabel("快捷键：右Ctrl 显隐界面")

local grpParam = TabMain:AddRightGroupbox("参数")
grpParam:AddSlider("Radius", {
	Text = "光环范围", Default = 25, Min = 5, Max = 100, Rounding = 0, Suffix = "格",
	Callback = function(v) State.Radius = v end,
})
grpParam:AddSlider("Interval", {
	Text = "扫描间隔", Default = 0.1, Min = 0.02, Max = 1, Rounding = 2, Suffix = "秒",
	Callback = function(v) State.Interval = v end,
})
grpParam:AddSlider("StayTime", {
	Text = "停留时间（触发判定）", Default = 0.045, Min = 0.02, Max = 0.15, Rounding = 3, Suffix = "秒",
	Callback = function(v) State.StayTime = v end,
})

local grpFn = TabMain:AddLeftGroupbox("目标")
grpFn:AddToggle("IncludePlayers", { Text = "包含其他玩家", Default = true, Callback = function(v) State.IncludePlayers = v end })
grpFn:AddToggle("IncludeNPCs", { Text = "包含 NPC / 怪物", Default = true, Callback = function(v) State.IncludeNPCs = v end })
grpFn:AddToggle("AutoEquip", { Text = "自动装备武器", Default = true, Callback = function(v) State.AutoEquip = v end })
grpFn:AddToggle("AnchorChar", { Text = "光环期间角色定身（原地不动）", Default = true, Callback = function(v) State.AnchorChar = v end })

local grpStat = TabStat:AddLeftGroupbox("计数")
local lbl = {}
local function makeLabel(grp, key, text)
	lbl[key] = grp:AddLabel(text)
end
makeLabel(grpStat, "Hits", "攻击次数：0")
makeLabel(grpStat, "Kills", "击杀次数：0")
makeLabel(grpStat, "Targets", "范围内目标：0")
makeLabel(grpStat, "Weapon", "当前武器：-")

local RecentLog = {}
local function log(text)
	table.insert(RecentLog, 1, os.date("%H:%M:%S") .. " " .. text)
	if #RecentLog > 8 then table.remove(RecentLog) end
end
local grpLog = TabStat:AddRightGroupbox("日志")
local lblLog = grpLog:AddLabel("-")

task.spawn(function()
	while true do
		task.wait(0.4)
		pcall(function()
			lbl.Hits:SetText("攻击次数：" .. State.Stat.Hits)
			lbl.Kills:SetText("击杀次数：" .. State.Stat.Kills)
			lbl.Targets:SetText("范围内目标：" .. State.Stat.Targets)
			local char = lp.Character
			local tool = char and char:FindFirstChildOfClass("Tool")
			lbl.Weapon:SetText("当前武器：" .. (tool and tool.Name or "无"))
			lblLog:SetText(#RecentLog > 0 and table.concat(RecentLog, "\n") or "-")
		end)
	end
end)

-- ================= 主循环 =================
local stopped = false
g._KA_STOP = function() stopped = true end
g._KA_STATE = State
local vim = game:GetService("VirtualInputManager")

task.spawn(function()
	task.wait(1)
	local lastCache = 0
	local myRoot = nil
	while not stopped do
		if State.Enabled then
			local char = lp.Character
			myRoot = char and char:FindFirstChild("HumanoidRootPart")
			if myRoot then
				-- 角色定身：锚定 HRP，Handle 瞬移的反作用力不会拖动角色
				myRoot.Anchored = State.AnchorChar
				-- 低频刷新目标缓存（0.5s）
				if os.clock() - lastCache > 0.5 then
					lastCache = os.clock()
					refreshCache()
				end
				local handle = getHandle()
				if handle then
					handle.Massless = true -- 武器质量不参与角色物理，防拖拽
				end
				if handle and #TargetCache > 0 then
					local cam = workspace.CurrentCamera
					local vp = cam.ViewportSize
					local cx, cy = vp.X / 2, vp.Y / 2
					for _, t in ipairs(TargetCache) do
						if not State.Enabled then break end
						if t.hum.Parent and t.hum.Health > 0 then
							local pre = t.hum.Health
							-- 点击激活武器攻击状态（伤害由服务器 Touched 判定，需要攻击窗口）
							vim:SendMouseButtonEvent(cx, cy, 0, true, game, 0)
							task.wait(0.06)
							vim:SendMouseButtonEvent(cx, cy, 0, false, game, 0)
							-- Handle 瞬移到敌人（非锚定：客户端网络所有权 → CFrame 复制到服务器 → 远程 Touched 扣血）
							-- HRP 已锚定，Motor6D 拖拽不会移动角色位置
							handle.CFrame = t.root.CFrame * CFrame.new(0, 0, -1.5)
							task.wait(State.StayTime)
							if t.hum.Health <= 0 and pre > 0 then
								State.Stat.Kills += 1
								log("击杀 " .. t.name)
							end
							handle.CFrame = myRoot.CFrame
							State.Stat.Hits += 1
						end
					end
					task.wait(math.max(State.Interval, 0.03))
				else
					task.wait(0.4)
				end
			else
				task.wait(0.5)
			end
		else
			-- 关闭时解除定身
			local char = lp.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then hrp.Anchored = false end
			task.wait(0.3)
		end
	end
end)

Library:Notify("杀戮光环 v1.0 已加载", 4)
print("[杀戮光环] v1.0 加载完成")
