--!nocheck
--[[
	FazbearSecurityPlugin.server.lua
	================================
	Roblox Studio plugin: builds the Freddy Fazbear's Security map and installs
	the multiplayer camera tablet + door system into your place.

	Install:
		1. In Studio, right-click this script in the explorer (after pasting
		   it into a Script in `Workspace`) and pick "Save as Local Plugin",
		   OR drop this file in your local Plugins folder:
		     Windows:  %LOCALAPPDATA%\Roblox\Plugins
		     macOS:    ~/Documents/Roblox/Plugins
		2. Restart Studio.
		3. Click the "Fazbear Security" toolbar -> "Install / Rebuild".

	What it installs:
		Workspace.FazbearMap                         rooms, doors, vents, cams
		ReplicatedStorage.FazbearSecurity            RemoteEvents folder
		ServerScriptService.FazbearSecurityServer    door + camera server logic
		StarterPlayer.StarterPlayerScripts.FazbearTabletClient
		                                             per-client tablet UI

	"Install / Rebuild" wipes the existing FazbearMap / FazbearSecurity*
	instances and rebuilds them, so it's safe to click repeatedly while you
	iterate on settings. Anything you've put elsewhere in the place is left
	alone.
]]

if not plugin then
	return
end

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

------------------------------------------------------------------------------
-- Tags
------------------------------------------------------------------------------

local TAG_ROOM = "FazbearRoom"
local TAG_DOOR = "FazbearDoor"
local TAG_LOCKABLE = "FazbearLockableDoor"
local TAG_CAMERA = "FazbearCamera"
local TAG_VENT = "FazbearVent"

------------------------------------------------------------------------------
-- Map config -- single source of truth for the floor plan
------------------------------------------------------------------------------

local ROOM_SIZE = 40 -- studs (square rooms on a 3x3 grid)
local ROOM_HEIGHT = 14 -- wall + ceiling height
local WALL_THICK = 1
local FLOOR_THICK = 1
local DOOR_WIDTH = 8
local DOOR_HEIGHT = 9
local VENT_SIZE = 4

-- col: -1=W, 0=M, 1=E.  row: -1=N, 0=M, 1=S.  Centre of room = (col*40, row*40).
local ROOMS = {
	BackRoom = {
		col = -1,
		row = -1,
		name = "Back Room",
		camera = "CAM 04",
		floor = Color3.fromRGB(46, 38, 36),
		wall = Color3.fromRGB(38, 28, 26),
		theme = "office",
	},
	ShowStage = {
		col = 0,
		row = -1,
		name = "Show Stage",
		camera = "CAM 02",
		floor = Color3.fromRGB(60, 36, 40),
		wall = Color3.fromRGB(42, 22, 28),
		theme = "stage",
	},
	Arcade = {
		col = 1,
		row = -1,
		name = "Arcade",
		camera = "CAM 05",
		floor = Color3.fromRGB(22, 22, 46),
		wall = Color3.fromRGB(18, 16, 36),
		theme = "arcade",
	},
	Kitchen = {
		col = -1,
		row = 0,
		name = "Kitchen",
		camera = "CAM 03",
		audioOnly = true,
		floor = Color3.fromRGB(64, 64, 70),
		wall = Color3.fromRGB(50, 50, 56),
		theme = "kitchen",
	},
	DiningArea = {
		col = 0,
		row = 0,
		name = "Dining Area",
		camera = "CAM 01",
		floor = Color3.fromRGB(56, 44, 38),
		wall = Color3.fromRGB(42, 32, 28),
		theme = "dining",
	},
	PartyRoom = {
		col = 1,
		row = 0,
		name = "Party Room",
		camera = "CAM 06",
		floor = Color3.fromRGB(50, 38, 36),
		wall = Color3.fromRGB(38, 26, 26),
		theme = "party",
	},
	WestHall = {
		col = -1,
		row = 1,
		name = "West Hall",
		camera = "CAM 07",
		floor = Color3.fromRGB(38, 30, 28),
		wall = Color3.fromRGB(28, 22, 22),
		theme = "hall",
	},
	SecurityOffice = {
		col = 0,
		row = 1,
		name = "Security Office",
		camera = nil,
		floor = Color3.fromRGB(36, 30, 30),
		wall = Color3.fromRGB(28, 22, 22),
		theme = "office",
	},
	EastHall = {
		col = 1,
		row = 1,
		name = "East Hall",
		camera = "CAM 08",
		floor = Color3.fromRGB(38, 30, 28),
		wall = Color3.fromRGB(28, 22, 22),
		theme = "hall",
	},
}

-- Passages between adjacent rooms.
-- type: "door"     -- blue, click-to-toggle
--       "lockable" -- red, only togglable from the tablet UI
--       "vent"     -- green grate, decorative (animatronic-only in lore)
local PASSAGES = {
	{ a = "BackRoom", b = "ShowStage", type = "door" },
	{ a = "ShowStage", b = "Arcade", type = "door" },
	{ a = "ShowStage", b = "DiningArea", type = "door" },
	{ a = "Kitchen", b = "DiningArea", type = "door" },
	{ a = "DiningArea", b = "PartyRoom", type = "door" },
	{ a = "DiningArea", b = "SecurityOffice", type = "door" },
	{ a = "WestHall", b = "SecurityOffice", type = "lockable", lockId = "West" },
	{ a = "SecurityOffice", b = "EastHall", type = "lockable", lockId = "East" },
	{ a = "Kitchen", b = "WestHall", type = "vent" },
	{ a = "PartyRoom", b = "EastHall", type = "vent" },
}

------------------------------------------------------------------------------
-- Geometry helpers
------------------------------------------------------------------------------

local function roomCentre(room)
	return Vector3.new(room.col * ROOM_SIZE, 0, room.row * ROOM_SIZE)
end

local function makePart(name, size, cf, props, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = true
	p.Size = size
	p.CFrame = cf
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.Concrete
	if props then
		for k, v in pairs(props) do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

-- Returns the four ordered "corner" room ids around a room (N, S, W, E).
local function neighbourId(roomId, dx, dz)
	local r = ROOMS[roomId]
	for id, other in pairs(ROOMS) do
		if other.col == r.col + dx and other.row == r.row + dz then
			return id
		end
	end
	return nil
end

-- Look up a passage between two rooms (order-independent).
local function findPassage(roomA, roomB)
	for _, p in ipairs(PASSAGES) do
		if (p.a == roomA and p.b == roomB) or (p.a == roomB and p.b == roomA) then
			return p
		end
	end
	return nil
end

------------------------------------------------------------------------------
-- Build a room: floor, ceiling, four walls (with gaps for passages).
------------------------------------------------------------------------------

local function buildWallSegment(parent, name, x1, x2, z1, z2, height, colour)
	local cx = (x1 + x2) / 2
	local cz = (z1 + z2) / 2
	local sx = math.abs(x2 - x1)
	local sz = math.abs(z2 - z1)
	if sx <= 0.01 or sz <= 0.01 then
		return nil
	end
	local part = makePart(name, Vector3.new(sx, height, sz), CFrame.new(cx, height / 2, cz), {
		Color = colour,
		Material = Enum.Material.Concrete,
	}, parent)
	return part
end

local function buildSide(parent, room, side, gap, colour)
	-- side = "N" (north, -z), "S" (south, +z), "W" (west, -x), "E" (east, +x)
	local centre = roomCentre(room)
	local half = ROOM_SIZE / 2
	local h = ROOM_HEIGHT
	local x1, x2, z1, z2
	if side == "N" then
		x1, x2 = centre.X - half, centre.X + half
		z1, z2 = centre.Z - half, centre.Z - half + WALL_THICK
	elseif side == "S" then
		x1, x2 = centre.X - half, centre.X + half
		z1, z2 = centre.Z + half - WALL_THICK, centre.Z + half
	elseif side == "W" then
		x1, x2 = centre.X - half, centre.X - half + WALL_THICK
		z1, z2 = centre.Z - half, centre.Z + half
	elseif side == "E" then
		x1, x2 = centre.X + half - WALL_THICK, centre.X + half
		z1, z2 = centre.Z - half, centre.Z + half
	else
		return
	end

	if not gap then
		buildWallSegment(parent, "Wall_" .. side, x1, x2, z1, z2, h, colour)
		return
	end

	-- Gap is horizontal (along x) for N/S walls, vertical (along z) for W/E walls.
	if side == "N" or side == "S" then
		local gapMid = centre.X
		local gapHalf = gap.width / 2
		-- left/right wall segments
		buildWallSegment(parent, "Wall_" .. side .. "_L", x1, gapMid - gapHalf, z1, z2, h, colour)
		buildWallSegment(parent, "Wall_" .. side .. "_R", gapMid + gapHalf, x2, z1, z2, h, colour)
		-- lintel ABOVE the doorway
		local lintelHeight = h - DOOR_HEIGHT
		local lintelCFrame = CFrame.new(gapMid, DOOR_HEIGHT + lintelHeight / 2, (z1 + z2) / 2)
		local lintelSize = Vector3.new(gap.width, lintelHeight, math.abs(z2 - z1))
		makePart("Lintel_" .. side, lintelSize, lintelCFrame, {
			Color = colour,
			Material = Enum.Material.Concrete,
		}, parent)
		-- Door slot: centre it on the room boundary (the boundary is the room
		-- edge in the +z direction for "S", -z for "N").
		local boundaryZ = if side == "S" then centre.Z + half else centre.Z - half
		gap.cframe = CFrame.new(gapMid, DOOR_HEIGHT / 2, boundaryZ)
		gap.size = Vector3.new(gap.width, DOOR_HEIGHT, WALL_THICK + 0.2)
	else
		local gapMid = centre.Z
		local gapHalf = gap.width / 2
		buildWallSegment(parent, "Wall_" .. side .. "_T", x1, x2, z1, gapMid - gapHalf, h, colour)
		buildWallSegment(parent, "Wall_" .. side .. "_B", x1, x2, gapMid + gapHalf, z2, h, colour)
		local lintelHeight = h - DOOR_HEIGHT
		local lintelCFrame = CFrame.new((x1 + x2) / 2, DOOR_HEIGHT + lintelHeight / 2, gapMid)
		local lintelSize = Vector3.new(math.abs(x2 - x1), lintelHeight, gap.width)
		makePart("Lintel_" .. side, lintelSize, lintelCFrame, {
			Color = colour,
			Material = Enum.Material.Concrete,
		}, parent)
		local boundaryX = if side == "E" then centre.X + half else centre.X - half
		gap.cframe = CFrame.new(boundaryX, DOOR_HEIGHT / 2, gapMid)
		gap.size = Vector3.new(WALL_THICK + 0.2, DOOR_HEIGHT, gap.width)
	end
end

------------------------------------------------------------------------------
-- Door / vent props
------------------------------------------------------------------------------

local function spawnDoor(parent, passage, cf, size)
	-- For door slides we want the closed-CFrame to be at `cf` and the open-CFrame
	-- to be the same translated down into the floor.
	local colour = if passage.type == "lockable"
		then Color3.fromRGB(180, 40, 50)
		else Color3.fromRGB(60, 110, 200)
	local part = makePart(passage.type == "lockable" and "LockableDoor" or "Door", size, cf, {
		Color = colour,
		Material = Enum.Material.Metal,
		Reflectance = 0.05,
	}, parent)
	part:SetAttribute("ClosedCFrame", cf)
	part:SetAttribute("OpenCFrame", cf - Vector3.new(0, DOOR_HEIGHT + 1, 0))
	part:SetAttribute("Open", true)
	if passage.type == "lockable" then
		part:SetAttribute("LockId", passage.lockId)
		CollectionService:AddTag(part, TAG_LOCKABLE)
	else
		CollectionService:AddTag(part, TAG_DOOR)
	end
	-- start open
	part.CFrame = part:GetAttribute("OpenCFrame")
	part.CanCollide = false
	part.Transparency = 0.85
	return part
end

local function spawnVent(parent, room, side)
	-- Place a small green grate on the floor near the appropriate wall.
	local centre = roomCentre(room)
	local half = ROOM_SIZE / 2
	local offset = half - 4
	local px, pz = centre.X, centre.Z
	if side == "N" then
		pz = centre.Z - offset
	elseif side == "S" then
		pz = centre.Z + offset
	elseif side == "W" then
		px = centre.X - offset
	elseif side == "E" then
		px = centre.X + offset
	end
	local grate = makePart(
		"VentGrate",
		Vector3.new(VENT_SIZE, 0.2, VENT_SIZE),
		CFrame.new(px, FLOOR_THICK + 0.1, pz),
		{
			Color = Color3.fromRGB(120, 200, 130),
			Material = Enum.Material.DiamondPlate,
		},
		parent
	)
	CollectionService:AddTag(grate, TAG_VENT)
	return grate
end

------------------------------------------------------------------------------
-- Build the entire map
------------------------------------------------------------------------------

local function buildRoom(parent, id, room)
	local centre = roomCentre(room)

	local roomModel = Instance.new("Model")
	roomModel.Name = id
	roomModel.Parent = parent
	CollectionService:AddTag(roomModel, TAG_ROOM)
	roomModel:SetAttribute("DisplayName", room.name)
	roomModel:SetAttribute("CameraId", room.camera)
	roomModel:SetAttribute("AudioOnly", room.audioOnly == true)

	-- Floor
	makePart(
		"Floor",
		Vector3.new(ROOM_SIZE, FLOOR_THICK, ROOM_SIZE),
		CFrame.new(centre.X, FLOOR_THICK / 2, centre.Z),
		{
			Color = room.floor,
			Material = Enum.Material.WoodPlanks,
		},
		roomModel
	)

	-- Ceiling
	makePart(
		"Ceiling",
		Vector3.new(ROOM_SIZE, FLOOR_THICK, ROOM_SIZE),
		CFrame.new(centre.X, ROOM_HEIGHT + FLOOR_THICK / 2, centre.Z),
		{
			Color = Color3.fromRGB(20, 16, 14),
			Material = Enum.Material.Concrete,
		},
		roomModel
	)

	-- Determine gap per side based on adjacent passages.
	local sides = {
		N = { dx = 0, dz = -1 },
		S = { dx = 0, dz = 1 },
		W = { dx = -1, dz = 0 },
		E = { dx = 1, dz = 0 },
	}
	local doorSpawns = {}
	for sideName, sideDelta in pairs(sides) do
		local nId = neighbourId(id, sideDelta.dx, sideDelta.dz)
		local gap = nil
		if nId then
			local p = findPassage(id, nId)
			if p and (p.type == "door" or p.type == "lockable") then
				gap = { width = DOOR_WIDTH, passage = p, side = sideName, neighbourId = nId }
			end
		end
		buildSide(roomModel, room, sideName, gap, room.wall)
		if gap and gap.cframe then
			-- Build the door part only once -- the wall on the neighbour's side
			-- will have the same opening, so we only spawn the door for the
			-- room whose id comes first alphabetically. (Deterministic.)
			if id < nId then
				table.insert(doorSpawns, gap)
			end
		end
	end

	for _, gap in ipairs(doorSpawns) do
		local cf = gap.cframe
		-- Door size: 1 stud thick along the wall normal, DOOR_WIDTH wide, DOOR_HEIGHT tall.
		local size
		if gap.side == "N" or gap.side == "S" then
			size = Vector3.new(DOOR_WIDTH, DOOR_HEIGHT, WALL_THICK + 0.2)
		else
			size = Vector3.new(WALL_THICK + 0.2, DOOR_HEIGHT, DOOR_WIDTH)
		end
		spawnDoor(roomModel, gap.passage, cf, size)
	end

	-- Vent grates: spawn one in this room on the side toward the venting partner,
	-- only if the partner is an adjacent room with a "vent" passage.
	for sideName, sideDelta in pairs(sides) do
		local nId = neighbourId(id, sideDelta.dx, sideDelta.dz)
		if nId then
			local p = findPassage(id, nId)
			if p and p.type == "vent" then
				spawnVent(roomModel, room, sideName)
			end
		end
	end

	-- Camera marker: small neon part hung from the ceiling looking down-mid.
	if room.camera then
		local camPart = makePart(
			"CameraMarker",
			Vector3.new(1.6, 1.2, 2.6),
			CFrame.new(centre.X, ROOM_HEIGHT - 1.2, centre.Z) * CFrame.Angles(-math.rad(20), 0, 0),
			{
				Color = Color3.fromRGB(40, 40, 40),
				Material = Enum.Material.Metal,
				CanCollide = false,
			},
			roomModel
		)
		camPart.Name = "Camera_" .. (room.camera:gsub(" ", "_"))
		camPart:SetAttribute("CameraId", room.camera)
		camPart:SetAttribute("RoomId", id)
		camPart:SetAttribute("AudioOnly", room.audioOnly == true)
		CollectionService:AddTag(camPart, TAG_CAMERA)

		-- The red recording-light dot
		local lens = makePart(
			"Lens",
			Vector3.new(0.4, 0.4, 0.4),
			camPart.CFrame * CFrame.new(0, -0.4, -1.2),
			{
				Color = Color3.fromRGB(220, 50, 60),
				Material = Enum.Material.Neon,
				CanCollide = false,
			},
			roomModel
		)
		lens.Shape = Enum.PartType.Ball

		-- Floor sign with the room's display name so players know where they are
		local sign = Instance.new("Part")
		sign.Name = "RoomSign"
		sign.Anchored = true
		sign.CanCollide = false
		sign.Size = Vector3.new(ROOM_SIZE - 4, 0.05, 2)
		sign.CFrame = CFrame.new(centre.X, FLOOR_THICK + 0.05, centre.Z - ROOM_SIZE / 2 + 2)
		sign.Transparency = 1
		sign.Parent = roomModel
		local sg = Instance.new("SurfaceGui")
		sg.Face = Enum.NormalId.Top
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 50
		sg.Parent = sign
		local txt = Instance.new("TextLabel")
		txt.Size = UDim2.fromScale(1, 1)
		txt.BackgroundTransparency = 1
		txt.Text = string.upper(room.name) .. (room.audioOnly and "   |   AUDIO ONLY" or "")
		txt.Font = Enum.Font.Code
		txt.TextScaled = true
		txt.TextColor3 = Color3.fromRGB(180, 60, 60)
		txt.Parent = sg
	end

	-- Theme dressing: just a few flavour parts so the rooms feel different.
	local dressColor = Color3.fromRGB(60, 50, 48)
	if room.theme == "stage" then
		-- raised stage
		makePart(
			"Stage",
			Vector3.new(20, 2, 10),
			CFrame.new(centre.X, FLOOR_THICK + 1, centre.Z - 8),
			{
				Color = Color3.fromRGB(70, 24, 32),
				Material = Enum.Material.WoodPlanks,
			},
			roomModel
		)
		-- curtain rod (cosmetic)
		makePart(
			"Curtain",
			Vector3.new(24, 6, 0.4),
			CFrame.new(centre.X, FLOOR_THICK + 6, centre.Z - 12),
			{
				Color = Color3.fromRGB(70, 18, 24),
				Material = Enum.Material.Fabric,
			},
			roomModel
		)
	elseif room.theme == "dining" then
		for i = -1, 1 do
			for j = -1, 1 do
				if not (i == 0 and j == 0) then
					makePart(
						"Table_" .. i .. "_" .. j,
						Vector3.new(6, 3, 6),
						CFrame.new(centre.X + i * 12, FLOOR_THICK + 1.5, centre.Z + j * 12),
						{
							Color = Color3.fromRGB(100, 70, 50),
							Material = Enum.Material.WoodPlanks,
						},
						roomModel
					)
				end
			end
		end
	elseif room.theme == "kitchen" then
		makePart(
			"Counter",
			Vector3.new(ROOM_SIZE - 6, 3, 6),
			CFrame.new(centre.X, FLOOR_THICK + 1.5, centre.Z - 14),
			{
				Color = Color3.fromRGB(200, 200, 210),
				Material = Enum.Material.SmoothPlastic,
			},
			roomModel
		)
		makePart(
			"Stove",
			Vector3.new(10, 4, 6),
			CFrame.new(centre.X, FLOOR_THICK + 2, centre.Z + 14),
			{
				Color = Color3.fromRGB(40, 40, 40),
				Material = Enum.Material.Metal,
			},
			roomModel
		)
	elseif room.theme == "arcade" then
		for i = -1, 1, 2 do
			for j = -1, 1, 2 do
				makePart(
					"Machine_" .. i .. "_" .. j,
					Vector3.new(4, 7, 4),
					CFrame.new(centre.X + i * 12, FLOOR_THICK + 3.5, centre.Z + j * 12),
					{
						Color = Color3.fromRGB(20, 22, 80),
						Material = Enum.Material.Neon,
					},
					roomModel
				)
			end
		end
	elseif room.theme == "party" then
		makePart(
			"PartyTable",
			Vector3.new(20, 3, 8),
			CFrame.new(centre.X, FLOOR_THICK + 1.5, centre.Z),
			{
				Color = Color3.fromRGB(140, 90, 110),
				Material = Enum.Material.SmoothPlastic,
			},
			roomModel
		)
	elseif room.theme == "office" and id == "SecurityOffice" then
		-- security desk + monitors
		makePart(
			"Desk",
			Vector3.new(18, 3, 6),
			CFrame.new(centre.X, FLOOR_THICK + 1.5, centre.Z + 6),
			{
				Color = Color3.fromRGB(90, 60, 40),
				Material = Enum.Material.WoodPlanks,
			},
			roomModel
		)
		for i = -1, 1 do
			makePart(
				"Monitor_" .. i,
				Vector3.new(4, 3, 0.4),
				CFrame.new(centre.X + i * 5, FLOOR_THICK + 4.5, centre.Z + 6),
				{
					Color = Color3.fromRGB(20, 30, 40),
					Material = Enum.Material.Neon,
				},
				roomModel
			)
		end
		-- Player spawn pad
		local spawn = Instance.new("SpawnLocation")
		spawn.Name = "OfficeSpawn"
		spawn.Anchored = true
		spawn.Size = Vector3.new(6, 0.4, 6)
		spawn.CFrame = CFrame.new(centre.X, FLOOR_THICK + 0.2, centre.Z + 1)
		spawn.Color = Color3.fromRGB(255, 200, 90)
		spawn.Material = Enum.Material.Neon
		spawn.TopSurface = Enum.SurfaceType.Smooth
		spawn.BottomSurface = Enum.SurfaceType.Smooth
		spawn.Parent = roomModel
		spawn:SetAttribute("IsOffice", true)
	elseif room.theme == "hall" then
		-- a couple of posters
		for i = -1, 1, 2 do
			local poster = makePart(
				"Poster_" .. i,
				Vector3.new(4, 6, 0.2),
				CFrame.new(
					centre.X + i * 12,
					FLOOR_THICK + 6,
					centre.Z - ROOM_SIZE / 2 + WALL_THICK + 0.2
				),
				{
					Color = Color3.fromRGB(180, 130, 80),
					Material = Enum.Material.SmoothPlastic,
				},
				roomModel
			)
			poster.Reflectance = 0
		end
	elseif room.theme == "office" and id == "BackRoom" then
		for i = -1, 1, 2 do
			makePart(
				"Crate_" .. i,
				Vector3.new(5, 5, 5),
				CFrame.new(centre.X + i * 10, FLOOR_THICK + 2.5, centre.Z),
				{
					Color = Color3.fromRGB(110, 80, 50),
					Material = Enum.Material.WoodPlanks,
				},
				roomModel
			)
		end
	end

	local _ = dressColor

	return roomModel
end

local function applyAtmosphere()
	Lighting.Ambient = Color3.fromRGB(15, 12, 14)
	Lighting.OutdoorAmbient = Color3.fromRGB(20, 18, 20)
	Lighting.Brightness = 1.4
	Lighting.ClockTime = 0.5
	Lighting.GeographicLatitude = 41
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.2
	Lighting.EnvironmentSpecularScale = 0.2
	Lighting.ShadowSoftness = 0.6
	Lighting.FogColor = Color3.fromRGB(10, 10, 14)
	Lighting.FogStart = 30
	Lighting.FogEnd = 250
end

local function buildMap()
	local existing = Workspace:FindFirstChild("FazbearMap")
	if existing then
		existing:Destroy()
	end

	local map = Instance.new("Model")
	map.Name = "FazbearMap"
	map.Parent = Workspace

	-- Big outer slab for visuals (slightly bigger than the 3x3 grid)
	local outerSize = ROOM_SIZE * 3 + 20
	makePart("GroundSlab", Vector3.new(outerSize, 1, outerSize), CFrame.new(0, -0.5, 0), {
		Color = Color3.fromRGB(18, 14, 16),
		Material = Enum.Material.Slate,
	}, map)

	for id, room in pairs(ROOMS) do
		buildRoom(map, id, room)
	end

	applyAtmosphere()
	return map
end

------------------------------------------------------------------------------
-- Embedded server + client source
------------------------------------------------------------------------------

local SERVER_SOURCE = [==[
--!strict
-- Auto-installed by FazbearSecurityPlugin.
-- Runs on the server.  Owns lockable-door state and broadcasts it to all
-- clients.  Plain (blue) doors are click-toggled directly by clients via
-- ClickDetectors.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TAG_DOOR = "FazbearDoor"
local TAG_LOCKABLE = "FazbearLockableDoor"

local remotes = ReplicatedStorage:WaitForChild("FazbearSecurity")
local toggleDoor = remotes:WaitForChild("ToggleDoor") :: RemoteEvent
local doorStateRemote = remotes:WaitForChild("DoorState") :: RemoteEvent
local requestState = remotes:WaitForChild("RequestState") :: RemoteEvent

local DOOR_TWEEN_TIME = 0.25

local lockState: { [string]: boolean } = {}

local function setDoorOpen(part: BasePart, open: boolean)
	local closedCFrame = part:GetAttribute("ClosedCFrame") :: CFrame?
	local openCFrame = part:GetAttribute("OpenCFrame") :: CFrame?
	if not (closedCFrame and openCFrame) then
		return
	end
	part:SetAttribute("Open", open)
	part.CFrame = open and openCFrame or closedCFrame
	part.CanCollide = not open
	part.Transparency = open and 0.85 or 0
end

local function broadcastLocks()
	doorStateRemote:FireAllClients(lockState)
end

-- Initialise lockable doors
for _, part in ipairs(CollectionService:GetTagged(TAG_LOCKABLE)) do
	local lockId = part:GetAttribute("LockId") :: string?
	if lockId then
		lockState[lockId] = false -- false = unlocked (=open)
		setDoorOpen(part, true)
	end
end

-- Plain doors: server-driven click toggle (so all clients see the same state).
for _, part in ipairs(CollectionService:GetTagged(TAG_DOOR)) do
	if part:FindFirstChildOfClass("ClickDetector") == nil then
		local cd = Instance.new("ClickDetector")
		cd.MaxActivationDistance = 14
		cd.Parent = part
	end
	local cd = part:FindFirstChildOfClass("ClickDetector") :: ClickDetector
	cd.MouseClick:Connect(function(_player)
		setDoorOpen(part, not (part:GetAttribute("Open") == true))
	end)
	setDoorOpen(part, true)
end

toggleDoor.OnServerEvent:Connect(function(player, lockIdAny)
	if typeof(lockIdAny) ~= "string" then
		return
	end
	local lockId: string = lockIdAny
	for _, part in ipairs(CollectionService:GetTagged(TAG_LOCKABLE)) do
		if part:GetAttribute("LockId") == lockId then
			local nowLocked = not (lockState[lockId] or false)
			lockState[lockId] = nowLocked
			-- Locked = closed door = not open.
			setDoorOpen(part, not nowLocked)
			broadcastLocks()
			return
		end
	end
end)

requestState.OnServerEvent:Connect(function(player)
	doorStateRemote:FireClient(player, lockState)
end)

Players.PlayerAdded:Connect(function(player)
	doorStateRemote:FireClient(player, lockState)
end)

broadcastLocks()
print("[FazbearSecurity] server ready -- doors:", #CollectionService:GetTagged(TAG_DOOR),
	"lockable:", #CollectionService:GetTagged(TAG_LOCKABLE))
]==]

local CLIENT_SOURCE = [==[
--!strict
-- Auto-installed by FazbearSecurityPlugin.
-- Per-client tablet UI: press M to toggle.  Cycles CAM 01..CAM 08.  Sends
-- server requests to toggle the West / East security-office lockable doors.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local TAG_CAMERA = "FazbearCamera"

local remotes = ReplicatedStorage:WaitForChild("FazbearSecurity")
local toggleDoor = remotes:WaitForChild("ToggleDoor") :: RemoteEvent
local doorStateRemote = remotes:WaitForChild("DoorState") :: RemoteEvent
local requestState = remotes:WaitForChild("RequestState") :: RemoteEvent

local CAMERA_ORDER = {
	"CAM 01", "CAM 02", "CAM 03", "CAM 04",
	"CAM 05", "CAM 06", "CAM 07", "CAM 08",
}

local function findCamera(id: string): BasePart?
	for _, part in ipairs(CollectionService:GetTagged(TAG_CAMERA)) do
		if part:GetAttribute("CameraId") == id then
			return part
		end
	end
	return nil
end

local function cameraIsAudioOnly(id: string): boolean
	local part = findCamera(id)
	return part ~= nil and part:GetAttribute("AudioOnly") == true
end

local function roomDisplayName(id: string): string
	local part = findCamera(id)
	if not part then
		return id
	end
	local roomModel = part.Parent
	if roomModel and roomModel:IsA("Model") then
		local name = roomModel:GetAttribute("DisplayName") :: string?
		if name then
			return name
		end
	end
	return id
end

------------------------------------------------------------------------------
-- GUI
------------------------------------------------------------------------------

local function newInstance(class: string, props: { [string]: any }): Instance
	local inst = Instance.new(class)
	for k, v in pairs(props) do
		(inst :: any)[k] = v
	end
	return inst
end

local playerGui = LocalPlayer:WaitForChild("PlayerGui")

local gui = newInstance("ScreenGui", {
	Name = "FazbearTablet",
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	DisplayOrder = 100,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

-- Hint label (always visible)
local hint = newInstance("TextLabel", {
	Name = "Hint",
	Size = UDim2.new(0, 240, 0, 36),
	Position = UDim2.new(1, -260, 1, -56),
	AnchorPoint = Vector2.new(0, 0),
	BackgroundColor3 = Color3.fromRGB(0, 0, 0),
	BackgroundTransparency = 0.45,
	BorderSizePixel = 0,
	Font = Enum.Font.Code,
	TextColor3 = Color3.fromRGB(220, 80, 80),
	TextScaled = true,
	Text = "[M] CAMERAS",
	Parent = gui,
})
hint.TextXAlignment = Enum.TextXAlignment.Center
hint.TextYAlignment = Enum.TextYAlignment.Center

local root = newInstance("Frame", {
	Name = "TabletRoot",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(0, 0, 0),
	BackgroundTransparency = 0.15,
	BorderSizePixel = 0,
	Visible = false,
	Parent = gui,
})

-- Tablet bezel
local bezel = newInstance("Frame", {
	Size = UDim2.new(1, -80, 1, -100),
	Position = UDim2.new(0, 40, 0, 40),
	BackgroundColor3 = Color3.fromRGB(20, 18, 20),
	BorderSizePixel = 0,
	Parent = root,
})
newInstance("UICorner", { CornerRadius = UDim.new(0, 16), Parent = bezel })

-- Feed area (just visual border; camera is the *actual* workspace camera)
local feed = newInstance("Frame", {
	Size = UDim2.new(1, -40, 1, -180),
	Position = UDim2.new(0, 20, 0, 20),
	BackgroundColor3 = Color3.fromRGB(0, 0, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Parent = bezel,
})

-- Top label (CAM XX -- ROOM NAME)
local camLabel = newInstance("TextLabel", {
	Size = UDim2.new(1, 0, 0, 40),
	Position = UDim2.new(0, 0, 0, 0),
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	TextColor3 = Color3.fromRGB(255, 70, 70),
	TextScaled = true,
	Text = "CAM 01  -  DINING AREA",
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = feed,
})

-- AUDIO ONLY overlay
local audioOverlay = newInstance("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(0, 0, 0),
	BackgroundTransparency = 0.1,
	BorderSizePixel = 0,
	Visible = false,
	Parent = feed,
})
newInstance("TextLabel", {
	Size = UDim2.fromScale(1, 1),
	BackgroundTransparency = 1,
	Font = Enum.Font.Code,
	TextColor3 = Color3.fromRGB(255, 200, 60),
	TextScaled = true,
	Text = "*** AUDIO ONLY ***",
	Parent = audioOverlay,
})

-- "Static" / scanlines hint
local scanlines = newInstance("Frame", {
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.fromRGB(255, 255, 255),
	BackgroundTransparency = 0.97,
	BorderSizePixel = 0,
	Parent = feed,
})
scanlines.ZIndex = 4
scanlines.Active = false

-- Camera button row
local camRow = newInstance("Frame", {
	Size = UDim2.new(1, -40, 0, 120),
	Position = UDim2.new(0, 20, 1, -140),
	BackgroundTransparency = 1,
	Parent = bezel,
})
local layout = newInstance("UIListLayout", {
	FillDirection = Enum.FillDirection.Horizontal,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	VerticalAlignment = Enum.VerticalAlignment.Center,
	Padding = UDim.new(0, 8),
	Parent = camRow,
})

local camButtons: { [string]: TextButton } = {}

local currentCamera = "CAM 01"

local function makeButton(text: string, onClick: () -> ())
	local btn = newInstance("TextButton", {
		Size = UDim2.new(0, 110, 0, 80),
		BackgroundColor3 = Color3.fromRGB(30, 30, 34),
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		TextColor3 = Color3.fromRGB(220, 220, 220),
		TextScaled = true,
		AutoButtonColor = true,
		Text = text,
		Parent = camRow,
	})
	newInstance("UICorner", { CornerRadius = UDim.new(0, 6), Parent = btn })
	btn.MouseButton1Click:Connect(onClick)
	return btn
end

local function setCameraView(cameraId: string)
	currentCamera = cameraId
	local part = findCamera(cameraId)
	local cam = Workspace.CurrentCamera
	if part and cam then
		cam.CameraType = Enum.CameraType.Scriptable
		-- look from the camera marker down to the centre of its room
		local roomModel = part.Parent
		local centre = part.Position
		if roomModel and roomModel:IsA("Model") then
			local cf, _size = roomModel:GetBoundingBox()
			centre = cf.Position
		end
		cam.CFrame = CFrame.new(part.Position + Vector3.new(0, -1, 0), centre)
	end
	camLabel.Text = string.format("%s  -  %s", cameraId, string.upper(roomDisplayName(cameraId)))
	audioOverlay.Visible = cameraIsAudioOnly(cameraId)

	for id, btn in pairs(camButtons) do
		btn.BackgroundColor3 = (id == cameraId) and Color3.fromRGB(120, 30, 30) or Color3.fromRGB(30, 30, 34)
	end
end

for _, camId in ipairs(CAMERA_ORDER) do
	local btn = makeButton(camId, function()
		setCameraView(camId)
	end)
	camButtons[camId] = btn
end

-- Door control buttons (top-right of bezel)
local doorPanel = newInstance("Frame", {
	Size = UDim2.new(0, 220, 0, 80),
	Position = UDim2.new(1, -240, 0, 60),
	BackgroundColor3 = Color3.fromRGB(20, 12, 12),
	BorderSizePixel = 0,
	Parent = bezel,
})
newInstance("UICorner", { CornerRadius = UDim.new(0, 8), Parent = doorPanel })

local doorButtons: { [string]: TextButton } = {}
local function makeDoorBtn(lockId: string, label: string, posX: number)
	local b = newInstance("TextButton", {
		Size = UDim2.new(0, 90, 0, 60),
		Position = UDim2.new(0, posX, 0, 10),
		BackgroundColor3 = Color3.fromRGB(40, 40, 40),
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		TextColor3 = Color3.fromRGB(220, 220, 220),
		TextScaled = true,
		Text = label .. "\nDOOR",
		Parent = doorPanel,
	})
	newInstance("UICorner", { CornerRadius = UDim.new(0, 6), Parent = b })
	b.MouseButton1Click:Connect(function()
		toggleDoor:FireServer(lockId)
	end)
	doorButtons[lockId] = b
	return b
end
makeDoorBtn("West", "WEST", 10)
makeDoorBtn("East", "EAST", 115)

local function applyLockUI(state: { [string]: boolean })
	for lockId, btn in pairs(doorButtons) do
		local locked = state[lockId] == true
		btn.BackgroundColor3 = locked and Color3.fromRGB(180, 40, 50) or Color3.fromRGB(40, 40, 40)
		btn.Text = (locked and "[LOCKED]\n" or "[OPEN]\n") .. string.upper(lockId) .. " DOOR"
	end
end

doorStateRemote.OnClientEvent:Connect(applyLockUI)
requestState:FireServer()

------------------------------------------------------------------------------
-- Tablet open / close
------------------------------------------------------------------------------

local tabletOpen = false
local lastCameraType: Enum.CameraType? = nil

local function openTablet()
	if tabletOpen then return end
	tabletOpen = true
	root.Visible = true
	hint.Text = "[M] CLOSE"
	local cam = Workspace.CurrentCamera
	if cam then
		lastCameraType = cam.CameraType
	end
	setCameraView(currentCamera)
end

local function closeTablet()
	if not tabletOpen then return end
	tabletOpen = false
	root.Visible = false
	hint.Text = "[M] CAMERAS"
	local cam = Workspace.CurrentCamera
	if cam then
		cam.CameraType = lastCameraType or Enum.CameraType.Custom
		cam.CameraSubject = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildWhichIsA("Humanoid") or cam.CameraSubject
	end
end

local function toggleTablet()
	if tabletOpen then
		closeTablet()
	else
		openTablet()
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.M then
		toggleTablet()
	end
end)

-- Animated scanline noise while tablet is open
RunService.RenderStepped:Connect(function(dt)
	if tabletOpen then
		scanlines.BackgroundTransparency = 0.94 + math.random() * 0.05
	end
end)

LocalPlayer.CharacterAdded:Connect(function(_char)
	closeTablet()
end)

print("[FazbearSecurity] tablet ready -- press M to open cameras")
]==]

------------------------------------------------------------------------------
-- Install scripts + remotes
------------------------------------------------------------------------------

local function ensureRemotes()
	local existing = ReplicatedStorage:FindFirstChild("FazbearSecurity")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "FazbearSecurity"
	folder.Parent = ReplicatedStorage

	for _, name in ipairs({ "ToggleDoor", "DoorState", "RequestState" }) do
		local r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
end

local function installServerScript()
	local existing = ServerScriptService:FindFirstChild("FazbearSecurityServer")
	if existing then
		existing:Destroy()
	end
	local s = Instance.new("Script")
	s.Name = "FazbearSecurityServer"
	s.Source = SERVER_SOURCE
	s.Parent = ServerScriptService
end

local function installClientScript()
	local sps = StarterPlayer:FindFirstChild("StarterPlayerScripts")
	if not sps then
		warn("[FazbearSecurity] StarterPlayer.StarterPlayerScripts is missing")
		return
	end
	local existing = sps:FindFirstChild("FazbearTabletClient")
	if existing then
		existing:Destroy()
	end
	local s = Instance.new("LocalScript")
	s.Name = "FazbearTabletClient"
	s.Source = CLIENT_SOURCE
	s.Parent = sps
end

------------------------------------------------------------------------------
-- Plugin orchestration
------------------------------------------------------------------------------

local function installAll()
	local recording = ChangeHistoryService:TryBeginRecording("Install Fazbear Security")
	local ok, err = pcall(function()
		buildMap()
		ensureRemotes()
		installServerScript()
		installClientScript()
	end)
	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		warn("[FazbearSecurity] install failed:", err)
	else
		print(
			"[FazbearSecurity] installed."
				.. " Press Play, then press M in-game to open the camera tablet."
		)
	end
end

local function rebuildMapOnly()
	local recording = ChangeHistoryService:TryBeginRecording("Rebuild Fazbear Map")
	local ok, err = pcall(buildMap)
	if recording then
		ChangeHistoryService:FinishRecording(
			recording,
			ok and Enum.FinishRecordingOperation.Commit or Enum.FinishRecordingOperation.Cancel
		)
	end
	if not ok then
		warn("[FazbearSecurity] rebuild failed:", err)
	end
end

local toolbar = plugin:CreateToolbar("Fazbear Security")

local installButton = toolbar:CreateButton(
	"Install / Rebuild",
	"Build the Freddy Fazbear's map and install the multiplayer cameras + doors",
	"rbxasset://textures/AnimationEditor/icon_axes.png"
)
installButton.ClickableWhenViewportHidden = true
installButton.Click:Connect(installAll)

local mapOnlyButton = toolbar:CreateButton(
	"Rebuild Map Only",
	"Rebuild just the map geometry (keeps scripts and remotes)",
	"rbxasset://textures/AnimationEditor/icon_keyframe.png"
)
mapOnlyButton.ClickableWhenViewportHidden = true
mapOnlyButton.Click:Connect(rebuildMapOnly)
