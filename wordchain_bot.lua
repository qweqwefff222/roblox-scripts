--[[
    完成这个词 · 自动答题 v1.0
    ============ 协议(反编译确认) ============
    - 上行: event.remoteFire("keyStroke", 键名) 逐键(A-Z) + ("tryAnswer") 提交
      → 实际走 RemoteFunction:InvokeServer(name, ...)
    - 下行: updateRound(轮数据, ?, 回合玩家) — 轮数据.RequiredLetter=必填开头字母串
      → 输入光标起始位 = #RequiredLetter (前缀已预填, 只需打后缀!)
    - correct/takeDamage 事件标记对错
    ============ 功能 ============
    [自动答题] 监听 updateRound, 轮到自己时:
      1. 延迟(基础+随机) 模拟思考
      2. 从内嵌词库选一个以 RequiredLetter 开头、没用过的词
      3. 逐键发送后缀(humanlike键间隔) → tryAnswer
    [已答词追踪] 防重复
    单例守护 + 落盘日志
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
local ev = game.ReplicatedStorage:WaitForChild("Services"):WaitForChild("Communication"):WaitForChild("event")
local RemoteFunction = ev:WaitForChild("RemoteFunction")

-- ================= 单例守护 =================
if getgenv()._WC_INST and typeof(getgenv()._WC_INST.kill) == "function" then
    pcall(function() getgenv()._WC_INST.kill() end)
end
local INST = { alive = true, conns = {}, used = {} }
getgenv()._WC_INST = INST
local function bind(c) table.insert(INST.conns, c) end

-- ================= 配置 =================
local state = {
    enabled = true,   -- 自动答题
    baseDelay = 1.5,  -- 基础延迟(秒)
    randDelay = 1.5,  -- 随机延迟上限(秒)
}
-- ========================================

-- ---------- 日志 ----------
local logBuf = {}
local function log(msg)
    local line = string.format("[%s] %s", os.date("%H:%M:%S"), tostring(msg))
    table.insert(logBuf, line)
    if #logBuf > 200 then
        local keep = {}
        for i = #logBuf - 99, #logBuf do keep[#keep + 1] = logBuf[i] end
        logBuf = keep
    end
    getgenv()._WC_LOG = logBuf
    pcall(function()
        if writefile then
            local old = ""
            if isfile and isfile("wordchain_log.txt") then
                old = readfile("wordchain_log.txt")
                if #old > 100000 then old = "" end
            end
            writefile("wordchain_log.txt", old .. line .. "\n")
        end
    end)
end

-- ---------- 词库(常用英文词, 按首字母) ----------
local RAW = {
A = "able about above add afraid after afternoon again age agree air airplane airport all allow almost alone along already also always amazing among angry animal ankle answer ant any anyone anything apartment appear apple apply approach April are area arm army around arrange arrive art artist as ask asleep assistant at attack attempt attend attention august aunt author autumn available average awake away",
B = "baby back bad bag ball balloon banana band bank bar basket battle beach bear beat beautiful because become bed bee beef before begin behave behind believe bell belong below belt bench bend best better between beyond big bike bill bird birthday bit bite black blade blame blank blanket bless blind block blood blow blue board boat body boil bomb bone book boot border borrow boss both bottle bottom bowl box boy brain branch brave bread break breakfast breath brick bridge bright bring broad brother brown brush build bullet bundle burn burst business busy butter button buy",
C = "cabin cake call calm camera camp can canal candle cap car card care carry case cash cast castle catch cattle cause ceiling cell center central century certain chain chair chalk challenge chance change character charge chat cheap check cheese chest chicken chief child chimney choice choose church circle city claim class clean clear clerk clever click cliff climb clock close cloth cloud club coal coast coat code coffee coin cold collect college color comb combine come comfort command comment common company compare complete computer concern condition consider contain content continue control cook cool copy corner correct cost cotton could count country couple course cousin cover cow crack crash cream create creature credit crew crime crop cross crowd crown cry culture cup current cut",
D = "daily damage dance danger dare dark date daughter day dead deal dear death debate debt decide decision deep defeat defend define degree delay delete deliver demand department depend describe desert design desk detail develop device dictionary die diet difference different difficult dig digital dinner direct dirt dirty disappear disaster discover discuss disease dish distance distant divide do doctor document dog dollar door double doubt down dozen draw dream dress drink drive drop dry duck during dust duty",
E = "each ear early earn earth easy eat economy edge education effect effort egg eight either elbow elder elect electric elephant else empty end enemy energy engine enjoy enough enter entire equal escape especially even evening event ever every evidence exact example except excite exercise exist expect expensive experience explain explore express extra eye",
F = "face fact factory fail fair fall false family famous fan fancy far farm fashion fast fat father fault favor fear feature february fee feed feel female fence festival fever few fiber field fifteen fight figure fill film final find fine finger finish fire first fish fit five fix flag flat flight floor flour flow flower fly focus fog fold follow food foot for force foreign forest forget fork form fortune forward four fraction free fresh friend from front fruit fuel full fun funny furniture future",
G = "gain game garden gas gate gather general generous gentle get gift girl give glad glass globe glory glove go goal goat god gold golf good grab grade grain grand grant grass grave gray great green greet grey grocery ground group grow guard guess guest guide gun",
H = "hair half hall hand hang happen happy hard harm hat hate have he head health hear heart heat heavy height hello help hen here hero hide high hill hint hire history hit hold hole holiday home honest honey honor hope horse hospital host hot hotel hour house how however huge human humble humor hunger hunt hurry hurt husband",
I = "ice idea ideal if ill imagine impact import important impossible improve in inch include income increase indeed indicate industry influence information ink inner innocent input insect inside inspire instant instead interest internal internet interview into introduce invent invest investigate invite iron island item",
J = "jacket jail jam january jaw jazz jeans jelly jet jewel job join joke journey joy judge juice jump june junior just",
K = "keen keep key keyboard kick kid kill kind king kiss kitchen kite knee knife knock know knowledge",
L = "lab label labor lack lady lake lamp land language large last late laugh law lay lazy lead leaf league learn leave lecture left leg legal lend length less lesson let letter level library license lie life lift light like limit line lion lip liquid list listen literature little live load loan local lock long look lose lot loud love low lucky lunch lung",
M = "machine mad magazine magic mail main major make male man manage manner many map march mark market marry mass master match material math matter may maybe mayor meal mean measure meat media medical meet melody melt member memory mental mention menu message metal method middle might mile milk million mind mine minute mirror miss mistake mix model modern moment money monitor month moon moral more morning most mother motion motor mountain mouse mouth move movie much music must mystery",
N = "nail name narrow nation native nature near nearly necessary neck need negative neighbor neither nephew nerve nervous nest net network never new news next nice night nine nobody noise none noon nor normal north nose not note nothing notice now number nurse nut",
O = "obey object observe obtain obvious occasion occur ocean october of off offer office officer often oil okay old on once one onion only onto open operate opinion oppose option orange orbit order ordinary organ origin other otherwise out outdoor outside over own owner",
P = "pack page pain paint pair palace pale pan paper paragraph pardon parent park part particular partly partner party pass passage passenger passion past patch path patient pattern pause pay peace peak pen pencil people pepper per percent perfect perform perhaps period permanent permission person pet photo phrase physical piano pick picture pie piece pig pigeon pile pilot pin pink pipe pity pizza place plan plane planet plant plastic plate play please pleasure plenty plot pocket poem point poison police policy polish polite pool poor pop popular population port portion position possible post pot potato pound power practice praise pray prefer prepare present president press pressure pretend pretty prevent price pride primary prince princess principal print prison private prize probable problem procedure produce product profession professor program promise proof proper protect proud prove provide public pull pump pumpkin punish pupil purchase pure purple purpose push put",
Q = "quality quantity quarter queen question quick quiet quite quiz",
R = "rabbit race radio rail rain raise range rank rapid rare rate rather reach read ready real reason receive recent record recover red reduce refer reflect reform refuse regard region regret regular reject relate relax release relief religion rely remain remark remind remote remove rent repair repeat replace reply report represent require rescue research reserve resist resource respect respond rest restaurant result return reveal review reward rice rich ride ring rise risk river road rob robot rock role roll roof room root rope rose rough round route row rub ruin rule run rush",
S = "sad safe sail salad sale salt same sample sand satisfy save say scale school science score sea search season seat second secret section see seed seem sell send senior sense separate september series serious serve service set settle seven several shade shadow shake shall shape share sharp she sheep sheet shelf shell shelter shift shine ship shirt shock shoe shoot shop shore short should shoulder shout show shower shut sick side sight sign silence silent silk silver similar simple since sing single sink sister sit site situation six size skill skin skirt sky sleep slice slide slight slip slow small smell smile smoke smooth snake snow so soap soccer social society sock soft soil soldier solid solution solve some son song soon sorry sort sound soup source south space speak special species speech speed spend spin spirit split sport spot spread spring square squeeze stable staff stage stairs stamp stand star start state station stay steady steak steal steam steel step stick still stomach stone stop store storm story straight strange stream street strength stress stretch strict strike string strong structure struggle student study stuff style subject succeed such sudden suffer sugar suggest suit summer sun supply support suppose sure surface surprise survive swim system",
T = "table tail take tale talk tall tank tape target task taste tax tea teach team tear technique teeth telephone television tell temperature ten tend tennis tent term terrible test text than thank that theater their them then theory there these thick thin thing think third thirst this though thought thousand three throat through throw thumb thunder ticket tie tiger tight time tiny tip tire title today toe together toilet tomorrow tone tongue tonight too tool tooth top total touch tour toward towel tower town toy track trade tradition traffic train transform translate transport travel treat tree triangle tribe trick trip trouble truck true trust truth try tube tune tunnel turn twelve twenty twice twin two type",
U = "ugly uncle under understand uniform union unit unite universe university unless until up upon upper upset urban urge us use useful usual",
V = "vacation valley valuable value van variety various vast vegetable vehicle very victory video view village violin virtue visit voice volume vote",
W = "wage waist wait wake walk wall want war warm wash waste watch water wave way we weak wealth weapon wear weather web wedding week weigh weight welcome well west wet what wheat wheel when where whether which while white who whole whom why wide wife wild will win wind window wine wing winter wipe wire wisdom wise wish with within without witness woman wonder wood word work world worry worth would wrap write wrong",
X = "xenon xerox xylophone",
Y = "yard yarn yell yellow yes yesterday yet yield you young your",
Z = "zero zone zoo zipper",
}

-- 解析词库
local WORDS = {}
for letter, str in pairs(RAW) do
    local list = {}
    for w in str:gmatch("%S+") do
        table.insert(list, w)
    end
    WORDS[letter] = list
end

-- ---------- 面板 ----------
if lp.PlayerGui:FindFirstChild("_wc_panel") then
    lp.PlayerGui._wc_panel:Destroy()
end
local gui = Instance.new("ScreenGui")
gui.Name = "_wc_panel"
gui.ResetOnSpawn = false
gui.Parent = lp:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 200, 0, 196)
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
title.Text = "完成这个词 自动答题"
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

makeToggle("自动答题", 28, function() return state.enabled end, function(v)
    state.enabled = v
end)

makeSlider(58, "基础延迟: %.1f秒", 0.5, 5, state.baseDelay, 0.5, function(v)
    state.baseDelay = v
end)

makeSlider(90, "随机延迟: %.1f秒", 0, 4, state.randDelay, 0.5, function(v)
    state.randDelay = v
end)

status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 60)
status.Position = UDim2.new(0, 8, 0, 122)
status.BackgroundTransparency = 1
status.Text = "状态: 等待对局..."
status.TextColor3 = Color3.fromRGB(150, 200, 150)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextWrapped = true
status.Parent = frame

-- ---------- 答题逻辑 ----------
local function pickWord(req)
    local letter = req:sub(1, 1):upper()
    local list = WORDS[letter]
    if not list then return nil end
    local candidates = {}
    for _, w in ipairs(list) do
        if #w > #req and w:sub(1, #req):lower() == req:lower() and not INST.used[w] then
            table.insert(candidates, w)
        end
    end
    if #candidates == 0 then return nil end
    return candidates[math.random(1, #candidates)]
end

local function typeSuffix(suffix)
    for i = 1, #suffix do
        if not INST.alive then return end
        local ch = suffix:sub(i, i):upper()
        RemoteFunction:InvokeServer("keyStroke", ch)
        task.wait(0.06 + math.random() * 0.09)
    end
end

-- 监听4条入站通道
local function fmtv(v, depth)
    if type(v) == "table" then
        if depth > 1 then return "{...}" end
        local parts = {}
        for k, vv in pairs(v) do
            parts[#parts + 1] = tostring(k) .. "=" .. fmtv(vv, depth + 1)
        end
        return "{" .. table.concat(parts, ","):sub(1, 200) .. "}"
    end
    return tostring(v):sub(1, 80)
end

local handlers = {ev.RemoteEvent, ev.UnreliableRemoteEvent, ev.FastRe, ev.FastUre}
for _, r in ipairs(handlers) do
    bind(r.OnClientEvent:Connect(function(...)
        local args = {...}
        local name = tostring(args[1])
        if name == "updateRound" then
            local round = args[2]
            local turnPlayer = args[4]
            if type(round) == "table" then
                INST.lastRound = round
                INST.turnPlayer = turnPlayer
                log(string.format("updateRound: req=%s turn=%s", tostring(round.RequiredLetter), tostring(turnPlayer)))
            end
        elseif name == "correct" then
            -- 记录别人答对的词(防重复)
            local w = args[2] or args[3]
            if type(w) == "string" and #w > 1 then
                INST.used[w:lower()] = true
                log("correct: " .. w)
            end
        end
    end))
end

-- 答题循环
task.spawn(function()
    while INST.alive do
        local ok, err = pcall(function()
            if not state.enabled then
                setStatus("自动答题已关")
                return
            end
            if not lp:GetAttribute("InGame") then
                setStatus("不在对局中")
                return
            end
            local round = INST.lastRound
            local turn = INST.turnPlayer
            if not round or not turn then
                setStatus("等待对局数据...")
                return
            end
            if turn ~= lp then
                local tn = typeof(turn) == "Instance" and turn.Name or tostring(turn)
                setStatus(string.format("等待别人答 (%s) | 已答%d词", tn, #INST.used and (function() local n=0 for _ in pairs(INST.used) do n=n+1 end return n end)() or 0))
                return
            end
            local req = tostring(round.RequiredLetter or "")
            if req == "" then
                setStatus("本轮无必填字母?")
                return
            end
            -- 我的回合: 延迟+随机延迟
            local wait = state.baseDelay + math.random() * state.randDelay
            setStatus(string.format("轮到我! 必填'%s' | 思考%.1f秒...", req, wait))
            task.wait(wait)
            if not INST.alive then return end
            -- 选词
            local word = pickWord(req)
            if not word then
                setStatus(string.format("词库里 '%s' 开头的词都用完了!", req))
                task.wait(2)
                return
            end
            local suffix = word:sub(#req + 1):upper()
            log(string.format("答题: req=%s word=%s suffix=%s", req, word, suffix))
            -- 逐键发送后缀
            typeSuffix(suffix)
            -- 提交
            RemoteFunction:InvokeServer("tryAnswer")
            INST.used[word:lower()] = true
            setStatus(string.format("已提交 '%s' (后缀%s, %d键)", word, suffix, #suffix))
            INST.lastRound = nil -- 防重复答
        end)
        if not ok then
            log("主循环异常: " .. tostring(err))
            setStatus("异常: " .. tostring(err):sub(1, 40))
        end
        task.wait(0.3)
    end
end)

log("[WordChain v1.0] 自动答题已加载 | 单例守护")
print("[WordChain v1.0] 自动答题已加载 | 单例守护")

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
