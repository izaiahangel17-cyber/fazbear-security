--!nocheck
--[[
	HorrorMenuPlugin.server.lua
	===========================
	Roblox Studio plugin that installs a polished, neon-purple VHS-themed horror
	main-menu system into your place. Everything is built from this single file
	so you can drop it into your Plugins folder and click one toolbar button.

	Install:
		1. In Studio, paste this file into a `Script` in `Workspace`, right-click
		   it and pick "Save as Local Plugin..."  OR copy the file into:
		     Windows:  %LOCALAPPDATA%\Roblox\Plugins
		     macOS:    ~/Documents/Roblox/Plugins
		2. Restart Studio.
		3. Click the "Horror Menu" toolbar -> "Install / Rebuild".

	What it installs:
		StarterGui.HorrorMenuGui                     full ScreenGui hierarchy
		ReplicatedStorage.HorrorMenu                 RemoteEvents / RemoteFunctions
		ReplicatedStorage.HorrorMenu.MenuConfig      data-driven menu config
		ServerScriptService.HorrorMenuServer         party service + matchmaking
		StarterPlayer.StarterPlayerScripts.HorrorMenuClient
		                                             screen manager / settings /
		                                             party client / camera sway
		Workspace.HorrorMenuScene                    blurred backdrop for the menu
		Lighting.HorrorMenuLighting                  bloom + grain + colour fx

	"Install / Rebuild" wipes the existing HorrorMenu* instances and rebuilds
	them, so it's safe to click repeatedly while iterating. Anything you've put
	elsewhere in the place is left alone.

	The plugin uses only free Roblox-shipped asset IDs (rbxasset://...) so the
	menu works out of the box without any uploads. Replace the IDs in
	`AUDIO_IDS` / `IMAGE_IDS` near the top of the file with your own Sound /
	Decal asset IDs to skin the menu.
]]

if not plugin then
	return
end

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

------------------------------------------------------------------------------
-- Theme + asset IDs (edit these to reskin)
------------------------------------------------------------------------------

local PALETTE = {
	background = Color3.fromRGB(8, 6, 16),
	backgroundEdge = Color3.fromRGB(20, 8, 38),
	panel = Color3.fromRGB(14, 8, 26),
	panelEdge = Color3.fromRGB(28, 16, 56),
	primaryGlow = Color3.fromRGB(180, 90, 255),
	secondaryGlow = Color3.fromRGB(80, 200, 255),
	accentWarning = Color3.fromRGB(255, 80, 110),
	accentReady = Color3.fromRGB(120, 255, 170),
	textPrimary = Color3.fromRGB(232, 224, 255),
	textDim = Color3.fromRGB(150, 138, 180),
	textVeryDim = Color3.fromRGB(96, 88, 124),
	scanline = Color3.fromRGB(180, 90, 255),
}

local FONTS = {
	title = Enum.Font.Antique,
	heading = Enum.Font.Code,
	body = Enum.Font.Gotham,
	mono = Enum.Font.RobotoMono,
}

-- All rbxasset:// IDs ship with Roblox -- no uploads required.
local AUDIO_IDS = {
	hover = "rbxasset://sounds/button-09.mp3",
	click = "rbxasset://sounds/electronicpingshort.wav",
	back = "rbxasset://sounds/electronicpingshort.wav",
	toggle = "rbxasset://sounds/bass.wav",
	transition = "rbxasset://sounds/impact_water.mp3",
	error = "rbxasset://sounds/uuhhh.mp3",
	-- Music + VHS static are placeholders -- paste your own SoundId here.
	-- Format:  "rbxassetid://<NUMERIC ID>"
	music = "rbxassetid://9046862961",
	staticAmbience = "rbxassetid://9046862961",
}

local IMAGE_IDS = {
	-- Generic round-corner backgrounds shipped with Roblox.
	roundedFill = "rbxasset://textures/ui/GuiImagePlaceholder.png",
	-- Subtle scanline overlay -- use a UIGradient instead for the look.
	noise = "rbxasset://textures/particles/sparkles_main.dds",
}

local UI = {
	-- The reference design: large title, vertical button stack pinned to
	-- the left third of the screen.
	titleHeight = 110,
	subtitleHeight = 34,
	mainButtonSize = UDim2.fromOffset(360, 56),
	mainButtonSpacing = 14,
	-- Side-panel dimensions when in Play / Party / Settings / Credits.
	panelSize = UDim2.fromScale(0.62, 0.78),
	panelCornerRadius = UDim.new(0, 10),
	scanlineCount = 90,
	dustCount = 28,
	transitionTime = 0.45,
	hoverTime = 0.18,
}

------------------------------------------------------------------------------
-- Tiny helpers
------------------------------------------------------------------------------

local function setProps(instance, props)
	if props then
		for key, value in pairs(props) do
			(instance :: any)[key] = value
		end
	end
	return instance
end

local function newInstance(className, props, children)
	local inst = Instance.new(className)
	setProps(inst, props)
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	return inst
end

local function corner(radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = radius or UI.panelCornerRadius
	return c
end

local function stroke(color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color or PALETTE.primaryGlow
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0.25
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	return s
end

local function gradient(colorSequence, rotation, transparencyKeypoints)
	local g = Instance.new("UIGradient")
	g.Color = colorSequence
	g.Rotation = rotation or 0
	if transparencyKeypoints then
		g.Transparency = NumberSequence.new(transparencyKeypoints)
	end
	return g
end

local function pad(top, right, bottom, left)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, top or 0)
	p.PaddingRight = UDim.new(0, right or top or 0)
	p.PaddingBottom = UDim.new(0, bottom or top or 0)
	p.PaddingLeft = UDim.new(0, left or right or top or 0)
	return p
end

local function listLayout(direction, padding, alignment)
	local l = Instance.new("UIListLayout")
	l.FillDirection = direction or Enum.FillDirection.Vertical
	l.Padding = UDim.new(0, padding or 8)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.HorizontalAlignment = alignment or Enum.HorizontalAlignment.Left
	return l
end

local function tagButtonHover(button)
	-- Marker attribute -- the client script wires hover/click anims onto these.
	button:SetAttribute("HMHoverable", true)
end

------------------------------------------------------------------------------
-- Background + atmosphere
------------------------------------------------------------------------------

local function buildBackdrop(parent)
	local backdrop = newInstance("Frame", {
		Name = "Backdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = PALETTE.background,
		BorderSizePixel = 0,
		ZIndex = 1,
	})

	-- Vertical gradient from deep purple to near-black for a vignette look.
	gradient(
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, PALETTE.backgroundEdge),
			ColorSequenceKeypoint.new(0.45, PALETTE.background),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
		}),
		90
	).Parent =
		backdrop

	-- Faint radial vignette via an inner stroke + a darker frame on the edges.
	local vignette = newInstance("ImageLabel", {
		Name = "Vignette",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Image = "rbxasset://textures/ui/Controls/DropShadow.png",
		ImageColor3 = Color3.fromRGB(0, 0, 0),
		ImageTransparency = 0.35,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(12, 12, 244, 244),
		ZIndex = 4,
	})
	vignette.Parent = backdrop

	-- "Scene" placeholder -- the client script can swap this for a 3D viewport
	-- of HorrorMenuScene if it exists.  Until then, render a moody gradient.
	local sceneStandIn = newInstance("Frame", {
		Name = "SceneStandIn",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 2,
	})
	gradient(
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 14, 60)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(8, 6, 24)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
		}),
		135,
		{
			NumberSequenceKeypoint.new(0, 0.4),
			NumberSequenceKeypoint.new(0.5, 0.55),
			NumberSequenceKeypoint.new(1, 0.7),
		}
	).Parent =
		sceneStandIn
	sceneStandIn.Parent = backdrop

	backdrop.Parent = parent
	return backdrop
end

local function buildVHSOverlay(parent)
	local overlay = newInstance("Frame", {
		Name = "VHSOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 50,
	})

	-- A column of thin scanlines tinted with the primary glow.
	local scanlines = newInstance("Frame", {
		Name = "Scanlines",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	})
	local scanlineLayout =
		listLayout(Enum.FillDirection.Vertical, 3, Enum.HorizontalAlignment.Center)
	scanlineLayout.Parent = scanlines
	for i = 1, UI.scanlineCount do
		local row = newInstance("Frame", {
			Name = "Line",
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = PALETTE.scanline,
			BorderSizePixel = 0,
			BackgroundTransparency = 0.92,
			LayoutOrder = i,
		})
		row.Parent = scanlines
	end
	scanlines.Parent = overlay

	-- Chromatic aberration + grain: a magenta-cyan tinted noise image at low
	-- opacity, plus a faint magenta haze tween-flickered by the client.
	local grain = newInstance("ImageLabel", {
		Name = "Grain",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Image = IMAGE_IDS.noise,
		ImageColor3 = PALETTE.primaryGlow,
		ImageTransparency = 0.92,
		ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(280, 280),
	})
	grain.Parent = overlay

	local flicker = newInstance("Frame", {
		Name = "Flicker",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = PALETTE.primaryGlow,
		BackgroundTransparency = 0.98,
		BorderSizePixel = 0,
	})
	flicker.Parent = overlay

	-- Chromatic edge: a thin magenta + cyan band on left and right edges.
	for i, color in ipairs({ PALETTE.primaryGlow, PALETTE.secondaryGlow }) do
		local edge = newInstance("Frame", {
			Name = "ChromaEdge_" .. i,
			Size = UDim2.new(0, 6, 1, 0),
			Position = i == 1 and UDim2.new(0, 0, 0, 0) or UDim2.new(1, -6, 0, 0),
			BackgroundColor3 = color,
			BackgroundTransparency = 0.85,
			BorderSizePixel = 0,
		})
		edge.Parent = overlay
	end

	overlay.Parent = parent
	return overlay
end

local function buildDustParticles(parent)
	local container = newInstance("Frame", {
		Name = "Dust",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 5,
	})
	for i = 1, UI.dustCount do
		-- Position randomly; the client tweens these slowly upwards and resets.
		local dust = newInstance("Frame", {
			Name = "Dust_" .. i,
			Size = UDim2.fromOffset(3 + (i % 3), 3 + (i % 3)),
			Position = UDim2.fromScale(math.random(), math.random()),
			BackgroundColor3 = PALETTE.primaryGlow,
			BackgroundTransparency = 0.4 + math.random() * 0.5,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
		})
		corner(UDim.new(1, 0)).Parent = dust
		dust:SetAttribute("HMDust", true)
		dust.Parent = container
	end
	container.Parent = parent
	return container
end

------------------------------------------------------------------------------
-- Title + version + watermark
------------------------------------------------------------------------------

local function buildTitleArea(parent)
	local titleArea = newInstance("Frame", {
		Name = "TitleArea",
		Size = UDim2.new(0.55, 0, 0, UI.titleHeight + UI.subtitleHeight + 24),
		Position = UDim2.fromScale(0.055, 0.18),
		BackgroundTransparency = 1,
		ZIndex = 10,
	})

	local title = newInstance("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, UI.titleHeight),
		BackgroundTransparency = 1,
		Font = FONTS.title,
		Text = "HORROR  NIGHTS",
		TextColor3 = PALETTE.textPrimary,
		TextSize = 86,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		RichText = true,
		TextStrokeTransparency = 0.65,
		TextStrokeColor3 = PALETTE.primaryGlow,
		ZIndex = 11,
	})
	gradient(
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, PALETTE.primaryGlow),
			ColorSequenceKeypoint.new(0.5, PALETTE.textPrimary),
			ColorSequenceKeypoint.new(1, PALETTE.secondaryGlow),
		}),
		15
	).Parent =
		title
	-- Outer glow stroke
	local titleStroke = stroke(PALETTE.primaryGlow, 2, 0.55)
	titleStroke.Parent = title
	title:SetAttribute("HMLogoReveal", true)
	title.Parent = titleArea

	local subtitle = newInstance("TextLabel", {
		Name = "Subtitle",
		Size = UDim2.new(1, 0, 0, UI.subtitleHeight),
		Position = UDim2.new(0, 4, 0, UI.titleHeight + 4),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// VHS  PROTOCOL  —  PRESS  ANY  KEY",
		TextColor3 = PALETTE.textDim,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextTransparency = 0.15,
		ZIndex = 11,
	})
	subtitle.Parent = titleArea

	titleArea.Parent = parent
	return titleArea
end

local function buildVersionAndWatermark(parent)
	local version = newInstance("TextLabel", {
		Name = "Version",
		Size = UDim2.new(0, 220, 0, 22),
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -10),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "v0.1.0  —  build %BUILD%",
		TextColor3 = PALETTE.textVeryDim,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 60,
	})
	version.Parent = parent

	local watermark = newInstance("Frame", {
		Name = "BetaWatermark",
		Size = UDim2.fromOffset(74, 22),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 14),
		BackgroundColor3 = PALETTE.accentWarning,
		BorderSizePixel = 0,
		BackgroundTransparency = 0.35,
		ZIndex = 60,
	})
	corner(UDim.new(0, 4)).Parent = watermark
	stroke(PALETTE.accentWarning, 1, 0.2).Parent = watermark
	local wmLabel = newInstance("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "BETA",
		TextColor3 = PALETTE.textPrimary,
		TextSize = 14,
		ZIndex = 61,
	})
	wmLabel.Parent = watermark
	watermark.Parent = parent

	return version, watermark
end

------------------------------------------------------------------------------
-- Main menu button stack (Play / Party / Settings / Credits / Quit)
------------------------------------------------------------------------------

local function buildMenuButton(text, layoutOrder, accent)
	local button = newInstance("TextButton", {
		Name = text:gsub("%s+", "") .. "Button",
		Size = UI.mainButtonSize,
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = FONTS.mono,
		Text = "",
		TextColor3 = PALETTE.textPrimary,
		LayoutOrder = layoutOrder,
		ZIndex = 12,
	})
	corner(UDim.new(0, 8)).Parent = button
	local strokeInst = stroke(accent or PALETTE.primaryGlow, 1.5, 0.4)
	strokeInst.Name = "GlowStroke"
	strokeInst.Parent = button

	-- Inner panel gradient (left-bright -> right-dim)
	local grad = gradient(
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, accent or PALETTE.primaryGlow),
			ColorSequenceKeypoint.new(1, PALETTE.panel),
		}),
		0,
		{
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		}
	)
	grad.Name = "AccentGradient"
	grad.Parent = button

	-- Left rail indicator that fattens on hover
	local rail = newInstance("Frame", {
		Name = "Rail",
		Size = UDim2.new(0, 3, 1, -10),
		Position = UDim2.new(0, 6, 0, 5),
		BackgroundColor3 = accent or PALETTE.primaryGlow,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		ZIndex = 13,
	})
	corner(UDim.new(1, 0)).Parent = rail
	rail.Parent = button

	local label = newInstance("TextLabel", {
		Name = "Label",
		Size = UDim2.new(1, -38, 1, 0),
		Position = UDim2.new(0, 28, 0, 0),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = text:upper(),
		TextColor3 = PALETTE.textPrimary,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 14,
	})
	label.Parent = button

	-- Bracket prefix that animates wider on hover (>>).
	local bracket = newInstance("TextLabel", {
		Name = "Bracket",
		Size = UDim2.new(0, 20, 1, 0),
		Position = UDim2.new(0, 6, 0, 0),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = ">",
		TextColor3 = accent or PALETTE.primaryGlow,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTransparency = 0.35,
		ZIndex = 14,
	})
	bracket.Parent = button

	tagButtonHover(button)
	button:SetAttribute("HMAccentR", (accent or PALETTE.primaryGlow).R)
	button:SetAttribute("HMAccentG", (accent or PALETTE.primaryGlow).G)
	button:SetAttribute("HMAccentB", (accent or PALETTE.primaryGlow).B)
	return button
end

local function buildMainMenuPanel(parent)
	local panel = newInstance("Frame", {
		Name = "MainMenu",
		Size = UDim2.new(0, 380, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.fromScale(0.055, 0.42),
		BackgroundTransparency = 1,
		ZIndex = 12,
	})

	local stack = newInstance("Frame", {
		Name = "Stack",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	})
	listLayout(Enum.FillDirection.Vertical, UI.mainButtonSpacing, Enum.HorizontalAlignment.Left).Parent =
		stack

	local buttons = {
		{ text = "Play", accent = PALETTE.primaryGlow, target = "Play" },
		{ text = "Party", accent = PALETTE.secondaryGlow, target = "Party" },
		{ text = "Settings", accent = PALETTE.primaryGlow, target = "Settings" },
		{ text = "Credits", accent = PALETTE.secondaryGlow, target = "Credits" },
		{ text = "Quit", accent = PALETTE.accentWarning, target = "Quit" },
	}
	for i, info in ipairs(buttons) do
		local b = buildMenuButton(info.text, i, info.accent)
		b:SetAttribute("HMTarget", info.target)
		b.Parent = stack
	end
	stack.Parent = panel

	-- Decorative trailing tagline below the stack.
	local tagline = newInstance("TextLabel", {
		Name = "Tagline",
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(0, 4, 0, 0),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// loop  the  tape  again ?  [Y / N]",
		TextColor3 = PALETTE.textVeryDim,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 999,
		ZIndex = 12,
	})
	tagline.Parent = stack

	panel.Parent = parent
	return panel
end

------------------------------------------------------------------------------
-- Side panel shell (Play / Party / Settings / Credits all share this)
------------------------------------------------------------------------------

local function buildSidePanel(name, headerText, subText)
	local panel = newInstance("Frame", {
		Name = name .. "Panel",
		Size = UI.panelSize,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -48, 0.5, 0),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 20,
	})
	corner(UDim.new(0, 12)).Parent = panel
	stroke(PALETTE.primaryGlow, 1.5, 0.45).Parent = panel
	pad(20, 24, 20, 24).Parent = panel
	panel:SetAttribute("HMScreen", name)
	panel:SetAttribute("HMHidden", true)

	-- Soft inner glow on the top edge
	local edgeGlow = newInstance("Frame", {
		Name = "EdgeGlow",
		Size = UDim2.new(1, 0, 0, 2),
		Position = UDim2.new(0, 0, 0, 0),
		BackgroundColor3 = PALETTE.primaryGlow,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ZIndex = 21,
	})
	edgeGlow.Parent = panel

	-- Header row (title + close button)
	local header = newInstance("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 60),
		BackgroundTransparency = 1,
		ZIndex = 22,
	})

	local title = newInstance("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, -160, 1, 0),
		BackgroundTransparency = 1,
		Font = FONTS.title,
		Text = headerText:upper(),
		TextColor3 = PALETTE.textPrimary,
		TextSize = 38,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 23,
	})
	title.Parent = header

	local subtitle = newInstance("TextLabel", {
		Name = "Subtitle",
		Size = UDim2.new(1, -160, 0, 18),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 4, 1, -2),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// " .. subText:upper(),
		TextColor3 = PALETTE.textDim,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 23,
	})
	subtitle.Parent = header

	local back = newInstance("TextButton", {
		Name = "BackButton",
		Size = UDim2.fromOffset(140, 36),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Font = FONTS.mono,
		Text = "< BACK  [Esc]",
		TextColor3 = PALETTE.textPrimary,
		TextSize = 16,
		AutoButtonColor = false,
		ZIndex = 23,
	})
	corner(UDim.new(0, 6)).Parent = back
	stroke(PALETTE.secondaryGlow, 1.25, 0.5).Parent = back
	tagButtonHover(back)
	back:SetAttribute("HMBack", true)
	back.Parent = header

	header.Parent = panel

	-- Divider
	local divider = newInstance("Frame", {
		Name = "Divider",
		Size = UDim2.new(1, 0, 0, 1),
		Position = UDim2.new(0, 0, 0, 70),
		BackgroundColor3 = PALETTE.primaryGlow,
		BackgroundTransparency = 0.7,
		BorderSizePixel = 0,
		ZIndex = 22,
	})
	divider.Parent = panel

	-- Body area (scroll-friendly)
	local body = newInstance("Frame", {
		Name = "Body",
		Size = UDim2.new(1, 0, 1, -82),
		Position = UDim2.new(0, 0, 0, 80),
		BackgroundTransparency = 1,
		ZIndex = 22,
		ClipsDescendants = true,
	})
	body.Parent = panel

	return panel, body
end

------------------------------------------------------------------------------
-- Reusable form controls (toggle, slider, dropdown, list row)
------------------------------------------------------------------------------

local function buildToggle(name, label, layoutOrder, defaultOn)
	local row = newInstance("Frame", {
		Name = name .. "Row",
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
		ZIndex = 23,
	})
	local lbl = newInstance("TextLabel", {
		Name = "Label",
		Size = UDim2.new(0.6, 0, 1, 0),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = label,
		TextColor3 = PALETTE.textPrimary,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 24,
	})
	lbl.Parent = row
	local toggle = newInstance("TextButton", {
		Name = "Toggle",
		Size = UDim2.fromOffset(56, 24),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		BackgroundColor3 = defaultOn and PALETTE.primaryGlow or PALETTE.panel,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		ZIndex = 24,
	})
	corner(UDim.new(1, 0)).Parent = toggle
	stroke(PALETTE.primaryGlow, 1, 0.55).Parent = toggle
	local knob = newInstance("Frame", {
		Name = "Knob",
		Size = UDim2.fromOffset(20, 20),
		Position = defaultOn and UDim2.new(1, -22, 0.5, -10) or UDim2.new(0, 2, 0.5, -10),
		BackgroundColor3 = PALETTE.textPrimary,
		BorderSizePixel = 0,
		ZIndex = 25,
	})
	corner(UDim.new(1, 0)).Parent = knob
	knob.Parent = toggle
	tagButtonHover(toggle)
	toggle:SetAttribute("HMToggle", name)
	toggle:SetAttribute("HMToggleValue", defaultOn)
	toggle.Parent = row
	return row
end

local function buildSlider(name, label, layoutOrder, defaultValue, suffix)
	local row = newInstance("Frame", {
		Name = name .. "Row",
		Size = UDim2.new(1, 0, 0, 50),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
		ZIndex = 23,
	})
	local lbl = newInstance("TextLabel", {
		Name = "Label",
		Size = UDim2.new(0.55, 0, 0, 18),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = label,
		TextColor3 = PALETTE.textPrimary,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 24,
	})
	lbl.Parent = row
	local valueLabel = newInstance("TextLabel", {
		Name = "Value",
		Size = UDim2.new(0.45, 0, 0, 18),
		Position = UDim2.new(0.55, 0, 0, 0),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = tostring(defaultValue) .. (suffix or "%"),
		TextColor3 = PALETTE.secondaryGlow,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 24,
	})
	valueLabel.Parent = row
	-- Track
	local track = newInstance("Frame", {
		Name = "Track",
		Size = UDim2.new(1, 0, 0, 6),
		Position = UDim2.new(0, 0, 0, 30),
		BackgroundColor3 = PALETTE.panel,
		BorderSizePixel = 0,
		ZIndex = 24,
	})
	corner(UDim.new(1, 0)).Parent = track
	stroke(PALETTE.primaryGlow, 1, 0.6).Parent = track
	-- Fill
	local fill = newInstance("Frame", {
		Name = "Fill",
		Size = UDim2.new(defaultValue / 100, 0, 1, 0),
		BackgroundColor3 = PALETTE.primaryGlow,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		ZIndex = 25,
	})
	corner(UDim.new(1, 0)).Parent = fill
	gradient(
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, PALETTE.secondaryGlow),
			ColorSequenceKeypoint.new(1, PALETTE.primaryGlow),
		}),
		0
	).Parent =
		fill
	fill.Parent = track
	-- Knob
	local knob = newInstance("TextButton", {
		Name = "Knob",
		Size = UDim2.fromOffset(14, 14),
		Position = UDim2.new(defaultValue / 100, -7, 0.5, -7),
		BackgroundColor3 = PALETTE.textPrimary,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		ZIndex = 26,
	})
	corner(UDim.new(1, 0)).Parent = knob
	stroke(PALETTE.primaryGlow, 1, 0.2).Parent = knob
	knob.Parent = track
	track.Parent = row

	-- Slider attributes for client logic.
	row:SetAttribute("HMSlider", name)
	row:SetAttribute("HMSliderValue", defaultValue)
	row:SetAttribute("HMSliderSuffix", suffix or "%")
	return row
end

local function buildKeybindRow(name, label, layoutOrder, defaultKey)
	local row = newInstance("Frame", {
		Name = name .. "Row",
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundTransparency = 1,
		LayoutOrder = layoutOrder,
		ZIndex = 23,
	})
	local lbl = newInstance("TextLabel", {
		Size = UDim2.new(0.6, 0, 1, 0),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = label,
		TextColor3 = PALETTE.textPrimary,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 24,
	})
	lbl.Parent = row
	local btn = newInstance("TextButton", {
		Name = "Bind",
		Size = UDim2.fromOffset(120, 28),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = FONTS.mono,
		Text = string.upper(defaultKey),
		TextColor3 = PALETTE.secondaryGlow,
		TextSize = 14,
		ZIndex = 24,
	})
	corner(UDim.new(0, 4)).Parent = btn
	stroke(PALETTE.secondaryGlow, 1, 0.55).Parent = btn
	tagButtonHover(btn)
	btn:SetAttribute("HMKeybind", name)
	btn:SetAttribute("HMKeybindValue", defaultKey)
	btn.Parent = row
	return row
end

local function buildPrimaryButton(text, layoutOrder, accent, fullWidth)
	local btn = newInstance("TextButton", {
		Name = text:gsub("%s+", "") .. "Button",
		Size = fullWidth and UDim2.new(1, 0, 0, 44) or UDim2.fromOffset(220, 44),
		BackgroundColor3 = accent or PALETTE.primaryGlow,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = FONTS.mono,
		Text = text:upper(),
		TextColor3 = PALETTE.textPrimary,
		TextSize = 18,
		LayoutOrder = layoutOrder,
		ZIndex = 24,
	})
	corner(UDim.new(0, 6)).Parent = btn
	stroke(accent or PALETTE.primaryGlow, 1.5, 0.2).Parent = btn
	gradient(
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, accent or PALETTE.primaryGlow),
			ColorSequenceKeypoint.new(1, PALETTE.panel),
		}),
		15,
		{
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 0.7),
		}
	).Parent =
		btn
	tagButtonHover(btn)
	return btn
end

local function buildSecondaryButton(text, layoutOrder)
	local btn = newInstance("TextButton", {
		Name = text:gsub("%s+", "") .. "Button",
		Size = UDim2.fromOffset(180, 36),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = FONTS.mono,
		Text = text:upper(),
		TextColor3 = PALETTE.textPrimary,
		TextSize = 14,
		LayoutOrder = layoutOrder,
		ZIndex = 24,
	})
	corner(UDim.new(0, 4)).Parent = btn
	stroke(PALETTE.primaryGlow, 1, 0.45).Parent = btn
	tagButtonHover(btn)
	return btn
end

------------------------------------------------------------------------------
-- Play screen
------------------------------------------------------------------------------

local MISSIONS = {
	{
		id = "facility_alpha",
		title = "FACILITY  ALPHA",
		blurb = "Reset the breaker grid before the night shift ends.",
		minDifficulty = "Easy",
	},
	{
		id = "the_attraction",
		title = "THE  ATTRACTION",
		blurb = "Survive seven hours inside the abandoned park.",
		minDifficulty = "Normal",
	},
	{
		id = "static_signal",
		title = "STATIC  SIGNAL",
		blurb = "Decode the broken transmission. Don't blink.",
		minDifficulty = "Hard",
	},
	{
		id = "the_loop",
		title = "THE  LOOP",
		blurb = "Endless mode. Tapes never stop rewinding.",
		minDifficulty = "Nightmare",
	},
}

local DIFFICULTIES = { "Easy", "Normal", "Hard", "Nightmare" }

local function buildMissionRow(mission, layoutOrder)
	local row = newInstance("TextButton", {
		Name = "Mission_" .. mission.id,
		Size = UDim2.new(1, 0, 0, 70),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = layoutOrder,
		ZIndex = 24,
	})
	corner(UDim.new(0, 6)).Parent = row
	stroke(PALETTE.primaryGlow, 1, 0.55).Parent = row
	pad(10, 14, 10, 14).Parent = row

	local title = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = mission.title,
		TextColor3 = PALETTE.textPrimary,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 25,
	})
	title.Parent = row
	local blurb = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 0, 24),
		BackgroundTransparency = 1,
		Font = FONTS.body,
		Text = mission.blurb,
		TextColor3 = PALETTE.textDim,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 25,
	})
	blurb.Parent = row
	local meta = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 14),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "MIN  DIFFICULTY  :  " .. mission.minDifficulty:upper(),
		TextColor3 = PALETTE.textVeryDim,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 25,
	})
	meta.Parent = row

	tagButtonHover(row)
	row:SetAttribute("HMMission", mission.id)
	return row
end

local function buildPlayScreen(parent)
	local panel, body = buildSidePanel("Play", "Play", "select mission // tune the night")
	-- Left column: mission list
	local missionsList = newInstance("ScrollingFrame", {
		Name = "Missions",
		Size = UDim2.new(0.58, -10, 1, -64),
		Position = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = PALETTE.primaryGlow,
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		BorderSizePixel = 0,
		ZIndex = 23,
	})
	listLayout(Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Left).Parent = missionsList
	for i, m in ipairs(MISSIONS) do
		buildMissionRow(m, i).Parent = missionsList
	end
	missionsList.Parent = body

	-- Right column: difficulty + lobby type + matchmake
	local right = newInstance("Frame", {
		Name = "Right",
		Size = UDim2.new(0.42, -10, 1, 0),
		Position = UDim2.new(0.58, 10, 0, 0),
		BackgroundTransparency = 1,
		ZIndex = 23,
	})
	pad(0, 0, 0, 0).Parent = right
	listLayout(Enum.FillDirection.Vertical, 14, Enum.HorizontalAlignment.Left).Parent = right

	-- Difficulty header
	local diffLabel = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// DIFFICULTY",
		TextColor3 = PALETTE.secondaryGlow,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 1,
		ZIndex = 24,
	})
	diffLabel.Parent = right

	for i, diff in ipairs(DIFFICULTIES) do
		local row = newInstance("TextButton", {
			Name = "Diff_" .. diff,
			Size = UDim2.new(1, 0, 0, 32),
			BackgroundColor3 = PALETTE.panel,
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Font = FONTS.mono,
			Text = "   " .. diff:upper(),
			TextColor3 = PALETTE.textPrimary,
			TextSize = 15,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 1 + i,
			ZIndex = 24,
		})
		corner(UDim.new(0, 4)).Parent = row
		stroke(PALETTE.primaryGlow, 1, 0.6).Parent = row
		tagButtonHover(row)
		row:SetAttribute("HMDifficulty", diff)
		row.Parent = right
	end

	-- Lobby type header
	local lobbyLabel = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// LOBBY",
		TextColor3 = PALETTE.secondaryGlow,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = 10,
		ZIndex = 24,
	})
	lobbyLabel.Parent = right

	local lobbyRow = newInstance("Frame", {
		Name = "LobbyRow",
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundTransparency = 1,
		LayoutOrder = 11,
		ZIndex = 24,
	})
	local hLayout = listLayout(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left)
	hLayout.Parent = lobbyRow
	for i, kind in ipairs({ "Public", "Private" }) do
		local btn = newInstance("TextButton", {
			Name = "Lobby_" .. kind,
			Size = UDim2.new(0.5, -4, 1, 0),
			BackgroundColor3 = PALETTE.panel,
			BackgroundTransparency = 0.2,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Font = FONTS.mono,
			Text = kind:upper(),
			TextColor3 = PALETTE.textPrimary,
			TextSize = 15,
			LayoutOrder = i,
			ZIndex = 25,
		})
		corner(UDim.new(0, 4)).Parent = btn
		stroke(PALETTE.primaryGlow, 1, 0.55).Parent = btn
		tagButtonHover(btn)
		btn:SetAttribute("HMLobby", kind)
		btn.Parent = lobbyRow
	end
	lobbyRow.Parent = right

	local startBtn = buildPrimaryButton("MATCHMAKE  >", 20, PALETTE.primaryGlow, true)
	startBtn:SetAttribute("HMAction", "Matchmake")
	startBtn.Parent = right

	right.Parent = body

	-- Footer status hint
	local footer = newInstance("TextLabel", {
		Name = "Hint",
		Size = UDim2.new(1, 0, 0, 18),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// matchmaking  pings  every  2.0s   //   esc  to  return",
		TextColor3 = PALETTE.textVeryDim,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 23,
	})
	footer.Parent = body

	panel.Parent = parent
	return panel
end

------------------------------------------------------------------------------
-- Party screen
------------------------------------------------------------------------------

local function buildPartyMemberRow(layoutOrder)
	-- Template row -- the client clones this for each party member.
	local row = newInstance("Frame", {
		Name = "MemberTemplate",
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		LayoutOrder = layoutOrder,
		Visible = false,
		ZIndex = 24,
	})
	corner(UDim.new(0, 6)).Parent = row
	stroke(PALETTE.primaryGlow, 1, 0.55).Parent = row
	pad(6, 10, 6, 10).Parent = row
	row:SetAttribute("HMPartyMemberTemplate", true)

	local avatar = newInstance("ImageLabel", {
		Name = "Avatar",
		Size = UDim2.fromOffset(32, 32),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		BackgroundColor3 = PALETTE.panelEdge,
		BorderSizePixel = 0,
		Image = "rbxasset://textures/ui/GuiImagePlaceholder.png",
		ZIndex = 25,
	})
	corner(UDim.new(1, 0)).Parent = avatar
	stroke(PALETTE.primaryGlow, 1, 0.4).Parent = avatar
	avatar.Parent = row

	local leaderBadge = newInstance("TextLabel", {
		Name = "LeaderBadge",
		Size = UDim2.fromOffset(18, 18),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(0, 32, 0, 0),
		BackgroundColor3 = PALETTE.secondaryGlow,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Font = FONTS.mono,
		Text = "L",
		TextColor3 = PALETTE.background,
		TextSize = 12,
		Visible = false,
		ZIndex = 26,
	})
	corner(UDim.new(1, 0)).Parent = leaderBadge
	leaderBadge.Parent = row

	local nameLabel = newInstance("TextLabel", {
		Name = "Name",
		Size = UDim2.new(1, -150, 0, 18),
		Position = UDim2.new(0, 44, 0, 2),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "PlayerName",
		TextColor3 = PALETTE.textPrimary,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 25,
	})
	nameLabel.Parent = row

	local statusLabel = newInstance("TextLabel", {
		Name = "Status",
		Size = UDim2.new(1, -150, 0, 14),
		Position = UDim2.new(0, 44, 0, 20),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// NOT READY",
		TextColor3 = PALETTE.textDim,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 25,
	})
	statusLabel.Parent = row

	local readyIndicator = newInstance("Frame", {
		Name = "Ready",
		Size = UDim2.fromOffset(10, 10),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		BackgroundColor3 = PALETTE.accentWarning,
		BorderSizePixel = 0,
		ZIndex = 25,
	})
	corner(UDim.new(1, 0)).Parent = readyIndicator
	readyIndicator.Parent = row

	return row
end

local function buildPartyScreen(parent)
	local panel, body =
		buildSidePanel("Party", "Party", "create or join // sync up // teleport together")

	-- Left column: party state + actions
	local left = newInstance("Frame", {
		Name = "Left",
		Size = UDim2.new(0.45, -10, 1, -32),
		BackgroundTransparency = 1,
		ZIndex = 23,
	})
	listLayout(Enum.FillDirection.Vertical, 12, Enum.HorizontalAlignment.Left).Parent = left

	-- Party code display
	local codeFrame = newInstance("Frame", {
		Name = "PartyCodeFrame",
		Size = UDim2.new(1, 0, 0, 64),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		ZIndex = 24,
	})
	corner(UDim.new(0, 6)).Parent = codeFrame
	stroke(PALETTE.secondaryGlow, 1, 0.4).Parent = codeFrame
	pad(8, 12, 8, 12).Parent = codeFrame
	local codeTitle = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 14),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// PARTY  CODE",
		TextColor3 = PALETTE.secondaryGlow,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 25,
	})
	codeTitle.Parent = codeFrame
	local codeValue = newInstance("TextLabel", {
		Name = "Code",
		Size = UDim2.new(1, 0, 0, 32),
		Position = UDim2.new(0, 0, 0, 16),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "—  —  —  —",
		TextColor3 = PALETTE.textPrimary,
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 25,
	})
	codeValue.Parent = codeFrame
	codeFrame.Parent = left

	-- Action buttons
	local createBtn = buildPrimaryButton("CREATE  PARTY", 2, PALETTE.primaryGlow, true)
	createBtn:SetAttribute("HMAction", "CreateParty")
	createBtn.Parent = left

	local joinRow = newInstance("Frame", {
		Name = "JoinRow",
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		ZIndex = 24,
	})
	local joinInput = newInstance("TextBox", {
		Name = "JoinInput",
		Size = UDim2.new(1, -150, 1, 0),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Font = FONTS.mono,
		Text = "",
		PlaceholderText = "ENTER  PARTY  CODE",
		PlaceholderColor3 = PALETTE.textVeryDim,
		TextColor3 = PALETTE.textPrimary,
		TextSize = 16,
		ClearTextOnFocus = false,
		ZIndex = 25,
	})
	corner(UDim.new(0, 6)).Parent = joinInput
	stroke(PALETTE.primaryGlow, 1, 0.5).Parent = joinInput
	joinInput.Parent = joinRow
	local joinBtn = newInstance("TextButton", {
		Name = "JoinBtn",
		Size = UDim2.fromOffset(140, 44),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		BackgroundColor3 = PALETTE.secondaryGlow,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = FONTS.mono,
		Text = "JOIN  >",
		TextColor3 = PALETTE.textPrimary,
		TextSize = 16,
		ZIndex = 25,
	})
	corner(UDim.new(0, 6)).Parent = joinBtn
	stroke(PALETTE.secondaryGlow, 1, 0.2).Parent = joinBtn
	tagButtonHover(joinBtn)
	joinBtn:SetAttribute("HMAction", "JoinParty")
	joinBtn.Parent = joinRow
	joinRow.Parent = left

	-- Ready toggle + leave + invite
	local readyBtn = buildPrimaryButton("READY  UP", 4, PALETTE.accentReady, true)
	readyBtn:SetAttribute("HMAction", "ToggleReady")
	readyBtn.Parent = left

	local actionsRow = newInstance("Frame", {
		Name = "ActionsRow",
		Size = UDim2.new(1, 0, 0, 36),
		BackgroundTransparency = 1,
		LayoutOrder = 5,
		ZIndex = 24,
	})
	listLayout(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left).Parent = actionsRow
	local inviteBtn = buildSecondaryButton("INVITE  FRIEND", 1)
	inviteBtn.Size = UDim2.new(0.5, -4, 1, 0)
	inviteBtn:SetAttribute("HMAction", "InviteFriend")
	inviteBtn.Parent = actionsRow
	local leaveBtn = buildSecondaryButton("LEAVE  PARTY", 2)
	leaveBtn.Size = UDim2.new(0.5, -4, 1, 0)
	leaveBtn:SetAttribute("HMAction", "LeaveParty")
	leaveBtn.Parent = actionsRow
	actionsRow.Parent = left

	-- Start (leader only)
	local startBtn = buildPrimaryButton("START  GAME", 6, PALETTE.primaryGlow, true)
	startBtn:SetAttribute("HMAction", "StartGame")
	startBtn:SetAttribute("HMLeaderOnly", true)
	startBtn.Parent = left

	left.Parent = body

	-- Right column: members + chat
	local right = newInstance("Frame", {
		Name = "Right",
		Size = UDim2.new(0.55, -10, 1, -32),
		Position = UDim2.new(0.45, 10, 0, 0),
		BackgroundTransparency = 1,
		ZIndex = 23,
	})

	-- Members panel (top half)
	local membersBox = newInstance("Frame", {
		Name = "Members",
		Size = UDim2.new(1, 0, 0.55, -6),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		ZIndex = 24,
	})
	corner(UDim.new(0, 6)).Parent = membersBox
	stroke(PALETTE.primaryGlow, 1, 0.5).Parent = membersBox
	pad(10, 10, 10, 10).Parent = membersBox

	local membersTitle = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// PARTY  MEMBERS  (0/4)",
		TextColor3 = PALETTE.secondaryGlow,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 25,
	})
	membersTitle.Name = "MembersTitle"
	membersTitle.Parent = membersBox

	local membersList = newInstance("ScrollingFrame", {
		Name = "MembersList",
		Size = UDim2.new(1, 0, 1, -22),
		Position = UDim2.new(0, 0, 0, 22),
		BackgroundTransparency = 1,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = PALETTE.primaryGlow,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = 25,
	})
	listLayout(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left).Parent = membersList
	buildPartyMemberRow(1).Parent = membersList
	membersList.Parent = membersBox
	membersBox.Parent = right

	-- Chat panel (bottom half)
	local chatBox = newInstance("Frame", {
		Name = "Chat",
		Size = UDim2.new(1, 0, 0.45, -6),
		Position = UDim2.new(0, 0, 0.55, 6),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		ZIndex = 24,
	})
	corner(UDim.new(0, 6)).Parent = chatBox
	stroke(PALETTE.secondaryGlow, 1, 0.5).Parent = chatBox
	pad(10, 10, 10, 10).Parent = chatBox

	local chatTitle = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// LOBBY  CHAT",
		TextColor3 = PALETTE.secondaryGlow,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 25,
	})
	chatTitle.Parent = chatBox

	local chatLog = newInstance("ScrollingFrame", {
		Name = "Log",
		Size = UDim2.new(1, 0, 1, -56),
		Position = UDim2.new(0, 0, 0, 22),
		BackgroundTransparency = 1,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = PALETTE.secondaryGlow,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = 25,
	})
	listLayout(Enum.FillDirection.Vertical, 2, Enum.HorizontalAlignment.Left).Parent = chatLog
	chatLog.Parent = chatBox

	local chatInputRow = newInstance("Frame", {
		Name = "InputRow",
		Size = UDim2.new(1, 0, 0, 28),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		BackgroundTransparency = 1,
		ZIndex = 25,
	})
	local chatInput = newInstance("TextBox", {
		Name = "Input",
		Size = UDim2.new(1, -60, 1, 0),
		BackgroundColor3 = PALETTE.background,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Font = FONTS.mono,
		Text = "",
		PlaceholderText = "TYPE  TO  CHAT...",
		PlaceholderColor3 = PALETTE.textVeryDim,
		TextColor3 = PALETTE.textPrimary,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		ClearTextOnFocus = false,
		ZIndex = 26,
	})
	corner(UDim.new(0, 4)).Parent = chatInput
	stroke(PALETTE.secondaryGlow, 1, 0.6).Parent = chatInput
	pad(0, 8, 0, 8).Parent = chatInput
	chatInput.Parent = chatInputRow
	local sendBtn = newInstance("TextButton", {
		Name = "SendBtn",
		Size = UDim2.fromOffset(54, 28),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		BackgroundColor3 = PALETTE.secondaryGlow,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = FONTS.mono,
		Text = "SEND",
		TextColor3 = PALETTE.textPrimary,
		TextSize = 12,
		ZIndex = 26,
	})
	corner(UDim.new(0, 4)).Parent = sendBtn
	stroke(PALETTE.secondaryGlow, 1, 0.25).Parent = sendBtn
	tagButtonHover(sendBtn)
	sendBtn:SetAttribute("HMAction", "SendChat")
	sendBtn.Parent = chatInputRow
	chatInputRow.Parent = chatBox

	chatBox.Parent = right
	right.Parent = body

	panel.Parent = parent
	return panel
end

------------------------------------------------------------------------------
-- Settings screen
------------------------------------------------------------------------------

local function buildSettingsScreen(parent)
	local panel, body = buildSidePanel("Settings", "Settings", "tune the feed // bind the keys")

	-- Scrollable settings list
	local list = newInstance("ScrollingFrame", {
		Name = "Settings",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = PALETTE.primaryGlow,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ZIndex = 23,
	})
	listLayout(Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Left).Parent = list
	pad(0, 18, 8, 0).Parent = list

	local function sectionHeader(text, order)
		local h = newInstance("TextLabel", {
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundTransparency = 1,
			Font = FONTS.mono,
			Text = "//  " .. text:upper(),
			TextColor3 = PALETTE.secondaryGlow,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = order,
			ZIndex = 24,
		})
		return h
	end

	sectionHeader("Audio", 1).Parent = list
	buildSlider("MasterVolume", "MASTER  VOLUME", 2, 80).Parent = list
	buildSlider("MusicVolume", "MUSIC  VOLUME", 3, 60).Parent = list
	buildSlider("SfxVolume", "SFX  VOLUME", 4, 85).Parent = list
	buildSlider("AmbienceVolume", "AMBIENCE  VOLUME", 5, 70).Parent = list

	sectionHeader("Graphics", 10).Parent = list
	buildSlider("Quality", "GRAPHICS  QUALITY", 11, 75).Parent = list
	buildToggle("MotionBlur", "MOTION  BLUR", 12, true).Parent = list
	buildToggle("FilmGrain", "FILM  GRAIN", 13, true).Parent = list
	buildToggle("Fullscreen", "FULLSCREEN", 14, false).Parent = list

	sectionHeader("Camera", 20).Parent = list
	buildSlider("Sensitivity", "MOUSE  SENSITIVITY", 21, 50, "%").Parent = list
	buildSlider("FieldOfView", "FIELD  OF  VIEW", 22, 70, "°").Parent = list

	sectionHeader("Keybinds", 30).Parent = list
	buildKeybindRow("Forward", "MOVE  FORWARD", 31, "W").Parent = list
	buildKeybindRow("Back", "MOVE  BACK", 32, "S").Parent = list
	buildKeybindRow("Left", "STRAFE  LEFT", 33, "A").Parent = list
	buildKeybindRow("Right", "STRAFE  RIGHT", 34, "D").Parent = list
	buildKeybindRow("Sprint", "SPRINT", 35, "LeftShift").Parent = list
	buildKeybindRow("Interact", "INTERACT", 36, "E").Parent = list
	buildKeybindRow("Crouch", "CROUCH", 37, "LeftControl").Parent = list
	buildKeybindRow("Flashlight", "FLASHLIGHT", 38, "F").Parent = list
	buildKeybindRow("Menu", "PAUSE  MENU", 39, "Escape").Parent = list

	sectionHeader("Save", 90).Parent = list
	local saveRow = newInstance("Frame", {
		Name = "SaveRow",
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundTransparency = 1,
		LayoutOrder = 91,
		ZIndex = 24,
	})
	listLayout(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left).Parent = saveRow
	local saveBtn = buildPrimaryButton("SAVE", 1, PALETTE.accentReady, false)
	saveBtn:SetAttribute("HMAction", "SaveSettings")
	saveBtn.Parent = saveRow
	local resetBtn = buildSecondaryButton("RESET  TO  DEFAULTS", 2)
	resetBtn:SetAttribute("HMAction", "ResetSettings")
	resetBtn.Parent = saveRow
	saveRow.Parent = list

	list.Parent = body

	panel.Parent = parent
	return panel
end

------------------------------------------------------------------------------
-- Credits screen
------------------------------------------------------------------------------

local CREDITS = {
	{ heading = "DEVELOPED  BY" },
	{ name = "<your studio>" },
	{ heading = "DESIGN  +  PROGRAMMING" },
	{ name = "Lead Developer" },
	{ name = "UI / UX" },
	{ name = "Networking" },
	{ heading = "ENVIRONMENT  ART" },
	{ name = "Environment Lead" },
	{ name = "Lighting Artist" },
	{ heading = "AUDIO" },
	{ name = "Sound Design" },
	{ name = "Music Composition" },
	{ heading = "TESTING" },
	{ name = "QA Lead" },
	{ name = "Community Testers" },
	{ heading = "SPECIAL  THANKS" },
	{ name = "The Roblox developer community" },
	{ name = "The horror genre, for being terrifying" },
	{ name = "Coffee, at 2am" },
	{ heading = "" },
	{ name = "Built  with  Roblox  Studio" },
	{ name = "" },
	{ name = "Press  Esc  to  go  back" },
}

local function buildCreditsScreen(parent)
	local panel, body = buildSidePanel("Credits", "Credits", "the people behind the static")

	local scroller = newInstance("ScrollingFrame", {
		Name = "CreditsScroll",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ScrollBarThickness = 0,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ZIndex = 23,
	})
	scroller:SetAttribute("HMCreditsScroll", true)
	listLayout(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Center).Parent = scroller
	pad(20, 0, 40, 0).Parent = scroller

	for i, entry in ipairs(CREDITS) do
		if entry.heading then
			local h = newInstance("TextLabel", {
				Size = UDim2.new(1, 0, 0, 32),
				BackgroundTransparency = 1,
				Font = FONTS.mono,
				Text = entry.heading,
				TextColor3 = PALETTE.secondaryGlow,
				TextSize = 14,
				LayoutOrder = i,
				ZIndex = 24,
			})
			h.Parent = scroller
		else
			local n = newInstance("TextLabel", {
				Size = UDim2.new(1, 0, 0, 24),
				BackgroundTransparency = 1,
				Font = FONTS.body,
				Text = entry.name,
				TextColor3 = PALETTE.textPrimary,
				TextSize = 18,
				LayoutOrder = i,
				ZIndex = 24,
			})
			n.Parent = scroller
		end
	end
	scroller.Parent = body

	panel.Parent = parent
	return panel
end

------------------------------------------------------------------------------
-- Loading screen, notifications, transitions
------------------------------------------------------------------------------

local function buildLoadingScreen(parent)
	local screen = newInstance("Frame", {
		Name = "LoadingScreen",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = PALETTE.background,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 200,
	})
	gradient(
		ColorSequence.new({
			ColorSequenceKeypoint.new(0, PALETTE.backgroundEdge),
			ColorSequenceKeypoint.new(0.5, PALETTE.background),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
		}),
		90
	).Parent =
		screen

	local spinner = newInstance("ImageLabel", {
		Name = "Spinner",
		Size = UDim2.fromOffset(72, 72),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		BackgroundTransparency = 1,
		Image = "rbxasset://textures/loading/loadingCircle.png",
		ImageColor3 = PALETTE.primaryGlow,
		ZIndex = 201,
	})
	spinner:SetAttribute("HMSpinner", true)
	spinner.Parent = screen

	local status = newInstance("TextLabel", {
		Name = "Status",
		Size = UDim2.new(1, 0, 0, 28),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 16),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "LOADING  /  PLEASE  STAND  BY",
		TextColor3 = PALETTE.textPrimary,
		TextSize = 20,
		ZIndex = 201,
	})
	status.Parent = screen

	local hint = newInstance("TextLabel", {
		Name = "Hint",
		Size = UDim2.new(1, 0, 0, 18),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 46),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "// rewinding  the  tape...",
		TextColor3 = PALETTE.textDim,
		TextSize = 13,
		ZIndex = 201,
	})
	hint.Parent = screen

	screen.Parent = parent
	return screen
end

local function buildTransitionFade(parent)
	local fader = newInstance("Frame", {
		Name = "TransitionFader",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 300,
	})
	fader:SetAttribute("HMFader", true)
	fader.Parent = parent
	return fader
end

local function buildNotifications(parent)
	local container = newInstance("Frame", {
		Name = "Notifications",
		Size = UDim2.fromOffset(320, 600),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -20, 0, 48),
		BackgroundTransparency = 1,
		ZIndex = 250,
	})
	local layout = listLayout(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Right)
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.Parent = container
	container:SetAttribute("HMNotifications", true)

	-- Toast template (cloned by the client).
	local template = newInstance("Frame", {
		Name = "ToastTemplate",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 251,
	})
	corner(UDim.new(0, 6)).Parent = template
	stroke(PALETTE.primaryGlow, 1, 0.3).Parent = template
	pad(10, 12, 10, 12).Parent = template
	local title = newInstance("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 18),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "NOTIFICATION",
		TextColor3 = PALETTE.secondaryGlow,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 252,
	})
	title.Parent = template
	local body = newInstance("TextLabel", {
		Name = "Body",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.new(0, 0, 0, 20),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "Something happened.",
		TextColor3 = PALETTE.textPrimary,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		ZIndex = 252,
	})
	body.Parent = template
	template:SetAttribute("HMToastTemplate", true)
	template.Parent = container

	container.Parent = parent
	return container
end

local function buildInvitePopup(parent)
	local backdrop = newInstance("Frame", {
		Name = "InvitePopup",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 280,
	})

	local card = newInstance("Frame", {
		Name = "Card",
		Size = UDim2.fromOffset(440, 200),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = PALETTE.panel,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		ZIndex = 281,
	})
	corner(UDim.new(0, 10)).Parent = card
	stroke(PALETTE.primaryGlow, 1.5, 0.2).Parent = card
	pad(20, 22, 20, 22).Parent = card

	local title = newInstance("TextLabel", {
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundTransparency = 1,
		Font = FONTS.title,
		Text = "PARTY  INVITE",
		TextColor3 = PALETTE.textPrimary,
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 282,
	})
	title.Parent = card

	local fromLine = newInstance("TextLabel", {
		Name = "From",
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.new(0, 0, 0, 30),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "From  <player>",
		TextColor3 = PALETTE.textDim,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 282,
	})
	fromLine.Parent = card

	local codeLine = newInstance("TextLabel", {
		Name = "Code",
		Size = UDim2.new(1, 0, 0, 36),
		Position = UDim2.new(0, 0, 0, 54),
		BackgroundTransparency = 1,
		Font = FONTS.mono,
		Text = "—  —  —  —",
		TextColor3 = PALETTE.secondaryGlow,
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 282,
	})
	codeLine.Parent = card

	local actionsRow = newInstance("Frame", {
		Size = UDim2.new(1, 0, 0, 44),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		BackgroundTransparency = 1,
		ZIndex = 282,
	})
	listLayout(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Right).Parent =
		actionsRow
	local declineBtn = buildSecondaryButton("DECLINE", 1)
	declineBtn:SetAttribute("HMAction", "DeclineInvite")
	declineBtn.Parent = actionsRow
	local acceptBtn = buildPrimaryButton("ACCEPT", 2, PALETTE.accentReady, false)
	acceptBtn:SetAttribute("HMAction", "AcceptInvite")
	acceptBtn.Parent = actionsRow
	actionsRow.Parent = card

	card.Parent = backdrop
	backdrop:SetAttribute("HMInvitePopup", true)
	backdrop.Parent = parent
	return backdrop
end

------------------------------------------------------------------------------
-- Sounds folder
------------------------------------------------------------------------------

local function buildSounds(parent)
	local folder = newInstance("Folder", { Name = "Sounds" })
	for name, id in pairs(AUDIO_IDS) do
		local sound = newInstance("Sound", {
			Name = name,
			SoundId = id,
			Volume = 0.5,
			Looped = name == "music" or name == "staticAmbience",
			PlayOnRemove = false,
		})
		sound.Parent = folder
	end
	folder.Parent = parent
	return folder
end

------------------------------------------------------------------------------
-- Top-level GUI tree
------------------------------------------------------------------------------

local function buildGui()
	local screenGui = newInstance("ScreenGui", {
		Name = "HorrorMenuGui",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 50,
	})
	-- Marker so the client can find the root GUI quickly.
	screenGui:SetAttribute("HMRoot", true)

	-- A "Scale" frame at 1280x720 reference, used for AutoScale rules.
	local autoScale = newInstance("UIScale", { Scale = 1 })
	autoScale.Name = "AutoScale"
	autoScale.Parent = screenGui

	buildBackdrop(screenGui)
	buildDustParticles(screenGui)
	buildTitleArea(screenGui)
	buildVHSOverlay(screenGui)
	buildMainMenuPanel(screenGui)

	buildPlayScreen(screenGui)
	buildPartyScreen(screenGui)
	buildSettingsScreen(screenGui)
	buildCreditsScreen(screenGui)

	buildVersionAndWatermark(screenGui)
	buildNotifications(screenGui)
	buildInvitePopup(screenGui)
	buildLoadingScreen(screenGui)
	buildTransitionFade(screenGui)

	buildSounds(screenGui)

	return screenGui
end

------------------------------------------------------------------------------
-- Workspace scene (dimly lit backdrop the camera looks at while menu is up)
------------------------------------------------------------------------------

local function buildScene()
	local existing = Workspace:FindFirstChild("HorrorMenuScene")
	if existing then
		existing:Destroy()
	end
	local scene = Instance.new("Model")
	scene.Name = "HorrorMenuScene"
	scene.Parent = Workspace

	-- Position the scene safely off the playable area.
	local origin = CFrame.new(0, 1000, 0)
	scene:SetAttribute("HMSceneOrigin", true)

	local floor = Instance.new("Part")
	floor.Name = "Floor"
	floor.Anchored = true
	floor.CanCollide = false
	floor.Size = Vector3.new(60, 1, 60)
	floor.CFrame = origin * CFrame.new(0, -2, 0)
	floor.Material = Enum.Material.SmoothPlastic
	floor.Color = Color3.fromRGB(10, 6, 18)
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.Parent = scene

	local backWall = Instance.new("Part")
	backWall.Name = "BackWall"
	backWall.Anchored = true
	backWall.CanCollide = false
	backWall.Size = Vector3.new(50, 20, 1)
	backWall.CFrame = origin * CFrame.new(0, 8, -15)
	backWall.Material = Enum.Material.Concrete
	backWall.Color = Color3.fromRGB(14, 8, 26)
	backWall.Parent = scene

	-- A row of glowing "neon" purple bars suspended in front of the wall.
	for i = -3, 3 do
		local bar = Instance.new("Part")
		bar.Name = "NeonBar_" .. (i + 4)
		bar.Anchored = true
		bar.CanCollide = false
		bar.Size = Vector3.new(0.4, 12, 0.4)
		bar.CFrame = origin * CFrame.new(i * 5, 6, -14)
		bar.Material = Enum.Material.Neon
		bar.Color = (i % 2 == 0) and PALETTE.primaryGlow or PALETTE.secondaryGlow
		bar.Transparency = 0.2
		bar.Parent = scene

		local pointLight = Instance.new("PointLight")
		pointLight.Brightness = 1.4
		pointLight.Range = 14
		pointLight.Color = bar.Color
		pointLight.Parent = bar
	end

	-- A "VHS TV" prop in the centre.
	local tv = Instance.new("Part")
	tv.Name = "TV"
	tv.Anchored = true
	tv.CanCollide = false
	tv.Size = Vector3.new(6, 4, 0.6)
	tv.CFrame = origin * CFrame.new(0, 4, -10)
	tv.Material = Enum.Material.SmoothPlastic
	tv.Color = Color3.fromRGB(20, 12, 32)
	tv.Parent = scene

	local screen = Instance.new("Part")
	screen.Name = "Screen"
	screen.Anchored = true
	screen.CanCollide = false
	screen.Size = Vector3.new(5.2, 3.2, 0.05)
	screen.CFrame = tv.CFrame * CFrame.new(0, 0, 0.32)
	screen.Material = Enum.Material.Neon
	screen.Color = PALETTE.primaryGlow
	screen.Transparency = 0.15
	screen.Parent = scene

	-- An accent camera position for the menu camera.
	local camAttach = Instance.new("Part")
	camAttach.Name = "CameraPosition"
	camAttach.Anchored = true
	camAttach.CanCollide = false
	camAttach.Transparency = 1
	camAttach.Size = Vector3.new(1, 1, 1)
	camAttach.CFrame = origin * CFrame.new(0, 5, 6)
	camAttach.Parent = scene

	-- Soft floor reflection part for ambience.
	local fog = Instance.new("Part")
	fog.Name = "FogPad"
	fog.Anchored = true
	fog.CanCollide = false
	fog.Transparency = 0.7
	fog.Material = Enum.Material.ForceField
	fog.Color = PALETTE.primaryGlow
	fog.Size = Vector3.new(50, 0.1, 50)
	fog.CFrame = origin * CFrame.new(0, -1, 0)
	fog.Parent = scene

	return scene
end

------------------------------------------------------------------------------
-- Lighting effects (bloom + grain + soft blur)
------------------------------------------------------------------------------

local function buildLightingEffects()
	-- Wipe any old menu effects first
	for _, child in ipairs(Lighting:GetChildren()) do
		if child.Name:sub(1, 5) == "HMFx_" then
			child:Destroy()
		end
	end

	local bloom = Instance.new("BloomEffect")
	bloom.Name = "HMFx_Bloom"
	bloom.Intensity = 0.6
	bloom.Size = 36
	bloom.Threshold = 0.85
	bloom.Parent = Lighting

	local blur = Instance.new("BlurEffect")
	blur.Name = "HMFx_MenuBlur"
	blur.Size = 0 -- The client raises this while the menu is open.
	blur.Parent = Lighting

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "HMFx_Color"
	cc.Brightness = -0.02
	cc.Contrast = 0.18
	cc.Saturation = -0.05
	cc.TintColor = Color3.fromRGB(220, 200, 255)
	cc.Parent = Lighting

	local atmos = Instance.new("Atmosphere")
	atmos.Name = "HMFx_Atmosphere"
	atmos.Density = 0.35
	atmos.Offset = 0.2
	atmos.Color = Color3.fromRGB(28, 16, 60)
	atmos.Decay = Color3.fromRGB(8, 4, 16)
	atmos.Glare = 0
	atmos.Haze = 0.6
	atmos.Parent = Lighting
end

------------------------------------------------------------------------------
-- MenuConfig ModuleScript (data the client + server share)
------------------------------------------------------------------------------

local MENU_CONFIG_SOURCE = [==[
--!strict
-- ReplicatedStorage.HorrorMenu.MenuConfig
-- Generated by HorrorMenuPlugin -- tune the menu without editing scripts.

local MenuConfig = {}

-- Set this to the placeId of the lobby/gameplay place to teleport to on
-- "Start Game" / "Matchmake". 0 = stay in current place (useful while testing).
MenuConfig.GamePlaceId = 0

MenuConfig.MaxPartySize = 4

MenuConfig.Missions = {
	{
		id = "facility_alpha",
		title = "Facility Alpha",
		blurb = "Reset the breaker grid before the night shift ends.",
		minDifficulty = "Easy",
	},
	{
		id = "the_attraction",
		title = "The Attraction",
		blurb = "Survive seven hours inside the abandoned park.",
		minDifficulty = "Normal",
	},
	{
		id = "static_signal",
		title = "Static Signal",
		blurb = "Decode the broken transmission. Don't blink.",
		minDifficulty = "Hard",
	},
	{
		id = "the_loop",
		title = "The Loop",
		blurb = "Endless mode. Tapes never stop rewinding.",
		minDifficulty = "Nightmare",
	},
}

MenuConfig.Difficulties = { "Easy", "Normal", "Hard", "Nightmare" }

MenuConfig.DefaultSettings = {
	MasterVolume = 80,
	MusicVolume = 60,
	SfxVolume = 85,
	AmbienceVolume = 70,
	Quality = 75,
	MotionBlur = true,
	FilmGrain = true,
	Fullscreen = false,
	Sensitivity = 50,
	FieldOfView = 70,
	Keybinds = {
		Forward = "W",
		Back = "S",
		Left = "A",
		Right = "D",
		Sprint = "LeftShift",
		Interact = "E",
		Crouch = "LeftControl",
		Flashlight = "F",
		Menu = "Escape",
	},
}

return MenuConfig
]==]

------------------------------------------------------------------------------
-- SERVER source (installed under ServerScriptService.HorrorMenuServer)
------------------------------------------------------------------------------

local SERVER_SOURCE = [==[
--!strict
-- ServerScriptService.HorrorMenuServer
-- Owns the party / matchmaking / settings-persistence remotes for the
-- HorrorMenu plugin.  Server is authoritative: clients never mutate party
-- state directly, only request changes via RemoteEvents / RemoteFunctions.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local TextService = game:GetService("TextService")

local pkg = ReplicatedStorage:WaitForChild("HorrorMenu")
local Remotes = pkg:WaitForChild("Remotes")
local Config = require(pkg:WaitForChild("MenuConfig"))

local SettingsStore = DataStoreService:GetDataStore("HorrorMenu_Settings_v1")

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

local function getRemote(name: string, class: string): any
	local r = Remotes:WaitForChild(name)
	assert(r:IsA(class), "expected " .. class .. " for remote " .. name)
	return r
end

local function generateCode(): string
	-- 4-character A-Z + 2-digit code, e.g. "ZK 47".
	local alphabet = "ABCDEFGHJKMNPQRSTVWXYZ"
	local s = ""
	for _ = 1, 4 do
		local i = math.random(1, #alphabet)
		s ..= alphabet:sub(i, i)
	end
	return s
end

local function sanitizeChat(text: string): string?
	if typeof(text) ~= "string" then
		return nil
	end
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if #text == 0 then
		return nil
	end
	if #text > 240 then
		text = text:sub(1, 240)
	end
	return text
end

local function sanitizeDifficulty(value): string
	if typeof(value) ~= "string" then
		return Config.Difficulties[1]
	end
	for _, d in ipairs(Config.Difficulties) do
		if d == value then
			return d
		end
	end
	return Config.Difficulties[1]
end

local function sanitizeMission(value): string
	if typeof(value) ~= "string" then
		return Config.Missions[1].id
	end
	for _, m in ipairs(Config.Missions) do
		if m.id == value then
			return m.id
		end
	end
	return Config.Missions[1].id
end

----------------------------------------------------------------------
-- Party state
----------------------------------------------------------------------

type Party = {
	code: string,
	leaderId: number,
	memberIds: { number },
	maxSize: number,
	public: boolean,
	missionId: string,
	difficulty: string,
	ready: { [number]: boolean },
	chat: { { id: number, name: string, text: string, t: number } },
	starting: boolean,
}

local parties: { [string]: Party } = {}
local playerParty: { [number]: string } = {}

local function indexOf(t, value): number?
	for i, v in ipairs(t) do
		if v == value then
			return i
		end
	end
	return nil
end

local function partyOf(player: Player): Party?
	local code = playerParty[player.UserId]
	if not code then
		return nil
	end
	return parties[code]
end

local function memberPlayers(party: Party): { Player }
	local out = {}
	for _, uid in ipairs(party.memberIds) do
		local p = Players:GetPlayerByUserId(uid)
		if p then
			table.insert(out, p)
		end
	end
	return out
end

local function snapshotForClient(party: Party)
	local membersOut = {}
	for _, uid in ipairs(party.memberIds) do
		local p = Players:GetPlayerByUserId(uid)
		table.insert(membersOut, {
			userId = uid,
			name = p and p.Name or "Player",
			displayName = p and p.DisplayName or "Player",
			ready = party.ready[uid] == true,
			isLeader = uid == party.leaderId,
		})
	end
	return {
		code = party.code,
		leaderId = party.leaderId,
		maxSize = party.maxSize,
		public = party.public,
		missionId = party.missionId,
		difficulty = party.difficulty,
		members = membersOut,
		chat = party.chat,
		starting = party.starting,
	}
end

local PartyState = getRemote("PartyState", "RemoteEvent")

local function broadcastParty(party: Party)
	local snap = snapshotForClient(party)
	for _, p in ipairs(memberPlayers(party)) do
		PartyState:FireClient(p, snap)
	end
end

local function broadcastPartyDissolved(player: Player)
	PartyState:FireClient(player, false)
end

local function newParty(leader: Player): Party
	local code = generateCode()
	while parties[code] do
		code = generateCode()
	end
	local party: Party = {
		code = code,
		leaderId = leader.UserId,
		memberIds = { leader.UserId },
		maxSize = Config.MaxPartySize or 4,
		public = false,
		missionId = Config.Missions[1].id,
		difficulty = Config.Difficulties[1],
		ready = { [leader.UserId] = false },
		chat = {},
		starting = false,
	}
	parties[code] = party
	playerParty[leader.UserId] = code
	return party
end

local function removeFromParty(player: Player)
	local code = playerParty[player.UserId]
	if not code then
		return
	end
	local party = parties[code]
	playerParty[player.UserId] = nil
	if not party then
		return
	end
	local idx = indexOf(party.memberIds, player.UserId)
	if idx then
		table.remove(party.memberIds, idx)
	end
	party.ready[player.UserId] = nil
	broadcastPartyDissolved(player)
	if #party.memberIds == 0 then
		parties[code] = nil
		return
	end
	if party.leaderId == player.UserId then
		party.leaderId = party.memberIds[1]
	end
	broadcastParty(party)
end

----------------------------------------------------------------------
-- Remotes
----------------------------------------------------------------------

local CreateParty = getRemote("CreateParty", "RemoteFunction")
local JoinParty = getRemote("JoinParty", "RemoteFunction")
local LeaveParty = getRemote("LeaveParty", "RemoteEvent")
local SetReady = getRemote("SetReady", "RemoteEvent")
local KickMember = getRemote("KickMember", "RemoteEvent")
local TransferLeader = getRemote("TransferLeader", "RemoteEvent")
local StartGame = getRemote("StartGame", "RemoteEvent")
local SendChat = getRemote("SendChat", "RemoteEvent")
local SetMission = getRemote("SetMission", "RemoteEvent")
local SetDifficulty = getRemote("SetDifficulty", "RemoteEvent")
local SetLobbyType = getRemote("SetLobbyType", "RemoteEvent")
local StartMatchmake = getRemote("StartMatchmake", "RemoteFunction")
local InvitePlayer = getRemote("InvitePlayer", "RemoteEvent")
local InviteReceived = getRemote("InviteReceived", "RemoteEvent")
local AcceptInvite = getRemote("AcceptInvite", "RemoteEvent")
local DeclineInvite = getRemote("DeclineInvite", "RemoteEvent")
local SaveSettings = getRemote("SaveSettings", "RemoteEvent")
local SettingsLoaded = getRemote("SettingsLoaded", "RemoteEvent")
local Toast = getRemote("Toast", "RemoteEvent")

local pendingInvites: { [number]: { from: number, code: string, t: number } } = {}

CreateParty.OnServerInvoke = function(player: Player)
	if playerParty[player.UserId] then
		return false, "already in a party"
	end
	local party = newParty(player)
	broadcastParty(party)
	return true, party.code
end

JoinParty.OnServerInvoke = function(player: Player, codeAny)
	if typeof(codeAny) ~= "string" then
		return false, "invalid code"
	end
	local code = codeAny:upper():gsub("%s+", "")
	local party = parties[code]
	if not party then
		return false, "no party found"
	end
	if #party.memberIds >= party.maxSize then
		return false, "party is full"
	end
	if playerParty[player.UserId] then
		removeFromParty(player)
	end
	table.insert(party.memberIds, player.UserId)
	party.ready[player.UserId] = false
	playerParty[player.UserId] = code
	broadcastParty(party)
	return true, party.code
end

LeaveParty.OnServerEvent:Connect(function(player)
	removeFromParty(player)
end)

SetReady.OnServerEvent:Connect(function(player, value)
	local party = partyOf(player)
	if not party then
		return
	end
	party.ready[player.UserId] = value and true or false
	broadcastParty(party)
end)

KickMember.OnServerEvent:Connect(function(player, targetUidAny)
	local party = partyOf(player)
	if not party or party.leaderId ~= player.UserId then
		return
	end
	if typeof(targetUidAny) ~= "number" then
		return
	end
	local target = Players:GetPlayerByUserId(targetUidAny)
	if target then
		removeFromParty(target)
	end
end)

TransferLeader.OnServerEvent:Connect(function(player, targetUidAny)
	local party = partyOf(player)
	if not party or party.leaderId ~= player.UserId then
		return
	end
	if typeof(targetUidAny) ~= "number" then
		return
	end
	if not indexOf(party.memberIds, targetUidAny) then
		return
	end
	party.leaderId = targetUidAny
	broadcastParty(party)
end)

SetMission.OnServerEvent:Connect(function(player, missionId)
	local party = partyOf(player)
	if not party or party.leaderId ~= player.UserId then
		return
	end
	party.missionId = sanitizeMission(missionId)
	broadcastParty(party)
end)

SetDifficulty.OnServerEvent:Connect(function(player, value)
	local party = partyOf(player)
	if not party or party.leaderId ~= player.UserId then
		return
	end
	party.difficulty = sanitizeDifficulty(value)
	broadcastParty(party)
end)

SetLobbyType.OnServerEvent:Connect(function(player, isPublic)
	local party = partyOf(player)
	if not party or party.leaderId ~= player.UserId then
		return
	end
	party.public = isPublic and true or false
	broadcastParty(party)
end)

-- Roblox requires every player-authored string we display to other players to
-- pass through TextService.  We filter once on the server and broadcast the
-- broadcast-safe filtered version to every party member.
local function filterChatForBroadcast(text: string, fromUserId: number): string?
	local okFilter, filterResult = pcall(function()
		return TextService:FilterStringAsync(text, fromUserId, Enum.TextFilterContext.PublicChat)
	end)
	if not okFilter then
		warn("[HorrorMenu] FilterStringAsync failed:", filterResult)
		return nil
	end
	local okText, filtered = pcall(function()
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)
	if not okText then
		warn("[HorrorMenu] GetNonChatStringForBroadcastAsync failed:", filtered)
		return nil
	end
	return filtered
end

SendChat.OnServerEvent:Connect(function(player, textAny)
	local party = partyOf(player)
	if not party then
		return
	end
	local text = sanitizeChat(textAny)
	if not text then
		return
	end
	local filtered = filterChatForBroadcast(text, player.UserId)
	if not filtered then
		Toast:FireClient(player, "Chat", "Message could not be sent.")
		return
	end
	local entry = {
		id = player.UserId,
		name = player.DisplayName,
		text = filtered,
		t = os.time(),
	}
	table.insert(party.chat, entry)
	if #party.chat > 50 then
		table.remove(party.chat, 1)
	end
	broadcastParty(party)
end)

InvitePlayer.OnServerEvent:Connect(function(player, targetUidAny)
	local party = partyOf(player)
	if not party or party.leaderId ~= player.UserId then
		Toast:FireClient(player, "Party", "You must be in a party to invite.")
		return
	end
	if typeof(targetUidAny) ~= "number" then
		return
	end
	local target = Players:GetPlayerByUserId(targetUidAny)
	if not target then
		Toast:FireClient(player, "Invite", "Player is not in this server.")
		return
	end
	pendingInvites[target.UserId] = {
		from = player.UserId,
		code = party.code,
		t = os.time(),
	}
	InviteReceived:FireClient(target, {
		fromName = player.DisplayName,
		fromUserId = player.UserId,
		code = party.code,
	})
	Toast:FireClient(player, "Invite", "Invite sent to " .. target.DisplayName)
end)

AcceptInvite.OnServerEvent:Connect(function(player)
	local inv = pendingInvites[player.UserId]
	if not inv then
		Toast:FireClient(player, "Invite", "No pending invites.")
		return
	end
	pendingInvites[player.UserId] = nil
	local code = inv.code
	local party = parties[code]
	if not party then
		Toast:FireClient(player, "Invite", "Party no longer exists.")
		return
	end
	if #party.memberIds >= party.maxSize then
		Toast:FireClient(player, "Invite", "Party is full.")
		return
	end
	if playerParty[player.UserId] then
		removeFromParty(player)
	end
	table.insert(party.memberIds, player.UserId)
	party.ready[player.UserId] = false
	playerParty[player.UserId] = code
	broadcastParty(party)
end)

DeclineInvite.OnServerEvent:Connect(function(player)
	pendingInvites[player.UserId] = nil
end)

----------------------------------------------------------------------
-- Matchmaking + StartGame teleport
----------------------------------------------------------------------

local function allMembersReady(party: Party): boolean
	for _, uid in ipairs(party.memberIds) do
		if not party.ready[uid] then
			return false
		end
	end
	return true
end

local function teleportPartyToPlace(party: Party, placeId: number)
	if placeId <= 0 then
		for _, p in ipairs(memberPlayers(party)) do
			Toast:FireClient(p, "Match", "GamePlaceId is 0 -- staying here for demo.")
		end
		party.starting = false
		broadcastParty(party)
		return
	end
	local players = memberPlayers(party)
	local ok, accessCode = pcall(function()
		return TeleportService:ReserveServer(placeId)
	end)
	if not ok then
		warn("[HorrorMenu] ReserveServer failed:", accessCode)
		for _, p in ipairs(players) do
			Toast:FireClient(p, "Match", "Failed to reserve server.")
		end
		party.starting = false
		broadcastParty(party)
		return
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = accessCode
	options:SetTeleportData({
		partyCode = party.code,
		missionId = party.missionId,
		difficulty = party.difficulty,
	})
	local ok2, err = pcall(function()
		TeleportService:TeleportAsync(placeId, players, options)
	end)
	if not ok2 then
		warn("[HorrorMenu] TeleportAsync failed:", err)
		for _, p in ipairs(players) do
			Toast:FireClient(p, "Match", "Teleport failed: " .. tostring(err))
		end
		party.starting = false
		broadcastParty(party)
	end
end

StartGame.OnServerEvent:Connect(function(player)
	local party = partyOf(player)
	if not party or party.leaderId ~= player.UserId then
		return
	end
	if not allMembersReady(party) then
		Toast:FireClient(player, "Match", "All party members must be ready.")
		return
	end
	if party.starting then
		return
	end
	party.starting = true
	broadcastParty(party)
	task.defer(teleportPartyToPlace, party, Config.GamePlaceId or 0)
end)

StartMatchmake.OnServerInvoke = function(player, missionAny, difficultyAny, publicAny)
	local missionId = sanitizeMission(missionAny)
	local difficulty = sanitizeDifficulty(difficultyAny)
	local public = publicAny and true or false
	-- If the player isn't in a party, spin up a solo one so the same flow runs.
	local party = partyOf(player)
	if not party then
		party = newParty(player)
	end
	party.missionId = missionId
	party.difficulty = difficulty
	party.public = public
	party.ready[player.UserId] = true
	broadcastParty(party)
	task.defer(function()
		if allMembersReady(party) then
			teleportPartyToPlace(party, Config.GamePlaceId or 0)
		else
			Toast:FireClient(player, "Match", "Waiting for party members...")
		end
	end)
	return true, party.code
end

----------------------------------------------------------------------
-- Settings persistence
----------------------------------------------------------------------

local function loadSettings(player: Player)
	local key = "u_" .. tostring(player.UserId)
	local ok, data = pcall(function()
		return SettingsStore:GetAsync(key)
	end)
	if not ok or typeof(data) ~= "table" then
		data = Config.DefaultSettings
	end
	SettingsLoaded:FireClient(player, data)
end

SaveSettings.OnServerEvent:Connect(function(player, settingsAny)
	if typeof(settingsAny) ~= "table" then
		return
	end
	local key = "u_" .. tostring(player.UserId)
	local ok, err = pcall(function()
		SettingsStore:SetAsync(key, settingsAny)
	end)
	if not ok then
		warn("[HorrorMenu] settings save failed:", err)
		Toast:FireClient(player, "Settings", "Save failed.")
		return
	end
	Toast:FireClient(player, "Settings", "Saved.")
end)

----------------------------------------------------------------------
-- Player lifecycle
----------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
	task.spawn(loadSettings, player)
end)

Players.PlayerRemoving:Connect(function(player)
	removeFromParty(player)
end)

print("[HorrorMenu] server ready -- parties / matchmaking / settings online")
]==]

------------------------------------------------------------------------------
-- CLIENT source (installed under StarterPlayer.StarterPlayerScripts.HorrorMenuClient)
------------------------------------------------------------------------------

local CLIENT_SOURCE = [==[
--!nocheck
-- StarterPlayer.StarterPlayerScripts.HorrorMenuClient
-- Big single-script client for the HorrorMenu plugin.  Owns:
--   - screen manager (Main / Play / Party / Settings / Credits)
--   - hover + click + sound feedback for every HMHoverable button
--   - settings load / save / live-apply
--   - party UI sync from the server
--   - menu camera + sway / parallax / dust
--   - loading screen, invite popup, toast notifications

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local pkg = ReplicatedStorage:WaitForChild("HorrorMenu")
local Remotes = pkg:WaitForChild("Remotes")
local Config = require(pkg:WaitForChild("MenuConfig"))

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Gui = PlayerGui:WaitForChild("HorrorMenuGui")

local function findByAttribute(parent, attrName)
	for _, d in ipairs(parent:GetDescendants()) do
		if d:GetAttribute(attrName) then
			return d
		end
	end
	return nil
end

local Sounds = Gui:WaitForChild("Sounds")
local function playSound(name, volume)
	local s = Sounds:FindFirstChild(name)
	if not s then
		return
	end
	local clone = s:Clone()
	clone.Volume = volume or s.Volume
	clone.Parent = Sounds
	clone:Play()
	game:GetService("Debris"):AddItem(clone, 5)
end

----------------------------------------------------------------------
-- UI references
----------------------------------------------------------------------

local mainMenu = Gui:WaitForChild("MainMenu")
local playPanel = Gui:WaitForChild("PlayPanel")
local partyPanel = Gui:WaitForChild("PartyPanel")
local settingsPanel = Gui:WaitForChild("SettingsPanel")
local creditsPanel = Gui:WaitForChild("CreditsPanel")
local loadingScreen = Gui:WaitForChild("LoadingScreen")
local fader = findByAttribute(Gui, "HMFader")
local invitePopup = findByAttribute(Gui, "HMInvitePopup")
local notifications = findByAttribute(Gui, "HMNotifications")

local panels = {
	Play = playPanel,
	Party = partyPanel,
	Settings = settingsPanel,
	Credits = creditsPanel,
}

local toastTemplate = findByAttribute(Gui, "HMToastTemplate")
local memberTemplate = findByAttribute(Gui, "HMPartyMemberTemplate")

----------------------------------------------------------------------
-- Tween helpers
----------------------------------------------------------------------

local function tween(obj, time, props, style, dir)
	local tinfo = TweenInfo.new(
		time,
		style or Enum.EasingStyle.Quad,
		dir or Enum.EasingDirection.Out
	)
	local t = TweenService:Create(obj, tinfo, props)
	t:Play()
	return t
end

local function fadeIn(obj, time)
	obj.Visible = true
	if obj:IsA("Frame") or obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
		obj.BackgroundTransparency = 1
		tween(obj, time or 0.35, { BackgroundTransparency = 0.1 })
	end
	-- Slide-up entrance for panels
	if obj:GetAttribute("HMScreen") then
		local original = obj.Position
		obj.Position = original + UDim2.fromOffset(0, 20)
		tween(obj, time or 0.35, { Position = original })
	end
end

----------------------------------------------------------------------
-- Screen manager
----------------------------------------------------------------------

local currentScreen = "Main"

local function showScreen(name)
	if name == currentScreen then
		return
	end
	playSound("transition", 0.4)
	for key, panel in pairs(panels) do
		if panel and key ~= name then
			panel.Visible = false
		end
	end
	if name == "Main" then
		mainMenu.Visible = true
	else
		local panel = panels[name]
		if panel then
			fadeIn(panel, 0.35)
		end
	end
	currentScreen = name
end

local function fade(toBlack, time, after)
	if not fader then
		if after then
			after()
		end
		return
	end
	fader.Visible = true
	tween(fader, time or 0.35, { BackgroundTransparency = toBlack and 0 or 1 })
	task.delay(time or 0.35, function()
		if not toBlack then
			fader.Visible = false
		end
		if after then
			after()
		end
	end)
end

----------------------------------------------------------------------
-- Hover + click wiring (any TextButton with HMHoverable=true)
----------------------------------------------------------------------

local function wireHoverable(button)
	if not button:IsA("GuiButton") then
		return
	end
	if button:GetAttribute("HMHoverWired") then
		return
	end
	button:SetAttribute("HMHoverWired", true)

	local originalSize = button.Size
	local hoverSize = UDim2.new(
		originalSize.X.Scale,
		originalSize.X.Offset + 6,
		originalSize.Y.Scale,
		originalSize.Y.Offset
	)
	local origBgTransparency = button.BackgroundTransparency

	local strokeChild = button:FindFirstChildOfClass("UIStroke")
	local bracket = button:FindFirstChild("Bracket")
	local rail = button:FindFirstChild("Rail")

	button.MouseEnter:Connect(function()
		playSound("hover", 0.18)
		tween(button, 0.18, {
			Size = hoverSize,
			BackgroundTransparency = math.max(0, origBgTransparency - 0.1),
		})
		if strokeChild then
			tween(strokeChild, 0.18, { Transparency = 0.05, Thickness = (strokeChild.Thickness or 1) + 0.5 })
		end
		if bracket then
			tween(bracket, 0.18, { TextTransparency = 0 })
			bracket.Text = ">>"
		end
		if rail then
			tween(rail, 0.18, { Size = UDim2.new(0, 5, 1, -10) })
		end
	end)

	button.MouseLeave:Connect(function()
		tween(button, 0.18, {
			Size = originalSize,
			BackgroundTransparency = origBgTransparency,
		})
		if strokeChild then
			tween(strokeChild, 0.18, { Transparency = 0.4, Thickness = math.max(1, (strokeChild.Thickness or 1) - 0.5) })
		end
		if bracket then
			tween(bracket, 0.18, { TextTransparency = 0.35 })
			bracket.Text = ">"
		end
		if rail then
			tween(rail, 0.18, { Size = UDim2.new(0, 3, 1, -10) })
		end
	end)

	button.MouseButton1Click:Connect(function()
		playSound("click", 0.35)
	end)
end

for _, d in ipairs(Gui:GetDescendants()) do
	if d:GetAttribute("HMHoverable") then
		wireHoverable(d)
	end
end
Gui.DescendantAdded:Connect(function(d)
	if d:GetAttribute("HMHoverable") then
		wireHoverable(d)
	end
end)

----------------------------------------------------------------------
-- Main menu wiring
----------------------------------------------------------------------

local function findMainButton(target)
	for _, b in ipairs(mainMenu:GetDescendants()) do
		if b:IsA("TextButton") and b:GetAttribute("HMTarget") == target then
			return b
		end
	end
	return nil
end

local quitConfirmActive = false

local function confirmQuit()
	if quitConfirmActive then
		return
	end
	quitConfirmActive = true
	local btn = findMainButton("Quit")
	if not btn then
		quitConfirmActive = false
		return
	end
	local label = btn:FindFirstChild("Label")
	if not label then
		quitConfirmActive = false
		return
	end
	local original = label.Text
	label.Text = "ARE  YOU  SURE  ?  [CLICK  AGAIN]"
	local doubleClick
	doubleClick = btn.MouseButton1Click:Connect(function()
		doubleClick:Disconnect()
		quitConfirmActive = false
		fade(true, 0.5, function()
			LocalPlayer:Kick("Closed the menu.")
		end)
	end)
	task.delay(2.5, function()
		if quitConfirmActive then
			label.Text = original
			quitConfirmActive = false
			if doubleClick.Connected then
				doubleClick:Disconnect()
			end
		end
	end)
end

local function onMainButton(target)
	if target == "Quit" then
		confirmQuit()
		return
	end
	showScreen(target)
end

for _, b in ipairs(mainMenu:GetDescendants()) do
	if b:IsA("TextButton") and b:GetAttribute("HMTarget") then
		local target = b:GetAttribute("HMTarget")
		b.MouseButton1Click:Connect(function()
			onMainButton(target)
		end)
	end
end

-- Back buttons on every side panel
for _, d in ipairs(Gui:GetDescendants()) do
	if d:IsA("TextButton") and d:GetAttribute("HMBack") then
		d.MouseButton1Click:Connect(function()
			showScreen("Main")
		end)
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Escape and currentScreen ~= "Main" then
		showScreen("Main")
	end
end)
]==]

CLIENT_SOURCE = CLIENT_SOURCE
	.. [==[

----------------------------------------------------------------------
-- Settings: state + apply + persistence
----------------------------------------------------------------------

local function deepCopy(value)
	if typeof(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = deepCopy(v)
	end
	return out
end

local Settings = deepCopy(Config.DefaultSettings)

local SettingsBody = settingsPanel:FindFirstChild("Body"):FindFirstChild("Settings")

local function updateSliderUI(row, value)
	value = math.clamp(math.floor(value + 0.5), 0, 100)
	local suffix = row:GetAttribute("HMSliderSuffix") or "%"
	row:SetAttribute("HMSliderValue", value)
	local valueLabel = row:FindFirstChild("Value")
	if valueLabel then
		valueLabel.Text = tostring(value) .. suffix
	end
	local track = row:FindFirstChild("Track")
	if track then
		local fill = track:FindFirstChild("Fill")
		local knob = track:FindFirstChild("Knob")
		if fill then
			fill.Size = UDim2.new(value / 100, 0, 1, 0)
		end
		if knob then
			knob.Position = UDim2.new(value / 100, -7, 0.5, -7)
		end
	end
end

local function applySettingsToWorld()
	-- Volumes
	SoundService.Volume = (Settings.MasterVolume or 80) / 100
	local sfxSounds = { "hover", "click", "back", "toggle", "transition", "error" }
	for _, s in ipairs(Sounds:GetChildren()) do
		if s:IsA("Sound") then
			if s.Name == "music" then
				s.Volume = (Settings.MusicVolume or 60) / 100 * 0.6
			elseif s.Name == "staticAmbience" then
				s.Volume = (Settings.AmbienceVolume or 70) / 100 * 0.3
			elseif table.find(sfxSounds, s.Name) then
				s.Volume = (Settings.SfxVolume or 85) / 100 * 0.6
			end
		end
	end

	-- Camera FOV + sensitivity
	local cam = Workspace.CurrentCamera
	if cam then
		cam.FieldOfView = 40 + ((Settings.FieldOfView or 70) / 100) * 80
	end
	UserInputService.MouseDeltaSensitivity = 0.2 + ((Settings.Sensitivity or 50) / 100) * 1.8

	-- Motion blur
	local existingBlur = Lighting:FindFirstChild("HMFx_MotionBlur")
	if Settings.MotionBlur then
		if not existingBlur then
			local b = Instance.new("BlurEffect")
			b.Name = "HMFx_MotionBlur"
			b.Size = 0
			b.Parent = Lighting
		end
	else
		if existingBlur then
			existingBlur:Destroy()
		end
	end

	-- Film grain (the GUI overlay)
	local grain = Gui.VHSOverlay and Gui.VHSOverlay:FindFirstChild("Grain")
	if grain then
		grain.ImageTransparency = Settings.FilmGrain and 0.92 or 1
	end

	-- Note: Roblox does not let scripts toggle the user's fullscreen window
	-- directly -- the Fullscreen toggle is left in the UI for parity with
	-- other settings menus and as a hint to the user to press F11 themselves.
end

local function ensureKeybindButton(name)
	for _, btn in ipairs(SettingsBody:GetDescendants()) do
		if btn:IsA("TextButton") and btn:GetAttribute("HMKeybind") == name then
			return btn
		end
	end
	return nil
end

local function setKeybind(name, key)
	Settings.Keybinds[name] = key
	local btn = ensureKeybindButton(name)
	if btn then
		btn.Text = string.upper(tostring(key))
		btn:SetAttribute("HMKeybindValue", key)
	end
end

local function applySettingsToUI()
	-- Sliders
	for _, row in ipairs(SettingsBody:GetDescendants()) do
		if row:GetAttribute("HMSlider") then
			local key = row:GetAttribute("HMSlider")
			updateSliderUI(row, Settings[key] or 0)
		elseif row:GetAttribute("HMToggle") then
			local key = row:GetAttribute("HMToggle")
			local on = Settings[key] == true
			row:SetAttribute("HMToggleValue", on)
			row.BackgroundColor3 = on
				and Color3.fromRGB(180, 90, 255)
				or Color3.fromRGB(14, 8, 26)
			local knob = row:FindFirstChild("Knob")
			if knob then
				knob.Position = on and UDim2.new(1, -22, 0.5, -10)
					or UDim2.new(0, 2, 0.5, -10)
			end
		end
	end
	for name, key in pairs(Settings.Keybinds or {}) do
		setKeybind(name, key)
	end
end

local function setSlider(key, value)
	Settings[key] = value
	for _, row in ipairs(SettingsBody:GetDescendants()) do
		if row:GetAttribute("HMSlider") == key then
			updateSliderUI(row, value)
		end
	end
	applySettingsToWorld()
end

local function setToggle(key, value)
	Settings[key] = value and true or false
	for _, row in ipairs(SettingsBody:GetDescendants()) do
		if row:GetAttribute("HMToggle") == key then
			local on = Settings[key]
			row:SetAttribute("HMToggleValue", on)
			row.BackgroundColor3 = on
				and Color3.fromRGB(180, 90, 255)
				or Color3.fromRGB(14, 8, 26)
			local knob = row:FindFirstChild("Knob")
			if knob then
				tween(knob, 0.15, {
					Position = on and UDim2.new(1, -22, 0.5, -10) or UDim2.new(0, 2, 0.5, -10),
				})
			end
		end
	end
	applySettingsToWorld()
end

-- Slider drag wiring
for _, row in ipairs(SettingsBody:GetDescendants()) do
	if row:GetAttribute("HMSlider") then
		local key = row:GetAttribute("HMSlider")
		local track = row:FindFirstChild("Track")
		if track then
			local dragging = false
			local function updateFromInputX(x)
				local absPos = track.AbsolutePosition.X
				local absSize = track.AbsoluteSize.X
				local pct = math.clamp((x - absPos) / math.max(1, absSize), 0, 1)
				setSlider(key, pct * 100)
			end
			track.InputBegan:Connect(function(input)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					dragging = true
					updateFromInputX(input.Position.X)
				end
			end)
			UserInputService.InputChanged:Connect(function(input)
				if not dragging then
					return
				end
				if
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				then
					updateFromInputX(input.Position.X)
				end
			end)
			UserInputService.InputEnded:Connect(function(input)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					dragging = false
				end
			end)
		end
	end
end

-- Toggle button wiring
for _, t in ipairs(SettingsBody:GetDescendants()) do
	if t:GetAttribute("HMToggle") and t:IsA("GuiButton") then
		local key = t:GetAttribute("HMToggle")
		t.MouseButton1Click:Connect(function()
			setToggle(key, not Settings[key])
		end)
	end
end

-- Keybind capture
local capturing = nil
local function captureKeybind(name, btn)
	if capturing then
		return
	end
	capturing = name
	btn.Text = "PRESS  KEY..."
	local conn
	conn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			local keyName = input.KeyCode.Name
			setKeybind(name, keyName)
			capturing = nil
			conn:Disconnect()
		end
	end)
end

for _, b in ipairs(SettingsBody:GetDescendants()) do
	if b:IsA("TextButton") and b:GetAttribute("HMKeybind") then
		b.MouseButton1Click:Connect(function()
			captureKeybind(b:GetAttribute("HMKeybind"), b)
		end)
	end
end

-- Save / reset buttons
for _, b in ipairs(SettingsBody:GetDescendants()) do
	if b:IsA("TextButton") and b:GetAttribute("HMAction") == "SaveSettings" then
		b.MouseButton1Click:Connect(function()
			local payload = deepCopy(Settings)
			Remotes.SaveSettings:FireServer(payload)
		end)
	elseif b:IsA("TextButton") and b:GetAttribute("HMAction") == "ResetSettings" then
		b.MouseButton1Click:Connect(function()
			Settings = deepCopy(Config.DefaultSettings)
			applySettingsToUI()
			applySettingsToWorld()
		end)
	end
end

-- Receive saved settings from the server when we join.
Remotes.SettingsLoaded.OnClientEvent:Connect(function(data)
	if typeof(data) ~= "table" then
		return
	end
	for k, v in pairs(data) do
		Settings[k] = v
	end
	applySettingsToUI()
	applySettingsToWorld()
end)
]==]

CLIENT_SOURCE = CLIENT_SOURCE
	.. [==[

----------------------------------------------------------------------
-- Toasts / notifications
----------------------------------------------------------------------

local function toast(title, body)
	if not toastTemplate then
		return
	end
	local copy = toastTemplate:Clone()
	copy.Visible = true
	copy.Name = "Toast"
	copy.BackgroundTransparency = 1
	copy.Parent = notifications
	local titleLbl = copy:FindFirstChild("Title")
	local bodyLbl = copy:FindFirstChild("Body")
	if titleLbl then
		titleLbl.Text = string.upper(tostring(title or "INFO"))
	end
	if bodyLbl then
		bodyLbl.Text = tostring(body or "")
	end
	tween(copy, 0.25, { BackgroundTransparency = 0.15 })
	task.delay(4.5, function()
		tween(copy, 0.35, { BackgroundTransparency = 1 })
		task.delay(0.4, function()
			copy:Destroy()
		end)
	end)
end

Remotes.Toast.OnClientEvent:Connect(toast)

----------------------------------------------------------------------
-- Play screen wiring
----------------------------------------------------------------------

local PlayBody = playPanel:FindFirstChild("Body")
local Missions = PlayBody:FindFirstChild("Missions")
local PlayRight = PlayBody:FindFirstChild("Right")

local selectedMission = Config.Missions[1].id
local selectedDifficulty = Config.Difficulties[1]
local lobbyType = "Public"

local function refreshMissionHighlights()
	for _, row in ipairs(Missions:GetChildren()) do
		if row:GetAttribute("HMMission") then
			local on = row:GetAttribute("HMMission") == selectedMission
			row.BackgroundTransparency = on and 0.05 or 0.2
			local strokeChild = row:FindFirstChildOfClass("UIStroke")
			if strokeChild then
				strokeChild.Transparency = on and 0.15 or 0.55
				strokeChild.Thickness = on and 1.8 or 1
			end
		end
	end
end

local function refreshDifficultyHighlights()
	for _, row in ipairs(PlayRight:GetChildren()) do
		if row:GetAttribute("HMDifficulty") then
			local on = row:GetAttribute("HMDifficulty") == selectedDifficulty
			row.BackgroundTransparency = on and 0.05 or 0.2
			local strokeChild = row:FindFirstChildOfClass("UIStroke")
			if strokeChild then
				strokeChild.Transparency = on and 0.15 or 0.6
			end
		end
	end
end

local function refreshLobbyHighlights()
	local row = PlayRight:FindFirstChild("LobbyRow")
	if not row then
		return
	end
	for _, b in ipairs(row:GetChildren()) do
		if b:GetAttribute("HMLobby") then
			local on = b:GetAttribute("HMLobby") == lobbyType
			b.BackgroundTransparency = on and 0.05 or 0.2
			local strokeChild = b:FindFirstChildOfClass("UIStroke")
			if strokeChild then
				strokeChild.Transparency = on and 0.15 or 0.55
			end
		end
	end
end

for _, row in ipairs(Missions:GetChildren()) do
	if row:IsA("GuiButton") and row:GetAttribute("HMMission") then
		row.MouseButton1Click:Connect(function()
			selectedMission = row:GetAttribute("HMMission")
			refreshMissionHighlights()
			Remotes.SetMission:FireServer(selectedMission)
		end)
	end
end

for _, row in ipairs(PlayRight:GetChildren()) do
	if row:IsA("GuiButton") and row:GetAttribute("HMDifficulty") then
		row.MouseButton1Click:Connect(function()
			selectedDifficulty = row:GetAttribute("HMDifficulty")
			refreshDifficultyHighlights()
			Remotes.SetDifficulty:FireServer(selectedDifficulty)
		end)
	end
end

local LobbyRow = PlayRight:FindFirstChild("LobbyRow")
if LobbyRow then
	for _, b in ipairs(LobbyRow:GetChildren()) do
		if b:IsA("GuiButton") and b:GetAttribute("HMLobby") then
			b.MouseButton1Click:Connect(function()
				lobbyType = b:GetAttribute("HMLobby")
				refreshLobbyHighlights()
				Remotes.SetLobbyType:FireServer(lobbyType == "Public")
			end)
		end
	end
end

local function showLoading(status, hint)
	if not loadingScreen then
		return
	end
	loadingScreen.Visible = true
	loadingScreen.BackgroundTransparency = 1
	tween(loadingScreen, 0.3, { BackgroundTransparency = 0 })
	local s = loadingScreen:FindFirstChild("Status")
	local h = loadingScreen:FindFirstChild("Hint")
	if s and status then
		s.Text = status
	end
	if h and hint then
		h.Text = hint
	end
end

local function hideLoading()
	if not loadingScreen then
		return
	end
	tween(loadingScreen, 0.3, { BackgroundTransparency = 1 })
	task.delay(0.32, function()
		loadingScreen.Visible = false
	end)
end

for _, b in ipairs(PlayRight:GetDescendants()) do
	if b:IsA("TextButton") and b:GetAttribute("HMAction") == "Matchmake" then
		b.MouseButton1Click:Connect(function()
			showLoading("MATCHMAKING...", "// hunting  for  similar  tapes")
			task.spawn(function()
				local ok, codeOrErr =
					Remotes.StartMatchmake:InvokeServer(selectedMission, selectedDifficulty, lobbyType == "Public")
				task.wait(0.6)
				hideLoading()
				if ok then
					toast("Matchmaking", "Party: " .. tostring(codeOrErr))
				else
					toast("Matchmaking", tostring(codeOrErr))
				end
			end)
		end)
	end
end

refreshMissionHighlights()
refreshDifficultyHighlights()
refreshLobbyHighlights()

----------------------------------------------------------------------
-- Party screen wiring
----------------------------------------------------------------------

local PartyBody = partyPanel:FindFirstChild("Body")
local PartyLeft = PartyBody:FindFirstChild("Left")
local PartyRight = PartyBody:FindFirstChild("Right")
local CodeFrame = PartyLeft:FindFirstChild("PartyCodeFrame")
local CodeValue = CodeFrame and CodeFrame:FindFirstChild("Code")
local MembersBox = PartyRight:FindFirstChild("Members")
local MembersTitle = MembersBox:FindFirstChild("MembersTitle")
local MembersList = MembersBox:FindFirstChild("MembersList")
local ChatBox = PartyRight:FindFirstChild("Chat")
local ChatLog = ChatBox and ChatBox:FindFirstChild("Log")
local ChatInputRow = ChatBox and ChatBox:FindFirstChild("InputRow")
local ChatInput = ChatInputRow and ChatInputRow:FindFirstChild("Input")
local JoinInput = PartyLeft:FindFirstChild("JoinRow"):FindFirstChild("JoinInput")

local currentParty = nil
local myReady = false

local function refreshLeaderOnlyButtons(amLeader)
	for _, b in ipairs(partyPanel:GetDescendants()) do
		if b:IsA("GuiButton") and b:GetAttribute("HMLeaderOnly") then
			b.Visible = amLeader
		end
	end
end

local function clearMembersList()
	for _, c in ipairs(MembersList:GetChildren()) do
		if c:IsA("Frame") and not c:GetAttribute("HMPartyMemberTemplate") then
			c:Destroy()
		end
	end
end

local function addMemberRow(member, layoutOrder)
	local row = memberTemplate:Clone()
	row.Name = "M_" .. tostring(member.userId)
	row.LayoutOrder = layoutOrder
	row.Visible = true
	row:SetAttribute("HMPartyMemberTemplate", nil)
	local nameLbl = row:FindFirstChild("Name")
	local statusLbl = row:FindFirstChild("Status")
	local leaderBadge = row:FindFirstChild("LeaderBadge")
	local readyDot = row:FindFirstChild("Ready")
	if nameLbl then
		nameLbl.Text = member.displayName
	end
	if statusLbl then
		statusLbl.Text = member.ready and "// READY" or "// NOT READY"
		statusLbl.TextColor3 = member.ready
			and Color3.fromRGB(120, 255, 170)
			or Color3.fromRGB(150, 138, 180)
	end
	if leaderBadge then
		leaderBadge.Visible = member.isLeader
	end
	if readyDot then
		readyDot.BackgroundColor3 = member.ready
			and Color3.fromRGB(120, 255, 170)
			or Color3.fromRGB(255, 80, 110)
	end
	row.Parent = MembersList
	return row
end

local function refreshChatLog()
	if not ChatLog then
		return
	end
	for _, c in ipairs(ChatLog:GetChildren()) do
		if c:IsA("TextLabel") then
			c:Destroy()
		end
	end
	if not currentParty then
		return
	end
	for i, entry in ipairs(currentParty.chat) do
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1, 0, 0, 18)
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.RobotoMono
		lbl.Text = string.format("[%s] %s", entry.name, entry.text)
		lbl.TextColor3 = Color3.fromRGB(232, 224, 255)
		lbl.TextSize = 13
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.LayoutOrder = i
		lbl.Parent = ChatLog
	end
end

local function refreshParty(state)
	currentParty = state
	if not state then
		if CodeValue then
			CodeValue.Text = "—  —  —  —"
		end
		clearMembersList()
		if MembersTitle then
			MembersTitle.Text = "// PARTY  MEMBERS  (0/" .. tostring(Config.MaxPartySize) .. ")"
		end
		refreshLeaderOnlyButtons(false)
		refreshChatLog()
		return
	end
	if CodeValue then
		CodeValue.Text = state.code:gsub("(.)(.)(.)(.)", "%1  %2  %3  %4")
	end
	clearMembersList()
	for i, m in ipairs(state.members) do
		addMemberRow(m, i)
	end
	if MembersTitle then
		MembersTitle.Text = string.format(
			"// PARTY  MEMBERS  (%d/%d)",
			#state.members,
			state.maxSize
		)
	end
	local amLeader = state.leaderId == LocalPlayer.UserId
	refreshLeaderOnlyButtons(amLeader)
	refreshChatLog()
end

Remotes.PartyState.OnClientEvent:Connect(function(stateOrFalse)
	if stateOrFalse == false then
		refreshParty(nil)
	else
		refreshParty(stateOrFalse)
	end
end)

local function partyAction(action)
	if action == "CreateParty" then
		task.spawn(function()
			local ok, codeOrErr = Remotes.CreateParty:InvokeServer()
			if ok then
				toast("Party", "Created party " .. tostring(codeOrErr))
			else
				toast("Party", tostring(codeOrErr))
			end
		end)
	elseif action == "JoinParty" then
		local code = (JoinInput and JoinInput.Text or ""):gsub("%s+", ""):upper()
		if #code < 4 then
			toast("Party", "Enter a valid code.")
			return
		end
		task.spawn(function()
			local ok, msg = Remotes.JoinParty:InvokeServer(code)
			if ok then
				toast("Party", "Joined " .. tostring(msg))
			else
				toast("Party", tostring(msg))
			end
		end)
	elseif action == "LeaveParty" then
		Remotes.LeaveParty:FireServer()
	elseif action == "ToggleReady" then
		myReady = not myReady
		Remotes.SetReady:FireServer(myReady)
	elseif action == "StartGame" then
		Remotes.StartGame:FireServer()
		showLoading("STARTING...", "// reserving  server")
	elseif action == "InviteFriend" then
		toast("Invite", "Open the Roblox social menu to invite friends.")
	elseif action == "SendChat" then
		if not ChatInput then
			return
		end
		local text = ChatInput.Text
		if #text > 0 then
			Remotes.SendChat:FireServer(text)
			ChatInput.Text = ""
		end
	end
end

for _, b in ipairs(partyPanel:GetDescendants()) do
	if b:IsA("TextButton") and b:GetAttribute("HMAction") then
		b.MouseButton1Click:Connect(function()
			partyAction(b:GetAttribute("HMAction"))
		end)
	end
end

if ChatInput then
	ChatInput.FocusLost:Connect(function(enterPressed)
		if enterPressed and #ChatInput.Text > 0 then
			Remotes.SendChat:FireServer(ChatInput.Text)
			ChatInput.Text = ""
		end
	end)
end

----------------------------------------------------------------------
-- Invite popup
----------------------------------------------------------------------

Remotes.InviteReceived.OnClientEvent:Connect(function(info)
	if not invitePopup then
		return
	end
	invitePopup.Visible = true
	invitePopup.BackgroundTransparency = 1
	tween(invitePopup, 0.25, { BackgroundTransparency = 0.55 })
	local card = invitePopup:FindFirstChild("Card")
	if card then
		card.Position = UDim2.fromScale(0.5, 0.55)
		tween(card, 0.3, { Position = UDim2.fromScale(0.5, 0.5) })
		local fromLine = card:FindFirstChild("From")
		local codeLine = card:FindFirstChild("Code")
		if fromLine then
			fromLine.Text = "From  " .. info.fromName
		end
		if codeLine then
			codeLine.Text = info.code:gsub("(.)(.)(.)(.)", "%1  %2  %3  %4")
		end
	end
end)

if invitePopup then
	for _, b in ipairs(invitePopup:GetDescendants()) do
		if b:IsA("TextButton") and b:GetAttribute("HMAction") then
			b.MouseButton1Click:Connect(function()
				local action = b:GetAttribute("HMAction")
				if action == "AcceptInvite" then
					Remotes.AcceptInvite:FireServer()
				elseif action == "DeclineInvite" then
					Remotes.DeclineInvite:FireServer()
				end
				invitePopup.Visible = false
			end)
		end
	end
end
]==]

CLIENT_SOURCE = CLIENT_SOURCE
	.. [==[

----------------------------------------------------------------------
-- Menu camera + parallax / sway
----------------------------------------------------------------------

local menuScene = Workspace:FindFirstChild("HorrorMenuScene")
local cameraAnchor = menuScene and menuScene:FindFirstChild("CameraPosition")
local menuOn = true
local swayPhase = 0

local function setMenuCamera()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	if menuScene and cameraAnchor then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CFrame = cameraAnchor.CFrame
	end
end

setMenuCamera()

RunService.RenderStepped:Connect(function(dt)
	if not menuOn then
		return
	end
	swayPhase += dt
	local cam = Workspace.CurrentCamera
	if not cam or not cameraAnchor then
		return
	end
	-- Slow cinematic sway + tiny parallax from mouse position.
	local viewport = cam.ViewportSize
	local m = UserInputService:GetMouseLocation()
	local nx = (m.X / viewport.X) - 0.5
	local ny = (m.Y / viewport.Y) - 0.5
	local target = cameraAnchor.CFrame
		* CFrame.Angles(
			math.rad(math.sin(swayPhase * 0.5) * 0.7 + ny * -2.5),
			math.rad(math.cos(swayPhase * 0.4) * 0.7 + nx * -2.5),
			math.rad(math.sin(swayPhase * 0.3) * 0.4)
		)
		* CFrame.new(nx * 0.6, -ny * 0.4, math.sin(swayPhase * 0.6) * 0.15)
	cam.CFrame = cam.CFrame:Lerp(target, math.clamp(dt * 4, 0, 1))
end)

----------------------------------------------------------------------
-- Dust particles drifting up the screen
----------------------------------------------------------------------

local dustContainer = Gui:FindFirstChild("Dust")
local dustTweens = {}

local function startDustFor(dust)
	if not dust then
		return
	end
	local function loop()
		local startX = math.random() * 1.05 - 0.025
		local startY = 1 + math.random() * 0.1
		local endX = startX + (math.random() - 0.5) * 0.05
		local endY = -0.05 - math.random() * 0.1
		dust.Position = UDim2.fromScale(startX, startY)
		local time = 14 + math.random() * 18
		local t = tween(dust, time, { Position = UDim2.fromScale(endX, endY) }, Enum.EasingStyle.Linear)
		dustTweens[dust] = t
		t.Completed:Connect(function()
			loop()
		end)
	end
	task.delay(math.random() * 8, loop)
end

if dustContainer then
	for _, d in ipairs(dustContainer:GetChildren()) do
		if d:GetAttribute("HMDust") then
			startDustFor(d)
		end
	end
end

----------------------------------------------------------------------
-- VHS flicker (tiny random pulses on the magenta overlay)
----------------------------------------------------------------------

local flicker = Gui:FindFirstChild("VHSOverlay") and Gui.VHSOverlay:FindFirstChild("Flicker")
if flicker then
	task.spawn(function()
		while flicker.Parent do
			task.wait(0.05 + math.random() * 0.35)
			if math.random() < 0.18 then
				flicker.BackgroundTransparency = 0.85 + math.random() * 0.12
				task.wait(0.04 + math.random() * 0.08)
				flicker.BackgroundTransparency = 0.99
			end
		end
	end)
end

local sceneStandIn = Gui:FindFirstChild("Backdrop")
sceneStandIn = sceneStandIn and sceneStandIn:FindFirstChild("SceneStandIn") or nil
if sceneStandIn then
	-- Slow gradient rotation to feel "alive".
	task.spawn(function()
		local grad = sceneStandIn:FindFirstChildOfClass("UIGradient")
		if not grad then
			return
		end
		while sceneStandIn.Parent do
			local t = tween(grad, 6, { Rotation = grad.Rotation + 15 }, Enum.EasingStyle.Sine)
			t.Completed:Wait()
		end
	end)
end

----------------------------------------------------------------------
-- Loading spinner rotation
----------------------------------------------------------------------

local spinner = findByAttribute(Gui, "HMSpinner")
if spinner then
	task.spawn(function()
		while spinner.Parent do
			local t = tween(spinner, 1.2, { Rotation = spinner.Rotation + 360 }, Enum.EasingStyle.Linear)
			t.Completed:Wait()
		end
	end)
end

----------------------------------------------------------------------
-- Animated logo reveal
----------------------------------------------------------------------

local logo = findByAttribute(Gui, "HMLogoReveal")
if logo then
	logo.TextTransparency = 1
	local stroke = logo:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 1
	end
	task.delay(0.3, function()
		tween(logo, 1.2, { TextTransparency = 0 }, Enum.EasingStyle.Quint)
		if stroke then
			tween(stroke, 1.2, { Transparency = 0.55 }, Enum.EasingStyle.Quint)
		end
	end)
end

----------------------------------------------------------------------
-- Ambient music + static loop
----------------------------------------------------------------------

local music = Sounds:FindFirstChild("music")
local staticAmb = Sounds:FindFirstChild("staticAmbience")
if music then
	music.Volume = 0
	music:Play()
	tween(music, 4, { Volume = 0.35 }, Enum.EasingStyle.Quad)
end
if staticAmb then
	staticAmb.Volume = 0
	staticAmb:Play()
	tween(staticAmb, 4, { Volume = 0.18 }, Enum.EasingStyle.Quad)
end

----------------------------------------------------------------------
-- Auto-scale: shrink the menu down on small viewports.
----------------------------------------------------------------------

local autoScale = Gui:FindFirstChild("AutoScale")

local function recomputeScale()
	if not autoScale then
		return
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local size = cam.ViewportSize
	local target = math.clamp(math.min(size.X / 1280, size.Y / 720), 0.55, 1.4)
	autoScale.Scale = target
end

recomputeScale()
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local cam = Workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(recomputeScale)
		recomputeScale()
	end
end)

if Workspace.CurrentCamera then
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(recomputeScale)
end

----------------------------------------------------------------------
-- Menu blur on entry / out
----------------------------------------------------------------------

local menuBlur = Lighting:FindFirstChild("HMFx_MenuBlur")
if menuBlur then
	menuBlur.Size = 0
	tween(menuBlur, 1.4, { Size = 14 }, Enum.EasingStyle.Quad)
end

----------------------------------------------------------------------
-- Initial application of settings + fade-in
----------------------------------------------------------------------

applySettingsToUI()
applySettingsToWorld()
mainMenu.Visible = true

fader.Visible = true
fader.BackgroundTransparency = 0
tween(fader, 0.6, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
task.delay(0.65, function()
	fader.Visible = false
end)

print("[HorrorMenu] client ready")
]==]

------------------------------------------------------------------------------
-- Install functions
------------------------------------------------------------------------------

local REMOTE_EVENTS = {
	"LeaveParty",
	"SetReady",
	"KickMember",
	"TransferLeader",
	"StartGame",
	"SendChat",
	"SetMission",
	"SetDifficulty",
	"SetLobbyType",
	"InvitePlayer",
	"InviteReceived",
	"AcceptInvite",
	"DeclineInvite",
	"SaveSettings",
	"SettingsLoaded",
	"PartyState",
	"Toast",
}

local REMOTE_FUNCTIONS = {
	"CreateParty",
	"JoinParty",
	"StartMatchmake",
}

local function ensurePackage()
	local existing = ReplicatedStorage:FindFirstChild("HorrorMenu")
	if existing then
		existing:Destroy()
	end
	local pkg = Instance.new("Folder")
	pkg.Name = "HorrorMenu"
	pkg.Parent = ReplicatedStorage

	local cfg = Instance.new("ModuleScript")
	cfg.Name = "MenuConfig"
	cfg.Source = MENU_CONFIG_SOURCE
	cfg.Parent = pkg

	local remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = pkg
	for _, name in ipairs(REMOTE_EVENTS) do
		local r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotes
	end
	for _, name in ipairs(REMOTE_FUNCTIONS) do
		local r = Instance.new("RemoteFunction")
		r.Name = name
		r.Parent = remotes
	end
end

local function installServerScript()
	local existing = ServerScriptService:FindFirstChild("HorrorMenuServer")
	if existing then
		existing:Destroy()
	end
	local s = Instance.new("Script")
	s.Name = "HorrorMenuServer"
	s.Source = SERVER_SOURCE
	s.Parent = ServerScriptService
end

local function installClientScript()
	local sps = StarterPlayer:FindFirstChild("StarterPlayerScripts")
	if not sps then
		warn("[HorrorMenu] StarterPlayer.StarterPlayerScripts is missing")
		return
	end
	local existing = sps:FindFirstChild("HorrorMenuClient")
	if existing then
		existing:Destroy()
	end
	local s = Instance.new("LocalScript")
	s.Name = "HorrorMenuClient"
	s.Source = CLIENT_SOURCE
	s.Parent = sps
end

local function installGui()
	local existing = StarterGui:FindFirstChild("HorrorMenuGui")
	if existing then
		existing:Destroy()
	end
	local gui = buildGui()
	gui.Parent = StarterGui
end

local function installScene()
	buildScene()
end

local function installLighting()
	buildLightingEffects()
end

------------------------------------------------------------------------------
-- Plugin orchestration
------------------------------------------------------------------------------

local function installAll()
	local recording = ChangeHistoryService:TryBeginRecording("Install Horror Menu")
	local ok, err = pcall(function()
		ensurePackage()
		installServerScript()
		installClientScript()
		installGui()
		installScene()
		installLighting()
	end)
	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		warn("[HorrorMenu] install failed:", err)
		return
	end
	print(
		"[HorrorMenu] installed. Press Play to see the menu."
			.. "  Edit ReplicatedStorage.HorrorMenu.MenuConfig.GamePlaceId"
			.. " to point matchmaking at your game place."
	)
end

local function rebuildUiOnly()
	local recording = ChangeHistoryService:TryBeginRecording("Rebuild Horror Menu UI")
	local ok, err = pcall(function()
		installGui()
		installLighting()
	end)
	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		warn("[HorrorMenu] UI rebuild failed:", err)
		return
	end
	print("[HorrorMenu] UI rebuilt.")
end

local function rebuildSceneOnly()
	local recording = ChangeHistoryService:TryBeginRecording("Rebuild Horror Menu Scene")
	local ok, err = pcall(function()
		installScene()
		installLighting()
	end)
	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		warn("[HorrorMenu] scene rebuild failed:", err)
		return
	end
	print("[HorrorMenu] scene rebuilt.")
end

local toolbar = plugin:CreateToolbar("Horror Menu")

local installButton = toolbar:CreateButton(
	"Install / Rebuild",
	"Build the neon-purple horror main menu, party system, settings + credits",
	"rbxasset://textures/AnimationEditor/icon_axes.png"
)
installButton.ClickableWhenViewportHidden = true
installButton.Click:Connect(installAll)

local uiButton = toolbar:CreateButton(
	"Rebuild UI Only",
	"Re-generate the StarterGui menu hierarchy (keeps scripts + remotes)",
	"rbxasset://textures/AnimationEditor/icon_keyframe.png"
)
uiButton.ClickableWhenViewportHidden = true
uiButton.Click:Connect(rebuildUiOnly)

local sceneButton = toolbar:CreateButton(
	"Rebuild Scene Only",
	"Re-generate the Workspace.HorrorMenuScene + Lighting effects",
	"rbxasset://textures/AnimationEditor/icon_keyframe.png"
)
sceneButton.ClickableWhenViewportHidden = true
sceneButton.Click:Connect(rebuildSceneOnly)
