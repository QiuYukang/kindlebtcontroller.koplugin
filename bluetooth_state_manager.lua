-- bluetooth_state_manager.lua （独立文件，可被插件和补丁共享）
local UIManager = require("ui/uimanager")

local BluetoothStateManager = {
    _instance = nil,
    _state_cache = { value = false, timestamp = 0 },
    CACHE_TTL = 2, -- 状态缓存2秒
    _listeners = {}, -- 状态监听器
}

-- 单例模式获取实例
function BluetoothStateManager:getInstance()
    if not self._instance then
        self._instance = setmetatable({}, { __index = self })
        self._instance:init()
    end
    return self._instance
end

function BluetoothStateManager:init()
    -- 初始检测
    self:_updateState()
    -- 可选：启动定时更新（如每10秒检查一次）
    self:_startAutoRefresh(10)
end

-- 核心：线程安全的唯一状态获取方法
function BluetoothStateManager:isOn()
    local now = os.time()
    
    -- 使用缓存，避免频繁调用系统命令
    if now - self._state_cache.timestamp < self.CACHE_TTL then
        return self._state_cache.value
    end
    
    -- 加锁更新状态（简单文件锁实现）
    local lock_acquired = self:_withLock(function()
        self:_updateState()
    end)
    
    return self._state_cache.value
end

-- 私有方法：实际检测蓝牙状态
function BluetoothStateManager:_updateState()
    local status, result = pcall(function()
        -- 使用非阻塞方式，添加超时
        local cmd = "timeout 1 lipc-get-prop com.lab126.btfd BTstate 2>/dev/null || echo '0'"
        local f = io.popen(cmd)
        if not f then return "0" end
        local content = f:read("*all") or "0"
        f:close()
        return content
    end)
    
    local new_value = (status and result and (tonumber(result) or 0) > 0)
    
    -- 只有状态变化时才更新缓存并通知监听者
    if new_value ~= self._state_cache.value then
        self._state_cache.value = new_value
        self._state_cache.timestamp = os.time()
        self:_notifyListeners(new_value)
    else
        self._state_cache.timestamp = os.time() -- 仅更新时间戳
    end
end

-- 简单的文件锁，防止并发检测冲突
function BluetoothStateManager:_withLock(callback)
    local lock_file = "/tmp/koreader_bt_lock"
    local max_retry = 3
    
    for i = 1, max_retry do
        local fd = io.open(lock_file, "w")
        if fd then
            fd:write("1")
            fd:close()
            
            -- 执行关键代码
            pcall(callback)
            
            -- 释放锁
            os.remove(lock_file)
            return true
        end
        os.execute("usleep " .. tostring(100000 * i)) -- 递增延迟
    end
    
    -- 获取锁失败，仍然执行但不保证线程安全
    pcall(callback)
    return false
end

-- 状态变化通知（观察者模式）
function BluetoothStateManager:addListener(id, callback)
    self._listeners[id] = callback
end

function BluetoothStateManager:removeListener(id)
    self._listeners[id] = nil
end

function BluetoothStateManager:_notifyListeners(new_state)
    for id, callback in pairs(self._listeners) do
        pcall(callback, new_state)
    end
end

-- 可选：定时自动刷新
function BluetoothStateManager:_startAutoRefresh(interval)
    UIManager:scheduleIn(interval, function()
        self:_updateState()
        if self._auto_refresh_timer then
            self:_startAutoRefresh(interval)
        end
    end)
end

function BluetoothStateManager:stopAutoRefresh()
    self._auto_refresh_timer = nil
end

return BluetoothStateManager
