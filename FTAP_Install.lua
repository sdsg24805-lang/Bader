-- الصق هذا كامل في خانة الأوامر تحت في Studio ثم اضغط Ctrl+Enter (لازم وانت مو في وضع Play)
local SSS = game:GetService("ServerScriptService")
local SPS = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")

-- يمسح أي نسخة قديمة عشان ما تتكرر
for _, c in SSS:GetChildren() do
	if c:IsA("Script") and (c.Name == "Script" or c.Name == "FTAP_Server") then c:Destroy() end
end
for _, c in SPS:GetChildren() do
	if c:IsA("LocalScript") and (c.Name == "LocalScript" or c.Name == "FTAP_Client") then c:Destroy() end
end

local server = Instance.new("Script")
server.Name = "FTAP_Server"
server.Source = [==[
--[[
	FTAP_Server.lua
	النوع: Script  |  المكان: ServerScriptService
	يتحكم بكل منطق الماب (الإمساك، الرمي، الانفجارات، التيليبورت...)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

--------------------------------------------------------------------
-- الإعدادات (عدّل عليها زي ما تبي)
--------------------------------------------------------------------
local CONFIG = {
	AllowEveryone = true,       -- true = كل اللي بالماب يستخدمون القائمة | false = بس المسموح لهم
	AllowedUserIds = {},        -- مثال: {123456789, 987654321}  (بالإضافة لصاحب الماب)
	DefaultThrow = 80,          -- قوة الرمي العادية (بدون Super Strength)
	DefaultSuperThrow = 400,    -- قوة Super Strength الافتراضية
	MaxThrow = 2000,            -- أعلى قوة رمي مسموحة
	GrabRange = 150,            -- أبعد مسافة تقدر تمسك منها
	MaxRadius = 80,             -- أكبر نطاق للأوامر القريبة
}

--------------------------------------------------------------------
-- RemoteEvent
--------------------------------------------------------------------
local remote = Instance.new("RemoteEvent")
remote.Name = "HubEvent"
remote.Parent = ReplicatedStorage

--------------------------------------------------------------------
-- أدوات مساعدة
--------------------------------------------------------------------
local function isAllowed(plr)
	if CONFIG.AllowEveryone then
		return true
	end
	if plr.UserId == game.CreatorId then
		return true
	end
	return table.find(CONFIG.AllowedUserIds, plr.UserId) ~= nil
end

local function getRoot(plr)
	local char = plr.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function clampNum(v, min, max, default)
	v = tonumber(v)
	if not v or v ~= v then
		return default
	end
	return math.clamp(v, min, max)
end

local function findPlayerByName(name)
	if type(name) ~= "string" or #name == 0 then
		return nil
	end
	name = string.lower(name)
	for _, p in Players:GetPlayers() do
		if string.lower(p.Name):sub(1, #name) == name or string.lower(p.DisplayName):sub(1, #name) == name then
			return p
		end
	end
	return nil
end

local lastUse = {}
local function onCooldown(plr, key, t)
	lastUse[plr] = lastUse[plr] or {}
	local now = os.clock()
	local last = lastUse[plr][key]
	if last and now - last < t then
		return true
	end
	lastUse[plr][key] = now
	return false
end

local function nearbyPlayers(plr, radius)
	local root = getRoot(plr)
	local list = {}
	if not root then
		return list
	end
	for _, other in Players:GetPlayers() do
		if other ~= plr then
			local r = getRoot(other)
			if r and (r.Position - root.Position).Magnitude <= radius then
				table.insert(list, other)
			end
		end
	end
	return list
end

--------------------------------------------------------------------
-- حالة كل لاعب
--------------------------------------------------------------------
local strength = {}   -- قوة الرمي المخصصة
local superOn = {}    -- هل Super Strength شغال
local grabs = {}      -- الإمساك الحالي
local godSet = {}
local auras = {}

local function throwSpeed(plr)
	if superOn[plr] then
		return strength[plr] or CONFIG.DefaultSuperThrow
	end
	return CONFIG.DefaultThrow
end

--------------------------------------------------------------------
-- الإمساك والرمي
--------------------------------------------------------------------
local function releaseGrab(plr, throwDir)
	local g = grabs[plr]
	if not g then
		return
	end
	grabs[plr] = nil

	if g.align then g.align:Destroy() end
	if g.att0 then g.att0:Destroy() end
	if g.holder then g.holder:Destroy() end

	local part = g.part
	if part and part.Parent then
		pcall(function()
			part:SetNetworkOwnershipAuto()
		end)
		local speed = throwSpeed(plr)
		if g.victim then
			if throwDir then
				remote:FireClient(g.victim, "Launch", throwDir * speed, 2)
			else
				remote:FireClient(g.victim, "Launch", Vector3.zero, 0.5)
			end
		elseif throwDir then
			part:ApplyImpulse(throwDir * speed * part.AssemblyMass)
		end
	end
end

local handlers = {}

handlers.Strength = function(plr, v)
	strength[plr] = clampNum(v, 1, CONFIG.MaxThrow, CONFIG.DefaultSuperThrow)
end

handlers.SuperStrength = function(plr, on)
	superOn[plr] = (on == true)
end

handlers.Grab = function(plr, target)
	if grabs[plr] then
		return
	end
	if typeof(target) ~= "Instance" or not target:IsA("BasePart") then
		return
	end
	if not target:IsDescendantOf(Workspace) then
		return
	end
	local myRoot = getRoot(plr)
	if not myRoot then
		return
	end
	if plr.Character and target:IsDescendantOf(plr.Character) then
		return
	end

	local part = target
	local victim = nil
	local model = target:FindFirstAncestorOfClass("Model")
	local victimPlr = model and Players:GetPlayerFromCharacter(model)
	if victimPlr then
		victim = victimPlr
		part = getRoot(victimPlr)
		if not part then
			return
		end
	else
		local rootPart = target.AssemblyRootPart
		if target.Anchored or (rootPart and rootPart.Anchored) then
			return
		end
	end

	if (part.Position - myRoot.Position).Magnitude > CONFIG.GrabRange then
		return
	end

	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = Vector3.one * 0.2
	holder.Position = part.Position
	holder.Parent = Workspace

	local att1 = Instance.new("Attachment")
	att1.Parent = holder

	local att0 = Instance.new("Attachment")
	att0.Parent = part

	local align = Instance.new("AlignPosition")
	align.Mode = Enum.PositionAlignmentMode.TwoAttachment
	align.Attachment0 = att0
	align.Attachment1 = att1
	align.MaxForce = math.huge
	align.MaxVelocity = math.huge
	align.Responsiveness = 40
	align.RigidityEnabled = false
	align.Parent = part

	pcall(function()
		part:SetNetworkOwner(nil)
	end)

	if victim then
		remote:FireClient(victim, "Launch", Vector3.zero, 30)
	end

	grabs[plr] = { part = part, holder = holder, att0 = att0, align = align, victim = victim }
end

handlers.GrabMove = function(plr, pos)
	local g = grabs[plr]
	if not g or typeof(pos) ~= "Vector3" then
		return
	end
	if onCooldown(plr, "GrabMove", 0.03) then
		return
	end
	local root = getRoot(plr)
	if not root or not g.holder.Parent then
		return
	end
	local off = pos - root.Position
	if off.Magnitude > CONFIG.GrabRange then
		pos = root.Position + off.Unit * CONFIG.GrabRange
	end
	g.holder.Position = pos
end

handlers.Release = function(plr, dir)
	local d = nil
	if typeof(dir) == "Vector3" and dir.Magnitude > 0 then
		d = dir.Unit
	end
	releaseGrab(plr, d)
end

--------------------------------------------------------------------
-- أوامر اللاعبين القريبين
--------------------------------------------------------------------
handlers.ThrowNearby = function(plr, radius)
	if onCooldown(plr, "ThrowNearby", 0.4) then
		return
	end
	radius = clampNum(radius, 1, CONFIG.MaxRadius, 25)
	local root = getRoot(plr)
	if not root then
		return
	end
	local speed = throwSpeed(plr)
	for _, other in nearbyPlayers(plr, radius) do
		local r = getRoot(other)
		if r then
			local off = r.Position - root.Position
			local dir = (off.Magnitude > 0.1) and off.Unit or Vector3.yAxis
			remote:FireClient(other, "Launch", (dir + Vector3.new(0, 0.6, 0)).Unit * speed, 2)
		end
	end
end

handlers.RagdollNearby = function(plr, radius)
	if onCooldown(plr, "RagdollNearby", 0.5) then
		return
	end
	radius = clampNum(radius, 1, CONFIG.MaxRadius, 25)
	for _, other in nearbyPlayers(plr, radius) do
		remote:FireClient(other, "Launch", Vector3.zero, 4)
	end
end

handlers.FreezeNearby = function(plr, radius)
	if onCooldown(plr, "FreezeNearby", 0.5) then
		return
	end
	radius = clampNum(radius, 1, CONFIG.MaxRadius, 25)
	for _, other in nearbyPlayers(plr, radius) do
		local r = getRoot(other)
		if r then
			r.Anchored = true
			task.delay(4, function()
				if r.Parent then
					r.Anchored = false
				end
			end)
		end
	end
end

handlers.FlingPlayer = function(plr, name)
	if onCooldown(plr, "FlingPlayer", 0.5) then
		return
	end
	local target = findPlayerByName(name)
	if not target or target == plr then
		return
	end
	local dir = Vector3.new(math.random(-100, 100) / 100, 1, math.random(-100, 100) / 100).Unit
	remote:FireClient(target, "Launch", dir * throwSpeed(plr), 2.5)
end

--------------------------------------------------------------------
-- الانفجارات
--------------------------------------------------------------------
local function explode(plr, pos, radius, pressure, includeSelf)
	local e = Instance.new("Explosion")
	e.Position = pos
	e.BlastRadius = radius
	e.BlastPressure = pressure
	e.DestroyJointRadiusPercent = 0 -- ما يكسر المفاصل ولا يقتل
	e.ExplosionType = Enum.ExplosionType.NoCraters
	e.Parent = Workspace

	local power = math.clamp(pressure / 250000, 0.2, 4)
	for _, other in Players:GetPlayers() do
		if includeSelf or other ~= plr then
			local r = getRoot(other)
			if r then
				local off = r.Position - pos
				if off.Magnitude <= radius then
					local dir = (off.Magnitude > 0.1) and off.Unit or Vector3.yAxis
					remote:FireClient(other, "Launch", (dir * 70 + Vector3.new(0, 50, 0)) * power, 1.5)
				end
			end
		end
	end
end

handlers.Explode = function(plr, pos, radius, pressure, includeSelf)
	if onCooldown(plr, "Explode", 0.15) then
		return
	end
	local root = getRoot(plr)
	if not root or typeof(pos) ~= "Vector3" then
		return
	end
	if (pos - root.Position).Magnitude > 1000 then
		return
	end
	radius = clampNum(radius, 1, 60, 15)
	pressure = clampNum(pressure, 0, 500000, 250000)
	explode(plr, pos, radius, pressure, includeSelf == true)
end

handlers.Aura = function(plr, on)
	auras[plr] = (on == true)
end

task.spawn(function()
	while true do
		task.wait(0.5)
		for plr, enabled in auras do
			if enabled then
				local root = getRoot(plr)
				if root then
					explode(plr, root.Position, 14, 150000, false)
				end
			end
		end
	end
end)

--------------------------------------------------------------------
-- حماية (God Mode)
--------------------------------------------------------------------
local function applyGod(plr)
	local char = plr.Character
	if not char then
		return
	end
	local old = char:FindFirstChild("HubGod")
	if godSet[plr] then
		if not old then
			local ff = Instance.new("ForceField")
			ff.Name = "HubGod"
			ff.Visible = false
			ff.Parent = char
		end
	elseif old then
		old:Destroy()
	end
end

handlers.God = function(plr, on)
	godSet[plr] = (on == true)
	applyGod(plr)
end

--------------------------------------------------------------------
-- التيليبورت
--------------------------------------------------------------------
handlers.TeleportToPlayer = function(plr, name)
	local target = findPlayerByName(name)
	local tRoot = target and getRoot(target)
	if not tRoot or not plr.Character then
		return
	end
	plr.Character:PivotTo(tRoot.CFrame * CFrame.new(0, 3, 4))
end

handlers.BringPlayer = function(plr, name)
	local target = findPlayerByName(name)
	local root = getRoot(plr)
	if not target or target == plr or not root or not target.Character then
		return
	end
	target.Character:PivotTo(root.CFrame * CFrame.new(0, 3, -5))
end

handlers.TeleportToSpawn = function(plr)
	if not plr.Character then
		return
	end
	local spawn = Workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawn then
		plr.Character:PivotTo(spawn.CFrame + Vector3.new(0, 5, 0))
	else
		plr.Character:PivotTo(CFrame.new(0, 10, 0))
	end
end

--------------------------------------------------------------------
-- العالم
--------------------------------------------------------------------
handlers.Gravity = function(plr, v)
	Workspace.Gravity = clampNum(v, 10, 400, 196.2)
end

handlers.Time = function(plr, v)
	Lighting.ClockTime = clampNum(v, 0, 24, 14)
end

--------------------------------------------------------------------
-- الربط
--------------------------------------------------------------------
remote.OnServerEvent:Connect(function(plr, action, ...)
	if not isAllowed(plr) then
		return
	end
	local fn = handlers[action]
	if fn then
		fn(plr, ...)
	end
end)

local function setupPlayer(plr)
	plr:SetAttribute("HubAllowed", isAllowed(plr))
	plr.CharacterAdded:Connect(function()
		task.wait(0.2)
		applyGod(plr)
	end)
end

Players.PlayerAdded:Connect(setupPlayer)
for _, p in Players:GetPlayers() do
	setupPlayer(p)
end

Players.PlayerRemoving:Connect(function(plr)
	releaseGrab(plr, nil)
	strength[plr], superOn[plr], godSet[plr], auras[plr], lastUse[plr] = nil, nil, nil, nil, nil
end)

]==]
server.Parent = SSS

local client = Instance.new("LocalScript")
client.Name = "FTAP_Client"
client.Source = [==[
--[[
	FTAP_Client.lua
	النوع: LocalScript  |  المكان: StarterPlayer > StarterPlayerScripts
	يبني الواجهة (تبويبات + بحث + تصغير/إغلاق) ويرسل الأوامر للسيرفر
	زر RightShift أو الزر الصغير (☰) يفتح/يخفي القائمة
]]

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local camera = Workspace.CurrentCamera
local remote = ReplicatedStorage:WaitForChild("HubEvent")

-- ننتظر السيرفر يحدد إذا اللاعب مسموح له
for _ = 1, 50 do
	if player:GetAttribute("HubAllowed") ~= nil then
		break
	end
	task.wait(0.1)
end
if not player:GetAttribute("HubAllowed") then
	return
end

--------------------------------------------------------------------
-- الحالة
--------------------------------------------------------------------
local state = {
	grab = false,
	grabbing = false,
	grabDist = 30,
	clickExplode = false,
	clickTP = false,
	fly = false,
	flySpeed = 60,
	noclip = false,
	infJump = false,
	spin = false,
	esp = false,
	walkSpeed = nil,
	jumpPower = nil,
	exSize = 15,
	exPressure = 250000,
	radius = 25,
	targetName = "",
}

local function getChar() return player.Character end
local function getHum()
	local c = getChar()
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function getRoot()
	local c = getChar()
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function num(t, d)
	return tonumber(t) or d
end

--------------------------------------------------------------------
-- استقبال الأوامر من السيرفر (الرمي والـ Ragdoll)
--------------------------------------------------------------------
local launchToken = 0
remote.OnClientEvent:Connect(function(action, vel, ragdollSecs)
	if action ~= "Launch" then
		return
	end
	local root, hum = getRoot(), getHum()
	if not root or not hum then
		return
	end
	launchToken += 1
	local myToken = launchToken
	hum:ChangeState(Enum.HumanoidStateType.Physics)
	if typeof(vel) == "Vector3" and vel.Magnitude > 0 then
		root.AssemblyLinearVelocity = vel
	end
	task.delay(tonumber(ragdollSecs) or 1.5, function()
		if myToken == launchToken and hum.Parent then
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end)
end)

--------------------------------------------------------------------
-- مميزات اللاعب: طيران / اختراق / قفز لا نهائي / دوران / سرعة
--------------------------------------------------------------------
local flyBV, flyBG

local function setFly(on)
	state.fly = on
	local root, hum = getRoot(), getHum()
	if flyBV then flyBV:Destroy() flyBV = nil end
	if flyBG then flyBG:Destroy() flyBG = nil end
	if on and root and hum then
		flyBV = Instance.new("BodyVelocity")
		flyBV.MaxForce = Vector3.one * 1e6
		flyBV.Velocity = Vector3.zero
		flyBV.Parent = root
		flyBG = Instance.new("BodyGyro")
		flyBG.MaxTorque = Vector3.one * 1e6
		flyBG.P = 1e4
		flyBG.CFrame = root.CFrame
		flyBG.Parent = root
		hum.PlatformStand = true
	elseif hum then
		hum.PlatformStand = false
	end
end

RunService.RenderStepped:Connect(function(dt)
	local root, hum = getRoot(), getHum()
	if not root or not hum then
		return
	end

	if state.fly and flyBV and flyBG then
		local dir = hum.MoveDirection
		if UIS:IsKeyDown(Enum.KeyCode.Space) then
			dir += Vector3.yAxis
		end
		if UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.Q) then
			dir -= Vector3.yAxis
		end
		flyBV.Velocity = dir * state.flySpeed
		local look = camera.CFrame.LookVector
		flyBG.CFrame = CFrame.lookAt(root.Position, root.Position + Vector3.new(look.X, 0, look.Z))
	end

	if state.spin then
		root.CFrame *= CFrame.Angles(0, math.rad(720) * dt, 0)
	end
end)

RunService.Stepped:Connect(function()
	if state.noclip then
		local c = getChar()
		if c then
			for _, p in c:GetDescendants() do
				if p:IsA("BasePart") then
					p.CanCollide = false
				end
			end
		end
	end
end)

RunService.Heartbeat:Connect(function()
	local hum = getHum()
	if not hum then
		return
	end
	if state.walkSpeed then
		hum.WalkSpeed = state.walkSpeed
	end
	if state.jumpPower then
		hum.UseJumpPower = true
		hum.JumpPower = state.jumpPower
	end
end)

UIS.JumpRequest:Connect(function()
	if state.infJump then
		local hum = getHum()
		if hum then
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end
end)

player.CharacterAdded:Connect(function()
	task.wait(0.5)
	if state.fly then
		setFly(true)
	end
end)

--------------------------------------------------------------------
-- ESP
--------------------------------------------------------------------
local espObjs = {}

local function clearESP(p)
	local items = espObjs[p]
	if items then
		for _, i in items do
			i:Destroy()
		end
		espObjs[p] = nil
	end
end

local function applyESP(p)
	clearESP(p)
	if not state.esp or p == player or not p.Character then
		return
	end
	local h = Instance.new("Highlight")
	h.FillColor = Color3.fromRGB(255, 60, 60)
	h.FillTransparency = 0.6
	h.OutlineColor = Color3.new(1, 1, 1)
	h.Parent = p.Character
	local items = { h }

	local head = p.Character:FindFirstChild("Head")
	if head then
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromOffset(140, 22)
		bb.StudsOffset = Vector3.new(0, 2.6, 0)
		bb.AlwaysOnTop = true
		bb.Adornee = head
		local tl = Instance.new("TextLabel")
		tl.Size = UDim2.fromScale(1, 1)
		tl.BackgroundTransparency = 1
		tl.Text = p.DisplayName
		tl.TextColor3 = Color3.new(1, 1, 1)
		tl.TextStrokeTransparency = 0.4
		tl.Font = Enum.Font.GothamBold
		tl.TextSize = 14
		tl.Parent = bb
		bb.Parent = head
		table.insert(items, bb)
	end
	espObjs[p] = items
end

local function hookESP(p)
	p.CharacterAdded:Connect(function()
		task.wait(0.5)
		applyESP(p)
	end)
end

for _, p in Players:GetPlayers() do
	hookESP(p)
end
Players.PlayerAdded:Connect(hookESP)
Players.PlayerRemoving:Connect(clearESP)

local function setESP(on)
	state.esp = on
	for _, p in Players:GetPlayers() do
		if on then
			applyESP(p)
		else
			clearESP(p)
		end
	end
end

--------------------------------------------------------------------
-- الإمساك والرمي + النقر (انفجار / تيليبورت)
--------------------------------------------------------------------
local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function mouseRay()
	local loc = UIS:GetMouseLocation()
	return camera:ViewportPointToRay(loc.X, loc.Y)
end

UIS.InputBegan:Connect(function(input, gp)
	if gp or not isPress(input) then
		return
	end

	if state.grab then
		local target = mouse.Target
		if target then
			state.grabDist = math.clamp((target.Position - camera.CFrame.Position).Magnitude, 8, 120)
			state.grabbing = true
			remote:FireServer("Grab", target)
		end
	end

	if state.clickExplode and mouse.Hit then
		remote:FireServer("Explode", mouse.Hit.Position, state.exSize, state.exPressure, false)
	end

	if state.clickTP and mouse.Hit then
		local root = getRoot()
		if root then
			root.CFrame = CFrame.new(mouse.Hit.Position + Vector3.new(0, 4, 0))
		end
	end
end)

UIS.InputEnded:Connect(function(input)
	if isPress(input) and state.grabbing then
		state.grabbing = false
		remote:FireServer("Release", mouseRay().Direction)
	end
end)

local sendTimer = 0
RunService.RenderStepped:Connect(function(dt)
	if state.grabbing then
		sendTimer += dt
		if sendTimer >= 0.05 then
			sendTimer = 0
			local ray = mouseRay()
			remote:FireServer("GrabMove", ray.Origin + ray.Direction * state.grabDist)
		end
	end
end)

--------------------------------------------------------------------
-- بناء الواجهة
--------------------------------------------------------------------
local C = {
	bg = Color3.fromRGB(24, 24, 27),
	side = Color3.fromRGB(30, 30, 34),
	row = Color3.fromRGB(38, 38, 43),
	stroke = Color3.fromRGB(60, 60, 68),
	text = Color3.fromRGB(235, 235, 240),
	dim = Color3.fromRGB(150, 150, 160),
	accent = Color3.fromRGB(90, 130, 255),
	off = Color3.fromRGB(70, 70, 78),
}

local function make(class, props, parent)
	local o = Instance.new(class)
	for k, v in props do
		o[k] = v
	end
	o.Parent = parent
	return o
end

local function corner(parent, r)
	return make("UICorner", { CornerRadius = UDim.new(0, r or 8) }, parent)
end

local gui = make("ScreenGui", {
	Name = "FTAPHub",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, player:WaitForChild("PlayerGui"))

local main = make("Frame", {
	Size = UDim2.fromOffset(580, 380),
	Position = UDim2.new(0.5, -290, 0.5, -190),
	BackgroundColor3 = C.bg,
	BorderSizePixel = 0,
}, gui)
corner(main, 10)
make("UIStroke", { Color = C.stroke, Thickness = 1 }, main)

-- شريط العنوان
local titleBar = make("Frame", { Size = UDim2.new(1, 0, 0, 44), BackgroundTransparency = 1 }, main)
make("TextLabel", {
	Text = "FTAP Private Hub",
	Font = Enum.Font.GothamBold,
	TextSize = 18,
	TextColor3 = C.text,
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(16, 0),
	Size = UDim2.new(1, -110, 1, 0),
	TextXAlignment = Enum.TextXAlignment.Left,
}, titleBar)

local function titleButton(text, xOffset)
	local b = make("TextButton", {
		Text = text,
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		TextColor3 = C.text,
		BackgroundColor3 = C.row,
		Size = UDim2.fromOffset(32, 28),
		Position = UDim2.new(1, xOffset, 0, 8),
		AutoButtonColor = true,
	}, titleBar)
	corner(b, 6)
	return b
end
local minBtn = titleButton("–", -78)
local closeBtn = titleButton("✕", -40)

local body = make("Frame", {
	Size = UDim2.new(1, 0, 1, -44),
	Position = UDim2.fromOffset(0, 44),
	BackgroundTransparency = 1,
}, main)

-- سحب النافذة
do
	local dragging, dragStart, startPos
	titleBar.InputBegan:Connect(function(i)
		if isPress(i) then
			dragging = true
			dragStart = i.Position
			startPos = main.Position
		end
	end)
	UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	UIS.InputEnded:Connect(function(i)
		if isPress(i) then
			dragging = false
		end
	end)
end

-- القائمة الجانبية
local sidebar = make("Frame", {
	Size = UDim2.new(0, 150, 1, -8),
	Position = UDim2.fromOffset(8, 0),
	BackgroundColor3 = C.side,
	BorderSizePixel = 0,
}, body)
corner(sidebar, 8)

local searchBox = make("TextBox", {
	PlaceholderText = "Search...",
	Text = "",
	ClearTextOnFocus = false,
	Font = Enum.Font.Gotham,
	TextSize = 14,
	TextColor3 = C.text,
	PlaceholderColor3 = C.dim,
	BackgroundColor3 = C.row,
	Size = UDim2.new(1, -16, 0, 30),
	Position = UDim2.fromOffset(8, 8),
}, sidebar)
corner(searchBox, 6)

local tabList = make("ScrollingFrame", {
	Size = UDim2.new(1, -8, 1, -50),
	Position = UDim2.fromOffset(4, 46),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 2,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
}, sidebar)
make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, tabList)

-- منطقة المحتوى
local content = make("ScrollingFrame", {
	Size = UDim2.new(1, -176, 1, -8),
	Position = UDim2.fromOffset(166, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
}, body)
make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, content)
make("UIPadding", { PaddingRight = UDim.new(0, 6) }, content)

--------------------------------------------------------------------
-- نظام الصفوف والتبويبات والبحث
--------------------------------------------------------------------
local rows = {}
local tabButtons = {}
local currentTab = "Combat"
local order = 0

local function refresh()
	local q = string.lower(searchBox.Text)
	for _, r in rows do
		if q == "" then
			r.frame.Visible = (r.tab == currentTab)
		else
			r.frame.Visible = (r.name ~= nil) and (string.find(string.lower(r.name), q, 1, true) ~= nil)
		end
	end
	for name, b in tabButtons do
		b.BackgroundColor3 = (name == currentTab and q == "") and C.accent or C.side
	end
end

local tabOrder = 0
local function addTab(name)
	tabOrder += 1
	local b = make("TextButton", {
		Text = name,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = C.text,
		BackgroundColor3 = C.side,
		Size = UDim2.new(1, -4, 0, 32),
		LayoutOrder = tabOrder,
		AutoButtonColor = false,
	}, tabList)
	corner(b, 6)
	tabButtons[name] = b
	b.MouseButton1Click:Connect(function()
		currentTab = name
		searchBox.Text = ""
		refresh()
	end)
end

local function newRow(tab, name, height)
	order += 1
	local f = make("Frame", {
		Size = UDim2.new(1, -2, 0, height or 38),
		BackgroundColor3 = C.row,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Visible = false,
	}, content)
	corner(f, 8)
	table.insert(rows, { frame = f, tab = tab, name = name })
	return f
end

local function rowLabel(f, text)
	return make("TextLabel", {
		Text = text,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = C.text,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -120, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
	}, f)
end

local function addSection(tab, text)
	local f = newRow(tab, nil, 24)
	f.BackgroundTransparency = 1
	make("TextLabel", {
		Text = text,
		Font = Enum.Font.GothamMedium,
		TextSize = 13,
		TextColor3 = C.dim,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
	}, f)
end

local function addToggle(tab, name, cb)
	local f = newRow(tab, name)
	rowLabel(f, name)
	local box = make("TextButton", {
		Text = "",
		Size = UDim2.fromOffset(26, 26),
		Position = UDim2.new(1, -38, 0.5, -13),
		BackgroundColor3 = C.off,
		AutoButtonColor = false,
	}, f)
	corner(box, 6)
	local on = false
	box.MouseButton1Click:Connect(function()
		on = not on
		box.BackgroundColor3 = on and C.accent or C.off
		cb(on)
	end)
end

local function addInput(tab, name, default, cb)
	local f = newRow(tab, name)
	rowLabel(f, name)
	local box = make("TextBox", {
		Text = tostring(default),
		ClearTextOnFocus = false,
		Font = Enum.Font.Gotham,
		TextSize = 14,
		TextColor3 = C.text,
		BackgroundColor3 = C.bg,
		Size = UDim2.fromOffset(90, 26),
		Position = UDim2.new(1, -102, 0.5, -13),
	}, f)
	corner(box, 6)
	box.FocusLost:Connect(function()
		cb(box.Text)
	end)
end

local function addButton(tab, name, cb)
	local f = newRow(tab, name)
	local b = make("TextButton", {
		Text = name,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		TextColor3 = C.text,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	}, f)
	b.MouseButton1Click:Connect(cb)
end

--------------------------------------------------------------------
-- التبويبات والمميزات
--------------------------------------------------------------------
for _, t in { "Combat", "Player", "ESP", "Explosions", "Teleport", "World" } do
	addTab(t)
end

-- Combat ------------------------------------------------------------
addSection("Combat", "Strength")
addToggle("Combat", "Super Strength", function(on)
	remote:FireServer("SuperStrength", on)
end)
addInput("Combat", "Strength", 400, function(t)
	remote:FireServer("Strength", num(t, 400))
end)
addToggle("Combat", "Grab & Throw (اضغط وأمسك، اترك للرمي)", function(on)
	state.grab = on
end)

addSection("Combat", "Nearby Players")
addInput("Combat", "Radius", 25, function(t)
	state.radius = math.clamp(num(t, 25), 1, 80)
end)
addButton("Combat", "Throw Nearby Players", function()
	remote:FireServer("ThrowNearby", state.radius)
end)
addButton("Combat", "Ragdoll Nearby Players", function()
	remote:FireServer("RagdollNearby", state.radius)
end)
addButton("Combat", "Freeze Nearby Players (4s)", function()
	remote:FireServer("FreezeNearby", state.radius)
end)
addInput("Combat", "Player Name", "", function(t)
	state.targetName = t
end)
addButton("Combat", "Fling Player (by name)", function()
	remote:FireServer("FlingPlayer", state.targetName)
end)

-- Player ------------------------------------------------------------
addSection("Player", "Movement")
addInput("Player", "Walk Speed", 16, function(t)
	state.walkSpeed = math.clamp(num(t, 16), 0, 200)
end)
addInput("Player", "Jump Power", 50, function(t)
	state.jumpPower = math.clamp(num(t, 50), 0, 300)
end)
addToggle("Player", "Infinite Jump", function(on)
	state.infJump = on
end)
addToggle("Player", "Fly (Space فوق / Ctrl تحت)", setFly)
addInput("Player", "Fly Speed", 60, function(t)
	state.flySpeed = math.clamp(num(t, 60), 5, 300)
end)
addToggle("Player", "Noclip", function(on)
	state.noclip = on
end)
addToggle("Player", "Spin", function(on)
	state.spin = on
end)

addSection("Player", "Protection")
addToggle("Player", "God Mode", function(on)
	remote:FireServer("God", on)
end)
addButton("Player", "Reset Character", function()
	local hum = getHum()
	if hum then
		hum.Health = 0
	end
end)

-- ESP ---------------------------------------------------------------
addSection("ESP", "Visuals")
addToggle("ESP", "Player ESP", setESP)

-- Explosions --------------------------------------------------------
addSection("Explosions", "Settings")
addInput("Explosions", "Size", 15, function(t)
	state.exSize = math.clamp(num(t, 15), 1, 60)
end)
addInput("Explosions", "Pressure", 250000, function(t)
	state.exPressure = math.clamp(num(t, 250000), 0, 500000)
end)

addSection("Explosions", "Actions")
addToggle("Explosions", "Click Explosion", function(on)
	state.clickExplode = on
end)
addToggle("Explosions", "Explosion Aura", function(on)
	remote:FireServer("Aura", on)
end)
addButton("Explosions", "Explode Myself (launch)", function()
	local root = getRoot()
	if root then
		remote:FireServer("Explode", root.Position - Vector3.new(0, 2, 0), state.exSize, state.exPressure, true)
	end
end)

-- Teleport ----------------------------------------------------------
addSection("Teleport", "Players")
addInput("Teleport", "Player Name", "", function(t)
	state.targetName = t
end)
addButton("Teleport", "Teleport To Player", function()
	remote:FireServer("TeleportToPlayer", state.targetName)
end)
addButton("Teleport", "Bring Player", function()
	remote:FireServer("BringPlayer", state.targetName)
end)

addSection("Teleport", "Places")
addToggle("Teleport", "Click Teleport", function(on)
	state.clickTP = on
end)
addButton("Teleport", "Teleport To Spawn", function()
	remote:FireServer("TeleportToSpawn")
end)

-- World -------------------------------------------------------------
addSection("World", "Environment")
addInput("World", "Gravity", 196.2, function(t)
	remote:FireServer("Gravity", num(t, 196.2))
end)
addButton("World", "Reset Gravity", function()
	remote:FireServer("Gravity", 196.2)
end)
addInput("World", "Time of Day (0-24)", 14, function(t)
	remote:FireServer("Time", num(t, 14))
end)

--------------------------------------------------------------------
-- أزرار النافذة
--------------------------------------------------------------------
local minimized = false
minBtn.MouseButton1Click:Connect(function()
	minimized = not minimized
	body.Visible = not minimized
	main.Size = minimized and UDim2.fromOffset(580, 44) or UDim2.fromOffset(580, 380)
end)

closeBtn.MouseButton1Click:Connect(function()
	main.Visible = false
end)

-- زر عائم صغير (مفيد للجوال)
local floatBtn = make("TextButton", {
	Text = "☰",
	Font = Enum.Font.GothamBold,
	TextSize = 20,
	TextColor3 = C.text,
	BackgroundColor3 = C.bg,
	Size = UDim2.fromOffset(40, 40),
	Position = UDim2.new(0, 10, 0.5, -20),
}, gui)
corner(floatBtn, 10)
make("UIStroke", { Color = C.stroke, Thickness = 1 }, floatBtn)
floatBtn.MouseButton1Click:Connect(function()
	main.Visible = not main.Visible
end)

UIS.InputBegan:Connect(function(input, gp)
	if not gp and input.KeyCode == Enum.KeyCode.RightShift then
		main.Visible = not main.Visible
	end
end)

searchBox:GetPropertyChangedSignal("Text"):Connect(refresh)
refresh()

]==]
client.Parent = SPS

print("تم تركيب سكربتات FTAP بنجاح! اضغط Play")
