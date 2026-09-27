--[[
	重铸死亡 辅助 v1.0  ·  Obsidian UI（全中文）
	============================================
	游戏：[生辉1980年代] 重铸死亡（placeId 130584743573563）
	功能：
	1. 自爆透视——只高亮自爆僵尸（Bomber，模型带 BoolValue"Bomber" 标记）
	2. 近战杀戮光环（全近战通用）——自动探测/装备任何带 Remotes.MeleeEvent 的 Tool，
	   高频 FireServer({Type="Attack"})，服务器区域检测自动扣血
	3. 自动瞬移清怪（可选）——瞬移到最近怪旁打完回原位
	协议来源：客户端脚本反编译（Project Real Luau Decompiler）
	  - 攻击入口：Tool.Remotes.MeleeEvent:FireServer({Type = "Attack"})
	  - 伤害/范围配置（Damage/RegionSize 等 NumberValue）在服务器侧读取，客户端改无效 → 武器 mod 不可行
]]

-- 防重复加载
local g = getgenv()
if g._RD_STOP then pcall(g._RD_STOP) end

local Players = game:GetService("Players")
local lp = Players.LocalPlayer

-- Obsidian UI 加载
local repo = "https://raw.githubusercontent.com/mstudio45/Obsidian/main/"
local library = loadstring(game:HttpGet(repo .. "Library.lua"))()
local window = library:CreateWindow({
	Title = "重铸死亡 辅助 v1.0",
	Footer = "v1.0 · 自爆透视 + 近战光环",
	Center = true,
	AutoShow = true,
})
local TabMain = window:AddTab("主页", "home")
local TabStat = window:AddTab("状态", "activity")

local State = {
	Enabled = false,       -- 近战光环总开关
	AttackInterval = 0.25, -- 攻击间隔（服务器有节流，0.25 起步）
	TpEnabled = false,     -- 自动瞬移清怪
	EspEnabled = true,     -- 自爆透视
	Stat = { Attacks = 0, Kills = 0, Bombers = 0 },
}
local Blacklist = {}

-- 帧等待延迟（Heartbeat 让出，不忙等占核；hook 全局 wait 会卡死游戏）
local RunService = game:GetService("RunService")
local function delay(t)
	local t0 = os.clock()
	while os.clock() - t0 < t do
		RunService.Heartbeat:Wait()
	end
end

local function log(text)
	print("[重铸死亡] " .. text)
end

-- ================= UI =================
local grpMain = TabMain:AddLeftGroupbox("功能")
grpMain:AddToggle("EspEnabled", {
	Text = "自爆透视（只标 Bomber 自爆僵尸）",
	Default = true,
	Callback = function(v)
		State.EspEnabled = v
		if not v then
			-- 关闭时清理全部高亮
			for _, d in ipairs(workspace:GetChildren()) do
				if d:IsA("Model") and d:FindFirstChild("Bomber") then
					local hl = d:FindFirstChild("_rd_esp")
					if hl then hl:Destroy() end
					local bb = d:FindFirstChild("_rd_tag")
					if bb then bb:Destroy() end
				end
			end
		end
	end,
})
grpMain:AddToggle("Enabled", {
	Text = "近战杀戮光环（自动装备近战）",
	Default = false,
	Callback = function(v)
		State.Enabled = v
		if not v then
			local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
			if hrp then hrp.Anchored = false end
		end
	end,
})
grpMain:AddToggle("TpEnabled", {
	Text = "自动瞬移清怪（传送到最近怪旁，打完回原位）",
	Default = false,
	Callback = function(v) State.TpEnabled = v end,
})

local grpParam = TabMain:AddRightGroupbox("参数")
grpParam:AddSlider("AttackInterval", {
	Text = "攻击间隔（服务器有节流，过低会丢包）", Default = 0.25, Min = 0.15, Max = 1, Rounding = 2, Suffix = "秒",
	Callback = function(v) State.AttackInterval = v end,
})
grpParam:AddSlider("TpRadius", {
	Text = "瞬移索怪范围", Default = 100, Min = 10, Max = 1000, Rounding = 0, Suffix = "格",
	Callback = function(v) State.TpRadius = v end,
})
grpParam:AddLabel("武器 mod：伤害配置在服务器侧读取，客户端改无效，故不做")
grpParam:AddLabel("近战识别：任何带 Remotes.MeleeEvent 的 Tool 自动装备")

local grpStat = TabStat:AddLeftGroupbox("计数")
local lbl = {}
local function makeLabel(key, text)
	lbl[key] = grpStat:AddLabel(text)
end
makeLabel("Attacks", "攻击次数：0")
makeLabel("Zombies", "剩余僵尸：-")
makeLabel("Bombers", "自爆怪数量：0")

-- ================= 近战武器通用探测 =================
local function getMelee()
	local char = lp.Character
	if not char then return nil end
	-- 手上优先
	local tool = char:FindFirstChildOfClass("Tool")
	if tool and tool:FindFirstChild("Remotes") and tool.Remotes:FindFirstChild("MeleeEvent") then
		return tool.Remotes.MeleeEvent
	end
	-- 背包找近战并装备
	local bp = lp:FindFirstChild("Backpack")
	if bp then
		for _, t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") and t:FindFirstChild("Remotes") and t.Remotes:FindFirstChild("MeleeEvent") then
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum then hum:EquipTool(t) end
				return nil -- 本轮跳过，装备后下一轮生效
			end
		end
	end
	return nil
end

-- ================= 自爆透视 =================
local function espStep()
	if not State.EspEnabled then return end
	local count = 0
	for _, d in ipairs(workspace:GetChildren()) do
		if d:IsA("Model") then
			local marker = d:FindFirstChild("Bomber")
			if marker and marker:IsA("BoolValue") then
				local h = d:FindFirstChildOfClass("Humanoid")
				if h and h.Health > 0 then
					count += 1
					local hl = d:FindFirstChild("_rd_esp")
					if not hl then
						hl = Instance.new("Highlight")
						hl.Name = "_rd_esp"
						hl.FillColor = Color3.fromRGB(255, 40, 40)
						hl.OutlineColor = Color3.fromRGB(255, 120, 0)
						hl.FillTransparency = 0.6
						hl.OutlineTransparency = 0
						hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
						hl.Parent = d
					end
					-- 名字标注（自爆 + 距离）
					local head = d:FindFirstChild("Head") or d:FindFirstChild("Torso")
					if head then
						local bb = d:FindFirstChild("_rd_tag")
						if not bb then
							bb = Instance.new("BillboardGui")
							bb.Name = "_rd_tag"
							bb.Size = UDim2.new(0, 120, 0, 24)
							bb.StudsOffset = Vector3.new(0, 2.5, 0)
							bb.AlwaysOnTop = true
							bb.Adornee = head
							bb.Parent = d
							local tl = Instance.new("TextLabel")
							tl.Name = "Label"
							tl.Size = UDim2.new(1, 0, 1, 0)
							tl.BackgroundTransparency = 1
							tl.TextColor3 = Color3.fromRGB(255, 80, 40)
							tl.TextStrokeTransparency = 0.3
							tl.Font = Enum.Font.GothamBold
							tl.TextSize = 14
							tl.Parent = bb
						end
						local lblText = bb:FindFirstChild("Label")
						if lblText and head then
							local dist = (head.Position - lp.Character.HumanoidRootPart.Position).Magnitude
							lblText.Text = string.format("☠ 自爆 %.0fm", dist)
						end
					end
				else
					-- 死亡清理
					local hl = d:FindFirstChild("_rd_esp")
					if hl then hl:Destroy() end
					local bb = d:FindFirstChild("_rd_tag")
					if bb then bb:Destroy() end
				end
			else
				-- 非自爆怪清理（防止怪物重生换模型残留）
				local hl = d:FindFirstChild("_rd_esp")
				if hl then hl:Destroy() end
				local bb = d:FindFirstChild("_rd_tag")
				if bb then bb:Destroy() end
			end
		end
	end
	State.Stat.Bombers = count
end

-- ================= 找最近怪（瞬移索怪） =================
local function findNearestEnemy(maxDist)
	local char = lp.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	local best, bd, bRoot = nil, maxDist, nil
	for _, d in ipairs(workspace:GetChildren()) do
		if d:IsA("Model") and d:FindFirstChild("IsEnemy") and not Blacklist[d] then
			local h = d:FindFirstChildOfClass("Humanoid")
			if h and h.Health > 0 then
				local root = d:FindFirstChild("HumanoidRootPart") or d:FindFirstChild("Torso")
				if root then
					local dist = (root.Position - hrp.Position).Magnitude
					if dist < bd then
						best, bd, bRoot = d, dist, root
					end
				end
			end
		end
	end
	return best, bRoot
end

-- ================= 主循环 =================
local stopped = false
g._RD_STOP = function() stopped = true end
g._RD_STATE = State

task.spawn(function()
	task.wait(1)
	local lastEsp = 0
	while not stopped do
		if State.Enabled then
			local char = lp.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hum and hum.Health > 0 and hrp and hrp.Parent then
				local meleeEvent = getMelee()
				if meleeEvent then
					-- 瞬移索怪（可选）：找最近怪，瞬移到旁 3.5 格
					if State.TpEnabled then
						local target, tRoot = findNearestEnemy(State.TpRadius)
						if target and tRoot then
							hrp.CFrame = CFrame.lookAt(tRoot.Position + tRoot.CFrame.LookVector * 3.5, tRoot.Position)
						end
					end
					-- 发攻击（服务器区域检测自动扣血）
					meleeEvent:FireServer({ Type = "Attack" })
					State.Stat.Attacks += 1
					delay(State.AttackInterval)
				else
					log("未找到近战武器（需要带 MeleeEvent 的 Tool）")
					task.wait(1.5)
				end
			else
				task.wait(0.5)
			end
		else
			task.wait(0.3)
		end
	end
end)

-- ================= ESP 调度循环（独立于光环总开关） =================
-- 修复：v1.0 的 espStep 从未被调用导致透视不生效
task.spawn(function()
	task.wait(1.2)
	while not stopped do
		local ok, err = pcall(espStep)
		if not ok then log("ESP错误: " .. tostring(err):sub(1, 60)) end
		-- 剩余僵尸显示
		local remain = workspace:FindFirstChild("RemainZombie")
		if remain and remain:IsA("NumberValue") then
			pcall(function() lbl.Zombies:SetText("剩余僵尸：" .. tostring(math.floor(remain.Value))) end)
		end
		pcall(function() lbl.Attacks:SetText("攻击次数：" .. State.Stat.Attacks) end)
		pcall(function() lbl.Bombers:SetText("自爆怪数量：" .. State.Stat.Bombers) end)
		task.wait(0.4)
	end
end)

