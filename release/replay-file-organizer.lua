obs = obslua

local SCRIPT_TAG = "replay_file_organizer"
local DEFAULT_LABEL = "Desktop"
local DATETIME_TOKENS = "%CCYY-%MM-%DD %hh-%mm-%ss"
local BRIDGE_PLUGIN_NAME = "smart-replay-tracker"

local settings_ref = nil
local script_enabled = true
local debug_logging = true
local max_prefix_length = 80

local selected_sources = {}
local excluded_sources = {}
local excluded_set = {}
local available_sources = {}
local available_source_selected = ""
local excluded_available_source_selected = ""

local mappings_raw = [[
dota2.exe=Dota2
brawlhalla.exe=Brawlhalla
]]
local parsed_mappings = {}
local check_formatting_result = "Formatting result: not checked yet"

local original_filename_format = nil
local format_overridden = false
local replay_saving_connected = false
local replay_saved_connected = false
local replay_saved_guard_ns = 0
local postsave_timer_active = false
local pending_postsave_retries = 0
local pending_postsave_folder = nil
local pending_postsave_prefix = nil
local last_moved_replay_source = ""
local replay_cfg_overridden = false
local replay_old_prefix = nil
local replay_old_suffix = nil
local replay_old_filename_format = nil

local STOPWORDS = {
    win64 = true, win32 = true, shipping = true, launcher = true, client = true,
    release = true, retail = true, dx11 = true, dx12 = true, vulkan = true,
    steam = true, epic = true, eac = true
}

local function trim(s)
    if s == nil then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lower(s)
    return string.lower(s or "")
end

local function basename_from_path(path)
    local value = trim(path or "")
    if value == "" then return "" end
    return lower(value:match("([^/\\]+)$") or value)
end

local function normalize_segment(name)
    local safe = trim(name)
    safe = safe:gsub('[\\/:*?"<>|]', "_")
    safe = safe:gsub("%s+", "_")
    safe = safe:gsub("_+", "_")
    safe = safe:gsub("^_+", ""):gsub("_+$", "")
    if safe == "" then return DEFAULT_LABEL end
    return safe
end

local function truncate_text(s, max_len)
    if #s <= max_len then return s end
    return s:sub(1, max_len)
end

local function debug_log(msg)
    if debug_logging then
        obs.script_log(obs.LOG_INFO, "[" .. SCRIPT_TAG .. "] " .. tostring(msg))
    end
end

local function get_time_ns()
    if obs.os_gettime_ns ~= nil then
        return obs.os_gettime_ns()
    end
    return os.time() * 1000000000
end

local function parse_rule_block(block)
    local out = {}
    for line in (block .. "\n"):gmatch("([^\n]*)\n") do
        local raw = trim(line)
        if raw ~= "" and raw:sub(1, 1) ~= "#" then
            local key, folder = raw:match("^(.-)=(.-)$")
            if key ~= nil and folder ~= nil then
                key = lower(trim(key))
                folder = normalize_segment(folder)
                if key ~= "" and folder ~= "" then
                    table.insert(out, { key = key, folder = folder })
                end
            end
        end
    end
    return out
end

local function rebuild_mapping_cache()
    parsed_mappings = parse_rule_block(mappings_raw)
end

local function persist_mappings()
    if settings_ref ~= nil then
        obs.obs_data_set_string(settings_ref, "mappings_raw", mappings_raw)
    end
    rebuild_mapping_cache()
end

local function rebuild_excluded_set()
    excluded_set = {}
    for _, n in ipairs(excluded_sources) do
        excluded_set[n] = true
    end
end

local function is_excluded(name)
    return excluded_set[name] == true
end

local function remove_from_list(list, name)
    local out = {}
    for _, v in ipairs(list) do
        if v ~= name then table.insert(out, v) end
    end
    return out
end

local function filter_priority_against_excluded()
    local out, seen = {}, {}
    for _, n in ipairs(selected_sources) do
        if not is_excluded(n) and not seen[n] then
            table.insert(out, n)
            seen[n] = true
        end
    end
    selected_sources = out
end

local function split_tokens(raw)
    local s = lower(raw)
    s = s:gsub("%.exe$", "")
    s = s:gsub("[^%w]+", " ")
    local out = {}
    for token in s:gmatch("%S+") do
        if token ~= "" and not STOPWORDS[token] then
            table.insert(out, token)
        end
    end
    return out
end

local function canonicalize_name(executable, title, source_name)
    local candidates = { trim(executable), trim(title), trim(source_name) }
    for _, text in ipairs(candidates) do
        if text ~= "" then
            local tokens = split_tokens(text)
            if #tokens > 0 then
                local t = tokens[1]
                if #tokens > 1 and #tokens[1] <= 2 then
                    t = tokens[1] .. tokens[2]
                end
                return normalize_segment(t)
            end
        end
    end
    return DEFAULT_LABEL
end

local function is_supported_capture_type(source_id)
    return source_id == "game_capture" or
           source_id == "window_capture" or
           source_id == "wasapi_process_output_capture"
end

local function get_current_scene()
    local scene_source = obs.obs_frontend_get_current_scene()
    if scene_source == nil then return nil, nil end
    local scene = obs.obs_scene_from_source(scene_source)
    return scene_source, scene
end

local function collect_scene_sources_recursive(scene, include_hidden, out_names)
    if scene == nil then return end
    local items = obs.obs_scene_enum_items(scene)
    if items == nil then return end
    for _, item in ipairs(items) do
        local visible = obs.obs_sceneitem_visible(item)
        if include_hidden or visible then
            local src = obs.obs_sceneitem_get_source(item)
            if src ~= nil then
                local sid = obs.obs_source_get_unversioned_id(src) or ""
                local name = obs.obs_source_get_name(src) or ""
                if sid ~= "group" and name ~= "" then
                    out_names[name] = true
                end
            end
            if obs.obs_sceneitem_is_group ~= nil and obs.obs_sceneitem_is_group(item) then
                local gscene = obs.obs_sceneitem_group_get_scene(item)
                if gscene ~= nil then
                    collect_scene_sources_recursive(gscene, include_hidden, out_names)
                end
            end
        end
    end
    obs.sceneitem_list_release(items)
end

local function rebuild_available_sources(props)
    available_sources = {}
    local scene_source, scene = get_current_scene()
    if scene ~= nil then
        local names = {}
        collect_scene_sources_recursive(scene, true, names)
        for name, _ in pairs(names) do
            table.insert(available_sources, name)
        end
        table.sort(available_sources, function(a, b) return lower(a) < lower(b) end)
    end
    if scene_source ~= nil then obs.obs_source_release(scene_source) end

    if props ~= nil then
        local p1 = obs.obs_properties_get(props, "available_source")
        if p1 ~= nil then
            obs.obs_property_list_clear(p1)
            for _, n in ipairs(available_sources) do
                obs.obs_property_list_add_string(p1, n, n)
            end
        end
        local p2 = obs.obs_properties_get(props, "excluded_available_source")
        if p2 ~= nil then
            obs.obs_property_list_clear(p2)
            for _, n in ipairs(available_sources) do
                obs.obs_property_list_add_string(p2, n, n)
            end
        end
    end
end

local function load_string_array(settings, key)
    local out = {}
    local arr = obs.obs_data_get_array(settings, key)
    if arr == nil then return out end
    local count = obs.obs_data_array_count(arr)
    for i = 0, count - 1 do
        local item = obs.obs_data_array_item(arr, i)
        if item ~= nil then
            local value = trim(obs.obs_data_get_string(item, "value") or "")
            if value ~= "" then table.insert(out, value) end
            obs.obs_data_release(item)
        end
    end
    obs.obs_data_array_release(arr)
    return out
end

local function save_string_array(key, values)
    if settings_ref == nil then return end
    local arr = obs.obs_data_array_create()
    for _, n in ipairs(values) do
        local item = obs.obs_data_create()
        obs.obs_data_set_string(item, "value", n)
        obs.obs_data_array_push_back(arr, item)
        obs.obs_data_release(item)
    end
    obs.obs_data_set_array(settings_ref, key, arr)
    obs.obs_data_array_release(arr)
end

local function add_unique_to_priority(name)
    if name == nil or name == "" or is_excluded(name) then return end
    for _, x in ipairs(selected_sources) do
        if x == name then return end
    end
    table.insert(selected_sources, name)
end

local function add_unique_to_excluded(name)
    if name == nil or name == "" then return end
    for _, x in ipairs(excluded_sources) do
        if x == name then return end
    end
    table.insert(excluded_sources, name)
end

local function fetch_hooked_data(source)
    local data = { called = false, hooked = false, title = "", executable = "" }
    local ph = obs.obs_source_get_proc_handler(source)
    if ph == nil then return data end
    local cd = obs.calldata_create()
    local ok = obs.proc_handler_call(ph, "get_hooked", cd)
    data.called = ok
    if ok then
        data.hooked = obs.calldata_bool(cd, "hooked")
        data.title = obs.calldata_string(cd, "title") or ""
        data.executable = obs.calldata_string(cd, "executable") or ""
    end
    obs.calldata_destroy(cd)
    return data
end

local function collect_visible_name_set()
    local names = {}
    local scene_source, scene = get_current_scene()
    if scene ~= nil then collect_scene_sources_recursive(scene, false, names) end
    if scene_source ~= nil then obs.obs_source_release(scene_source) end
    return names
end

local function source_to_candidate(source_name, visible_name_set)
    if is_excluded(source_name) or visible_name_set[source_name] ~= true then return nil end
    local source = obs.obs_get_source_by_name(source_name)
    if source == nil then return nil end
    local sid = obs.obs_source_get_unversioned_id(source)
    local active = obs.obs_source_active(source)
    local candidate = nil
    if active and is_supported_capture_type(sid) then
        local hook = fetch_hooked_data(source)
        if hook.called and hook.hooked then
            candidate = {
                source_name = source_name,
                executable = lower(trim(hook.executable)),
                title = lower(trim(hook.title)),
                sid = sid,
                provider = "obs_hook"
            }
        end
    end
    obs.obs_source_release(source)
    return candidate
end

local function collect_candidates_from_priority(visible_name_set)
    local out, seen = {}, {}
    for _, name in ipairs(selected_sources) do
        if not seen[name] then
            local c = source_to_candidate(name, visible_name_set)
            if c ~= nil then table.insert(out, c) end
            seen[name] = true
        end
    end
    return out
end

local function collect_candidates_from_scene(visible_name_set)
    local out = {}
    local sources = obs.obs_enum_sources()
    if sources == nil then return out end
    for _, source in ipairs(sources) do
        local name = obs.obs_source_get_name(source) or ""
        if name ~= "" and not is_excluded(name) and visible_name_set[name] then
            local sid = obs.obs_source_get_unversioned_id(source)
            if obs.obs_source_active(source) and is_supported_capture_type(sid) then
                local hook = fetch_hooked_data(source)
                if hook.called and hook.hooked then
                    table.insert(out, {
                        source_name = name,
                        executable = lower(trim(hook.executable)),
                        title = lower(trim(hook.title)),
                        sid = sid,
                        provider = "obs_hook"
                    })
                end
            end
        end
    end
    obs.source_list_release(sources)
    return out
end

local function apply_rules(candidate)
    for _, rule in ipairs(parsed_mappings) do
        if (candidate.executable ~= "" and candidate.executable:find(rule.key, 1, true) ~= nil) or
           (candidate.title ~= "" and candidate.title:find(rule.key, 1, true) ~= nil) or
           (candidate.source_name ~= "" and lower(candidate.source_name):find(rule.key, 1, true) ~= nil) then
            return rule.folder
        end
    end
    return nil
end

local function resolve_label(candidate)
    local mapped = apply_rules(candidate)
    if mapped ~= nil then return mapped end
    return canonicalize_name(candidate.executable, candidate.title, candidate.source_name)
end

local function extract_executable_from_window_selector(window_value)
    local value = trim(window_value or "")
    if value == "" then return "" end
    local exe = value:match(".*:.*:(.+)$")
    if exe == nil then return "" end
    return trim(exe)
end

local function get_executable_from_source_settings(source)
    local data = obs.obs_source_get_settings(source)
    if data == nil then return "" end
    local executable = trim(obs.obs_data_get_string(data, "executable") or "")
    if executable == "" then
        executable = extract_executable_from_window_selector(obs.obs_data_get_string(data, "window") or "")
    end
    if executable == "" then
        executable = trim(obs.obs_data_get_string(data, "application") or "")
    end
    obs.obs_data_release(data)
    return executable
end

local function build_mapping_line_from_candidate(candidate)
    local folder = canonicalize_name(candidate.executable, candidate.title, candidate.source_name)
    local key = trim(candidate.executable)
    if key == "" then key = lower(trim(candidate.source_name)) end
    if key == "" then return nil end
    return key .. "=" .. folder
end

local function build_mapping_line_from_source(source_name)
    local source = obs.obs_get_source_by_name(source_name)
    if source == nil then return nil end
    local hook = fetch_hooked_data(source)
    local executable = trim(hook.executable or "")
    local title = trim(hook.title or "")
    if executable == "" then
        executable = get_executable_from_source_settings(source)
    end
    obs.obs_source_release(source)
    if executable == "" then return nil end
    return build_mapping_line_from_candidate({
        source_name = source_name,
        executable = lower(executable),
        title = lower(title)
    })
end

local function upsert_mapping_line(new_line)
    if new_line == nil or trim(new_line) == "" then return false end
    local key = lower(trim((new_line:match("^(.-)=") or "")))
    if key == "" then return false end
    local lines = {}
    local replaced = false
    for line in (mappings_raw .. "\n"):gmatch("([^\n]*)\n") do
        local raw = trim(line)
        if raw ~= "" then
            local old_key = lower(trim((raw:match("^(.-)=") or "")))
            if old_key == key then
                if not replaced then
                    table.insert(lines, new_line)
                    replaced = true
                end
            else
                table.insert(lines, raw)
            end
        end
    end
    if not replaced then table.insert(lines, new_line) end
    mappings_raw = table.concat(lines, "\n")
    persist_mappings()
    return true
end

local function default_bridge_state_path()
    local appdata = os.getenv("APPDATA") or ""
    if appdata == "" then
        return ""
    end
    return appdata .. "\\obs-studio\\plugin_config\\" .. BRIDGE_PLUGIN_NAME .. "\\state.txt"
end

local function default_bridge_request_path()
    local appdata = os.getenv("APPDATA") or ""
    if appdata == "" then
        return ""
    end
    return appdata .. "\\obs-studio\\plugin_config\\" .. BRIDGE_PLUGIN_NAME .. "\\move_request.txt"
end

local function read_text_file(path)
    if path == nil or path == "" then return nil end
    local file = io.open(path, "rb")
    if file == nil then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function parse_state_text(text)
    local out = {}
    if text == nil then return out end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local key, value = line:match("^(.-)=(.*)$")
        if key ~= nil then
            out[trim(key)] = trim(value)
        end
    end
    return out
end

local function read_bridge_state()
    local path = default_bridge_state_path()
    local text = read_text_file(path)
    if text == nil then
        return nil, path
    end
    return parse_state_text(text), path
end

local function bridge_candidate_from_state(prefer_save_candidate)
    local state, path = read_bridge_state()
    if state == nil then
        return nil, path
    end

    local prefix = prefer_save_candidate and "save_candidate_" or "foreground_"
    local exe_path = lower(trim(state[prefix .. "exe_path"] or ""))
    local basename = lower(trim(state[prefix .. "exe_basename"] or ""))
    local title = lower(trim(state[prefix .. "title"] or ""))

    if basename == "" and exe_path == "" and title == "" then
        if prefer_save_candidate then
            return bridge_candidate_from_state(false)
        end
        return nil, path
    end

    return {
        source_name = basename ~= "" and basename or title,
        executable = exe_path ~= "" and exe_path or basename,
        title = title,
        provider = prefer_save_candidate and "plugin_save" or "plugin_foreground"
    }, path
end

local function fallback_candidate_from_obs_hooks()
    local visible_name_set = collect_visible_name_set()
    local matches = collect_candidates_from_priority(visible_name_set)
    local provider = "obs_priority"
    if #matches == 0 then
        matches = collect_candidates_from_scene(visible_name_set)
        provider = "obs_scene"
    end
    if #matches == 0 then
        return nil, provider
    end
    return matches[1], provider
end

local function collect_runtime_obs_candidates()
    local visible_name_set = collect_visible_name_set()
    local matches = collect_candidates_from_priority(visible_name_set)
    local mode = "priority"
    if #matches == 0 then
        matches = collect_candidates_from_scene(visible_name_set)
        mode = "scene"
    end
    return matches, mode
end

local function candidate_matches_plugin(plugin_candidate, obs_candidate)
    local plugin_base = basename_from_path(plugin_candidate.executable ~= "" and plugin_candidate.executable or plugin_candidate.source_name)
    local obs_base = basename_from_path(obs_candidate.executable)
    if plugin_base ~= "" and obs_base ~= "" then
        if plugin_base == obs_base or
           obs_base:find(plugin_base, 1, true) ~= nil or
           plugin_base:find(obs_base, 1, true) ~= nil then
            return true
        end
    end

    local plugin_title = lower(trim(plugin_candidate.title))
    local obs_title = lower(trim(obs_candidate.title))
    if plugin_title ~= "" and obs_title ~= "" then
        if obs_title:find(plugin_title, 1, true) ~= nil or
           plugin_title:find(obs_title, 1, true) ~= nil then
            return true
        end
    end

    local plugin_source = lower(trim(plugin_candidate.source_name))
    local obs_source = lower(trim(obs_candidate.source_name))
    if plugin_source ~= "" and obs_source ~= "" then
        if obs_source:find(plugin_source, 1, true) ~= nil or
           plugin_source:find(obs_source, 1, true) ~= nil then
            return true
        end
    end

    return false
end

local function find_matching_obs_candidate(plugin_candidate, obs_candidates)
    for _, candidate in ipairs(obs_candidates) do
        if candidate_matches_plugin(plugin_candidate, candidate) then
            return candidate
        end
    end
    return nil
end

local function build_runtime_routing(prefer_save_candidate)
    local plugin_candidate, plugin_path = bridge_candidate_from_state(prefer_save_candidate)
    local obs_candidates, obs_mode = collect_runtime_obs_candidates()

    local chosen_candidate = nil
    local provider = "default"

    if plugin_candidate ~= nil then
        local mapped_label = apply_rules(plugin_candidate)
        if mapped_label ~= nil then
            local prefix = truncate_text(normalize_segment(mapped_label), max_prefix_length)
            return {
                label = mapped_label,
                folder = normalize_segment(mapped_label),
                prefix = prefix,
                provider = prefer_save_candidate and "plugin_save_mapped" or "plugin_foreground_mapped",
                plugin_state_path = plugin_path or ""
            }
        end

        local matched = find_matching_obs_candidate(plugin_candidate, obs_candidates)
        if matched ~= nil then
            chosen_candidate = matched
            provider = prefer_save_candidate and "plugin_save_matched" or "plugin_foreground_matched"
        end
    end

    if chosen_candidate == nil and #obs_candidates > 0 then
        chosen_candidate = obs_candidates[1]
        provider = "obs_" .. obs_mode
    end

    local label = DEFAULT_LABEL
    if chosen_candidate ~= nil then
        label = resolve_label(chosen_candidate)
    end

    return {
        label = label,
        folder = normalize_segment(label),
        prefix = truncate_text(normalize_segment(label), max_prefix_length),
        provider = provider,
        plugin_state_path = plugin_path or default_bridge_state_path()
    }
end

local function safe_build_replay_format(prefer_save_candidate)
    local ok, format, info = pcall(function()
        local routing = build_runtime_routing(prefer_save_candidate)
        local format = routing.folder .. "/" .. routing.prefix .. " " .. DATETIME_TOKENS
        return format, routing
    end)

    if ok then
        return format, info
    end

    debug_log("format build error")
    return DEFAULT_LABEL .. "/" .. DEFAULT_LABEL .. " " .. DATETIME_TOKENS, {
        label = DEFAULT_LABEL,
        prefix = DEFAULT_LABEL,
        folder = DEFAULT_LABEL,
        provider = "error",
        plugin_state_path = default_bridge_state_path()
    }
end

local function get_output_directory_and_extension()
    local cfg = obs.obs_frontend_get_profile_config()
    if cfg == nil then
        return "", "mp4"
    end

    local mode = obs.config_get_string(cfg, "Output", "Mode") or ""
    local directory = ""
    local extension = "mp4"

    if mode == "Simple" then
        directory = trim(obs.config_get_string(cfg, "SimpleOutput", "FilePath") or "")
        extension = trim(obs.config_get_string(cfg, "SimpleOutput", "RecFormat") or "")
    else
        local rec_type = obs.config_get_string(cfg, "AdvOut", "RecType") or "Standard"
        if rec_type == "Standard" then
            directory = trim(obs.config_get_string(cfg, "AdvOut", "RecFilePath") or "")
            extension = trim(obs.config_get_string(cfg, "AdvOut", "RecFormat2") or "")
            if extension == "" then
                extension = trim(obs.config_get_string(cfg, "AdvOut", "RecFormat") or "")
            end
        else
            directory = trim(obs.config_get_string(cfg, "AdvOut", "FFFilePath") or "")
            extension = trim(obs.config_get_string(cfg, "AdvOut", "FFExtension") or "")
        end
    end

    directory = directory:gsub('"', "")
    extension = extension:gsub("^%.*", "")
    if extension == "" then
        extension = "mp4"
    end

    return directory, extension
end

local function build_formatting_preview_text()
    local _, info = safe_build_replay_format(false)
    local preview_name = tostring(info.prefix or DEFAULT_LABEL) .. " " .. os.date("%d.%m.%Y %H-%M")
    local output_dir, extension = get_output_directory_and_extension()
    local full_path = preview_name .. "." .. extension

    if output_dir ~= "" then
        local sep = package.config:sub(1, 1)
        full_path = output_dir .. sep .. tostring(info.folder or DEFAULT_LABEL) .. sep .. full_path
    end

    local plugin_path = info.plugin_state_path or default_bridge_state_path()
    local provider = info.provider or "default"

    return
        "Formatting result: " .. preview_name ..
        "\nSave path: " .. full_path ..
        "\nName source: " .. provider ..
        "\nBridge state: " .. plugin_path
end

local function write_bridge_move_request(folder, prefix)
    local path = default_bridge_request_path()
    if path == "" then
        return false, "bridge request path unavailable"
    end

    local file = io.open(path, "wb")
    if file == nil then
        return false, "failed to open bridge request file"
    end

    file:write("version=1\n")
    file:write("folder=", tostring(normalize_segment(folder)), "\n")
    file:write("prefix=", tostring(normalize_segment(prefix)), "\n")
    file:close()
    return true, path
end

local function split_path(path)
    local dir = path:match("^(.*)[/\\][^/\\]+$") or ""
    local file = path:match("([^/\\]+)$") or path
    local stem, ext = file:match("^(.*)(%.[^%.]+)$")
    if stem == nil then
        stem = file
        ext = ""
    end
    return dir, file, stem, ext
end

local function path_exists(path)
    local file = io.open(path, "rb")
    if file ~= nil then
        file:close()
        return true
    end
    return false
end

local function ps_escape_single_quotes(s)
    return (s or ""):gsub("'", "''")
end

local function ensure_directory(path)
    if path == "" then
        return
    end
    os.execute('mkdir "' .. path .. '" >nul 2>nul')
end

local function get_output_base_path()
    local directory = get_output_directory_and_extension()
    return trim(directory or "")
end

local function get_last_replay_path_fallback()
    local base = get_output_base_path()
    if base == "" then
        return ""
    end

    local escaped_base = ps_escape_single_quotes(base)
    local command = "powershell -NoProfile -Command \"Get-ChildItem -LiteralPath '" ..
        escaped_base ..
        "' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName\""
    local pipe = io.popen(command)
    if pipe == nil then
        return ""
    end
    local result = pipe:read("*a") or ""
    pipe:close()
    return trim(result)
end

local function get_last_replay_path()
    if obs.obs_frontend_get_last_replay ~= nil then
        local p = trim(obs.obs_frontend_get_last_replay() or "")
        if p ~= "" then
            return p
        end
    end
    return get_last_replay_path_fallback()
end

local function build_postsave_target_path(src_path, folder, prefix)
    local base = get_output_base_path()
    if base == "" then
        local src_dir = split_path(src_path)
        base = src_dir
    end

    local target_dir = base .. "\\" .. normalize_segment(folder)
    ensure_directory(target_dir)

    local _, _, _, ext = split_path(src_path)
    local name = normalize_segment(prefix) .. " " .. os.date("%d.%m.%Y %H-%M-%S")
    local target_path = target_dir .. "\\" .. name .. ext
    local index = 1

    while path_exists(target_path) do
        target_path = target_dir .. "\\" .. name .. "_" .. tostring(index) .. ext
        index = index + 1
    end

    return target_path, target_dir
end

local function move_last_replay_postsave()
    local src = get_last_replay_path()
    if src == "" then
        return false
    end
    if src == last_moved_replay_source then
        return true
    end
    if not path_exists(src) then
        return false
    end

    local folder = pending_postsave_folder
    local prefix = pending_postsave_prefix
    if folder == nil or prefix == nil then
        local routing = build_runtime_routing(true)
        folder = routing.folder
        prefix = routing.prefix
    end

    local target, target_dir = build_postsave_target_path(src, folder, prefix)
    local src_dir, src_file = split_path(src)
    local normalized_prefix = lower(normalize_segment(prefix))

    if lower(src_dir) == lower(target_dir) and
       lower(src_file):find(normalized_prefix, 1, true) == 1 then
        last_moved_replay_source = src
        return true
    end

    local ok = os.rename(src, target)
    if ok then
        last_moved_replay_source = src
        debug_log("post-save moved replay: " .. src .. " -> " .. target)
        return true
    end

    local ps_cmd = "powershell -NoProfile -Command \"Move-Item -LiteralPath '" ..
        ps_escape_single_quotes(src) .. "' -Destination '" ..
        ps_escape_single_quotes(target) .. "' -Force\""
    local ps_ok = os.execute(ps_cmd)
    if ps_ok == true or ps_ok == 0 then
        last_moved_replay_source = src
        debug_log("post-save moved replay via powershell")
        return true
    end

    return false
end

local function on_postsave_retry_timer()
    if pending_postsave_retries <= 0 then
        if postsave_timer_active then
            obs.timer_remove(on_postsave_retry_timer)
            postsave_timer_active = false
        end
        restore_replay_config_fallback()
        debug_log("post-save retries exhausted")
        return
    end

    pending_postsave_retries = pending_postsave_retries - 1
    local done = move_last_replay_postsave()
    if done and postsave_timer_active then
        obs.timer_remove(on_postsave_retry_timer)
        postsave_timer_active = false
        restore_replay_config_fallback()
    end
end

local function apply_replay_config_fallback(folder_name, prefix_name)
    local cfg = obs.obs_frontend_get_profile_config()
    if cfg == nil then
        return
    end

    if not replay_cfg_overridden then
        replay_old_prefix = obs.config_get_string(cfg, "SimpleOutput", "RecRBPrefix") or ""
        replay_old_suffix = obs.config_get_string(cfg, "SimpleOutput", "RecRBSuffix") or ""
        replay_old_filename_format = obs.config_get_string(cfg, "Output", "FilenameFormatting") or ""
        replay_cfg_overridden = true
    end

    local rb_prefix = normalize_segment(folder_name) .. "/"
    obs.config_set_string(cfg, "SimpleOutput", "RecRBPrefix", rb_prefix)
    obs.config_set_string(cfg, "SimpleOutput", "RecRBSuffix", "")
    obs.config_set_string(
        cfg,
        "Output",
        "FilenameFormatting",
        normalize_segment(prefix_name) .. " " .. DATETIME_TOKENS
    )
end

function restore_replay_config_fallback()
    if not replay_cfg_overridden then
        return
    end

    local cfg = obs.obs_frontend_get_profile_config()
    if cfg ~= nil then
        obs.config_set_string(cfg, "SimpleOutput", "RecRBPrefix", replay_old_prefix or "")
        obs.config_set_string(cfg, "SimpleOutput", "RecRBSuffix", replay_old_suffix or "")
        obs.config_set_string(cfg, "Output", "FilenameFormatting", replay_old_filename_format or "")
    end

    replay_cfg_overridden = false
end

local function apply_replay_format(reason, prefer_save_candidate)
    local format, info = safe_build_replay_format(prefer_save_candidate)
    local rb = obs.obs_frontend_get_replay_buffer_output()
    if rb ~= nil then
        local data = obs.obs_output_get_settings(rb)
        obs.obs_data_set_string(data, "format", format)
        obs.obs_output_update(rb, data)
        obs.obs_data_release(data)
        obs.obs_output_release(rb)
        debug_log("applied replay format [" .. tostring(reason) .. "]: " .. format)
    end
    apply_replay_config_fallback(info.folder, info.prefix)
    check_formatting_result = build_formatting_preview_text()
    return format, info
end

local function on_replay_buffer_saving(_)
    if not script_enabled then
        return
    end
    replay_saved_guard_ns = 0
    apply_replay_format("replay saving", true)
end

local function on_replay_buffer_saved_signal(_)
    if not script_enabled then
        return
    end

    local now_ns = get_time_ns()
    if replay_saved_guard_ns ~= 0 and (now_ns - replay_saved_guard_ns) < 1000000000 then
        debug_log("ignored duplicate replay saved event")
        return
    end
    replay_saved_guard_ns = now_ns

    local routing = build_runtime_routing(true)
    pending_postsave_folder = routing.folder
    pending_postsave_prefix = routing.prefix

    local ok, request_path = write_bridge_move_request(routing.folder, routing.prefix)
    if ok then
        debug_log("queued bridge move request: " .. tostring(request_path))
    else
        debug_log("bridge move request failed: " .. tostring(request_path))
    end

    restore_replay_config_fallback()
    check_formatting_result = build_formatting_preview_text()
end

local function connect_replay_saving_signal()
    if replay_saving_connected then return end
    local rb = obs.obs_frontend_get_replay_buffer_output()
    if rb ~= nil then
        local sh = obs.obs_output_get_signal_handler(rb)
        obs.signal_handler_connect(sh, "saving", on_replay_buffer_saving)
        obs.obs_output_release(rb)
        replay_saving_connected = true
        debug_log("connected replay saving signal")
    end
end

local function connect_replay_saved_signal()
    if replay_saved_connected then return end
    local rb = obs.obs_frontend_get_replay_buffer_output()
    if rb ~= nil then
        local sh = obs.obs_output_get_signal_handler(rb)
        obs.signal_handler_connect(sh, "saved", on_replay_buffer_saved_signal)
        obs.obs_output_release(rb)
        replay_saved_connected = true
        debug_log("connected replay saved signal")
    end
end

local function disconnect_replay_saving_signal()
    if not replay_saving_connected then return end
    local rb = obs.obs_frontend_get_replay_buffer_output()
    if rb ~= nil then
        local sh = obs.obs_output_get_signal_handler(rb)
        obs.signal_handler_disconnect(sh, "saving", on_replay_buffer_saving)
        obs.obs_output_release(rb)
    end
    replay_saving_connected = false
    debug_log("disconnected replay saving signal")
end

local function disconnect_replay_saved_signal()
    if not replay_saved_connected then return end
    local rb = obs.obs_frontend_get_replay_buffer_output()
    if rb ~= nil then
        local sh = obs.obs_output_get_signal_handler(rb)
        obs.signal_handler_disconnect(sh, "saved", on_replay_buffer_saved_signal)
        obs.obs_output_release(rb)
    end
    replay_saved_connected = false
    debug_log("disconnected replay saved signal")
end

local function on_refresh_sources_clicked(props, _)
    rebuild_available_sources(props)
    return true
end

local function on_available_source_modified(_, _, settings)
    available_source_selected = trim(obs.obs_data_get_string(settings, "available_source") or "")
    return true
end

local function on_excluded_available_source_modified(_, _, settings)
    excluded_available_source_selected = trim(obs.obs_data_get_string(settings, "excluded_available_source") or "")
    return true
end

local function on_add_selected_clicked(_, _)
    local name = available_source_selected
    if name == "" and settings_ref ~= nil then
        name = trim(obs.obs_data_get_string(settings_ref, "available_source") or "")
    end
    if name ~= "" then
        add_unique_to_priority(name)
        excluded_sources = remove_from_list(excluded_sources, name)
        rebuild_excluded_set()
        save_string_array("selected_sources", selected_sources)
        save_string_array("excluded_sources", excluded_sources)
    end
    return true
end

local function on_add_all_scene_sources_clicked(_, _)
    local scene_source, scene = get_current_scene()
    if scene ~= nil then
        local names = {}
        collect_scene_sources_recursive(scene, true, names)
        for name, _ in pairs(names) do
            add_unique_to_priority(name)
            excluded_sources = remove_from_list(excluded_sources, name)
        end
        rebuild_excluded_set()
        save_string_array("selected_sources", selected_sources)
        save_string_array("excluded_sources", excluded_sources)
    end
    if scene_source ~= nil then obs.obs_source_release(scene_source) end
    return true
end

local function on_add_from_current_hooked_clicked(_, _)
    local visible = collect_visible_name_set()
    local matches = collect_candidates_from_scene(visible)
    for _, m in ipairs(matches) do
        add_unique_to_priority(m.source_name)
        excluded_sources = remove_from_list(excluded_sources, m.source_name)
    end
    rebuild_excluded_set()
    save_string_array("selected_sources", selected_sources)
    save_string_array("excluded_sources", excluded_sources)
    return true
end

local function on_clear_priority_clicked(_, _)
    selected_sources = {}
    save_string_array("selected_sources", selected_sources)
    return true
end

local function on_add_excluded_selected_clicked(_, _)
    local name = excluded_available_source_selected
    if name == "" and settings_ref ~= nil then
        name = trim(obs.obs_data_get_string(settings_ref, "excluded_available_source") or "")
    end
    if name ~= "" then
        add_unique_to_excluded(name)
        selected_sources = remove_from_list(selected_sources, name)
        rebuild_excluded_set()
        save_string_array("selected_sources", selected_sources)
        save_string_array("excluded_sources", excluded_sources)
    end
    return true
end

local function on_add_excluded_from_hooked_clicked(_, _)
    local visible = collect_visible_name_set()
    local matches = collect_candidates_from_scene(visible)
    for _, m in ipairs(matches) do
        add_unique_to_excluded(m.source_name)
        selected_sources = remove_from_list(selected_sources, m.source_name)
    end
    rebuild_excluded_set()
    save_string_array("selected_sources", selected_sources)
    save_string_array("excluded_sources", excluded_sources)
    return true
end

local function on_clear_excluded_clicked(_, _)
    excluded_sources = {}
    rebuild_excluded_set()
    save_string_array("excluded_sources", excluded_sources)
    return true
end

local function on_build_mappings_clicked(_, _)
    if #selected_sources == 0 then
        return true
    end
    for _, src_name in ipairs(selected_sources) do
        if not is_excluded(src_name) then
            local line = build_mapping_line_from_source(src_name)
            if line ~= nil then
                upsert_mapping_line(line)
            end
        end
    end
    return true
end

local function on_dedup_mappings_clicked(_, _)
    local rules = parse_rule_block(mappings_raw)
    local key_to_folder = {}
    for _, r in ipairs(rules) do
        key_to_folder[r.key] = r.folder
    end
    local keys = {}
    for k, _ in pairs(key_to_folder) do table.insert(keys, k) end
    table.sort(keys)
    local lines = {}
    for _, k in ipairs(keys) do table.insert(lines, k .. "=" .. key_to_folder[k]) end
    mappings_raw = table.concat(lines, "\n")
    persist_mappings()
    return true
end

local function on_remove_invalid_mappings_clicked(_, _)
    local rules = parse_rule_block(mappings_raw)
    local lines = {}
    for _, r in ipairs(rules) do
        if r.key ~= "" and r.folder ~= "" then
            table.insert(lines, r.key .. "=" .. r.folder)
        end
    end
    mappings_raw = table.concat(lines, "\n")
    persist_mappings()
    return true
end

local function on_check_formatting_clicked(props, _)
    check_formatting_result = build_formatting_preview_text()
    local info = obs.obs_properties_get(props, "check_formatting_result")
    if info ~= nil then
        obs.obs_property_set_long_description(info, check_formatting_result)
    end
    return true
end

local function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTING then
        if not script_enabled then return end
        local format = safe_build_replay_format(false)
        local cfg = obs.obs_frontend_get_profile_config()
        if cfg ~= nil then
            original_filename_format = obs.config_get_string(cfg, "Output", "FilenameFormatting") or ""
            obs.config_set_string(cfg, "Output", "FilenameFormatting", format)
            format_overridden = true
            debug_log("applied recording format: " .. tostring(format))
        end
        return
    end

    if event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        if format_overridden then
            local cfg = obs.obs_frontend_get_profile_config()
            if cfg ~= nil then
                obs.config_set_string(cfg, "Output", "FilenameFormatting", original_filename_format or "")
            end
            format_overridden = false
        end
        return
    end

    if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED then
        connect_replay_saving_signal()
        connect_replay_saved_signal()
        return
    end

    if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPING or
       event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED then
        disconnect_replay_saving_signal()
        disconnect_replay_saved_signal()
        if postsave_timer_active then
            obs.timer_remove(on_postsave_retry_timer)
            postsave_timer_active = false
        end
        restore_replay_config_fallback()
    end
end

function script_description()
    return "Replay File Organizer: renames and sorts replay buffer clips into the correct folders using OBS sources, mappings, and replay save events."
end

function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_bool(props, "script_enabled", "Enable Script")
    obs.obs_properties_add_bool(props, "debug_logging", "Enable Debug Logging")

    obs.obs_properties_add_button(props, "refresh_sources", "Refresh Sources", on_refresh_sources_clicked)
    local available = obs.obs_properties_add_list(
        props, "available_source", "Available Sources",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING
    )
    obs.obs_property_set_modified_callback(available, on_available_source_modified)

    obs.obs_properties_add_button(props, "add_selected", "Add Selected", on_add_selected_clicked)
    obs.obs_properties_add_button(props, "add_all_scene", "Add All Scene Sources", on_add_all_scene_sources_clicked)
    obs.obs_properties_add_button(props, "add_from_hooked", "Add From Current Hooked", on_add_from_current_hooked_clicked)
    obs.obs_properties_add_button(props, "clear_priority", "Clear Priority List", on_clear_priority_clicked)

    obs.obs_properties_add_editable_list(
        props, "selected_sources", "Priority Sources",
        obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil
    )

    local ex_available = obs.obs_properties_add_list(
        props, "excluded_available_source", "Excluded Available Sources",
        obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING
    )
    obs.obs_property_set_modified_callback(ex_available, on_excluded_available_source_modified)
    obs.obs_properties_add_button(props, "add_excluded_selected", "Add Excluded Selected", on_add_excluded_selected_clicked)
    obs.obs_properties_add_button(props, "add_excluded_hooked", "Add Excluded From Current Hooked", on_add_excluded_from_hooked_clicked)
    obs.obs_properties_add_button(props, "clear_excluded", "Clear Excluded List", on_clear_excluded_clicked)

    obs.obs_properties_add_editable_list(
        props, "excluded_sources", "Excluded Sources",
        obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil
    )

    obs.obs_properties_add_text(
        props, "mappings_raw", "Mappings (keyword=FolderName per line)",
        obs.OBS_TEXT_MULTILINE
    )
    obs.obs_properties_add_button(props, "build_mappings", "Build Mappings From Priority Sources", on_build_mappings_clicked)
    obs.obs_properties_add_button(props, "map_dedup", "Mappings: Deduplicate", on_dedup_mappings_clicked)
    obs.obs_properties_add_button(props, "map_clean", "Mappings: Remove Invalid", on_remove_invalid_mappings_clicked)

    obs.obs_properties_add_int(props, "max_prefix_length", "Max File Prefix Length", 20, 180, 1)

    obs.obs_properties_add_button(props, "check_formatting", "Check Formatting", on_check_formatting_clicked)
    local preview = obs.obs_properties_add_text(props, "check_formatting_result", "Formatting Result", obs.OBS_TEXT_INFO)
    obs.obs_property_set_long_description(preview, check_formatting_result)

    rebuild_available_sources(props)
    return props
end

function script_defaults(settings)
    obs.obs_data_set_default_bool(settings, "script_enabled", true)
    obs.obs_data_set_default_bool(settings, "debug_logging", true)
    obs.obs_data_set_default_array(settings, "selected_sources", nil)
    obs.obs_data_set_default_array(settings, "excluded_sources", nil)
    obs.obs_data_set_default_string(settings, "mappings_raw", mappings_raw)
    obs.obs_data_set_default_int(settings, "max_prefix_length", 80)
end

function script_update(settings)
    settings_ref = settings
    script_enabled = obs.obs_data_get_bool(settings, "script_enabled")
    debug_logging = obs.obs_data_get_bool(settings, "debug_logging")
    mappings_raw = obs.obs_data_get_string(settings, "mappings_raw") or mappings_raw
    max_prefix_length = obs.obs_data_get_int(settings, "max_prefix_length")

    if max_prefix_length < 20 then max_prefix_length = 20 end

    available_source_selected = trim(obs.obs_data_get_string(settings, "available_source") or "")
    excluded_available_source_selected = trim(obs.obs_data_get_string(settings, "excluded_available_source") or "")
    selected_sources = load_string_array(settings, "selected_sources")
    excluded_sources = load_string_array(settings, "excluded_sources")
    rebuild_excluded_set()
    filter_priority_against_excluded()

    save_string_array("selected_sources", selected_sources)
    rebuild_mapping_cache()
    check_formatting_result = build_formatting_preview_text()
end

function script_load(settings)
    script_update(settings)
    obs.obs_frontend_add_event_callback(on_frontend_event)
    if obs.obs_frontend_replay_buffer_active ~= nil and obs.obs_frontend_replay_buffer_active() then
        connect_replay_saving_signal()
        connect_replay_saved_signal()
    end
end

function script_unload()
    disconnect_replay_saving_signal()
    disconnect_replay_saved_signal()
    if postsave_timer_active then
        obs.timer_remove(on_postsave_retry_timer)
        postsave_timer_active = false
    end
    restore_replay_config_fallback()
end
