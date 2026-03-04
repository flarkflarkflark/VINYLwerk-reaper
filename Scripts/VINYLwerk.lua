--[[
 * ReaScript Name: VINYLwerk
 * Description: Professional Audio Restoration (v1.33.0 - Identity Preserved)
 * Author: flarkAUDIO
 * Version: 1.33.0
--]]

local info = debug.getinfo(1, "S")
local script_path = info.source:sub(2):match("(.*[\\\\/])")
local is_windows = reaper.GetOS():match("Win")
local cli_name = (is_windows and "vinylwerk_cli.exe" or "vinylwerk_cli")
local cli_exec = script_path .. cli_name
local preview_file = is_windows and
    (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp") .. "\\flark_vinyl_clicks.txt" or
    "/tmp/flark_vinyl_clicks.txt"

local settings = { 
    click_sens = 75, click_enabled = true, click_width = 150, 
    noise_red = 12, noise_enabled = false,
    rumble = 20, rumble_enabled = true,
    hum = 50, hum_enabled = false,
    click_data = {}
}
local is_processing = false
local poll_start_time = 0
local status_msg = "Ready."

function save_state()
    local dock, x, y, w, h = gfx.dock(-1, 0, 0, 0, 0)
    reaper.SetExtState("flarkAUDIO_VINYLwerk", "window_pos", string.format("%d,%d,%d,%d", x, y, w, h), true)
    local s = settings
    local set_str = string.format("%.1f,%s,%.1f,%.1f,%s,%.1f,%s,%.1f,%s", 
        s.click_sens, tostring(s.click_enabled), s.click_width, s.noise_red, tostring(s.noise_enabled),
        s.rumble, tostring(s.rumble_enabled), s.hum, tostring(s.hum_enabled))
    reaper.SetExtState("flarkAUDIO_VINYLwerk", "settings", set_str, true)
end

function load_state()
    local win_str = reaper.GetExtState("flarkAUDIO_VINYLwerk", "window_pos")
    local sx, sy, sw, sh = 100, 100, 450, 520
    if win_str ~= "" then
        local rx, ry, rw, rh = win_str:match("([^,]+),([^,]+),([^,]+),([^,]+)")
        if rx then sx, sy, sw, sh = tonumber(rx), tonumber(ry), tonumber(rw), tonumber(rh) end
    end
    local set_str = reaper.GetExtState("flarkAUDIO_VINYLwerk", "settings")
    if set_str ~= "" then
        local vals = {}
        for v in set_str:gmatch("([^,]+)") do table.insert(vals, v) end
        if #vals >= 9 then
            settings.click_sens = tonumber(vals[1]) or 75
            settings.click_enabled = (vals[2] == "true")
            settings.click_width = tonumber(vals[3]) or 150
            settings.noise_red = tonumber(vals[4]) or 12
            settings.noise_enabled = (vals[5] == "true")
            settings.rumble = tonumber(vals[6]) or 20
            settings.rumble_enabled = (vals[7] == "true")
            settings.hum = tonumber(vals[8]) or 50
            settings.hum_enabled = (vals[9] == "true")
        end
    end
    return sx, sy, sw, sh
end

function clear_v_markers()
    local i = reaper.CountProjectMarkers(0)
    for j = i - 1, 0, -1 do
        local retval, isrgn, pos, rgnend, name, markidx = reaper.EnumProjectMarkers3(0, j)
        if name:match("^V%-") then reaper.DeleteProjectMarker(0, markidx, isrgn) end
    end
end

function get_targets()
    local targets = {}
    local t_start, t_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    local has_time_sel = t_end > t_start
    local sel_item_count = reaper.CountSelectedMediaItems(0)
    local items_to_check = {}
    if sel_item_count > 0 then
        for i = 0, sel_item_count - 1 do table.insert(items_to_check, reaper.GetSelectedMediaItem(0, i)) end
    elseif has_time_sel then
        for i = 0, reaper.CountTracks(0) - 1 do
            local track = reaper.GetTrack(0, i)
            for j = 0, reaper.CountTrackMediaItems(track) - 1 do table.insert(items_to_check, reaper.GetTrackMediaItem(track, j)) end
        end
    end
    for _, item in ipairs(items_to_check) do
        local take = reaper.GetActiveTake(item)
        if take and not reaper.TakeIsMIDI(take) then
            local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local ilen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local proc_start = has_time_sel and math.max(ipos, t_start) or ipos
            local proc_end = has_time_sel and math.min(ipos + ilen, t_end) or (ipos + ilen)
            if proc_end > proc_start then
                table.insert(targets, { item = item, take = take, start = proc_start, duration = proc_end - proc_start, offset = proc_start - ipos, ipos = ipos, ilen = ilen })
            end
        end
    end
    return targets
end

function check_results()
    if not is_processing or poll_start_time == 0 then return end
    local f = io.open(preview_file, "r")
    if f then
        local res = f:read("*a")
        f:close()
        os.remove(preview_file)
        local click_str = res:match("CLICKS_FOUND:([^\n\r]*)")
        settings.click_data = {}
        if click_str then
            local targets = get_targets()
            local t = targets[1]
            if t then
                local take_offset = reaper.GetMediaItemTakeInfo_Value(t.take, "D_STARTOFFS")
                local count = 0
                for ts in click_str:gmatch("([^,]+)") do
                    local source_time = tonumber(ts)
                    if source_time then
                        local project_time = t.ipos + (source_time - take_offset)
                        table.insert(settings.click_data, (project_time - t.start) / t.duration)
                        if count < 500 then reaper.AddProjectMarker2(0, false, project_time, 0, "V-CLICK", -1, 0xFF4444|0x1000000) end
                        count = count + 1
                    end
                end
                status_msg = "Preview Ready. Found " .. count .. " clicks."
            end
        end
        is_processing = false
        reaper.UpdateArrange()
    elseif reaper.time_precise() - poll_start_time > 8 then
        is_processing = false
        status_msg = "Error: Timeout."
    end
end

function run_backend(mode)
    local targets = get_targets()
    if #targets == 0 then status_msg = "Nothing selected!" return end
    
    if mode == "preview" then 
        is_processing = true
        status_msg = "Previewing..."
        clear_v_markers() 
        os.remove(preview_file)
        local t = targets[1]
        local source_file = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(t.take), "")
        local take_offset = reaper.GetMediaItemTakeInfo_Value(t.take, "D_STARTOFFS")
        local cmd = string.format("\"%s\" \"%s\" \"dummy\" --detect-only --click-sens %.1f --click-width %.1f --start %.4f --duration %.4f --detect-file \"%s\"",
            cli_exec, source_file, settings.click_sens, settings.click_width, t.offset + take_offset, t.duration, preview_file)
        if is_windows then
            os.execute("start /B \"\" " .. cmd .. " > NUL 2>&1")
        else
            os.execute(cmd .. " > /dev/null 2>&1 &")
        end
        poll_start_time = reaper.time_precise()
    else
        reaper.Undo_BeginBlock()
        local original_name = reaper.GetTakeName(targets[1].take)
        local original_bounds = {}
        for _, t in ipairs(targets) do
            original_bounds[#original_bounds+1] = { track = reaper.GetMediaItem_Track(t.item), start = t.ipos, length = t.ilen }
            reaper.SetMediaItemSelected(t.item, true)
        end
        
        -- SYNC SPLIT
        reaper.Main_OnCommand(40061, 0) -- Split at time selection
        local split_targets = get_targets()
        
        for _, t in ipairs(split_targets) do
            local source_file = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(t.take), "")
            local take_offset = reaper.GetMediaItemTakeInfo_Value(t.take, "D_STARTOFFS")
            local out_file = source_file:gsub("%.([^%%.]+)$", "_restored_" .. math.floor(reaper.time_precise() * 1000) .. ".wav")
            local cmd = string.format("\"%s\" \"%s\" \"%s\" --click-sens %.1f --click-width %.1f --start %.4f --duration %.4f",
                cli_exec, source_file, out_file, settings.click_sens, settings.click_width, t.offset + take_offset, t.duration)
            
            reaper.ExecProcess(cmd, 60000) -- Blocking Sync
            
            local new_source = reaper.PCM_Source_CreateFromFile(out_file)
            reaper.SetMediaItemTake_Source(t.take, new_source)
            reaper.SetMediaItemTakeInfo_Value(t.take, "D_STARTOFFS", 0)
        end
        
        -- ATOMIC GLUE & RENAME
        reaper.Main_OnCommand(40289, 0) -- Unselect all
        for _, b in ipairs(original_bounds) do
            local count = reaper.CountTrackMediaItems(b.track)
            for i = 0, count - 1 do
                local item = reaper.GetTrackMediaItem(b.track, i)
                local ipos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local ilen = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                if ipos >= b.start - 0.1 and (ipos + ilen) <= (b.start + b.length + 0.1) then
                    reaper.SetMediaItemSelected(item, true)
                end
            end
        end
        
        reaper.SetCursorContext(1, nil) -- Focus timeline
        reaper.Main_OnCommand(40362, 0) -- Item: Glue items
        
        -- RESTORE ORIGINAL NAME
        local glued_item = reaper.GetSelectedMediaItem(0, 0)
        if glued_item then
            local glued_take = reaper.GetActiveTake(glued_item)
            if glued_take then
                reaper.GetSetMediaItemTakeInfo_String(glued_take, "P_NAME", original_name, true)
            end
        end
        
        reaper.Undo_EndBlock("VINYLwerk Restoration", -1)
        status_msg = "Done. Name preserved."
    end
    reaper.UpdateArrange()
end

function draw_slider(label, val, min, max, x, y, unit, enabled)
    local ww = gfx.w - 80
    local scale = math.min(gfx.w / 400, gfx.h / 520)
    if enabled == false then gfx.set(0.4, 0.4, 0.4, 0.5) else gfx.set(1, 1, 1, 0.8) end
    gfx.x, gfx.y = x + 35, y
    gfx.setfont(1, "Arial", math.floor(15 * scale))
    gfx.drawstr(label .. ": " .. (unit == "" and math.floor(val) or string.format("%.1f", val)) .. (unit or ""))
    local slider_y = y + (20 * scale)
    gfx.set(0.2, 0.2, 0.2, 1)
    gfx.rect(x + 35, slider_y, ww, 12 * scale, 1)
    if enabled ~= false then
        local pos = (val - min) / (max - min) * ww
        gfx.set(0.8, 0.4, 0.4, 1)
        gfx.rect(x + 35 + pos - 5, slider_y - 2, 10, 16 * scale, 1)
        if gfx.mouse_cap & 1 == 1 and gfx.mouse_x >= x + 35 and gfx.mouse_x <= x + 35 + ww and gfx.mouse_y >= slider_y - 5 and gfx.mouse_y <= slider_y + 15 then
            return math.max(min, math.min(max, (gfx.mouse_x - (x + 35)) / ww * (max - min) + min))
        end
    end
    return val
end

function draw_checkbox(state, x, y)
    local size = 20
    gfx.set(0.3, 0.3, 0.3, 1)
    gfx.rect(x, y, size, size, 1)
    if state then gfx.set(0.4, 0.8, 0.4, 1) gfx.rect(x + 4, y + 4, size - 8, size - 8, 1) end
    if gfx.mouse_cap & 1 == 1 and not last_mouse and gfx.mouse_x >= x and gfx.mouse_x <= x + size and gfx.mouse_y >= y and gfx.mouse_y <= y + size then
        return not state
    end
    return state
end

function draw_visualizer(x, y, w, h)
    gfx.set(0.05, 0.05, 0.05, 1)
    gfx.rect(x, y, w, h, 1)
    gfx.set(0.2, 0.2, 0.2, 1)
    gfx.rect(x, y, w, h, 0)
    gfx.set(1, 0, 0, 0.6)
    if settings.click_data then
        for _, rel_pos in ipairs(settings.click_data) do
            local vx = x + (rel_pos * w)
            if vx >= x and vx <= x + w then gfx.line(vx, y + 2, vx, y + h - 2) end
        end
    end
end

function main()
    local char = gfx.getchar()
    if char == 27 then os.execute("pkill -f " .. cli_name) is_processing = false status_msg = "Cancelled." end
    gfx.set(0.1, 0.1, 0.1, 1)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
    local scale = math.min(gfx.w / 400, gfx.h / 520)
    local targets = get_targets()
    local y_off = 20 * scale
    settings.click_enabled = draw_checkbox(settings.click_enabled, 20, y_off)
    settings.click_sens = draw_slider("Click Sensitivity", settings.click_sens, 0, 100, 20, y_off, "", settings.click_enabled)
    y_off = y_off + (50 * scale)
    settings.click_width = draw_slider("Max Click Width", settings.click_width, 1, 500, 20, y_off, " smp", settings.click_enabled)
    y_off = y_off + (50 * scale)
    draw_visualizer(20, y_off, gfx.w - 40, 40 * scale)
    y_off = y_off + (60 * scale)
    settings.noise_enabled = draw_checkbox(settings.noise_enabled, 20, y_off)
    settings.noise_red = draw_slider("Noise Reduction", settings.noise_red, 0, 48, 20, y_off, " dB", settings.noise_enabled)
    y_off = y_off + (50 * scale)
    settings.rumble_enabled = draw_checkbox(settings.rumble_enabled, 20, y_off)
    settings.rumble = draw_slider("Rumble Filter", settings.rumble, 0, 200, 20, y_off, " Hz", settings.rumble_enabled)
    y_off = y_off + (50 * scale)
    settings.hum_enabled = draw_checkbox(settings.hum_enabled, 20, y_off)
    settings.hum = draw_slider("Hum Filter", settings.hum, 0, 120, 20, y_off, " Hz", settings.hum_enabled)
    y_off = y_off + (70 * scale)
    local btn_w = (gfx.w - 60) / 3
    if is_processing then gfx.set(0.5, 0.3, 0.3, 1) else gfx.set(0.3, 0.3, 0.5, 1) end
    gfx.rect(20, y_off, btn_w, 40 * scale, 1)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = 20 + (btn_w/2) - 30, y_off + 12 * scale
    gfx.drawstr(is_processing and "CANCEL" or "PREVIEW")
    if gfx.mouse_cap&1==1 and not last_mouse and gfx.mouse_x>=20 and gfx.mouse_x<=20+btn_w and gfx.mouse_y>=y_off and gfx.mouse_y<=y_off+40*scale then 
        if is_processing then os.execute("pkill -f " .. cli_name) is_processing = false status_msg = "Cancelled." else run_backend("preview") end 
    end
    if not is_processing then gfx.set(0.2, 0.5, 0.2, 1) else gfx.set(0.3, 0.3, 0.3, 1) end
    gfx.rect(20 + btn_w + 10, y_off, btn_w, 40 * scale, 1)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = 20 + btn_w + 10 + (btn_w/2) - 25, y_off + 12 * scale
    gfx.drawstr("APPLY")
    if not is_processing and gfx.mouse_cap&1==1 and not last_mouse and gfx.mouse_x>=20+btn_w+10 and gfx.mouse_x<=20+2*btn_w+10 and gfx.mouse_y>=y_off and gfx.mouse_y<=y_off+40*scale then run_backend("apply") end
    gfx.set(0.4, 0.2, 0.2, 1)
    gfx.rect(20 + 2*btn_w + 20, y_off, btn_w, 40 * scale, 1)
    gfx.set(1, 1, 1, 1)
    gfx.x, gfx.y = 20 + 2*btn_w + 20 + (btn_w/2) - 20, y_off + 12 * scale
    gfx.drawstr("UNDO")
    if gfx.mouse_cap&1==1 and not last_mouse and gfx.mouse_x>=20+2*btn_w+20 and gfx.mouse_x<=gfx.w-20 and gfx.mouse_y>=y_off and gfx.mouse_y<=y_off+40*scale then reaper.Main_OnCommand(40029, 0) status_msg = "Undone." end
    if is_processing then check_results() end
    gfx.set(0.6, 0.6, 0.6, 1)
    gfx.x, gfx.y = 20, gfx.h - 25 * scale
    gfx.drawstr(status_msg)
    gfx.set(0.35, 0.35, 0.35, 1)
    gfx.setfont(1, "Arial", math.floor(11 * scale))
    gfx.x, gfx.y = gfx.w - 60, gfx.h - 20 * scale
    gfx.drawstr("v1.34.0")
    last_mouse = gfx.mouse_cap & 1 == 1
    if char >= 0 then reaper.defer(main) end
    gfx.update()
end

reaper.atexit(function() save_state() clear_v_markers() end)
local sx, sy, sw, sh = load_state()
gfx.init("VINYLwerk v1.34.0", sw, sh, 0, sx, sy)
main()
