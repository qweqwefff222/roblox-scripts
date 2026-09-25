--[[
	杀戮光环 v1.2 · 在设施翻新中生存（placeId 107946054053457）· Obsidian 全中文
	协议（反编译+实测实锤）：
	  Knife.HitEvent:FireServer(怪Model, 怪Humanoid)   —— 一刀 50 伤害
	  Knife.PlaySound:FireServer("Play", Handle.Swing) —— 挥击音效（伴随发送）
	  敌人判定：怪 Model 里有 "Enemy" 子对象
	  服务器节流：0.05s 有丢包（部分 0）、0.2s 起全中 → 默认 0.1s
	  反作弊：kick 为服务器直接 player:Kick()（客户端无 kick 代码可 hook），
	          规避方式 = 攻击频率限制（内置安全上限）
	无冷却：可选 hook wait/task.wait（游戏本地冷却失效；本脚本节奏用忙等不受影响）
	通用适配：目标 = 范围内任何带 "Enemy" 的 Model + Humanoid（不硬编码怪名）
]]

local g = getgenv()
if g._KA2_STOP then g._KA2_STOP() end

local Players = game:GetService("Players")
local lp = Players.LocalPlayer

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/Library.lua"))()
local Window = Library:CreateWindow({
	Title = "杀戮光环",
	Footer = "v1.2 · 设施生存",
	ToggleKeybind = Enum.KeyCode.RightControl,
	Center = true,
	AutoShow = true,
})
local TabMain = Window:AddTab("主页", "home")
local TabStat = Window:AddTab("状态", "activity")

local State = {
	Enabled = false,        -- 总开关
	Radius = 30,            -- 光环范围（studs）
	Interval = 0.1,         -- 攻击间隔（秒；<0.05 服务器会丢包）
	AnchorChar = true,      -- 定身（瞬移清怪不被围攻拖走）
	Stat = { Hits = 0, Kills = 0, Targets = 0, Dna = 0 },
}
local AnchorPos = nil    -- 定身锚点
local StandPos = nil     -- 站桩点（定身关闭时钉位用：开启光环时自动记录当前位置）
local Blacklist = {}     -- 击杀/失效目标短名单（防重复选死目标）

-- 帧等待延迟（不忙等占核；hook 全局 wait 会导致游戏 Lua 调度器卡死——已移除该功能，
-- 本脚本直发 remote 天然绕过本地冷却，无需 hook）
local RunService = game:GetService("RunService")
local function delay(t)
	local t0 = os.clock()
	while os.clock() - t0 < t do
		RunService.Heartbeat:Wait()
	end
end

-- ================= UI =================
local grpMain = TabMain:AddLeftGroupbox("总控")
grpMain:AddToggle("Enabled", {
	Text = "杀戮光环（总开关）",
	Default = false,
	Callback = function(v)
		State.Enabled = v
		if v and not State.AnchorChar then
			StandPos = nil -- 站桩模式每次开启都在当前位置重新站桩
		end
		if v then
			local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
			AnchorPos = hrp and hrp.Position or nil
		else
			AnchorPos = nil
			local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
			if hrp then hrp.Anchored = false end
		end
	end,
})
grpMain:AddButton({
	Text = "以当前位置重新定身",
	Func = function()
		local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
		AnchorPos = hrp and hrp.Position or nil
		log("定身锚点已更新")
	end,
})
grpMain:AddLabel("快捷键：右Ctrl 显隐界面")

local grpParam = TabMain:AddRightGroupbox("参数")
grpParam:AddSlider("Radius", {
	Text = "光环范围", Default = 30, Min = 10, Max = 80, Rounding = 0, Suffix = "格",
	Callback = function(v) State.Radius = v end,
})
grpParam:AddSlider("Interval", {
	Text = "攻击间隔（<0.05 会丢包）", Default = 0.1, Min = 0.05, Max = 1, Rounding = 2, Suffix = "秒",
	Callback = function(v) State.Interval = v end,
})
grpParam:AddToggle("AnchorChar", {
	Text = "定身挂机（开=瞬移清怪钉回锚点 / 关=站桩不瞬移，原地清怪14格内）",
	Default = true,
	Callback = function(v)
		State.AnchorChar = v
		if not v then
			StandPos = nil -- 切到站桩模式：下次循环在当前位置重新站桩
		end
	end,
})
grpParam:AddLabel("无冷却：直发协议已绕过本地冷却，无需 hook")
grpParam:AddLabel("（hook 全局 wait 会卡死游戏，已移除该选项）")

local grpStat = TabStat:AddLeftGroupbox("计数")
local lbl = {}
local function makeLabel(key, text)
	lbl[key] = grpStat:AddLabel(text)
end
makeLabel("Hits", "攻击次数：0")
makeLabel("Kills", "击杀次数：0")
makeLabel("Targets", "范围内目标：0")
makeLabel("Weapon", "武器：-")

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
			lbl.Weapon:SetText("武器：" .. (tool and tool.Name or "无"))
			lblLog:SetText(#RecentLog > 0 and table.concat(RecentLog, "\n") or "-")
		end)
	end
end)

-- ================= 武器 =================
local function getKnife()
	local char = lp.Character
	if not char then return nil end
	local knife = char:FindFirstChild("Knife")
	if not knife then
		local bp = lp:FindFirstChild("Backpack")
		knife = bp and bp:FindFirstChild("Knife")
		if not knife then return nil end
		local hum = char:FindFirstChildOfClass("Humanoid")
		if not hum then return nil end
		hum:EquipTool(knife)
		delay(0.15)
		knife = char:FindFirstChild("Knife")
		if not knife then return nil end
	end
	local hitEvent = knife:FindFirstChild("HitEvent")
	local playSound = knife:FindFirstChild("PlaySound")
	local handle = knife:FindFirstChild("Handle")
	local swing = handle and handle:FindFirstChild("Swing")
	if not hitEvent or not playSound or not swing then return nil end
	return hitEvent, playSound, swing
end

-- ================= 服务器反馈监控（TextEvent = 反作弊警告通道）=================
-- "Cooldown" = 攻击过快警告 → 自动退避拉长间隔；"Message" 含踢出/封禁字样 → 立即停机保号
local stopped = false
local AdaptiveInterval = nil -- 自适应间隔（nil=用用户设定值）
local backoffLevel = 0
task.spawn(function()
	local textEvent = game:GetService("ReplicatedStorage"):WaitForChild("TextEvent", 10)
	if not textEvent then return end
	textEvent.OnClientEvent:Connect(function(kind, text, c3, c4)
		local t = tostring(text or "")
		if kind == "Cooldown" then
			-- 攻击过快警告：退避
			backoffLevel = math.min(backoffLevel + 1, 6)
			AdaptiveInterval = math.max(State.Interval, 0.1) * (1 + backoffLevel)
			log("服务器冷却警告（间隔提至 " .. string.format("%.2f", AdaptiveInterval) .. "s）：" .. t:sub(1, 40))
		elseif kind == "Message" then
			local low = t:lower()
			if low:find("kick", 1, true) or low:find("ban", 1, true) or low:find("cheat", 1, true) or low:find("exploit", 1, true) or low:find("detect", 1, true) then
				log("⚠ 检测警告，停止攻击保号：" .. t:sub(1, 50))
				State.Enabled = false
				AdaptiveInterval = nil
				backoffLevel = 0
			else
				log("服务器消息：" .. t:sub(1, 50))
			end
		end
	end)
	-- 间隔自适应恢复：无警告 10s 后逐步回落到用户设定值
	task.spawn(function()
		while not stopped do
			delay(2)
			if AdaptiveInterval then
				if os.clock() - (g._KA2_LASTWARN or 0) > 10 then
					backoffLevel = math.max(0, backoffLevel - 1)
					if backoffLevel == 0 then
						AdaptiveInterval = nil
						log("间隔已恢复正常")
					else
						AdaptiveInterval = math.max(State.Interval, 0.1) * (1 + backoffLevel)
					end
				end
			end
		end
	end)
	-- 记录警告时刻（供恢复逻辑）
	local origConnect = true
	g._KA2_LASTWARN = 0
	textEvent.OnClientEvent:Connect(function()
		g._KA2_LASTWARN = os.clock()
	end)
end)

-- ================= 主循环 =================
g._KA2_STOP = function() stopped = true end
g._KA2_STATE = State

task.spawn(function()
	delay(1)
	local hrp = nil
	while not stopped do
		if State.Enabled then
			local char = lp.Character
			hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and hrp.Parent then
				-- 位置钉定（HRP 保持非锚定以维持网络所有权，Handle/协议复制才有效）
				if State.AnchorChar and AnchorPos then
					-- 定身模式：钉回用户锚点
					hrp.Anchored = false
					hrp.CFrame = CFrame.new(AnchorPos)
					hrp.AssemblyLinearVelocity = Vector3.zero
				elseif not State.AnchorChar then
					-- 站桩模式：钉回开启点（防怪推搡位移），角色零移动原地清怪
					if StandPos == nil then
						StandPos = hrp.Position
						log("站桩点已记录")
					end
					hrp.Anchored = false
					hrp.CFrame = CFrame.new(StandPos)
					hrp.AssemblyLinearVelocity = Vector3.zero
				end
				local hitEvent, playSound, swing = getKnife()
				if hitEvent then
					-- 收集范围内活怪（带 Enemy 标记，通用适配）
					local targets = {}
					-- 站桩模式（定身关）：角色不动，服务器命中距离上限 ~16 studs（实测 16 命中 18 失效）
					-- 有效攻击半径取 14 留余量；范围外的怪会自己走近进入范围
					local effRadius = State.AnchorChar and State.Radius or math.min(State.Radius, 14)
					local r2 = effRadius * effRadius
					local base = State.AnchorChar and AnchorPos or (hrp.Position)
					for _, d in ipairs(workspace:GetDescendants()) do
						if d:IsA("Model") and d:FindFirstChild("Enemy") and not Blacklist[d] then
							local h = d:FindFirstChildOfClass("Humanoid")
							if h and h.Health > 0 then
								local root = d:FindFirstChild("HumanoidRootPart") or d:FindFirstChild("Torso") or d:FindFirstChildWhichIsA("BasePart")
								if root then
									local dv = root.Position - base
									if dv:Dot(dv) <= r2 then
										targets[#targets + 1] = { model = d, hum = h, root = root, name = d.Name }
									end
								end
							end
						end
					end
					State.Stat.Targets = #targets
					-- 逐个攻击
					for _, t in ipairs(targets) do
						if not State.Enabled then break end
						if t.hum.Parent and t.hum.Health > 0 then
							local pre = t.hum.Health
							if State.AnchorChar then
								-- 定身模式：瞬移到怪旁 3.5 studs 面朝怪（服务器距离校验范围内）
								hrp.CFrame = CFrame.lookAt(t.root.Position + t.root.CFrame.LookVector * 3.5, t.root.Position)
								delay(0.08) -- 就位
							end
							-- 站桩模式：角色零移动，原地直发协议（目标已按 14 studs 过滤）
							playSound:FireServer("Play", swing)
							hitEvent:FireServer(t.model, t.hum)
							State.Stat.Hits += 1
							delay(0.05)
							if t.hum.Health <= 0 and pre > 0 then
								State.Stat.Kills += 1
								Blacklist[t.model] = true
								log("击杀 " .. t.name)
							end
							-- 回锚点（定身模式下攻击间不被拖走）
							if State.AnchorChar and AnchorPos then
								hrp.CFrame = CFrame.new(AnchorPos)
							end
						end
					end
					delay(math.max(AdaptiveInterval or State.Interval, 0.05))
				else
					log("未找到 Knife（需要背包有刀）")
					delay(1)
				end
			else
				delay(0.5)
			end
		else
			delay(0.3)
		end
	end
end)

Library:Notify("杀戮光环 v1.2 已加载", 4)
print("[杀戮光环] v1.2 加载完成")
