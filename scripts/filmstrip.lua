-- filmstrip.lua —— iPhone 相册看视频那种“胶片条”进度条（B 方案）
-- 底下一条由整段视频的小缩略图拼成的条，白色拖条在上面滑，拖到哪画面跟到哪；
-- 鼠标悬停时整条放大（zoom in）；左边圆形播放键，右边圆形静音键。
-- 按住拖条不动 0.35 秒 → “放大镜”模式：整条只代表当前位置前后 fine_span 秒，小图换成这一段的，
--   横着拖一屏只走这几秒，能一帧一帧停；松手回到整段。
-- Tab 键在 A（uosc 进度条）/ B（胶片条）之间切换，切到哪个会记住。
-- 选项在 script-opts/filmstrip.conf。缩略图由后台另一个 mpv 抽帧，写到 portable_config/cache/filmstrip/。

local mp = require("mp")
local utils = require("mp.utils")
local assdraw = require("mp.assdraw")
local msg = require("mp.msg")

local opts = {
    default_on = true,       -- 第一次用默认开 B 方案
    thumbs = 24,             -- 一条里最多几张小图
    strip_h = 44,            -- 平时胶片条高度（像素，会按屏幕缩放）
    strip_h_hover = 64,      -- 悬停 / 拖动 / 放大镜时的高度
    button = 36,             -- 圆形按钮直径
    pad = 14,                -- 左右边距
    gap = 12,                -- 按钮和条之间的间距
    bottom = 10,             -- 条距窗口底边
    hold_ms = 350,           -- 按住多久进放大镜模式
    fine_px_per_frame = 6,   -- 放大镜模式每帧占几像素（决定一屏几秒：30 帧视频在 1280 宽窗口约 6 秒，全屏约 14 秒）
    fine_span = 15,          -- 放大镜模式一屏最多几秒
    font = "Segoe UI",
}
require("mp.options").read_options(opts, "filmstrip")

-- 和 bottom-bar.lua 用同一套高度/倍率，保证条画在它留出来的那一截里
local bar_opts = { height = 110, scale = 1, scale_fullscreen = 1.3, grow_window = true }
require("mp.options").read_options(bar_opts, "bottom-bar")

local OVERLAY_BASE = 1          -- 小图用 overlay id 1..opts.thumbs（thumbfast 用 42，不冲突）
local PLAYHEAD_ID = 60
local ov = mp.create_osd_overlay("ass-events")

local enabled = false
local mode_file = mp.command_native({ "expand-path", "~~/filmstrip-mode" })
local cache_root = mp.command_native({ "expand-path", "~~/cache/filmstrip" })

-- 状态
local W, H = 0, 0
local L = nil                   -- 当前布局
local mouse = { x = -1, y = -1, hover = false }
local hovering_strip = false
local dragging = false
local was_playing = false
local bindings_on = false
local redraw_timer = nil
local need_redraw = false
local press_timer = nil
local press_x = 0
local fine = nil                -- 放大镜模式：{ t0=, span= }

-- 缩略图：两套，overview = 整段，fine = 放大镜那几秒
-- 每套：{ dir=, n=, thumbs={ {file=, ready=} }, t0=, span=, token=, poll=, id= }
local sets = {}
local thumb_w, thumb_h = 0, 0   -- 生成时的像素尺寸（两套一样）
local gen_counter = 0
local placed = {}               -- [slot] = key，避免重复 overlay-add
local prev_slots = 0
local playhead_file = nil
local playhead_placed = nil

----------------------------------------------------------------------
-- 小工具
----------------------------------------------------------------------
local function clamp(v, a, b) if v < a then return a elseif v > b then return b else return v end end

local function scale()
    local fs = mp.get_property_native("fullscreen")
    local hidpi = mp.get_property_native("display-hidpi-scale") or 1
    return (fs and bar_opts.scale_fullscreen or bar_opts.scale) * hidpi
end

local function col(hex, alpha)  -- "RRGGBB" -> ASS 颜色；alpha 00 不透明 .. FF 全透明
    local r, g, b = hex:sub(1, 2), hex:sub(3, 4), hex:sub(5, 6)
    return string.format("\\1c&H%s%s%s&\\1a&H%s&", b, g, r, alpha or "00")
end

local function circle(ass, cx, cy, r)
    local k = 0.5523 * r
    ass:move_to(cx + r, cy)
    ass:bezier_curve(cx + r, cy + k, cx + k, cy + r, cx, cy + r)
    ass:bezier_curve(cx - k, cy + r, cx - r, cy + k, cx - r, cy)
    ass:bezier_curve(cx - r, cy - k, cx - k, cy - r, cx, cy - r)
    ass:bezier_curve(cx + k, cy - r, cx + r, cy - k, cx + r, cy)
end

local function shape(ass, color, draw)
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord0\\shad0" .. color .. "\\p1}")
    ass:draw_start()
    draw(ass)
    ass:draw_stop()
end

local function text(ass, x, y, an, size, color, s, str)
    ass:new_event()
    ass:append(string.format("{\\an%d\\pos(%.1f,%.1f)\\fn%s\\fs%.1f\\b0\\bord%.1f\\shad0\\1c&H%s&\\3c&H000000&\\3a&H60&}%s",
        an, x, y, opts.font, size * s, 2 * s, color, str))
end

local function fmt_time(t, short)
    if not t or t < 0 then t = 0 end
    local h = math.floor(t / 3600)
    local m = math.floor(t / 60) % 60
    local sec = t - math.floor(t / 60) * 60
    if short then
        if h > 0 then return string.format("%d:%02d:%02d", h, m, math.floor(sec)) end
        return string.format("%d:%02d", m, math.floor(sec))
    end
    if h > 0 then return string.format("%d:%02d:%05.2f", h, m, sec) end
    return string.format("%d:%05.2f", m, sec)
end

local function duration() return mp.get_property_native("duration") or 0 end

-- 当前这条代表的时间窗口
local function window()
    if fine then return fine.t0, fine.span end
    return 0, duration()
end

----------------------------------------------------------------------
-- 布局
----------------------------------------------------------------------
local function layout()
    local s = scale()
    local bar_h = bar_opts.height * s
    local top = H - bar_h
    local zoom = hovering_strip or dragging or fine
    local sh = (zoom and opts.strip_h_hover or opts.strip_h) * s
    local y1 = H - opts.bottom * s
    local y0 = y1 - sh
    local cy = (y0 + y1) / 2
    local btn = opts.button * s
    local pad, gap = opts.pad * s, opts.gap * s
    local x0 = pad + btn + gap
    local x1 = W - pad - btn - gap
    L = {
        s = s, top = top, bar_h = bar_h, zoom = zoom,
        play = { cx = pad + btn / 2, cy = cy, r = btn / 2 },
        mute = { cx = W - pad - btn / 2, cy = cy, r = btn / 2 },
        strip = { x0 = x0, x1 = x1, y0 = y0, y1 = y1, w = x1 - x0, h = sh },
    }
    return L
end

local function in_bar(x, y) return L and y >= L.top and y <= H and x >= 0 and x <= W end
local function in_strip(x, y)
    if not L then return false end
    local st = L.strip
    return x >= st.x0 - 6 * L.s and x <= st.x1 + 6 * L.s and y >= st.y0 - 10 * L.s and y <= st.y1 + 10 * L.s
end
local function in_circle(c, x, y) return (x - c.cx) ^ 2 + (y - c.cy) ^ 2 <= (c.r + 4) ^ 2 end

local function x_to_time(x)
    local t0, span = window()
    return t0 + clamp((x - L.strip.x0) / L.strip.w, 0, 1) * span
end
local function time_to_x(t)
    local t0, span = window()
    if span <= 0 then return L.strip.x0 end
    return L.strip.x0 + clamp((t - t0) / span, 0, 1) * L.strip.w
end

----------------------------------------------------------------------
-- overlay 贴图
----------------------------------------------------------------------
local function remove_overlays()
    for i = 1, opts.thumbs do mp.commandv("overlay-remove", OVERLAY_BASE + i - 1) end
    placed = {}
    prev_slots = 0
end

-- 窗口尺寸/全屏/模式变了：位置全部作废，下次重贴，并假定所有格子都可能还贴着
local function invalidate_placement()
    placed = {}
    prev_slots = opts.thumbs
    playhead_placed = nil
end

-- 把小图无缝拼满整条：格子数 = ceil(条宽 / 小图自然宽)，每格从对应时间的小图中间裁一块贴上
-- （overlay-add 的 offset/stride 可以只贴位图的一个子矩形）
local function place_thumbs()
    if not enabled or not L or thumb_w == 0 then return end
    local set = fine and sets.fine or sets.overview
    local st = L.strip
    local dh = math.floor(st.h + 0.5)
    local natural_w = dh * thumb_w / thumb_h
    local n_slots = math.max(1, math.ceil(st.w / natural_w))
    if n_slots > opts.thumbs then n_slots = opts.thumbs end
    local y = math.floor(st.y0 + 0.5)
    for j = 1, n_slots do
        local x = math.floor(st.x0 + (j - 1) * st.w / n_slots + 0.5)
        local x_next = math.floor(st.x0 + j * st.w / n_slots + 0.5)
        local dw = x_next - x + (j < n_slots and 1 or 0)   -- 相邻格子重叠 1 像素，免得缩放边缘露出细缝
        local t = nil
        local idx = 0
        if set and set.n > 0 then
            -- 这一格对应的时间 → 第几张小图（小图在这套的时间窗口里均匀分布）
            local frac = (j - 0.5) / n_slots
            idx = clamp(math.floor(frac * set.n) + 1, 1, set.n)
            t = set.thumbs[idx]
        end
        if t and t.ready and dw > 0 then
            local src_w = math.min(thumb_w, math.floor(dw * thumb_h / dh + 0.5))
            local x_off = math.floor((thumb_w - src_w) / 2)
            local key = string.format("%s,%d,%d,%d,%d,%d,%d", set.kind, idx, x, y, dw, dh, x_off)
            if placed[j] ~= key then
                -- 少贴最后一行：mpv 会检查 offset + h*stride 不能超过文件大小，裁切偏移后就差这一行
                mp.commandv("overlay-add", OVERLAY_BASE + j - 1, x, y, t.file, x_off * 4, "bgra",
                    src_w, thumb_h - 1, thumb_w * 4, dw, dh)
                placed[j] = key
            end
        elseif placed[j] then
            mp.commandv("overlay-remove", OVERLAY_BASE + j - 1)
            placed[j] = nil
        end
    end
    for j = n_slots + 1, prev_slots do
        mp.commandv("overlay-remove", OVERLAY_BASE + j - 1)
        placed[j] = nil
    end
    prev_slots = n_slots
end

-- 拖条位图：白色竖条 + 半透明黑边，生成一次，之后只换位置和显示尺寸
local PH_W, PH_H = 10, 100
local function ensure_playhead_file()
    if playhead_file then return true end
    local f = utils.join_path(mp.command_native({ "expand-path", "~~/cache" }), "filmstrip-playhead.bgra")
    local fh = io.open(f, "wb")
    if not fh then return false end
    local white = string.char(255, 255, 255, 255)
    local edge = string.char(0, 0, 0, 110)     -- 预乘 alpha 的半透明黑
    local row = {}
    for x = 1, PH_W do row[#row + 1] = (x <= 2 or x > PH_W - 2) and edge or white end
    local rowstr = table.concat(row)
    local rows = {}
    for y = 1, PH_H do rows[#rows + 1] = rowstr end
    fh:write(table.concat(rows))
    fh:close()
    playhead_file = f
    return true
end

local function place_playhead(cx, y, h)
    if not ensure_playhead_file() then return end
    local dw = math.floor(PH_W * L.s + 0.5)
    local dh = math.floor(h + 0.5)
    local x = math.floor(cx - dw / 2 + 0.5)
    local yy = math.floor(y + 0.5)
    local key = string.format("%d,%d,%d,%d", x, yy, dw, dh)
    if playhead_placed == key then return end
    playhead_placed = key
    mp.commandv("overlay-add", PLAYHEAD_ID, x, yy, playhead_file, 0, "bgra", PH_W, PH_H, PH_W * 4, dw, dh)
end

local function remove_playhead()
    if playhead_placed then
        mp.commandv("overlay-remove", PLAYHEAD_ID)
        playhead_placed = nil
    end
end

----------------------------------------------------------------------
-- 画
----------------------------------------------------------------------
local function draw()
    need_redraw = false
    if not enabled or W == 0 then
        ov.data = ""
        ov:update()
        remove_playhead()
        return
    end
    layout()
    local s = L.s
    local ass = assdraw.ass_new()
    local pos = mp.get_property_native("time-pos") or 0
    local dur = duration()
    local paused = mp.get_property_native("pause")
    local muted = mp.get_property_native("mute")
    local st = L.strip

    -- 底条背景
    shape(ass, col("000000"), function(a) a:rect_cw(0, L.top, W, H) end)

    -- 胶片条底色（小图还没出来时是深灰）+ 细边；放大镜模式边框亮一点
    shape(ass, col(fine and "e0e0e0" or "3a3a3c"), function(a)
        a:round_rect_cw(st.x0 - 1.5 * s, st.y0 - 1.5 * s, st.x1 + 1.5 * s, st.y1 + 1.5 * s, 6 * s)
    end)
    shape(ass, col("1c1c1e"), function(a) a:round_rect_cw(st.x0, st.y0, st.x1, st.y1, 5 * s) end)
    place_thumbs()

    -- 播放键（圆）
    local p = L.play
    shape(ass, col("3a3a3c"), function(a) circle(a, p.cx, p.cy, p.r) end)
    if paused then
        local w, h = 12 * s, 14 * s
        shape(ass, col("ffffff"), function(a)
            a:move_to(p.cx - w / 2 + 1.5 * s, p.cy - h / 2)
            a:line_to(p.cx + w / 2 + 1.5 * s, p.cy)
            a:line_to(p.cx - w / 2 + 1.5 * s, p.cy + h / 2)
        end)
    else
        local w, h, g = 4 * s, 14 * s, 3 * s
        shape(ass, col("ffffff"), function(a)
            a:rect_cw(p.cx - g / 2 - w, p.cy - h / 2, p.cx - g / 2, p.cy + h / 2)
            a:rect_cw(p.cx + g / 2, p.cy - h / 2, p.cx + g / 2 + w, p.cy + h / 2)
        end)
    end

    -- 静音键（圆 + 小喇叭）
    local m = L.mute
    shape(ass, col("3a3a3c"), function(a) circle(a, m.cx, m.cy, m.r) end)
    local u = s * 1.1
    shape(ass, col("ffffff"), function(a)
        local ox, oy = m.cx - 6 * u, m.cy
        a:move_to(ox, oy - 3 * u); a:line_to(ox + 3 * u, oy - 3 * u); a:line_to(ox + 7 * u, oy - 6.5 * u)
        a:line_to(ox + 7 * u, oy + 6.5 * u); a:line_to(ox + 3 * u, oy + 3 * u); a:line_to(ox, oy + 3 * u)
    end)
    if muted then
        shape(ass, col("ff453a"), function(a)
            local cx, cy = m.cx + 1 * u, m.cy
            a:move_to(cx - 7 * u, cy + 6 * u); a:line_to(cx - 5.5 * u, cy + 7.5 * u)
            a:line_to(cx + 7 * u, cy - 6 * u); a:line_to(cx + 5.5 * u, cy - 7.5 * u)
        end)
    else
        shape(ass, col("ffffff"), function(a)
            local ox, oy = m.cx + 3 * u, m.cy
            a:rect_cw(ox, oy - 1 * u, ox + 2 * u, oy + 1 * u)
            a:rect_cw(ox + 3.5 * u, oy - 3.5 * u, ox + 5 * u, oy + 3.5 * u)
        end)
    end

    -- 放大镜模式：条上方画秒刻度（每秒一道，每 2 秒标时间）
    if fine then
        local t0, span = window()
        local tick_y = st.y0 - 4 * s
        local first = math.ceil(t0)
        shape(ass, col("9a9a9a"), function(a)
            for t = first, math.floor(t0 + span) do
                local x = time_to_x(t)
                a:rect_cw(x - 0.5 * s, tick_y - 5 * s, x + 0.5 * s, tick_y)
            end
        end)
        for t = first, math.floor(t0 + span) do
            if t % 2 == 0 then text(ass, time_to_x(t), tick_y - 6 * s, 2, 10, "9A9A9A", s, fmt_time(t, true)) end
        end
    end

    -- 拖条（位图 overlay，压在小图之上）
    local hx = time_to_x(pos)
    local hy0, hy1 = st.y0 - 5 * s, st.y1 + 5 * s
    place_playhead(hx, hy0, hy1 - hy0)

    -- 时间：拖动/暂停时在拖条上方显示当前时间（放大镜模式加帧号）；悬停时在鼠标处显示指到的时间
    local label_y = fine and (st.y0 - 20 * s) or (hy0 - 4 * s)
    if dragging or paused then
        local str = fmt_time(pos)
        if fine then
            local fr = mp.get_property_native("estimated-frame-number")
            if fr then str = str .. "  ·  第 " .. fr .. " 帧" end
        end
        text(ass, hx, label_y, 2, 14, "FFFFFF", s, str)
    end
    if hovering_strip and not dragging and mouse.x then
        text(ass, clamp(mouse.x, st.x0, st.x1), st.y1 + 16 * s, 2, 12, "C8C8C8", s, fmt_time(x_to_time(mouse.x)))
    end
    if (dragging or paused or hovering_strip) and not fine then
        text(ass, st.x1, st.y0 - 4 * s, 9, 11, "9A9A9A", s, fmt_time(dur))
    end

    ov.res_x, ov.res_y = W, H
    ov.data = ass.text
    ov:update()
end

local function request_redraw()
    if not enabled then return end
    if redraw_timer then need_redraw = true; return end
    draw()
    redraw_timer = mp.add_timeout(1 / 30, function()
        redraw_timer = nil
        if need_redraw then request_redraw() end
    end)
end

----------------------------------------------------------------------
-- 后台抽帧（通用：一套 = 某个时间窗口里均匀的 n 张）
----------------------------------------------------------------------
local function stop_set(kind)
    local set = sets[kind]
    if not set then return end
    if set.token then mp.abort_async_command(set.token); set.token = nil end
    if set.poll then set.poll:kill(); set.poll = nil end
end

local function cleanup_dir(dir)
    local files = utils.readdir(dir, "files")
    if files then for _, f in ipairs(files) do os.remove(utils.join_path(dir, f)) end end
end

local function ensure_dir(dir)
    if not utils.file_info(dir) then
        mp.command_native({ name = "subprocess", playback_only = false,
            args = { "cmd", "/c", "mkdir", (dir:gsub("/", "\\")) } })
    end
end

local function mpv_path()
    local p = mp.get_property_native("user-data/frontend/process-path")
    if p and p ~= "" then return p end
    local cfg = mp.get_property("config-dir")     -- 便携版：portable_config 就在 mpv.exe 旁边
    if cfg then
        local exe = utils.join_path(utils.join_path(cfg, ".."), "mpv.exe")
        if utils.file_info(exe) then return exe end
    end
    return "mpv"
end

local function check_set(set)
    local all = true
    for i = 1, set.n do
        local t = set.thumbs[i]
        if not t.ready then
            local info = utils.file_info(t.file)
            if info and info.size == thumb_w * thumb_h * 4 then
                t.ready = true
            else
                all = false
            end
        end
    end
    place_thumbs()
    if all and set.poll then set.poll:kill(); set.poll = nil end
end

-- kind: "overview" / "fine"；t0, span：时间窗口；n：张数；exact：是否精确到帧（慢，放大镜用）
local function gen_set(kind, t0, span, n, exact)
    stop_set(kind)
    local path = mp.get_property("path")
    if not path or span <= 0 or n < 1 then return end
    gen_counter = gen_counter + 1
    local dir = utils.join_path(cache_root, kind)
    ensure_dir(dir)
    cleanup_dir(dir)
    local set = { kind = kind, dir = dir, n = n, thumbs = {}, t0 = t0, span = span, id = gen_counter }
    for i = 1, n do
        set.thumbs[i] = { file = utils.join_path(dir, string.format("t%03d.bgra", i)), ready = false }
    end
    sets[kind] = set
    local step = span / n
    local args = {
        mpv_path(), "--no-config", "--msg-level=all=no", "--no-terminal",
        "--no-audio", "--no-sub", "--vd-lavc-threads=2", "--vd-lavc-skiploopfilter=all",
        "--hwdec=" .. (exact and "auto-copy" or "no"),
        "--hr-seek=" .. (exact and "yes" or "no"),
        "--start=" .. string.format("%.3f", t0 + step / 2),
        "--sstep=" .. string.format("%.3f", step),
        "--frames=" .. n,
        "--vf=scale=" .. thumb_w .. ":" .. thumb_h .. ",format=bgra",
        "--ovc=rawvideo", "--of=image2", "--ofopts=start_number=1",
        "--o=" .. utils.join_path(dir, "t%03d.bgra"),
        path,
    }
    msg.verbose(string.format("filmstrip: %s: %d thumbs %dx%d from %.2fs span %.2fs", kind, n, thumb_w, thumb_h, t0, span))
    set.token = mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
        capture_stdout = false, capture_stderr = false }, function()
        set.token = nil
        if sets[kind] ~= set then return end
        check_set(set)
        -- 关键帧抽帧时实际张数可能比预计少：按实际张数重新均分
        local k = 0
        for i = 1, set.n do if set.thumbs[i].ready then k = i else break end end
        if k < set.n then
            set.n = k
            placed = {}
            place_thumbs()
        end
        msg.verbose("filmstrip: " .. kind .. " done, " .. k .. " thumbs")
        if set.poll then set.poll:kill(); set.poll = nil end
    end)
    set.poll = mp.add_periodic_timer(0.15, function() check_set(set) end)
end

-- 决定小图尺寸和整段那套的张数，然后开抽
local function start_overview()
    stop_set("overview"); stop_set("fine")
    sets = {}
    remove_overlays()
    if not enabled then return end
    local dur = duration()
    local vp = mp.get_property_native("video-params")
    if dur <= 0 or not vp or not vp.dw or vp.dw == 0 then return end
    if mp.get_property_native("demuxer-via-network") then return end
    layout()
    local aspect = vp.dw / vp.dh
    local hidpi = mp.get_property_native("display-hidpi-scale") or 1
    thumb_h = math.floor(opts.strip_h_hover * bar_opts.scale_fullscreen * hidpi + 0.5)   -- 按最大显示高度生成
    thumb_w = math.floor(thumb_h * aspect + 0.5)
    if thumb_w % 2 == 1 then thumb_w = thumb_w + 1 end
    local base_h = opts.strip_h * L.s
    local n = clamp(math.ceil(L.strip.w / (base_h * aspect)), 6, opts.thumbs)
    gen_set("overview", 0, dur, n, false)
end

-- 打开文件那一刻视频参数（尺寸）常常还没就绪，所以等 video-params / 窗口尺寸都出来再抽
local gen_pending = false
local function maybe_start_overview()
    if not gen_pending or not enabled or W == 0 then return end
    local vp = mp.get_property_native("video-params")
    if vp and vp.dw and vp.dw > 0 and duration() > 0 then
        gen_pending = false
        start_overview()
    end
end

----------------------------------------------------------------------
-- 放大镜模式
----------------------------------------------------------------------
local function enter_fine()
    if fine or not dragging then return end
    local dur = duration()
    if dur <= 0 then return end
    local pos = mp.get_property_native("time-pos") or 0
    -- 一屏几秒：按“每帧占 fine_px_per_frame 像素”算，封顶 fine_span 秒
    layout()
    local fps = mp.get_property_native("container-fps") or mp.get_property_native("estimated-vf-fps") or 30
    if fps <= 0 then fps = 30 end
    local span = L.strip.w / (opts.fine_px_per_frame * L.s * fps)
    span = clamp(span, 2, opts.fine_span)
    span = math.min(span, dur)
    -- 鼠标现在在条的哪个比例，那个点就是当前时间（这样进放大镜那一刻画面不跳）
    local frac = clamp((mouse.x - L.strip.x0) / L.strip.w, 0, 1)
    local t0 = clamp(pos - frac * span, 0, math.max(0, dur - span))
    fine = { t0 = t0, span = span }
    invalidate_placement()
    layout()
    -- 放大镜这几秒的小图：精确到帧抽，张数按格子数
    local st = L.strip
    local n = clamp(math.ceil(st.w / (st.h * thumb_w / thumb_h)), 4, opts.thumbs)
    if thumb_w > 0 then gen_set("fine", t0, span, n, true) end
    request_redraw()
end

local function exit_fine()
    if not fine then return end
    fine = nil
    stop_set("fine")
    sets.fine = nil
    invalidate_placement()
    request_redraw()
end

----------------------------------------------------------------------
-- 鼠标
----------------------------------------------------------------------
local function seek_to_x(x)
    local t = x_to_time(x)
    mp.commandv("seek", t, "absolute+exact")
end

local function enable_bindings(on)
    if on == bindings_on then return end
    bindings_on = on
    if on then mp.enable_key_bindings("filmstrip_mouse") else mp.disable_key_bindings("filmstrip_mouse") end
end

local function cancel_press_timer()
    if press_timer then press_timer:kill(); press_timer = nil end
end

local function on_mouse_down()
    if not L then return end
    local x, y = mouse.x, mouse.y
    if in_strip(x, y) then
        dragging = true
        was_playing = not mp.get_property_native("pause")
        if was_playing then mp.set_property_native("pause", true) end
        seek_to_x(x)
        press_x = x
        cancel_press_timer()
        press_timer = mp.add_timeout(opts.hold_ms / 1000, function()
            press_timer = nil
            if dragging and not fine and math.abs(mouse.x - press_x) < 6 * L.s then enter_fine() end
        end)
        request_redraw()
    elseif in_circle(L.play, x, y) then
        mp.commandv("cycle", "pause")
    elseif in_circle(L.mute, x, y) then
        mp.commandv("cycle", "mute")
    end
end

local function on_mouse_up()
    cancel_press_timer()
    if dragging then
        dragging = false
        exit_fine()
        if was_playing then mp.set_property_native("pause", false) end
        was_playing = false
        if not in_bar(mouse.x, mouse.y) then enable_bindings(false) end
        hovering_strip = in_strip(mouse.x, mouse.y)
        request_redraw()
    end
end

local function on_mouse_pos(_, mpos)
    if not enabled or not mpos or W == 0 then return end
    mouse = mpos
    if not L then layout() end
    local over_bar = mpos.hover and in_bar(mpos.x, mpos.y)
    if dragging then
        if not fine and press_timer and math.abs(mpos.x - press_x) >= 6 * L.s then cancel_press_timer() end
        seek_to_x(mpos.x)
        return
    end
    enable_bindings(over_bar)
    local hs = over_bar and in_strip(mpos.x, mpos.y)
    if hs ~= hovering_strip then
        hovering_strip = hs
        invalidate_placement()
    end
    if hs then request_redraw() end
end

mp.set_key_bindings({
    { "mbtn_left", function() on_mouse_up() end, function() on_mouse_down() end },
    { "mbtn_left_dbl", function() end },
}, "filmstrip_mouse", "force")

----------------------------------------------------------------------
-- 开关 A / B
----------------------------------------------------------------------
local function set_uosc_elements(disabled)
    -- uosc 的运行时接口：disable-elements <script_id> <元素列表>，空字符串恢复
    mp.commandv("script-message-to", "uosc", "disable-elements", mp.get_script_name(),
        disabled and "timeline,controls,volume" or "")
end

local function save_mode()
    local f = io.open(mode_file, "w")
    if f then f:write(enabled and "on" or "off"); f:close() end
end

local function load_mode()
    local f = io.open(mode_file, "r")
    if not f then return opts.default_on end
    local v = f:read("*l"); f:close()
    return v == "on"
end

local function set_enabled(on)
    enabled = on
    set_uosc_elements(on)
    if on then
        gen_pending = true
        maybe_start_overview()
        request_redraw()
    else
        stop_set("overview"); stop_set("fine")
        sets = {}
        fine = nil
        remove_overlays()
        remove_playhead()
        enable_bindings(false)
        hovering_strip, dragging = false, false
        draw()
    end
end

mp.add_key_binding(nil, "toggle", function()
    set_enabled(not enabled)
    save_mode()
    mp.osd_message(enabled and "B：胶片条" or "A：uosc 进度条", 1)
end)

----------------------------------------------------------------------
-- 事件
----------------------------------------------------------------------
mp.observe_property("osd-dimensions", "native", function(_, d)
    if d and d.w and d.w > 0 then
        W, H = d.w, d.h
        L = nil
        invalidate_placement()
        maybe_start_overview()
        request_redraw()
    end
end)
mp.observe_property("mouse-pos", "native", on_mouse_pos)
mp.observe_property("time-pos", "number", function() request_redraw() end)
mp.observe_property("pause", "native", function() request_redraw() end)
mp.observe_property("mute", "native", function() request_redraw() end)
mp.observe_property("duration", "native", function() maybe_start_overview(); request_redraw() end)
mp.observe_property("video-params", "native", function() maybe_start_overview() end)
mp.observe_property("fullscreen", "native", function() L = nil; invalidate_placement(); request_redraw() end)
mp.register_event("file-loaded", function()
    stop_set("overview"); stop_set("fine")
    sets = {}
    fine = nil
    remove_overlays()
    if mp.get_property_native("vid") == false then return end
    gen_pending = true
    maybe_start_overview()
    request_redraw()
end)
mp.register_event("end-file", function() stop_set("overview"); stop_set("fine") end)
mp.register_event("shutdown", function()
    stop_set("overview"); stop_set("fine")
    cleanup_dir(utils.join_path(cache_root, "overview"))
    cleanup_dir(utils.join_path(cache_root, "fine"))
end)

-- 启动：等 uosc 装好再告诉它关元素
enabled = load_mode()
mp.add_timeout(0.05, function() set_uosc_elements(enabled) end)
