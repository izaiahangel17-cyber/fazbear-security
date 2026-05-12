-- Animatronic chase AI for the Fazbear security map.
--
-- Drop this Script inside an NPC model that has a Humanoid and a
-- HumanoidRootPart. Set the script's "Difficulty" attribute to
-- "Easy" | "Medium" | "Hard" (defaults to Medium).
--
-- Optional: a child Folder named "PatrolPoints" containing BasePart
-- waypoints. If present, the animatronic patrols between them; if
-- absent, it wanders.
--
-- Detection feedback fires on ReplicatedStorage.PlayerDetectionChanged
-- (RemoteEvent) -- payload (player, isDetected: boolean). The plugin's
-- camera tablet can listen on this to flash an alert.
--
-- Design: a simple state machine. Sight is a forward cone with a
-- raycast, hearing is proximity scaled by player speed. There is NO
-- "audible through walls" or "wrong-path lottery" -- the AI either has
-- a reason to come for you or it doesn't.

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DIFFICULTY = script:GetAttribute("Difficulty") or "Medium"

local DIFFICULTIES = {
	Easy = {
		patrolSpeed = 8,
		investigateSpeed = 13,
		chaseSpeed = 16,
		sightRange = 45,
		sightFovDeg = 90,
		hearingRange = 26,
		hearingSpeedFloor = 10, -- player must move >= this fast to be heard
		investigateTimeout = 5.5,
		searchDuration = 3.5,
		patrolDwellMin = 4.0,
		patrolDwellMax = 7.0,
	},
	Medium = {
		patrolSpeed = 9,
		investigateSpeed = 15,
		chaseSpeed = 18,
		sightRange = 65,
		sightFovDeg = 120,
		hearingRange = 38,
		hearingSpeedFloor = 6,
		investigateTimeout = 4.5,
		searchDuration = 3.0,
		patrolDwellMin = 3.0,
		patrolDwellMax = 5.5,
	},
	Hard = {
		patrolSpeed = 11,
		investigateSpeed = 17,
		chaseSpeed = 21,
		sightRange = 90,
		sightFovDeg = 150,
		hearingRange = 52,
		hearingSpeedFloor = 3,
		investigateTimeout = 3.5,
		searchDuration = 2.5,
		patrolDwellMin = 2.0,
		patrolDwellMax = 4.0,
	},
}

local CONFIG = DIFFICULTIES[DIFFICULTY] or DIFFICULTIES.Medium
local SIGHT_FOV_HALF_COS = math.cos(math.rad(CONFIG.sightFovDeg) / 2)

local detectionEvent = ReplicatedStorage:FindFirstChild("PlayerDetectionChanged")
if not detectionEvent then
	detectionEvent = Instance.new("RemoteEvent")
	detectionEvent.Name = "PlayerDetectionChanged"
	detectionEvent.Parent = ReplicatedStorage
end

-- Tuning constants the difficulty curves don't touch.
local PERCEPTION_INTERVAL = 0.2
local PATH_REFRESH_INTERVAL = 0.5
local WAYPOINT_REACHED_DISTANCE = 4
local DIRECT_MOVE_DISTANCE = 12
local STUCK_CHECK_INTERVAL = 1.0
local STUCK_DISTANCE = 1.5
local EYE_HEIGHT = 2

local character = script.Parent
local humanoid = character:WaitForChild("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")

humanoid.AutoRotate = true
humanoid.PlatformStand = false
humanoid.Sit = false
humanoid.WalkSpeed = CONFIG.patrolSpeed

for _, part in ipairs(character:GetDescendants()) do
	if part:IsA("BasePart") then
		part.Anchored = false
		part.CanCollide = false
		part.Massless = part ~= rootPart
		pcall(function()
			part:SetNetworkOwner(nil)
		end)
	end
end

local raycastParams = RaycastParams.new()
raycastParams.FilterDescendantsInstances = { character }
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

-- Optional patrol points: a child Folder of BaseParts.
local patrolPoints = {}
local patrolFolder = character:FindFirstChild("PatrolPoints")
if patrolFolder then
	for _, child in ipairs(patrolFolder:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(patrolPoints, child.Position)
		end
	end
end

-- ------------------------------------------------------------------ --
-- Perception
-- ------------------------------------------------------------------ --

local function flatten(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function getLivingRoot(player)
	local char = player.Character
	if not char then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 then
		return nil
	end
	return root
end

local function hasLineOfSight(targetRoot)
	local origin = rootPart.Position + Vector3.new(0, EYE_HEIGHT, 0)
	local goal = targetRoot.Position + Vector3.new(0, EYE_HEIGHT, 0)
	local hit = workspace:Raycast(origin, goal - origin, raycastParams)
	if not hit then
		return true
	end
	return hit.Instance:IsDescendantOf(targetRoot.Parent)
end

local function isInForwardCone(targetRoot)
	local toTarget = flatten(targetRoot.Position - rootPart.Position)
	if toTarget.Magnitude < 0.1 then
		return true
	end
	local lookFlat = flatten(rootPart.CFrame.LookVector)
	if lookFlat.Magnitude < 0.1 then
		return true
	end
	return lookFlat.Unit:Dot(toTarget.Unit) >= SIGHT_FOV_HALF_COS
end

local function canSee(targetRoot)
	local distance = (targetRoot.Position - rootPart.Position).Magnitude
	if distance > CONFIG.sightRange then
		return false
	end
	if not isInForwardCone(targetRoot) then
		return false
	end
	return hasLineOfSight(targetRoot)
end

local function canHear(targetRoot)
	local distance = (targetRoot.Position - rootPart.Position).Magnitude
	if distance > CONFIG.hearingRange then
		return false
	end
	local speed = flatten(targetRoot.AssemblyLinearVelocity).Magnitude
	return speed >= CONFIG.hearingSpeedFloor
end

-- Returns (seen, heard) -- each is either nil or { player, root, position }.
-- "seen" wins if both are populated for the same player.
local function perceivePlayers()
	local seen, heard = nil, nil
	local seenDistance, heardDistance = math.huge, math.huge

	for _, player in ipairs(Players:GetPlayers()) do
		local targetRoot = getLivingRoot(player)
		if targetRoot then
			local distance = (rootPart.Position - targetRoot.Position).Magnitude
			if canSee(targetRoot) and distance < seenDistance then
				seen = { player = player, root = targetRoot, position = targetRoot.Position }
				seenDistance = distance
			elseif canHear(targetRoot) and distance < heardDistance then
				heard = { player = player, root = targetRoot, position = targetRoot.Position }
				heardDistance = distance
			end
		end
	end

	return seen, heard
end

-- ------------------------------------------------------------------ --
-- Movement (path follower)
-- ------------------------------------------------------------------ --

local currentPath = nil
local waypoints = {}
local waypointIndex = 0
local currentDestination = nil
local nextPathRefresh = 0
local lastMoveCommand = nil
local blockedConnection = nil

local function clearPath()
	if blockedConnection then
		blockedConnection:Disconnect()
		blockedConnection = nil
	end
	currentPath = nil
	waypoints = {}
	waypointIndex = 0
	lastMoveCommand = nil
end

local function commandMove(position)
	-- Dedup against the last issued MoveTo target so we don't thrash the
	-- humanoid when the destination only drifts by sub-stud amounts.
	if lastMoveCommand and (lastMoveCommand - position).Magnitude < 0.6 then
		return
	end
	lastMoveCommand = position
	humanoid:MoveTo(position)
end

local function followCurrentWaypoint()
	local wp = waypoints[waypointIndex]
	if not wp then
		return
	end
	if wp.Action == Enum.PathWaypointAction.Jump then
		humanoid.Jump = true
	end
	commandMove(wp.Position)
end

local function computePath(destination)
	clearPath()
	currentDestination = destination
	nextPathRefresh = os.clock() + PATH_REFRESH_INTERVAL

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = false,
		WaypointSpacing = 4,
	})

	local ok = pcall(function()
		path:ComputeAsync(rootPart.Position, destination)
	end)

	if not ok or path.Status ~= Enum.PathStatus.Success then
		-- Fall back to a direct move so the AI keeps making progress even
		-- when the navmesh can't find a route (e.g. open arena).
		commandMove(destination)
		return
	end

	currentPath = path
	waypoints = path:GetWaypoints()
	waypointIndex = math.min(2, #waypoints)

	blockedConnection = path.Blocked:Connect(function(blockedIndex)
		if blockedIndex >= waypointIndex then
			nextPathRefresh = 0
		end
	end)

	followCurrentWaypoint()
end

local function moveDirect(destination)
	-- Bypass pathfinding for short-range pursuit where the cost of a path
	-- query outweighs its benefit, and where pathfinding's lag tends to
	-- visibly let the player slip away.
	if blockedConnection then
		blockedConnection:Disconnect()
		blockedConnection = nil
	end
	currentPath = nil
	waypoints = {}
	waypointIndex = 0
	currentDestination = destination
	commandMove(destination)
end

local function pathTowards(destination)
	local now = os.clock()
	local destinationMoved = not currentDestination
		or (destination - currentDestination).Magnitude >= 6
	if destinationMoved or now >= nextPathRefresh or not currentPath then
		computePath(destination)
	end
end

local function advanceWaypointIfNeeded()
	local wp = waypoints[waypointIndex]
	if not wp then
		return
	end
	if (rootPart.Position - wp.Position).Magnitude <= WAYPOINT_REACHED_DISTANCE then
		waypointIndex += 1
		if waypointIndex > #waypoints then
			nextPathRefresh = 0
		else
			followCurrentWaypoint()
		end
	end
end

humanoid.MoveToFinished:Connect(function(reached)
	if not reached then
		nextPathRefresh = 0
	end
end)

-- ------------------------------------------------------------------ --
-- Detection event
-- ------------------------------------------------------------------ --

local detectedPlayer = nil
local lastDetectionState = false

local function setDetected(player, isDetected)
	if player ~= detectedPlayer then
		if detectedPlayer and lastDetectionState then
			detectionEvent:FireClient(detectedPlayer, false)
		end
		detectedPlayer = player
		lastDetectionState = false
	end
	if player and lastDetectionState ~= isDetected then
		lastDetectionState = isDetected
		detectionEvent:FireClient(player, isDetected)
	end
end

-- ------------------------------------------------------------------ --
-- State machine
-- ------------------------------------------------------------------ --

local State = {
	PATROL = "PATROL",
	INVESTIGATE = "INVESTIGATE",
	CHASE = "CHASE",
	SEARCH = "SEARCH",
}

local state = State.PATROL
local stateEnteredAt = 0
local targetPlayer = nil
local targetRoot = nil
local lastKnownPosition = nil
local patrolDestination = nil
local nextPatrolPickAt = 0

local function pickPatrolDestination()
	if #patrolPoints > 0 then
		-- Avoid picking the patrol point we're standing on if there are
		-- alternatives, so the NPC actually moves.
		local candidates = {}
		for _, position in ipairs(patrolPoints) do
			if (position - rootPart.Position).Magnitude > WAYPOINT_REACHED_DISTANCE then
				table.insert(candidates, position)
			end
		end
		local pool = #candidates > 0 and candidates or patrolPoints
		return pool[math.random(1, #pool)]
	end

	local angle = math.random() * math.pi * 2
	local distance = 12 + math.random() * 18
	return rootPart.Position
		+ Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

local function setState(newState, now)
	if newState == state then
		return
	end
	state = newState
	stateEnteredAt = now
	clearPath()

	if newState == State.PATROL then
		humanoid.WalkSpeed = CONFIG.patrolSpeed
		patrolDestination = nil
		setDetected(nil, false)
	elseif newState == State.INVESTIGATE then
		humanoid.WalkSpeed = CONFIG.investigateSpeed
		setDetected(targetPlayer, false)
	elseif newState == State.CHASE then
		humanoid.WalkSpeed = CONFIG.chaseSpeed
		setDetected(targetPlayer, true)
	elseif newState == State.SEARCH then
		humanoid.WalkSpeed = CONFIG.investigateSpeed
		setDetected(targetPlayer, false)
	end
end

local function updatePatrol(now)
	if
		not patrolDestination
		or now >= nextPatrolPickAt
		or (rootPart.Position - patrolDestination).Magnitude <= WAYPOINT_REACHED_DISTANCE
	then
		patrolDestination = pickPatrolDestination()
		nextPatrolPickAt = now
			+ CONFIG.patrolDwellMin
			+ math.random() * (CONFIG.patrolDwellMax - CONFIG.patrolDwellMin)
	end
	pathTowards(patrolDestination)
end

local function updateInvestigate(now)
	if not lastKnownPosition then
		setState(State.PATROL, now)
		return
	end

	if (rootPart.Position - lastKnownPosition).Magnitude <= WAYPOINT_REACHED_DISTANCE then
		setState(State.SEARCH, now)
		return
	end

	if now - stateEnteredAt > CONFIG.investigateTimeout then
		lastKnownPosition = nil
		setState(State.PATROL, now)
		return
	end

	pathTowards(lastKnownPosition)
end

local function updateChase(_now)
	if not targetRoot or not targetRoot.Parent then
		return
	end
	local distance = (rootPart.Position - targetRoot.Position).Magnitude
	if distance <= DIRECT_MOVE_DISTANCE and hasLineOfSight(targetRoot) then
		moveDirect(targetRoot.Position)
	else
		pathTowards(targetRoot.Position)
	end
end

local function updateSearch(now)
	if now - stateEnteredAt > CONFIG.searchDuration then
		lastKnownPosition = nil
		setState(State.PATROL, now)
		return
	end
	if lastKnownPosition then
		-- Pace a small circle around the last-known spot so the NPC isn't
		-- frozen during the search window; reads as "looking around".
		local angle = (now - stateEnteredAt) * 1.4
		local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 4
		moveDirect(lastKnownPosition + offset)
	end
end

-- ------------------------------------------------------------------ --
-- Heartbeat
-- ------------------------------------------------------------------ --

local nextPerceptionAt = 0
local stuckTimer = 0
local lastStuckPosition = rootPart.Position

RunService.Heartbeat:Connect(function(deltaTime)
	if humanoid.Health <= 0 then
		clearPath()
		return
	end

	local now = os.clock()

	if now >= nextPerceptionAt then
		nextPerceptionAt = now + PERCEPTION_INTERVAL
		local seen, heard = perceivePlayers()

		if seen then
			targetPlayer = seen.player
			targetRoot = seen.root
			lastKnownPosition = seen.position
			setState(State.CHASE, now)
		else
			if heard then
				targetPlayer = heard.player
				lastKnownPosition = heard.position
			end
			-- targetRoot is the live HumanoidRootPart and is only meaningful
			-- while we have visual contact; clear it as soon as we lose sight.
			targetRoot = nil

			if state == State.CHASE then
				-- Lost sight: drop into INVESTIGATE on the last-known position
				-- (refreshed above if we also have an audible cue this tick).
				setState(State.INVESTIGATE, now)
			elseif heard and (state == State.PATROL or state == State.SEARCH) then
				setState(State.INVESTIGATE, now)
			elseif heard and state == State.INVESTIGATE then
				-- Ongoing noise refreshes the investigate window so a player
				-- who keeps sprinting can't outlast the timeout.
				stateEnteredAt = now
			end
		end
	end

	if state == State.CHASE then
		updateChase(now)
	elseif state == State.INVESTIGATE then
		updateInvestigate(now)
	elseif state == State.SEARCH then
		updateSearch(now)
	else
		updatePatrol(now)
	end

	advanceWaypointIfNeeded()

	stuckTimer += deltaTime
	if stuckTimer >= STUCK_CHECK_INTERVAL then
		local moved = (rootPart.Position - lastStuckPosition).Magnitude
		if moved < STUCK_DISTANCE and currentDestination then
			if state == State.PATROL then
				-- The current patrol target is probably unreachable; pick
				-- another one rather than grinding into a wall.
				patrolDestination = pickPatrolDestination()
				nextPatrolPickAt = now + CONFIG.patrolDwellMin
			end
			clearPath()
			nextPathRefresh = 0
		end
		stuckTimer = 0
		lastStuckPosition = rootPart.Position
	end
end)
