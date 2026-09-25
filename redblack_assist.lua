--[[
	红黑据点战辅助 v1.5  ·  WindUI
	================================
	游戏：两队（Red/Black）A/B/C 据点占领射击战
	v1.5 变更：修 Aimbot 相机锁"锁的不是头"——
	aimStep 从 RenderStepped 挪到 BindToRenderStep(Camera+1)，
	RenderStepped 时写入的 cam.CFrame 会被默认相机脚本覆盖，
	实测渲染帧与头平均偏差 1.79°；改后锁定在渲染前最后写入生效
	v1.4 变更：
	1. 修拖窗口粘鼠标：watchdog 不再在拖动中途清 WindUI.CurrentInput
	   （鼠标按住期间不干预，只在松开后兜底恢复）
	2. IsMouseButtonPressed 在注入环境抛错 → 改 InputBegan/Ended 事件跟踪
	加载：
	loadstring(game:HttpGet("https://raw.githubusercontent.com/qweqwefff222/dropshipping-hub/main/redblack_assist.lua"))()

	功能：
	· 战斗 —— Aimbot（FOV 锁定 / 相机锁 & 鼠标移动双模式 / 提前量 / 可含 NPC）、TriggerBot（VIM）、No Spread
	· 视觉 —— 敌人 ESP（Chams 队伍色高亮 + 血条/名字/距离；NPC 橙色）、准星 FOV 圈
	· 据点 —— A/B/C 占领百分比 / 双方人数 / 争夺状态 实时面板
	· 移动 —— WalkSpeed / JumpPower
	· 枪械 —— 无后座/无散布/弹速/射速/伤害倍率（Config 直改）
]]

local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()

-- ================= 服务 =================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local lp = Players.LocalPlayer
local VirtualUser = game:GetService("VirtualUser")
-- VIM 实测才能触发游戏开火输入（VirtualUser 无效）
local VirtualInputManager = (function()
	local ok, v = pcall(function() return game:GetService("VirtualInputManager") end)
	return ok and v or nil
end)()

-- ================= live-reload 残留清理（旧循环/旧 FOV 圈/旧窗口/旧 ESP） =================
do
	local g = getgenv()
	pcall(function() if g._RBA_LOOP then g._RBA_LOOP:Disconnect() end end)
	pcall(function() if g._RBA_FOV then g._RBA_FOV:Remove() end end)
	pcall(function() if g._RBA_WIN then g._RBA_WIN:Destroy() end end)
	pcall(function() RunService:UnbindFromRenderStep("RBA_AIM") end)
	g._RBA_LOOP, g._RBA_FOV, g._RBA_WIN = nil, nil, nil
	pcall(function()
		local cs = Workspace:FindFirstChild("CharactersSpawned")
		if cs then
			for _, d in ipairs(cs:GetDescendants()) do
				if d.Name == "_assHL" then d:Destroy() end
			end
		end
		local pg = lp:FindFirstChildOfClass("PlayerGui")
		if pg then
			for _, d in ipairs(pg:GetDescendants()) do
				if d.Name == "_assBB" then d:Destroy() end
			end
		end
	end)
end

-- 相机每次动态取（重生/切场景时 CurrentCamera 会短暂为 nil 或被替换）
local function getCam()
	return Workspace.CurrentCamera
end

-- ================= 状态 =================
local State = {
	-- aimbot
	Aimbot = false, AimFov = 90, AimSmooth = 0.28, AimPart = "Head", AimLead = true,
	AimLeadFactor = 1.0, AimMode = "Camera锁", ShowFov = true, AimNpcs = false,
	-- trigger
	Trigger = false, TriggerHold = 0.08,
	-- spread
	NoSpread = false,
	-- esp
	Esp = false, Chams = false, EspMaxDist = 3000, EspNpcs = false,
	-- movement
	WalkSpeed = 16, JumpPower = 50, MoveEnabled = false,
	-- 枪械修改
	NoRecoil = false, NoSpreadCfg = false, InstantReload = false,
	DamageBoost = false, DamageMult = 3,
	BulletSpeedOn = false, BulletSpeedVal = 6000,
	FireRateOn = false, FireRateMult = 1.5,
	-- fov circle
	FovColorR = 255, FovColorG = 80, FovColorB = 80,
}

local _origCalcSpread = nil   -- 原 CalculateNewSpread
local _fovCircle = nil        -- Drawing 圈
local _espCache = {}          -- [Model] = {hl, bb, lbls...}
local _triggerHolding = false
local _lastTriggerAt = 0

-- ================= 工具 =================
local function notify(title, content, icon, dur)
	pcall(function()
		WindUI:Notify({ Title = title, Content = content, Icon = icon or "info", Duration = dur or 3 })
	end)
end

local function getPCRoot()
	local cs = Workspace:FindFirstChild("CharactersSpawned")
	return cs and cs:FindFirstChild("PlayerCharacters")
end

local function charOwnerName(model)
	-- PlayerCharacters 下子模型 Name == 玩家名
	if model and Players:FindFirstChild(model.Name) then return model.Name end
	return nil
end

local function getNpcRoot()
	local cs = Workspace:FindFirstChild("CharactersSpawned")
	return cs and cs:FindFirstChild("Npcs")
end

-- NPC 按队伍分文件夹：Npcs/Black、Npcs/Red（Major/Bunker/Alate/Soldier，父文件夹名 = 队伍）
local function isEnemyNpc(model)
	local folder = model and model.Parent
	if not folder or (folder.Name ~= "Black" and folder.Name ~= "Red") then return false end
	if not folder.Parent or folder.Parent.Name ~= "Npcs" then return false end
	return lp.Team ~= nil and folder.Name ~= lp.Team.Name
end

local function isEnemyModel(model)
	if isEnemyNpc(model) then return true end
	local name = charOwnerName(model)
	if not name or name == lp.Name then return false end
	local p = Players:FindFirstChild(name)
	return p ~= nil and p.Team ~= nil and lp.Team ~= nil and p.Team ~= lp.Team
end

local function alive(model)
	local h = model and model:FindFirstChildOfClass("Humanoid")
	return h and h.Health > 0, h
end

local function aimPoint(model)
	local part = model:FindFirstChild(State.AimPart == "Head" and "Head" or "HumanoidRootPart")
	if not part then part = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head") end
	return part
end

-- ================= No Spread =================
local function applyNoSpread()
	local ok, DHC = pcall(require,
		game.StarterPlayer.StarterPlayerScripts.Client.Services.DynamicCrossHairController)
	if not ok or not DHC then return false end
	if State.NoSpread and not _origCalcSpread then
		-- live-reload 防双层 hook：优先恢复 genv 里存的最原始函数
		if getgenv()._RBA_SPREAD_ORIG then
			_origCalcSpread = getgenv()._RBA_SPREAD_ORIG
		else
			_origCalcSpread = DHC.CalculateNewSpread
		end
		getgenv()._RBA_SPREAD_ORIG = _origCalcSpread
		DHC.CalculateNewSpread = function(...)
			if State.NoSpread then return 0 end
			return _origCalcSpread(...)
		end
		-- 顺带把准星参数压平（部分实现直接读表）
		pcall(function()
			DHC:SetCrossHairSettings({ MaxSpread = 0, MinSpread = 0, increasePerSecond = 0, decreasePerSecond = 9999 })
		end)
	elseif not State.NoSpread and _origCalcSpread then
		pcall(function()
			DHC.CalculateNewSpread = getgenv()._RBA_SPREAD_ORIG or _origCalcSpread
			DHC:SetCrossHairSettings({ MaxSpread = 6, MinSpread = 1, increasePerSecond = 4, decreasePerSecond = 4 })
		end)
		getgenv()._RBA_SPREAD_ORIG = nil
		_origCalcSpread = nil
	end
	return true
end

-- ================= Aimbot =================
local function pickTarget()
	local cam = getCam()
	if not cam then return nil end
	local best, bestD = nil, State.AimFov
	local vp = cam.ViewportSize
	local center = vp / 2
	local function consider(model)
		if not model:IsA("Model") or not isEnemyModel(model) then return end
		if not alive(model) then return end
		local part = aimPoint(model)
		if not part then return end
		local pos, onScreen = cam:WorldToViewportPoint(part.Position)
		if not (onScreen and pos.Z > 0) then return end
		local d = (Vector2.new(pos.X, pos.Y) - center).Magnitude
		-- NPC 目标加 30% 屏幕距离惩罚：同屏优先玩家，NPC 更近时也会锁定
		if not Players:FindFirstChild(model.Name) then d = d * 1.3 end
		if d < bestD then best, bestD = model, d end
	end
	for _, model in ipairs(getPCRoot() and getPCRoot():GetChildren() or {}) do
		consider(model)
	end
	if State.AimNpcs then
		local nroot = getNpcRoot()
		if nroot then
			for _, folder in ipairs(nroot:GetChildren()) do
				for _, model in ipairs(folder:GetChildren()) do
					consider(model)
				end
			end
		end
	end
	return best
end

local function aimStep()
	if not State.Aimbot then return end
	local cam = getCam()
	if not cam then return end
	local target = pickTarget()
	if not target then return end
	local part = aimPoint(target)
	if not part then return end

	local hitPos = part.Position
	if State.AimLead then
		local hrp = target:FindFirstChild("HumanoidRootPart")
		local head = target:FindFirstChild("Head")
		if hrp and head then
			local v = hrp.AssemblyLinearVelocity
			local dist = (part.Position - cam.CFrame.Position).Magnitude
			-- 子弹速度近似 800 st/s（LMG 级别），提前量 = 速度 × 飞行时间
			hitPos = hitPos + v * (dist / 800) * State.AimLeadFactor
		end
	end

	if State.AimMode == "鼠标移动" and mousemoverel then
		local pos, onScreen = cam:WorldToViewportPoint(hitPos)
		if onScreen then
			local vp = cam.ViewportSize
			local dx = pos.X - vp.X / 2
			local dy = pos.Y - vp.Y / 2
			mousemoverel(dx * State.AimSmooth, dy * State.AimSmooth)
		end
	else
		-- 相机锁：把视线平滑转向目标
		local cur = cam.CFrame
		local goal = CFrame.lookAt(cur.Position, hitPos)
		local alpha = 1 - math.clamp(State.AimSmooth, 0.01, 1)
		cam.CFrame = cur:Lerp(goal, math.clamp(alpha * 3, 0.08, 1))
	end
end

-- ================= TriggerBot =================
-- VIM 实测才能触发游戏开火输入；VIM 不可用时回退 VirtualUser
local function mouseDown()
	pcall(function()
		if VirtualInputManager then
			local m = UserInputService:GetMouseLocation()
			VirtualInputManager:SendMouseButtonEvent(m.X, m.Y, 0, true, game, 0)
		else
			VirtualUser:CaptureController()
			VirtualUser:Button1Down(Vector2.new())
		end
	end)
end

local function mouseUp()
	pcall(function()
		if VirtualInputManager then
			local m = UserInputService:GetMouseLocation()
			VirtualInputManager:SendMouseButtonEvent(m.X, m.Y, 0, false, game, 0)
		else
			VirtualUser:Button1Up(Vector2.new())
		end
	end)
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function refreshFilter()
	local ex = {}
	if lp.Character then table.insert(ex, lp.Character) end
	local myTeam = lp.Team
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= lp and p.Team == myTeam and p.Character then
			table.insert(ex, p.Character)
		end
	end
	-- 友方 NPC 整个文件夹排除（射线穿过友军，不误判不开火）
	local nroot = getNpcRoot()
	if nroot and myTeam then
		local friendly = nroot:FindFirstChild(myTeam.Name)
		if friendly then table.insert(ex, friendly) end
	end
	rayParams.FilterDescendantsInstances = ex
end

local function triggerStep()
	if not State.Trigger then return end
	local cam = getCam()
	if not cam then return end
	refreshFilter()
	local origin = cam.CFrame.Position
	local dir = cam.CFrame.LookVector * 2000
	local res = Workspace:Raycast(origin, dir, rayParams)
	local hitEnemy = false
	if res and res.Instance then
		local m = res.Instance:FindFirstAncestorOfClass("Model")
		if m and isEnemyModel(m) and alive(m) then hitEnemy = true end
	end
	local now = os.clock()
	if hitEnemy and not _triggerHolding then
		_triggerHolding = true
		_lastTriggerAt = now
		mouseDown()
	elseif _triggerHolding then
		if (not hitEnemy and now - _lastTriggerAt > 0.05) or (now - _lastTriggerAt > 2) then
			_triggerHolding = false
			mouseUp()
		end
	end
end

-- ================= ESP =================
local function makeEspObjects(model, isNpc)
	local col = isNpc and Color3.fromRGB(255, 165, 0) or Color3.fromRGB(255, 60, 60)
	local hl = Instance.new("Highlight")
	hl.Name = "_assHL"
	hl.FillColor = col
	hl.OutlineColor = Color3.fromRGB(255, 255, 255)
	hl.FillTransparency = 0.55
	hl.OutlineTransparency = 0
	hl.Enabled = State.Chams
	hl.Parent = model

	local head = model:FindFirstChild("Head") or model:FindFirstChild("HumanoidRootPart")
	local bb = Instance.new("BillboardGui")
	bb.Name = "_assBB"
	bb.Size = UDim2.fromOffset(160, 46)
	bb.StudsOffset = Vector3.new(0, 2.6, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = State.EspMaxDist
	if head then bb.Adornee = head end
	bb.Parent = lp:WaitForChild("PlayerGui")

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	bg.BackgroundTransparency = 0.55
	bg.BorderSizePixel = 0
	bg.Parent = bb
	local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 6); corner.Parent = bg

	local name = Instance.new("TextLabel")
	name.Size = UDim2.new(1, 0, 0, 16)
	name.BackgroundTransparency = 1
	name.Font = Enum.Font.GothamBold
	name.TextSize = 13
	name.TextColor3 = col
	name.Text = isNpc and ("[NPC] " .. model.Name) or model.Name
	name.Parent = bg

	local hpBg = Instance.new("Frame")
	hpBg.Position = UDim2.new(0.1, 0, 0, 20)
	hpBg.Size = UDim2.new(0.8, 0, 0, 8)
	hpBg.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	hpBg.BorderSizePixel = 0
	hpBg.Parent = bg
	local hpBgCorner = Instance.new("UICorner"); hpBgCorner.CornerRadius = UDim.new(0, 4); hpBgCorner.Parent = hpBg

	local hp = Instance.new("Frame")
	hp.Size = UDim2.fromScale(1, 1)
	hp.BackgroundColor3 = Color3.fromRGB(80, 220, 100)
	hp.BorderSizePixel = 0
	hp.Parent = hpBg
	local hpCorner = Instance.new("UICorner"); hpCorner.CornerRadius = UDim.new(0, 4); hpCorner.Parent = hp

	local dist = Instance.new("TextLabel")
	dist.Position = UDim2.new(0, 0, 0, 30)
	dist.Size = UDim2.new(1, 0, 0, 14)
	dist.BackgroundTransparency = 1
	dist.Font = Enum.Font.Gotham
	dist.TextSize = 11
	dist.TextColor3 = Color3.fromRGB(230, 230, 230)
	dist.Parent = bg

	return { hl = hl, bb = bb, hp = hp, dist = dist }
end

local function destroyEspObjects(model)
	local o = _espCache[model]
	if o then
		pcall(function() o.hl:Destroy() o.bb:Destroy() end)
		_espCache[model] = nil
	end
end

local espScanAcc = 0
local function espStep(dt)
	if not (State.Esp or State.Chams) then return end
	espScanAcc = espScanAcc + dt
	if espScanAcc < 0.3 then return end
	espScanAcc = 0

	local present = {}
	local function scan(model)
		if not (model:IsA("Model") and isEnemyModel(model) and alive(model)) then return end
		local isNpc = isEnemyNpc(model)
		if isNpc and not State.EspNpcs then return end
		present[model] = true
		local o = _espCache[model]
		if not o then o = makeEspObjects(model, isNpc) _espCache[model] = o end
		o.hl.Enabled = State.Chams
		o.bb.Enabled = State.Esp
		-- 血条距离实时由主循环轻量更新（放这里 0.3s 一次也够）
		local h = model:FindFirstChildOfClass("Humanoid")
		if h then
			local r = math.clamp(h.Health / math.max(h.MaxHealth, 1), 0, 1)
			o.hp.Size = UDim2.fromScale(r, 1)
			o.hp.BackgroundColor3 = Color3.fromRGB(255 - r * 175, 80 + r * 140, 90)
		end
		local part = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Head")
		if part then
			local cam = getCam()
			o.dist.Text = cam and string.format("%dm", math.floor((part.Position - cam.CFrame.Position).Magnitude + 0.5)) or "?"
		end
	end
	local root = getPCRoot()
	if root then
		for _, model in ipairs(root:GetChildren()) do scan(model) end
	end
	if State.EspNpcs then
		local nroot = getNpcRoot()
		if nroot then
			for _, folder in ipairs(nroot:GetChildren()) do
				for _, model in ipairs(folder:GetChildren()) do scan(model) end
			end
		end
	end
	for model in pairs(_espCache) do
		if not present[model] then destroyEspObjects(model) end
	end
end

local function clearAllEsp()
	for model in pairs(_espCache) do destroyEspObjects(model) end
end

-- ================= FOV 圈 =================
local function ensureFovCircle()
	if _fovCircle or not Drawing then return end
	_fovCircle = Drawing.new("Circle")
	_fovCircle.Thickness = 1.5
	_fovCircle.NumSides = 64
	_fovCircle.Filled = false
	_fovCircle.Visible = false
	getgenv()._RBA_FOV = _fovCircle
end

local function fovStep()
	local cam = getCam()
	if not cam then return end
	if State.Aimbot and State.ShowFov then
		ensureFovCircle()
		if _fovCircle then
			local vp = cam.ViewportSize
			_fovCircle.Position = vp / 2
			_fovCircle.Radius = State.AimFov
			_fovCircle.Color = Color3.fromRGB(State.FovColorR, State.FovColorG, State.FovColorB)
			_fovCircle.Visible = true
		end
	elseif _fovCircle then
		_fovCircle.Visible = false
	end
end

-- ================= 移动 =================
local function moveStep()
	if not State.MoveEnabled then return end
	local c = lp.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if h then
		if h.WalkSpeed ~= State.WalkSpeed then h.WalkSpeed = State.WalkSpeed end
		h.UseJumpPower = true
		if h.JumpPower ~= State.JumpPower then h.JumpPower = State.JumpPower end
	end
end

-- ================= 据点面板 =================
local objParagraph = nil
local function readObjectives()
	local m = Workspace:FindFirstChild("Map")
	local objs = m and m:FindFirstChild("Objectives")
	if not objs then return nil end
	local out = {}
	for _, obj in ipairs(objs:GetChildren()) do
		local pctR = obj:FindFirstChild("CapturePercentages")
		local capBy = obj:FindFirstChild("CapturedBy")
		local nR = obj:FindFirstChild("RedPlayers")
		local nB = obj:FindFirstChild("BlackPlayers")
		local contested = obj:FindFirstChild("Contested")
		table.insert(out, {
			name = obj.Name,
			cap = capBy and tostring(capBy.Value) or "?",
			pR = pctR and pctR:FindFirstChild("CapturePercentage_Red") and pctR.CapturePercentage_Red.Value or 0,
			pB = pctR and pctR:FindFirstChild("CapturePercentage_Black") and pctR.CapturePercentage_Black.Value or 0,
			nR = nR and nR.Value or 0,
			nB = nB and nB.Value or 0,
			fight = contested and contested.Value or false,
		})
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

local function objText()
	local list = readObjectives()
	if not list or #list == 0 then return "未找到 Map/Objectives" end
	local lines = {}
	for _, o in ipairs(list) do
		local who = o.cap == "Red" and "🔴红" or (o.cap == "Black" and "⚫黑" or "⚪中立")
		local fight = o.fight and " ⚔争夺" or ""
		table.insert(lines, string.format("%s: %s | 红%.0f%% 黑%.0f%% (%dv%d)%s",
			o.name, who, o.pR, o.pB, o.nR, o.nB, fight))
	end
	return table.concat(lines, "\n")
end

task.spawn(function()
	while true do
		if objParagraph then
			pcall(function() objParagraph:SetDesc(objText()) end)
		end
		task.wait(0.5)
	end
end)

-- ================= 枪械参数修改（Tool.Config 直改） =================
local _origGunCfg = {}   -- [枪名] = 原值快照

local function getGunConfig()
	local c = lp.Character
	local tool = c and c:FindFirstChildOfClass("Tool")
	if tool then
		local cm = tool:FindFirstChild("Config")
		if cm then
			local ok, T = pcall(require, cm)
			if ok and type(T) == "table" then return T, tool end
		end
	end
	for _, t in ipairs(lp.Backpack:GetChildren()) do
		local cm = t:FindFirstChild("Config")
		if cm then
			local ok, T = pcall(require, cm)
			if ok and type(T) == "table" then return T, t end
		end
	end
	return nil, nil
end

local function applyGunMods()
	local cfg, tool = getGunConfig()
	if not cfg or not cfg.Recoil then return false, "无枪" end
	local key = tool.Name
	local o = _origGunCfg[key]
	if not o then
		local chs = cfg.CrossHairStats or {}
		o = {
			RecoilX = cfg.Recoil.X, RecoilY = cfg.Recoil.Y,
			Spread = cfg.Spread, ShotgunSpread = cfg.ShotgunSpread,
			CHSMin = chs.MinSpread, CHSMax = chs.MaxSpread, CHSInc = chs.increasePerSecond,
			ReloadTime = cfg.ReloadTime,
			Damage = cfg.Damage, HeadShotMult = cfg.HeadShotMult,
			BulletSpeed = cfg.BulletSpeed, FireRate = cfg.FireRate,
		}
		_origGunCfg[key] = o
	end
	local on = State.NoRecoil or State.NoSpreadCfg or State.InstantReload
		or State.DamageBoost or State.BulletSpeedOn or State.FireRateOn
	if not on then
		-- 全关：还原
		if cfg.Recoil then cfg.Recoil.X, cfg.Recoil.Y = o.RecoilX, o.RecoilY end
		cfg.Spread, cfg.ShotgunSpread = o.Spread, o.ShotgunSpread
		if cfg.CrossHairStats then
			cfg.CrossHairStats.MinSpread, cfg.CrossHairStats.MaxSpread, cfg.CrossHairStats.increasePerSecond = o.CHSMin, o.CHSMax, o.CHSInc
		end
		cfg.ReloadTime = o.ReloadTime
		cfg.Damage, cfg.HeadShotMult = o.Damage, o.HeadShotMult
		cfg.BulletSpeed, cfg.FireRate = o.BulletSpeed, o.FireRate
		return true, key .. "（已还原）"
	end
	if cfg.Recoil then
		cfg.Recoil.X = State.NoRecoil and 0 or o.RecoilX
		cfg.Recoil.Y = State.NoRecoil and 0 or o.RecoilY
	end
	if State.NoSpreadCfg then
		cfg.Spread, cfg.ShotgunSpread = 0, 0
		if cfg.CrossHairStats then
			cfg.CrossHairStats.MinSpread, cfg.CrossHairStats.MaxSpread, cfg.CrossHairStats.increasePerSecond = 0, 0, 0
		end
	else
		cfg.Spread, cfg.ShotgunSpread = o.Spread, o.ShotgunSpread
		if cfg.CrossHairStats then
			cfg.CrossHairStats.MinSpread, cfg.CrossHairStats.MaxSpread, cfg.CrossHairStats.increasePerSecond = o.CHSMin, o.CHSMax, o.CHSInc
		end
	end
	cfg.ReloadTime = State.InstantReload and 0.15 or o.ReloadTime
	cfg.Damage = State.DamageBoost and math.floor(o.Damage * State.DamageMult) or o.Damage
	cfg.HeadShotMult = State.DamageBoost and (o.HeadShotMult * State.DamageMult) or o.HeadShotMult
	cfg.BulletSpeed = State.BulletSpeedOn and State.BulletSpeedVal or o.BulletSpeed
	cfg.FireRate = State.FireRateOn and math.floor(o.FireRate * State.FireRateMult) or o.FireRate
	return true, key
end

-- 换枪/重生后自动重应用（每 1s）
task.spawn(function()
	while true do
		if State.NoRecoil or State.NoSpreadCfg or State.InstantReload
			or State.DamageBoost or State.BulletSpeedOn or State.FireRateOn then
			pcall(applyGunMods)
		end
		task.wait(1)
	end
end)

-- ================= 主循环 =================
local loopConn = RunService.RenderStepped:Connect(function(dt)
	fovStep()
	triggerStep()
	espStep(dt)
	moveStep()
end)
getgenv()._RBA_LOOP = loopConn
-- ⚠ v1.5 关键修复：Aimbot 相机锁改用 BindToRenderStep(Camera+1)。
-- RenderStepped 事件在默认相机脚本（BindToRenderStep Camera=200）之前触发，
-- aimStep 里写的 cam.CFrame 会被相机脚本覆盖 → 渲染帧没有对准头
-- （探针实测 104 采样平均偏差 1.79°，峰值 7.57° → "锁的不是头"）。
-- Camera.Value+1 = 在相机更新之后、渲染之前最后写 CFrame，锁定才真正生效。
RunService:BindToRenderStep("RBA_AIM", Enum.RenderPriority.Camera.Value + 1, function()
	pcall(aimStep)
end)

-- 玩家离开/重生清理
Players.PlayerRemoving:Connect(function(p)
	for model in pairs(_espCache) do
		if model.Name == p.Name then destroyEspObjects(model) end
	end
end)

-- ================= UI =================
local Window = WindUI:CreateWindow({
	Title = "红黑据点战辅助",
	Icon = "crosshair",
	Author = "v1.2 · WindUI",
	Folder = "RedBlackAssist",
	Size = UDim2.fromOffset(540, 440),
	Theme = "Dark",
	Transparent = true,
	SideBarWidth = 170,
	ToggleKey = Enum.KeyCode.RightShift,
})
getgenv()._RBA_WIN = Window

local tabCombat = Window:Tab({ Title = "战斗", Icon = "target", Id = "combat" })
local tabGun = Window:Tab({ Title = "枪械", Icon = "zap", Id = "guns" })
local tabVisual = Window:Tab({ Title = "视觉", Icon = "eye", Id = "visual" })
local tabObj = Window:Tab({ Title = "据点", Icon = "map-pin", Id = "objectives" })
local tabMove = Window:Tab({ Title = "移动", Icon = "move", Id = "move" })

do -- 枪械修改
	local secGun = tabGun:Section({ Title = "枪械参数（手持/背包枪自动应用）" })
	secGun:Toggle({
		Title = "无后座 No Recoil", Desc = "清零 Config.Recoil，枪口不上抬",
		CurrentValue = false,
		Callback = function(v) State.NoRecoil = v pcall(applyGunMods) end,
	})
	secGun:Toggle({
		Title = "无散布 No Spread（Config 层）", Desc = "Spread/准星扩散全清零，与战斗页 hook 双保险",
		CurrentValue = false,
		Callback = function(v) State.NoSpreadCfg = v pcall(applyGunMods) end,
	})
	secGun:Toggle({
		Title = "极速换弹（实验性）", Desc = "ReloadTime 7s→0.15s；部分武器换弹由服务器计时，可能无效",
		CurrentValue = false,
		Callback = function(v) State.InstantReload = v pcall(applyGunMods) end,
	})
	secGun:Toggle({
		Title = "伤害倍率", Desc = "若击杀伤害无变化说明服务器计算伤害（此项无效但无害）",
		CurrentValue = false,
		Callback = function(v) State.DamageBoost = v pcall(applyGunMods) end,
	})
	secGun:Slider({
		Title = "伤害倍数", Min = 1, Max = 10, Step = 0.5, CurrentValue = 3, Suffix = "x",
		Callback = function(v) State.DamageMult = v if State.DamageBoost then pcall(applyGunMods) end end,
	})
	secGun:Toggle({
		Title = "弹速提升", Desc = "BulletSpeed 拉高，弹道更直更难躲",
		CurrentValue = false,
		Callback = function(v) State.BulletSpeedOn = v pcall(applyGunMods) end,
	})
	secGun:Slider({
		Title = "子弹速度", Min = 2200, Max = 10000, Step = 200, CurrentValue = 6000, Suffix = "st/s",
		Callback = function(v) State.BulletSpeedVal = v if State.BulletSpeedOn then pcall(applyGunMods) end end,
	})
	secGun:Toggle({
		Title = "射速提升", Desc = "⚠ 服务器若校验开火频率可能拒绝部分子弹，异常就关",
		CurrentValue = false,
		Callback = function(v) State.FireRateOn = v pcall(applyGunMods) end,
	})
	secGun:Slider({
		Title = "射速倍数", Min = 1, Max = 2, Step = 0.1, CurrentValue = 1.5, Suffix = "x",
		Callback = function(v) State.FireRateMult = v if State.FireRateOn then pcall(applyGunMods) end end,
	})
	secGun:Button({
		Title = "还原当前枪所有参数", Callback = function()
			State.NoRecoil, State.NoSpreadCfg, State.InstantReload = false, false, false
			State.DamageBoost, State.BulletSpeedOn, State.FireRateOn = false, false, false
			local ok, msg = pcall(applyGunMods)
			notify("枪械参数", "已还原 " .. tostring(msg), "rotate-ccw", 2)
		end,
	})
end

do -- 战斗
	local secAim = tabCombat:Section({ Title = "自瞄 Aimbot" })
	secAim:Toggle({
		Title = "开启 Aimbot", CurrentValue = false,
		Callback = function(v) State.Aimbot = v end,
	})
	secAim:Dropdown({
		Title = "瞄准模式", Options = { "Camera锁", "鼠标移动" }, CurrentValue = "Camera锁",
		Callback = function(v) State.AimMode = v end,
	})
	secAim:Dropdown({
		Title = "瞄准部位", Options = { "Head", "HumanoidRootPart" }, CurrentValue = "Head",
		Callback = function(v) State.AimPart = v end,
	})
	secAim:Slider({
		Title = "FOV 半径", Min = 30, Max = 400, Step = 5, CurrentValue = 90, Suffix = "px",
		Callback = function(v) State.AimFov = v end,
	})
	secAim:Slider({
		Title = "平滑度（越小越跟手）", Min = 0.05, Max = 1, Step = 0.01, CurrentValue = 0.28,
		Callback = function(v) State.AimSmooth = v end,
	})
	secAim:Toggle({
		Title = "子弹提前量（打移动靶）", CurrentValue = true,
		Callback = function(v) State.AimLead = v end,
	})
	secAim:Toggle({
		Title = "显示 FOV 圈", CurrentValue = true,
		Callback = function(v) State.ShowFov = v end,
	})
	secAim:Toggle({
		Title = "瞄准 NPC（Major/Bunker/Alate/Soldier）", Desc = "NPC 目标带 30% 距离惩罚：同屏优先玩家，NPC 更近时锁 NPC",
		CurrentValue = false,
		Callback = function(v) State.AimNpcs = v end,
	})

	local secTrig = tabCombat:Section({ Title = "扳机与散布" })
	secTrig:Toggle({
		Title = "TriggerBot（准星上敌人自动开火）", CurrentValue = false,
		Callback = function(v)
			State.Trigger = v
			if not v and _triggerHolding then
				_triggerHolding = false
				mouseUp()
			end
		end,
	})
	secTrig:Toggle({
		Title = "No Spread（零散布）", Desc = "hook 准星散布计算，切枪/重载后仍生效",
		CurrentValue = false,
		Callback = function(v)
			State.NoSpread = v
			local ok = applyNoSpread()
			if not ok then notify("No Spread", "DynamicCrossHairController 加载失败", "alert-triangle") end
		end,
	})
end

do -- 视觉
	local secEsp = tabVisual:Section({ Title = "敌人 ESP" })
	secEsp:Toggle({
		Title = "ESP 血条/名字/距离", CurrentValue = false,
		Callback = function(v)
			State.Esp = v
			if not v and not State.Chams then clearAllEsp() end
		end,
	})
	secEsp:Toggle({
		Title = "Chams 透视高亮（红=玩家）", CurrentValue = false,
		Callback = function(v)
			State.Chams = v
			if not v and not State.Esp then clearAllEsp() end
		end,
	})
	secEsp:Toggle({
		Title = "包含 NPC（橙色区分）", Desc = "ESP/Chams 同时覆盖敌方 NPC：Major / Bunker / Alate / Soldier",
		CurrentValue = false,
		Callback = function(v)
			State.EspNpcs = v
			if not v then clearAllEsp() end
		end,
	})
	secEsp:Slider({
		Title = "ESP 最大距离", Min = 200, Max = 10000, Step = 100, CurrentValue = 3000, Suffix = "st",
		Callback = function(v) State.EspMaxDist = v end,
	})
end

do -- 据点
	local secObj = tabObj:Section({ Title = "A / B / C 占领状态（每 0.5s 刷新）" })
	objParagraph = secObj:Paragraph({ Title = "据点实时数据", Desc = "读取中..." })
end

do -- 移动
	local secMove = tabMove:Section({ Title = "人物移动" })
	secMove:Toggle({
		Title = "启用移动修改", CurrentValue = false,
		Callback = function(v) State.MoveEnabled = v end,
	})
	secMove:Slider({
		Title = "WalkSpeed", Min = 16, Max = 200, Step = 1, CurrentValue = 16, Suffix = "st/s",
		Callback = function(v) State.WalkSpeed = v end,
	})
	secMove:Slider({
		Title = "JumpPower", Min = 50, Max = 400, Step = 5, CurrentValue = 50,
		Callback = function(v) State.JumpPower = v end,
	})
end

-- 收尾：脚本环境销毁时断开主循环并清 ESP
game:GetService("Players").LocalPlayer.OnTeleport:Connect(function(state)
	if state == Enum.TeleportState.Started then
		pcall(function() loopConn:Disconnect() clearAllEsp() end)
	end
end)

Window:SelectTab(1)
notify("红黑据点战辅助", "已加载 v1.2 · RightShift 呼出/隐藏", "crosshair", 4)
print("[红黑辅助] v1.5 加载完成")

-- 修复 WindUI 内容区滚动（Active=false + 无滚动条导致滚不动）
task.defer(function()
	local wg = (gethui and gethui()) or game.CoreGui
	wg = wg:FindFirstChild("WindUI") or game.CoreGui:FindFirstChild("WindUI")
	if not wg then return end
	local function fixSf(sf)
		sf.Active = true
		if sf.ScrollBarThickness == 0 then
			sf.ScrollBarThickness = 6
			pcall(function()
				sf.ScrollBarImageColor3 = Color3.fromRGB(120, 120, 140)
				sf.ScrollBarImageTransparency = 0.2
			end)
		end
	end
	for _, v in ipairs(wg:GetDescendants()) do
		if v:IsA("ScrollingFrame") then fixSf(v) end
	end
	wg.DescendantAdded:Connect(function(v)
		if v:IsA("ScrollingFrame") then
			task.defer(function() pcall(fixSf, v) end)
		end
	end)
	print("[红黑辅助] 滚动修复已应用")
end)

-- Slider 拖动后输入泄漏修复（拖滑块后右栏滚不动/其他滑块拖不动的根因）：
-- WindUI dist 拖动开始时 ContainerFrame.ScrollingEnabled=false，恢复依赖 InputEnded
-- 里"结束输入 == 开始输入对象"匹配；快速连拖/失焦/注入输入等场景不匹配 →
-- ScrollingEnabled 永久 false（滚动卡死）+ WindUI.CurrentInput 残留（所有滑块拖不动）。
-- 修复：松开鼠标/触摸立即恢复（不依赖定时器）+ 0.5s 定时兜底；
-- GUI 查找走 gethui()/CoreGui/CoreGui.RobloxGui 三路（单一路径在不同执行环境会空转）。
local _sfCache = {}
local function collectWindUI()
	local hs = game:GetService("CoreGui")
	local roots = {}
	if gethui then pcall(function() table.insert(roots, gethui()) end) end
	table.insert(roots, hs)
	pcall(function()
		local rg = hs:FindFirstChild("RobloxGui")
		if rg then table.insert(roots, rg) end
	end)
	for _, r in ipairs(roots) do
		if r then
			for _, c in ipairs(r:GetChildren()) do
				if c.Name == "WindUI" then
					for _, v in ipairs(c:GetDescendants()) do
						if v:IsA("ScrollingFrame") then _sfCache[v] = true end
					end
					c.DescendantAdded:Connect(function(v)
						if v:IsA("ScrollingFrame") then _sfCache[v] = true end
					end)
				end
			end
		end
	end
end

-- 鼠标按下状态事件跟踪（IsMouseButtonPressed 在注入环境抛 "Argument 1 missing or nil"，
-- 不可用；InputBegan/InputEnded 事件已验证可用）
local _mouseDown = false
UserInputService.InputBegan:Connect(function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		_mouseDown = true
	end
end)

local function restoreScrolling()
	-- ⚠ v1.4 关键保护：鼠标按住期间可能正在拖窗口/滑块。窗口拖动（dist 25557）
	-- 结束时校验 m.CurrentInput==A，若我们中途清掉它，松手时校验失败 →
	-- 拖动状态残留 → 窗口粘在鼠标上。所以只在鼠标完全松开后才做任何恢复。
	if _mouseDown then return end
	for sf in pairs(_sfCache) do
		pcall(function()
			if not sf.ScrollingEnabled then sf.ScrollingEnabled = true end
			if not sf.Active then sf.Active = true end
		end)
	end
	-- CurrentInput 挂在 WindUI 主模块表上；鼠标已松开说明没有合法持有者，残留即泄漏
	pcall(function() WindUI.CurrentInput = nil end)
end

UserInputService.InputEnded:Connect(function(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
		_mouseDown = false
		-- defer 到当帧事件处理完之后：dist 自己的清理先跑，我们只兜底泄漏场景
		task.defer(function() pcall(restoreScrolling) end)
	end
end)

task.spawn(function()
	task.wait(1)
	pcall(collectWindUI)
	while true do
		task.wait(0.5)
		pcall(restoreScrolling)
	end
end)

-- 测试/调试句柄
_G.RBA = {
	State = State, pickTarget = pickTarget, objText = objText,
	applyNoSpread = applyNoSpread, getPCRoot = getPCRoot, getNpcRoot = getNpcRoot,
	isEnemyModel = isEnemyModel, isEnemyNpc = isEnemyNpc,
	clearAllEsp = clearAllEsp, readObjectives = readObjectives,
	applyGunMods = applyGunMods, getGunConfig = getGunConfig,
	WindUI = WindUI, restoreScrolling = restoreScrolling,
}
