-- MVS NOCTURNE v9.3 | Flat Halloween interface
-- Transfer continuation requires executor queue support. No automatic launch on game startup.
local BODY = [==[
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local UIS          = game:GetService("UserInputService")
local HttpService  = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local CoreGui      = game:GetService("CoreGui")
local RepStorage   = game:GetService("ReplicatedStorage")

if not game:IsLoaded() then game.Loaded:Wait() end
local LP = Players.LocalPlayer
while not LP do task.wait(); LP = Players.LocalPlayer end
local Camera = workspace.CurrentCamera
while not Camera do task.wait(); Camera = workspace.CurrentCamera end

local G = (getgenv and getgenv()) or _G

local StartupClock = os.clock()
local CFG = {
    GameMode = "Auto", KillAura = false, AuraRange = 8, ShowAuraRange = false, AuraDelay = 0.3,
    EspOn = true, NameTags = true, HideTeam = false, TeamCheck = true,
    AimbotOn = true, AimbotKey = Enum.KeyCode.Q, AimPart = "Head",
    WallCheck = true, FovOn = true, FovRadius = 150,
    FovColor = Color3.fromRGB(255, 125, 25),
    MenuKey = Enum.KeyCode.RightShift, UnloadKey = Enum.KeyCode.End,
    FireCooldown = 0.15,
    VisualInterval = 0.75, MaxHighlights = 12,
}

local KeyFields = {"AimbotKey", "MenuKey", "UnloadKey"}
local function encodeBinding(binding)
    if binding.EnumType == Enum.UserInputType then return "Input." .. binding.Name end
    return binding.Name
end
local function decodeBinding(value)
    if type(value) ~= "string" then return nil end
    if value:sub(1,6) == "Input." then
        local name = value:sub(7)
        if name ~= "MouseButton1" and name ~= "MouseButton2" and name ~= "MouseButton3" then return nil end
        return Enum.UserInputType[name]
    end
    local ok, key = pcall(function() return Enum.KeyCode[value] end)
    if not ok or not key or key == Enum.KeyCode.Unknown or key == Enum.KeyCode.Escape then return nil end
    return key
end
local function bindingFromInput(input)
    local kind = input.UserInputType
    if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.MouseButton2 or kind == Enum.UserInputType.MouseButton3 then return kind end
    if kind == Enum.UserInputType.Keyboard then
        local key = input.KeyCode
        if key ~= Enum.KeyCode.Unknown and key ~= Enum.KeyCode.Escape then return key end
    end
    return nil
end
local function bindingLabel(binding)
    local labels = {MouseButton1="Mouse 1", MouseButton2="Mouse 2", MouseButton3="Mouse 3", RightShift="RShift", LeftShift="LShift"}
    return labels[binding.Name] or binding.Name
end
local SettingsLive, SavePending = true, false
local SavedUi = {}
local function readJson(path)
    if not readfile or not isfile then return nil end
    local ok, value = pcall(function() if isfile(path) then return HttpService:JSONDecode(readfile(path)) end end)
    if ok and type(value) == "table" then return value end
end
local stored = G.MVS_CONFIG or readJson("mvs_settings.json")
if type(stored) ~= "table" then stored = G.MVS_SETTINGS or readJson("mvs_keys.json") end
if type(stored) == "table" then
    for key, default in pairs(CFG) do
        if type(default) == "boolean" and type(stored[key]) == "boolean" then CFG[key] = stored[key] end
    end
    local ranges = {AuraRange={2,25}, AuraDelay={0.15,1}, FovRadius={50,600}, FireCooldown={0.05,1}, VisualInterval={0.25,2}, MaxHighlights={1,31}}
    for key, range in pairs(ranges) do
        local value = stored[key]
        if type(value) == "number" and value == value then CFG[key] = math.clamp(value,range[1],range[2]) end
    end
    if stored.GameMode == "Auto" or stored.GameMode == "Duels" or stored.GameMode == "Infection" then CFG.GameMode=stored.GameMode end
    if stored.AimPart == "Head" or stored.AimPart == "HumanoidRootPart" then CFG.AimPart = stored.AimPart end
    local keys, used, valid = {}, {}, true
    for _, field in ipairs(KeyFields) do
        local key = decodeBinding(stored[field] or encodeBinding(CFG[field]))
        if not key or used[key] then valid = false; break end
        keys[field] = key; used[key] = true
    end
    if valid then for field, key in pairs(keys) do CFG[field] = key end end
    if type(stored.Ui) == "table" and type(stored.Ui.Tab) == "string" then SavedUi.Tab = stored.Ui.Tab end
end
local function settingsSnapshot()
    local out = {Version = 2, Ui = SavedUi}
    for key, value in pairs(CFG) do
        if type(value) == "boolean" or type(value) == "number" or type(value) == "string" then out[key] = value end
    end
    for _, field in ipairs(KeyFields) do out[field] = encodeBinding(CFG[field]) end
    return out
end
local function FlushSettings()
    local snapshot = settingsSnapshot()
    G.MVS_CONFIG = snapshot
    if writefile then
        local ok = pcall(function() writefile("mvs_settings.json", HttpService:JSONEncode(snapshot)) end)
        if not ok then warn("[MVS] Settings file could not be written") end
    end
end
local function SaveSettings()
    G.MVS_CONFIG = settingsSnapshot()
    if SavePending or not SettingsLive then return end
    SavePending = true
    task.delay(0.4, function()
        SavePending = false
        if SettingsLive then FlushSettings() end
    end)
end

local State = {
    Running = true, MenuOpen = true, Minimized = false,
    Conns = {}, Highlights = {}, Tags = {}, Murderers = {}, Roles = {},
    FovCircle = nil, LastFire = 0, Firing = false, Capturing = nil,
    RosterDirty = true, Tweens = {},
    TeamCache = {}, ManualTeams = {}, RemoteTeams = {}, MatchRoster = {},
    TeamStamp = 0, EspBusy = false, VisualDirty = true,
    Metrics = {StartupMs = 0, VisualPassWallMs = 0, VisualPeakWallMs = 0, Errors = 0},
}

if G.MVS_KILL then pcall(G.MVS_KILL) end
task.wait()
local function safe(fn, lbl)
    local ok, err = pcall(fn)
    if not ok then
        State.Metrics.Errors = State.Metrics.Errors + 1
        warn("[MVS] " .. tostring(lbl) .. ": " .. tostring(err))

    end
end
local function alive(p)
    local c = p and p.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    return c and c:FindFirstChild("HumanoidRootPart") and h and h.Health > 0
end

local function getRoot(p)
    local c = p and p.Character
    return c and (c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso"))
end
local TEAM_ATTRS = {"TeamId", "TeamID", "teamId", "MatchTeam", "MatchTeamId", "Team", "team", "TeamName", "Side", "Faction", "Squad"}
local UNKNOWN_COLOR = Color3.fromRGB(153, 160, 171)
local function normalizeTeam(value)
    if typeof(value) == "Instance" then
        if value:IsA("Team") then return "team:" .. value.Name:lower() end
        return nil
    end
    if type(value) == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return nil end
        return tostring(value)
    end
    if type(value) ~= "string" then return nil end
    local key = value:match("^%s*(.-)%s*$"):lower()
    if key == "" or key == "none" or key == "nil" or key == "neutral" or key == "lobby" or key == "spectator" or key == "spectators" or key == "unassigned" then return nil end
    return key
end

local function candidate(p, field)
    if field == "RobloxTeam" then
        if not p.Neutral and p.Team then return normalizeTeam(p.Team.Name) end
        return nil
    end
    local playerValue = normalizeTeam(p:GetAttribute(field))
    local charValue = p.Character and normalizeTeam(p.Character:GetAttribute(field))
    if playerValue and charValue and playerValue ~= charValue then return nil end
    if charValue or playerValue then return charValue or playerValue end
    -- Bounded, direct lookup only. Never recursively scan the character tree.
    local value = p:FindFirstChild(field)
    if not value and p.Character then value = p.Character:FindFirstChild(field) end
    if value and (value:IsA("StringValue") or value:IsA("IntValue") or value:IsA("NumberValue") or value:IsA("ObjectValue")) then
        return normalizeTeam(value.Value)
    end
    return nil
end

local function infectionRole(player)
    local found
    local function accept(role)
        if found and found~=role then found="CONFLICT" else found=role end
    end
    for _,node in ipairs({player,player.Character}) do
        for _,field in ipairs({"IsZombie","Zombie","IsInfected","Infected"}) do
            local value=node:GetAttribute(field)
            if value==nil then local child=node:FindFirstChild(field); if child and child:IsA("BoolValue") then value=child.Value end end
            if type(value)=="boolean" then accept(value and "ZOMBIE" or "HUMAN") end
        end
        for _,field in ipairs({"InfectionRole","Role","RoleName"}) do
            local value=node:GetAttribute(field)
            if value==nil then local child=node:FindFirstChild(field); if child and child:IsA("StringValue") then value=child.Value end end
            if type(value)=="string" then
                local name=value:lower()
                if name=="zombie" or name=="infected" then accept("ZOMBIE")
                elseif name=="human" or name=="survivor" then accept("HUMAN") end
            end
        end
    end
    if found=="CONFLICT" then return nil end
    return found
end
local function teammateMarker(player)
    local char=player.Character
    local root=char and char:FindFirstChild("HumanoidRootPart")
    local marker=root and root:FindFirstChild("TeammateIconPart")
    return marker~=nil and marker:IsA("BasePart")
end
local function nativeTeamRelations()
    local all=Players:GetPlayers()
    local relations,hasIcon={},false
    for _,player in ipairs(all) do
        if player~=LP and teammateMarker(player) then relations[player]="TEAM"; hasIcon=true end
    end
    local roster=State.MatchRoster or {}
    -- Infection does not require a TeamLocal roster or balanced team sizes.
    local infection=CFG.GameMode=="Infection" or (CFG.GameMode=="Auto" and State.InfectionActive)
    local directScope=infection or (CFG.GameMode=="Auto" and #roster==0 and hasIcon)
    State.DirectIconScope=directScope
    if directScope then
        local memory=State.InfectionMemory or {}
        if State.InfectionOwner~=LP.Character then
            memory={}; State.InfectionMemory=memory; State.InfectionOwner=LP.Character; State.IconMissingSince={}
        end
        local missing=State.IconMissingSince or {}; State.IconMissingSince=missing
        local established=next(memory)~=nil
        local evidence=hasIcon or established
        for _,player in ipairs(all) do
            if player~=LP then
                if relations[player]=="TEAM" then
                    memory[player.UserId]="TEAM"; missing[player.UserId]=nil
                elseif alive(player) then
                    if evidence then
                        missing[player.UserId]=missing[player.UserId] or os.clock()
                        if os.clock()-missing[player.UserId]>=0.25 then memory[player.UserId]="ENEMY" end
                    end
                    relations[player]=memory[player.UserId]
                else
                    relations[player]=memory[player.UserId]
                    missing[player.UserId]=nil
                end
            end
        end
        State.InfectionMemory=memory
        return relations
    end
    local memory=State.NativeMemory or {}
    local signature,ready,hasSelf,count,allies={},true,false,0,0
    for _,player in ipairs(roster) do
        count=count+1; if player==LP then hasSelf=true end
        local char=player.Character
        local root=char and char:FindFirstChild("HumanoidRootPart")
        if player.Parent~=Players or not char or not char.Parent or not root then ready=false end
        if relations[player]=="TEAM" then allies=allies+1 end
        table.insert(signature,tostring(player.UserId)..":"..tostring(relations[player]=="TEAM"))
    end
    local expected=(count>=2 and count<=8 and count%2==0) and count/2-1 or nil
    if expected and allies>expected then memory={}; State.NativeMemory={} end
    local valid=ready and hasSelf and expected~=nil and allies==expected
    local key=table.concat(signature,"|")
    local stable=valid and State.MarkerCandidate==key and os.clock()-(State.MarkerSince or os.clock())>=0.35
    if valid and State.MarkerCandidate~=key then State.MarkerCandidate=key; State.MarkerSince=os.clock() end
    if not valid then State.MarkerCandidate=nil; State.MarkerSince=nil end
    for _,player in ipairs(roster) do
        if player~=LP then
            if stable then
                -- Confirmed duel teams survive death; a new positive marker can override an old opponent.
                relations[player]=relations[player] or memory[player.UserId] or "ENEMY"
                memory[player.UserId]=relations[player]
            else relations[player]=relations[player] or memory[player.UserId] end
        end
    end
    State.NativeMemory=memory
    return relations
end

local function refreshTeamCache(force)
    if not force and os.clock() - State.TeamStamp < 0.15 then return end
    State.TeamStamp = os.clock()
    local players = Players:GetPlayers()
    local infections,hasZombie,hasHuman={},false,false
    for _,p in ipairs(players) do
        local role=infectionRole(p); infections[p]=role
        if role=="ZOMBIE" then hasZombie=true elseif role=="HUMAN" then hasHuman=true end
    end
    local infectionMode=CFG.GameMode=="Infection" or (CFG.GameMode~="Duels" and hasZombie and hasHuman)
    State.InfectionActive=infectionMode
    local native=nativeTeamRelations()
    local cache = {}
    for _, p in ipairs(players) do cache[p] = {relation = p == LP and "SELF" or "UNKNOWN", source = "No verified team data"} end
    local fields = {}
    for _, field in ipairs(TEAM_ATTRS) do table.insert(fields, field) end
    table.insert(fields, "RobloxTeam")
    for _, field in ipairs(fields) do
        local mine = candidate(LP, field)
        if mine then
            local values, distinct, count = {}, {}, 0
            for _, p in ipairs(players) do
                local value = candidate(p, field)
                values[p] = value
                if value and not distinct[value] then distinct[value] = true; count = count + 1 end
            end
            -- A shared lobby bucket cannot establish opponents.
            if count >= 2 then
                for _, p in ipairs(players) do
                    if p ~= LP and values[p] then
                        local relation = values[p] == mine and "TEAM" or "ENEMY"
                        local row = cache[p]
                        if row.relation == "UNKNOWN" then
                            row.relation = relation; row.source = field; row.key = values[p]
                        elseif row.relation ~= relation then
                            row.conflict = true
                        end
                    end
                end
            end
        end
    end
    for _, p in ipairs(players) do
        local row = cache[p]
        if row.conflict then row.relation = "UNKNOWN"; row.source = "Conflicting team fields" end
        -- Explicit, current-session teammate override; never persists into a new match.
        if native[p] then row.relation = native[p]; row.source = "Native TeammateIconPart" end
        local remote = State.RemoteTeams[p.UserId]
        local myRemote = State.RemoteTeams[LP.UserId]
        if remote and myRemote then
            row.relation = remote == myRemote and "TEAM" or "ENEMY"; row.source = "Explicit remote teams"
        end
        if infectionMode and p~=LP then
            local mine,theirs=infections[LP],infections[p]
            if mine and theirs then
                row.relation=mine==theirs and "TEAM" or "ENEMY"; row.source="Infection / "..theirs
            elseif native[p] then row.relation=native[p]; row.source="Infection / native teammate icon"
            else row.relation="UNKNOWN"; row.source="Infection role unavailable" end
        end
        local manual = State.ManualTeams[p.UserId]
        if manual then row.relation = manual == "ENEMY" and "ENEMY" or "TEAM"; row.source = "Manual selection" end
    end
    State.TeamCache = cache
end

local function consumeTeamPayload(data)
    if type(data) ~= "table" then return false end
    -- TeamLocal's flat array supplies match membership, not team order.
    local roster, seen, flat = {}, {}, true
    for key, value in pairs(data) do
        if type(key) ~= "number" or typeof(value) ~= "Instance" or not value:IsA("Player") or seen[value] then flat = false; break end
        seen[value] = true; table.insert(roster, value)
        if #roster > 16 then flat = false; break end
    end
    if flat and #roster > 0 and seen[LP] then
        local same = #roster == #(State.MatchRoster or {})
        for _, player in ipairs(State.MatchRoster or {}) do if not seen[player] then same = false end end
        State.MatchRoster = roster
        if not same then State.InfectionMemory={}; State.IconMissingSince={}; State.InfectionCandidate=nil; State.NativeMemory = {}; State.MarkerCandidate = nil; State.MarkerSince = nil; State.RemoteTeams = {}; State.ManualTeams = {} end
        State.TeamStamp = 0; State.VisualDirty = true
        return false
    end
    local proposed, distinct = {}, {}
    local function resolve(ref)
        if typeof(ref) == "Instance" and ref:IsA("Player") then return ref end
        if type(ref) == "number" then return Players:GetPlayerByUserId(ref) end
        if type(ref) == "string" then return Players:FindFirstChild(ref) or Players:GetPlayerByUserId(tonumber(ref) or -1) end
        return nil
    end
    local function add(ref, value)
        local player, key = resolve(ref), normalizeTeam(value)
        if not player or not key then return false end
        if proposed[player.UserId] and proposed[player.UserId] ~= key then return false end
        proposed[player.UserId] = key; distinct[key] = true; return true
    end
    if type(data.Teams) == "table" then
        local count = 0
        for key, group in pairs(data.Teams) do
            count = count + 1; if count > 16 then return false end
            if type(group) ~= "table" then return false end
            local roster = group.Players or group.Members
            if type(roster) ~= "table" then return false end
            local n = 0
            for _, ref in pairs(roster) do
                n = n + 1; if n > 64 or not add(ref, group.TeamId or group.TeamName or key) then return false end
            end
        end
    else
        local count = 0
        for ref, record in pairs(data) do
            count = count + 1; if count > 64 then return false end
            if type(record) == "table" then
                local value = record.TeamId or record.TeamID or record.TeamName or record.Team
                if value ~= nil and not add(record.Player or record.UserId or record.Name or ref, value) then return false end
            end
        end
    end
    local count = 0; for _ in pairs(distinct) do count = count + 1 end
    if count < 2 or not proposed[LP.UserId] then return false end
    State.RemoteTeams = proposed; State.TeamStamp = 0; State.VisualDirty = true
    return true
end

local function teamKey(p)
    local row = State.TeamCache[p]
    return row and row.key or nil
end
local function isTeammate(p)
    local row = State.TeamCache[p]
    return row and row.relation == "TEAM" or false
end
local function canTarget(p)
    if p == LP then return false end
    if State.ManualTeams[p.UserId] and State.ManualTeams[p.UserId] ~= "ENEMY" then return false end
    if not CFG.TeamCheck then return true end
    local row = State.TeamCache[p]
    return row ~= nil and row.relation == "ENEMY"
end

local function findWeapon()
    local char = LP.Character
    if char then
        for _, t in ipairs(char:GetChildren()) do
            if t:IsA("Tool") then
                if t:FindFirstChild("fire") then return t, "gun" end
                if t:FindFirstChild("Slash") then return t, "knife" end
            end
        end
    end
    for _, t in ipairs(LP.Backpack:GetChildren()) do
        if t:IsA("Tool") and t:FindFirstChild("fire") then return t, "gun" end
    end
    for _, t in ipairs(LP.Backpack:GetChildren()) do
        if t:IsA("Tool") and t:FindFirstChild("Slash") then return t, "knife" end
    end
    return nil, nil
end

local Unload
local function ArmPersist()
    local enqueue = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
    if not enqueue then State.TeleportStatus = "Unsupported: executor has no queue API"; return end
    if not State.Running or G.MVS_OFF then return end
    if G.MVS_QJOB == game.JobId then return end
    local src = G.MVS_SRC
    if not src and readfile then
        local ok, s = pcall(readfile, "mvs_v72_auto.lua")
        if ok then src = s end
    end
    if not src then return end
    G.MVS_QJOB = game.JobId
    local loader = "local g=(getgenv and getgenv()) or _G; if g.MVS_OFF then return end; if isfile and readfile then local ok,v=pcall(function() return isfile(\"mvs_v72_disabled.flag\") and readfile(\"mvs_v72_disabled.flag\") == \"disabled\" end); if ok and v then return end end; g.MVS_SRC="
        .. string.format("%q", src) .. "; loadstring(g.MVS_SRC)()"
    if readfile and isfile and writefile then
        local ok, exists = pcall(isfile, "mvs_v72_auto.lua")
        if ok and exists then
            loader = 'if not game:IsLoaded() then game.Loaded:Wait() end; local g=(getgenv and getgenv()) or _G; if g.MVS_OFF then return end; local ok,disabled=pcall(function() return isfile("mvs_v72_disabled.flag") and readfile("mvs_v72_disabled.flag")=="disabled" end); if ok and disabled then return end; local ok,src=pcall(readfile,"mvs_v72_auto.lua"); if ok then g.MVS_SRC=src; loadstring(src)() end'
        end
    end
    local session = G.MVS_SESSION
    if session and readfile and writefile then
        loader = 'local g=(getgenv and getgenv()) or _G; local ok,id=pcall(readfile,"mvs_v72_session.id"); if not ok or id~=' .. string.format("%q", session) .. ' then return end; g.MVS_SESSION=id; ' .. loader
    end
    local queued, result = pcall(enqueue, loader)
    if not queued or result == false then G.MVS_QJOB = nil; State.TeleportStatus = "Queue failed"
    else State.TeleportStatus = "Armed / X stops transfer reload" end
end
local COLOR_MURDER = Color3.fromRGB(255, 40, 40)
local COLOR_ENEMY  = Color3.fromRGB(255, 165, 30)
local COLOR_TEAM   = Color3.fromRGB(70, 235, 130)

local function statusOf(p)
    local row = State.TeamCache[p]
    if isTeammate(p) then return "TEAM", COLOR_TEAM end
    if not row or row.relation == "UNKNOWN" then return "UNKNOWN", UNKNOWN_COLOR end
    if State.Murderers[p] then return "MURDERER", COLOR_MURDER end
    return "ENEMY", COLOR_ENEMY
end

local function removeVisuals(p)
    if State.Highlights[p] then pcall(function() State.Highlights[p]:Destroy() end); State.Highlights[p] = nil end
    if State.Tags[p] then pcall(function() State.Tags[p].gui:Destroy() end); State.Tags[p] = nil end
end

local function makeVisuals(p)
    local char = p.Character
    if not char or not char.Parent then return end
    local hl = State.Highlights[p]
    if hl and (not hl.Parent or hl.Adornee ~= char) then removeVisuals(p); hl = nil end
    if not hl then
        hl = Instance.new("Highlight")
        hl.FillTransparency = 0.65; hl.OutlineTransparency = 0.15
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Adornee = char; hl.Parent = CoreGui; State.Highlights[p] = hl
    end
    local head = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
    local tag = State.Tags[p]
    if tag and (not tag.gui.Parent or not tag.lbl.Parent) then
        pcall(function() tag.gui:Destroy() end); State.Tags[p] = nil; tag = nil
    end
    if head and not tag then
        local gui = Instance.new("BillboardGui")
        gui.Size = UDim2.fromOffset(180, 40)
        gui.StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0)
        gui.AlwaysOnTop = true; gui.MaxDistance = 3000
        gui.Adornee = head; gui.Parent = CoreGui
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.fromScale(1, 1); lbl.BackgroundTransparency = 1
        lbl.Font = Enum.Font.GothamMedium; lbl.TextSize = 11
        lbl.TextStrokeTransparency = 0.35; lbl.Parent = gui
        State.Tags[p] = {gui = gui, lbl = lbl}; tag = State.Tags[p]
    end
    if tag then
        tag.gui.Adornee = head
        tag.gui.Enabled = CFG.NameTags and head ~= nil
    end
end

local function ESP_Update()
    refreshTeamCache()
    local visualCount = 0
    for p in pairs(State.Highlights) do
        if not p or not p.Parent then removeVisuals(p) end
    end
    if not CFG.EspOn then
        for p in pairs(State.Highlights) do removeVisuals(p) end
        return
    end
    local myRoot = getRoot(LP)
    for _, p in ipairs(Players:GetPlayers()) do
        if p == LP or not p.Character or not p.Character.Parent then
            removeVisuals(p)
        else
            local label, col = statusOf(p)
            if (CFG.HideTeam and label == "TEAM") or visualCount >= CFG.MaxHighlights then
                removeVisuals(p)
            else
                visualCount = visualCount + 1
                local hl = State.Highlights[p]
                local created = not hl or not hl.Parent or hl.Adornee ~= p.Character
                if not State.Running then return end
                makeVisuals(p); hl = State.Highlights[p]
                if created then
                    task.wait()
                    if not State.Running then removeVisuals(p); return end
                end
                local humanoid = p.Character and p.Character:FindFirstChildOfClass("Humanoid")
                local visible = humanoid ~= nil and humanoid.Health > 0
                if hl then hl.Enabled = visible end
                if hl then hl.FillColor = col; hl.OutlineColor = col end
                local tag = State.Tags[p]
                if tag then
                    tag.gui.Enabled = CFG.NameTags and visible and tag.gui.Adornee ~= nil
                    local dist = (myRoot and getRoot(p)) and math.floor((myRoot.Position - getRoot(p).Position).Magnitude) or 0
                    tag.lbl.Text = string.format("%s  ·  %dm\n[%s]", p.Name, dist, label)
                    tag.lbl.TextColor3 = col
                end
            end
        end
    end
end

local function queueTeamRefresh()
    if State.TeamRefreshQueued or not State.Running then return end
    State.TeamRefreshQueued=true
    task.defer(function()
        State.TeamRefreshQueued=false
        if not State.Running then return end
        State.TeamStamp=0; refreshTeamCache(true); State.VisualDirty=true
    end)
end
local function disconnectTeamWatch(player)
    local watches=State.TeamWatches and State.TeamWatches[player]
    if not watches then return end
    for _,bag in pairs(watches) do for _,connection in ipairs(bag) do connection:Disconnect() end end
    State.TeamWatches[player]=nil
end
local function ESP_Init()
    State.TeamWatches={}
    local attributeNames={IsZombie=true,Zombie=true,IsInfected=true,Infected=true,InfectionRole=true,Role=true,RoleName=true}
    for _,name in ipairs(TEAM_ATTRS) do attributeNames[name]=true end
    local function hookChar(player)
        disconnectTeamWatch(player)
        local watches={player={},character={}}; State.TeamWatches[player]=watches
        local function attachCharacter(char)
            for _,connection in ipairs(watches.character) do connection:Disconnect() end
            watches.character={}
            if not char or not State.Running then return end
            local function changed(node)
                if node.Name=="TeammateIconPart" or node.Name=="HumanoidRootPart" or node:IsA("Humanoid") then
                    queueTeamRefresh()
                    -- Removing events fire before reparenting. Recheck after the short replication guard.
                    task.delay(0.3,queueTeamRefresh)
                end
            end
            table.insert(watches.character,char.DescendantAdded:Connect(changed))
            table.insert(watches.character,char.DescendantRemoving:Connect(changed))
            table.insert(watches.character,char.AttributeChanged:Connect(function(name) if attributeNames[name] then queueTeamRefresh() end end))
            queueTeamRefresh(); task.delay(0.3,queueTeamRefresh)
        end
        table.insert(watches.player,player.CharacterAdded:Connect(attachCharacter))
        table.insert(watches.player,player.AttributeChanged:Connect(function(name) if attributeNames[name] then queueTeamRefresh() end end))
        table.insert(watches.player,player:GetPropertyChangedSignal("Team"):Connect(queueTeamRefresh))
        attachCharacter(player.Character)
    end
    for _,player in ipairs(Players:GetPlayers()) do hookChar(player) end
    table.insert(State.Conns,Players.PlayerAdded:Connect(function(player) hookChar(player); queueTeamRefresh() end))
    table.insert(State.Conns,Players.PlayerRemoving:Connect(function(player)
        disconnectTeamWatch(player); removeVisuals(player)
        State.TeamCache[player]=nil; State.ManualTeams[player.UserId]=nil
        if State.InfectionMemory then State.InfectionMemory[player.UserId]=nil end
        if State.IconMissingSince then State.IconMissingSince[player.UserId]=nil end
        queueTeamRefresh()
    end))

    local connected = setmetatable({}, {__mode = "k"})
    local function tryConnect(remote)
        if not remote:IsA("RemoteEvent") or connected[remote] then return end
        local eventName = remote.Name:match("([^/]+)$")
        local allowed = {TeamLocal=true, HighlightPlrs=true, MatchPreview=true, PrepareMatchMap=true, ConfirmMatchMap=true, StartRoundGui=true, MatchResults=true}
        if not allowed[eventName] then return end
        connected[remote] = true
        table.insert(State.Conns, remote.OnClientEvent:Connect(function(...)
            if not State.Running then return end
            State.TeamStamp = 0; State.VisualDirty = true
            local args = {...}
            if eventName == "TeamLocal" or eventName == "MatchPreview" then
                for i = 1, math.min(#args, 4) do consumeTeamPayload(args[i]) end
            elseif eventName == "PrepareMatchMap" or eventName == "MatchResults" then State.InfectionMemory={}; State.IconMissingSince={}; State.InfectionCandidate=nil; State.NativeMemory = {}; State.TeamStamp = 0; State.MarkerSince = nil; State.RemoteTeams = {}; State.ManualTeams = {}; State.MatchRoster = {}; State.MarkerCandidate = nil end
        end))
    end
    local function attachNetworking(net)
        table.insert(State.Conns, net.DescendantAdded:Connect(tryConnect))
        task.spawn(function()
            -- Only the known networking folder; never scan Workspace or all remotes.
            local pending = {{node = net, depth = 0}}
            local visited = 0
            while #pending > 0 and State.Running and visited < 512 do
                local item = table.remove(pending)
                for _, child in ipairs(item.node:GetChildren()) do
                    visited = visited + 1; tryConnect(child)
                    if item.depth < 3 and child:IsA("Folder") then table.insert(pending, {node = child, depth = item.depth + 1}) end
                    if visited % 32 == 0 then task.wait() end
                    if not State.Running or visited >= 512 then break end
                end
            end
        end)
    end
    local function attachPackages(packages)
        local net = packages:FindFirstChild("Networking")
        if net then attachNetworking(net) end
        table.insert(State.Conns, packages.ChildAdded:Connect(function(child) if child.Name == "Networking" then attachNetworking(child) end end))
    end
    local packages = RepStorage:FindFirstChild("Packages")
    if packages then attachPackages(packages) end
    table.insert(State.Conns, RepStorage.ChildAdded:Connect(function(child) if child.Name == "Packages" then attachPackages(child) end end))
    State.VisualDirty = true
end

local GuiService = game:GetService("GuiService")
local function aimCenters()
    local inset = GuiService:GetGuiInset()
    local firstPerson = Camera and (Camera.CFrame.Position - Camera.Focus.Position).Magnitude <= 1
    if Camera and (firstPerson or UIS.MouseBehavior == Enum.MouseBehavior.LockCenter) then
        local viewport = Camera.ViewportSize / 2
        return viewport, viewport
    end
    local screen = UIS:GetMouseLocation()
    return screen, screen - inset
end

local function FOV_Create()
    if State.FovCircle then pcall(function() State.FovCircle:Remove() end) end
    if not Drawing or not Drawing.new then return end
    local c = Drawing.new("Circle")
    c.Visible = CFG.FovOn; c.Radius = CFG.FovRadius; c.Color = CFG.FovColor
    c.Thickness = 1.5; c.Filled = false; c.NumSides = 64
    c.Position = aimCenters()
    State.FovCircle = c
end

local function FOV_Update()
    local circle = State.FovCircle
    if not circle or not Camera then return end
    local position = aimCenters()
    if circle.Position ~= position then circle.Position = position end
    if circle.Visible ~= CFG.FovOn then circle.Visible = CFG.FovOn end
    if circle.Radius ~= CFG.FovRadius then circle.Radius = CFG.FovRadius end
end

local function screenDist(pos, center)
    local sp, on = Camera:WorldToViewportPoint(pos)
    if not on then return nil end
    if not center then local screen; screen, center = aimCenters() end
    return (center - Vector2.new(sp.X, sp.Y)).Magnitude
end

local function wallOk(from, to, targetChar)
    if not CFG.WallCheck then return true end
    local dir = to - from
    if dir.Magnitude < 0.1 then return true end
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = {LP.Character}
    local hit = workspace:Raycast(from, dir, rp)
    if not hit then return true end
    return hit.Instance:IsDescendantOf(targetChar)
end

local function aimPoint(p)
    local c = p.Character
    local part = c and (c:FindFirstChild(CFG.AimPart) or getRoot(p))
    return part and part.Position
end
local function getTarget()
    refreshTeamCache(true)
    local screen, center = aimCenters()
    local best, bestD, bestPos = nil, math.huge, nil
    local counts = {unknown=0, team=0, outside=0, wall=0, alive=0}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP and alive(p) then
            counts.alive = counts.alive + 1
            if not canTarget(p) then
                if isTeammate(p) then counts.team=counts.team+1 else counts.unknown=counts.unknown+1 end
            else
                local pos = aimPoint(p)
                local d = pos and screenDist(pos, center)
                if not d or (CFG.FovOn and d > CFG.FovRadius) then counts.outside=counts.outside+1
                elseif not wallOk(Camera.CFrame.Position,pos,p.Character) then counts.wall=counts.wall+1
                elseif d < bestD then best,bestD,bestPos=p,d,pos end
            end
        end
    end
    local reason = "No live target"
    if counts.wall>0 then reason="Wall check blocked shot"
    elseif counts.outside>0 then reason="Aim part outside FOV"
    elseif counts.unknown>0 then reason="Team unknown / wait for match teams"
    elseif counts.team>0 then reason="Team check blocked teammate" end
    return best, bestPos, reason
end

local Notify
local function fireMessage(message)
    State.FireStatus = message
    if Notify and os.clock() - (State.LastFireNotice or -10) >= 1.5 then
        State.LastFireNotice = os.clock(); Notify(message)
    end
end
local function aimCursorRay(cam, position)
    local screen, viewport = aimCenters()
    local ray = cam:ViewportPointToRay(viewport.X, viewport.Y, 0)
    local delta = position - ray.Origin
    if delta.Magnitude < 0.001 then return end
    local from, toward = ray.Direction.Unit, delta.Unit
    local axis = from:Cross(toward)
    local cosine = math.clamp(from:Dot(toward), -1, 1)
    if axis.Magnitude < 0.00001 then return end
    local rotation = CFrame.fromAxisAngle(axis.Unit, math.acos(cosine))
    cam.CFrame = CFrame.new(cam.CFrame.Position) * rotation * cam.CFrame.Rotation
end
local function doFire()
    if not State.Running or State.Firing or State.AuraTool then return end
    if not CFG.AimbotOn then fireMessage("Aimbot is OFF"); return end
    if os.clock() - State.LastFire < CFG.FireCooldown then return end
    State.Firing = true
    local ok, err = pcall(function()
        local target, targetPos, reason = getTarget()
        if not target then fireMessage(reason); return end
        local myChar = LP.Character
        local hum = myChar and myChar:FindFirstChildOfClass("Humanoid")
        if not hum or hum.Health <= 0 then fireMessage("Character not ready"); return end
        local tool = findWeapon()
        if not tool then fireMessage("No supported weapon equipped"); return end
        if tool.Parent ~= myChar then hum:EquipTool(tool); task.wait(0.15) end
        if not State.Running or LP.Character ~= myChar or tool.Parent ~= myChar then return end
        if not tool.Enabled then fireMessage("Weapon not ready"); return end
        local cam = workspace.CurrentCamera
        if not cam then fireMessage("Camera not ready"); return end
        RunService:BindToRenderStep("MVS_AIM", Enum.RenderPriority.Camera.Value + 1, function()
            if State.Running and workspace.CurrentCamera == cam then
                local current = aimPoint(target)
                if current then aimCursorRay(cam,current) end
            end
        end)
        RunService.RenderStepped:Wait(); RunService.RenderStepped:Wait()
        if not State.Running or LP.Character ~= myChar or not alive(target) or not canTarget(target) then return end
        if not tool.Parent or tool.Parent ~= myChar or not tool.Enabled then return end
        local current = aimPoint(target)
        if not current or not wallOk(cam.CFrame.Position,current,target.Character) then fireMessage("Wall check blocked shot"); return end
        aimCursorRay(cam,current)
        State.LastFire = os.clock()
        tool:Activate(); State.FireStatus="Activated"
        RunService.RenderStepped:Wait()
        if tool.Parent then tool:Deactivate() end
    end)
    pcall(RunService.UnbindFromRenderStep, RunService, "MVS_AIM")
    State.Firing = false
    if not ok then warn("[MVS] Fire: " .. tostring(err)); fireMessage("Shot failed / see F9 console") end
end
local function equippedSword()
    local char = LP.Character
    if not char then return nil end
    for _, tool in ipairs(char:GetChildren()) do
        if tool:IsA("Tool") and tool:FindFirstChild("Slash") and not tool:FindFirstChild("fire") then return tool end
    end
    return nil
end
local function auraTarget(root)
    refreshTeamCache()
    local best, distance = nil, CFG.AuraRange
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LP and alive(player) and canTarget(player) then
            local otherRoot = getRoot(player)
            if otherRoot then
                local d = (otherRoot.Position - root.Position).Magnitude
                if d <= distance and wallOk(root.Position, otherRoot.Position, player.Character) then
                    best, distance = player, d
                end
            end
        end
    end
    return best
end
local function hideAuraRing()
    if State.AuraRangeGui then State.AuraRangeGui.Enabled=false end
end
local function updateAuraRange(root,sword)
    if not State.Running or not CFG.ShowAuraRange or not root or not Camera then hideAuraRing(); return end
    local gui=State.AuraRangeGui
    if not gui or not gui.Parent then
        gui=Instance.new("ScreenGui"); gui.Name="MVS_RANGE"; gui.IgnoreGuiInset=true
        gui.ResetOnSpawn=false; gui.DisplayOrder=49; gui.Parent=LP:FindFirstChildOfClass("PlayerGui") or CoreGui
        State.AuraRangeGui=gui; State.AuraLines={}
        for i=1,48 do
            local line=Instance.new("Frame"); line.AnchorPoint=Vector2.new(0,0.5)
            line.BorderSizePixel=0; line.BackgroundColor3=Color3.fromRGB(255,125,0)
            line.Parent=gui; State.AuraLines[i]=line
        end
    end
    gui.Enabled=true
    local hum=LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    local height=(hum and hum.HipHeight or 2)+(root.Size.Y/2)-0.15
    local center=root.Position-Vector3.new(0,height,0)
    local points={}
    for i=0,48 do
        local angle=i*math.pi*2/48
        points[i+1]=Camera:WorldToScreenPoint(center+Vector3.new(math.cos(angle)*CFG.AuraRange,0,math.sin(angle)*CFG.AuraRange))
    end
    for i,line in ipairs(State.AuraLines) do
        local a,b=points[i],points[i+1]
        if a.Z>0.1 and b.Z>0.1 then
            local dx,dy=b.X-a.X,b.Y-a.Y
            line.Position=UDim2.fromOffset(a.X,a.Y); line.Size=UDim2.fromOffset(math.sqrt(dx*dx+dy*dy),3)
            line.Rotation=math.deg(math.atan2(dy,dx)); line.Visible=true
        else line.Visible=false end
    end
end
local function stopAuraSwing()
    local tool=State.AuraTool
    State.AuraTool=nil; State.AuraReleaseAt=nil
    if tool then pcall(function() tool:Deactivate() end) end
end
local function beginAuraSwing(tool,target,root)
    -- Native auto swing only. A targeted 360-degree damage API has not been verified.
    if not alive(target) or not canTarget(target) then return end
    State.AuraTool=tool; State.AuraReleaseAt=os.clock()+0.08
    State.LastAura=os.clock(); State.LastFire=State.LastAura
    tool:Activate()
end
local function auraUpdate()
    if State.AuraTool and (not CFG.KillAura or os.clock()>=(State.AuraReleaseAt or 0)) then stopAuraSwing() end
    if not CFG.KillAura and not CFG.ShowAuraRange then
        hideAuraRing()
        return
    end
    local root,sword=getRoot(LP),equippedSword()
    if State.AuraTool then
        if not State.Running or State.MenuOpen or State.Capturing or UIS:GetFocusedTextBox() or sword~=State.AuraTool or not alive(LP) then stopAuraSwing() end
        return
    end
    if not State.Running or not CFG.KillAura or not root or not sword or not alive(LP) then return end
    if State.Firing or State.MenuOpen or State.Capturing or UIS:GetFocusedTextBox() or not sword.Enabled then return end
    local now=os.clock()
    if now-(State.LastAura or -10)<CFG.AuraDelay or now-State.LastFire<CFG.FireCooldown then return end
    local target=auraTarget(root)
    if target then beginAuraSwing(sword,target,root) end
end

local MENU_W, MENU_H, TITLE_H, SIDE_W, FOOT_H = 760, 540, 68, 166, 32
local MainFrame, ToastHolder, FooterLabel
local RefreshBindingLabels = function() end

local T = {
    BG = Color3.fromRGB(13, 16, 21), BG2 = Color3.fromRGB(13, 16, 21),
    Panel = Color3.fromRGB(20, 25, 32), Panel2 = Color3.fromRGB(29, 36, 45),
    Orange = Color3.fromRGB(236, 143, 71), Orange2 = Color3.fromRGB(249, 192, 129),
    Purple = Color3.fromRGB(125, 143, 166), Slime = Color3.fromRGB(113, 186, 154),
    Text = Color3.fromRGB(233, 237, 242), Muted = Color3.fromRGB(146, 158, 174),
    Off = Color3.fromRGB(44, 54, 67), Danger = Color3.fromRGB(215, 48, 66),
}

local function mkC(p, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = p; return c end
local function mkStroke(p, col, th, tr)
    local s = Instance.new("UIStroke"); s.Color = col; s.Thickness = th or 1; s.Transparency = tr or 0
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border; s.Parent = p; return s
end
local function mkLabel(parent, text, size, color, font, xalign)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1; l.Text = text; l.TextSize = size or 12
    l.TextColor3 = color or T.Text; l.Font = font or Enum.Font.Gotham
    l.TextXAlignment = xalign or Enum.TextXAlignment.Left; l.Parent = parent
    return l
end
local function tw(obj, t, props)
    local previous = State.Tweens[obj]
    if previous then previous:Cancel() end
    local tween = TweenService:Create(obj, TweenInfo.new(t, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
    State.Tweens[obj] = tween
    tween.Completed:Once(function() if State.Tweens[obj] == tween then State.Tweens[obj] = nil end end)
    tween:Play()
end

local orders = setmetatable({}, {__mode = "k"})
local function nextOrder(page) orders[page] = (orders[page] or 0) + 1; return orders[page] end

Notify = function(text, col)
    if not ToastHolder then return end
    local f = Instance.new("Frame")
    f.Size = UDim2.new(0, 250, 0, 38); f.BackgroundColor3 = T.Panel
    f.BackgroundTransparency = 1; f.BorderSizePixel = 0; f.Parent = ToastHolder
    mkC(f, 10)
    local st = mkStroke(f, col or T.Orange, 1.4, 1)
    local l = mkLabel(f, "  " .. text, 12, T.Text, Enum.Font.GothamMedium)
    l.Size = UDim2.new(1, -14, 1, 0); l.Position = UDim2.new(0, 12, 0, 0); l.TextTransparency = 1
    tw(f, 0.25, {BackgroundTransparency = 0.05}); tw(st, 0.25, {Transparency = 0}); tw(l, 0.25, {TextTransparency = 0})
    task.delay(2, function()
        if not f.Parent then return end
        tw(f, 0.3, {BackgroundTransparency = 1}); tw(st, 0.3, {Transparency = 1}); tw(l, 0.3, {TextTransparency = 1})
        task.wait(0.35); pcall(function() f:Destroy() end)
    end)
end

local function newPage(parent)
    local sf = Instance.new("ScrollingFrame")
    sf.Size = UDim2.new(1, 0, 1, 0); sf.BackgroundTransparency = 1; sf.BorderSizePixel = 0
    sf.ScrollBarThickness = 3; sf.ScrollBarImageColor3 = T.Orange
    sf.CanvasSize = UDim2.new(0, 0, 0, 0); sf.AutomaticCanvasSize = Enum.AutomaticSize.Y
    sf.Visible = false; sf.Parent = parent
    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 14); pad.PaddingBottom = UDim.new(0, 14)
    pad.PaddingLeft = UDim.new(0, 16); pad.PaddingRight = UDim.new(0, 18); pad.Parent = sf
    local lay = Instance.new("UIListLayout")
    lay.SortOrder = Enum.SortOrder.LayoutOrder; lay.Padding = UDim.new(0, 8); lay.Parent = sf
    return sf
end

local function mkSec(page, text)
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, 24); f.BackgroundTransparency = 1
    f.LayoutOrder = nextOrder(page); f.Parent = page
    local l = mkLabel(f, "🕯  " .. text:upper(), 11, T.Orange2, Enum.Font.GothamBold)
    l.Size = UDim2.new(1, 0, 0, 16); l.Position = UDim2.new(0, 2, 0, 0)
    local line = Instance.new("Frame")
    line.Size = UDim2.new(1, 0, 0, 1); line.Position = UDim2.new(0, 0, 1, -3)
    line.BackgroundColor3 = Color3.fromRGB(255, 255, 255); line.BorderSizePixel = 0; line.Parent = f
    line.BackgroundColor3 = T.Orange
    line.BackgroundColor3 = T.Orange; line.BackgroundTransparency = 0.75
end

local BuiltRows = 0
local function mkRow(page, h)
    BuiltRows = BuiltRows + 1
    if BuiltRows % 4 == 0 then task.wait() end
    if not State.Running then error("Build cancelled") end
    local f = Instance.new("Frame")
    f.Size = UDim2.new(1, 0, 0, h); f.BackgroundColor3 = T.Panel; f.BorderSizePixel = 0
    f.LayoutOrder = nextOrder(page); f.Parent = page
    mkC(f, 7)
    local st = mkStroke(f, T.Off, 1, 0.5)
    f.MouseEnter:Connect(function() tw(f, 0.15, {BackgroundColor3 = T.Panel2}) end)
    f.MouseLeave:Connect(function() tw(f, 0.15, {BackgroundColor3 = T.Panel}) end)
    return f, st
end

local function mkToggle(page, label, desc, getV, setV)
    local f, st = mkRow(page, desc and 54 or 42)
    local l = mkLabel(f, label, 13, T.Text, Enum.Font.GothamMedium)
    l.Size = UDim2.new(1, -90, 0, 18); l.Position = UDim2.new(0, 14, 0, desc and 9 or 12)
    if desc then
        local d = mkLabel(f, desc, 11, T.Muted)
        d.Size = UDim2.new(1, -90, 0, 14); d.Position = UDim2.new(0, 14, 0, 29)
    end
    local sw = Instance.new("TextButton")
    sw.Text = ""; sw.AutoButtonColor = false; sw.BorderSizePixel = 0
    sw.Size = UDim2.new(0, 46, 0, 24); sw.Position = UDim2.new(1, -60, 0.5, -12); sw.Parent = f
    mkC(sw, 12)
    local swStroke = mkStroke(sw, T.Orange, 1.5, 1)
    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 18, 0, 18); knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0; knob.Parent = sw
    mkC(knob, 9)
    local function paint(anim)
        local v = getV()
        local bg = v and T.Orange or T.Off
        local pos = v and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)
        local sc = v and T.Orange or T.Panel2
        if anim then
            tw(sw, 0.2, {BackgroundColor3 = bg}); tw(knob, 0.2, {Position = pos})
            tw(st, 0.2, {Color = sc}); tw(swStroke, 0.2, {Transparency = v and 0.35 or 1})
        else
            sw.BackgroundColor3 = bg; knob.Position = pos; st.Color = sc; swStroke.Transparency = v and 0.35 or 1
        end
    end
    paint(false)
    sw.MouseButton1Click:Connect(function()
        setV(not getV()); SaveSettings(); paint(true)
        Notify(label .. ": " .. (getV() and "ON" or "OFF"), getV() and T.Orange or T.Muted)
    end)
end

local function mkSlider(page, label, mn, mx, step, fmt, getV, setV)
    local f = mkRow(page, 60)
    local l = mkLabel(f, label, 13, T.Text, Enum.Font.GothamMedium)
    l.Size = UDim2.new(0.6, 0, 0, 18); l.Position = UDim2.new(0, 14, 0, 9)
    local chip = Instance.new("Frame")
    chip.Size = UDim2.new(0, 74, 0, 20); chip.Position = UDim2.new(1, -88, 0, 8)
    chip.BackgroundColor3 = T.Panel2; chip.BorderSizePixel = 0; chip.Parent = f
    mkC(chip, 10)
    local val = mkLabel(chip, fmt(getV()), 11, T.Orange2, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
    val.Size = UDim2.new(1, 0, 1, 0)
    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -28, 0, 6); track.Position = UDim2.new(0, 14, 0, 42)
    track.BackgroundColor3 = T.Off; track.BorderSizePixel = 0; track.Parent = f
    mkC(track, 3)
    local ratio = (getV() - mn) / (mx - mn)
    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(ratio, 0, 1, 0); fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    fill.BackgroundColor3 = T.Orange; fill.BorderSizePixel = 0; fill.Parent = track
    mkC(fill, 3); fill.BackgroundColor3 = T.Orange
    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 16, 0, 16); knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new(ratio, 0, 0.5, 0); knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0; knob.Parent = track
    mkC(knob, 8); mkStroke(knob, T.Orange, 2, 0)
    local hit = Instance.new("TextButton")
    hit.Text = ""; hit.BackgroundTransparency = 1
    hit.Size = UDim2.new(1, -14, 0, 28); hit.Position = UDim2.new(0, 7, 0, 31); hit.Parent = f
    local drag = false
    local function setFromX(x)
        local r = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        local v = math.clamp(math.floor((mn + r * (mx - mn)) / step + 0.5) * step, mn, mx)
        setV(v); SaveSettings()
        local rr = (v - mn) / (mx - mn)
        fill.Size = UDim2.new(rr, 0, 1, 0); knob.Position = UDim2.new(rr, 0, 0.5, 0); val.Text = fmt(v)
    end
    hit.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            drag = true; setFromX(i.Position.X)
        end
    end)
    table.insert(State.Conns, UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then drag = false end
    end))
    table.insert(State.Conns, UIS.InputChanged:Connect(function(i)
        if drag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            setFromX(i.Position.X)
        end
    end))
end

local function mkButton(page, text, col, cb)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, 0, 0, 40); b.BackgroundColor3 = col; b.BorderSizePixel = 0
    b.AutoButtonColor = false; b.Text = text; b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.Font = Enum.Font.GothamBold; b.TextSize = 13
    b.LayoutOrder = nextOrder(page); b.Parent = page
    mkC(b, 11)
    mkStroke(b, T.Off, 1, 0.3)
    b.MouseEnter:Connect(function() tw(b, 0.15, {BackgroundTransparency = 0.18}) end)
    b.MouseLeave:Connect(function() tw(b, 0.15, {BackgroundTransparency = 0}) end)
    b.MouseButton1Click:Connect(cb)
    return b
end

local function mkInfo(page, text, h)
    local f = mkRow(page, h or 60)
    local l = mkLabel(f, text, 12, T.Muted)
    l.RichText = true; l.TextWrapped = true; l.TextYAlignment = Enum.TextYAlignment.Center
    l.Size = UDim2.new(1, -28, 1, 0); l.Position = UDim2.new(0, 14, 0, 0)
end

local function exportCombatInfo()
    local out={version="9.2",placeId=tostring(game.PlaceId),mode=CFG.GameMode,players={}}
    local function attributes(node)
        local result={}
        for name,value in pairs(node:GetAttributes()) do
            if type(value)=="boolean" or type(value)=="number" then result[name]=value
            elseif type(value)=="string" then result[name]=value:sub(1,160) end
        end
        return result
    end
    for _,p in ipairs(Players:GetPlayers()) do
        local row={name=p.Name,attributes=attributes(p),characterAttributes=p.Character and attributes(p.Character) or {},role=infectionRole(p) or "unknown",tools={}}
        if p.Character then
            for _,tool in ipairs(p.Character:GetChildren()) do
                if tool:IsA("Tool") then
                    local item={name=tool.Name,attributes=attributes(tool),nodes={}}
                    for i,node in ipairs(tool:GetDescendants()) do
                        if i>64 then break end
                        table.insert(item.nodes,{name=node.Name,class=node.ClassName,attributes=attributes(node)})
                    end
                    table.insert(row.tools,item)
                end
            end
        end
        table.insert(out.players,row)
    end
    local text=HttpService:JSONEncode(out)
    print("[MVS Combat info] "..text)
    if writefile then pcall(writefile,"mvs_combat_info.json",text) end
    Notify("Combat info saved locally / F9 console")
end
local function BuildUI()
    local old = CoreGui:FindFirstChild("MVS_GUI"); if old then old:Destroy() end
    local sg = Instance.new("ScreenGui")
    sg.Name = "MVS_GUI"; sg.ResetOnSpawn = false
    sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; sg.Parent = CoreGui
    sg.DisplayOrder = 60

    MainFrame = Instance.new("Frame")
    MainFrame.Size = UDim2.new(0, MENU_W, 0, MENU_H); MainFrame.Position = UDim2.new(0, 40, 0, 70)
    MainFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255); MainFrame.BorderSizePixel = 0
    MainFrame.ClipsDescendants = true; MainFrame.Parent = sg
    mkC(MainFrame, 10)
    local scale = Instance.new("UIScale")
    scale.Parent = MainFrame
    local function resize()
        local camera = workspace.CurrentCamera
        if camera then
            scale.Scale = math.min(1, math.max(0.3, math.min((camera.ViewportSize.X - 32) / MENU_W, (camera.ViewportSize.Y - 48) / MENU_H)))
        end
    end
    resize()
    local viewportConnection
    local function attachViewport()
        if viewportConnection then viewportConnection:Disconnect() end
        local camera = workspace.CurrentCamera
        if camera then viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(resize); table.insert(State.Conns, viewportConnection) end
        resize()
    end
    attachViewport()
    table.insert(State.Conns, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(attachViewport))
    local winStroke = mkStroke(MainFrame, T.Off, 1, 0)
    MainFrame.BackgroundColor3 = T.BG
    local tb = Instance.new("Frame")
    tb.Size = UDim2.new(1, 0, 0, TITLE_H); tb.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    tb.BorderSizePixel = 0; tb.ClipsDescendants = true; tb.Parent = MainFrame
    mkC(tb, 16)
    tb.BackgroundColor3 = T.Panel
    local tbFill = Instance.new("Frame")
    tbFill.Size = UDim2.new(1, 0, 0, 16); tbFill.Position = UDim2.new(0, 0, 1, -16)
    tbFill.BackgroundColor3 = Color3.fromRGB(255, 255, 255); tbFill.BorderSizePixel = 0; tbFill.Parent = tb
    tbFill.BackgroundColor3 = T.Panel
    local tbLine = Instance.new("Frame")
    tbLine.Size = UDim2.new(1, 0, 0, 1); tbLine.Position = UDim2.new(0, 0, 1, -1)
    tbLine.BackgroundColor3 = Color3.fromRGB(255, 255, 255); tbLine.BorderSizePixel = 0; tbLine.Parent = tb
    tbLine.BackgroundColor3 = T.Orange
    local moon = Instance.new("Frame")
    moon.Size = UDim2.new(0, 34, 0, 34); moon.Position = UDim2.new(0, 14, 0, 12)
    moon.BackgroundColor3 = Color3.fromRGB(255, 235, 170); moon.BorderSizePixel = 0; moon.Parent = tb
    mkC(moon, 17); mkStroke(moon, T.Orange2, 2, 0.4)
    moon.BackgroundColor3 = T.Orange
    local pumpkin = mkLabel(moon, "31", 15, T.Text, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
    pumpkin.Size = UDim2.new(1, 0, 1, 0)

    local title = mkLabel(tb, "NOCTURNE / MVS", 21, Color3.fromRGB(255, 255, 255), Enum.Font.GothamBlack)
    title.Size = UDim2.new(0, 260, 0, 26); title.Position = UDim2.new(0, 58, 0, 8)
    title.TextColor3 = T.Text
    local chip = Instance.new("Frame")
    chip.Size = UDim2.new(0, 122, 0, 16); chip.Position = UDim2.new(0, 60, 0, 35)
    chip.BackgroundColor3 = T.Panel2; chip.BackgroundTransparency = 0; chip.BorderSizePixel = 0; chip.Parent = tb
    mkC(chip, 8)
    local cl = mkLabel(chip, "HALLOWEEN / 9.3", 9, T.Text, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
    cl.Size = UDim2.new(1, 0, 1, 0)

    local function mkTitleBtn(txt, xOff, col)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0, 30, 0, 28); b.Position = UDim2.new(1, xOff, 0, 15)
        b.BackgroundColor3 = col; b.BorderSizePixel = 0; b.AutoButtonColor = false
        b.Text = txt; b.TextColor3 = Color3.fromRGB(255, 255, 255)
        b.Font = Enum.Font.GothamBold; b.TextSize = 14; b.Parent = tb
        mkC(b, 8)
        b.MouseEnter:Connect(function() tw(b, 0.12, {BackgroundTransparency = 0.25}) end)
        b.MouseLeave:Connect(function() tw(b, 0.12, {BackgroundTransparency = 0}) end)
        return b
    end
    local minBtn = mkTitleBtn("–", -74, T.Panel2)
    local closeBtn = mkTitleBtn("✕", -38, T.Danger)

    local dragging, dragStart, startPos = false, nil, nil
    tb.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = i.Position; startPos = MainFrame.Position
        end
    end)
    table.insert(State.Conns, UIS.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
    end))
    table.insert(State.Conns, UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            local d = (i.Position - dragStart) / scale.Scale
            MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end))
    local side = Instance.new("Frame")
    side.Size = UDim2.new(0, SIDE_W, 1, -TITLE_H - FOOT_H); side.Position = UDim2.new(0, 0, 0, TITLE_H)
    side.BackgroundColor3 = T.Panel; side.BackgroundTransparency = 0.35; side.BorderSizePixel = 0; side.Parent = MainFrame
    local sideLine = Instance.new("Frame")
    sideLine.Size = UDim2.new(0, 1, 1, 0); sideLine.Position = UDim2.new(1, -1, 0, 0)
    sideLine.BackgroundColor3 = T.Orange; sideLine.BackgroundTransparency = 0.7; sideLine.BorderSizePixel = 0; sideLine.Parent = side
    local content = Instance.new("Frame")
    content.Size = UDim2.new(1, -SIDE_W, 1, -TITLE_H - FOOT_H); content.Position = UDim2.new(0, SIDE_W, 0, TITLE_H)
    content.BackgroundTransparency = 1; content.ClipsDescendants = true; content.Parent = MainFrame

    local Tabs, TabBtns = {}, {}
    local function selectTab(name)
        SavedUi.Tab = name; SaveSettings()
        for n, p in pairs(Tabs) do p.Visible = (n == name) end
        for n, b in pairs(TabBtns) do
            local on = (n == name)
            tw(b.btn, 0.2, {BackgroundTransparency = on and 0.1 or 1})
            tw(b.bar, 0.2, {BackgroundTransparency = on and 0 or 1})
            tw(b.lbl, 0.2, {TextColor3 = on and T.Orange2 or T.Muted})
        end
    end
    local tabOrder = 0
    local function addTab(icon, name)
        tabOrder = tabOrder + 1
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, -20, 0, 40)
        btn.Position = UDim2.fromOffset(10, 14 + (tabOrder - 1) * 46)
        btn.BackgroundColor3 = T.Panel2; btn.BackgroundTransparency = 1
        btn.BorderSizePixel = 0; btn.AutoButtonColor = false; btn.Text = ""
        btn.LayoutOrder = tabOrder; btn.Parent = side
        mkC(btn, 6)
        local lbl = mkLabel(btn, name, 12, T.Muted, Enum.Font.GothamBold)
        lbl.Size = UDim2.new(1, -22, 1, 0); lbl.Position = UDim2.new(0, 18, 0, 0)
        local bar = Instance.new("Frame")
        bar.Size = UDim2.new(0, 3, 0, 20); bar.Position = UDim2.new(0, 5, 0.5, -10)
        bar.BackgroundColor3 = T.Orange; bar.BackgroundTransparency = 1; bar.BorderSizePixel = 0; bar.Parent = btn
        mkC(bar, 2)
        TabBtns[name] = {btn = btn, lbl = lbl, bar = bar}
        local page = newPage(content)
        Tabs[name] = page
        btn.MouseButton1Click:Connect(function() selectTab(name) end)
        btn.MouseEnter:Connect(function() if not Tabs[name].Visible then tw(btn, 0.15, {BackgroundTransparency = 0.7}) end end)
        btn.MouseLeave:Connect(function() if not Tabs[name].Visible then tw(btn, 0.15, {BackgroundTransparency = 1}) end end)
        return page
    end
    local pAim = addTab("", "Combat")
    mkSec(pAim, "Teams / mode")
    local modeButton
    modeButton=mkButton(pAim,"Mode: "..CFG.GameMode,T.Panel2,function()
        CFG.GameMode=CFG.GameMode=="Auto" and "Infection" or (CFG.GameMode=="Infection" and "Duels" or "Auto")
        State.NativeMemory={}; State.TeamStamp=0; State.VisualDirty=true; SaveSettings()
        modeButton.Text="Mode: "..CFG.GameMode
    end)
    mkSec(pAim, "Sword / range")
    mkToggle(pAim, "Auto swing (experimental)", "Native sword click only / no verified 360-degree hit",
        function() return CFG.KillAura end, function(v) CFG.KillAura = v; if not v then stopAuraSwing() end end)
    mkSlider(pAim, "Aura range", 2, 25, 1,
        function(v) return string.format("%d studs", v) end,
        function() return CFG.AuraRange end, function(v) CFG.AuraRange = v end)
    mkToggle(pAim, "Show range", "Orange ground ring / centered on your character",
        function() return CFG.ShowAuraRange end, function(v) CFG.ShowAuraRange = v; updateAuraRange(getRoot(LP),equippedSword()) end)
    mkSlider(pAim, "Swing delay", 0.15, 1, 0.05,
        function(v) return string.format("%.2f s", v) end,
        function() return CFG.AuraDelay end, function(v) CFG.AuraDelay = v end)
    mkSec(pAim, "Aim assist")
    mkToggle(pAim, "Aimbot", "Aim and activate your equipped tool",
        function() return CFG.AimbotOn end, function(v) CFG.AimbotOn = v end)
    mkToggle(pAim, "Wall check", "Require a clear line of sight",
        function() return CFG.WallCheck end, function(v) CFG.WallCheck = v end)
    mkToggle(pAim, "Team check", "Only target confirmed opponents; unknown players are skipped",
        function() return CFG.TeamCheck end, function(v) CFG.TeamCheck = v; State.VisualDirty = true end)
    local partBtn
    partBtn = mkButton(pAim, "Aim part: " .. CFG.AimPart, T.Panel2, function()
        CFG.AimPart = (CFG.AimPart == "Head") and "HumanoidRootPart" or "Head"
        SaveSettings()
        partBtn.Text = "Aim part: " .. CFG.AimPart
    end)
    mkSlider(pAim, "Fire delay", 0.05, 1, 0.05,
        function(v) return string.format("%.2f s", v) end,
        function() return CFG.FireCooldown end, function(v) CFG.FireCooldown = v end)
    mkSec(pAim, "FOV")
    mkToggle(pAim, "FOV", "Follows cursor / centered in first person and shift lock",
        function() return CFG.FovOn end, function(v) CFG.FovOn = v; FOV_Update() end)
    mkSlider(pAim, "FOV radius", 50, 600, 5,
        function(v) return string.format("%d px", v) end,
        function() return CFG.FovRadius end, function(v) CFG.FovRadius = v; FOV_Update() end)
    local pEsp = addTab("", "Visuals")
    mkSec(pEsp, "ESP")
    mkToggle(pEsp, "ESP", "Highlight player characters",
        function() return CFG.EspOn end, function(v) CFG.EspOn = v; State.VisualDirty = true end)
    mkToggle(pEsp, "Names", "Display name, distance and role",
        function() return CFG.NameTags end, function(v) CFG.NameTags = v; State.VisualDirty = true end)
    mkToggle(pEsp, "Hide teammates", "Hide teammate highlights and labels",
        function() return CFG.HideTeam end, function(v) CFG.HideTeam = v; State.VisualDirty = true end)
    mkSec(pEsp, "Role colors")
    mkInfo(pEsp, "<font color=\"#46eb82\">●</font>  Teammate\n<font color=\"#ffa51e\">●</font>  Enemy\n<font color=\"#ff2828\">●</font>  Murderer", 74)
    local pPl = addTab("", "Players")
    mkButton(pPl,"Export local combat info",T.Panel2,exportCombatInfo)
    mkSec(pPl, "Players")
    mkInfo(pPl, "Auto teams: 1v1, 2v2, 3v3 and 4v4.\nConfirmed teams stay saved until the match ends.", 60)
    local function refreshPlayers()
        for _, c in ipairs(pPl:GetChildren()) do
            if c.Name == "PL_ROW" then c:Destroy() end
        end
        local i = 0
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then
                i = i + 1
                local label, col = statusOf(p)
                local f = Instance.new("Frame")
                f.Name = "PL_ROW"; f.Size = UDim2.new(1, 0, 0, 64); f.BackgroundColor3 = T.Panel
                f.BorderSizePixel = 0; f.LayoutOrder = 1000 + i; f.Parent = pPl
                mkC(f, 9); mkStroke(f, T.Off, 1, 0.5)
                local dot = Instance.new("Frame")
                dot.Size = UDim2.new(0, 8, 0, 8); dot.Position = UDim2.new(0, 12, 0.5, -4)
                dot.BackgroundColor3 = col; dot.BorderSizePixel = 0; dot.Parent = f; mkC(dot, 4)
                local n = mkLabel(f, p.Name, 12, T.Text, Enum.Font.GothamMedium)
                n.Size = UDim2.new(0.48, 0, 0, 28); n.Position = UDim2.new(0, 28, 0, 4)
                local tg = mkLabel(f, label .. (alive(p) and "" or "  "), 11, col, Enum.Font.GothamBold, Enum.TextXAlignment.Right)
                tg.Size = UDim2.new(0.4, 0, 0, 28); tg.Position = UDim2.new(0.6, -12, 0, 4)
                local source = State.TeamCache[p]
                local detail = mkLabel(f, source and source.source or "Pending", 10, T.Muted)
                detail.Position = UDim2.fromOffset(28, 36); detail.Size = UDim2.new(1, -42, 0, 20)

            end
        end
    end
    task.spawn(function()
        while State.Running do
            if pPl.Visible and MainFrame.Visible then
                local snapshot = {}
                for _, player in ipairs(Players:GetPlayers()) do
                    table.insert(snapshot, player.UserId .. ":" .. statusOf(player) .. ":" .. tostring(not not alive(player)) .. ":" .. (State.TeamCache[player] and State.TeamCache[player].source or ""))
                end
                local signature = table.concat(snapshot, "|")
                if signature ~= State.RosterSignature then State.RosterSignature = signature; safe(refreshPlayers, "PlayersTab") end
            end
            task.wait(1)
        end
    end)
    local pMisc = addTab("", "Settings")
    mkSec(pMisc, "Transfer status")
    mkInfo(pMisc, State.TeleportStatus or "Not armed", 46)
    mkSec(pMisc, "Settings")
    mkInfo(pMisc, writefile and "Settings save automatically." or "File storage unavailable: settings last for this session only.", 46)
    mkSec(pMisc, "Binds")
    mkInfo(pMisc, "Click a bind, then press a key or mouse button. Esc cancels.\nSide buttons: map to F6/F7 in your mouse software first.", 64)
    local bindings = {}
    local function addBinding(label, field)
        local row = mkRow(pMisc, 56)
        local title = mkLabel(row, label, 13, T.Text, Enum.Font.GothamMedium)
        title.Position = UDim2.fromOffset(14, 8); title.Size = UDim2.new(1, -200, 0, 18)
        local hint = mkLabel(row, "Keyboard or Mouse 1/2/3. Esc cancels.", 11, T.Muted)
        hint.Position = UDim2.fromOffset(14, 30); hint.Size = UDim2.new(1, -180, 0, 16)
        local key = Instance.new("TextButton")
        key.Size = UDim2.fromOffset(140, 30); key.Position = UDim2.new(1, -154, 0.5, -15)
        key.BackgroundColor3 = T.Panel2; key.TextColor3 = T.Orange2
        key.Font = Enum.Font.GothamMedium; key.TextSize = 12
        key.AutoButtonColor = false; key.BorderSizePixel = 0; key.Parent = row
        mkC(key, 6); mkStroke(key, T.Off)
        bindings[field] = key
        key.Activated:Connect(function(input)
            if input and input == State.CaptureInput then return end
            State.Capturing = State.Capturing == field and nil or field
            RefreshBindingLabels()
        end)
    end
    RefreshBindingLabels = function()
        for field, button in pairs(bindings) do
            button.Text = State.Capturing == field and "PRESS INPUT..." or bindingLabel(CFG[field])
            button.TextColor3 = State.Capturing == field and T.Text or T.Orange2
        end
        if FooterLabel then FooterLabel.Text = "ACTIVE   /   " .. bindingLabel(CFG.AimbotKey) .. " fire   /   " .. bindingLabel(CFG.MenuKey) .. " menu   /   " .. bindingLabel(CFG.UnloadKey) .. " unload" end
    end
    addBinding("Aim and fire", "AimbotKey")
    addBinding("Toggle interface", "MenuKey")
    addBinding("Unload session", "UnloadKey")
    RefreshBindingLabels()
    mkSec(pMisc, "Session")
    mkButton(pMisc, "  Unload / stop transfer reload", T.Danger, function() Unload(true) end)

    selectTab(Tabs[SavedUi.Tab] and SavedUi.Tab or "Combat")
    local foot = Instance.new("Frame")
    foot.Size = UDim2.new(1, 0, 0, FOOT_H); foot.Position = UDim2.new(0, 0, 1, -FOOT_H)
    foot.BackgroundColor3 = T.Panel; foot.BorderSizePixel = 0; foot.Parent = MainFrame
    mkC(foot, 16)
    local footFill = Instance.new("Frame")
    footFill.Size = UDim2.new(1, 0, 0, 16); footFill.BackgroundColor3 = T.Panel; footFill.BorderSizePixel = 0; footFill.Parent = foot
    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 8, 0, 8); dot.Position = UDim2.new(0, 14, 0.5, -4)
    dot.BackgroundColor3 = T.Slime; dot.BorderSizePixel = 0; dot.Parent = foot; mkC(dot, 4)
    local fl = mkLabel(foot, "ACTIVE   /   RIGHT SHIFT menu   /   END unload", 11, T.Muted, Enum.Font.GothamMedium)
    fl.Size = UDim2.new(1, -60, 1, 0); fl.Position = UDim2.new(0, 30, 0, 0)
    FooterLabel = fl; RefreshBindingLabels()
    local ghost = mkLabel(foot, "", 14, T.Text, Enum.Font.Gotham, Enum.TextXAlignment.Right)
    ghost.Size = UDim2.new(0, 30, 1, 0); ghost.Position = UDim2.new(1, -40, 0, 0); ghost.TextTransparency = 0.3

    minBtn.MouseButton1Click:Connect(function()
        State.Minimized = not State.Minimized
        tbFill.Visible = not State.Minimized
        tw(MainFrame, 0.3, {Size = State.Minimized and UDim2.new(0, MENU_W, 0, TITLE_H) or UDim2.new(0, MENU_W, 0, MENU_H)})
        minBtn.Text = State.Minimized and "+" or "–"
    end)
    closeBtn.MouseButton1Click:Connect(function() Unload(true) end)


    ToastHolder = Instance.new("Frame")
    ToastHolder.Size = UDim2.new(0, 254, 0, 240); ToastHolder.AnchorPoint = Vector2.new(1, 1)
    ToastHolder.Position = UDim2.new(1, -20, 1, -20); ToastHolder.BackgroundTransparency = 1; ToastHolder.Parent = sg
    local tl = Instance.new("UIListLayout")
    tl.SortOrder = Enum.SortOrder.LayoutOrder; tl.Padding = UDim.new(0, 6)
    tl.VerticalAlignment = Enum.VerticalAlignment.Bottom; tl.HorizontalAlignment = Enum.HorizontalAlignment.Right
    tl.Parent = ToastHolder

    MainFrame.Size = UDim2.fromOffset(MENU_W, MENU_H - 14)
    tw(MainFrame, 0.2, {Size = UDim2.fromOffset(MENU_W, MENU_H)})
    Notify("MVS ready. Configure your keys in Settings.", T.Orange)
end

Unload = function(permanent)
    if not State.Running then return end
    FlushSettings(); SettingsLive = false
    State.Running = false
    if State.TeamWatches then for player in pairs(State.TeamWatches) do disconnectTeamWatch(player) end end
    stopAuraSwing()
    if State.AuraRangeGui then pcall(function() State.AuraRangeGui:Destroy() end); State.AuraRangeGui=nil; State.AuraLines=nil end
    State.Capturing = nil
    for _, tween in pairs(State.Tweens) do tween:Cancel() end
    table.clear(State.Tweens)
    for _, c in ipairs(State.Conns) do pcall(function() c:Disconnect() end) end
    State.Conns = {}
    for p in pairs(State.Highlights) do removeVisuals(p) end
    for p in pairs(State.Tags) do removeVisuals(p) end
    pcall(RunService.UnbindFromRenderStep, RunService, "MVS_AIM")
    if State.FovCircle then pcall(function() State.FovCircle:Remove() end); State.FovCircle = nil end
    local gui = CoreGui:FindFirstChild("MVS_GUI"); if gui then gui:Destroy() end
    if permanent == true then
        G.MVS_OFF = true
        if writefile then pcall(writefile, "mvs_v72_disabled.flag", "disabled") end
        G.MVS_SRC = nil
        G.MVS_QJOB = nil

    end
end
G.MVS_KILL = function() Unload(false) end

local function Keybinds()
    local function mouseOverMenu(input)
        if input.UserInputType == Enum.UserInputType.Keyboard or not MainFrame or not MainFrame.Visible then return false end
        local inset = game:GetService("GuiService"):GetGuiInset()
        local mouse = UIS:GetMouseLocation() - inset
        local position, size = MainFrame.AbsolutePosition, MainFrame.AbsoluteSize
        return mouse.X >= position.X and mouse.X <= position.X + size.X and mouse.Y >= position.Y and mouse.Y <= position.Y + size.Y
    end
    table.insert(State.Conns, UIS.InputBegan:Connect(function(input, processed)
        if not State.Running then return end
        if State.Capturing then
            if input.KeyCode == Enum.KeyCode.Escape then State.Capturing = nil; RefreshBindingLabels(); return end
            if UIS:GetFocusedTextBox() then return end
            local binding = bindingFromInput(input)
            if not binding then return end
            for _, field in ipairs(KeyFields) do
                if field ~= State.Capturing and CFG[field] == binding then Notify("Bind already in use", T.Danger); return end
            end
            CFG[State.Capturing] = binding
            State.Capturing = nil; State.CaptureInput = input
            SaveSettings(); RefreshBindingLabels(); Notify("Bind saved"); return
        end
        if processed or UIS:GetFocusedTextBox() or mouseOverMenu(input) then return end
        local binding = bindingFromInput(input)
        if not binding then return end
        if binding == CFG.UnloadKey then Unload(true); return end
        if binding == CFG.MenuKey then
            State.MenuOpen = not State.MenuOpen
            if MainFrame then MainFrame.Visible = State.MenuOpen end
            return
        end
        if binding == CFG.AimbotKey then task.spawn(function() safe(doFire, "Fire") end) end
    end))
end

local function TeleportPersist()
    ArmPersist()
    table.insert(State.Conns, LP.OnTeleport:Connect(function(teleportState)
        if teleportState == Enum.TeleportState.Started and State.Running then FlushSettings(); ArmPersist() end
    end))
    table.insert(State.Conns, LP.CharacterAdded:Connect(function()
        task.wait(1)
        if State.Running then State.VisualDirty = true; State.TeamStamp = 0 end
    end))
    table.insert(State.Conns, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        Camera = workspace.CurrentCamera
        if State.Running and Camera then safe(FOV_Create, "CamChange") end
    end))
end

local function MainLoop()
    local rangeElapsed=0
    table.insert(State.Conns,RunService.RenderStepped:Connect(function(dt)
        if not State.Running or not CFG.ShowAuraRange then hideAuraRing(); return end
        rangeElapsed=rangeElapsed+dt
        if rangeElapsed<1/30 then return end
        rangeElapsed=0
        local ok,err=pcall(updateAuraRange,getRoot(LP),nil)
        if not ok then CFG.ShowAuraRange=false; hideAuraRing(); warn("[MVS] Range drawing: "..tostring(err)) end
    end))
    table.insert(State.Conns, UIS.InputChanged:Connect(function(input)
        if State.Running and input.UserInputType == Enum.UserInputType.MouseMovement then FOV_Update() end
    end))
    task.spawn(function()
        local nextVisual = 0
        while State.Running do
            if Camera then safe(FOV_Update, "FOV") end
            local auraOk, auraError = pcall(auraUpdate)
            if not auraOk then
                stopAuraSwing(); CFG.KillAura=false; CFG.ShowAuraRange=false
                warn("[MVS] Sword aura: " .. tostring(auraError))
            end
            if State.VisualDirty or os.clock() >= nextVisual then
                State.VisualDirty = false
                local began = os.clock()
                safe(ESP_Update, "Visuals")
                State.Metrics.VisualPassWallMs = (os.clock() - began) * 1000
                State.Metrics.VisualPeakWallMs = math.max(State.Metrics.VisualPeakWallMs, State.Metrics.VisualPassWallMs)
                nextVisual = os.clock() + CFG.VisualInterval
            end
            task.wait(0.1)
        end
    end)
end

safe(Keybinds, "Keybinds")
safe(TeleportPersist, "TeleportPersist")
safe(ESP_Init, "ESP_Init")
safe(BuildUI, "BuildUI")
if not State.Running then return end
safe(FOV_Create, "FOV_Create")
safe(MainLoop, "MainLoop")
State.Metrics.StartupMs = (os.clock() - StartupClock) * 1000

print("[MVS v9.3] Ready | Configure keys in Settings")
]==]

local G = (getgenv and getgenv()) or _G
G.MVS_OFF = nil
G.MVS_QJOB = nil
G.MVS_SESSION = game:GetService("HttpService"):GenerateGUID(false)
if writefile then pcall(writefile, "mvs_v72_session.id", G.MVS_SESSION) end
-- Invalidate v6 loaders already queued before this upgrade.
if writefile then pcall(writefile, "mvs_disabled.flag", "disabled"); pcall(writefile, "mvs_v7_disabled.flag", "disabled") end
if writefile then pcall(writefile, "mvs_v72_disabled.flag", "enabled") end
G.MVS_SRC = BODY
if writefile then pcall(writefile, "mvs_v72_auto.lua", BODY) end
loadstring(BODY)()