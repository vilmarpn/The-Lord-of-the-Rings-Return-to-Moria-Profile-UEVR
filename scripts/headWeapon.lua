-- Head Weapon VR Mod
-- Cleaned, organized, and commented in US English

local api = uevr.api
local vr = uevr.params.vr

-- UObject references
local hitresult_c = api:find_uobject("ScriptStruct /Script/Engine.HitResult")
local LegacyCameraShake_c = api:find_uobject("Class /Script/GameplayCameras.MatineeCameraShake")

-- Weapon offset configuration (for aligning with hand in VR)
local weapon_location_offset = Vector3f.new(0.0, 0.0, 0.0)
local weapon_rotation_offset = Vector3f.new(-100.0, 0.0, 0.0)

-- Globals
local empty_hitresult = StructObject.new(hitresult_c)
local swinging_fast = false
local swing_threshold = 2.5  -- Minimum velocity to detect a swing
local swing_cooldown = 0.15  -- Time between valid swings (to prevent spamming)
local config_filename = "moriaconfig.txt"
local config_data = ""
local gesture_on = 1
local hide_Mesh_bool = true

-- Runtime melee motion data
local melee_data = {
    pos_now = Vector3f.new(0, 0, 0),
    pos_prev = Vector3f.new(0, 0, 0),
    q = UEVR_Quaternionf.new(),
    raw = UEVR_Vector3f.new(),
    last_swing_time = 0.0,
}

local saved_rotation = nil

-- Helper: Finds UObject or errors
local function find_required_object(name)
    local obj = uevr.api:find_uobject(name)
    if not obj then
        error("Cannot find " .. name)
    end
    return obj
end

-- Writes gesture toggle to config file
local function write_config()
    config_data = "gesture =" .. tostring(gesture_on) .. "\n"
    fs.write(config_filename, config_data)
end

-- Reads gesture toggle from config file
local function read_config()
    config_data = fs.read(config_filename)
    if config_data then 
        for key, value in config_data:gmatch("([^=]+)=([^\n]+)\n?") do
            if key == "gesture" then
                gesture_on = (value == "true" or value == "1") and 1 or 0
            end
        end
    else
        print("Error: Could not read config file.")
    end
end

-- Hides mesh component (avoids rendering in VR view)
local function hide_Mesh(name)
    if name then
        name:SetRenderInMainPass(false)
        name:SetRenderCustomDepth(false)
    end
end

-- Updates weapon state with motion controller info
local function update_weapon_motion_controller()
    local pawn = api:get_local_pawn(0)
    if not pawn or not pawn.Children then return end

    for _, component in ipairs(pawn.Children) do
        if component and UEVR_UObjectHook.exists(component) and (not string.find(component:get_full_name(), "DwarfDeath")) then
            local state = UEVR_UObjectHook.get_or_add_motion_controller_state(component.RootComponent)
            if state then
                if string.find(component:get_full_name(), "Torch") then  
                    hide_Mesh(component.RaycastMesh)
                    state:set_hand(0)  -- Left hand  
                elseif string.find(component:get_full_name(), "Shield") then  
                    state:set_hand(0)  -- Left hand  
                else              
                    state:set_hand(1)  -- Right hand
                end
                state:set_permanent(true)
                state:set_location_offset(weapon_location_offset)
                if string.find(component:get_full_name(), "Mattock") then  
                    state:set_rotation_offset(Vector3f.new(-100.0, 3.3, 0.0)) 
                elseif string.find(component:get_full_name(), "Hammer_2h") then 
                    state:set_rotation_offset(Vector3f.new(-100.0, 0.0, 0.0)) 
                elseif string.find(component:get_full_name(), "Hammer") or string.find(component:get_full_name(), "Pick_") or string.find(component:get_full_name(), "Shield") then 
                    state:set_rotation_offset(Vector3f.new(-100.0, 1.8, 0.0)) 
                else             
                    state:set_rotation_offset(weapon_rotation_offset) 
                end               
            end
        end
    end
end

-- Disables camera lag and animation-related side effects
local function disable_camera_effects(pawn)
    local camera_component = pawn:GetComponentByClass(api:find_uobject("Class /Script/Engine.CameraComponent"))
    local attach_parent = camera_component and camera_component.AttachParent

    if attach_parent then
        attach_parent.bEnableCameraRotationLag = false
        attach_parent.bEnableCameraLag = false

        local attach_parent_parent = attach_parent.AttachParent
        if attach_parent_parent and attach_parent_parent.ResetLookOperation then
            attach_parent_parent:ResetLookOperation(nil)
        end
    end
end

-- Forces character to only rotate on the Yaw (horizontal) axis
local function update_character_rotation(pawn, rotation)
    local character_rotation = pawn:K2_GetActorRotation()
    character_rotation.Yaw = rotation.Yaw
    pawn:K2_SetActorRotation(character_rotation, false)
end

-- Helper: Linear interpolation between two positions
local function lerp_position(from, to, alpha)
    return Vector3f.new(
        from.X + (to.X - from.X) * alpha,
        from.Y + (to.Y - from.Y) * alpha,
        from.Z + (to.Z - from.Z) * alpha
    )
end

-- Gets head position from Mesh or approximates it
local function get_head_position(pawn)
    if not pawn or not pawn.Mesh then
        print("Error: Mesh not found!")
        return pawn:K2_GetActorLocation()
    end

    if pawn.Mesh:DoesSocketExist("Head") then
        return pawn.Mesh:GetSocketLocation("Head")
    else
        local head_pos = pawn.Mesh:K2_GetComponentLocation()
        head_pos.Z = head_pos.Z + 80
        return head_pos
    end
end

read_config()

-- VR Stereo Camera Sync
uevr.sdk.callbacks.on_early_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    local pawn = api:get_local_pawn(0)
    if not pawn then return end

    -- Hide unnecessary body parts for immersion
    hide_Mesh(pawn.SK_Backpack)
    hide_Mesh(pawn.SK_BaseBody)
    hide_Mesh(pawn.SK_Beard)
    hide_Mesh(pawn.SK_Chest)
    hide_Mesh(pawn.SK_Extras)
    hide_Mesh(pawn.SK_Gloves)
    hide_Mesh(pawn.SK_Hair)
    hide_Mesh(pawn.SK_Hands)
    hide_Mesh(pawn.SK_Hat)
    hide_Mesh(pawn.SK_Head)
    hide_Mesh(pawn.SK_Legs)

    disable_camera_effects(pawn)

    local head_pos = get_head_position(pawn)
    position.x, position.y, position.z = head_pos.X, head_pos.Y, head_pos.Z + 70

    update_character_rotation(pawn, rotation)

    local camera_component = pawn:GetComponentByClass(api:find_uobject("Class /Script/Engine.CameraComponent"))
    if camera_component then
        camera_component:SetUsingAbsoluteLocation(true)
        camera_component:SetUsingAbsoluteRotation(true)
        camera_component:K2_SetWorldLocation(Vector3f.new(position.x, position.y, position.z), false, empty_hitresult, true)
        camera_component:K2_SetWorldRotation(rotation, false)
    else
        local player_controller = api:get_player_controller(0)
        local camera_manager = player_controller and player_controller.PlayerCameraManager
        if camera_manager then
            camera_manager:K2_SetActorLocation(position, false, empty_hitresult, true)
            camera_manager:K2_SetActorRotation(rotation, false)
        end
    end
end)

-- VR Gesture to Trigger Conversion
uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    if gesture_on == 1 and state and swinging_fast then
        state.Gamepad.bRightTrigger = 200
    end
end)

-- Settings UI
uevr.sdk.callbacks.on_draw_ui(function()
    imgui.text("The Lord of the Rings: Return to Moria Mod Settings")
    imgui.text("Mod by Vilmar de Paula")
    imgui.text("")
    imgui.text("")
    local needs_save = false

    local gesture_bool = (gesture_on == 1)
    local changed, new_value = imgui.checkbox("Trigger attacks through gestures:", gesture_bool)
    if changed then
        gesture_on = new_value and 1 or 0
        needs_save = true
    end

    if needs_save then
        write_config()
    end
end)

-- Disable Camera Shake: BlueprintUpdateCameraShake
local BlueprintUpdateCameraShake = LegacyCameraShake_c:find_function("BlueprintUpdateCameraShake")
if BlueprintUpdateCameraShake then
    BlueprintUpdateCameraShake:set_function_flags(BlueprintUpdateCameraShake:get_function_flags() | 0x400)
    BlueprintUpdateCameraShake:hook_ptr(function(fn, obj, locals, result)
        obj.ShakeScale = 0.0
        return false
    end)
end

-- Disable Camera Shake: ReceivePlayShake
local ReceivePlayShake = LegacyCameraShake_c:find_function("ReceivePlayShake")
if ReceivePlayShake then
    ReceivePlayShake:set_function_flags(ReceivePlayShake:get_function_flags() | 0x400)
    ReceivePlayShake:hook_ptr(function(fn, obj, locals, result)
        obj.ShakeScale = 0.0
        return false
    end)
end

-- Per-frame logic for tracking melee swing gesture
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if not vr.is_hmd_active() then return end

    update_weapon_motion_controller()

    if gesture_on == 1 then
        vr.get_pose(vr.get_right_controller_index(), melee_data.raw, melee_data.q)

        melee_data.pos_prev:set(melee_data.pos_now.x, melee_data.pos_now.y, melee_data.pos_now.z)
        melee_data.pos_now:set(melee_data.raw.x, melee_data.raw.y, melee_data.raw.z)

        local velocity = (melee_data.pos_now - melee_data.pos_prev) * (1 / delta)
        local vel_len = velocity:length()

        local now = os.clock()

        -- Simple gesture detection
        if velocity.y < 0 and vel_len >= swing_threshold then
            if (now - melee_data.last_swing_time) > swing_cooldown then
                swinging_fast = true
                melee_data.last_swing_time = now
            end
        else
            swinging_fast = false
        end
    end
end)
