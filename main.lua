local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local logger = require("logger")
local DataStorage = require("datastorage")
local _ = require("gettext")
local ffi = require("ffi")
local C = ffi.C

-- 初始化管理器
local BluetoothStateManager = require("bluetooth_state_manager")

local BluetoothController = WidgetContainer:extend {
    name = "BluetoothController",
    
    last_action_time = 0,
    target_state = false,

    -- 按键检测状态
    key_detection_active = false,
    key_detection_dialog = nil,
    detected_keys = {},  -- 存储检测到的按键

    -- 先设置一个空的默认配置，在 init 中动态加载
    config = {},
    
    -- 按键映射配置路径：koreader/setting/bluetooth.lua
    settings_file = DataStorage:getSettingsDir() .. "/bluetooth.lua",
}

function BluetoothController:init()
    -- 添加调试日志
    local logger = require("logger")
    logger.dbg("蓝牙插件：开始初始化")
    
    if not Device:isKindle() then 
        logger.dbg("蓝牙插件：非Kindle设备，退出")
        return 
    end

    logger.dbg("蓝牙插件：正在加载默认设置...")
    self:loadConfig()
    
    logger.dbg("蓝牙插件：正在加载设置...")
    self:loadSettings()
    
    logger.dbg("蓝牙插件：正在注册菜单...")
    self.ui.menu:registerToMainMenu(self)
    
    logger.dbg("蓝牙插件：正在注册快捷键...")
    self:onDispatcherRegisterActions()
    
    -- 防止钩子重复叠加
    logger.dbg("蓝牙插件：正在注册输入钩子...")
    self:registerInputHook()
    
    -- 启动连接
    logger.dbg("蓝牙插件：正在连接设备...")
    self:ensureConnected()

    -- 绑定全局变量
    _G.KOBluetoothStateManager = BluetoothStateManager:getInstance()
    
    logger.dbg("蓝牙插件：初始化完成")
end

-- =======================================================
--  配置加载与保存
-- =======================================================

-- 尝试动态加载
function BluetoothController:loadConfig()
    local config_path = self.path .. "/" .. "config.lua"
    local file = io.open(config_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local func = loadstring(content)
        if func then
            self.config = func()
        end
    end
    
    logger.warn("BT Plugin: Cannot found config.lua")
end

function BluetoothController:loadSettings()
    local logger = require("logger")
    logger.dbg("蓝牙插件：开始加载设置")
    
    -- 检查 config.lua 是否加载成功
    logger.dbg("默认配置：", self.config)

    local f = io.open(self.settings_file, "r")
    if f then
        local c = f:read("*all")
        f:close()
        local func = loadstring(c)
        if func then
            local u = func()
            if u then 
                -- 合并用户设置到默认配置
                for k, v in pairs(u) do
                    if type(v) == "table" and type(self.config[k]) == "table" then
                        -- 如果是表，则合并子项
                        for sub_k, sub_v in pairs(v) do
                            self.config[k][sub_k] = sub_v
                        end
                    else
                        -- 否则直接覆盖
                        self.config[k] = v
                    end
                end
            end
        end
    else
        -- 首次运行，保存默认配置
        self:saveSettings()
    end
end

-- 支持缩进和排序的保存函数
function BluetoothController:saveSettings()
    local f = io.open(self.settings_file, "w")
    if f then
        -- 递归序列化函数，带缩进层级
        local function serialize(o, level)
            level = level or 0
            local indent = string.rep("    ", level)
            local next_indent = string.rep("    ", level + 1)

            if type(o) == "table" then
                local s = "{\n"
                
                -- 获取所有 Key 并排序
                local keys = {}
                for k in pairs(o) do table.insert(keys, k) end
                table.sort(keys, function(a, b) 
                    return tostring(a) < tostring(b) 
                end)

                for _, k in ipairs(keys) do
                    local v = o[k]
                    local k_str
                    if type(k) == "number" then
                        k_str = "[" .. k .. "]"
                    else
                        k_str = "[\"" .. tostring(k) .. "\"]"
                    end
                    
                    s = s .. next_indent .. k_str .. " = " .. serialize(v, level + 1) .. ",\n"
                end
                return s .. indent .. "}"
            elseif type(o) == "string" then
                return string.format("%q", o)
            else
                return tostring(o)
            end
        end

        f:write("return " .. serialize(self.config))
        f:close()
    end
end

-- =======================================================
--  钩子管理逻辑
-- =======================================================

function BluetoothController:registerInputHook()
    if Device.input._bt_hook_ref then
        -- 针对没有自动清理的情况, 尝试从表中移除
        if Device.input.event_adjust_hooks then
            for i, hook in ipairs(Device.input.event_adjust_hooks) do
                if hook == Device.input._bt_hook_ref then
                    table.remove(Device.input.event_adjust_hooks, i)
                    logger.warn("BT Plugin: Manual reload detected - Cleaned up old hook")
                    break
                end
            end
        end
        Device.input._bt_hook_ref = nil
    end

    local hook_func = function(input_instance, ev)
        self:handleInputEvent(ev)
    end

    Device.input:registerEventAdjustHook(hook_func)
    Device.input._bt_hook_ref = hook_func
end

-- =======================================================
--  连接管理逻辑
-- =======================================================

function BluetoothController:ensureConnected()
    local input = Device.input
    local path = self.config.device_path
    if not input then return end

    -- 1. 如果已经连接了，直接退出
    if input.opened_devices and input.opened_devices[path] then
        return true
    end

    -- 2. 先检查设备文件是否存在
    local f = io.open(path, "r")
    if f then
        f:close()
        logger.info("BT Plugin: Device " .. path .. " found")
    else
        -- 文件不存在，说明没开手柄。
        logger.info("BT Plugin: Device " .. path .. " not found (Controller off?)")
        return false
    end

    -- 3. 只有确认文件存在，才尝试从内核挂载
    logger.warn("BT Plugin: Found device, connecting to " .. path)
    local ok, err = pcall(function() input:open(path) end)
    
    if not ok then
        -- 只有当文件存在却打不开时，才打印报错
        logger.warn("BT Plugin: Failed to open -> " .. tostring(err))
    end
    
    return ok
end

function BluetoothController:reloadDevice()
    local input = Device.input
    local path = self.config.device_path
    if not input then return end
    
    if input.opened_devices and input.opened_devices[path] then
        logger.warn("BT Plugin: Reload - Closing old connection " .. path)
        pcall(function() input:close(path) end)
    end
    
    logger.warn("BT Plugin: Reload - Re-opening " .. path)
    local ok, err = pcall(function() input:open(path) end)
    
    return ok
end

-- =======================================================
--  硬件状态逻辑
-- =======================================================

-- function BluetoothController:getRealState()
--     local status, result = pcall(function()
--         local f = io.popen("lipc-get-prop com.lab126.btfd BTstate")
--         if not f then return nil end
--         local content = f:read("*all")
--         f:close()
--         return content
--     end)
--     if not status or not result then return false end
--     local state = tonumber(result) or 0
--     return state > 0
-- end

function BluetoothController:setBluetoothState(enable)
    local val = enable and 0 or 1
    os.execute(string.format("lipc-set-prop com.lab126.btfd BTflightMode %d", val))
    local msg = enable and _("蓝牙已开启") or _("蓝牙已禁用")
    UIManager:show(InfoMessage:new { text = msg, timeout = 2 })
end

function BluetoothController:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_kindle_bluetooth", {
        category = "none",
        event = "ToggleBluetooth",
        title = _("开/关 蓝牙"),
        device = true
    })
    Dispatcher:registerAction("bluetooth_reload_device", {
        category = "none",
        event = "BluetoothReloadDevice",
        title = _("重载蓝牙设备"),
        device = true
    })
end

function BluetoothController:onToggleBluetooth()
    local logger = require("logger")
    logger.dbg("蓝牙插件：开/关蓝牙")

    local now = os.time()
    local next_state
    if (now - self.last_action_time) < 2 then next_state = not self.target_state
    else next_state = not _G.KOBluetoothStateManager:isOn() end
    self.target_state = next_state
    self.last_action_time = now
    self:setBluetoothState(next_state)
    _G.KOBluetoothStateManager:_updateState()
end

function BluetoothController:onBluetoothReloadDevice()
    local logger = require("logger")
    logger.dbg("蓝牙插件：重载设备")

    self:loadSettings()
    if self:reloadDevice() then
        UIManager:show(InfoMessage:new{ text = _("✓ 蓝牙设备已连接"), timeout = 2 })
    else
        UIManager:show(InfoMessage:new{ text = _("✗ 蓝牙设备连接失败"), timeout = 2 })
    end
end

-- =======================================================
--  输入处理逻辑
-- =======================================================

function BluetoothController:handleInputEvent(ev)
    local action = nil  -- 改为 action 而不是 dir

    if ev.type == C.EV_KEY then
        if ev.value == 1 or ev.value == 2 then
            action = self.config.key_map[ev.code]
        end
    elseif ev.type == C.EV_ABS then
        if ev.value ~= 0 then
            local axis_map = self.config.joy_map[ev.code]
            if axis_map then
                action = axis_map[ev.value]
            end
        end
    end

    if action then
        self:executeAction(action)  -- 统一处理
        ev.type = -1  -- 标记事件已处理
    end
end

-- =======================================================
--  统一动作执行
-- =======================================================

function BluetoothController:executeAction(action)
    -- 翻页
    if action == "next_page" then
        local dir = 1
        if self.config.invert_layout then dir = -1 end
        UIManager:sendEvent(Event:new("GotoViewRel", dir))
    elseif action == "prev_page" then
        local dir = -1
        if self.config.invert_layout then dir = 1 end
        UIManager:sendEvent(Event:new("GotoViewRel", dir))

    -- 快速翻页
    elseif action == "fast_next_page" then
        local dir = 1
        if self.config.invert_layout then dir = -1 end
        UIManager:sendEvent(Event:new("GotoViewRel", dir * 10))
    elseif action == "fast_prev_page" then
        local dir = -1
        if self.config.invert_layout then dir = 1 end
        UIManager:sendEvent(Event:new("GotoViewRel", dir * 10))
    
    -- 章节导航
    elseif action == "next_chapter" then
        UIManager:sendEvent(Event:new("GotoNextChapter"))
    elseif action == "prev_chapter" then
        UIManager:sendEvent(Event:new("GotoPrevChapter"))

    -- 书签导航
    elseif action == "next_bookmark" then
        UIManager:sendEvent(Event:new("GotoNextBookmarkFromPage"))
    elseif action == "prev_bookmark" then
        UIManager:sendEvent(Event:new("GotoPreviousBookmarkFromPage"))
    elseif action == "last_bookmark" then
        UIManager:sendEvent(Event:new("GoToLatestBookmark"))
    
    -- 亮度调节
    elseif action == "increase_brightness" then
        UIManager:sendEvent(Event:new("IncreaseFlIntensity", 1))
    elseif action == "decrease_brightness" then
        UIManager:sendEvent(Event:new("DecreaseFlIntensity", 1))
    
    -- 色温调节
    elseif action == "increase_warmth" then
        UIManager:sendEvent(Event:new("IncreaseFlWarmth", 1))
    elseif action == "decrease_warmth" then
        UIManager:sendEvent(Event:new("IncreaseFlWarmth", -1))
    
    -- 字体调节
    elseif action == "increase_font_size" then
        UIManager:sendEvent(Event:new("IncreaseFontSize", 2))
    elseif action == "decrease_font_size" then
        UIManager:sendEvent(Event:new("DecreaseFontSize", -2))
    
    -- 其他功能
    elseif action == "toggle_statusbar" then
        UIManager:sendEvent(Event:new("ToggleFooterMode"))
    elseif action == "toggle_bookmark" then
        UIManager:sendEvent(Event:new("ToggleBookmark"))
    elseif action == "toggle_night_mode" then
        UIManager:sendEvent(Event:new("ToggleNightMode"))
    elseif action == "full_refresh" then
        UIManager:sendEvent(Event:new("FullRefresh"))
    elseif action == "go_home" then
        UIManager:sendEvent(Event:new("Home"))
    end
end

-- =======================================================
--  按键检测功能
-- =======================================================

function BluetoothController:startKeyTester()
    if self.testing_mode then return end
    
    local logger = require("logger")
    logger.dbg("蓝牙插件：开始按键测试")
    
    self.testing_mode = true
    self.test_results = {}
    self.test_start_time = os.time()
    
    -- 显示测试提示
    self.test_dialog = InfoMessage:new{ 
        text = _("按键测试模式已启动\n请按手柄按键...\n30秒后自动结束\n\n已检测到：0 个按键"), 
        timeout = 30 
    }
    UIManager:show(self.test_dialog)
    
    -- 保存原始的处理函数
    self.original_handle_input = self.handleInputEvent
    
    -- 创建测试专用的处理函数
    self.handleInputEvent = function(self_ref, ev)
        -- 如果是测试模式，记录所有EV_KEY事件
        if self.testing_mode and ev.type == C.EV_KEY and (ev.value == 1 or ev.value == 2) then
            logger.dbg(string.format("测试模式捕获按键：code=%d, value=%d", ev.code, ev.value))
            
            local key_name = self:getKeyName(ev.code)
            
            -- 检查是否已记录
            local existing = false
            for _, key in ipairs(self.test_results) do
                if key.code == ev.code then
                    key.count = (key.count or 1) + 1
                    key.last_time = os.date("%H:%M:%S")
                    existing = true
                    break
                end
            end
            
            if not existing then
                table.insert(self.test_results, {
                    code = ev.code,
                    name = key_name,
                    count = 1,
                    first_time = os.date("%H:%M:%S"),
                    last_time = os.date("%H:%M:%S")
                })
            end
            
            -- 更新对话框
            self:updateTestDialog()
            
            -- 标记事件已处理，防止重复
            ev.type = -1
            return true
        end
        
        -- 非测试模式或非按键事件：调用原始处理函数
        if self.original_handle_input then
            return self.original_handle_input(self_ref, ev)
        end
        
        return false
    end
    
    logger.dbg("蓝牙插件：按键测试钩子已安装")
    
    -- 10秒后自动停止
    UIManager:scheduleIn(30, function()
        if self.testing_mode then
            logger.dbg("蓝牙插件：自动停止测试")
            self:stopKeyTester()
        end
    end)
end

function BluetoothController:updateTestDialog()
    if not self.test_dialog then return end
    
    local remaining = 30 - (os.time() - self.test_start_time)
    if remaining < 0 then remaining = 0 end
    
    local text = _("按键测试模式\n请按手柄按键...")
    text = text .. "\n" .. string.format(_("剩余时间：%d秒"), remaining)
    text = text .. "\n" .. string.format(_("已检测到：%d 个不同按键"), #self.test_results)
    
    if #self.test_results > 0 then
        text = text .. "\n\n" .. _("检测到的按键：")
        for i, key in ipairs(self.test_results) do
            text = text .. string.format("\n%s (键码：%d) - %d次", 
                key.name, key.code, key.count or 1)
        end
    end
    
    -- 更新对话框
    UIManager:close(self.test_dialog)
    self.test_dialog = InfoMessage:new{ 
        text = text, 
        timeout = math.ceil(remaining) + 1
    }
    UIManager:show(self.test_dialog)
end

function BluetoothController:stopKeyTester()
    if not self.testing_mode then return end
    
    local logger = require("logger")
    logger.dbg("蓝牙插件：停止按键测试")
    
    self.testing_mode = false
    
    -- 恢复原始处理函数
    if self.original_handle_input then
        self.handleInputEvent = self.original_handle_input
        self.original_handle_input = nil
    end
    
    -- 关闭对话框
    if self.test_dialog then
        UIManager:close(self.test_dialog)
        self.test_dialog = nil
    end
    
    -- 显示最终结果
    self:showTestResults()
end

function BluetoothController:showTestResults()
    local logger = require("logger")
    
    if #self.test_results == 0 then
        logger.dbg("蓝牙插件：未检测到任何按键")
        UIManager:show(InfoMessage:new{ 
            text = _("未检测到任何按键\n\n调试建议:\n1. 确认手柄已连接且亮灯\n2. 尝试重载设备\n3. 尝试重启KOReader"), 
            timeout = 5 
        })
    else
        logger.dbg("蓝牙插件：检测到 " .. #self.test_results .. " 个不同按键")
        
        local lines = {_("=== 按键检测结果 ===")}
        
        -- 按键列表
        table.insert(lines, _("\n检测到的按键："))
        for i, key in ipairs(self.test_results) do
            table.insert(lines, string.format("%d. %s（键码：%d）", 
                i, key.name, key.code))
            table.insert(lines, string.format("   首次：%s，最后：%s, 次数：%d", 
                key.first_time, key.last_time, key.count or 1))
        end
        
        -- 添加调试信息
        table.insert(lines, _("\n调试信息："))
        table.insert(lines, string.format(_("测试时长：%d秒"), 30))
        table.insert(lines, string.format(_("总按键次数：%d"), 
            self:sumKeyPresses()))
        
        UIManager:show(InfoMessage:new{ 
            text = table.concat(lines, "\n"), 
            timeout = 15 
        })
    end
    
    self.test_results = {}
end

-- =======================================================
--  按键映射编辑器功能
-- =======================================================

function BluetoothController:showKeyMappingEditor()
    local ButtonDialog = require("ui/widget/buttondialog")
    local InputDialog = require("ui/widget/inputdialog")
    local logger = require("logger")
    
    logger.dbg("蓝牙插件：显示按键映射编辑器")
    
    -- 创建一个菜单对话框，显示当前的按键映射
    local button_rows = {}

    -- 显示当前映射
    table.insert(button_rows, {
        {
            text = _("查看当前映射"),
            callback = function()
                self:showCurrentMappings()
            end,
        }
    })
    
    -- 添加新映射
    table.insert(button_rows, {
        {
            text = _("添加按键映射"),
            callback = function()
                self:addKeyMapping()
            end,
        }
    })
    
    -- 修改现有映射
    table.insert(button_rows, {
        {
            text = _("修改按键映射"),
            callback = function()
                self:editKeyMapping()
            end,
        }
    })
    
    -- 关闭按钮
    table.insert(button_rows, {
        {
            text = _("关闭"),
            callback = function()
                UIManager:close(self.mapping_dialog)
            end,
        }
    })
    
    self.mapping_dialog = ButtonDialog:new{
        title = _("按键映射（修改重启生效）"),
        buttons = button_rows,
    }
    UIManager:show(self.mapping_dialog)
end

-- 显示当前所有映射
function BluetoothController:showCurrentMappings()
    local lines = {_("当前按键映射配置：")}
    
    -- 按键映射
    if self.config.key_map and next(self.config.key_map) then
        table.insert(lines, "\n" .. _("按键映射："))
        local key_codes = {}
        for code, _ in pairs(self.config.key_map) do
            table.insert(key_codes, code)
        end
        table.sort(key_codes)
        
        for _, code in ipairs(key_codes) do
            local action = self.config.key_map[code]
            local key_name = self:getKeyName(code)
            local action_name = self:getActionName(action)
            table.insert(lines, string.format("  键码 %d（%s）→ %s", 
                code, key_name, action_name))
        end
    else
        table.insert(lines, "\n" .. _("按键映射：无"))
    end
    
    -- 摇杆映射
    if self.config.joy_map and next(self.config.joy_map) then
        table.insert(lines, "\n" .. _("摇杆映射："))
        local axis_codes = {}
        for code, _ in pairs(self.config.joy_map) do
            table.insert(axis_codes, code)
        end
        table.sort(axis_codes)
        
        for _, code in ipairs(axis_codes) do
            local axis_map = self.config.joy_map[code]
            if axis_map then
                for value, action in pairs(axis_map) do
                    local action_name = self:getActionName(action)
                    table.insert(lines, string.format("  轴 %d 值 %d → %s", 
                        code, value, action_name))
                end
            end
        end
    else
        table.insert(lines, "\n" .. _("摇杆映射：无"))
    end
    
    -- 其他配置
    table.insert(lines, "\n" .. _("其他设置："))
    table.insert(lines, string.format(_("  设备路径：%s"), self.config.device_path or "未设置"))
    table.insert(lines, string.format(_("  反转方向：%s"), tostring(self.config.invert_layout or false)))
    
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
        timeout = 15
    })
end

-- 添加新的按键映射
function BluetoothController:addKeyMapping()
    local ButtonDialog = require("ui/widget/buttondialog")
    
    -- 第一步：选择映射类型
    local type_dialog
    type_dialog = ButtonDialog:new{
        title = _("添加按键映射（非摇杆选择按键）"),
        buttons = {
            {
                {
                    text = _("按键"),
                    callback = function()
                        UIManager:close(type_dialog)
                        self:addKeyMappingStep2("key")
                    end,
                },
                {
                    text = _("摇杆轴"),
                    callback = function()
                        UIManager:close(type_dialog)
                        self:addKeyMappingStep2("axis")
                    end,
                },
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(type_dialog)
                    end,
                }
            }
        }
    }
    UIManager:show(type_dialog)
end

function BluetoothController:addKeyMappingStep2(mapping_type)
    local InputDialog = require("ui/widget/inputdialog")
    
    if mapping_type == "key" then
        -- 添加按键映射
        local input_dialog
        input_dialog = InputDialog:new{
            title = _("添加按键映射"),
            description = _("请输入键码（使用按键检测功能获取键码）："),
            input_hint = _("例如：304"),
            input_type = "number",
            buttons = {
                {
                    {
                        text = _("取消"),
                        callback = function()
                            UIManager:close(input_dialog)
                        end,
                    },
                    {
                        text = _("下一步"),
                        is_enter_default = true,
                        callback = function()
                            local key_code = tonumber(input_dialog:getInputText())
                            if key_code then
                                UIManager:close(input_dialog)
                                self:addKeyMappingStep3(key_code)
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("请输入有效的数字键码"),
                                    timeout = 2
                                })
                            end
                        end,
                    }
                }
            }
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
    else
        -- 添加摇杆轴映射
        local input_dialog
        input_dialog = InputDialog:new{
            title = _("添加摇杆轴映射"),
            description = _("请输入轴代码和值 (例如：0,-32767):"),
            input_hint = _("轴代码,值"),
            buttons = {
                {
                    {
                        text = _("取消"),
                        callback = function()
                            UIManager:close(input_dialog)
                        end,
                    },
                    {
                        text = _("下一步"),
                        is_enter_default = true,
                        callback = function()
                            local input = input_dialog:getInputText()
                            local axis_code, axis_value = input:match("(%d+),([%-]?%d+)")
                            
                            if axis_code and axis_value then
                                axis_code = tonumber(axis_code)
                                axis_value = tonumber(axis_value)
                                UIManager:close(input_dialog)
                                self:addKeyMappingStep3(nil, axis_code, axis_value)
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("格式错误！请使用：轴代码,值"),
                                    timeout = 2
                                })
                            end
                        end,
                    }
                }
            }
        }
        UIManager:show(input_dialog)
        input_dialog:onShowKeyboard()
    end
end

function BluetoothController:addKeyMappingStep3(key_code, axis_code, axis_value)
    local ButtonDialog = require("ui/widget/buttondialog")
    
    -- 可用的动作列表
    local available_actions = self.getAvailableActions()
    
    local action_rows = {}
    
    -- 创建动作按钮
    for i = 1, #available_actions, 2 do
        local row = {}
        
        -- 第一个按钮
        local action1 = available_actions[i]
        table.insert(row, {
            text = self:getActionName(action1),
            callback = function()
                UIManager:close(self.action_dialog)
                self:saveNewMapping(key_code, axis_code, axis_value, action1)
            end,
        })
        
        -- 第二个按钮（如果有）
        if available_actions[i + 1] then
            local action2 = available_actions[i + 1]
            table.insert(row, {
                text = self:getActionName(action2),
                callback = function()
                    UIManager:close(self.action_dialog)
                    self:saveNewMapping(key_code, axis_code, axis_value, action2)
                end,
            })
        end
        
        table.insert(action_rows, row)
    end
    
    -- 添加取消按钮
    table.insert(action_rows, {
        {
            text = _("取消"),
            callback = function()
                UIManager:close(self.action_dialog)
            end,
        }
    })
    
    local title
    if key_code then
        local key_name = self:getKeyName(key_code)
        title = string.format(_("选择动作 (键码 %d：%s)"), key_code, key_name)
    else
        title = string.format(_("选择动作 (轴 %d，值 %d)"), axis_code, axis_value)
    end
    
    self.action_dialog = ButtonDialog:new{
        title = title,
        buttons = action_rows,
    }
    UIManager:show(self.action_dialog)
end

function BluetoothController:saveNewMapping(key_code, axis_code, axis_value, action)
    -- 保存新的映射
    if key_code then
        -- 按键映射
        if not self.config.key_map then
            self.config.key_map = {}
        end
        self.config.key_map[key_code] = action
        
        local key_name = self:getKeyName(key_code)
        local action_name = self:getActionName(action)
        
        UIManager:show(InfoMessage:new{
            text = string.format(_("已添加映射：\n%s (键码 %d) → %s"), 
                key_name, key_code, action_name),
            timeout = 3
        })
    else
        -- 摇杆轴映射
        if not self.config.joy_map then
            self.config.joy_map = {}
        end
        if not self.config.joy_map[axis_code] then
            self.config.joy_map[axis_code] = {}
        end
        self.config.joy_map[axis_code][axis_value] = action
        
        UIManager:show(InfoMessage:new{
            text = string.format(_("已添加映射：\n轴 %d, 值 %d → %s"), 
                axis_code, axis_value, self:getActionName(action)),
            timeout = 3
        })
    end
    
    -- 保存设置
    self:saveSettings()
    
    -- 重新加载设备以应用新映射
    self:reloadDevice()
end

-- 编辑现有映射
function BluetoothController:editKeyMapping()
    local ButtonDialog = require("ui/widget/buttondialog")
    
    local button_rows = {}
    local has_mappings = false
    
    -- 添加按键映射
    if self.config.key_map and next(self.config.key_map) then
        has_mappings = true
        table.insert(button_rows, {
            {
                text = _("编辑按键映射"),
                enabled = false,
            }
        })
        
        local key_codes = {}
        for code, _ in pairs(self.config.key_map) do
            table.insert(key_codes, code)
        end
        table.sort(key_codes)
        
        for _, code in ipairs(key_codes) do
            local action = self.config.key_map[code]
            local key_name = self:getKeyName(code)
            
            table.insert(button_rows, {
                {
                    text = string.format("%s → %s", key_name, self:getActionName(action)),
                    callback = function()
                        self:editSingleMapping("key", code, action)
                    end,
                }
            })
        end
    end
    
    -- 添加摇杆映射
    if self.config.joy_map and next(self.config.joy_map) then
        has_mappings = true
        table.insert(button_rows, {
            {
                text = _("编辑摇杆映射"),
                enabled = false,
            }
        })
        
        local axis_codes = {}
        for code, _ in pairs(self.config.joy_map) do
            table.insert(axis_codes, code)
        end
        table.sort(axis_codes)
        
        for _, axis_code in ipairs(axis_codes) do
            local axis_map = self.config.joy_map[axis_code]
            if axis_map then
                for value, action in pairs(axis_map) do
                    table.insert(button_rows, {
                        {
                            text = string.format("轴%d值%d → %s", 
                                axis_code, value, self:getActionName(action)),
                            callback = function()
                                self:editSingleMapping("axis", axis_code, action, value)
                            end,
                        }
                    })
                end
            end
        end
    end
    
    if not has_mappings then
        UIManager:show(InfoMessage:new{
            text = _("没有找到可编辑的映射"),
            timeout = 2
        })
        return
    end
    
    -- 添加取消按钮
    table.insert(button_rows, {
        {
            text = _("取消"),
            callback = function()
                UIManager:close(self.edit_dialog)
            end,
        }
    })
    
    self.edit_dialog = ButtonDialog:new{
        title = _("选择要编辑的映射"),
        buttons = button_rows,
    }
    UIManager:show(self.edit_dialog)
end

function BluetoothController:editSingleMapping(mapping_type, code, current_action, value)
    local ButtonDialog = require("ui/widget/buttondialog")
    
    local available_actions = self.getAvailableActions()
    
    local action_rows = {}
    
    -- 创建动作按钮
    for i = 1, #available_actions, 2 do
        local row = {}
        
        -- 第一个按钮
        local action1 = available_actions[i]
        table.insert(row, {
            text = self:getActionName(action1),
            callback = function()
                UIManager:close(self.edit_action_dialog)
                self:updateMapping(mapping_type, code, value, action1)
            end,
        })
        
        -- 第二个按钮（如果有）
        if available_actions[i + 1] then
            local action2 = available_actions[i + 1]
            table.insert(row, {
                text = self:getActionName(action2),
                callback = function()
                    UIManager:close(self.edit_action_dialog)
                    self:updateMapping(mapping_type, code, value, action2)
                end,
            })
        end
        
        table.insert(action_rows, row)
    end
    
    -- 删除按钮
    table.insert(action_rows, {
        {
            text = _("删除此映射"),
            callback = function()
                UIManager:close(self.edit_action_dialog)
                self:deleteSingleMapping(mapping_type, code, value)
            end,
        }
    })
    
    -- 取消按钮
    table.insert(action_rows, {
        {
            text = _("取消"),
            callback = function()
                UIManager:close(self.edit_action_dialog)
            end,
        }
    })
    
    local title
    if mapping_type == "key" then
        local key_name = self:getKeyName(code)
        title = string.format(_("编辑映射：%s (当前：%s)"), 
            key_name, self:getActionName(current_action))
    else
        title = string.format(_("编辑映射：轴%d值%d (当前：%s)"), 
            code, value, self:getActionName(current_action))
    end
    
    self.edit_action_dialog = ButtonDialog:new{
        title = title,
        buttons = action_rows,
    }
    UIManager:show(self.edit_action_dialog)
end

function BluetoothController:updateMapping(mapping_type, code, value, new_action)
    -- 更新映射
    if mapping_type == "key" then
        self.config.key_map[code] = new_action
        local key_name = self:getKeyName(code)
        
        UIManager:show(InfoMessage:new{
            text = string.format(_("已更新映射：\n%s → %s"), 
                key_name, self:getActionName(new_action)),
            timeout = 3
        })
    else
        self.config.joy_map[code][value] = new_action
        
        UIManager:show(InfoMessage:new{
            text = string.format(_("已更新映射：\n轴%d值%d → %s"), 
                code, value, self:getActionName(new_action)),
            timeout = 3
        })
    end
    
    -- 保存设置
    self:saveSettings()
    
    -- 重新加载设备以应用新映射
    self:reloadDevice()
end

-- 删除单个映射
function BluetoothController:deleteSingleMapping(mapping_type, code, value)
    UIManager:show(ConfirmBox:new{
        text = _("确定要删除此映射吗？"),
        ok_text = _("删除"),
        cancel_text = _("取消"),
        ok_callback = function()
            if mapping_type == "key" then
                self.config.key_map[code] = nil
                local key_name = self:getKeyName(code)
                
                UIManager:show(InfoMessage:new{
                    text = string.format(_("已删除映射：%s"), key_name),
                    timeout = 3
                })
            else
                self.config.joy_map[code][value] = nil
                -- 如果这个轴没有其他映射了，删除整个轴
                if not next(self.config.joy_map[code]) then
                    self.config.joy_map[code] = nil
                end
                
                UIManager:show(InfoMessage:new{
                    text = string.format(_("已删除映射：轴%d值%d"), code, value),
                    timeout = 3
                })
            end
            
            -- 保存设置
            self:saveSettings()
            
            -- 重新加载设备
            self:reloadDevice()
        end,
    })
end

-- 序列化配置用于显示
function BluetoothController:serializeConfig()
    local function serializeTable(val, indent)
        indent = indent or 0
        local str = ""
        local spaces = string.rep("    ", indent)
        
        if type(val) == "table" then
            str = str .. "{\n"
            local keys = {}
            for k in pairs(val) do table.insert(keys, k) end
            table.sort(keys, function(a, b) 
                if type(a) == "number" and type(b) == "number" then
                    return a < b
                else
                    return tostring(a) < tostring(b)
                end
            end)
            
            for _, k in ipairs(keys) do
                local v = val[k]
                if type(k) == "number" then
                    str = str .. spaces .. "    [" .. k .. "] = " .. serializeTable(v, indent + 1) .. ",\n"
                else
                    str = str .. spaces .. "    [\"" .. k .. "\"] = " .. serializeTable(v, indent + 1) .. ",\n"
                end
            end
            str = str .. spaces .. "}"
        elseif type(val) == "string" then
            str = "\"" .. val .. "\""
        else
            str = tostring(val)
        end
        
        return str
    end
    
    local config_copy = {}
    for k, v in pairs(self.config) do
        config_copy[k] = v
    end
    
    return serializeTable(config_copy)
end

-- 辅助函数：获取可用动作
function BluetoothController:getAvailableActions(action)
    local available_actions = {
        "next_page", "prev_page",
        "fast_prev_page", "fast_next_page",
        "next_chapter", "prev_chapter",
        "next_bookmark", "prev_bookmark",
        "last_bookmark",
        "decrease_font_size", "increase_font_size",
        "decrease_brightness", "increase_brightness",
        "decrease_warmth", "increase_warmth",
        "toggle_statusbar", "toggle_bookmark", "toggle_night_mode",
        "full_refresh", "go_home",
    }
    
    return available_actions
end

-- 辅助函数：获取动作名称
function BluetoothController:getActionName(action)
    local action_names = {
        next_page = "下一页",
        prev_page = "上一页",
        fast_prev_page = "上十页",
        fast_next_page = "下十页",
        next_chapter = "下一章",
        prev_chapter = "上一章",
        prev_bookmark = "上一书签",
        next_bookmark = "下一书签",
        last_bookmark = "最后书签",
        increase_brightness = "增加亮度",
        decrease_brightness = "减少亮度",
        increase_font_size = "增加字号",
        decrease_font_size = "减小字号",
        increase_warmth = "增加色温",
        decrease_warmth = "减少色温",
        toggle_statusbar = "切换状态栏",
        toggle_bookmark = "切换书签",
        toggle_night_mode = "切换夜间模式",
        full_refresh = "全刷屏幕",
        go_home = "返回首页",
    }
    
    return action_names[action] or action
end

-- 辅助函数：计算总按键次数
function BluetoothController:sumKeyPresses()
    local total = 0
    for _, key in ipairs(self.test_results) do
        total = total + (key.count or 1)
    end
    return total
end

-- 辅助函数：获取按键名称
function BluetoothController:getKeyName(code)
    local names = {
        [304] = "A键", [305] = "B键", [306] = "X键", [307] = "Y键",
        [308] = "L键", [309] = "R键", [310] = "L2键", [311] = "R2键",
        [312] = "TL2键", [313] = "TR2键", [314] = "摇杆按下", [315] = "START键",
        [316] = "SELECT键", [317] = "左摇杆", [318] = "右摇杆",
        [103] = "上方向", [108] = "下方向", [105] = "左方向", [106] = "右方向",
        [28] = "ENTER键", [1] = "ESC键", [57] = "SPACE键",
    }
    return names[code] or "未知键"
end

-- =======================================================
--  菜单界面
-- =======================================================

function BluetoothController:addToMainMenu(menu_items)
    local logger = require("logger")
    logger.dbg("蓝牙插件：正在创建菜单项")

    menu_items.bluetooth_controller = {
        text = _("蓝牙翻页器"),
        sorting_hint = "tools",
        sub_item_table = {
            -- 1. 蓝牙开关
            {
                text = _("蓝牙开关"),
                keep_menu_open = true,
                checked_func = function()
                    local now = os.time()
                    if (now - self.last_action_time) < 2 then return self.target_state
                    else return _G.KOBluetoothStateManager:isOn() end
                end,
                callback = function(touchmenu_instance)
                    touchmenu_instance:updateItems()
                    self:onToggleBluetooth()
                end,
            },
            -- 2. 颠倒方向
            {
                text = _("反转方向"),
                checked_func = function() return self.config.invert_layout end,
                callback = function()
                    self.config.invert_layout = not self.config.invert_layout
                    self:saveSettings()
                end
            },
            -- 3. 重载设备
            {
                text = _("重载设备"),
                callback = function()
                    self:onBluetoothReloadDevice()
                end
            },
            -- 4. 按键检测
            {
                text = _("按键检测"),
                callback = function()
                    self:startKeyTester()
                end
            },
            -- 5. 按键映射
            {
                text = _("按键映射"),
                callback = function()
                    self:showKeyMappingEditor()
                end
            }
        }
    }
end

return BluetoothController
