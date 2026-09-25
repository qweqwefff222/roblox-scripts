--[[
	911 调度助手 v3.1 · Obsidian UI（全中文）
	游戏：[911调度模拟器] placeId 74226462246442
	三合一：自动接听（含全对话+CAD提交）/ 自动调度派遣 / 自动购买单位
	协议（反编译实锤）：
	  接听   PlayerAnsweredCall:FireServer(call.Id)
	  对话   PlayerSelectedDialogue:FireServer(callId, choiceId, {Priority, Services})
	  派遣   DispatchUnits:FireServer({IncidentId=inc.Id, UnitIds={unit.Id,...}})
	  购买   BuyUnit:FireServer(unit.Id)
]]

local g = getgenv()
if g._N911_ASSIST_STOP then g._N911_ASSIST_STOP() end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local lp = Players.LocalPlayer

local N = ReplicatedStorage:WaitForChild("NineOneOne")
local Remotes = N:WaitForChild("NineOneOne_Remotes")
local Modules = N:WaitForChild("NineOneOne_Modules")
local function R(name) return Remotes:FindFirstChild(name) end

-- ================= 对话库索引（TemplateId -> 定义） =================
local CallLib = {}
do
	for _, m in ipairs(Modules:GetChildren()) do
		if m.Name:find("CallContentV2_Data") and m:IsA("ModuleScript") then
			local ok, d = pcall(require, m)
			if ok and type(d) == "table" then
				for _, def in pairs(d) do
					if type(def) == "table" and def.TemplateId then
						CallLib[tostring(def.TemplateId)] = def
					end
				end
			end
		end
	end
end

local function orderedChoices(def)
	local list = {}
	if type(def) ~= "table" or type(def.Choices) ~= "table" then return list end
	for k, v in pairs(def.Choices) do
		local nk = tonumber(k)
		if nk then list[nk] = v end
	end
	-- 仅当数据带 _i 排序键时才 sort（否则 list 已按数字键 1..N 有序；
	-- 全相等比较器 + Lua 不稳定排序有打乱顺序的理论风险）
	local hasI = false
	for _, v in ipairs(list) do
		if type(v) == "table" and v._i ~= nil then hasI = true break end
	end
	if hasI then
		table.sort(list, function(a, b) return (a._i or 0) < (b._i or 0) end)
	end
	-- ipairs 语义：按数字键顺序
	local out = {}
	for i = 1, #list do out[i] = list[i] end
	return out
end

-- ================= 状态 =================
local State = {
	Enabled = true,         -- AI 总开关（默认开启）
	AutoAnswer = true,      -- 自动接听+对话+CAD
	AutoDispatch = true,    -- 自动派遣
	AutoBuy = true,         -- 自动购买单位
	AutoStartShift = true,  -- 自动开始值班（每天掉线自动重开）
	AutoDistrict = true,    -- 自动扩展城区（钱够就解锁新城区）
	AutoBoard = true,       -- 自动扩任务板（钱够就买 ExtraIncidentSlot）
	AutoUpgrades = true,    -- 自动购买升级（中心升级+城市计划，勾选过滤）
	AutoStation = true,     -- 自动购买建筑（新城区解锁后买消防局/警察局/医院）
	DistrictReserve = 0,    -- 扩城区现金预留
	BuySelection = {},      -- 用户勾选要买的单位（中文名集合）
	UpgradeSelection = {},  -- 用户勾选要买的升级（中文名集合）
	UpgradeAll = true,      -- 升级未勾选时买全部可买
	BuyAll = true,          -- 未勾选时买全部可买
	CashReserve = 0,        -- 购买现金预留
	DialogueStep = 0.9,     -- 对话选项间隔（秒）
	Stat = {
		Answered = 0, Dialogue = 0, CAD = 0,
		Incidents = 0, Dispatched = 0, Bought = 0, Shifts = 0, Districts = 0, Board = 0, Upgrades = 0, Stations = 0,
	},
}

-- 运行时表（监听维护）
local Calls = {}         -- [callId] = call 对象（服务器推送，含 Status/ChoicesUsed/TemplateId）
local CallOrder = {}     -- 有序 callId 列表
local SentState = {} -- [callId] = {seq=最后发送序号, at=发送时刻, retries=重试次数, skips=跳过次数}（在途登记，不作进度权威）
local AnswerTry = {} -- [callId] = {n=接听fire次数, at=最后fire时刻}（3s 内状态未离开 Ringing 则重试，最多 3 次）
local Blacklist = {} -- [callId] = true（判定死亡的通话：推送再带回来也不复活，防死循环刷被拒请求）
local LastSeen = {} -- [callId] = 最后一次收到服务器推送的时刻（过期清理用，防残留通话死循环）
local CallCool = {}      -- [callId] = 冷却截止（防重发）
local Incidents = {}  -- [incidentId] = {Id, Category, RecommendServices, Dispatched}
local Units = {}      -- [unitId] = {Id, Service, Status, AssignedIncidentId}
local Shop = nil      -- ShopData
local UnlockedDistricts = {}  -- [districtId] = true
local OwnedUpgrades = {}      -- [upgradeId] = true
local DistrictCool = {}       -- [districtId] = 冷却截止
local BoardCool = 0           -- 板子扩容冷却
local UpgradeCool = {}        -- [upgradeId] = 冷却截止（升级购买防重发）
local IncidentCool = {}       -- [incidentId] = 派遣冷却截止（防推送间隙重复派）
local StationsOwned = {}      -- [stationId] = true（服务器 OwnedStations 数组）
local StationCool = {}        -- [stationId] = 建筑购买冷却截止
local eventConns = {}         -- 全部事件连接（stop 时统一 Disconnect，防重载双监听）

-- 城区定义（GAME_CONFIG.Districts 快照，价格升序）+ 建筑目录（config.Stations）
local DistrictList = {}
local StationsList = {}
do
	local okCfg, cfg911 = pcall(require, N and Modules and Modules:FindFirstChild("NineOneOne_Config"))
	if okCfg and type(cfg911) == "table" then
		if type(cfg911.Districts) == "table" then
			for _, d in ipairs(cfg911.Districts) do
				if type(d) == "table" and d.Id then
					DistrictList[#DistrictList + 1] = { Id = tostring(d.Id), Price = tonumber(d.Price) or 0, DisplayName = tostring(d.DisplayName or d.Id) }
				end
			end
		end
		if type(cfg911.Stations) == "table" then
			for _, s in ipairs(cfg911.Stations) do
				if type(s) == "table" and s.Id then
					StationsList[#StationsList + 1] = {
						Id = tostring(s.Id),
						DisplayName = tostring(s.DisplayName or s.Id),
						District = tostring(s.District or ""),
						Service = tostring(s.Service or ""),
						Price = tonumber(s.Price) or 0,
						Starter = s.Starter == true,
					}
				end
			end
			table.sort(StationsList, function(a, b) return a.Price < b.Price end)
		end
	end
end
-- 建筑中文名（按 DisplayName 语义翻译）
local STATION_ZH = {
	police_hq = "市中心警察总局",
	fire_downtown = "市中心消防站",
	hospital_downtown = "市中心医院",
	fire_southgate = "南门消防站",
	police_southgate = "南门警察局",
	hospital_southgate = "南门社区医院",
	fire_westvale = "西谷消防站",
	police_westvale = "西谷警察局",
	fire_northridge = "北岭消防站",
	police_northridge = "北岭警察局",
	hospital_northridge = "北岭医疗中心",
	fire_ironyards = "铁厂消防站",
	police_ironyards = "铁厂警察局",
	fire_harbourfront = "港口消防站",
	police_harbourfront = "港口警察局",
	fire_airport = "机场救援站",
}
local function stationZh(s)
	if type(s) ~= "table" then return tostring(s) end
	return STATION_ZH[tostring(s.Id)] or tostring(s.DisplayName or s.Id)
end
-- 板子升级链（服务器现有 1-9 档，钱够+等级到就顺次买）
local BOARD_SLOTS = { "ExtraIncidentSlot1", "ExtraIncidentSlot2", "ExtraIncidentSlot3", "ExtraIncidentSlot4", "ExtraIncidentSlot5", "ExtraIncidentSlot6", "ExtraIncidentSlot7", "ExtraIncidentSlot8", "ExtraIncidentSlot9" }

-- 升级中文名映射（Id -> 中文名，来自中心升级/城市计划页）
local UPG_ZH = {
	ExtraCallSlot1 = "呼叫队列槽位 I（+1 来电等待）",
	ExtraCallSlot2 = "呼叫队列槽位 II（+1 来电等待）",
	ExtraCallSlot3 = "呼叫队列槽位 III（+1 来电等待）",
	BetterRadioSystem = "更好的无线电（单位速度 +8%）",
	AdvancedCAD = "CAD 路由系统（单位速度 +5%）",
	ResponseNetwork3 = "响应网络 III（单位速度）",
	DispatcherTraining = "调度员培训（经验 +15%）",
	DispatcherTraining2 = "调度员培训 II（经验）",
	TrainingGrant = "培训拨款（经验加成）",
	CityBond = "城市债券（现金 +2%）",
	RadioNetwork = "广播网络（单位速度 +2.5%）",
	PoliceStrength = "警力扩充（+1 警察席位）",
	FireStrength = "消防扩充（+1 消防席位）",
	EMSStrength = "EMS 扩充（+1 EMS 席位）",
}
local function upgradeLabel(u)
	if type(u) ~= "table" then return tostring(u) end
	local cat = tostring(u.Tier) == "Contract" and "【城市】" or "【中心】"
	local zh = UPG_ZH[tostring(u.Id)] or tostring(u.DisplayName or u.Id)
	return cat .. zh .. " $" .. tostring(u.Cost or "?")
end

local RecentLog = {}  -- UI 日志
local function log(text)
	table.insert(RecentLog, 1, os.date("%H:%M:%S") .. " " .. text)
	if #RecentLog > 8 then table.remove(RecentLog) end
end

-- 单位名中文翻译
local UNIT_ZH = {
	PatrolCar = "巡逻车", Patrol = "巡逻车",
	Ambulance = "救护车", Medic = "救护车", EMS = "急救单元",
	Engine = "消防车", Pumper = "泵浦消防车", FireEngine = "消防车",
	Ladder = "云梯车", LadderTruck = "云梯车", TruckCo = "云梯车", Quint = "云梯救援车",
	Rescue = "救援车", HeavyRescue = "重型救援车",
	K9 = "警犬单元", K9Unit = "警犬单元",
	SWAT = "特警车", SWATVan = "特警车",
	Hazmat = "防化单元", HazmatUnit = "防化单元",
	Traffic = "交通执法车", TrafficUnit = "交通执法车",
	Helicopter = "直升机", PoliceHelicopter = "警用直升机", Air = "空中支援",
	Tanker = "水罐车", Tender = "水罐车", WaterTender = "水罐车",
	Brush = "越野消防车", BrushTruck = "越野消防车",
	Supervisor = "指挥车", SupervisorSUV = "主管指挥车", Command = "指挥车", CommandUnit = "指挥车",
	Battalion = "消防指挥车", Chief = "队长指挥车",
	Van = "警用大巴", PoliceVan = "警用大巴", Transport = "押运车",
	Boat = "消防艇", Marine = "水上单元",
	BombSquad = "排爆单元", Dive = "潜水救援", Water = "水上救援",
}
local function zhUnitName(unit)
	if type(unit) ~= "table" then return tostring(unit) end
	local key = tostring(unit.UnitType or unit.Id or "")
	local name = tostring(unit.DisplayName or unit.Name or key)
	if UNIT_ZH[key] then return UNIT_ZH[key] end
	for en, zh in pairs(UNIT_ZH) do
		if key:find(en, 1, true) or name:find(en, 1, true) then return zh end
	end
	return name
end
-- 商店条目 -> "中文 (类别)" 显示名
local function shopEntryLabel(unit)
	return zhUnitName(unit) .. " [" .. tostring(unit.ShopCategory or "?") .. "] $" .. tostring(unit.Cost or "?")
end

-- ================= Obsidian UI =================
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/Library.lua"))()
local Window = Library:CreateWindow({
	Title = "911 调度助手",
	Footer = "v3.1 · 全自动调度助手",
	ToggleKeybind = Enum.KeyCode.RightControl,
	Center = true,
	AutoShow = true,
})
local TabMain = Window:AddTab("主页", "home")
local TabStat = Window:AddTab("状态", "activity")
local TabSet = Window:AddTab("设置", "settings")

local grpMain = TabMain:AddLeftGroupbox("AI 总控")
grpMain:AddToggle("Enabled", {
	Text = "AI 自动游玩（总开关）",
	Default = true,
	Callback = function(v) State.Enabled = v end,
})
grpMain:AddLabel("快捷键：右Ctrl 显隐界面")

local grpFn = TabMain:AddRightGroupbox("功能开关")
grpFn:AddToggle("AutoAnswer", { Text = "自动接听（全对话+发CAD）", Default = true, Callback = function(v) State.AutoAnswer = v end })
grpFn:AddToggle("AutoDispatch", { Text = "自动调度（派单位去事故）", Default = true, Callback = function(v) State.AutoDispatch = v end })
grpFn:AddToggle("AutoBuy", { Text = "自动购买单位", Default = true, Callback = function(v) State.AutoBuy = v end })
grpFn:AddToggle("AutoStartShift", { Text = "自动开始值班（每日自动重开）", Default = true, Callback = function(v) State.AutoStartShift = v end })
grpFn:AddToggle("AutoDistrict", { Text = "自动扩展城区（钱够解锁最便宜的）", Default = true, Callback = function(v) State.AutoDistrict = v end })
grpFn:AddToggle("AutoStation", { Text = "自动购买建筑（新城区的消防局/警察局/医院）", Default = true, Callback = function(v) State.AutoStation = v end })
grpFn:AddToggle("AutoBoard", { Text = "自动扩任务板（钱够买下一个槽位）", Default = true, Callback = function(v) State.AutoBoard = v end })
grpFn:AddToggle("AutoUpgrades", { Text = "自动买升级（中心升级+城市计划）", Default = true, Callback = function(v) State.AutoUpgrades = v end })

local grpParam = TabMain:AddLeftGroupbox("参数")
grpParam:AddSlider("DialogueStep", {
	Text = "对话选项间隔", Default = 0.9, Min = 0.01, Max = 2, Rounding = 2, Suffix = "秒",
	Callback = function(v) State.DialogueStep = v end,
})
grpParam:AddSlider("CashReserve", {
	Text = "购单位现金预留", Default = 0, Min = 0, Max = 50000, Rounding = 0, Suffix = "$",
	Callback = function(v) State.CashReserve = v end,
})

local grpBuy = TabMain:AddRightGroupbox("购买单位选择（勾选要买的）")
local buyDropdown = grpBuy:AddDropdown("BuySelection", {
	Values = { "（等待商店数据...）" },
	Default = {},
	Multi = true,
	Text = "要自动购买的单位",
	Tooltip = "从商店目录勾选要自动购买的单位类型",
	Callback = function(v)
		State.BuySelection = type(v) == "table" and v or {}
	end,
})
grpBuy:AddToggle("BuyAll", { Text = "未勾选时买全部可买", Default = true, Callback = function(v) State.BuyAll = v end })
grpBuy:AddButton({
	Text = "全选商店单位",
	Func = function()
		if type(Shop) == "table" and type(Shop.Units) == "table" then
			for _, u in ipairs(Shop.Units) do
				if type(u) == "table" then
					State.BuySelection[shopEntryLabel(u)] = true
				end
			end
		end
		log("已全选商店单位")
	end,
})
grpBuy:AddButton({
	Text = "清空选择",
	Func = function()
		State.BuySelection = {}
		pcall(function() buyDropdown:SetValues({}) end)
	end,
})

local grpUpg = TabMain:AddRightGroupbox("升级自动购买（中心升级+城市计划）")
local upgDropdown = grpUpg:AddDropdown("UpgradeSelection", {
	Values = { "（等待商店数据...）" },
	Default = {},
	Multi = true,
	Text = "要自动购买的升级",
	Tooltip = "事件板栏位由「自动扩任务板」开关管理，不在此列",
	Callback = function(v)
		State.UpgradeSelection = type(v) == "table" and v or {}
	end,
})
grpUpg:AddToggle("UpgradeAll", { Text = "未勾选时买全部可买", Default = true, Callback = function(v) State.UpgradeAll = v end })
grpUpg:AddButton({
	Text = "全选升级",
	Func = function()
		if type(Shop) == "table" and type(Shop.Upgrades) == "table" then
			for _, u in ipairs(Shop.Upgrades) do
				if type(u) == "table" and tostring(u.UpgradeType) ~= "IncidentSlots" then
					State.UpgradeSelection[upgradeLabel(u)] = true
				end
			end
		end
		log("已全选升级")
	end,
})
grpUpg:AddButton({
	Text = "清空升级选择",
	Func = function()
		State.UpgradeSelection = {}
		pcall(function() upgDropdown:SetValues({}) end)
	end,
})

local grpStat = TabStat:AddLeftGroupbox("计数")
local lbl = {}
local function makeLabel(grp, key, text)
	lbl[key] = grp:AddLabel(text)
end
makeLabel(grpStat, "Answered", "已接来电：0")
makeLabel(grpStat, "Dialogue", "对话选项：0")
makeLabel(grpStat, "CAD", "CAD 提交：0")
makeLabel(grpStat, "Incidents", "事故总数：0")
makeLabel(grpStat, "Dispatched", "派遣次数：0")
makeLabel(grpStat, "Bought", "购买单位：0")
makeLabel(grpStat, "Shifts", "值班重开：0")
makeLabel(grpStat, "Districts", "扩城区：0")
makeLabel(grpStat, "Board", "扩任务板：0")
makeLabel(grpStat, "Upgrades", "升级购买：0")
makeLabel(grpStat, "Stations", "购买建筑：0")
makeLabel(grpStat, "Calls", "进行中对话：0")
makeLabel(grpStat, "UnitsAvail", "可用单位：0")

local grpLog = TabStat:AddRightGroupbox("日志")
local lblLog = grpLog:AddLabel("-")

local grpHelp = TabSet:AddLeftGroupbox("说明")
grpHelp:AddLabel("接听：来电自动接起，全部问题按库顺序问完，最后自动提交 CAD 生成事故。")
grpHelp:AddLabel("调度：事故生成后自动派匹配服务的可用单位。")
grpHelp:AddLabel("购买：商店内可买可负担的单位自动购入。")
grpHelp:AddLabel("快捷键：右Ctrl 显隐 / P 总开关。")
grpHelp:AddButton({
	Text = "卸载脚本",
	Func = function()
		if g._N911_ASSIST_STOP then g._N911_ASSIST_STOP() end
		Library:Unload()
	end,
})

task.spawn(function()
	while true do
		task.wait(0.5)
		pcall(function()
			lbl.Answered:SetText("已接来电：" .. State.Stat.Answered)
			lbl.Dialogue:SetText("对话选项：" .. State.Stat.Dialogue)
			lbl.CAD:SetText("CAD 提交：" .. State.Stat.CAD)
			lbl.Incidents:SetText("事故总数：" .. State.Stat.Incidents)
			lbl.Dispatched:SetText("派遣次数：" .. State.Stat.Dispatched)
			lbl.Bought:SetText("购买单位：" .. State.Stat.Bought)
			lbl.Shifts:SetText("值班重开：" .. State.Stat.Shifts)
			lbl.Districts:SetText("扩城区：" .. State.Stat.Districts)
			lbl.Board:SetText("扩任务板：" .. State.Stat.Board)
			lbl.Upgrades:SetText("升级购买：" .. State.Stat.Upgrades)
			lbl.Stations:SetText("购买建筑：" .. State.Stat.Stations)
			local nCalls = 0
			for _ in pairs(Calls) do nCalls += 1 end
			local nAvail = 0
			for _, u in pairs(Units) do
				if u.Status == "Available" then nAvail += 1 end
			end
			lbl.Calls:SetText("进行中对话：" .. nCalls)
			lbl.UnitsAvail:SetText("可用单位：" .. nAvail)
			lblLog:SetText(#RecentLog > 0 and table.concat(RecentLog, "\n") or "-")
		end)
	end
end)

-- ================= 监听器 =================
local function trackIncoming(call)
	if type(call) ~= "table" or call.Id == nil then return end
	local id = tostring(call.Id)
	if Blacklist[id] then return end -- 判死通话永不复活（推送再带来也忽略）
	local isNew = Calls[id] == nil
	call._answered = call._answered or (Calls[id] and Calls[id]._answered)
	call._choiceIdx = call._choiceIdx or (Calls[id] and Calls[id]._choiceIdx) or 0
	call._busy = call._busy or (Calls[id] and Calls[id]._busy)
	Calls[id] = call
	LastSeen[id] = os.clock() -- 每次服务器推送刷新活跃时间（过期清理依据）
	if isNew then
		CallOrder[#CallOrder + 1] = id
		log("来电 " .. tostring(call.TemplateId or id):sub(1, 40))
	end
end

local function connectEvents()
	-- 统一 hook：收集连接到 eventConns，stop 时全部 Disconnect（防重载后双监听）
	local function hook(name, handler)
		local r = R(name)
		if r then eventConns[#eventConns + 1] = r.OnClientEvent:Connect(handler) end
	end
	hook("IncomingCall", function(call, ...) trackIncoming(call) end)
	hook("CallUpdated", function(call, ...) trackIncoming(call) end)
	hook("CallEnded", function(payload, ...)
		-- payload 兼容：可能是 callId 字符串，也可能是 call 对象（table）
		local cid = type(payload) == "table" and tostring(payload.Id or "") or tostring(payload or "")
		if cid ~= "" then
			Calls[cid] = nil
			AnswerTry[cid] = nil
			SentState[cid] = nil
			LastSeen[cid] = nil
		end
	end)
	hook("IncidentCreated", function(inc, ...)
		if type(inc) == "table" and inc.Id then
			local id = tostring(inc.Id)
			if Incidents[id] == nil then
				Incidents[id] = {
					Id = id,
					Category = inc.Category or inc.CallCategory,
					RequiredServiceCounts = inc.RequiredServiceCounts or {},
					RequiredUnitTypes = inc.RequiredUnitTypes,
					DispatchCoverage = inc.DispatchCoverage,
					SentCount = {},
					RecommendServices = inc.RecommendServices or (inc.ClientDisplay and inc.ClientDisplay.MapIcon),
					Dispatched = false,
				}
				State.Stat.Incidents += 1
				log("事故 " .. id:sub(1, 20) .. " (" .. tostring(inc.Category) .. ") 待派 需求:" .. HttpService:JSONEncode(inc.RequiredServiceCounts or {}))
			end
		end
	end)
	hook("IncidentResolved", function(inc, ...)
		local id = type(inc) == "table" and tostring(inc.Id) or tostring(inc or "")
		Incidents[id] = nil
	end)
	hook("UnitUpdated", function(payload, ...)
		if type(payload) ~= "table" then return end
		if payload.Mode == "FullList" and type(payload.Units) == "table" then
			Units = {}
			for _, u in ipairs(payload.Units) do
				if type(u) == "table" and u.Id then Units[tostring(u.Id)] = u end
			end
		elseif payload.Id then
			Units[tostring(payload.Id)] = payload
		end
	end)
	hook("ShopUpdated", function(data, ...)
		if type(data) == "table" then
			Shop = data
			-- 刷新购买下拉选项（中文名列表）
			if type(data.Units) == "table" and buyDropdown then
				local labels = {}
				for _, u in ipairs(data.Units) do
					if type(u) == "table" then labels[#labels + 1] = shopEntryLabel(u) end
				end
				table.sort(labels)
				pcall(function() buyDropdown:SetValues(labels) end)
			end
			-- 刷新升级下拉选项（中文名列表，排除事件板栏位）
			if type(data.Upgrades) == "table" and upgDropdown then
				local labels = {}
				for _, u in ipairs(data.Upgrades) do
					if type(u) == "table" and tostring(u.UpgradeType) ~= "IncidentSlots" then
						labels[#labels + 1] = upgradeLabel(u)
					end
				end
				table.sort(labels)
				pcall(function() upgDropdown:SetValues(labels) end)
			end
		end
	end)
	-- c8：FullStateUpdate（全量数据：OwnedUnits/ActiveIncidents/Cash/ShiftActive）
	hook("FullStateUpdate", function(st, ...)
		if type(st) ~= "table" then return end
		-- 单位表全量重建
		if type(st.OwnedUnits) == "table" then
			Units = {}
			for _, u in ipairs(st.OwnedUnits) do
				if type(u) == "table" and u.Id then Units[tostring(u.Id)] = u end
			end
		end
		-- 城区解锁表 / 已购升级表（兼容数组 {"id",...} 与字典 {id=true} 两种推送格式）
		if type(st.UnlockedDistricts) == "table" then
			UnlockedDistricts = {}
			for k, d in pairs(st.UnlockedDistricts) do
				if type(d) == "string" or type(d) == "number" then
					UnlockedDistricts[tostring(d)] = true -- 数组格式
				else
					UnlockedDistricts[tostring(k)] = true -- 字典格式
				end
			end
		end
		if type(st.OwnedUpgrades) == "table" then
			OwnedUpgrades = {}
			for k, v in pairs(st.OwnedUpgrades) do
				if type(v) == "string" then
					OwnedUpgrades[v] = true -- 数组格式 {"ExtraIncidentSlot1",...}
				else
					OwnedUpgrades[tostring(k)] = (v == true) or v == 1 or v == "true" or (tonumber(v) or 0) > 0
				end
			end
		end
		-- 已拥有建筑（服务器 OwnedStations 数组，源码 IsStationOwned 用 table.find 判定）
		if type(st.OwnedStations) == "table" then
			StationsOwned = {}
			for _, s in ipairs(st.OwnedStations) do
				StationsOwned[tostring(s)] = true
			end
		end
		-- 现金
		if st.Cash then
			if type(Shop) ~= "table" then Shop = {} end
			Shop.Cash = st.Cash
		end
		-- 自动开始值班：班次结束立即重开（10s 冷却防连发）
		if State.AutoStartShift and st.ShiftActive == false and os.clock() > (g._N911_SHIFT_COOL or 0) then
			local ss = R("StartShift")
			if ss then
				g._N911_SHIFT_COOL = os.clock() + 10
				ss:FireServer()
				State.Stat.Shifts += 1
				log("班次已结束，自动重新开始值班（第 " .. State.Stat.Shifts .. " 次）")
			end
		end
		-- 活跃事故表（含需求），并清理已解决的
		if type(st.ActiveIncidents) == "table" then
			local present = {}
			for _, inc in ipairs(st.ActiveIncidents) do
				if type(inc) == "table" and inc.Id then
					local id = tostring(inc.Id)
					present[id] = true
					if Incidents[id] == nil then
						Incidents[id] = {
							Id = id,
							Category = inc.Category or inc.CallCategory,
							RequiredServiceCounts = inc.RequiredServiceCounts or {},
							RequiredUnitTypes = inc.RequiredUnitTypes,
							DispatchCoverage = inc.DispatchCoverage,
							SentCount = {},
							Dispatched = false,
						}
						State.Stat.Incidents += 1
						log("事故 " .. id:sub(1, 20) .. " (" .. tostring(inc.Category) .. ") 待派")
					else
						Incidents[id].RequiredServiceCounts = inc.RequiredServiceCounts or Incidents[id].RequiredServiceCounts
						Incidents[id].RequiredUnitTypes = inc.RequiredUnitTypes
						Incidents[id].DispatchCoverage = inc.DispatchCoverage
					end
					-- 已派记账按服务器 AssignedUnitIds 重建（服务器真相，新建/已知事故统一校准）：
					-- req=原始需求不变；本地累计记账会因网络期重复 fire 虚高（v2.4 永不补派真凶）；
					-- v2.5 的清零记账则在原始需求语义下反复把 Available 单位堆上去（全派出灾难）。
					local sc = {}
					if type(inc.AssignedUnitIds) == "table" then
						for _, uid in ipairs(inc.AssignedUnitIds) do
							local u = Units[tostring(uid)] or Units[uid]
							local svc = type(u) == "table" and tostring(u.Service or "") or ""
							if svc ~= "" then
								sc[svc] = (sc[svc] or 0) + 1
							end
						end
					end
					Incidents[id].SentCount = sc
				end
			end
			for id in pairs(Incidents) do
				if not present[id] then Incidents[id] = nil end
			end
		end
	end)
end
connectEvents()

-- 服务器→客户端的接听确认（PlayerAnsweredCall 也回显）：本地标记
local answeredConn
do
	local r = R("PlayerAnsweredCall")
	if r then
		answeredConn = r.OnClientEvent:Connect(function(call, ...)
			trackIncoming(call)
		end)
	end
end

-- ================= 核心动作 =================
local function fireAnswered(callId)
	local r = R("PlayerAnsweredCall")
	if r then r:FireServer(callId) end
end

local function fireDialogue(callId, choiceId, cfg)
	local r = R("PlayerSelectedDialogue")
	if r then r:FireServer(callId, choiceId, cfg) end
end

local function fireDispatch(incidentId, unitIds)
	local r = R("DispatchUnits")
	if r then r:FireServer({ IncidentId = incidentId, UnitIds = unitIds }) end
end

local function fireBuy(unitId)
	local r = R("BuyUnit")
	if r then r:FireServer(unitId) end
end

-- 接听 + 全对话 + CAD：进度权威只认服务器（见 stepDialogue）

local function countDispatcherLines(call)
	local n = 0
	if type(call.Conversation) == "table" then
		for _, m in ipairs(call.Conversation) do
			if type(m) == "table" and m.Speaker == "Dispatcher" then n += 1 end
		end
	end
	return n
end

local function stepDialogue()
	for _, callId in ipairs(CallOrder) do
		local call = Calls[callId]
		if type(call) ~= "table" then
			Calls[callId] = nil
		else
			local id = tostring(call.Id or callId)
			local status = tostring(call.Status or "")
			local flags = call.Flags or {}
			local serverAnswered = (tonumber(call.AnsweredAt) or 0) > 0
			-- 1) 接听：响铃中、未被自动话务处理；fire 后 3s 状态未离开 Ringing 则重试（最多 3 次），仍失败拉黑该来电
			if status == "Ringing" and not serverAnswered and call.AutoCalltakerProcessing ~= true then
				local try = AnswerTry[id]
				if try and try.n >= 3 then
					-- 接听 3 次都无效果（被限流/会话异常）：放弃该来电，不阻塞后续
					Blacklist[id] = true
					Calls[id] = nil
					AnswerTry[id] = nil
					SentState[id] = nil
					LastSeen[id] = nil
					log("接听无响应，放弃该来电：" .. id:sub(1, 16))
					return true
				end
				local needFire = (try == nil) or (os.clock() - try.at > 3)
				if needFire and (CallCool[id] or 0) <= os.clock() then
					local r = R("PlayerAnsweredCall")
					if r then r:FireServer(id, call) end -- 源码 OnAnswer(Id, call) 双参数
					AnswerTry[id] = { n = (try and try.n or 0) + 1, at = os.clock() }
					CallCool[id] = os.clock() + math.max(State.DialogueStep, 0.05)
					State.Stat.Answered += 1
					log("已自动接听 " .. tostring(call.IncidentDisplayTitle or id):sub(1, 30) .. ((try and try.n or 0) > 0 and "（重试）" or ""))
					return true
				end
			end
			-- 2) 对话推进：在途登记 + 服务器确认驱动 + 超时重发
			--    （旧版 max(服务器确认, 本地已发) 会让被拒选项造成本地进度虚高 → 跳过末尾问题/CAD 且永不重试）
			-- 终态判定：任一终态都停止推进（Ended 之外补 Missed/Completed/Cancelled/Resolved 保险）
			local terminal = status == "Ended" or status == "Missed" or status == "Completed" or status == "Cancelled" or status == "Resolved"
			if (AnswerTry[id] or serverAnswered) and not terminal and not flags.CreatedIncident and call.TemplateId then
				local def = CallLib[tostring(call.TemplateId)]
				if def then
					local choices = orderedChoices(def)
					local total = #choices
					local confirmed = math.min(countDispatcherLines(call), total) -- 服务器真进度（被接受的选项数）
					local st = SentState[id]
					local function cfg()
						return {
							Priority = def.Priority or "Low",
							Services = {
								Police = (def.RequiredServiceCounts and def.RequiredServiceCounts.Police) or 0,
								Fire = (def.RequiredServiceCounts and def.RequiredServiceCounts.Fire) or 0,
								EMS = (def.RequiredServiceCounts and def.RequiredServiceCounts.EMS) or 0,
							},
						}
					end
					if total == 0 then
						-- 模板无选项：无事可做
					elseif confirmed >= total then
						-- 全部选项已被服务器接受：等 CreatedIncident；
						-- 久等不来则兜底重发 CREATE_INCIDENT（服务器对同通话幂等），最多 3 次后放弃
						if st and st.seq >= total and (os.clock() - st.at) > 6 and (CallCool[id] or 0) <= os.clock() then
							local last = choices[total]
							if last then
								local cadRetries = (st.cadRetries or 0) + 1
								if cadRetries > 3 then
									log("CAD 无响应，已放弃该通话：" .. id:sub(1, 16))
									Blacklist[id] = true
									Calls[id] = nil
									AnswerTry[id] = nil
									SentState[id] = nil
									return true
								end
								fireDialogue(id, tostring(last.Id), cfg())
								SentState[id] = { seq = total, at = os.clock(), retries = (st.retries or 0) + 1, skips = st.skips or 0, cadRetries = cadRetries }
								CallCool[id] = os.clock() + 2
								log("CAD 兜底重发（" .. id:sub(1, 18) .. "）")
								return true
							end
						end
					else
						local inFlight = st and st.seq > confirmed and (os.clock() - st.at) < 3
						if inFlight then
							-- 在途未确认：等 3 秒确认窗
						elseif (CallCool[id] or 0) > os.clock() then
							-- 发送冷却中
						else
							local seq = confirmed + 1
							local retries = (st and st.seq == seq and st.retries) or 0
							local skips = (st and st.skips) or 0
							if retries >= 4 then
								skips += 1
								if skips >= 3 then
									-- 多问连续无响应（典型：通话已在服务器端结束/被清理）→ 放弃并拉黑，
									-- 释放遍历让新来电能被接听（否则残留通话永久抢占 stepDialogue）
									log("通话无响应，已放弃：" .. id:sub(1, 16))
									Blacklist[id] = true
									Calls[id] = nil
									AnswerTry[id] = nil
									SentState[id] = nil
									return true
								end
								-- 该问连续 4 次无服务器确认：跳过该问防整通死等（日志留痕，仍会走到 CAD）
								log("跳过无响应第 " .. seq .. "/" .. total .. " 问")
								seq = confirmed + 2
								retries = 0
							end
							if seq > total then seq = total end
							local choice = choices[seq]
							if choice then
								fireDialogue(id, tostring(choice.Id), cfg())
								SentState[id] = { seq = seq, at = os.clock(), retries = retries + 1, skips = skips }
								CallCool[id] = os.clock() + math.max(State.DialogueStep, 0.05)
								State.Stat.Dialogue += 1
								if seq >= total then
									State.Stat.CAD += 1
									log("CAD 提交（" .. tostring(call.IncidentDisplayTitle or id):sub(1, 24) .. "）")
								else
									log("对话 " .. seq .. "/" .. total .. " " .. tostring(choice.Id):sub(1, 26))
								end
								return true
							end
						end
					end
				elseif not call._unknownLogged then
					call._unknownLogged = true
					log("未知模板 " .. tostring(call.TemplateId):sub(1, 30))
				end
			end
		end
	end
	return false
end

-- 派遣：按事故的 RequiredServiceCounts 逐服务补派缺口（Multi 事故各服务分别派）
local function stepDispatch()
	for incId, inc in pairs(Incidents) do
		local req = inc.RequiredServiceCounts
		if type(req) ~= "table" then
			-- 兜底：按 Category 派一个
			req = { [inc.Category or "Police"] = 1 }
		end
		inc.SentCount = inc.SentCount or {}
		local toSend = {}
		local picked = {}     -- [unitId] = true（本轮已收录，防专用车/服务两循环重复选同一单位）
		local allSatisfied = true
		-- 1) 专用车缺口优先：事故指定车辆（如 Tanker 水罐车，派对有 +25% XP）。
		--    服务器真相 = RequiredUnitTypes[车型] - DispatchCoverage.CoveredUnitTypeCounts[车型]
		--    （源码判定同款），无需本地记账，FullStateUpdate 每 3s 刷新自动纠偏。
		local reqTypes = inc.RequiredUnitTypes
		if type(reqTypes) == "table" then
			local covered = (type(inc.DispatchCoverage) == "table" and type(inc.DispatchCoverage.CoveredUnitTypeCounts) == "table" and inc.DispatchCoverage.CoveredUnitTypeCounts) or {}
			for utype, need in pairs(reqTypes) do
				need = tonumber(need) or 0
				local missingSpecial = need - (tonumber(covered[tostring(utype)]) or 0)
				for _, u in pairs(Units) do
					if missingSpecial > 0 and tostring(u.UnitType) == tostring(utype) and u.Status == "Available" and not picked[u.Id] then
						local aid = u.AssignedIncidentId
						if aid == nil or aid == "" then
							toSend[#toSend + 1] = u.Id
							picked[u.Id] = true
							missingSpecial -= 1
						end
					end
				end
			end
		end
		-- 2) 服务缺口（原逻辑 + picked 排除已收录单位）
		for service, need in pairs(req) do
			need = tonumber(need) or 0
			if need > 0 then
				local sent = tonumber(inc.SentCount[service]) or 0
				local missing = need - sent
				if missing > 0 then
					allSatisfied = false
					for _, u in pairs(Units) do
						if missing > 0 and tostring(u.Service) == service and u.Status == "Available" and not picked[u.Id] then
							local aid = u.AssignedIncidentId
							if aid == nil or aid == "" then
								toSend[#toSend + 1] = u.Id
								picked[u.Id] = true
								missing -= 1
							end
						end
					end
				end
			end
		end
		if #toSend > 0 then
			if (IncidentCool[incId] or 0) <= os.clock() then
				fireDispatch(incId, toSend)
				IncidentCool[incId] = os.clock() + 3 -- 与 FullStateUpdate 刷新周期一致：一批在途时不重复派
				-- 记账：按每个单位的实际 Service 分摊（粗记曾把全部数量摊给第一个缺口服务，导致其他服务永远显示缺员误补派）
				for _, uid in ipairs(toSend) do
					local u = Units[uid] or Units[tostring(uid)]
					local svc = type(u) == "table" and tostring(u.Service or "") or ""
					if svc ~= "" then
						inc.SentCount[svc] = (tonumber(inc.SentCount[svc]) or 0) + 1
					end
				end
				State.Stat.Dispatched += 1
				local names = {}
				for _, uid in ipairs(toSend) do
					names[#names + 1] = zhUnitName(Units[uid] or { Id = uid })
				end
				log("派遣 " .. #toSend .. " 单位（" .. table.concat(names, "、") .. "）→ " .. incId:sub(1, 18))
				return true
			end
			-- 冷却中（上一批在途）：跳过该事故继续看下一个
		end
		if allSatisfied and not inc.Dispatched then
			inc.Dispatched = true
		end
	end
	return false
end

-- 购买：商店 CanBuy 且可负担（现金 - 预留）；按用户勾选过滤，未勾选时按 BuyAll
local function stepBuy()
	if type(Shop) ~= "table" or type(Shop.Units) ~= "table" then return false end
	local cash = tonumber(Shop.Cash) or 0
	for _, unit in ipairs(Shop.Units) do
		if type(unit) == "table" and unit.Id then
			local label = shopEntryLabel(unit)
			local want = State.BuyAll or State.BuySelection[label] == true
			local canBuy = unit.CanBuy == true
			local afford = cash - State.CashReserve >= (tonumber(unit.Cost) or math.huge)
			if want and canBuy and afford then
				fireBuy(unit.Id)
				State.Stat.Bought += 1
				log("购买单位：" .. zhUnitName(unit) .. "（$" .. tostring(unit.Cost or "?") .. "）")
				return true
			end
		end
	end
	return false
end

-- 自动扩展城区：按价格升序找未解锁的，钱够就 BuyDistrict（服务器校验等级/相邻，被拒进冷却不刷）
local function stepDistrict()
	if type(Shop) ~= "table" then return false end
	local cash = tonumber(Shop.Cash) or 0
	for _, d in ipairs(DistrictList) do
		if not UnlockedDistricts[d.Id] and d.Price > 0 then
			if cash - State.DistrictReserve >= d.Price then
				if (DistrictCool[d.Id] or 0) <= os.clock() then
					local r = R("BuyDistrict")
					if r then
						r:FireServer(d.Id)
						DistrictCool[d.Id] = os.clock() + 30
						State.Stat.Districts += 1
						log("扩展城区：" .. d.DisplayName .. "（$" .. d.Price .. "）")
						return true
					end
				end
				return false -- 钱够但在冷却，等下一轮
			end
			return false -- 最便宜的未解锁城区钱不够，后面的更贵不用看
		end
	end
	return false
end

-- 自动购买建筑：新城区解锁后买该区的消防局/警察局/医院（未拥有 + 城区已解锁 + 钱够，价格升序；
-- 源码实锤无等级/声望门槛，Starter 建筑免费视为已拥有）。城区未解锁的建筑跳过继续看下一个。
local function stepStations()
	if #StationsList == 0 then return false end
	local cash = tonumber(Shop and Shop.Cash) or 0
	for _, st in ipairs(StationsList) do
		if not st.Starter and st.Price > 0 and not StationsOwned[st.Id] then
			if UnlockedDistricts[st.District] then
				if cash - State.DistrictReserve >= st.Price then
					if (StationCool[st.Id] or 0) <= os.clock() then
						local r = R("BuyStation")
						if r then
							r:FireServer(st.Id)
							StationCool[st.Id] = os.clock() + 30
							State.Stat.Stations += 1
							log("购买建筑：" .. stationZh(st) .. "（$" .. st.Price .. "）")
							return true
						end
					end
					return false -- 最便宜的可买建筑在冷却，等下一轮
				end
				return false -- 最便宜的可买建筑钱不够，后面的更贵
			end
			-- 该建筑所属城区未解锁：跳过，继续看下一个（不同建筑可能属于不同城区）
		end
	end
	return false
end

-- 自动扩任务板：ExtraIncidentSlot1→9 顺序买；只有商店条目 CanBuy==true 才发
-- （CanBuy 已含等级/现金/已购判定——等级不够时绝不发请求，防被拒刷屏触发服务器限流）
local function stepBoard()
	if type(Shop) ~= "table" or type(Shop.Upgrades) ~= "table" then return false end
	local cash = tonumber(Shop.Cash) or 0
	local shopInfo = {}
	for _, up in ipairs(Shop.Upgrades) do
		if type(up) == "table" and up.Id then shopInfo[tostring(up.Id)] = up end
	end
	for _, slotId in ipairs(BOARD_SLOTS) do
		local info = shopInfo[slotId]
		if info == nil then
			return false -- 该档不在商店数据里（未收到数据或档位不存在）：停住等下次推送
		end
		if not OwnedUpgrades[slotId] and info.Owned ~= true then
			local cost = tonumber(info.Cost) or 3250
			if info.CanBuy == true and cash - State.DistrictReserve >= cost then
				if BoardCool <= os.clock() then
					local r = R("BuyUpgrade")
					if r then
						r:FireServer(slotId)
						BoardCool = os.clock() + math.max(State.DialogueStep, 0.5)
						State.Stat.Board += 1
						log("扩任务板：" .. tostring(info.DisplayName or slotId) .. "（$" .. cost .. "）")
						return true
					end
				end
				return false -- 冷却中
			end
			return false -- CanBuy=false（等级/声望锁或钱不够）：不发请求，等服务器推新状态
		end
	end
	return false
end

-- 自动买升级（中心升级+城市计划）：CanBuy（服务器已含等级/现金/已购判定）+ 扣预留够钱才发；事件板栏位由 stepBoard 管
local function stepUpgrades()
	if type(Shop) ~= "table" or type(Shop.Upgrades) ~= "table" then return false end
	local cash = tonumber(Shop.Cash) or 0
	for _, up in ipairs(Shop.Upgrades) do
		if type(up) == "table" and up.Id then
			local id = tostring(up.Id)
			if tostring(up.UpgradeType) ~= "IncidentSlots" then
				local label = upgradeLabel(up)
				local want = State.UpgradeAll or State.UpgradeSelection[label] == true
				if want and up.Owned ~= true and OwnedUpgrades[id] ~= true and up.CanBuy == true then
					if (UpgradeCool[id] or 0) <= os.clock() and cash - State.CashReserve >= (tonumber(up.Cost) or math.huge) then
						local r = R("BuyUpgrade")
						if r then
							r:FireServer(id)
							UpgradeCool[id] = os.clock() + 6
							State.Stat.Upgrades += 1
							log("购买升级：" .. label)
							return true
						end
					end
				end
			end
		end
	end
	return false
end

-- ================= 主循环 =================
local stopped = false
g._N911_ASSIST_STOP = function()
	stopped = true
	-- 断开全部事件监听（重载时防旧连接泄漏/双监听）
	for _, c in ipairs(eventConns) do
		pcall(function() c:Disconnect() end)
	end
	if answeredConn then pcall(function() answeredConn:Disconnect() end) end
	eventConns = {}
end
g._N911_STATE = State      -- 远程诊断句柄
g._N911_TABLES = function() return Calls, Incidents, Units, Shop end

local RF_FullState = R("GetFullState")
local RD_Refresh = R("RequestDataRefresh")
local lastFullPoll = 0

task.spawn(function()
	task.wait(1)
	local lastBeat = 0
	while not stopped do
		if State.Enabled then
			-- 每 3s 触发一次 RequestDataRefresh → 服务器推 FullStateUpdate（单位/事故/现金全量）
			if RD_Refresh and os.clock() - lastFullPoll > 3 then
				lastFullPoll = os.clock()
				pcall(function() RD_Refresh:FireServer() end)
			end
			local acted = false
			pcall(function()
				if State.AutoAnswer then acted = stepDialogue() or acted end
				if State.AutoDispatch then acted = stepDispatch() or acted end
				if State.AutoBuy then acted = stepBuy() or acted end
				if State.AutoDistrict then acted = stepDistrict() or acted end
				if State.AutoStation then acted = stepStations() or acted end
				if State.AutoBoard then acted = stepBoard() or acted end
				if State.AutoUpgrades then acted = stepUpgrades() or acted end
			end)
			-- 心跳（每 6s 一条，确认循环活着）
			if os.clock() - lastBeat > 6 then
				lastBeat = os.clock()
				-- 清理已结束通话的残留（CallOrder 压缩 + 进度/冷却表回收），防长挂增长
				for cid in pairs(SentState) do
					if Calls[cid] == nil then SentState[cid] = nil end
				end
				-- 过期通话清理：120s 无任何服务器推送 = 已死通话（正常活跃通话每次选项被接受都会推送刷新）
				for cid in pairs(Calls) do
					local seen = LastSeen[cid]
					if seen == nil then
						LastSeen[cid] = os.clock() -- 老条目补登记，下轮起参与过期判定
					elseif os.clock() - seen > 45 then
						-- 45s 无任何服务器推送 = 死通话（正常活跃通话每次选项被接受都会推送刷新）
						Blacklist[cid] = true
						Calls[cid] = nil
						AnswerTry[cid] = nil
						SentState[cid] = nil
						LastSeen[cid] = nil
						log("通话超时清理：" .. tostring(cid):sub(1, 16))
					end
				end
				for cid in pairs(CallCool) do
					if Calls[cid] == nil then CallCool[cid] = nil end
				end
				local alive = {}
				for _, cid in ipairs(CallOrder) do
					if Calls[cid] ~= nil then alive[#alive + 1] = cid end
				end
				if #alive ~= #CallOrder then CallOrder = alive end
				local nCalls = 0
				for _ in pairs(Calls) do nCalls += 1 end
				log("运行中：对话 " .. nCalls .. " | 事故 " .. (function() local n = 0 for _ in pairs(Incidents) do n += 1 end return n end)() .. " | 单位 " .. (function() local n = 0 for _ in pairs(Units) do n += 1 end return n end)())
			end
			task.wait(acted and State.DialogueStep or 0.6)
		else
			task.wait(0.4)
		end
	end
end)

Library:Notify("911 调度助手 v3.1 已加载（全自动）", 4)
print("[911调度助手] v3.1 加载完成，对话库 " .. (function() local n = 0 for _ in pairs(CallLib) do n += 1 end return n end)() .. " 个模板，建筑 " .. #StationsList .. " 座")
