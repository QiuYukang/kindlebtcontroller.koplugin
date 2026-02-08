
return {
    -- 默认设备路径
    device_path = "/dev/input/event2",
    invert_layout = false,
    
    -- prev_page 上一页
    -- next_page 下一页
    -- fast_prev_page 上十页
    -- fast_next_page 下十页
    -- prev_chapter 上一章
    -- next_chapter 下一章
    -- prev_bookmark 上一书签
    -- next_bookmark 下一书签
    -- last_bookmark 最后书签
    -- decrease_brightness 减小亮度
    -- increase_brightness 增加亮度
    -- decrease_warmth 减小色温
    -- increase_warmth 增加色温
    -- decrease_font_size 减小字号
    -- increase_font_size 增加字号
    -- toggle_statusbar 切换状态栏
    -- toggle_bookmark 切换书签
    -- full_refresh 全刷屏幕
    -- go_home 返回首页

    -- 默认按键映射
    key_map = {
        [304] = "next_page",       -- A键: 下一页
        [305] = "prev_page",       -- B键: 上一页
        [306] = "next_chapter",    -- X键: 下一章
        [307] = "prev_chapter",    -- Y键: 上一章
        [308] = "decrease_brightness", -- L键: 减小亮度
        [309] = "increase_brightness", -- R键: 增加亮度
        [310] = "decrease_warmth", -- L2键: 减小色温
        [311] = "increase_warmth", -- R2键: 增加色温
        [312] = "toggle_statusbar", -- TL2键: 切换状态栏
        [313] = "toggle_bookmark", -- TR2键: 切换书签
        [314] = "full_refresh",   -- 摇杆按下: 旋转屏幕
        [316] = "go_home",         -- START键: 返回首页
    },
    
    -- 摇杆映射
    joy_map = {
        [17] = { [1] = "fast_next_page", [-1] = "fast_prev_page" }, -- 上下摇杆: 快速翻页
        [16] = { [1] = "next_bookmark", [-1] = "prev_bookmark" }  -- 左右摇杆: 上/下一个书签
    }
}