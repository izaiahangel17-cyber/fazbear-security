-- Fair horror chase AI for an animatronic-style NPC.
-- Tweak the Difficulty attribute on this Script to Easy, Medium, or Hard.

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local DIFFICULTY = script:GetAttribute("Difficulty") or "Medium"

local DIFFICULTIES = {
	Easy = {
		walkSpeed = 10,
		chaseSpeed = 17,
		seenSpeed = 18,
		reactionMin = 0.42,
		reactionMax = 0.6,
		seenReactionMin = 0.26,
		seenReactionMax = 0.42,
		predictionError = 10,
		badPathChance = 0.25,
		badPathOffset = 14,
		commitTime = 0.55,
		overshootDistance = 12,
		searchRadius = 24,
	},
	Medium = {
		walkSpeed = 11,
		chaseSpeed = 19,
		seenSpeed = 21,
		reactionMin = 0.28,
		reactionMax = 0.48,
		seenReactionMin = 0.18,
		seenReactionMax = 0.32,
		predictionError = 6,
		badPathChance = 0.16,
		badPathOffset = 10,
		commitTime = 0.38,
		overshootDistance = 9,
		searchRadius = 18,
	},
	Hard = {
		walkSpeed = 12,
		chaseSpeed = 21,
		seenSpeed = 23,
		reactionMin = 0.2,
		reactionMax = 0.34,
		seenReactionMin = 0.12,
		seenReactionMax = 0.24,
		predictionError = 3.5,
		badPathChance = 0.1,
		badPathOffset = 7,
		commitTime = 0.25,
		overshootDistance = 6,
		searchRadius = 14,
	},
}

local CONFIG = DIFFICULTIES[DIFFICULTY] or DIFFICULTIES.Medium

local detectionEvent = ReplicatedStorage:FindFirstChild("PlayerDetectionChanged")
if not detectionEvent then
	detectionEvent = Instance.new("RemoteEvent")
	detectionEvent.Name = "PlayerDetectionChanged"
	detectionEvent.Parent = ReplicatedStorage
end

-- Core movement tuning.
local SEARCH_DISTANCE = 260
local GIVE_UP_AFTER_LOS_LOSS = 7
local TARGET_REFRESH_INTERVAL = 0.2
local PATH_REFRESH_INTERVAL = 0.55
local WAYPOINT_REACHED_DISTANCE = 3.75
local DESTINATION_REPATH_DISTANCE = 5
local CLOSE_RANGE_DISTANCE = 10
local PERSONAL_SPACE = 4.5

-- Horror/fairness tuning.
local SHARP_TURN_DOT = 0.15
local MIN_TURN_SPEED = 10
local GLITCH_PAUSE_CHANCE = 0.06
local GLITCH_PAUSE_MIN = 0.2
local GLITCH_PAUSE_MAX = 0.55
local GLITCH_CHECK_INTERVAL = 4
local IDLE_WANDER_RADIUS = 22
local STUCK_CHECK_INTERVAL = 0.8
local STUCK_DISTANCE = 1.1

local character = script.Parent
local humanoid = character:WaitForChild("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")

humanoid.WalkSpeed = CONFIG.walkSpeed
humanoid.AutoRotate = true
humanoid.PlatformStand = false
humanoid.Sit = false

if rootPart:IsA("BasePart") then
	rootPart.Anchored = false
end

for _, descendant in ipairs(character:GetDescendants()) do
	if descendant:IsA("BasePart") then
		descendant.Anchored = false
		descendant.CanCollide = false
		descendant.Massless = descendant ~= rootPart
		pcall(function()
			descendant:SetNetworkOwner(nil)
		end)
	end
end

local raycastParams = RaycastParams.new()
raycastParams.FilterDescendantsInstances = { character }
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

-- Movement state.
local currentPath = nil
local blockedConnection = nil
local waypoints = {}
local waypointIndex = 0
local currentDestination = nil
local lastMoveCommand = nil
local forceRepath = true
local nextPathRefresh = 0

-- Detection and decision state.
local targetRoot = nil
local detectedPlayer = nil
local lastDetectionState = false
local lastKnownPosition = nil
local lastSeenVelocity = Vector3.new(0, 0, 0)
local previousTargetVelocity = Vector3.new(0, 0, 0)
local pendingTargetVelocity = Vector3.new(0, 0, 0)
local nextTargetMemoryRefresh = 0
local hadLineOfSight = false
local lastSeenAt = -math.huge
local nextTargetRefresh = 0
local nextDecisionAt = 0
local committedUntil = 0
local decisionDestination = nil

-- Search/idle state.
local searchDestination = nil
local nextSearchPickAt = 0
local nextIdleWanderAt = 0
local pauseUntil = 0
local nextGlitchCheck = 0
local stuckTimer = 0
local lastStuckPosition = rootPart.Position

local function randomRange(minValue, maxValue)
	return minValue + math.random() * (maxValue - minValue)
end

local function flatten(vector)
	return Vector3.new(vector.X, 0, vector.Z)
end

local function randomHorizontalOffset(radius)
	local angle = randomRange(0, math.pi * 2)
	local distance = randomRange(radius * 0.35, radius)
	return Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

local function getLivingRoot(player)
	local playerCharacter = player.Character
	if not playerCharacter then
		return nil
	end
	local targetHumanoid = playerCharacter:FindFirstChildOfClass("Humanoid")
	local targetRootPart = playerCharacter:FindFirstChild("HumanoidRootPart")
	if not targetHumanoid or not targetRootPart or targetHumanoid.Health <= 0 then
		return nil
	end
	return targetRootPart
end

local function getPlayerFromRoot(root)
	if root and root.Parent then
		return Players:GetPlayerFromCharacter(root.Parent)
	end
	return nil
end

local function setPlayerDetected(player, isDetected)
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

local function isTargetValid(root)
	if not root or not root.Parent then
		return false
	end
	local targetHumanoid = root.Parent:FindFirstChildOfClass("Humanoid")
	return targetHumanoid and targetHumanoid.Health > 0
end

local function hasLineOfSight(root)
	local origin = rootPart.Position + Vector3.new(0, 2, 0)
	local destination = root.Position + Vector3.new(0, 2, 0)
	local result = workspace:Raycast(origin, destination - origin, raycastParams)
	if not result then
		return true
	end
	return result.Instance:IsDescendantOf(root.Parent)
end

local function chooseTarget()
	local bestVisibleRoot = nil
	local bestVisibleDistance = SEARCH_DISTANCE
	local bestAudibleRoot = nil
	local bestAudibleDistance = SEARCH_DISTANCE

	for _, player in ipairs(Players:GetPlayers()) do
		local playerRoot = getLivingRoot(player)
		if playerRoot then
			local distance = (rootPart.Position - playerRoot.Position).Magnitude
			if distance <= SEARCH_DISTANCE then
				if hasLineOfSight(playerRoot) and distance < bestVisibleDistance then
					bestVisibleRoot = playerRoot
					bestVisibleDistance = distance
				elseif distance < bestAudibleDistance then
					bestAudibleRoot = playerRoot
					bestAudibleDistance = distance
				end
			end
		end
	end

	return bestVisibleRoot or bestAudibleRoot
end

local function clearPath()
	if blockedConnection then
		blockedConnection:Disconnect()
		blockedConnection = nil
	end
	currentPath = nil
	waypoints = {}
	waypointIndex = 0
	-- Drop the dedup memory too, otherwise the next commandMove() right after
	-- a pause or repath can be silently skipped because it looks 'close enough'
	-- to whatever we'd commanded before clearing the path.
	lastMoveCommand = nil
end

local function commandMove(position)
	if lastMoveCommand and (lastMoveCommand - position).Magnitude < 0.4 then
		return
	end
	lastMoveCommand = position
	humanoid:MoveTo(position)
end

local function followCurrentWaypoint()
	local waypoint = waypoints[waypointIndex]
	if not waypoint then
		return
	end
	if waypoint.Action == Enum.PathWaypointAction.Jump then
		humanoid.Jump = true
	end
	commandMove(waypoint.Position)
end

local function computePath(destination)
	clearPath()
	currentDestination = destination
	nextPathRefresh = os.clock() + PATH_REFRESH_INTERVAL
	forceRepath = false

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 6,
		AgentCanJump = false,
		WaypointSpacing = 4,
	})

	local success = pcall(function()
		path:ComputeAsync(rootPart.Position, destination)
	end)

	if not success or path.Status ~= Enum.PathStatus.Success then
		commandMove(destination)
		return
	end

	currentPath = path
	waypoints = path:GetWaypoints()
	waypointIndex = math.min(2, #waypoints)

	blockedConnection = path.Blocked:Connect(function(blockedWaypointIndex)
		if blockedWaypointIndex >= waypointIndex then
			forceRepath = true
		end
	end)

	followCurrentWaypoint()
end

local function setDestination(destination, canMoveDirectly)
	if canMoveDirectly then
		clearPath()
		currentDestination = destination
		commandMove(destination)
		return
	end

	local now = os.clock()
	local destinationMoved = not currentDestination
		or (destination - currentDestination).Magnitude >= DESTINATION_REPATH_DISTANCE

	if forceRepath or destinationMoved or now >= nextPathRefresh or not currentPath then
		computePath(destination)
	end
end

local function advanceWaypointIfNeeded()
	local waypoint = waypoints[waypointIndex]
	if not waypoint then
		return
	end
	if (rootPart.Position - waypoint.Position).Magnitude <= WAYPOINT_REACHED_DISTANCE then
		waypointIndex += 1
		if waypointIndex > #waypoints then
			forceRepath = true
		else
			followCurrentWaypoint()
		end
	end
end

local function pickSearchDestination(center)
	searchDestination = center + randomHorizontalOffset(CONFIG.searchRadius)
	nextSearchPickAt = os.clock() + randomRange(1.0, 1.8)
	return searchDestination
end

local function buildImperfectDestination(canSeeTarget, now)
	local basePosition

	if canSeeTarget then
		local targetPosition = targetRoot.Position
		local targetVelocity = flatten(targetRoot.AssemblyLinearVelocity)
		local distanceToTarget = (rootPart.Position - targetPosition).Magnitude

		basePosition = targetPosition + targetVelocity * randomRange(0.08, 0.22)

		-- FIX: Stop short of the player rather than overshooting through them.
		-- The direction from the target back toward the NPC is used so the NPC
		-- aims for a point just in front of the player, not past them.
		if distanceToTarget < CLOSE_RANGE_DISTANCE then
			local towardNpc = flatten(rootPart.Position - targetPosition)
			if towardNpc.Magnitude > 0.1 then
				basePosition += towardNpc.Unit * PERSONAL_SPACE
			end
		end

		local previousFlatVelocity = flatten(previousTargetVelocity)
		if
			targetVelocity.Magnitude >= MIN_TURN_SPEED
			and previousFlatVelocity.Magnitude >= MIN_TURN_SPEED
		then
			local turnDot = targetVelocity.Unit:Dot(previousFlatVelocity.Unit)
			if turnDot < SHARP_TURN_DOT then
				committedUntil = now + CONFIG.commitTime
				basePosition = targetPosition + previousFlatVelocity.Unit * CONFIG.overshootDistance
			end
		end
	elseif lastKnownPosition then
		basePosition = lastKnownPosition
		if lastSeenVelocity.Magnitude > 1 then
			basePosition += lastSeenVelocity.Unit * randomRange(
				CONFIG.overshootDistance * 0.35,
				CONFIG.overshootDistance
			)
		end
	else
		basePosition = rootPart.Position
	end

	local errorRadius = CONFIG.predictionError
	if not canSeeTarget then
		errorRadius *= 1.35
	end

	local destination = basePosition + randomHorizontalOffset(errorRadius)
	if math.random() < CONFIG.badPathChance then
		destination += randomHorizontalOffset(CONFIG.badPathOffset)
	end

	return destination
end

local function resetTargetMemory()
	previousTargetVelocity = Vector3.new(0, 0, 0)
	pendingTargetVelocity = Vector3.new(0, 0, 0)
	nextTargetMemoryRefresh = 0
	lastKnownPosition = nil
	lastSeenVelocity = Vector3.new(0, 0, 0)
	lastSeenAt = -math.huge
end

local function updateTargetMemory(canSeeTarget, now)
	if not isTargetValid(targetRoot) then
		return
	end

	local currentPosition = targetRoot.Position
	local currentVelocity = flatten(targetRoot.AssemblyLinearVelocity)

	-- Snapshot the velocity on a fixed cadence so `previousTargetVelocity` is a
	-- real ~TARGET_REFRESH_INTERVAL-old sample. The prior implementation divided
	-- a one-frame displacement by TARGET_REFRESH_INTERVAL, producing a magnitude
	-- roughly an order of magnitude too small. As a result the sharp-turn check
	-- in buildImperfectDestination (magnitudes >= MIN_TURN_SPEED) never fired,
	-- and the animatronic would just trundle through every juke.
	if now >= nextTargetMemoryRefresh then
		previousTargetVelocity = pendingTargetVelocity
		pendingTargetVelocity = currentVelocity
		nextTargetMemoryRefresh = now + TARGET_REFRESH_INTERVAL
	end

	if canSeeTarget then
		lastKnownPosition = currentPosition
		lastSeenVelocity = currentVelocity
		lastSeenAt = now
	elseif not lastKnownPosition then
		-- Initial no-LOS awareness is intentionally vague, like hearing movement nearby.
		lastKnownPosition = currentPosition + randomHorizontalOffset(CONFIG.searchRadius)
		lastSeenVelocity = Vector3.new(0, 0, 0)
		lastSeenAt = now - 1
	end
end

local function updateDecision(canSeeTarget, now)
	if now < committedUntil then
		return
	end

	local reactionMin = canSeeTarget and CONFIG.seenReactionMin or CONFIG.reactionMin
	local reactionMax = canSeeTarget and CONFIG.seenReactionMax or CONFIG.reactionMax

	if now >= nextDecisionAt then
		decisionDestination = buildImperfectDestination(canSeeTarget, now)
		nextDecisionAt = now + randomRange(reactionMin, reactionMax)
	end
end

-- FIX: handleSearch now routes through updateDecision so reaction delays apply
-- during search, and correctly returns whether the search is still active.
local function handleSearch(now)
	if not lastKnownPosition or now - lastSeenAt > GIVE_UP_AFTER_LOS_LOSS then
		lastKnownPosition = nil
		searchDestination = nil
		-- FIX: Reset speed to walk when giving up the chase entirely.
		humanoid.WalkSpeed = CONFIG.walkSpeed
		return false
	end

	-- Refresh the search anchor point periodically or when we reach it.
	if
		not searchDestination
		or now >= nextSearchPickAt
		or (rootPart.Position - searchDestination).Magnitude <= WAYPOINT_REACHED_DISTANCE
	then
		searchDestination = pickSearchDestination(lastKnownPosition)
	end

	-- Route through updateDecision so reaction time applies during search too.
	if now >= nextDecisionAt then
		decisionDestination = searchDestination
		local reactionMin = CONFIG.reactionMin
		local reactionMax = CONFIG.reactionMax
		nextDecisionAt = now + randomRange(reactionMin, reactionMax)
	end

	return true
end

local function handleIdle(now)
	humanoid.WalkSpeed = CONFIG.walkSpeed
	if now >= nextIdleWanderAt then
		decisionDestination = rootPart.Position + randomHorizontalOffset(IDLE_WANDER_RADIUS)
		nextIdleWanderAt = now + randomRange(2.5, 4.5)
	end
end

humanoid.MoveToFinished:Connect(function(reached)
	if not reached then
		forceRepath = true
	end
end)

RunService.Heartbeat:Connect(function(deltaTime)
	if humanoid.Health <= 0 then
		clearPath()
		return
	end

	local now = os.clock()

	if now >= nextTargetRefresh or not isTargetValid(targetRoot) then
		local newTarget = chooseTarget()
		if newTarget ~= targetRoot then
			-- Wipe stale memory; otherwise the AI inherits the previous victim's
			-- last-known position and velocity when switching targets.
			resetTargetMemory()
		end
		targetRoot = newTarget
		if not targetRoot then
			setPlayerDetected(nil, false)
		end
		nextTargetRefresh = now + TARGET_REFRESH_INTERVAL
	end

	local canSeeTarget = isTargetValid(targetRoot) and hasLineOfSight(targetRoot)
	local isActivelyHunting = canSeeTarget
		or (lastKnownPosition and now - lastSeenAt <= GIVE_UP_AFTER_LOS_LOSS)

	setPlayerDetected(getPlayerFromRoot(targetRoot), isActivelyHunting)

	if canSeeTarget ~= hadLineOfSight then
		forceRepath = true
		hadLineOfSight = canSeeTarget
	end

	-- The stop command is issued exactly once on pause entry below. Re-issuing
	-- humanoid:MoveTo every frame cancels the previous request, fires
	-- MoveToFinished(reached=false) on a loop, and that handler sets
	-- forceRepath=true continuously -- which thrashes the pathfinder the moment
	-- the pause ends.
	if now < pauseUntil then
		return
	end

	if now >= nextGlitchCheck then
		nextGlitchCheck = now + GLITCH_CHECK_INTERVAL
		if isTargetValid(targetRoot) and math.random() < GLITCH_PAUSE_CHANCE then
			pauseUntil = now + randomRange(GLITCH_PAUSE_MIN, GLITCH_PAUSE_MAX)
			clearPath()
			humanoid:MoveTo(rootPart.Position)
			return
		end
	end

	if isTargetValid(targetRoot) then
		updateTargetMemory(canSeeTarget, now)

		-- FIX: Set speed before deciding destination so the correct speed is
		-- always active regardless of which branch runs below.
		if canSeeTarget then
			humanoid.WalkSpeed = CONFIG.seenSpeed
		else
			humanoid.WalkSpeed = CONFIG.chaseSpeed
		end

		if canSeeTarget then
			updateDecision(canSeeTarget, now)
		else
			-- handleSearch returns false when the NPC gives up; in that case
			-- fall through to idle so it doesn't freeze in place.
			if not handleSearch(now) then
				handleIdle(now)
			end
		end
	else
		setPlayerDetected(nil, false)
		handleIdle(now)
	end

	advanceWaypointIfNeeded()

	-- Stuck detection.
	stuckTimer += deltaTime
	if stuckTimer >= STUCK_CHECK_INTERVAL then
		local moved = (rootPart.Position - lastStuckPosition).Magnitude
		if
			moved < STUCK_DISTANCE
			and decisionDestination
			and (rootPart.Position - decisionDestination).Magnitude > WAYPOINT_REACHED_DISTANCE
		then
			clearPath()
			forceRepath = true
			-- Route the nudge through decisionDestination instead of issuing it
			-- directly with commandMove. The unconditional `setDestination` block
			-- below would otherwise re-path to the player and clobber the nudge
			-- the same frame. Briefly gate the decision/search/idle updaters so
			-- the next iteration doesn't immediately overwrite it either.
			local nudge = rootPart.Position + randomHorizontalOffset(CONFIG.badPathOffset)
			decisionDestination = nudge
			local nudgeUntil = now + 0.5
			committedUntil = math.max(committedUntil, nudgeUntil)
			nextDecisionAt = math.max(nextDecisionAt, nudgeUntil)
			nextIdleWanderAt = math.max(nextIdleWanderAt, nudgeUntil)
			humanoid:ChangeState(Enum.HumanoidStateType.Running)
		end
		lastStuckPosition = rootPart.Position
		stuckTimer = 0
	end

	if decisionDestination then
		local directMove = canSeeTarget
			and (rootPart.Position - decisionDestination).Magnitude <= CLOSE_RANGE_DISTANCE
		setDestination(decisionDestination, directMove)
	end
end)
