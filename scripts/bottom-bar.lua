-- bottom-bar.lua —— QuickTime 布局：画面在上，uosc 的按钮条 + 进度条在下面单独一条，互不重叠
-- 做两件事：
--   1. 每次窗口大小变了，按像素把 video-margin-ratio-bottom 算成“底部留 height 像素”；
--   2. 刚打开文件时（窗口模式、非最大化），把窗口加高那一条，画面不缩、不出黑边；
--      屏幕放不下就改成按比例收窄窗口。全屏只做第 1 件。
-- 选项在 script-opts/bottom-bar.conf：
--   height=88            留几像素（uosc 默认：timeline 40 + controls 32 + 间距 16）
--   scale=1              窗口模式倍率，要和 uosc.conf 的 scale 一样
--   scale_fullscreen=1.3 全屏倍率，要和 uosc.conf 的 scale_fullscreen 一样
--   grow_window=yes      打开文件时自动加高窗口；no 则只让画面缩进去

local options = {
    height = 88,
    scale = 1,
    scale_fullscreen = 1.3,
    grow_window = true,
}
require("mp.options").read_options(options, "bottom-bar")

local last_ratio = -1
local pending_grow = false

local function bar_px(fs)
    local hidpi = mp.get_property_native("display-hidpi-scale") or 1
    return options.height * (fs and options.scale_fullscreen or options.scale) * hidpi
end

local function apply_margin(dims, fs)
    local ratio = bar_px(fs) / dims.h
    if ratio > 0.5 then ratio = 0.5 end
    if math.abs(ratio - last_ratio) < 0.0005 then return end
    last_ratio = ratio
    mp.set_property_number("video-margin-ratio-bottom", ratio)
end

-- 刚打开文件：窗口按视频尺寸开好后，再加高一条给进度条
local function grow_window(dims, fs)
    if fs or mp.get_property_native("window-maximized") then return end
    local px = math.floor(bar_px(false) + 0.5)
    local w, h = dims.w, dims.h
    local display_h = mp.get_property_native("display-height") or 0
    local new_w, new_h
    if display_h <= 0 or h + px <= display_h - 80 then
        new_w, new_h = w, h + px            -- 放得下：直接加高
    else
        new_w, new_h = math.floor((h - px) * w / h + 0.5), h   -- 放不下：高度不变，按比例收窄
    end
    if new_w < 200 or new_h < 150 then return end
    mp.set_property("geometry", string.format("%dx%d", new_w, new_h))
end

local function on_dims(_, dims)
    if not dims or not dims.w or dims.w <= 0 or dims.h <= 0 then return end
    local fs = mp.get_property_native("fullscreen")
    if pending_grow then
        pending_grow = false
        if options.grow_window then
            grow_window(dims, fs)
            return  -- 窗口变了会再触发一次 on_dims，到时再算 margin
        end
    end
    apply_margin(dims, fs)
end

local function refresh()
    on_dims(nil, mp.get_property_native("osd-dimensions"))
end

mp.observe_property("osd-dimensions", "native", on_dims)
mp.observe_property("fullscreen", "native", refresh)
mp.observe_property("display-hidpi-scale", "native", refresh)
mp.register_event("file-loaded", function()
    if mp.get_property_native("vid") == false then return end   -- 纯音频不管
    pending_grow = true
    last_ratio = -1
    refresh()
end)
