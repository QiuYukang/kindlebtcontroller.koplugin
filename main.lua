local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local logger = require("logger")
local DataStorage = require("datastorage")
local _ = require("gettext_btcontroller")
local ffi = require("ffi")
local C = ffi.C

local BluetoothStateManager = require("bluetooth_state_manager")

-- =======================================================
--  统一动作注册表（表驱动，单一数据源）
--  每个 action 只需在此处定义一次，即可自动用于：
--    执行、名称显示、可选列表、映射编辑
-- =======================================================

local ACTION_REGISTRY = {
    -- { id, 名称（中文默认，用 _() 包裹支持多语言）, 执行函数 }
    { id = "next_page",           name = _("下一页"),           exec = function() UIManager:sendEvent(Event:new("GotoViewRel", 1)) end },
    { id = "prev_page",           name = _("上一页"),           exec = function() UIManager:sendEvent(Event:new("GotoViewRel", -1)) end },
    { id = "fast_next_page",      name = _("下十页"),           exec = function() UIManager:sendEvent(Event:new("GotoViewRel", 10)) end },
    { id = "fast_prev_page",      name = _("上十页"),           exec = function() UIManager:sendEvent(Event:new("GotoViewRel", -10)) end },
    { id = "next_chapter",        name = _("下一章"),           exec = function() UIManager:sendEvent(Event:new("GotoNextChapter")) end },
    { id = "prev_chapter",        name = _("上一章"),           exec = function() UIManager:sendEvent(Event:new("GotoPrevChapter")) end },
    { id = "next_bookmark",       name = _("下一书签"),         exec = function() UIManager:sendEvent(Event:new("GotoNextBookmarkFromPage")) end },
    { id = "prev_bookmark",       name = _("上一书签"),         exec = function() UIManager:sendEvent(Event:new("GotoPreviousBookmarkFromPage")) end },
    { id = "last_bookmark",       name = _("最后书签"),         exec = function() UIManager:sendEvent(Event:new("GoToLatestBookmark")) end },
    { id = "increase_brightness", name = _("增加亮度"),         exec = function() UIManager:sendEvent(Event:new("IncreaseFlIntensity", 1)) end },
    { id = "decrease_brightness", name = _("减少亮度"),         exec = function() UIManager:sendEvent(Event:new("DecreaseFlIntensity", 1)) end },
    { id = "increase_warmth",     name = _("增加色温"),         exec = function() UIManager:sendEvent(Event:new("IncreaseFlWarmth", 1)) end },
    { id = "decrease_warmth",     name = _("减少色温"),         exec = function() UIManager:sendEvent(Event:new("IncreaseFlWarmth", -1)) end },
    { id = "increase_font_size",  name = _("增大字号"),         exec = function() UIManager:sendEvent(Event:new("IncreaseFontSize", 1)) end },
    { id = "decrease_font_size",  name = _("减小字号"),         exec = function() UIManager:sendEvent(Event:new("DecreaseFontSize", 1)) end },
    { id = "toggle_statusbar",    name = _("显示/隐藏状态栏"),  exec = function() UIManager:sendEvent(Event:new("ToggleFooterMode")) end },
    { id = "toggle_bookmark",     name = _("添加/取消书签"),    exec = function() UIManager:sendEvent(Event:new("ToggleBookmark")) end },
    { id = "toggle_night_mode",   name = _("切换夜间模式"),     exec = function() UIManager:sendEvent(Event:new("ToggleNightMode")) end },
    { id = "full_refresh",        name = _("全刷屏幕"),         exec = function() UIManager:sendEvent(Event:new("FullRefresh")) end },
    { id = "go_home",             name = _("返回首页"),         exec = function() UIManager:sendEvent(Event:new("Home")) end },
    { id = "push_progress",       name = _("上传阅读进度"),     exec = function() UIManager:sendEvent(Event:new("KOSyncPushProgress")) end },
    { id = "pull_progress",       name = _("拉取阅读进度"),     exec = function() UIManager:sendEvent(Event:new("KOSyncPullProgress")) end },
    { id = "sync_book_stat",      name = _("同步阅读统计"),     exec = function() UIManager:sendEvent(Event:new("SyncBookStats")) end },
    { id = "screenshot",          name = _("截图"),             exec = function() UIManager:sendEvent(Event:new("Screenshot")) end },
}

-- 从注册表构建快速查找索引
local ACTION_EXEC_MAP = {}   -- id -> 执行函数
local ACTION_NAME_MAP = {}   -- id -> 显示名称
local ACTION_ID_LIST = {}    -- 有序 id 列表（用于 UI 选择）

for _, entry in ipairs(ACTION_REGISTRY) do
    ACTION_EXEC_MAP[entry.id] = entry.exec
    ACTION_NAME_MAP[entry.id] = entry.name
    table.insert(ACTION_ID_LIST, entry.id)
end

-- 按键名称表
local KEY_NAMES = {
    [304] = _("A键"), [305] = _("B键"), [306] = _("X键"), [307] = _("Y键"),
    [308] = _("L键"), [309] = _("R键"), [310] = _("L2键"), [311] = _("R2键"),
    [312] = _("TL2键"), [313] = _("TR2键"), [314] = _("摇杆按下"), [315] = _("START键"),
    [316] = _("HOME键"), [317] = _("左摇杆"), [318] = _("右摇杆"),
    [103] = _("上方向"), [108] = _("下方向"), [105] = _("左方向"), [106] = _("右方向"),
    [28] = _("ENTER键"), [1] = _("ESC键"), [57] = _("SPACE键"),
}


-- =======================================================
--  需要忽略的系统按键码
-- =======================================================
local IGNORED_KEY_CODES = {
    [10002] = true,
    [10001] = true,
}

-- =======================================================
--  BluetoothController 定义
-- =======================================================

local BluetoothController = WidgetContainer:extend {
    name = "BluetoothController",

    last_action_time = 0,
    target_state = false,

    -- 按键检测状态
    testing_mode = false,

    config = {},

    -- 设置文件路径
    settings_file = DataStorage:getSettingsDir() .. "/kindlebtcontroller.lua",

    -- 自动重连定时器标记
    reconnect_timer_active = false,
    RECONNECT_INTERVAL = 2,       -- 检测间隔（秒）
    RECONNECT_RELOAD_DELAY = 1,   -- 重连后延迟重载（秒）
}

-- =======================================================
--  初始化
-- =======================================================

function BluetoothController:init()
    logger.info("BT Plugin: Initializing")

    if not Device:isKindle() then
        logger.info("BT Plugin: Not a Kindle device, skipping")
        return
    end

    self:loadConfig()
    self:loadSettings()

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:registerInputHook()

    _G.KOBluetoothStateManager = BluetoothStateManager:getInstance()

    -- 只在首次初始化时连接设备并启动重连检测
    -- 第二次初始化（打开书籍时）跳过，避免与 KOReader 内部的设备管理冲突
    if not _G._bt_device_initialized then
        _G._bt_device_initialized = true
        if self:validateDevicePath() then
            self:ensureConnected()
        end
        self:startReconnectWatcher()
    end

    logger.info("BT Plugin: Initialization complete")
end

-- =======================================================
--  配置加载与保存
-- =======================================================

function BluetoothController:loadConfig()
    local config_path = self.path .. "/config.lua"
    local file = io.open(config_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local func = loadstring(content)
        if func then
            self.config = func()
            return
        end
    end
    logger.warn("BT Plugin: Cannot found config.lua, using empty config")
end

function BluetoothController:loadSettings()
    local file = io.open(self.settings_file, "r")
    if not file then
        self:saveSettings()
        return
    end

    local content = file:read("*all")
    file:close()
    local func = loadstring(content)
    if not func then return end

    local user_settings = func()
    if not user_settings then return end

    -- 合并用户设置到默认配置
    -- key_map 和 joy_map 整体替换（用户自定义后以用户的为准，避免删除的映射被默认值"复活"）
    local replace_keys = { key_map = true, joy_map = true }
    for key, value in pairs(user_settings) do
        if replace_keys[key] then
            self.config[key] = value
        elseif type(value) == "table" and type(self.config[key]) == "table" then
            for sub_key, sub_value in pairs(value) do
                self.config[key][sub_key] = sub_value
            end
        else
            self.config[key] = value
        end
    end
end

function BluetoothController:saveSettings()
    local file = io.open(self.settings_file, "w")
    if not file then return end

    local function serialize(object, level)
        level = level or 0
        local indent = string.rep("    ", level)
        local next_indent = string.rep("    ", level + 1)

        if type(object) == "table" then
            local parts = { "{\n" }
            local keys = {}
            for key in pairs(object) do table.insert(keys, key) end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

            for _, key in ipairs(keys) do
                local key_str = type(key) == "number"
                        and "[" .. key .. "]"
                        or  "[\"" .. tostring(key) .. "\"]"
                table.insert(parts, next_indent .. key_str .. " = " .. serialize(object[key], level + 1) .. ",\n")
            end
            table.insert(parts, indent .. "}")
            return table.concat(parts)
        elseif type(object) == "string" then
            return string.format("%q", object)
        else
            return tostring(object)
        end
    end

    file:write("return " .. serialize(self.config))
    file:close()
end

-- =======================================================
--  输入钩子管理
-- =======================================================

function BluetoothController:registerInputHook()
    -- 使用全局变量存储当前活跃的 controller 实例
    -- KOReader 的 registerEventAdjustHook 是链式调用，无法移除已注册的钩子
    -- 所以只注册一次钩子，通过全局变量引用当前活跃实例
    _G._bt_controller_instance = self

    if _G._bt_hook_registered then
        logger.info("BT Plugin: Hook already registered, updated controller instance")
        return
    end

    local hook_func = function(_input_instance, ev)
        local controller = _G._bt_controller_instance
        if controller then
            controller:handleInputEvent(ev)
        end
    end

    Device.input:registerEventAdjustHook(hook_func)
    _G._bt_hook_registered = true
    logger.info("BT Plugin: Hook registered (first time)")
end

-- =======================================================
--  设备连接管理
-- =======================================================

--- 检测 device_path 是否指向了 Kindle 系统设备（触摸屏、电源键、手写笔等）
--- 检测方式：
---   1. 检查设备是否已被 KOReader 打开（opened_devices）
---   2. 检查设备名称是否匹配已知的 Kindle 系统设备
function BluetoothController:validateDevicePath()
    local path = self.config.device_path
    if not path then return true end

    -- 读取设备名称，用于日志和提示
    local device_name = self:getInputDeviceName(path)
    logger.info(string.format("BT Plugin: Configured device_path = %s, device_name = %s",
            path, tostring(device_name or "unknown")))

    local is_system_device = false
    local reason = ""

    -- 检测 1：设备是否已被 KOReader 打开（触摸屏、电源键等在 KOReader 启动时就会被打开）
    local input = Device.input
    if input and input.opened_devices and input.opened_devices[path] then
        is_system_device = true
        reason = "already opened by KOReader"
    end

    -- 检测 2：设备名称是否匹配已知的 Kindle 系统设备
    if not is_system_device and device_name then
        local known_system_devices = {
            "pt_mt",            -- Kindle 触摸屏 (multi-touch)
            "bd71828-pwrkey",   -- Kindle 电源键
        }
        local lower_name = device_name:lower()
        for _i, known_name in ipairs(known_system_devices) do
            if lower_name == known_name then
                is_system_device = true
                reason = "matches known system device name"
                break
            end
        end
    end

    if is_system_device then
        local display_name = device_name or path
        logger.warn(string.format("BT Plugin: WARNING - device_path %s is a system device (%s): %s",
                path, reason, display_name))
        UIManager:scheduleIn(2, function()
            UIManager:show(InfoMessage:new{
                text = string.format(
                        _("⚠️ 蓝牙控制器配置错误！\n\n设备路径 %s 是 KOReader 已打开的系统设备「%s」（如触摸屏或电源键），而非蓝牙控制器。\n\n请修改 config.lua 中的 device_path。\n\n提示：使用 ls /dev/input 查看设备列表，蓝牙控制器通常是编号最大的 eventX。"),
                        path, display_name
                ),
            })
        end)
        return false
    end

    return true
end

--- 读取输入设备的名称（通过 /sys/class/input/eventX/device/name）
function BluetoothController:getInputDeviceName(path)
    local event_name = path:match("(event%d+)$")
    if not event_name then return nil end

    local sys_name_path = "/sys/class/input/" .. event_name .. "/device/name"
    local file = io.open(sys_name_path, "r")
    if not file then return nil end

    local device_name = file:read("*l")
    file:close()
    return device_name
end

function BluetoothController:ensureConnected()
    local input = Device.input
    local path = self.config.device_path
    if not input or not path then return false end

    if input.opened_devices and input.opened_devices[path] then
        return true
    end

    local file = io.open(path, "r")
    if not file then
        logger.info("BT Plugin: Device " .. path .. " not found")
        return false
    end
    file:close()

    logger.warn("BT Plugin: Connecting to " .. path)
    local ok, err = pcall(function() input:open(path) end)
    if not ok then
        logger.warn("BT Plugin: Failed to open -> " .. tostring(err))
    end
    return ok
end

function BluetoothController:reloadDevice()
    local input = Device.input
    local path = self.config.device_path
    if not input or not path then return false end

    if input.opened_devices and input.opened_devices[path] then
        logger.warn("BT Plugin: Closing old connection " .. path)
        pcall(function() input:close(path) end)
    end

    logger.warn("BT Plugin: Re-opening " .. path)
    local ok, _err = pcall(function() input:open(path) end)

    -- 重新注册输入钩子，确保 close/open 后钩子仍然有效
    if ok then
        self:registerInputHook()
    end

    return ok
end

--- 检查蓝牙设备是否可用（蓝牙开启 + 设备文件存在）
function BluetoothController:isDeviceAvailable()
    if not _G.KOBluetoothStateManager or not _G.KOBluetoothStateManager:isOn() then
        return false
    end
    local path = self.config.device_path
    if not path then return false end
    local file = io.open(path, "r")
    if file then
        file:close()
        return true
    end
    return false
end

-- =======================================================
--  自动重连检测
-- =======================================================

function BluetoothController:startReconnectWatcher()
    -- 使用全局变量防止多个实例重复启动 watcher
    if _G._bt_reconnect_active then return end
    _G._bt_reconnect_active = true
    _G._bt_reconnect_in_progress = false
    _G._bt_was_connected = self:isDeviceAvailable()
    self:scheduleReconnectCheck()
end

function BluetoothController:stopReconnectWatcher()
    _G._bt_reconnect_active = false
    _G._bt_reconnect_in_progress = false
end

function BluetoothController:scheduleReconnectCheck()
    if not _G._bt_reconnect_active then return end

    UIManager:scheduleIn(self.RECONNECT_INTERVAL, function()
        if not _G._bt_reconnect_active then return end
        -- 始终使用全局实例，确保操作的是当前活跃的 controller
        local controller = _G._bt_controller_instance
        if not controller then return end

        local available_now = controller:isDeviceAvailable()

        if available_now and not _G._bt_was_connected and not _G._bt_reconnect_in_progress then
            _G._bt_was_connected = true
            _G._bt_reconnect_in_progress = true
            logger.info("BT Plugin: Device reconnected, will reload in 1s")
            UIManager:scheduleIn(controller.RECONNECT_RELOAD_DELAY, function()
                _G._bt_reconnect_in_progress = false
                local ctrl = _G._bt_controller_instance
                if not ctrl then return end
                if ctrl:isDeviceAvailable() then
                    local ok = ctrl:reloadDevice()
                    local device_name = ctrl:getConnectedDeviceName() or _("未知设备")
                    if ok then
                        UIManager:show(InfoMessage:new{
                            text = string.format(_("蓝牙设备已连接：%s"), device_name),
                            timeout = 2
                        })
                    end
                end
            end)
        elseif not available_now and _G._bt_was_connected then
            _G._bt_was_connected = false
            UIManager:show(InfoMessage:new{
                text = _("蓝牙设备已断开"),
                timeout = 2,
            })
        end
        -- 继续下一轮检测（通过当前活跃实例调用）
        if controller then
            controller:scheduleReconnectCheck()
        end
    end)
end

-- =======================================================
--  蓝牙设备名称获取
-- =======================================================

function BluetoothController:getConnectedDeviceName()
    local handle = io.popen("lipc-get-prop com.lab126.btfd BTconnectedDevName 2>/dev/null")
    if not handle then return nil end
    local result = handle:read("*a")
    handle:close()

    if result then
        result = result:gsub("^%s*(.-)%s*$", "%1")
        if result ~= "" then
            return result
        end
    end
    return nil
end



-- =======================================================
--  蓝牙硬件状态控制
-- =======================================================

function BluetoothController:setBluetoothState(enable)
    local flight_mode_value = enable and 0 or 1
    os.execute(string.format("lipc-set-prop com.lab126.btfd BTflightMode %d", flight_mode_value))
    local msg = enable and _("蓝牙已开启") or _("蓝牙已禁用")
    UIManager:show(InfoMessage:new{ text = msg, timeout = 2 })
end

function BluetoothController:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_kindle_bluetooth", {
        category = "none",
        event = "ToggleBluetooth",
        title = _("开/关 蓝牙"),
        device = true,
    })
    Dispatcher:registerAction("bluetooth_reload_device", {
        category = "none",
        event = "BluetoothReloadDevice",
        title = _("重载蓝牙设备"),
        device = true,
    })
    Dispatcher:registerAction("bluetooth_key_tester", {
        category = "none",
        event = "BluetoothKeyTester",
        title = _("按键检测"),
        device = true,
    })
    Dispatcher:registerAction("bluetooth_key_config", {
        category = "none",
        event = "BluetoothKeyConfig",
        title = _("按键配置"),
        device = true,
    })
end

function BluetoothController:onBluetoothKeyTester()
    self:startKeyTester()
end

function BluetoothController:onBluetoothKeyConfig()
    self:showKeyMappingEditor()
end

function BluetoothController:onToggleBluetooth()
    local now = os.time()
    local next_state
    if (now - self.last_action_time) < 2 then
        next_state = not self.target_state
    else
        next_state = not _G.KOBluetoothStateManager:isOn()
    end
    self.target_state = next_state
    self.last_action_time = now
    self:setBluetoothState(next_state)
    _G.KOBluetoothStateManager:_updateState()
end

function BluetoothController:onBluetoothReloadDevice()
    self:loadSettings()
    if self:reloadDevice() then
        local device_name = self:getConnectedDeviceName() or _("未知")
        UIManager:show(InfoMessage:new{
            text = string.format(_("✓ 蓝牙设备已连接：%s"), device_name),
            timeout = 2,
        })
    else
        UIManager:show(InfoMessage:new{ text = _("✗ 蓝牙设备连接失败"), timeout = 2 })
    end
end

-- =======================================================
--  输入事件处理
-- =======================================================

function BluetoothController:handleInputEvent(ev)
    -- 按键检测模式：拦截所有按键和摇杆事件
    if self.testing_mode then
        self:handleTestModeEvent(ev)
        return
    end

    -- 检查是否是需要忽略的系统按键
    if IGNORED_KEY_CODES[ev.code] then
        logger.info(string.format("BT Plugin: Ignored system key code: %d", ev.code))
        return
    end

    local actions = nil

    if ev.type == C.EV_KEY and (ev.value == 1 or ev.value == 2) then
        actions = self:resolveActions(self.config.key_map, ev.code)
    elseif ev.type == C.EV_ABS and ev.value ~= 0 and not self:isTouchscreenAbsEvent(ev.code) then
        local axis_map = self.config.joy_map and self.config.joy_map[ev.code]
        if axis_map then
            actions = self:resolveActions(axis_map, ev.value)
        end
    end

    if actions then
        logger.info(string.format("BT Plugin: Matched ev(type=%d code=%d value=%d) → %s",
                ev.type, ev.code, ev.value, table.concat(actions, ", ")))
        for _, action_id in ipairs(actions) do
            self:executeAction(action_id)
        end
        ev.type = -1
    else
        -- 未匹配映射的按键/摇杆事件，弹出提示
        if ev.type == C.EV_KEY and (ev.value == 1 or ev.value == 2) then
            local key_name = self:getKeyName(ev.code)
            UIManager:show(InfoMessage:new{
                text = string.format(_("按键 %s（%d）未配置映射"), key_name, ev.code),
                timeout = 1,
            })
        elseif ev.type == C.EV_ABS and ev.value ~= 0 and not self:isTouchscreenAbsEvent(ev.code) then
            UIManager:show(InfoMessage:new{
                text = string.format(_("摇杆 轴%d值%d 未配置映射"), ev.code, ev.value),
                timeout = 1,
            })
        end
    end
end

--- 从映射表中解析 action 列表，支持单个字符串或数组
function BluetoothController:resolveActions(mapping_table, key)
    if not mapping_table then return nil end
    local value = mapping_table[key]
    if not value then return nil end

    if type(value) == "string" then
        return { value }
    elseif type(value) == "table" then
        return value
    end
    return nil
end

-- =======================================================
--  统一动作执行（表驱动）
-- =======================================================

function BluetoothController:executeAction(action_id)
    local exec_func = ACTION_EXEC_MAP[action_id]
    if exec_func then
        exec_func(self)
    else
        logger.warn("BT Plugin: Unknown action: " .. tostring(action_id))
    end
end

-- =======================================================
--  按键检测功能（简化版：立即弹出提示）
-- =======================================================

function BluetoothController:startKeyTester()
    if self.testing_mode then return end

    self.testing_mode = true
    -- 存储结构化检测记录：{ event_type="key"|"axis", code=N, value=N }
    self.test_detected_events = {}
    self.test_refresh_pending = false

    logger.info("BT Plugin: Key tester started")
    self:showTestDialog()
end

--- 获取某个检测事件当前的映射描述
function BluetoothController:getTestEventMappingDisplay(event)
    if event.event_type == "key" then
        local mapping = self.config.key_map and self.config.key_map[event.code]
        if mapping then
            return self:formatMappingActions(mapping)
        end
    elseif event.event_type == "axis" then
        local axis_map = self.config.joy_map and self.config.joy_map[event.code]
        if axis_map then
            local mapping = axis_map[event.value]
            if mapping then
                return self:formatMappingActions(mapping)
            end
        end
    end
    return nil
end

function BluetoothController:showTestDialog()
    local ButtonDialog = require("ui/widget/buttondialog")

    if self.test_dialog then
        UIManager:close(self.test_dialog)
        self.test_dialog = nil
    end

    local button_rows = {}

    if #self.test_detected_events > 0 then
        -- 只显示最近 6 条，避免对话框过长
        local start_index = math.max(1, #self.test_detected_events - 5)
        for i = start_index, #self.test_detected_events do
            local event = self.test_detected_events[i]
            local label
            local mapping_display = self:getTestEventMappingDisplay(event)

            if event.event_type == "key" then
                label = string.format("%s（%d）", self:getKeyName(event.code), event.code)
            else
                label = string.format(_("轴%d 值%d"), event.code, event.value)
            end

            if mapping_display then
                label = label .. " → " .. mapping_display
            else
                label = label .. " → " .. _("未映射")
            end

            -- 每条记录一行：显示信息 + 编辑按钮
            local captured_event = event
            table.insert(button_rows, {
                {
                    text = label,
                    callback = function()
                        -- 暂停检测模式，打开编辑界面
                        self:editTestEventMapping(captured_event)
                    end,
                },
            })
        end

        if start_index > 1 then
            table.insert(button_rows, {
                { text = string.format(_("...共检测到 %d 个按键"), #self.test_detected_events), enabled = false },
            })
        end
    end

    -- 底部按钮
    table.insert(button_rows, {
        {
            text = _("退出检测"),
            callback = function()
                self:stopKeyTester()
            end,
        },
    })

    local title = _("按键检测（按手柄按键，点击可编辑映射）")
    if #self.test_detected_events == 0 then
        title = _("按键检测\n请按手柄按键...")
    end

    self.test_dialog = ButtonDialog:new{
        title = title,
        buttons = button_rows,
    }
    UIManager:show(self.test_dialog)
    self.test_refresh_pending = false
end

--- 从检测界面编辑某个按键的映射
function BluetoothController:editTestEventMapping(event)
    local mapping_type, code, value
    if event.event_type == "key" then
        mapping_type = "key"
        code = event.code
        value = nil
    else
        mapping_type = "axis"
        code = event.code
        value = event.value
    end

    local has_mapping = false
    if mapping_type == "key" then
        has_mapping = self.config.key_map and self.config.key_map[code] ~= nil
    else
        has_mapping = self.config.joy_map and self.config.joy_map[code] and self.config.joy_map[code][value] ~= nil
    end

    if has_mapping then
        -- 已有映射，弹出编辑/删除界面
        self:editSingleMapping(mapping_type, code, value, function()
            self:showTestDialog()
        end)
    else
        -- 无映射，直接进入选择动作界面
        local title
        if mapping_type == "key" then
            title = string.format(_("为 %s（键码 %d）选择动作"), self:getKeyName(code), code)
        else
            title = string.format(_("为 轴%d值%d 选择动作"), code, value)
        end
        self:selectActions(title, function(selected_actions)
            self:saveMappingAndApply(mapping_type,
                    mapping_type == "key" and code or nil,
                    mapping_type == "axis" and code or nil,
                    value, selected_actions,
                    function() self:showTestDialog() end)
        end)
    end
end

--- 判断 EV_ABS 事件是否来自触摸屏（而非手柄摇杆）
function BluetoothController:isTouchscreenAbsEvent(code)
    return code >= 47 and code <= 63
end

--- 请求刷新检测对话框（防抖：多次快速按键只刷新一次）
function BluetoothController:requestTestDialogRefresh()
    if self.test_refresh_pending then return end
    self.test_refresh_pending = true
    UIManager:nextTick(function()
        if self.testing_mode then
            self:showTestDialog()
        end
    end)
end

function BluetoothController:handleTestModeEvent(ev)
    if ev.type == C.EV_KEY and (ev.value == 1 or ev.value == 2) then
        local key_name = KEY_NAMES[ev.code] or _("未知键")
        logger.info(string.format("BT Plugin: Test detected key: %s (code=%d)", key_name, ev.code))
        table.insert(self.test_detected_events, {
            event_type = "key",
            code = ev.code,
        })
        self:requestTestDialogRefresh()
        ev.type = -1
    elseif ev.type == C.EV_ABS and ev.value ~= 0 and not self:isTouchscreenAbsEvent(ev.code) then
        logger.info(string.format("BT Plugin: Test detected axis: code=%d value=%d", ev.code, ev.value))
        table.insert(self.test_detected_events, {
            event_type = "axis",
            code = ev.code,
            value = ev.value,
        })
        self:requestTestDialogRefresh()
        ev.type = -1
    end
end

function BluetoothController:stopKeyTester()
    if not self.testing_mode then return end
    self.testing_mode = false
    self.test_refresh_pending = false
    logger.info("BT Plugin: Key tester stopped")

    if self.test_dialog then
        UIManager:close(self.test_dialog)
        self.test_dialog = nil
    end

    self.test_detected_events = {}
end

-- =======================================================
--  辅助函数
-- =======================================================

function BluetoothController:getActionName(action_id)
    return ACTION_NAME_MAP[action_id] or action_id
end

function BluetoothController:getKeyName(code)
    return KEY_NAMES[code] or string.format(_("键码%d"), code)
end

--- 格式化映射值用于显示（支持单个和多个 action）
function BluetoothController:formatMappingActions(value)
    if type(value) == "string" then
        return self:getActionName(value)
    elseif type(value) == "table" then
        local names = {}
        for _, action_id in ipairs(value) do
            table.insert(names, self:getActionName(action_id))
        end
        return table.concat(names, " + ")
    end
    return _("未知")
end

-- =======================================================
--  按键映射编辑器（统一查看/编辑/添加界面）
-- =======================================================

function BluetoothController:showKeyMappingEditor()
    local ButtonDialog = require("ui/widget/buttondialog")

    if self.mapping_editor_dialog then
        UIManager:close(self.mapping_editor_dialog)
        self.mapping_editor_dialog = nil
    end

    local button_rows = {}

    -- 设备路径（显示在最上方，不可点击）
    local device_path = self.config.device_path or _("未设置")
    table.insert(button_rows, {
        { text = string.format(_("设备路径：%s"), device_path), enabled = false },
    })

    -- 按键映射列表
    if self.config.key_map and next(self.config.key_map) then
        local sorted_codes = {}
        for code in pairs(self.config.key_map) do table.insert(sorted_codes, code) end
        table.sort(sorted_codes)

        for _i, code in ipairs(sorted_codes) do
            local display = self:formatMappingActions(self.config.key_map[code])
            table.insert(button_rows, {
                {
                    text = string.format("%s → %s", self:getKeyName(code), display),
                    callback = function()
                        UIManager:close(self.mapping_editor_dialog)
                        self:editSingleMapping("key", code, nil, function()
                            self:showKeyMappingEditor()
                        end)
                    end,
                },
            })
        end
    end

    -- 摇杆映射列表
    if self.config.joy_map and next(self.config.joy_map) then
        local sorted_axes = {}
        for code in pairs(self.config.joy_map) do table.insert(sorted_axes, code) end
        table.sort(sorted_axes)

        for _i, axis_code in ipairs(sorted_axes) do
            local axis_map = self.config.joy_map[axis_code]
            if axis_map then
                local sorted_values = {}
                for value in pairs(axis_map) do table.insert(sorted_values, value) end
                table.sort(sorted_values)
                for _j, value in ipairs(sorted_values) do
                    local display = self:formatMappingActions(axis_map[value])
                    table.insert(button_rows, {
                        {
                            text = string.format(_("轴%d值%d → %s"), axis_code, value, display),
                            callback = function()
                                UIManager:close(self.mapping_editor_dialog)
                                self:editSingleMapping("axis", axis_code, value, function()
                                    self:showKeyMappingEditor()
                                end)
                            end,
                        },
                    })
                end
            end
        end
    end

    if #button_rows == 0 then
        table.insert(button_rows, {
            { text = _("暂无映射"), enabled = false },
        })
    end

    -- 底部操作按钮
    table.insert(button_rows, {
        {
            text = _("＋ 添加映射"),
            callback = function()
                UIManager:close(self.mapping_editor_dialog)
                self:addKeyMapping(function()
                    self:showKeyMappingEditor()
                end)
            end,
        },
        {
            text = _("关闭"),
            callback = function()
                UIManager:close(self.mapping_editor_dialog)
            end,
        },
    })

    self.mapping_editor_dialog = ButtonDialog:new{
        title = _("按键配置（点击可编辑）"),
        buttons = button_rows,
    }
    UIManager:show(self.mapping_editor_dialog)
end

-- =======================================================
--  添加按键映射
-- =======================================================

function BluetoothController:addKeyMapping(on_done)
    local ButtonDialog = require("ui/widget/buttondialog")

    local type_dialog
    type_dialog = ButtonDialog:new{
        title = _("选择映射类型"),
        buttons = {
            {
                {
                    text = _("按键"),
                    callback = function()
                        UIManager:close(type_dialog)
                        self:inputKeyCode(function(key_code)
                            self:selectActions(
                                    string.format(_("选择动作（%s，键码 %d）"), self:getKeyName(key_code), key_code),
                                    function(selected_actions)
                                        self:saveMappingAndApply("key", key_code, nil, nil, selected_actions, on_done)
                                    end
                            )
                        end)
                    end,
                },
                {
                    text = _("摇杆轴"),
                    callback = function()
                        UIManager:close(type_dialog)
                        self:inputAxisCode(function(axis_code, axis_value)
                            self:selectActions(
                                    string.format(_("选择动作（轴 %d，值 %d）"), axis_code, axis_value),
                                    function(selected_actions)
                                        self:saveMappingAndApply("axis", nil, axis_code, axis_value, selected_actions, on_done)
                                    end
                            )
                        end)
                    end,
                },
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(type_dialog)
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(type_dialog)
end

--- 输入键码
function BluetoothController:inputKeyCode(on_confirm)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("输入键码"),
        description = _("请输入键码（使用按键检测功能获取）："),
        input_hint = "304",
        input_type = "number",
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local code = tonumber(dialog:getInputText())
                        if code then
                            UIManager:close(dialog)
                            on_confirm(code)
                        else
                            UIManager:show(InfoMessage:new{ text = _("请输入有效的数字键码"), timeout = 2 })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 输入轴代码和值
function BluetoothController:inputAxisCode(on_confirm)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("输入摇杆轴"),
        description = _("请输入轴代码和值（例如：0,-32767）："),
        input_hint = _("轴代码,值"),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local input = dialog:getInputText()
                        local axis_code, axis_value = input:match("(%d+),([%-]?%d+)")
                        if axis_code and axis_value then
                            UIManager:close(dialog)
                            on_confirm(tonumber(axis_code), tonumber(axis_value))
                        else
                            UIManager:show(InfoMessage:new{ text = _("格式错误！请使用：轴代码,值"), timeout = 2 })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 选择一个或多个 Action（支持多选）
function BluetoothController:selectActions(title, on_confirm)
    local ButtonDialog = require("ui/widget/buttondialog")

    local selected = {}
    local action_dialog

    local function rebuildDialog()
        local action_rows = {}

        for i = 1, #ACTION_ID_LIST, 2 do
            local row = {}
            local action_id_1 = ACTION_ID_LIST[i]
            local mark_1 = selected[action_id_1] and "✓ " or ""
            table.insert(row, {
                text = mark_1 .. ACTION_NAME_MAP[action_id_1],
                callback = function()
                    selected[action_id_1] = not selected[action_id_1] or nil
                    UIManager:close(action_dialog)
                    rebuildDialog()
                end,
            })

            if ACTION_ID_LIST[i + 1] then
                local action_id_2 = ACTION_ID_LIST[i + 1]
                local mark_2 = selected[action_id_2] and "✓ " or ""
                table.insert(row, {
                    text = mark_2 .. ACTION_NAME_MAP[action_id_2],
                    callback = function()
                        selected[action_id_2] = not selected[action_id_2] or nil
                        UIManager:close(action_dialog)
                        rebuildDialog()
                    end,
                })
            end

            table.insert(action_rows, row)
        end

        -- 确认和取消按钮（分隔线 + 图标区分）
        table.insert(action_rows, {})

        table.insert(action_rows, {
            {
                text = "✔ " .. _("确认选择"),
                callback = function()
                    local result = {}
                    for _, action_id in ipairs(ACTION_ID_LIST) do
                        if selected[action_id] then
                            table.insert(result, action_id)
                        end
                    end
                    if #result == 0 then
                        UIManager:show(InfoMessage:new{ text = _("请至少选择一个动作"), timeout = 2 })
                        return
                    end
                    UIManager:close(action_dialog)
                    on_confirm(result)
                end,
            },
            {
                text = "✖ " .. _("取消"),
                callback = function() UIManager:close(action_dialog) end,
            },
        })

        action_dialog = ButtonDialog:new{
            title = title,
            buttons = action_rows,
        }
        UIManager:show(action_dialog)
    end

    rebuildDialog()
end

--- 保存映射并立即生效
function BluetoothController:saveMappingAndApply(mapping_type, key_code, axis_code, axis_value, actions, on_done)
    local store_value = #actions == 1 and actions[1] or actions
    local display = self:formatMappingActions(store_value)

    if mapping_type == "key" then
        if not self.config.key_map then self.config.key_map = {} end
        self.config.key_map[key_code] = store_value
        UIManager:show(InfoMessage:new{
            text = string.format(_("已保存：%s → %s"), self:getKeyName(key_code), display),
            timeout = 2,
        })
    else
        if not self.config.joy_map then self.config.joy_map = {} end
        if not self.config.joy_map[axis_code] then self.config.joy_map[axis_code] = {} end
        self.config.joy_map[axis_code][axis_value] = store_value
        UIManager:show(InfoMessage:new{
            text = string.format(_("已保存：轴%d值%d → %s"), axis_code, axis_value, display),
            timeout = 2,
        })
    end

    self:saveSettings()
    logger.info(string.format("BT Plugin: Mapping saved: %s code=%s value=%s → %s",
            mapping_type, tostring(key_code or axis_code), tostring(axis_value), display))
    if on_done then on_done() end
end

-- =======================================================
--  编辑单个映射（支持回调返回上级界面）
-- =======================================================

function BluetoothController:editSingleMapping(mapping_type, code, value, on_done)
    local ButtonDialog = require("ui/widget/buttondialog")

    local current_display
    if mapping_type == "key" then
        current_display = string.format("%s → %s", self:getKeyName(code), self:formatMappingActions(self.config.key_map[code]))
    else
        current_display = string.format(_("轴%d值%d → %s"), code, value, self:formatMappingActions(self.config.joy_map[code][value]))
    end

    local edit_action_dialog
    edit_action_dialog = ButtonDialog:new{
        title = current_display,
        buttons = {
            {
                {
                    text = _("修改动作"),
                    callback = function()
                        UIManager:close(edit_action_dialog)
                        self:selectActions(
                                _("选择新动作"),
                                function(selected_actions)
                                    local store_value = #selected_actions == 1 and selected_actions[1] or selected_actions
                                    if mapping_type == "key" then
                                        self.config.key_map[code] = store_value
                                    else
                                        self.config.joy_map[code][value] = store_value
                                    end
                                    self:saveSettings()
                                    UIManager:show(InfoMessage:new{
                                        text = string.format(_("已更新 → %s"), self:formatMappingActions(store_value)),
                                        timeout = 2,
                                    })
                                    if on_done then on_done() end
                                end
                        )
                    end,
                },
            },
            {
                {
                    text = _("删除映射"),
                    callback = function()
                        UIManager:close(edit_action_dialog)
                        self:deleteSingleMapping(mapping_type, code, value, on_done)
                    end,
                },
            },
            {
                {
                    text = _("返回"),
                    callback = function()
                        UIManager:close(edit_action_dialog)
                        if on_done then on_done() end
                    end,
                },
            },
        },
    }
    UIManager:show(edit_action_dialog)
end

function BluetoothController:deleteSingleMapping(mapping_type, code, value, on_done)
    UIManager:show(ConfirmBox:new{
        text = _("确定要删除此映射吗？"),
        ok_text = _("删除"),
        cancel_text = _("取消"),
        ok_callback = function()
            if mapping_type == "key" then
                self.config.key_map[code] = nil
                UIManager:show(InfoMessage:new{
                    text = string.format(_("已删除：%s"), self:getKeyName(code)),
                    timeout = 2,
                })
            else
                self.config.joy_map[code][value] = nil
                if not next(self.config.joy_map[code]) then
                    self.config.joy_map[code] = nil
                end
                UIManager:show(InfoMessage:new{
                    text = string.format(_("已删除：轴%d值%d"), code, value),
                    timeout = 2,
                })
            end
            self:saveSettings()
            if on_done then on_done() end
        end,
        cancel_callback = function()
            if on_done then on_done() end
        end,
    })
end

-- =======================================================
--  菜单界面
-- =======================================================

function BluetoothController:addToMainMenu(menu_items)
    menu_items.bluetooth_controller = {
        text = _("蓝牙控制器"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("蓝牙开关"),
                keep_menu_open = true,
                checked_func = function()
                    local now = os.time()
                    if (now - self.last_action_time) < 2 then
                        return self.target_state
                    end
                    return _G.KOBluetoothStateManager:isOn()
                end,
                callback = function(touchmenu_instance)
                    touchmenu_instance:updateItems()
                    self:onToggleBluetooth()
                end,
            },
            {
                text_func = function()
                    if not _G.KOBluetoothStateManager or not _G.KOBluetoothStateManager:isOn() then
                        return _("已连接设备：蓝牙已关闭")
                    end
                    local device_name = self:getConnectedDeviceName()
                    if not device_name then
                        return _("已连接设备：无")
                    end
                    return string.format(_("已连接设备：%s"), device_name)
                end,
                keep_menu_open = true,
                enabled_func = function() return false end,
                callback = function() end,
            },
            {
                text = _("按键检测"),
                callback = function()
                    self:startKeyTester()
                end,
            },
            {
                text = _("按键配置"),
                callback = function()
                    self:showKeyMappingEditor()
                end,
            },
            {
                text = _("重载设备"),
                callback = function()
                    self:onBluetoothReloadDevice()
                end,
            },
        },
    }
end

return BluetoothController