-- Optimized OBS Mac Capture Restarter with incremental checking
-- Reduces micro-stutters by distributing work across multiple timer calls

-- Define source types to monitor and their reactivation properties
local SOURCE_TYPES = {
    {
        id = "screen_capture",
        name = "screen capture",
        reactivate_property = "reactivate_capture"
    },
}

-- Cache and state management
local source_cache = {}
local current_check_index = 1
local last_enum_time = 0
local ENUM_INTERVAL = 15000 -- Re-enumerate sources every 15 seconds
local CHECK_INTERVAL = 500 -- Check one source every 500ms (30x faster, but only checks one at a time)
local SOURCES_PER_CHECK = 1 -- Number of sources to check per timer tick

-- Function to check if a source type should be monitored
local function should_monitor_source(source_id)
    for _, source_type in pairs(SOURCE_TYPES) do
        if source_id == source_type.id then
            return source_type
        end
    end
    return nil
end

-- Function to try restarting a single source
local function try_restart_source(source_ref)
    if not source_ref or not source_ref.source then
        return false
    end

    local source = source_ref.source
    local source_type = source_ref.source_type

    -- Get fresh properties (this is the expensive operation we're spreading out)
    local properties = obslua.obs_source_properties(source)
    if not properties then
        return false
    end

    local restarted = false
    local source_name = obslua.obs_source_get_name(source)

    -- Try the specific property first
    local reactivate_btn = obslua.obs_properties_get(properties, source_type.reactivate_property)

    if reactivate_btn ~= nil then
        local can_reactivate = obslua.obs_property_enabled(reactivate_btn)
        if can_reactivate then
            obslua.obs_property_button_clicked(reactivate_btn, source)
            print("Restarted " .. source_type.name .. ": " .. source_name)
            restarted = true
        end
    else
        -- If primary property not found, try alternative property names
        local property_names = {"restart_capture", "reactivate_capture", "restart", "reactivate"}

        for _, prop_name in ipairs(property_names) do
            local restart_btn = obslua.obs_properties_get(properties, prop_name)

            if restart_btn ~= nil then
                local can_restart = obslua.obs_property_enabled(restart_btn)
                if can_restart then
                    obslua.obs_property_button_clicked(restart_btn, source)
                    print("Restarted " .. source_type.name .. ": " .. source_name .. " (using property: " .. prop_name .. ")")
                    restarted = true
                    break
                end
            end
        end
    end

    obslua.obs_properties_destroy(properties)
    return restarted
end

-- Function to update the source cache
local function update_source_cache()
    -- Clear old cache
    source_cache = {}

    local sources = obslua.obs_enum_sources()
    if not sources then return end

    for _, source in pairs(sources) do
        local source_id = obslua.obs_source_get_unversioned_id(source)
        local source_type = should_monitor_source(source_id)

        if source_type then
            -- Store reference to source and its type
            table.insert(source_cache, {
                source = source,
                source_type = source_type,
                last_checked = 0
            })
        end
    end

    -- Don't release sources here - we're keeping references in cache
    -- They'll be released when we rebuild the cache or unload the script

    print("Cache updated: monitoring " .. #source_cache .. " sources")
    last_enum_time = os.clock() * 1000
end

-- Incremental check function - checks only a few sources per call
function check_capture_status_incremental()
    local current_time = os.clock() * 1000

    -- Re-enumerate sources periodically
    if current_time - last_enum_time > ENUM_INTERVAL then
        update_source_cache()
        current_check_index = 1
        return
    end

    -- If no sources to check, return early
    if #source_cache == 0 then
        return
    end

    -- Check a limited number of sources per tick
    local sources_checked = 0
    local start_index = current_check_index

    while sources_checked < SOURCES_PER_CHECK do
        -- Wrap around if we've reached the end
        if current_check_index > #source_cache then
            current_check_index = 1
        end

        -- Prevent infinite loop if we've checked all sources
        if current_check_index == start_index and sources_checked > 0 then
            break
        end

        local source_ref = source_cache[current_check_index]
        if source_ref then
            -- Only check if source is still valid
            if source_ref.source and obslua.obs_source_get_name(source_ref.source) then
                try_restart_source(source_ref)
                source_ref.last_checked = current_time
            else
                -- Source is invalid, mark for removal
                source_ref.invalid = true
            end
        end

        current_check_index = current_check_index + 1
        sources_checked = sources_checked + 1
    end

    -- Clean up invalid sources periodically
    if current_check_index == 1 then
        local valid_sources = {}
        for _, source_ref in ipairs(source_cache) do
            if not source_ref.invalid then
                table.insert(valid_sources, source_ref)
            end
        end
        source_cache = valid_sources
    end
end

-- Alternative: Use coroutine-based checking (experimental)
local check_coroutine = nil

function check_capture_coroutine()
    while true do
        local sources = obslua.obs_enum_sources()
        if sources then
            for _, source in pairs(sources) do
                local source_id = obslua.obs_source_get_unversioned_id(source)
                local source_type = should_monitor_source(source_id)

                if source_type then
                    try_restart_source({source = source, source_type = source_type})
                    coroutine.yield() -- Yield control after each source
                end
            end
            obslua.source_list_release(sources)
        end

        -- Wait before next full check
        for i = 1, 30 do -- 30 * 500ms = 15 seconds
            coroutine.yield()
        end
    end
end

function check_capture_with_coroutine()
    if not check_coroutine or coroutine.status(check_coroutine) == "dead" then
        check_coroutine = coroutine.create(check_capture_coroutine)
    end

    local success, err = coroutine.resume(check_coroutine)
    if not success then
        print("Coroutine error: " .. tostring(err))
        check_coroutine = nil
    end
end

function script_description()
    return "Optimized script that automatically restarts frozen macOS screen captures and audio sources " ..
           "with minimal performance impact. Uses incremental checking to prevent micro-stutters."
end

function script_properties()
    local props = obslua.obs_properties_create()

    obslua.obs_properties_add_int(props, "check_interval", "Check interval (ms)", 100, 5000, 100)
    obslua.obs_properties_add_int(props, "sources_per_check", "Sources per check", 1, 10, 1)
    obslua.obs_properties_add_bool(props, "use_coroutine", "Use coroutine mode (experimental)")

    return props
end

function script_defaults(settings)
    obslua.obs_data_set_default_int(settings, "check_interval", 500)
    obslua.obs_data_set_default_int(settings, "sources_per_check", 1)
    obslua.obs_data_set_default_bool(settings, "use_coroutine", false)
end

function script_update(settings)
    CHECK_INTERVAL = obslua.obs_data_get_int(settings, "check_interval")
    SOURCES_PER_CHECK = obslua.obs_data_get_int(settings, "sources_per_check")
    local use_coroutine = obslua.obs_data_get_bool(settings, "use_coroutine")

    -- Restart timer with new settings
    obslua.timer_remove(check_capture_status_incremental)
    obslua.timer_remove(check_capture_with_coroutine)

    if use_coroutine then
        obslua.timer_add(check_capture_with_coroutine, CHECK_INTERVAL)
        print("Capture Restarter: Using coroutine mode with " .. CHECK_INTERVAL .. "ms interval")
    else
        obslua.timer_add(check_capture_status_incremental, CHECK_INTERVAL)
        print("Capture Restarter: Using incremental mode - checking " .. SOURCES_PER_CHECK ..
              " source(s) every " .. CHECK_INTERVAL .. "ms")
    end
end

function script_load(settings)
    -- Initialize cache
    update_source_cache()

    -- Start with incremental checking by default
    local use_coroutine = obslua.obs_data_get_bool(settings, "use_coroutine")

    if use_coroutine then
        obslua.timer_add(check_capture_with_coroutine, CHECK_INTERVAL)
        print("Capture Restarter: Started in coroutine mode")
    else
        obslua.timer_add(check_capture_status_incremental, CHECK_INTERVAL)
        print("Capture Restarter: Started in incremental mode")
    end
end

function script_unload()
    obslua.timer_remove(check_capture_status_incremental)
    obslua.timer_remove(check_capture_with_coroutine)

    -- Release all cached sources
    if source_cache then
        for _, source_ref in ipairs(source_cache) do
            if source_ref.source then
                obslua.obs_source_release(source_ref.source)
            end
        end
        source_cache = {}
    end

    print("Capture Restarter: Stopped monitoring and released all resources")
end
