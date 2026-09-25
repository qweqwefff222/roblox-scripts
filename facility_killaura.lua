--[[
	杀戮光环 v1.7 · 在设施翻新中生存（placeId 107946054053457）· Obsidian 全中文
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
	Footer = "v1.7 · 设施生存",
	ToggleKeybind = Enum.KeyCode.RightControl,
	Center = true,
	AutoShow = true,
})
local TabMain = Window:AddTab("主页", "home")
local TabStat = Window:AddTab("状态", "activity")

local State = {
	Enabled = false,        -- 总开关
	TP_Enabled = true,      -- 瞬移光环：瞬移到怪旁打（大范围扫图），打完回原位
	TP_Radius = 40,         -- 瞬移光环范围（studs）
	Walk_Enabled = true,    -- 走动光环：不瞬移，角色完全由你控制，只清身边怪
	Walk_Radius = 12,       -- 走动光环范围（上限 14 = 服务器命中距离校验实测值）
	Interval = 0.25,        -- 共享挥击节奏（秒）：两光环共用 1 次 PlaySound/轮，服务器统计挥击频率踢人，≥0.22 模拟正常连点
	Stat = { Hits = 0, Kills = 0, Targets = 0, Dna = 0 },
}
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
		if not v then
			local hrp = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
			if hrp then hrp.Anchored = false end
		end
	end,
})
grpMain:AddToggle("TP_Enabled", {
	Text = "瞬移光环（传送到怪旁打，打完回原位）",
	Default = true,
	Callback = function(v) State.TP_Enabled = v end,
})
grpMain:AddToggle("Walk_Enabled", {
	Text = "走动光环（不瞬移，自由走动清身边怪）",
	Default = true,
	Callback = function(v) State.Walk_Enabled = v end,
})
grpMain:AddLabel("快捷键：右Ctrl 显隐界面")

local grpParam = TabMain:AddRightGroupbox("参数")
grpParam:AddSlider("TPRadius", {
	Text = "瞬移光环范围（最高 1000，越大清图越广、每轮越慢）", Default = 100, Min = 5, Max = 1000, Rounding = 0, Suffix = "格",
	Callback = function(v) State.TP_Radius = v end,
})
grpParam:AddSlider("WalkRadius", {
	Text = "走动光环范围（不瞬移，上限14=服务器命中校验）", Default = 12, Min = 3, Max = 14, Rounding = 0, Suffix = "格",
	Callback = function(v) State.Walk_Radius = v end,
})
grpParam:AddSlider("Interval", {
	Text = "挥击节奏（≥0.22 安全，0.1 持续会被踢）", Default = 0.25, Min = 0.2, Max = 2, Rounding = 2, Suffix = "秒",
	Callback = function(v) State.Interval = v end,
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
-- 通用近战武器探测：任何带 HitEvent 的 Tool（刀/斧/棒等，协议同源）
-- 优先用手上已装备的；手上没有近战则从背包自动装备一把（下一轮生效）
local function getMelee()
	local char = lp.Character
	if not char then return nil end
	local tool = char:FindFirstChildOfClass("Tool")
	if tool and tool:FindFirstChild("HitEvent") then
		local hitEvent = tool:FindFirstChild("HitEvent")
		local playSound = tool:FindFirstChild("PlaySound")
		local handle = tool:FindFirstChild("Handle")
		-- 挥击音效通用探测：Handle 下第一个 Sound（Knife 是 Swing，其他武器名字可能不同）
		local swing = handle and (handle:FindFirstChild("Swing") or handle:FindFirstChildWhichIsA("Sound"))
		if hitEvent and playSound and swing then
			return hitEvent, playSound, swing
		end
		return nil
	end
	-- 手上不是近战（枪/空手）：从背包找近战装备
	local bp = lp:FindFirstChild("Backpack")
	if bp then
		for _, t in ipairs(bp:GetChildren()) do
			if t:IsA("Tool") and t:FindFirstChild("HitEvent") then
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum then
					hum:EquipTool(t)
				end
				break
			end
		end
	end
	return nil
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
			AdaptiveInterval = math.max(State.Interval, 0.25) * (1 + backoffLevel)
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
						AdaptiveInterval = math.max(State.Interval, 0.25) * (1 + backoffLevel)
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
				-- 角色位置完全由玩家控制（走动光环零干预；瞬移光环打完自动回原位）
				if hrp.Anchored then hrp.Anchored = false end
				local hitEvent, playSound, swing = getMelee()
				if hitEvent then
					-- 双光环目标收集（带 Enemy 标记通用适配）
					-- 走动光环：Walk_Radius 内原地直发（角色不动）；瞬移光环：TP_Radius 内逐怪就位打完回原位
					-- 14 格内的怪归走动光环（不瞬移），14 格外的归瞬移光环（服务器命中校验上限 ~16）
					local walkTargets, tpTargets = {}, {}
					local myPos = hrp.Position
					local wr2 = State.Walk_Radius * State.Walk_Radius
					local tr2 = State.TP_Radius * State.TP_Radius
					for _, d in ipairs(workspace:GetDescendants()) do
						if d:IsA("Model") and d:FindFirstChild("Enemy") and not Blacklist[d] then
							local h = d:FindFirstChildOfClass("Humanoid")
							if h and h.Health > 0 then
								local root = d:FindFirstChild("HumanoidRootPart") or d:FindFirstChild("Torso") or d:FindFirstChildWhichIsA("BasePart")
								if root then
									local dv = root.Position - myPos
									local d2 = dv:Dot(dv)
									if State.Walk_Enabled and d2 <= wr2 then
										walkTargets[#walkTargets + 1] = { model = d, hum = h, root = root, name = d.Name }
									elseif State.TP_Enabled and d2 <= tr2 then
										tpTargets[#tpTargets + 1] = { model = d, hum = h, root = root, name = d.Name }
									end
								end
							end
						end
					end
					State.Stat.Targets = #walkTargets + #tpTargets
					if State.Stat.Targets > 0 then
						-- 共享挥击：每轮只发 1 次 PlaySound（服务器统计挥击频率踢人，两光环共用节拍）
						playSound:FireServer("Play", swing)
						-- 1) 走动光环：原地直发，角色零干预
						for _, t in ipairs(walkTargets) do
							if not State.Enabled then break end
							if t.hum.Parent and t.hum.Health > 0 then
								local pre = t.hum.Health
								hitEvent:FireServer(t.model, t.hum)
								State.Stat.Hits += 1
								if t.hum.Health <= 0 and pre > 0 then
									State.Stat.Kills += 1
									Blacklist[t.model] = true
									log("击杀 " .. t.name)
								end
							end
						end
						-- 2) 瞬移光环：逐怪就位打，全部打完回原位
						if #tpTargets > 0 then
							local returnCf = hrp.CFrame
							for _, t in ipairs(tpTargets) do
								if not State.Enabled then break end
								if t.hum.Parent and t.hum.Health > 0 then
									local pre = t.hum.Health
									hrp.CFrame = CFrame.lookAt(t.root.Position + t.root.CFrame.LookVector * 3.5, t.root.Position)
									hitEvent:FireServer(t.model, t.hum)
									State.Stat.Hits += 1
									if t.hum.Health <= 0 and pre > 0 then
										State.Stat.Kills += 1
										Blacklist[t.model] = true
										log("击杀 " .. t.name)
									end
								end
							end
							hrp.CFrame = returnCf
						end
					end
					delay(math.max(AdaptiveInterval or State.Interval, 0.2))
				else
					log("未找到近战武器（需要带 HitEvent 的 Tool，会自动装备）")
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

Library:Notify("杀戮光环 v1.7 已加载", 4)
print("[杀戮光环] v1.7 加载完成")
