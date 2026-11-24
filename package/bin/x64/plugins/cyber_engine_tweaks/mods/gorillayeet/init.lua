-- ============================================================
--  Gorilla Yeet - launch NPCs into orbit with Gorilla Arms
--  by penicius-code
--  v0.5.10
-- ============================================================

local json = require('json')

local GorillaYeet = {
    drawWindow   = false,
    modVersion   = '0.5.10',
    debugLog     = false,   -- toggle in-game via the CET overlay
    configDirty  = false,
    time         = 0.0,     -- seconds since init, driven by onUpdate
    lastCheck    = 0.0,
    lastSync     = -1000.0, -- last time the non-lethal option was passed to the redscript part
    syncFailed   = false,
    lastBodySlam = -1000.0  -- last time the player was in the body slam state
}

local Config = {
    enabled            = true,
    yeetForce          = 90.0,
    upwardBias         = 30.0,   -- extra +Z force for a satisfying launch arc
    pushYeet           = true,   -- 0.5.10: the block + attack push launches NPCs too (heavy-only or not)
    pushForce          = 60.0,   -- 0.5.10: launch force of the push (the heavy punch uses yeetForce)
    makeHostile        = true,
    nonLethal          = false,  -- punched NPCs drop to nonLethalHealthPct instead of dying from the yeet
    nonLethalHealthPct = 40,     -- % health a punched NPC drops to (never raised; bosses / MaxTac skipped)
    gradeImpacts       = true,   -- wall and ground hits graded like Push/Pull (needs PushPullNonLethal.reds)
    heavyOnly          = true,   -- only strong (held) punches yeet
    cooldownSeconds    = 0.0,    -- per-target cooldown, 0 = off
    lootFix            = true,   -- make yeeted bodies lootable again (see TrackStep)
    killingBlowOnly    = false,  -- yeet only when the punch kills
    dismemberOnKill    = false,  -- One Punch Man: head pops when a yeeted NPC dies
    groundSlam         = true,   -- the Gorilla Arms ground slam also yeets
    vehicles           = true,   -- punches shove vehicles
    vehicleForce       = 12.0,   -- vehicle impulse in multiples of the vehicle mass
    armorStance        = true    -- cars cannot knock you down while you body slam with Gorilla Arms
}

local configPath = "config.json"

-- Vanilla puts BaseStatusEffect.NonInteractable on a living NPC whenever a ragdoll starts
-- (NPCPuppet.OnRagdollEnabledEvent) and only removes it when the AI ragdoll behaviour ends.
-- A yeeted NPC that dies mid-flight never reaches that cleanup, so its body shows loot but
-- cannot be looted or carried. TrackStep removes the effect once the NPC is dead or defeated,
-- which is exactly what the game's own cleanup (AIRagdollDelegate.DoClearActiveStatusEffect) does.
local NON_INTERACTABLE    = "BaseStatusEffect.NonInteractable"
local MIN_REYEET_INTERVAL = 0.25   -- seconds; stops stacked impulses from rapid hits (Sandevistan)
local TRACK_SECONDS       = 20.0   -- how long a yeeted NPC stays tracked
local DEAD_GRACE_SECONDS  = 3.0    -- keep clearing the effect this long after the NPC went down
local CHECK_INTERVAL      = 0.25   -- seconds between tracker passes
local SYNC_INTERVAL       = 1.0    -- seconds between passing the non-lethal option to the redscript part
local ARMOR_GRACE_SECONDS = 0.5    -- armor stance holds this long after the body slam ends

local tracked = {}   -- key -> { id = EntityID, since, lastYeet, deadAt, dismembered }

-- ============================================================
-- Utility
-- ============================================================

local function Log(msg)
    if GorillaYeet.debugLog then
        print("[GorillaYeet] " .. tostring(msg))
    end
end

local function ShowHUDMessage(msg)
    -- Primary: push a SimpleScreenMessage via the UI_Notifications blackboard.
    -- This is the same path the game uses for its own on-screen notifications.
    local ok = pcall(function()
        local defs    = GetAllBlackboardDefs()
        local board   = Game.GetBlackboardSystem():Get(defs.UI_Notifications)
        local screen  = SimpleScreenMessage.new()
        screen.isShown  = true
        screen.duration = 2.0
        screen.message  = msg
        board:SetVariant(defs.UI_Notifications.OnscreenMessage, ToVariant(screen), true)
    end)
    -- Fallback for older/non-standard CET builds.
    if not ok then
        pcall(function() GameHUD.ShowMessage(msg) end)
    end
end

local function LoadConfig()
    local file = io.open(configPath, "rb")
    if not file then return end
    local content = file:read("*a")
    io.close(file)
    if not content or content == "" then return end

    local ok, loaded = pcall(json.decode, content)
    if not ok or not loaded then return end

    -- Only copy known keys; ignores legacy/unknown fields from older saves
    for k, _ in pairs(Config) do
        if loaded[k] ~= nil then
            Config[k] = loaded[k]
        end
    end
end

local function SaveConfig()
    local file = io.open(configPath, "w")
    if not file then return end
    file:write(json.encode(Config))
    io.close(file)
    GorillaYeet.configDirty = false
end

local function KeyOf(entity)
    local ok, key = pcall(function() return tostring(entity:GetEntityID().hash) end)
    if ok and key then return key end
    return nil
end

-- Dead, defeated or unconscious: the states in which vanilla clears NonInteractable at once
local function IsDown(npc)
    local ok, res = pcall(function()
        return npc:IsDead() or not ScriptedPuppet.IsAlive(npc) or ScriptedPuppet.IsDefeated(npc)
            or ScriptedPuppet.IsUnconscious(npc)
    end)
    return ok and res or false
end

-- For the debug log: a knocked out NPC can look dead, so the tracker says which it is
local function DownState(npc)
    local ok, res = pcall(function()
        if npc:IsDead() or not ScriptedPuppet.IsAlive(npc) then return "dead" end
        if ScriptedPuppet.IsUnconscious(npc) then return "unconscious" end
        return "defeated"
    end)
    return ok and res or "unknown"
end

-- Bosses and MaxTac are never set to the non-lethal health: they must stay killable with punches
local function IsBossOrMaxTac(npc)
    local ok, res = pcall(function()
        return ScriptedPuppet.IsBoss(npc) or ScriptedPuppet.IsMaxTac(npc)
    end)
    return ok and res or false
end

-- ============================================================
-- Gorilla Arms detection
-- ============================================================

local function IsGorillaWeapon(weapon)
    if not weapon then return false end

    local weaponID = weapon:GetItemID()
    if not weaponID then return false end

    -- Primary: the weapon record's item type. Covers every tier and modded Gorilla Arms
    -- without depending on record names.
    local okType, isArms = pcall(function()
        return WeaponObject.IsOfType(weaponID, gamedataItemType.Cyb_StrongArms)
    end)
    if okType then
        if isArms then Log("Hit weapon is Cyb_StrongArms") end
        return isArms
    end

    -- Fallback (v0.4 behaviour) if the type check is unavailable: match the record name.
    -- Vanilla records are Items.AdvancedStrongArms*, never "Gorilla".
    local record = RPGManager.GetItemRecord(weaponID)
    if not record then return false end
    local idString = tostring(record:GetID())
    Log("Hit weapon: " .. idString)
    return string.find(idString, "StrongArms") ~= nil or string.find(idString, "orilla") ~= nil
end

-- ============================================================
-- Yeet
-- ============================================================

local function MakeHostile(target, player)
    local targetAtt = target:GetAttitudeAgent()
    local playerAtt = player:GetAttitudeAgent()
    if targetAtt and playerAtt then
        targetAtt:SetAttitudeTowards(playerAtt, EAIAttitude.AIA_Hostile)
    end
end

local function ClearNonInteractable(npc)
    local ok, err = pcall(function()
        local ses = Game.GetStatusEffectSystem()
        local id  = npc:GetEntityID()
        local effect = TweakDBID.new(NON_INTERACTABLE)
        if ses:HasStatusEffect(id, effect) then
            ses:RemoveStatusEffect(id, effect)
            Log("Removed NonInteractable from a downed target")
        end
    end)
    if not ok then Log("Loot fix failed: " .. tostring(err)) end
end

local function PopHead(npc)
    local ok, err = pcall(function()
        DismembermentComponent.RequestDismemberment(
            npc, gameDismBodyPart.HEAD, gameDismWoundType.COARSE, npc:GetWorldPosition(), true)
    end)
    if not ok then Log("Dismemberment failed: " .. tostring(err)) end
end

-- One tracker pass for a yeeted NPC. Returns false when it can be forgotten.
local function TrackStep(key, entry)
    local now = GorillaYeet.time
    if now - entry.since > TRACK_SECONDS then return false end

    local npc = Game.FindEntityByID(entry.id)
    if not npc then return false end

    if IsDown(npc) then
        if not entry.deadAt then
            entry.deadAt = now
            Log("Tracked target is down: " .. DownState(npc))
            if Config.dismemberOnKill and not entry.dismembered then
                entry.dismembered = true
                PopHead(npc)
            end
        end
        if Config.lootFix then ClearNonInteractable(npc) end
        if now - entry.deadAt > DEAD_GRACE_SECONDS then return false end
    end
    return true
end

local function WasKillingBlow(npc, hitEvent)
    local ok, res = pcall(function()
        if npc:IsDead() then return true end
        local dmg = hitEvent.attackComputed:GetTotalAttackValue(gamedataStatPoolType.Health)
        local hp  = Game.GetStatPoolsSystem():GetStatPoolValue(npc:GetEntityID(), gamedataStatPoolType.Health, false)
        return dmg >= hp
    end)
    return ok and res or false
end

local function AimDirection(player, target, radial)
    local camMatrix = player:GetFPPCameraComponent():GetLocalToWorld()
    local camPos    = Matrix.GetTranslation(camMatrix)
    local camDir    = Vector4.Normalize(Matrix.GetDirectionVector(camMatrix))
    if not radial then return camPos, camDir end

    -- Ground slam: push the NPC away from the player, flat, the upward bias adds the lift
    local tp = target:GetWorldPosition()
    local pp = player:GetWorldPosition()
    local dx, dy = tp.x - pp.x, tp.y - pp.y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 0.05 then return camPos, camDir end
    return camPos, Vector4.new(dx / len, dy / len, 0.0, 0.0)
end

-- push: the block + attack push (0.5.10). It launches with Config.pushForce instead of the yeet force, the upward
-- bias scaled down by the same ratio, and never drops health (the push is a shove; its vanilla record already
-- carries Nonlethal, and wall or ground impacts are graded as for a yeet).
local function YeetTarget(target, radial, push)
    if not target then return end
    local player = Game.GetPlayer()
    if not player then return end

    local key = KeyOf(target)
    local now = GorillaYeet.time
    local entry = key and tracked[key] or nil
    if entry then
        local sinceLast = now - entry.lastYeet
        if sinceLast < MIN_REYEET_INTERVAL then return end
        if Config.cooldownSeconds > 0 and sinceLast < Config.cooldownSeconds then
            Log("Target on cooldown")
            return
        end
    end

    local down = IsDown(target)

    -- Non-lethal: a punch drops a healthier NPC to the set health, so the launch does not kill it.
    -- Never raises health (a punch must not heal a badly hurt NPC, or robots and other NPCs that
    -- Ped Damage Overhaul does not take down could never be punched to death), and bosses and
    -- MaxTac are left alone (they take normal damage). Not on a body that is already down.
    -- This runs after the hit, so it only limits the health left: the punch itself is made
    -- non-lethal by PushPullNonLethal.reds (see SyncSpare).
    if Config.nonLethal and not push and not down and not IsBossOrMaxTac(target) then
        local ok, err = pcall(function()
            local pools = Game.GetStatPoolsSystem()
            local id = target:GetEntityID()
            local current = pools:GetStatPoolValue(id, gamedataStatPoolType.Health, true)
            if current > Config.nonLethalHealthPct then
                pools:RequestSettingStatPoolValue(id, gamedataStatPoolType.Health, Config.nonLethalHealthPct, nil, true)
            end
        end)
        if not ok then Log("Non-lethal health set failed: " .. tostring(err)) end
    end

    -- Build impulse from camera aim (or radially for the ground slam)
    local camPos, dir = AimDirection(player, target, radial)

    local origin = Vector4.new(
        camPos.x + dir.x * 0.10,
        camPos.y + dir.y * 0.10,
        camPos.z + dir.z * 0.10,
        camPos.w + dir.w * 0.10
    )

    local strength = push and Config.pushForce or Config.yeetForce
    local up = Config.upwardBias
    if push and Config.yeetForce > 0 then up = Config.upwardBias * Config.pushForce / Config.yeetForce end
    local force = Vector4.new(
        dir.x * strength,
        dir.y * strength,
        dir.z * strength + up,
        dir.w * strength
    )

    -- 41 km/h knocks out, 90 km/h or a 12 m fall kills (vanilla kills from 41 km/h). Without the
    -- redscript part the call fails quietly and impacts stay vanilla.
    if Config.gradeImpacts then
        pcall(function() target:PushPullMarkImpact(8.0, 11.4, 25.0, 12.0) end)
    end

    target:QueueEvent(CreateForceRagdollEvent("GorillaYeet"))
    GameInstance.GetDelaySystem():DelayEvent(
        target,
        CreateRagdollApplyImpulseEvent(origin, force, 900000000.0),
        0.10,
        false
    )

    Log("YEET! force=" .. strength .. " up=" .. up .. (radial and " (slam)" or "") .. (push and " (push)" or ""))

    if Config.makeHostile and not down then MakeHostile(target, player) end

    if key then
        if not entry then
            entry = { id = target:GetEntityID(), dismembered = false }
            tracked[key] = entry
        end
        entry.since    = now
        entry.lastYeet = now
        if down and not entry.deadAt then entry.deadAt = now end
    end
end

local function ProcessHit(self, hitEvent)
    local attackData = hitEvent.attackData
    local attacker = attackData:GetInstigator()
    if not attacker or not attacker:IsPlayer() then return end

    local attackType = attackData:GetAttackType()
    Log("hit attackType=" .. tostring(attackType))

    -- Gorilla Arms punches report Melee (light) or StrongMelee (held). The block + attack push is a Melee hit with
    -- the BlockAttack subtype (StrongArmsAttacks.FistsBlockAttack); 0.5.10 launches it with the push force.
    local isPunch = attackType == gamedataAttackType.Melee or attackType == gamedataAttackType.StrongMelee
    local isPush = false
    if attackType == gamedataAttackType.Melee then
        local ok, subtype = pcall(function() return attackData:GetAttackSubtype() end)
        isPush = ok and subtype == gamedataAttackSubtype.BlockAttack
    end
    -- The redscript part launches slam targets itself; this path is only the fallback without it
    local isSlam  = Config.groundSlam and GorillaYeet.syncFailed and attackType == gamedataAttackType.PressureWave
    if not isPunch and not isSlam then return end

    if isPunch then
        if isPush then
            if not Config.pushYeet then return end
        elseif Config.heavyOnly and attackType ~= gamedataAttackType.StrongMelee then
            return
        end
        if not IsGorillaWeapon(attackData:GetWeapon()) then return end
    else
        -- The Gorilla Arms ground slam is a weapon attack. Landing shockwaves (superhero landing,
        -- charge jump, hover jump) are PressureWave hits without a weapon and must not yeet.
        local weapon = attackData:GetWeapon()
        if not weapon then
            Log("PressureWave without weapon (landing), ignored")
            return
        end
        if not IsGorillaWeapon(weapon) then return end
    end

    if Config.killingBlowOnly and not WasKillingBlow(self, hitEvent) then return end

    Log(isPush and "Gorilla Arms push - yeeting" or "Gorilla Arms hit - yeeting")
    YeetTarget(self, isSlam, isPush)
end

-- The damage pipeline decides whether a hit kills before the OnHit hook runs, so the punch has to be
-- flagged in redscript (PushPullNonLethal.reds). Without that file the call fails, logged once.
local function SyncSpare()
    local ok, err = pcall(function()
        local player = Game.GetPlayer()
        if player then
            player:GorillaYeetSetSpare(Config.enabled and Config.nonLethal, not Config.heavyOnly)
            player:GorillaYeetSetSlam(Config.enabled and Config.groundSlam, Config.yeetForce, Config.upwardBias)
        end
    end)
    if not ok and not GorillaYeet.syncFailed then
        GorillaYeet.syncFailed = true
        Log("Non-lethal sync failed: " .. tostring(err))
    end
end

-- ============================================================
-- Vehicles (experimental)
-- ============================================================

local function ShoveVehicle(vehicle)
    local player = Game.GetPlayer()
    if not player then return end

    local camMatrix = player:GetFPPCameraComponent():GetLocalToWorld()
    local dir = Vector4.Normalize(Matrix.GetDirectionVector(camMatrix))

    local okMass, mass = pcall(function() return vehicle:GetTotalMass() end)
    if not okMass or not mass or mass <= 0 then mass = 1500.0 end
    local strength = mass * Config.vehicleForce

    local pos = vehicle:GetWorldPosition()
    local evt = PhysicalImpulseEvent.new()
    evt.radius = 1.0
    evt.worldPosition = Vector3.new(pos.x, pos.y, pos.z + 0.5)
    evt.worldImpulse  = Vector3.new(dir.x * strength, dir.y * strength, (dir.z + 0.15) * strength)
    vehicle:QueueEvent(evt)

    Log("Vehicle shove, mass=" .. tostring(mass) .. " strength=" .. tostring(strength))
end

-- 0.5.9: which Gorilla Arms moves shove a car. With "heavy punches only" these count as heavy:
--   StrongMelee        held punch, and the sprint + block body slam (BodySlamAttackLevel1-3 are StrongMelee)
--   ChargedWhipAttack  fully charged punch (One Punch; the combat log showed this type, not StrongMelee)
--   Melee + BlockAttack subtype  block + attack push (StrongArmsAttacks.FistsBlockAttack is an Impact, so Melee)
local VEHICLE_SHOVE_INTERVAL = 0.30   -- a body slam's hit box can touch the same car several times
local lastVehicleShove = {}           -- vehicle key -> GorillaYeet.time of its last shove

local function VehicleMove(attackData)
    local attackType = attackData:GetAttackType()
    if attackType == gamedataAttackType.StrongMelee then return "heavy" end
    if attackType == gamedataAttackType.ChargedWhipAttack then return "charged" end
    if attackType ~= gamedataAttackType.Melee then return nil end
    local ok, subtype = pcall(function() return attackData:GetAttackSubtype() end)
    if ok and subtype == gamedataAttackSubtype.BlockAttack then return "block push" end
    return "light"
end

local function ProcessVehicleHit(vehicle, hitEvent)
    local attackData = hitEvent.attackData
    local attacker = attackData:GetInstigator()
    if not attacker or not attacker:IsPlayer() then return end

    local attackType = attackData:GetAttackType()
    local move = VehicleMove(attackData)
    if not move then return end
    if not IsGorillaWeapon(attackData:GetWeapon()) then
        Log("Vehicle hit skipped: not Gorilla Arms (" .. tostring(attackType) .. ")")
        return
    end
    if Config.heavyOnly and move == "light" then
        Log("Vehicle hit skipped: light punch, heavy punches only is on")
        return
    end

    local key = KeyOf(vehicle)
    if key then
        local last = lastVehicleShove[key]
        if last and GorillaYeet.time - last < VEHICLE_SHOVE_INTERVAL then return end
        lastVehicleShove[key] = GorillaYeet.time
    end

    Log("Vehicle hit: " .. move .. " (" .. tostring(attackType) .. ")")
    ShoveVehicle(vehicle)
end

-- ============================================================
-- Armor stance (experimental)
-- ============================================================

-- When a car hits the player the engine sends OnCarHitPlayer. PlayerPuppet.OnCarHitPlayer then
-- queues the Attacks.CarHitPlayer hit (knockdown and damage) and a separation impulse (the push).
-- Armor stance skips that callback while the player body slams (sprint + block, the vanilla
-- Body perk move for blunt weapons) with Gorilla Arms out.

local function InBodySlam(player)
    local ok, res = pcall(function()
        local bb = player:GetPlayerStateMachineBlackboard()
        return bb:GetBool(GetAllBlackboardDefs().PlayerStateMachine.IsInBodySlamState)
    end)
    return ok and res or false
end

local function ArmorStanceUp(player)
    -- The grace window covers a collision that ends the body slam in the same frame
    if not InBodySlam(player) and GorillaYeet.time - GorillaYeet.lastBodySlam > ARMOR_GRACE_SECONDS then
        return false
    end
    return IsGorillaWeapon(GameObject.GetActiveWeapon(player))
end

-- ============================================================
-- Hit hooks + tracker + hotkey
-- ============================================================

registerForEvent("onInit", function()
    LoadConfig()
    print("[GorillaYeet] v" .. GorillaYeet.modVersion .. " loaded (enabled=" .. tostring(Config.enabled) .. ")")

    ObserveAfter("NPCPuppet", "OnHit", function(self, hitEvent)
        if not Config.enabled then return end
        if not self or not hitEvent or not hitEvent.attackData then return end
        local ok, err = pcall(ProcessHit, self, hitEvent)
        if not ok then Log("OnHit error: " .. tostring(err)) end
    end)

    ObserveAfter("VehicleObject", "OnHit", function(self, hitEvent)
        if not self or not hitEvent or not hitEvent.attackData then return end
        if not Config.enabled or not Config.vehicles then
            Log("Vehicle hit skipped: " .. (Config.enabled and "vehicle shove is off" or "Gorilla Yeet is off"))
            return
        end
        local ok, err = pcall(ProcessVehicleHit, self, hitEvent)
        if not ok then Log("Vehicle OnHit error: " .. tostring(err)) end
    end)

    Override("PlayerPuppet", "OnCarHitPlayer", function(self, evt, wrapped)
        if Config.enabled and Config.armorStance then
            local ok, up = pcall(ArmorStanceUp, self)
            if not ok then Log("Armor stance error: " .. tostring(up)) end
            if ok and up then
                Log("Armor stance: car hit ignored")
                return false
            end
        end
        return wrapped(evt)
    end)
end)

registerForEvent("onUpdate", function(delta)
    GorillaYeet.time = GorillaYeet.time + delta

    if GorillaYeet.time - GorillaYeet.lastSync >= SYNC_INTERVAL then
        GorillaYeet.lastSync = GorillaYeet.time
        SyncSpare()
    end

    if Config.enabled and Config.armorStance then
        -- body slam poll at 10 Hz instead of every frame; the 0.5 s armor grace absorbs the step
        GorillaYeet.slamPollAcc = (GorillaYeet.slamPollAcc or 0) + delta
        if GorillaYeet.slamPollAcc >= 0.1 then
            GorillaYeet.slamPollAcc = 0
            local player = Game.GetPlayer()
            if player and InBodySlam(player) then GorillaYeet.lastBodySlam = GorillaYeet.time end
        end
    end

    if next(tracked) == nil then return end
    if GorillaYeet.time - GorillaYeet.lastCheck < CHECK_INTERVAL then return end
    GorillaYeet.lastCheck = GorillaYeet.time

    for key, entry in pairs(tracked) do
        local ok, keep = pcall(TrackStep, key, entry)
        if not ok then
            Log("Tracker error: " .. tostring(keep))
            keep = false
        end
        if not keep then tracked[key] = nil end
    end
end)

registerForEvent("onShutdown", function()
    if GorillaYeet.configDirty then SaveConfig() end
end)

-- Hotkey: toggle the mod on/off mid-combat.
-- Must be registered at top level so CET's bindings scanner picks it up.
-- User binds the key themselves via CET overlay -> Bindings tab -> gorillayeet.
registerHotkey("toggle_yeet", "Toggle Gorilla Yeet on off", function()
    Config.enabled = not Config.enabled
    GorillaYeet.configDirty = true
    local status = Config.enabled and "ENABLED" or "DISABLED"
    ShowHUDMessage("Gorilla Yeet: " .. status)
    Log("Toggled via hotkey: " .. status)
end)

registerHotkey("toggle_nonlethal", "Toggle Non-lethal", function()
    Config.nonLethal = not Config.nonLethal
    Log("Non-lethal toggled via hotkey: " .. (Config.nonLethal and "ON" or "OFF"))
    GorillaYeet.configDirty = true
    GorillaYeet.lastSync = -1000.0  -- reaches the redscript part on the next update
    ShowHUDMessage("Non-lethal: " .. (Config.nonLethal and "ON" or "OFF"))
end)

-- ============================================================
-- CET overlay UI
-- ============================================================

registerForEvent("onOverlayOpen",  function() GorillaYeet.drawWindow = true  end)
registerForEvent("onOverlayClose", function()
    GorillaYeet.drawWindow = false
    if GorillaYeet.configDirty then SaveConfig() end
end)

local function Tip(text)
    -- pcall so an older CET build without these two ImGui functions cannot spam the log every frame
    pcall(function()
        if ImGui.IsItemHovered() then ImGui.SetTooltip(text) end
    end)
end

local function Checkbox(label, key, tip)
    local v, c = ImGui.Checkbox(label, Config[key])
    if c then
        Config[key] = v; GorillaYeet.configDirty = true
        Log("Overlay: " .. key .. " = " .. tostring(v))
    end
    if tip then Tip(tip) end
end

registerForEvent("onDraw", function()
    if not GorillaYeet.drawWindow then return end

    ImGui.SetNextWindowPos(100, 350, ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowSize(420, 600, ImGuiCond.FirstUseEver)

    if ImGui.Begin("Gorilla Yeet v" .. GorillaYeet.modVersion) then
        local v, c

        Checkbox("Enabled", "enabled")
        ImGui.TextDisabled("Bind a hotkey in CET -> Bindings -> gorillayeet")

        Checkbox("Heavy punches only", "heavyOnly",
            "Only held (strong) punches yeet. Light combo punches hit normally.")
        Checkbox("Make targets hostile", "makeHostile")

        v, c = ImGui.Checkbox("Debug logging (CET console)", GorillaYeet.debugLog)
        if c then GorillaYeet.debugLog = v end

        ImGui.Separator()

        Checkbox("Grade wall hits (Push/Pull rules)", "gradeImpacts",
            "Hits knock out from 41 km/h, kill from 90 km/h or a 12 m fall. Needs PushPullNonLethal.reds.")
        Checkbox("Non-lethal (NPCs survive the yeet)", "nonLethal",
            "Punches that yeet knock humans out instead of killing them. A body already down can still be finished. Bosses, MaxTac and machines take normal damage. Needs PushPullNonLethal.reds.")
        if Config.nonLethal then
            v, c = ImGui.SliderInt("Drop to health %", Config.nonLethalHealthPct, 10, 90)
            if c then Config.nonLethalHealthPct = v; GorillaYeet.configDirty = true end
            Tip("A punch drops an NPC with more health than this to this value, so the yeet does not kill it. Never heals; bosses and MaxTac take normal damage.")
        end

        ImGui.Separator()

        v, c = ImGui.InputFloat("Yeet Force", Config.yeetForce, 10, 50, "%.0f")
        if c then Config.yeetForce = v; GorillaYeet.configDirty = true end

        v, c = ImGui.InputFloat("Upward Bias", Config.upwardBias, 5, 25, "%.0f")
        if c then Config.upwardBias = v; GorillaYeet.configDirty = true end

        Checkbox("Push launches NPCs (block + attack)", "pushYeet",
            "The block + attack push launches humans with its own force, also with heavy punches only. It never drops health; wall hits are graded like a yeet.")
        if Config.pushYeet then
            v, c = ImGui.InputFloat("Push Force", Config.pushForce, 10, 50, "%.0f")
            if c then Config.pushForce = v; GorillaYeet.configDirty = true end
        end

        v, c = ImGui.SliderFloat("Cooldown (s)", Config.cooldownSeconds, 0.0, 15.0, "%.1f")
        if c then Config.cooldownSeconds = v; GorillaYeet.configDirty = true end
        Tip("Seconds before the same NPC can be yeeted again. 0 = off. Rapid hits within 0.25 s are always merged.")

        ImGui.Separator()
        ImGui.Text("Fixes")

        Checkbox("Make yeeted bodies lootable", "lootFix",
            "Removes the interaction block the game leaves on NPCs that die while ragdolling.")

        ImGui.Separator()
        ImGui.Text("Experimental")

        Checkbox("Killing blow only", "killingBlowOnly",
            "Yeet only when the punch kills the target.")
        Checkbox("One Punch Man: pop the head on kill", "dismemberOnKill",
            "When a yeeted NPC dies, its head comes off.")
        Checkbox("Ground slam also yeets", "groundSlam",
            "The Gorilla Arms ground slam only ragdolls humans: no damage, no kill, no lost limbs. Walls can knock out. Bosses, MaxTac and machines stay vanilla.")
        Checkbox("Punches shove vehicles", "vehicles",
            "Gorilla punches push cars and bikes.")
        if Config.vehicles then
            v, c = ImGui.SliderFloat("Vehicle force (x mass)", Config.vehicleForce, 1.0, 30.0, "%.0f")
            if c then Config.vehicleForce = v; GorillaYeet.configDirty = true end
        end
        Checkbox("Armor stance: cars can't knock you down", "armorStance",
            "While you body slam (sprint + block, Body perk) with Gorilla Arms, cars can't knock you down, push you or hurt you.")
    end
    ImGui.End()
end)
