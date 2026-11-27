local SOURCE = [========[local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local Player = Players.LocalPlayer
local Environment = type(getgenv) == "function" and getgenv() or _G
local Request = Environment.request or Environment.http_request
local QueueTeleport = Environment.queue_on_teleport
	or Environment.queueonteleport
	or (Environment.syn and Environment.syn.queue_on_teleport)

local MIN_ITEMS = 5
local REPORT_FILE = "servers.txt"
local TARGET_FILE = "hop_target.txt"
local HISTORY_FILE = "server_hop_history.json"
local STAY_SECONDS = 12

local SourceText = tostring(SOURCE or "")
local BRACKET_OPEN = "[" .. string.rep("=", 8) .. "["
local BRACKET_CLOSE = "]" .. string.rep("=", 8) .. "]"
local ResumeSource = "local SOURCE = " .. BRACKET_OPEN .. SourceText .. BRACKET_CLOSE .. "\n" .. SourceText

local ServerHop = {
	Busy = false,
	Target = nil,
	Mode = "Random",
	MinPlayers = 0,
	MaxPlayers = math.huge,
	Visited = {},
	BadServers = {},
	BlockedUntil = 0,
}

local ITEMS = {
	"Mysterious Arrow", "Rokakaka", "Gold Coin", "Diamond", "Stone Mask",
	"Quinton's Glove", "Steel Ball", "Dio's Diary", "Pure Rokakaka",
	"Lucky Arrow", "Lucky Stone Mask", "Rib Cage of The Saint's Corpse",
	"Ancient Scroll", "Caesar's Headband", "Clackers", "Zeppeli's Hat",
	"Christmas Present", "Green Candy", "Red Candy", "Blue Candy", "Yellow Candy",
}

local itemSet = {}
for _, name in ipairs(ITEMS) do
	itemSet[name] = true
end

local function saveHistory()
	if type(writefile) ~= "function" then return end
	pcall(function()
		writefile(HISTORY_FILE, HttpService:JSONEncode({
			visited = ServerHop.Visited,
			bad = ServerHop.BadServers,
		}))
	end)
end

pcall(function()
	if type(isfile) == "function" and isfile(HISTORY_FILE) and type(readfile) == "function" then
		local history = HttpService:JSONDecode(readfile(HISTORY_FILE))
		ServerHop.Visited = history.visited or {}
		ServerHop.BadServers = history.bad or {}
	end
end)

local function pruneHistory()
	local now = os.time()
	for id, timestamp in pairs(ServerHop.Visited) do
		if now - timestamp >= 1200 then ServerHop.Visited[id] = nil end
	end
	for id, timestamp in pairs(ServerHop.BadServers) do
		if now - timestamp >= 1800 then ServerHop.BadServers[id] = nil end
	end
end

local function fetchServers()
	local servers = {}
	local cursor = nil
	for _ = 1, 3 do
		local url = string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100&excludeFullGames=true",
			game.PlaceId
		)
		if cursor then url ..= "&cursor=" .. HttpService:UrlEncode(cursor) end

		local response
		if Request then
			response = Request({ Url = url, Method = "GET" })
		else
			response = { StatusCode = 200, Body = game:HttpGet(url) }
		end

		local status = tonumber(response.StatusCode or response.Status)
		if status == 429 then
			ServerHop.BlockedUntil = os.clock() + 60
			break
		end
		if status ~= 200 then error("Server list HTTP " .. tostring(status)) end

		local page = HttpService:JSONDecode(response.Body)
		for _, server in ipairs(page.data or {}) do
			table.insert(servers, server)
		end
		cursor = page.nextPageCursor
		if not cursor or cursor == "" then break end
		task.wait(1)
	end
	return servers
end

local function selectServer(servers)
	local tiers = {
		{ MinFPS = 55, MaxPing = 200, MinPlayers = 3, FreeSlots = 4 },
		{ MinFPS = 48, MaxPing = 280, MinPlayers = 3, FreeSlots = 3 },
		{ MinFPS = 0, MaxPing = math.huge, MinPlayers = 0, FreeSlots = 1 },
	}
	for _, tier in ipairs(tiers) do
		local candidates = {}
		for _, server in ipairs(servers) do
			local id = server.id
			local playing = tonumber(server.playing) or math.huge
			local capacity = tonumber(server.maxPlayers) or 0
			local fps = tonumber(server.fps) or 50
			local ping = tonumber(server.ping) or 150
			if type(id) == "string" and id ~= "" and id ~= game.JobId
				and not ServerHop.Visited[id] and not ServerHop.BadServers[id]
				and playing >= math.max(ServerHop.MinPlayers, tier.MinPlayers)
				and playing <= ServerHop.MaxPlayers
				and playing <= capacity - tier.FreeSlots
				and fps >= tier.MinFPS and ping <= tier.MaxPing
			then
				table.insert(candidates, server)
			end
		end
		if #candidates > 0 then
			if ServerHop.Mode == "Fewest players" then
				table.sort(candidates, function(a, b) return (tonumber(a.playing) or 0) < (tonumber(b.playing) or 0) end)
				return candidates[1]
			end
			return candidates[math.random(1, #candidates)]
		end
	end
	return nil
end

function ServerHop.Hop()
	if ServerHop.Busy then return false, "Teleport already pending" end
	if os.clock() < ServerHop.BlockedUntil then return false, "Server list cooldown" end

	ServerHop.Busy = true
	pruneHistory()
	if game.JobId ~= "" then ServerHop.Visited[game.JobId] = os.time() end

	local fetched, servers = pcall(fetchServers)
	if not fetched then
		ServerHop.Busy = false
		ServerHop.BlockedUntil = os.clock() + 15
		return false, tostring(servers)
	end

	if type(QueueTeleport) == "function" then
		local queued, queueError = pcall(QueueTeleport, ResumeSource)
		if not queued then
			ServerHop.Busy = false
			return false, tostring(queueError)
		end
	end

	local target = selectServer(servers)
	ServerHop.Target = target and target.id or nil
	if target then ServerHop.Visited[target.id] = os.time() end
	saveHistory()

	if type(writefile) == "function" then
		pcall(writefile, TARGET_FILE, ServerHop.Target or "")
	end

	local success, teleportError = pcall(function()
		if target then
			TeleportService:TeleportToPlaceInstance(game.PlaceId, target.id, Player)
		else
			TeleportService:Teleport(game.PlaceId, Player)
		end
	end)

	if not success then
		if target then
			ServerHop.BadServers[target.id] = os.time()
			saveHistory()
		end
		ServerHop.Busy = false
		ServerHop.Target = nil
	end
	return success, teleportError
end

TeleportService.TeleportInitFailed:Connect(function(player, result, message)
	if player ~= Player or not ServerHop.Busy then return end
	if ServerHop.Target then
		ServerHop.BadServers[ServerHop.Target] = os.time()
		saveHistory()
	end
	ServerHop.Target = nil
	ServerHop.Busy = false
	warn(result.Name .. ": " .. message)
end)

local function isVisible(part)
	if not part or not part.Parent then return false end
	if part:IsA("BasePart") and part.Transparency >= 0.5 then return false end
	return true
end

local function ownedByPlayer(part)
	for _, other in ipairs(Players:GetPlayers()) do
		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and (part.Position - root.Position).Magnitude < 12 then return true end
	end
	return false
end

local function countItems()
	local total = 0
	local seen = {}
	for _, obj in ipairs(workspace:GetDescendants()) do
		if itemSet[obj.Name] then
			local part = obj:IsA("BasePart") and obj or obj:FindFirstChildWhichIsA("BasePart", true)
			if part and part:IsA("BasePart") and not seen[part] then
				seen[part] = true
				if isVisible(part) and not ownedByPlayer(part) then total += 1 end
			end
		end
	end
	return total
end

local function report(count, server)
	local id = (server and server.id) or game.JobId
	local link = string.format("roblox://experiences/start?placeId=%d&gameInstanceId=%s", game.PlaceId, id)
	local line = table.concat({
		os.date("!%Y-%m-%d %H:%M:%S"),
		tostring(game.PlaceId),
		id,
		tostring(count),
		tostring(server and server.playing or ""),
		tostring(server and server.fps or ""),
		tostring(server and server.ping or ""),
		link,
	}, "|")

	local old = ""
	if type(isfile) == "function" and isfile(REPORT_FILE) and type(readfile) == "function" then
		pcall(function() old = readfile(REPORT_FILE) end)
	end
	if type(writefile) == "function" then
		pcall(writefile, REPORT_FILE, old .. line .. "\n")
	end
	pcall(function() if type(setclipboard) == "function" then setclipboard(link) end end)
	print("[SCOUT] " .. line)
end

task.spawn(function()
	local character = Player.Character or Player.CharacterAdded:Wait()
	character:WaitForChild("HumanoidRootPart", 15)
	task.wait(3)

	while true do
		if os.clock() < ServerHop.BlockedUntil then
			task.wait(10)
			continue
		end

		local count = countItems()
		if count >= MIN_ITEMS then
			report(count, nil)
		end

		local ok, err = ServerHop.Hop()
		if not ok then
			warn("[SCOUT] hop failed: " .. tostring(err))
			task.wait(15)
		else
			task.wait(STAY_SECONDS)
		end
	end
end)

print("[SCOUT] ready: min items " .. tostring(MIN_ITEMS) .. ", report -> " .. REPORT_FILE)
]========]
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local Player = Players.LocalPlayer
local Environment = type(getgenv) == "function" and getgenv() or _G
local Request = Environment.request or Environment.http_request
local QueueTeleport = Environment.queue_on_teleport
	or Environment.queueonteleport
	or (Environment.syn and Environment.syn.queue_on_teleport)

local MIN_ITEMS = 5
local REPORT_FILE = "servers.txt"
local TARGET_FILE = "hop_target.txt"
local HISTORY_FILE = "server_hop_history.json"
local STAY_SECONDS = 12

local SourceText = tostring(SOURCE or "")
local BRACKET_OPEN = "[" .. string.rep("=", 8) .. "["
local BRACKET_CLOSE = "]" .. string.rep("=", 8) .. "]"
local ResumeSource = "local SOURCE = " .. BRACKET_OPEN .. SourceText .. BRACKET_CLOSE .. "\n" .. SourceText

local ServerHop = {
	Busy = false,
	Target = nil,
	Mode = "Random",
	MinPlayers = 0,
	MaxPlayers = math.huge,
	Visited = {},
	BadServers = {},
	BlockedUntil = 0,
}

local ITEMS = {
	"Mysterious Arrow", "Rokakaka", "Gold Coin", "Diamond", "Stone Mask",
	"Quinton's Glove", "Steel Ball", "Dio's Diary", "Pure Rokakaka",
	"Lucky Arrow", "Lucky Stone Mask", "Rib Cage of The Saint's Corpse",
	"Ancient Scroll", "Caesar's Headband", "Clackers", "Zeppeli's Hat",
	"Christmas Present", "Green Candy", "Red Candy", "Blue Candy", "Yellow Candy",
}

local itemSet = {}
for _, name in ipairs(ITEMS) do
	itemSet[name] = true
end

local function saveHistory()
	if type(writefile) ~= "function" then return end
	pcall(function()
		writefile(HISTORY_FILE, HttpService:JSONEncode({
			visited = ServerHop.Visited,
			bad = ServerHop.BadServers,
		}))
	end)
end

pcall(function()
	if type(isfile) == "function" and isfile(HISTORY_FILE) and type(readfile) == "function" then
		local history = HttpService:JSONDecode(readfile(HISTORY_FILE))
		ServerHop.Visited = history.visited or {}
		ServerHop.BadServers = history.bad or {}
	end
end)

local function pruneHistory()
	local now = os.time()
	for id, timestamp in pairs(ServerHop.Visited) do
		if now - timestamp >= 1200 then ServerHop.Visited[id] = nil end
	end
	for id, timestamp in pairs(ServerHop.BadServers) do
		if now - timestamp >= 1800 then ServerHop.BadServers[id] = nil end
	end
end

local function fetchServers()
	local servers = {}
	local cursor = nil
	for _ = 1, 3 do
		local url = string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100&excludeFullGames=true",
			game.PlaceId
		)
		if cursor then url ..= "&cursor=" .. HttpService:UrlEncode(cursor) end

		local response
		if Request then
			response = Request({ Url = url, Method = "GET" })
		else
			response = { StatusCode = 200, Body = game:HttpGet(url) }
		end

		local status = tonumber(response.StatusCode or response.Status)
		if status == 429 then
			ServerHop.BlockedUntil = os.clock() + 60
			break
		end
		if status ~= 200 then error("Server list HTTP " .. tostring(status)) end

		local page = HttpService:JSONDecode(response.Body)
		for _, server in ipairs(page.data or {}) do
			table.insert(servers, server)
		end
		cursor = page.nextPageCursor
		if not cursor or cursor == "" then break end
		task.wait(1)
	end
	return servers
end

local function selectServer(servers)
	local tiers = {
		{ MinFPS = 55, MaxPing = 200, MinPlayers = 3, FreeSlots = 4 },
		{ MinFPS = 48, MaxPing = 280, MinPlayers = 3, FreeSlots = 3 },
		{ MinFPS = 0, MaxPing = math.huge, MinPlayers = 0, FreeSlots = 1 },
	}
	for _, tier in ipairs(tiers) do
		local candidates = {}
		for _, server in ipairs(servers) do
			local id = server.id
			local playing = tonumber(server.playing) or math.huge
			local capacity = tonumber(server.maxPlayers) or 0
			local fps = tonumber(server.fps) or 50
			local ping = tonumber(server.ping) or 150
			if type(id) == "string" and id ~= "" and id ~= game.JobId
				and not ServerHop.Visited[id] and not ServerHop.BadServers[id]
				and playing >= math.max(ServerHop.MinPlayers, tier.MinPlayers)
				and playing <= ServerHop.MaxPlayers
				and playing <= capacity - tier.FreeSlots
				and fps >= tier.MinFPS and ping <= tier.MaxPing
			then
				table.insert(candidates, server)
			end
		end
		if #candidates > 0 then
			if ServerHop.Mode == "Fewest players" then
				table.sort(candidates, function(a, b) return (tonumber(a.playing) or 0) < (tonumber(b.playing) or 0) end)
				return candidates[1]
			end
			return candidates[math.random(1, #candidates)]
		end
	end
	return nil
end

function ServerHop.Hop()
	if ServerHop.Busy then return false, "Teleport already pending" end
	if os.clock() < ServerHop.BlockedUntil then return false, "Server list cooldown" end

	ServerHop.Busy = true
	pruneHistory()
	if game.JobId ~= "" then ServerHop.Visited[game.JobId] = os.time() end

	local fetched, servers = pcall(fetchServers)
	if not fetched then
		ServerHop.Busy = false
		ServerHop.BlockedUntil = os.clock() + 15
		return false, tostring(servers)
	end

	if type(QueueTeleport) == "function" then
		local queued, queueError = pcall(QueueTeleport, ResumeSource)
		if not queued then
			ServerHop.Busy = false
			return false, tostring(queueError)
		end
	end

	local target = selectServer(servers)
	ServerHop.Target = target and target.id or nil
	if target then ServerHop.Visited[target.id] = os.time() end
	saveHistory()

	if type(writefile) == "function" then
		pcall(writefile, TARGET_FILE, ServerHop.Target or "")
	end

	local success, teleportError = pcall(function()
		if target then
			TeleportService:TeleportToPlaceInstance(game.PlaceId, target.id, Player)
		else
			TeleportService:Teleport(game.PlaceId, Player)
		end
	end)

	if not success then
		if target then
			ServerHop.BadServers[target.id] = os.time()
			saveHistory()
		end
		ServerHop.Busy = false
		ServerHop.Target = nil
	end
	return success, teleportError
end

TeleportService.TeleportInitFailed:Connect(function(player, result, message)
	if player ~= Player or not ServerHop.Busy then return end
	if ServerHop.Target then
		ServerHop.BadServers[ServerHop.Target] = os.time()
		saveHistory()
	end
	ServerHop.Target = nil
	ServerHop.Busy = false
	warn(result.Name .. ": " .. message)
end)

local function isVisible(part)
	if not part or not part.Parent then return false end
	if part:IsA("BasePart") and part.Transparency >= 0.5 then return false end
	return true
end

local function ownedByPlayer(part)
	for _, other in ipairs(Players:GetPlayers()) do
		local character = other.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and (part.Position - root.Position).Magnitude < 12 then return true end
	end
	return false
end

local function countItems()
	local total = 0
	local seen = {}
	for _, obj in ipairs(workspace:GetDescendants()) do
		if itemSet[obj.Name] then
			local part = obj:IsA("BasePart") and obj or obj:FindFirstChildWhichIsA("BasePart", true)
			if part and part:IsA("BasePart") and not seen[part] then
				seen[part] = true
				if isVisible(part) and not ownedByPlayer(part) then total += 1 end
			end
		end
	end
	return total
end

local function report(count, server)
	local id = (server and server.id) or game.JobId
	local link = string.format("roblox://experiences/start?placeId=%d&gameInstanceId=%s", game.PlaceId, id)
	local line = table.concat({
		os.date("!%Y-%m-%d %H:%M:%S"),
		tostring(game.PlaceId),
		id,
		tostring(count),
		tostring(server and server.playing or ""),
		tostring(server and server.fps or ""),
		tostring(server and server.ping or ""),
		link,
	}, "|")

	local old = ""
	if type(isfile) == "function" and isfile(REPORT_FILE) and type(readfile) == "function" then
		pcall(function() old = readfile(REPORT_FILE) end)
	end
	if type(writefile) == "function" then
		pcall(writefile, REPORT_FILE, old .. line .. "\n")
	end
	pcall(function() if type(setclipboard) == "function" then setclipboard(link) end end)
	print("[SCOUT] " .. line)
end

task.spawn(function()
	local character = Player.Character or Player.CharacterAdded:Wait()
	character:WaitForChild("HumanoidRootPart", 15)
	task.wait(3)

	while true do
		if os.clock() < ServerHop.BlockedUntil then
			task.wait(10)
			continue
		end

		local count = countItems()
		if count >= MIN_ITEMS then
			report(count, nil)
		end

		local ok, err = ServerHop.Hop()
		if not ok then
			warn("[SCOUT] hop failed: " .. tostring(err))
			task.wait(15)
		else
			task.wait(STAY_SECONDS)
		end
	end
end)

print("[SCOUT] ready: min items " .. tostring(MIN_ITEMS) .. ", report -> " .. REPORT_FILE)
