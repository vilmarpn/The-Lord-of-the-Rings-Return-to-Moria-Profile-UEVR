local api = uevr.api
local vr = uevr.params.vr

-- Helper function that ensures UObject references exist, or throws an error
local function find_required_object(name)
    local obj = uevr.api:find_uobject(name)
    if not obj then error("Cannot find " .. name) end
    return obj
end

local hitresult_c = api:find_uobject("ScriptStruct /Script/Engine.HitResult")
local LegacyCameraShake_c = api:find_uobject("Class /Script/GameplayCameras.MatineeCameraShake")
local game_engine_class = find_required_object("Class /Script/Engine.GameEngine")
local ftransform_c = find_required_object("ScriptStruct /Script/CoreUObject.Transform")
local temp_transform = StructObject.new(ftransform_c)

local find_static_class = function(name)
    local c = find_required_object(name)
    return c:get_class_default_object()
end

local Statics = find_static_class("Class /Script/Engine.GameplayStatics")

local weapon_location_offset = Vector3f.new(0.0, 0.0, 0.0)
local weapon_rotation_offset = Vector3f.new(0.4, 0.0, 0.0)

local empty_hitresult = StructObject.new(hitresult_c)
local swinging_fast = false
-- Minimum swing speed required to trigger a melee gesture
local swing_threshold = 2.5
-- Cooldown in seconds between valid melee swing detections
local swing_cooldown = 0.15
local config_filename = "moriaconfig.txt"
local config_data = ""
local gesture_on = 1
-- Hide a specific mesh component from rendering
local hide_Mesh_bool = true

local melee_data = {
    pos_now = Vector3f.new(0, 0, 0),
    pos_prev = Vector3f.new(0, 0, 0),
    q = UEVR_Quaternionf.new(),
    raw = UEVR_Vector3f.new(),
    last_swing_time = 0.0,
}

local saved_rotation = nil


-- Save gesture configuration to disk
local function write_config()
    config_data = "gesture =" .. tostring(gesture_on) .. "\n"
    fs.write(config_filename, config_data)
end

-- Load gesture configuration from disk
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

-- Hide a specific mesh component from rendering
local function hide_Mesh(name)
    if name then
        name:SetRenderInMainPass(false)
        name:SetRenderCustomDepth(false)
    end
end

-- Update weapon attachment logic and motion controller alignment
local function update_weapon_motion_controller()
    local pawn = api:get_local_pawn(0)
    if not pawn or type(pawn.Children) ~= "table" then return end

    local mesh = pawn.Mesh
    for _, component in ipairs(mesh.AttachChildren) do
        if component and UEVR_UObjectHook.exists(component) then
            if string.find(component:get_full_name(), "SceneComponent") then
                print("comp", component:get_full_name())
                if (string.find(component:get_full_name(), "EQ_")) or string.find(component:get_full_name(), "Torch") then
                local state = UEVR_UObjectHook.get_or_add_motion_controller_state(component)
                    if state then
                        local name = component:get_full_name()
                        if string.find(name, "Torch") then
-- Hide a specific mesh component from rendering
                            if component.RaycastMesh then hide_Mesh(component.RaycastMesh) end
                            state:set_hand(0)
                        elseif string.find(name, "Shield") then
                            state:set_hand(0)
                        else
                            state:set_hand(1)
                        end
                        state:set_permanent(true)
-- Offset used to align weapon position with VR hand
                        state:set_location_offset(weapon_location_offset)

                        if string.find(name, "Mattock") then
                            state:set_rotation_offset(Vector3f.new(0.4, 3.3, 0.0))
                        elseif string.find(name, "Hammer_2h") then
                            state:set_rotation_offset(Vector3f.new(0.4, 0.0, 0.0))
                        elseif string.find(name, "Hammer") or string.find(name, "Pick_") or string.find(name, "Shield") then
                            if string.find(name, "Restoration") then
                                state:set_rotation_offset(Vector3f.new(1.4, 1.8, 0.0))
                            else
                                state:set_rotation_offset(Vector3f.new(0.4, 1.8, 0.0))
                            end
                        else
-- Offset used to align weapon rotation with VR hand
                            state:set_rotation_offset(weapon_rotation_offset)
                        end
                    end
                end
            end
        end
    end
end

-- Disable camera lag and rotation smoothing for a sharper VR experience
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

-- Update character rotation to match the HMD orientation
local function update_character_rotation(pawn, rotation)
    local character_rotation = pawn:K2_GetActorRotation()
    character_rotation.Yaw = rotation.Yaw
    pawn:K2_SetActorRotation(character_rotation, false)
end

-- Linearly interpolate between two positions (used for camera smoothing)
local function lerp_position(from, to, alpha)
    return Vector3f.new(
        from.X + (to.X - from.X) * alpha,
        from.Y + (to.Y - from.Y) * alpha,
        from.Z + (to.Z - from.Z) * alpha
    )
end

-- Get the position of the character's head bone, or approximate if missing
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

-- Load gesture configuration from disk
read_config()

-- VR callback: adjust the camera before rendering to match head position
uevr.sdk.callbacks.on_early_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    local pawn = api:get_local_pawn(0)
    if not pawn then return end

-- Hide a specific mesh component from rendering
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

-- Disable camera lag and rotation smoothing for a sharper VR experience
    disable_camera_effects(pawn)

-- Get the position of the character's head bone, or approximate if missing
    local head_pos = get_head_position(pawn)
    position.x, position.y, position.z = head_pos.X, head_pos.Y, head_pos.Z + 70

-- Linearly interpolate between two positions (used for camera smoothing)
    local new_position = lerp_position(position, head_pos, 0.1)
    position.x, position.y, position.z = new_position.X, new_position.Y, new_position.Z

-- Update character rotation to match the HMD orientation
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

-- VR callback: inject input when gesture-based swing is active
uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    if gesture_on == 1 and state and swinging_fast then
        state.Gamepad.bRightTrigger = 200
    end
end)

-- UI callback: draw mod settings menu in ImGui
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
-- Save gesture configuration to disk
        write_config()
    end
end)

local BlueprintUpdateCameraShake = LegacyCameraShake_c:find_function("BlueprintUpdateCameraShake")
if BlueprintUpdateCameraShake then
    BlueprintUpdateCameraShake:set_function_flags(BlueprintUpdateCameraShake:get_function_flags() | 0x400)
    BlueprintUpdateCameraShake:hook_ptr(function(fn, obj, locals, result)
        obj.ShakeScale = 0.0
        return false
    end)
end

local ReceivePlayShake = LegacyCameraShake_c:find_function("ReceivePlayShake")
if ReceivePlayShake then
    ReceivePlayShake:set_function_flags(ReceivePlayShake:get_function_flags() | 0x400)
    ReceivePlayShake:hook_ptr(function(fn, obj, locals, result)
        obj.ShakeScale = 0.0
        return false
    end)
end

-- Main per-frame logic for motion tracking and gesture detection
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    if not vr.is_hmd_active() then return end

    vr.set_mod_value("VR_RenderingMethod", "0") -- Native Stereo. Synced sequential doesn't work atm but people shouldnt be using that anyways
    vr.set_mod_value("VR_CameraForwardOffset", "0.0") -- Reset camera offsets so weapons look correct and pivot positions are correct
    vr.set_mod_value("VR_CameraUpOffset", "0.0")
    vr.set_mod_value("VR_CameraRightOffset", "0.0")

-- Update weapon attachment logic and motion controller alignment
    update_weapon_motion_controller()

    if gesture_on == 1 then
-- Fetch the current pose (position & rotation) of the right hand controller
        vr.get_pose(vr.get_right_controller_index(), melee_data.raw, melee_data.q)

        melee_data.pos_prev:set(melee_data.pos_now.x, melee_data.pos_now.y, melee_data.pos_now.z)
        melee_data.pos_now:set(melee_data.raw.x, melee_data.raw.y, melee_data.raw.z)

-- Calculate hand movement velocity for gesture recognition
        local velocity = (melee_data.pos_now - melee_data.pos_prev) * (1 / delta)
        local vel_len = velocity:length()

        local now = os.clock()
-- Minimum swing speed required to trigger a melee gesture
        if velocity.y < 0 and vel_len >= swing_threshold then
-- Cooldown in seconds between valid melee swing detections
            if (now - melee_data.last_swing_time) > swing_cooldown then
                swinging_fast = true
                melee_data.last_swing_time = now
            end
        else
            swinging_fast = false
        end
    end
end)
