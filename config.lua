
return {
    -- 默认设备路径
    device_path = "/dev/input/event2",

    -- 默认按键映射
    key_map = {
        [304] = "next_page",
        [305] = "next_page",
        [306] = "prev_page",
        [307] = "prev_page",
        [308] = "push_progress",
        [309] = "next_page",
        [310] = "toggle_night_mode",
        [311] = "full_refresh",
        [312] = "pull_progress",
        [313] = "push_progress",
        [314] = "full_refresh",
        [316] = "go_home",
    },
    
    -- 摇杆映射
    joy_map = {
        [16] = {
            [-1] = "decrease_brightness",
            [1] = "increase_brightness",
        },
        [17] = {
            [-1] = "decrease_warmth",
            [1] = "increase_warmth",
        },
    }
}