local api = uevr.api
local vr = uevr.params.vr

local hitresult_c = api:find_uobject("ScriptStruct /Script/Engine.HitResult")
local AnimMontage_c = api:find_uobject("Class /Script/Engine.AnimMontage")

-- Weapon offset configuration
local weapon_location_offset = Vector3f.new(0.0, 0.0, 0.0)
local weapon_rotation_offset = Vector3f.new(-100.0, 1.80, 0.0)

local empty_hitresult = StructObject.new(hitresult_c)

local swing_cooldown = 0.15

local melee_data = {
    pos_now = Vector3f.new(0, 0, 0),
    pos_prev = Vector3f.new(0, 0, 0),
    q = UEVR_Quaternionf.new(),
    raw = UEVR_Vector3f.new(),
    last_swing_time = 0.0,
}

local saved_rotation = nil
local blocked_montages = {
    ["Dwa_Pick_Mine_SwingFull_Big_Montage"] = true,
    ["Dwa_FGK_Axe_Mine_SwingFull_Big_1H_Montage"] = true,
    ["Gob_UA_Squat_Dig_Loop_VarA_Montage"] = true,
    ["Gob_UA_Squat_Dig_Loop_VarA_Montage_Loop"] = true
}

local function find_required_object(name)
    local obj = uevr.api:find_uobject(name)
    if not obj then
        error("Cannot find " .. name)
        return nil
    end

    return obj
end

local function write_config()
	config_data = "gesture =" .. tostring(gesture_on) .. "\n" ..
    fs.write(config_filename, config_data)
end

local function read_config()
    config_data = fs.read(config_filename)
    if config_data then 
        for key, value in config_data:gmatch("([^=]+)=([^\n]+)\n?") do
            print("parsing key:", key, "value:", value)
            if key == "gesture" then
                gesture_on = (value == "true" or value == "1") and 1 or 0
            end
        end
    else
        print("Error: Could not read config file.")
        gesture_on = 1
        write_config()
    end
end

-- Applies motion controller state to the weapon
local function update_weapon_motion_controller()
    local pawn = api:get_local_pawn(0)
    if not pawn or not pawn.Children then return end
    --local empty_hitresult = StructObject.new(hitresult_c)

    for _, component in ipairs(pawn.Children) do
        
        if component and UEVR_UObjectHook.exists(component)  then
        
            local state = UEVR_UObjectHook.get_or_add_motion_controller_state(component.RootComponent)
            if state then
                if  string.find(component:get_full_name(), "Torch")  then  
                    state:set_hand(0)  -- Left hand  
                else              
                    state:set_hand(1)  -- Right hand
                end
                state:set_permanent(true)
                state:set_location_offset(weapon_location_offset)
                state:set_rotation_offset(weapon_rotation_offset)                
            end        
        end
    end
end

-- Disables camera effects that may cause issues
local function disable_camera_effects(pawn)
    local camera_component = pawn:GetComponentByClass(api:find_uobject("Class /Script/Engine.CameraComponent"))
    local attach_parent = camera_component and camera_component.AttachParent

    if attach_parent then
        attach_parent.bEnableCameraRotationLag = false
        attach_parent.bEnableCameraLag = false

        local attach_parent_parent = attach_parent.AttachParent
        if attach_parent_parent and attach_parent_parent.ResetLookOperation then
            attach_parent_parent:ResetLookOperation(nil) -- Reseta ajustes automáticos da câmera
        end
    end
end

-- Keeps the body rotation only on the Yaw axis
local function update_character_rotation(pawn, rotation)
    local character_rotation = pawn:K2_GetActorRotation()
    character_rotation.Yaw = rotation.Yaw -- Keeps only the horizontal rotation
    pawn:K2_SetActorRotation(character_rotation, false)
end

-- Smooths the transition of the camera position (prevents jitter)
local function lerp_position(from, to, alpha)
    return Vector3f.new(
        from.X + (to.X - from.X) * alpha,
        from.Y + (to.Y - from.Y) * alpha,
        from.Z + (to.Z - from.Z) * alpha
    )
end

local function hide_Mesh(name)
    if name then
        name:SetRenderInMainPass(false)
        name:SetRenderCustomDepth(false)
    end
end

-- Gets the correct head position from the Mesh
local function get_head_position(pawn)
    if not pawn or not pawn.Mesh then
        print("Error: Mesh not found!")
        return pawn:K2_GetActorLocation() -- Returns the default position if the Mesh is not found
    end

    -- If the head socket exists, retrieves its correct position
    if pawn.Mesh:DoesSocketExist("Head") then
        return pawn.Mesh:GetSocketLocation("Head")
    else
        -- Otherwise, uses the Mesh position and applies a manual fine adjustment
        local head_pos = pawn.Mesh:K2_GetComponentLocation()
        head_pos.Z = head_pos.Z + 80 -- Fine adjustment
        return head_pos
    end
end

read_config()

uevr.sdk.callbacks.on_early_calculate_stereo_view_offset(function(device, view_index, world_to_meters, position, rotation, is_double)
    local pawn = api:get_local_pawn(0)
    if not pawn then return end
    
    hide_Mesh(pawn.Mesh)
    
    -- Desativa efeitos de câmera que podem interferir
    disable_camera_effects(pawn)

    -- Pega a posição da cabeça diretamente
    local head_pos = get_head_position(pawn)
    position.x, position.y, position.z = head_pos.X, head_pos.Y, head_pos.Z+70

    -- Mantém a rotação do personagem apenas no eixo Yaw
    update_character_rotation(pawn, rotation)

    -- Acessa a câmera do personagem
    local camera_component = pawn:GetComponentByClass(api:find_uobject("Class /Script/Engine.CameraComponent"))
    
    if camera_component then
        -- Garante que a câmera use transformações absolutas, para evitar herança de animações
        camera_component:SetUsingAbsoluteLocation(true)
        camera_component:SetUsingAbsoluteRotation(true)

        -- Posiciona a câmera exatamente na cabeça
        camera_component:K2_SetWorldLocation(Vector3f.new(position.x, position.y, position.z), false, empty_hitresult, true)
        camera_component:K2_SetWorldRotation(rotation, false)
    else
        -- Alternativa: usa o PlayerCameraManager se a câmera não for encontrada
        local player_controller = api:get_player_controller(0)
        local camera_manager = player_controller and player_controller.PlayerCameraManager
        if camera_manager then
            camera_manager:K2_SetActorLocation(position, false, empty_hitresult, true)
            camera_manager:K2_SetActorRotation(rotation, false)
        end
    end
end)

uevr.sdk.callbacks.on_xinput_get_state(function(retval, user_index, state)
    if gesture_on == 1 then
        if state ~= nil then
            if swinging_fast then
                -- Simula ataque
                state.Gamepad.bRightTrigger = 200
            end
        end
    end
end)

uevr.sdk.callbacks.on_draw_ui(function()
    imgui.text("The Lord of the Rings: Return to Moria Mod Settings")
    imgui.text("Mod by Vilmar de Paula")
    imgui.text("")
    imgui.text("")
    local needs_save = false
    local changed, new_value

    -- Use more concise boolean conversion
    local gesture_bool = (gesture_on == 1)

    changed, new_value = imgui.checkbox("Trigger attacks through gestures:", gesture_bool)
    if changed then
        needs_save = true
        gesture_on = new_value and 1 or 0 -- Correctly use new_value        
    end

    if needs_save then
        write_config()
    end
end)

local LegacyCameraShake_c = find_required_object("Class /Script/GameplayCameras.MatineeCameraShake")

-- Disable camera shake 1
local BlueprintUpdateCameraShake = LegacyCameraShake_c:find_function("BlueprintUpdateCameraShake")

if BlueprintUpdateCameraShake ~= nil then
    BlueprintUpdateCameraShake:set_function_flags(BlueprintUpdateCameraShake:get_function_flags() | 0x400) -- Mark as native
    BlueprintUpdateCameraShake:hook_ptr(function(fn, obj, locals, result)
        obj.ShakeScale = 0.0
        
        return false
    end)
end

-- Disable camera shake 2
local ReceivePlayShake = LegacyCameraShake_c:find_function("ReceivePlayShake")

if ReceivePlayShake ~= nil then
    ReceivePlayShake:set_function_flags(ReceivePlayShake:get_function_flags() | 0x400) -- Mark as native
    ReceivePlayShake:hook_ptr(function(fn, obj, locals, result)
        obj.ShakeScale = 0.0
        return false
    end)
end


-- Main loop for updating weapon controller and firing logic
uevr.sdk.callbacks.on_pre_engine_tick(function(engine, delta)
    
    if vr.is_hmd_active() then
        update_weapon_motion_controller()

        if gesture_on == 1 then
            vr.get_pose(vr.get_right_controller_index(), melee_data.raw, melee_data.q)

            melee_data.pos_prev:set(melee_data.pos_now.x, melee_data.pos_now.y, melee_data.pos_now.z)
            melee_data.pos_now:set(melee_data.raw.x, melee_data.raw.y, melee_data.raw.z)

            local velocity = (melee_data.pos_now - melee_data.pos_prev) * (1 / delta)
            local vel_len = velocity:length()

            local now = os.clock()

            -- Detecção de swing
            if velocity.y < 0 and vel_len >= swing_threshold then
                if (now - melee_data.last_swing_time) > swing_cooldown then
                    swinging_fast = true
                    melee_data.last_swing_time = now
                end
            else
                swinging_fast = false
            end
        end

        local pawn = api:get_local_pawn(0)
        if not pawn or not pawn.Mesh then return end
        --pawn.Mesh.AnimScriptInstance = nil
        local anim_instance = pawn.Mesh.AnimScriptInstance
        if not anim_instance then return end

        local montage = anim_instance:GetCurrentActiveMontage()
        

        if montage then
            
            local name = montage:get_fname():to_string()
            print(name)
            if blocked_montages[name] then
                montage.bEnableRootMotionTranslation = false
                -- Bloqueia Root Motion
                --[[ anim_instance:SetRootMotionMode(1) -- IgnoreRootMotion
                anim_instance:AnimNotify_StopTransition()

                -- Mantém rotação fixa
                if not saved_rotation then
                    saved_rotation = pawn.Mesh:K2_GetComponentRotation()
                end
                pawn.Mesh:K2_SetWorldRotation(saved_rotation, false, empty_hitresult, true)
 ]]
                -- (opcional) print de debug
                -- print("[VR Patch] RootMotion bloqueado para:", name)
            end
        end
        -- Guardar a rotação "frontal"
        --[[ if not saved_rotation then
            saved_rotation = pawn.Mesh:K2_GetComponentRotation()
        end

        -- Forçar a malha a sempre olhar para frente
        pawn.Mesh:K2_SetWorldRotation(saved_rotation, false, empty_hitresult, true)

        --pawn.Mesh:SetAnimationMode(0)  -- 0 = AnimationMode::AnimationBlueprint, 1 = AnimationAsset, 2 = AnimationSingleNode
        
        local montages = AnimMontage_c:get_objects_matching(false)

        local anim_instance = pawn.Mesh.AnimScriptInstance
        if anim_instance then
            local current_montage = anim_instance:GetCurrentActiveMontage()
            
            for _, v in ipairs(montages) do
                local montage_name = v:get_fname():to_string()
                
                if string.find(montage_name, "Pick_Mine") then
                    -- Desativa root motion da montagem
                    v.bEnableRootMotionTranslation = false
                    
                    -- Garante que o anim instance também ignore root motion
                    anim_instance:SetRootMotionMode(1) -- 1 = IgnoreRootMotion
                    
                    -- Interrompe a animação, se ela estiver sendo executada agora
                    local montage_name = v:get_fname():to_string()
                    if current_montage and current_montage == v and anim_instance:Montage_IsPlaying(current_montage) then
                        local ok, err = pcall(function()
                            anim_instance:Montage_Stop(0.0)                            
                        end)
                        if not ok then
                            print("Erro ao parar montagem:", err)
                        else
                            print("Picareta: montagem parada com sucesso:", montage_name)
                        end
                    end
                end
            end
        end ]] 
        --fs.write("config_filename", dataconf)
    end    
end)
