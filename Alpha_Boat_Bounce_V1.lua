--[[
	ALPHA BOAT BOUNCE V1  -  2D arcade mini-game inside a compact GUI

	ENVIRONMENT
	  * Roblox Studio:  put this in a LocalScript (StarterPlayer > StarterPlayerScripts).
	    It must be a LocalScript, NOT a normal Script (it builds a GUI and reads local input).
	  * Executor: execute it as a client script; it parents itself to PlayerGui.

	HOW TO PLAY
	  * Press START. A glowing ball falls; slide the boat under it to bounce it back up.
	  * PC:     A / D  or  Left / Right arrow keys (they are captured only while a game runs)
	  * Mobile: hold the on-screen  <  and  >  buttons
	  * Every catch = +10 score, +1 bounce. The ball gets faster and bounces harder (with caps).
	    Hit the boat off-centre to steer the ball sideways.
	  * Miss the ball (it drops below the boat) = GAME OVER -> RESTART or MENU.

	NOTES
	  * Re-running the script removes the old GUI, loop and key bindings first (no duplicates).
	  * Best score is kept for the current session only (no DataStore).
	  * The physics section (between the PHYSICS markers) has no Roblox dependencies.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GUI_NAME = "AlphaBoatBounceV1"

--==================================================
-- CLEAN UP A PREVIOUS RUN
--==================================================
if typeof(_G.AlphaBoatBounce_Cleanup) == "function" then
	pcall(_G.AlphaBoatBounce_Cleanup)
end
do
	local old = playerGui:FindFirstChild(GUI_NAME)
	if old then old:Destroy() end
end
pcall(function() ContextActionService:UnbindAction("ABB_Left") end)
pcall(function() ContextActionService:UnbindAction("ABB_Right") end)

local alive = true
local connections = {}
local function bind(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

--==================================================
-- PHYSICS  (pure logic, no Roblox APIs)
--==================================================
--[[PHYSICS_BEGIN]]
local Physics = {}

Physics.ARENA_W = 280
Physics.ARENA_H = 340
Physics.BALL_R = 9
Physics.BOAT_W = 68
Physics.BOAT_H = 12
Physics.BOAT_Y = 306            -- y of the boat deck (top edge)
Physics.BOAT_SPEED = 340        -- max boat speed (px/s)
Physics.BOAT_ACCEL = 2600       -- boat acceleration (px/s^2)
Physics.GRAVITY = 640           -- base gravity (px/s^2)
Physics.GRAVITY_GAIN = 0.015    -- +1.5% gravity per bounce ...
Physics.GRAVITY_MAX_BONUS = 0.45 -- ... up to +45%
Physics.BASE_BOUNCE = 470       -- upward speed of the first bounce
Physics.BOUNCE_GAIN = 12        -- extra upward speed per bounce
Physics.MAX_BOUNCE = 740        -- cap for bounce power
Physics.MAX_FALL = 880          -- terminal fall speed
Physics.MAX_SPEED = 960         -- cap for total ball speed
Physics.SPIN_BASE = 200         -- sideways speed cap at the start ...
Physics.SPIN_GAIN = 8           -- ... grows per bounce ...
Physics.SPIN_MAX = 460          -- ... up to this
Physics.SUBSTEP = 1 / 120       -- fixed physics step (no tunnelling)
Physics.MAX_DT = 1 / 20         -- longest frame we simulate in one call
Physics.SCORE_PER_BOUNCE = 10

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

function Physics.reset(s, rng)
	rng = rng or math.random
	local R, W = Physics.BALL_R, Physics.ARENA_W
	s.bx = W / 2          -- boat centre x
	s.bvx = 0             -- boat velocity
	s.x = R + 6 + rng() * (W - 2 * R - 12) -- ball starts at the top
	s.y = R + 2
	s.vx = (rng() - 0.5) * 120
	s.vy = 0
	s.score = 0
	s.bounces = 0
	s.speed = 0
	s.over = false
	return s
end

function Physics.new(rng)
	return Physics.reset({}, rng)
end

function Physics.bouncePower(bounces)
	return math.min(Physics.BASE_BOUNCE + bounces * Physics.BOUNCE_GAIN, Physics.MAX_BOUNCE)
end

function Physics.gravity(bounces)
	return Physics.GRAVITY * (1 + math.min(bounces * Physics.GRAVITY_GAIN, Physics.GRAVITY_MAX_BONUS))
end

local function substep(s, h, dir, ev)
	local R, W = Physics.BALL_R, Physics.ARENA_W
	local BW, BH, BY = Physics.BOAT_W, Physics.BOAT_H, Physics.BOAT_Y

	-- boat: accelerate towards the wanted speed, stay inside the arena
	local want = clamp(dir, -1, 1) * Physics.BOAT_SPEED
	local dv = clamp(want - s.bvx, -Physics.BOAT_ACCEL * h, Physics.BOAT_ACCEL * h)
	s.bvx = s.bvx + dv
	s.bx = s.bx + s.bvx * h
	local lo, hi = BW / 2, W - BW / 2
	if s.bx < lo then s.bx = lo; s.bvx = 0 end
	if s.bx > hi then s.bx = hi; s.bvx = 0 end

	-- ball: gravity + velocity integration
	local prevBottom = s.y + R
	s.vy = s.vy + Physics.gravity(s.bounces) * h
	if s.vy > Physics.MAX_FALL then s.vy = Physics.MAX_FALL end
	s.x = s.x + s.vx * h
	s.y = s.y + s.vy * h

	-- walls and ceiling
	if s.x < R then
		s.x = R
		s.vx = math.abs(s.vx)
		ev.wall = true
	elseif s.x > W - R then
		s.x = W - R
		s.vx = -math.abs(s.vx)
		ev.wall = true
	end
	if s.y < R then
		s.y = R
		s.vy = math.abs(s.vy) * 0.85
		ev.wall = true
	end

	-- boat collision (only while falling, so one landing = one bounce)
	if s.vy > 0 then
		local left, right = s.bx - BW / 2, s.bx + BW / 2
		local cx = clamp(s.x, left, right)
		local cy = clamp(s.y, BY, BY + BH)
		local dx, dy = s.x - cx, s.y - cy
		local touching = (dx * dx + dy * dy) <= R * R
		local swept = prevBottom <= BY + 1 and s.y + R >= BY
			and s.x >= left - R * 0.7 and s.x <= right + R * 0.7
		if (touching or swept) and s.y <= BY + BH * 0.35 then
			s.bounces = s.bounces + 1
			s.score = s.score + Physics.SCORE_PER_BOUNCE
			s.y = BY - R
			s.vy = -Physics.bouncePower(s.bounces)

			local spinCap = math.min(Physics.SPIN_BASE + s.bounces * Physics.SPIN_GAIN, Physics.SPIN_MAX)
			local offset = clamp((s.x - s.bx) / (BW / 2), -1, 1)
			s.vx = clamp(offset * spinCap * 0.85 + s.bvx * 0.3, -spinCap, spinCap)

			-- keep the total speed under the global cap
			local sp = math.sqrt(s.vx * s.vx + s.vy * s.vy)
			if sp > Physics.MAX_SPEED then
				local k = Physics.MAX_SPEED / sp
				s.vx = s.vx * k
				s.vy = s.vy * k
			end
			ev.bounce = true
			ev.hitX = s.x
			ev.hitY = BY
		end
	end

	-- missed: the ball went below the boat deck without being caught
	if s.y > BY + BH then
		s.over = true
		ev.over = true
	end
end

-- Advances the simulation by dt seconds. dir = -1 (left), 0, 1 (right).
-- Returns an events table: bounce, wall, over (+ hitX/hitY).
function Physics.step(s, dt, dir)
	local ev = { bounce = false, wall = false, over = false, hitX = 0, hitY = 0 }
	if s.over then return ev end
	if dt ~= dt or dt <= 0 then return ev end -- NaN / non-positive guard
	if dt > Physics.MAX_DT then dt = Physics.MAX_DT end

	local remaining = dt
	while remaining > 1e-9 and not s.over do
		local h = math.min(remaining, Physics.SUBSTEP)
		remaining = remaining - h
		substep(s, h, dir or 0, ev)
	end
	s.speed = math.sqrt(s.vx * s.vx + s.vy * s.vy)
	return ev
end
--[[PHYSICS_END]]

--==================================================
-- THEME + HELPERS
--==================================================
local C = {
	bg = Color3.fromRGB(10, 8, 22),
	panel = Color3.fromRGB(22, 18, 44),
	panel2 = Color3.fromRGB(32, 26, 62),
	hover = Color3.fromRGB(52, 40, 100),
	purple = Color3.fromRGB(150, 70, 255),
	blue = Color3.fromRGB(40, 170, 255),
	text = Color3.fromRGB(236, 238, 255),
	muted = Color3.fromRGB(150, 150, 195),
	red = Color3.fromRGB(255, 70, 100),
	green = Color3.fromRGB(70, 230, 160),
	gold = Color3.fromRGB(255, 205, 90),
}

local function tween(obj, t, props, style, dir)
	local tw = TweenService:Create(obj, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function corner(p, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = p
	return c
end

local function gradient(p, rot, c0, c1)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(c0 or C.purple, c1 or C.blue)
	g.Rotation = rot or 0
	g.Parent = p
	return g
end

local function stroke(p, thick, transp)
	local s = Instance.new("UIStroke")
	s.Thickness = thick or 1
	s.Transparency = transp or 0
	s.Color = Color3.new(1, 1, 1)
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = p
	local g = gradient(s, 0)
	return s, g
end

local function frame(parent, pos, size, color)
	local f = Instance.new("Frame")
	f.Position = pos
	f.Size = size
	f.BackgroundColor3 = color or C.panel
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function label(parent, text, size, color, font, xalign)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color or C.text
	l.Font = font or Enum.Font.GothamMedium
	l.TextXAlignment = xalign or Enum.TextXAlignment.Center
	l.Parent = parent
	return l
end

local function button(parent, text, pos, size, textSize, callback)
	local b = Instance.new("TextButton")
	b.Position = pos
	b.Size = size
	b.BackgroundColor3 = C.panel2
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Text = text
	b.TextColor3 = C.text
	b.TextSize = textSize or 14
	b.Font = Enum.Font.GothamBold
	b.Parent = parent
	corner(b, 10)
	local s = stroke(b, 1.2, 0.5)
	local sc = Instance.new("UIScale", b)
	bind(b.MouseEnter, function()
		tween(b, 0.15, { BackgroundColor3 = C.hover })
		tween(s, 0.15, { Transparency = 0 })
	end)
	bind(b.MouseLeave, function()
		tween(b, 0.15, { BackgroundColor3 = C.panel2 })
		tween(s, 0.15, { Transparency = 0.5 })
		tween(sc, 0.12, { Scale = 1 })
	end)
	bind(b.MouseButton1Down, function() tween(sc, 0.07, { Scale = 0.93 }) end)
	bind(b.MouseButton1Up, function() tween(sc, 0.12, { Scale = 1 }, Enum.EasingStyle.Back) end)
	if callback then bind(b.MouseButton1Click, callback) end
	return b
end

--==================================================
-- GUI LAYOUT
--==================================================
local AW, AH = Physics.ARENA_W, Physics.ARENA_H
local WIDTH = AW + 20
local HEADER = 36
local STATS_Y = HEADER + 4
local ARENA_Y = STATS_Y + 42
local CTRL_Y = ARENA_Y + AH + 6
local HEIGHT = CTRL_Y + 54 + 10

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 60
gui.Parent = playerGui

local main = Instance.new("CanvasGroup")
main.Name = "Main"
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.Position = UDim2.new(0.5, 0, 0.5, 0)
main.Size = UDim2.new(0, WIDTH, 0, HEIGHT)
main.BackgroundColor3 = C.bg
main.BorderSizePixel = 0
main.GroupTransparency = 1
main.Parent = gui
corner(main, 16)
local _, mainStrokeGrad = stroke(main, 2, 0)
do
	local glow = Instance.new("UIStroke")
	glow.Thickness = 7
	glow.Transparency = 0.82
	glow.Color = Color3.new(1, 1, 1)
	glow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	glow.Parent = main
	gradient(glow, 45)
end
local mainScale = Instance.new("UIScale", main)

local bgFill = frame(main, UDim2.new(), UDim2.new(1, 0, 1, 0), Color3.new(1, 1, 1))
bgFill.ZIndex = 0
gradient(bgFill, 60, Color3.fromRGB(20, 14, 44), Color3.fromRGB(8, 14, 34))

local function viewScale()
	local cam = workspace.CurrentCamera
	if not cam then return 1 end
	local v = cam.ViewportSize
	return math.clamp(math.min(v.X / (WIDTH + 20), v.Y / (HEIGHT + 20)), 0.5, 1)
end

-- header
local header = frame(main, UDim2.new(), UDim2.new(1, 0, 0, HEADER), C.panel)
header.BackgroundTransparency = 0.25
local titleL = label(header, "ALPHA BOAT BOUNCE V1", 13, C.text, Enum.Font.GothamBlack, Enum.TextXAlignment.Left)
titleL.Position = UDim2.new(0, 12, 0, 0)
titleL.Size = UDim2.new(1, -80, 1, 0)
gradient(titleL, 0)
local minBtn = button(header, "–", UDim2.new(1, -66, 0.5, -12), UDim2.new(0, 28, 0, 24), 16)
local closeBtn = button(header, "✕", UDim2.new(1, -34, 0.5, -12), UDim2.new(0, 28, 0, 24), 13)

-- stats
local statsRow = frame(main, UDim2.new(0, 10, 0, STATS_Y), UDim2.new(1, -20, 0, 38), C.bg)
statsRow.BackgroundTransparency = 1
local statValues = {}
do
	local names = { "SCORE", "BEST", "BOUNCES", "SPEED" }
	for i, n in ipairs(names) do
		local cell = frame(statsRow, UDim2.new((i - 1) / 4, (i == 1) and 0 or 2, 0, 0), UDim2.new(0.25, (i == 1 or i == 4) and -2 or -4, 1, 0), C.panel)
		corner(cell, 8)
		stroke(cell, 1, 0.65)
		local t = label(cell, n, 9, C.muted, Enum.Font.GothamBold)
		t.Position = UDim2.new(0, 0, 0, 3)
		t.Size = UDim2.new(1, 0, 0, 11)
		local v = label(cell, "0", 16, C.text, Enum.Font.GothamBlack)
		v.Position = UDim2.new(0, 0, 0, 14)
		v.Size = UDim2.new(1, 0, 0, 20)
		statValues[n] = v
	end
end

-- arena
local arena = frame(main, UDim2.new(0, 10, 0, ARENA_Y), UDim2.new(0, AW, 0, AH), Color3.new(1, 1, 1))
arena.ClipsDescendants = true
corner(arena, 12)
gradient(arena, 90, Color3.fromRGB(26, 14, 58), Color3.fromRGB(8, 20, 48))
stroke(arena, 1.5, 0.2)

-- background stars (static, cheap)
do
	local rng = Random.new(7)
	for _ = 1, 26 do
		local st = frame(arena, UDim2.new(0, rng:NextInteger(4, AW - 4), 0, rng:NextInteger(4, AH - 60)), UDim2.new(0, 2, 0, 2), Color3.new(1, 1, 1))
		st.BackgroundTransparency = 0.4 + rng:NextNumber() * 0.5
		corner(st, 99)
	end
end

-- water
local water = frame(arena, UDim2.new(0, 0, 0, AH - 26), UDim2.new(1, 0, 0, 26), Color3.new(1, 1, 1))
water.BackgroundTransparency = 0.45
gradient(water, 90, Color3.fromRGB(40, 170, 255), Color3.fromRGB(70, 40, 160))
local waves = {}
for i = 1, 2 do
	local w = frame(arena, UDim2.new(0, 0, 0, AH - 28 + i * 6), UDim2.new(1, 40, 0, 2), Color3.fromRGB(150, 220, 255))
	w.BackgroundTransparency = 0.6
	corner(w, 2)
	waves[i] = w
end

-- particles (fixed pool, reused: no allocations during play)
local PCOUNT = 28
local particles = {}
for i = 1, PCOUNT do
	local p = frame(arena, UDim2.new(), UDim2.new(0, 5, 0, 5), Color3.new(1, 1, 1))
	p.Visible = false
	p.ZIndex = 6
	corner(p, 99)
	particles[i] = { f = p, x = 0, y = 0, vx = 0, vy = 0, life = 0, max = 1 }
end
local function burst(x, y, count, speed, color1, color2)
	local made = 0
	for _, p in ipairs(particles) do
		if p.life <= 0 then
			local a = math.random() * math.pi * 2
			local sp = speed * (0.35 + math.random() * 0.65)
			p.x, p.y = x, y
			p.vx = math.cos(a) * sp
			p.vy = -math.abs(math.sin(a)) * sp - 40
			p.max = 0.45 + math.random() * 0.35
			p.life = p.max
			p.f.BackgroundColor3 = (math.random() < 0.5) and color1 or color2
			p.f.Visible = true
			made = made + 1
			if made >= count then break end
		end
	end
end

-- ball (glow + trail)
local trail = {}
for i = 1, 5 do
	local t = frame(arena, UDim2.new(), UDim2.new(0, 18 - i * 2, 0, 18 - i * 2), C.blue)
	t.AnchorPoint = Vector2.new(0.5, 0.5)
	t.BackgroundTransparency = 0.55 + i * 0.08
	t.ZIndex = 4
	corner(t, 99)
	trail[i] = { f = t, x = 0, y = 0 }
end
local halo = frame(arena, UDim2.new(), UDim2.new(0, 38, 0, 38), C.purple)
halo.AnchorPoint = Vector2.new(0.5, 0.5)
halo.BackgroundTransparency = 0.8
halo.ZIndex = 4
corner(halo, 99)
local ball = frame(arena, UDim2.new(), UDim2.new(0, Physics.BALL_R * 2, 0, Physics.BALL_R * 2), Color3.new(1, 1, 1))
ball.AnchorPoint = Vector2.new(0.5, 0.5)
ball.ZIndex = 7
corner(ball, 99)
gradient(ball, 45, Color3.fromRGB(255, 255, 255), Color3.fromRGB(120, 200, 255))
stroke(ball, 2, 0)
local ballScale = Instance.new("UIScale", ball)

-- boat
local boat = frame(arena, UDim2.new(), UDim2.new(0, Physics.BOAT_W, 0, Physics.BOAT_H), Color3.new(1, 1, 1))
boat.AnchorPoint = Vector2.new(0.5, 0)
boat.ZIndex = 8
corner(boat, 6)
gradient(boat, 0)
stroke(boat, 1.5, 0)
local deckLine = frame(boat, UDim2.new(0, 6, 0, 1), UDim2.new(1, -12, 0, 2), Color3.new(1, 1, 1))
deckLine.BackgroundTransparency = 0.2
corner(deckLine, 2)
local boatScale = Instance.new("UIScale", boat)
local boatGlow = frame(arena, UDim2.new(), UDim2.new(0, Physics.BOAT_W + 20, 0, 10), C.blue)
boatGlow.AnchorPoint = Vector2.new(0.5, 0)
boatGlow.BackgroundTransparency = 0.8
boatGlow.ZIndex = 5
corner(boatGlow, 99)

-- overlays (menu / pause / game over)
local function overlay()
	local o = Instance.new("CanvasGroup")
	o.Size = UDim2.new(1, 0, 1, 0)
	o.BackgroundColor3 = Color3.fromRGB(8, 6, 20)
	o.BackgroundTransparency = 0.12
	o.BorderSizePixel = 0
	o.ZIndex = 20
	o.Visible = false
	o.GroupTransparency = 1
	o.Active = true -- blocks clicks from reaching nothing behind it
	o.Parent = arena
	corner(o, 12)
	return o
end
local overlays = {}
local function showOverlay(o, show)
	if show then
		o.Visible = true
		o.GroupTransparency = 1
		tween(o, 0.25, { GroupTransparency = 0 })
	else
		if o.Visible then
			local t = tween(o, 0.15, { GroupTransparency = 1 })
			t.Completed:Connect(function()
				if o.GroupTransparency >= 0.99 then o.Visible = false end
			end)
		end
	end
end

local menuOv = overlay()
local pauseOv = overlay()
local overOv = overlay()

-- menu
local mT1 = label(menuOv, "ALPHA BOAT", 28, C.text, Enum.Font.GothamBlack)
mT1.Position = UDim2.new(0, 0, 0, 38)
mT1.Size = UDim2.new(1, 0, 0, 34)
gradient(mT1, 0)
local mT2 = label(menuOv, "BOUNCE  V1", 28, C.text, Enum.Font.GothamBlack)
mT2.Position = UDim2.new(0, 0, 0, 70)
mT2.Size = UDim2.new(1, 0, 0, 34)
gradient(mT2, 0, C.blue, C.purple)
local mSub = label(menuOv, "Catch the ball with your boat and keep it bouncing!", 11, C.muted)
mSub.Position = UDim2.new(0, 14, 0, 112)
mSub.Size = UDim2.new(1, -28, 0, 30)
mSub.TextWrapped = true
local menuBest = label(menuOv, "BEST: 0", 14, C.gold, Enum.Font.GothamBold)
menuBest.Position = UDim2.new(0, 0, 0, 148)
menuBest.Size = UDim2.new(1, 0, 0, 20)
local startBtn = button(menuOv, "▶  START", UDim2.new(0.5, -80, 0, 182), UDim2.new(0, 160, 0, 42), 16)
local mHelp = label(menuOv, "A / D  or  ← →   ·   touch buttons below", 10, C.muted)
mHelp.Position = UDim2.new(0, 10, 0, 240)
mHelp.Size = UDim2.new(1, -20, 0, 24)
mHelp.TextWrapped = true

-- pause
local pT = label(pauseOv, "PAUSED", 28, C.text, Enum.Font.GothamBlack)
pT.Position = UDim2.new(0, 0, 0, 56)
pT.Size = UDim2.new(1, 0, 0, 36)
gradient(pT, 0)
local resumeBtn = button(pauseOv, "▶  RESUME", UDim2.new(0.5, -80, 0, 112), UDim2.new(0, 160, 0, 40), 15)
local pRestartBtn = button(pauseOv, "↻  RESTART", UDim2.new(0.5, -80, 0, 160), UDim2.new(0, 160, 0, 40), 15)
local pMenuBtn = button(pauseOv, "☰  MENU", UDim2.new(0.5, -80, 0, 208), UDim2.new(0, 160, 0, 40), 15)

-- game over
local oT = label(overOv, "GAME OVER", 28, C.red, Enum.Font.GothamBlack)
oT.Position = UDim2.new(0, 0, 0, 34)
oT.Size = UDim2.new(1, 0, 0, 36)
local oScore = label(overOv, "0", 46, C.text, Enum.Font.GothamBlack)
oScore.Position = UDim2.new(0, 0, 0, 72)
oScore.Size = UDim2.new(1, 0, 0, 54)
gradient(oScore, 0)
local oInfo = label(overOv, "BEST 0  ·  BOUNCES 0", 12, C.muted, Enum.Font.GothamBold)
oInfo.Position = UDim2.new(0, 0, 0, 128)
oInfo.Size = UDim2.new(1, 0, 0, 18)
local oNew = label(overOv, "★ NEW BEST! ★", 14, C.gold, Enum.Font.GothamBlack)
oNew.Position = UDim2.new(0, 0, 0, 148)
oNew.Size = UDim2.new(1, 0, 0, 20)
oNew.Visible = false
local restartBtn = button(overOv, "↻  RESTART", UDim2.new(0.5, -80, 0, 184), UDim2.new(0, 160, 0, 42), 15)
local oMenuBtn = button(overOv, "☰  MENU", UDim2.new(0.5, -80, 0, 234), UDim2.new(0, 160, 0, 38), 14)

-- controls row
local ctrl = frame(main, UDim2.new(0, 10, 0, CTRL_Y), UDim2.new(1, -20, 0, 54), C.bg)
ctrl.BackgroundTransparency = 1
local leftBtn = button(ctrl, "◀", UDim2.new(0, 0, 0, 0), UDim2.new(0.4, -3, 1, 0), 26)
local pauseBtn = button(ctrl, "⏸", UDim2.new(0.4, 1, 0, 0), UDim2.new(0.2, -2, 1, 0), 20)
local rightBtn = button(ctrl, "▶", UDim2.new(0.6, 3, 0, 0), UDim2.new(0.4, -3, 1, 0), 26)

--==================================================
-- GAME STATE + FLOW
--==================================================
local state = Physics.new()
local status = "menu" -- menu | playing | paused | over
local best = tonumber(_G.AlphaBoatBounce_Best) or 0
local keyLeft, keyRight, btnLeft, btnRight = false, false, false, false
local shakeT = 0
local ballTrailTimer = 0
local lastShown = {}

local function setStat(name, value)
	value = tostring(value)
	if lastShown[name] ~= value then
		lastShown[name] = value
		statValues[name].Text = value
	end
end

local function refreshStats()
	setStat("SCORE", state.score)
	setStat("BEST", best)
	setStat("BOUNCES", state.bounces)
	setStat("SPEED", math.floor(state.speed / 10))
	menuBest.Text = "BEST: " .. best
end

local function clearInputs()
	keyLeft, keyRight, btnLeft, btnRight = false, false, false, false
end

local function actionHandler(name, inputState)
	local down = (inputState == Enum.UserInputState.Begin)
	if inputState == Enum.UserInputState.Begin or inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		if name == "ABB_Left" then keyLeft = down else keyRight = down end
	end
	return Enum.ContextActionResult.Sink -- keep A/D from also walking your character
end

local function bindKeys()
	ContextActionService:BindActionAtPriority("ABB_Left", actionHandler, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.A, Enum.KeyCode.Left)
	ContextActionService:BindActionAtPriority("ABB_Right", actionHandler, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.D, Enum.KeyCode.Right)
end
local function unbindKeys()
	pcall(function() ContextActionService:UnbindAction("ABB_Left") end)
	pcall(function() ContextActionService:UnbindAction("ABB_Right") end)
	clearInputs()
end

local function hideAllOverlays()
	showOverlay(menuOv, false)
	showOverlay(pauseOv, false)
	showOverlay(overOv, false)
end

local function resetVisuals()
	for _, p in ipairs(particles) do
		p.life = 0
		p.f.Visible = false
	end
	for _, t in ipairs(trail) do
		t.x, t.y = state.x, state.y
	end
	lastShown = {}
	refreshStats()
end

local function startGame()
	Physics.reset(state)
	status = "playing"
	hideAllOverlays()
	clearInputs()
	bindKeys()
	resetVisuals()
	pauseBtn.Text = "⏸"
end

local function pauseGame()
	if status ~= "playing" then return end
	status = "paused"
	unbindKeys()
	showOverlay(pauseOv, true)
	pauseBtn.Text = "▶"
end

local function resumeGame()
	if status ~= "paused" then return end
	status = "playing"
	clearInputs()
	bindKeys()
	showOverlay(pauseOv, false)
	pauseBtn.Text = "⏸"
end

local function toMenu()
	status = "menu"
	unbindKeys()
	Physics.reset(state)
	hideAllOverlays()
	showOverlay(menuOv, true)
	resetVisuals()
	pauseBtn.Text = "⏸"
end

local function gameOver()
	status = "over"
	unbindKeys()
	local isNew = state.score > best
	if isNew then
		best = state.score
		_G.AlphaBoatBounce_Best = best
	end
	oScore.Text = tostring(state.score)
	oInfo.Text = string.format("BEST %d  ·  BOUNCES %d", best, state.bounces)
	oNew.Visible = isNew
	shakeT = 0.35
	burst(state.x, math.min(state.y, AH - 20), 22, 260, C.red, C.gold)
	refreshStats()
	task.delay(0.35, function()
		if alive and status == "over" then
			showOverlay(overOv, true)
		end
	end)
end

bind(startBtn.MouseButton1Click, startGame)
bind(resumeBtn.MouseButton1Click, resumeGame)
bind(pRestartBtn.MouseButton1Click, startGame)
bind(restartBtn.MouseButton1Click, startGame)
bind(pMenuBtn.MouseButton1Click, toMenu)
bind(oMenuBtn.MouseButton1Click, toMenu)
bind(pauseBtn.MouseButton1Click, function()
	if status == "playing" then
		pauseGame()
	elseif status == "paused" then
		resumeGame()
	end
end)

-- hold buttons (touch + mouse)
local function holdButton(btn, setter)
	bind(btn.InputBegan, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			setter(true)
			local c
			c = i.Changed:Connect(function()
				if i.UserInputState == Enum.UserInputState.End or i.UserInputState == Enum.UserInputState.Cancel then
					setter(false)
					c:Disconnect()
				end
			end)
		end
	end)
	bind(btn.MouseLeave, function() setter(false) end)
end
holdButton(leftBtn, function(v) btnLeft = v end)
holdButton(rightBtn, function(v) btnRight = v end)

--==================================================
-- WINDOW: drag / minimize / close
--==================================================
local mainOpen = false
local minimized = false

do
	local dragging, moved = false, false
	local startInput, startPos
	bind(header.InputBegan, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, moved = true, false
			startInput, startPos = i.Position, main.Position
		end
	end)
	bind(UserInputService.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - startInput
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
	bind(UserInputService.InputEnded, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
		end
	end)
end

local function setMinimized(min)
	minimized = min
	minBtn.Text = min and "▢" or "–"
	if min then
		pauseGame() -- never keep playing while hidden
		statsRow.Visible, arena.Visible, ctrl.Visible = false, false, false
		tween(main, 0.25, { Size = UDim2.new(0, WIDTH, 0, HEADER) }, Enum.EasingStyle.Quint)
	else
		local t = tween(main, 0.3, { Size = UDim2.new(0, WIDTH, 0, HEIGHT) }, Enum.EasingStyle.Back)
		t.Completed:Connect(function()
			if not minimized then
				statsRow.Visible, arena.Visible, ctrl.Visible = true, true, true
			end
		end)
	end
end
bind(minBtn.MouseButton1Click, function() setMinimized(not minimized) end)

-- cleanup / close
local heartbeatConn
local function cleanup()
	if not alive then return end
	alive = false
	unbindKeys()
	for _, c in ipairs(connections) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(connections)
	if heartbeatConn then pcall(function() heartbeatConn:Disconnect() end) end
	pcall(function() gui:Destroy() end)
	if _G.AlphaBoatBounce_Cleanup == cleanup then
		_G.AlphaBoatBounce_Cleanup = nil
	end
end
_G.AlphaBoatBounce_Cleanup = cleanup
bind(closeBtn.MouseButton1Click, cleanup)

-- scale to the screen
local function applyScale()
	if mainOpen then mainScale.Scale = viewScale() end
end
do
	local cam = workspace.CurrentCamera
	if cam then bind(cam:GetPropertyChangedSignal("ViewportSize"), applyScale) end
end

--==================================================
-- MAIN LOOP (one Heartbeat connection)
--==================================================
local t0 = os.clock()
local wakeTimer = 0
heartbeatConn = RunService.Heartbeat:Connect(function(dt)
	if not alive then return end
	local now = os.clock() - t0

	if status == "playing" then
		local dir = ((keyRight or btnRight) and 1 or 0) - ((keyLeft or btnLeft) and 1 or 0)
		local ev = Physics.step(state, dt, dir)

		if ev.bounce then
			burst(ev.hitX, ev.hitY, 12, 220, C.blue, C.purple)
			tween(boatScale, 0.06, { Scale = 0.88 }).Completed:Connect(function()
				if alive then tween(boatScale, 0.18, { Scale = 1 }, Enum.EasingStyle.Back) end
			end)
			tween(ballScale, 0.06, { Scale = 1.35 }).Completed:Connect(function()
				if alive then tween(ballScale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back) end
			end)
			tween(statValues.SCORE, 0.08, { TextColor3 = C.gold }).Completed:Connect(function()
				if alive then tween(statValues.SCORE, 0.3, { TextColor3 = C.text }) end
			end)
		elseif ev.wall then
			burst(state.x, state.y, 3, 90, C.purple, C.blue)
		end
		if ev.over then
			gameOver()
		end

		-- small wake behind the moving boat
		wakeTimer = wakeTimer + dt
		if wakeTimer > 0.07 and math.abs(state.bvx) > 120 then
			wakeTimer = 0
			burst(state.bx - (state.bvx > 0 and 1 or -1) * Physics.BOAT_W / 2, Physics.BOAT_Y + Physics.BOAT_H, 1, 40, C.blue, C.blue)
		end
		refreshStats()
	end

	-- ----- render -----
	if main.Visible or mainOpen then
		mainStrokeGrad.Rotation = (now * 40) % 360
	end

	ball.Position = UDim2.fromOffset(state.x, state.y)
	halo.Position = ball.Position
	halo.BackgroundTransparency = 0.78 + math.sin(now * 6) * 0.06
	boat.Position = UDim2.fromOffset(state.bx, Physics.BOAT_Y)
	boatGlow.Position = UDim2.fromOffset(state.bx, Physics.BOAT_Y + Physics.BOAT_H - 2)

	-- trail follows the ball with a small lag
	ballTrailTimer = ballTrailTimer + dt
	if ballTrailTimer > 0.025 then
		ballTrailTimer = 0
		for i = #trail, 2, -1 do
			trail[i].x, trail[i].y = trail[i - 1].x, trail[i - 1].y
		end
		trail[1].x, trail[1].y = state.x, state.y
	end
	for _, t in ipairs(trail) do
		t.f.Position = UDim2.fromOffset(t.x, t.y)
	end

	-- waves
	for i, w in ipairs(waves) do
		w.Position = UDim2.new(0, -((now * (14 + i * 8)) % 40), 0, AH - 28 + i * 6 + math.sin(now * 2 + i) * 1.5)
	end

	-- particles
	for _, p in ipairs(particles) do
		if p.life > 0 then
			p.life = p.life - dt
			if p.life <= 0 then
				p.f.Visible = false
			else
				p.vy = p.vy + 520 * dt
				p.x = p.x + p.vx * dt
				p.y = p.y + p.vy * dt
				local k = p.life / p.max
				p.f.Position = UDim2.fromOffset(p.x - 2.5, p.y - 2.5)
				p.f.BackgroundTransparency = 1 - k
				p.f.Size = UDim2.fromOffset(2 + 4 * k, 2 + 4 * k)
			end
		end
	end

	-- screen shake on game over
	if shakeT > 0 then
		shakeT = shakeT - dt
		local m = math.max(shakeT, 0) * 18
		arena.Position = UDim2.new(0, 10 + math.sin(now * 90) * m, 0, ARENA_Y + math.cos(now * 77) * m)
	else
		arena.Position = UDim2.new(0, 10, 0, ARENA_Y)
	end
end)

--==================================================
-- START (open animation + main menu)
--==================================================
mainOpen = true
mainScale.Scale = viewScale() * 0.88
tween(main, 0.3, { GroupTransparency = 0 })
tween(mainScale, 0.4, { Scale = viewScale() }, Enum.EasingStyle.Back)
Physics.reset(state)
resetVisuals()
showOverlay(menuOv, true)
