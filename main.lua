local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local Menu = require("ui/widget/menu")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local Screen = Device.screen

local OpenAI = WidgetContainer:extend{
    name = "openaiclient",
    is_doc_only = false,
}

local DEFAULT_ENDPOINTS = {
    {
        name = "Default",
        base_url = "https://api.llmgateway.io/v1",
        api_key = "",
        models = { "deepseek-v4-flash", "alibaba/qwen3.7-flash" },
        default_model = "deepseek-v4-flash",
        system_prompt = "",
        temperature = 0.7,
        timeout = 120,
    },
}

function OpenAI:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
end

--- Load endpoints and misc settings from G_reader_settings.
function OpenAI:loadSettings()
    local endpoints = G_reader_settings:readSetting("openaiclient_endpoints")
    if type(endpoints) ~= "table" or not util.tableSize(endpoints) then
        endpoints = DEFAULT_ENDPOINTS
        G_reader_settings:saveSetting("openaiclient_endpoints", endpoints)
    end

    local normalized = {}
    for i, ep in ipairs(endpoints) do
        if type(ep) == "table" then
            if type(ep.name) ~= "string" or ep.name == "" then
                ep.name = T(_("Endpoint %1"), i)
            end
            if type(ep.base_url) ~= "string" then
                ep.base_url = ""
            end
            if type(ep.api_key) ~= "string" then
                ep.api_key = ""
            end
            if type(ep.system_prompt) ~= "string" then
                ep.system_prompt = ""
            end
            if type(ep.models) ~= "table" then
                ep.models = {}
            end
            normalized[#normalized + 1] = ep
        end
    end
    if #normalized == 0 then
        normalized = DEFAULT_ENDPOINTS
    end
    self.endpoints = normalized
    G_reader_settings:saveSetting("openaiclient_endpoints", self.endpoints)

    self.active_endpoint = G_reader_settings:readSetting("openaiclient_active_endpoint")
    local active_found = false
    for _, ep in ipairs(self.endpoints) do
        if ep.name == self.active_endpoint then
            active_found = true
            break
        end
    end
    if not active_found then
        self.active_endpoint = self.endpoints[1].name
        G_reader_settings:saveSetting("openaiclient_active_endpoint", self.active_endpoint)
    end
end

function OpenAI:saveSettings()
    G_reader_settings:saveSetting("openaiclient_endpoints", self.endpoints)
    G_reader_settings:saveSetting("openaiclient_active_endpoint", self.active_endpoint)
end

--- @return table|nil the active endpoint definition (or first endpoint as a fallback)
function OpenAI:getActiveEndpoint()
    if not self.endpoints then return nil end
    for _, ep in ipairs(self.endpoints) do
        if ep.name == self.active_endpoint then
            return ep
        end
    end
    return self.endpoints[1]
end

function OpenAI:addToMainMenu(menu_items)
    menu_items.openaiclient = {
        text = _("OpenAI"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:buildMainSubMenu()
        end,
    }
end

function OpenAI:buildMainSubMenu()
    return {
        {
            text = _("Chat…"),
            callback = function()
                self:chat()
            end,
        },
        {
            text = _("Endpoints…"),
            sub_item_table_func = function()
                return self:buildEndpointsSubMenu()
            end,
        },
    }
end

function OpenAI:buildEndpointsSubMenu()
    local menu = {
        {
            text = _("Add endpoint…"),
            keep_menu_open = true,
            callback = function()
                self:showEndpointDialog(nil, nil)
            end,
        },
    }
    for i, ep in ipairs(self.endpoints) do
        menu[#menu + 1] = {
            text = ep.name,
            checked_func = function()
                return ep.name == self.active_endpoint
            end,
            sub_item_table = {
                {
                    text = _("Select"),
                    checked_func = function()
                        return ep.name == self.active_endpoint
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self.active_endpoint = ep.name
                        self:saveSettings()
                        touchmenu_instance:updateItems()
                    end,
                },
                {
                    text = _("Fetch model list from server"),
                    keep_menu_open = true,
                    callback = function()
                        self:fetchModels(ep, function(ok, models, res)
                            if ok then
                                ep.models = models
                                self:saveSettings()
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Fetched %1 models from %2."),
                                        #models, ep.name),
                                    timeout = 3,
                                })
                            else
                                local msg = _("Could not fetch model list.")
                                if res and res.code then
                                    msg = msg .. "\n" .. T(_("HTTP %1"), res.code)
                                elseif res and res.error then
                                    msg = msg .. "\n" .. tostring(res.error.message or res.error.code or "")
                                end
                                UIManager:show(InfoMessage:new{
                                    icon = "notice-warning",
                                    text = msg,
                                })
                            end
                        end)
                    end,
                },
                {
                    text = _("Edit…"),
                    keep_menu_open = true,
                    callback = function()
                        self:showEndpointDialog(ep, i)
                    end,
                },
                {
                    text = _("Delete"),
                    keep_menu_open = true,
                    callback = function()
                        self:deleteEndpoint(i)
                    end,
                },
            },
        }
    end
    return menu
end

--- Chat flow. Picks a model for the active endpoint, then a prompt, then sends.
function OpenAI:chat()
    local ep = self:getActiveEndpoint()
    if not self.endpoints or #self.endpoints == 0 then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("No endpoints configured. Add one under OpenAI → Endpoints…"),
        })
        return
    end

    local function proceed()
        if #(ep.models or {}) == 0 then
            -- Try auto-fetch once; fall back to a manual model choice on failure
            self:fetchModels(ep, function(ok)
                self:showModelMenu(ep, ok, function(model)
                    self:showChatDialog(ep, model)
                end)
            end)
        else
            self:showModelMenu(ep, true, function(model)
                self:showChatDialog(ep, model)
            end)
        end
    end

    if NetworkMgr:isConnected() then
        proceed()
    else
        NetworkMgr:promptWifiOn(proceed)
    end
end

--- Show a menu of the endpoint's models for selection.
--- @param ep table endpoint definition
--- @param fetched boolean whether the model list comes from the server
--- @param on_model function(model)
function OpenAI:showModelMenu(ep, fetched, on_model)
    local model_menu
    local item_table = {}
    for _, m in ipairs(ep.models or {}) do
        item_table[#item_table + 1] = {
            text = m,
            callback = function()
                self:setLastModel(ep, m)
                UIManager:close(model_menu)
                on_model(m)
            end,
        }
    end
    item_table[#item_table + 1] = {
        text = _("Custom model…"),
        callback = function()
            UIManager:close(model_menu)
            self:showCustomModelDialog(ep, on_model)
        end,
    }

    model_menu = Menu:new{
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        is_popout = false,
        title_bar_fm_style = true,
        title = T(_("%1 · select model"), ep.name),
        subtitle = fetched and _("Model list from server") or _("Model list (manual)"),
        item_table = item_table,
    }
    model_menu.close_callback = function()
        UIManager:close(model_menu)
    end
    UIManager:show(model_menu)
end

function OpenAI:showCustomModelDialog(ep, on_model)
    local dialog
    dialog = InputDialog:new{
        title = T(_("%1 · custom model"), ep.name),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                        self:showModelMenu(ep, true, on_model)
                    end,
                },
                {
                    text = _("Use"),
                    is_enter_default = true,
                    callback = function()
                        local model = dialog:getInputText()
                        UIManager:close(dialog)
                        if model == "" then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("Model name cannot be empty."),
                            })
                            return
                        end
                        self:setLastModel(ep, model)
                        on_model(model)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function OpenAI:setLastModel(ep, model)
    ep.default_model = model
    self:saveSettings()
end

--- Show a multiline prompt dialog then send the request.
--- @param ep table endpoint definition
--- @param model string model name
function OpenAI:showChatDialog(ep, model)
    local dialog
    dialog = InputDialog:new{
        title = T(_("Chat · %1 · %2"), ep.name, model),
        input = self.last_prompt or "",
        input_hint = _("Type your message…"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Model…"),
                    callback = function()
                        local prompt = dialog:getInputText()
                        self.last_prompt = prompt
                        self:saveSettings()
                        UIManager:close(dialog)
                        self:chat()
                    end,
                },
                {
                    text = _("Send"),
                    is_enter_default = true,
                    callback = function()
                        local prompt = dialog:getInputText()
                        self.last_prompt = prompt
                        self:saveSettings()
                        UIManager:close(dialog)
                        self:sendPrompt(ep, model, prompt)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Send a chat completion request for the given endpoint and model.
function OpenAI:sendPrompt(ep, model, prompt)
    if not prompt or prompt == "" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Please type a message first."),
        })
        return
    end

    local waiting = InfoMessage:new{
        text = T(_("Waiting for %1 (%2)…"), ep.name, model),
    }
    UIManager:show(waiting)
    UIManager:forceRePaint()

    local messages = {}
    if ep.system_prompt and ep.system_prompt ~= "" then
        messages[#messages + 1] = { role = "system", content = ep.system_prompt }
    end
    messages[#messages + 1] = { role = "user", content = prompt }

    local body = {
        model = model,
        messages = messages,
    }
    local temperature = tonumber(ep.temperature)
    if temperature and temperature >= 0 then
        body.temperature = temperature
    end

    local headers = {}
    if ep.api_key and ep.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. ep.api_key
    end

    self:apiRequest(ep, "POST", "/chat/completions", JSON.encode(body), headers,
        function(res)
            UIManager:close(waiting)
            self:handleChatResponse(res)
        end)
end

function OpenAI:handleChatResponse(res)
    if res.error then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Network error (%1): %2"),
                tostring(res.error.code or "?"),
                tostring(res.error.message or "?")) ..
                "\n\n" .. _("Check that Wi-Fi is on and the endpoint is reachable."),
        })
        return
    end

    if not res.body or res.body == "" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Empty response (HTTP %1) from the endpoint."), res.code),
        })
        return
    end

    local ok, data = pcall(JSON.decode, res.body)
    if not ok or not data then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Invalid JSON from endpoint (HTTP %1)."), res.code),
        })
        return
    end

    if res.code ~= 200 then
        local msg
        if data.error then
            msg = tostring(data.error.message or data.error.code or res.code)
        else
            msg = tostring(res.code)
        end
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Request failed (HTTP %1): %2"), res.code, msg),
        })
        return
    end

    local reply
    if data.choices and data.choices[1] and data.choices[1].message then
        reply = data.choices[1].message.content
    end
    if not reply or reply == "" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("The model returned an empty reply."),
        })
        return
    end
    reply = tostring(reply)

    -- Show as a scrollable dialog when the reply is long
    if #reply > 600 then
        UIManager:show(InfoMessage:new{
            text = reply,
            height = math.floor(Screen:getHeight() * 0.6),
        })
    else
        UIManager:show(InfoMessage:new{
            text = reply,
        })
    end
end

--- Perform an HTTP request against an endpoint.
--- Synchronous (socket.http), which is reliable on devices where the Turbo
--- event loop (DUSE_TURBO_LIB) is disabled. Callers should show a wait box
--- (and forceRePaint) beforehand if a slow response is expected.
--- @param ep table endpoint definition
--- @param method string HTTP method
--- @param path string URL path (appended to endpoint base_url)
--- @param body string|nil request body
--- @param headers table|nil extra headers
--- @param callback function(response)
function OpenAI:apiRequest(ep, method, path, body, headers, callback)
    local base = (ep.base_url or ""):gsub("/+$", "")
    if base == "" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Endpoint base URL is empty. Edit the endpoint."),
        })
        return
    end
    local url = base .. path
    local timeout = tonumber(ep.timeout) or 120

    local sink = {}
    local request = {
        url = url,
        method = method,
        sink = ltn12.sink.table(sink),
    }

    if body then
        request.headers = request.headers or {}
        request.headers["Content-Type"] = "application/json"
        request.headers["Content-Length"] = #body
        request.source = ltn12.source.string(body)
    end
    if headers then
        request.headers = request.headers or {}
        for k, v in pairs(headers) do
            request.headers[k] = v
        end
    end

    socketutil:set_timeout(15, timeout)
    -- socket.http returns `1, code, headers, status` on success (KOReader build),
    -- and RAISES an error on a network failure, so we wrap it in pcall.
    local ok, req_ok, code, resp_headers, status = pcall(http.request, request)
    socketutil:reset_timeout()

    local res = {}
    if ok then
        res.code = code
        res.status = status
        res.headers = resp_headers
        res.body = table.concat(sink)
    else
        res.code = nil
        res.error = { code = nil, message = tostring(req_ok) }
    end
    callback(res)
end

--- Fetch /v1/models for an endpoint, mapping data[].id into a model name list.
--- @param ep table endpoint definition
--- @param callback function(ok, models, response)
function OpenAI:fetchModels(ep, callback)
    local headers = {}
    if ep.api_key and ep.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. ep.api_key
    end
    self:apiRequest(ep, "GET", "/models", nil, headers, function(res)
        if res.error then
            callback(false, nil, res)
            return
        end
        if res.code ~= 200 then
            callback(false, nil, res)
            return
        end
        local ok, data = pcall(JSON.decode, res.body or "")
        if not ok or not data or not data.data then
            callback(false, nil, res)
            return
        end
        local models = {}
        for _, m in ipairs(data.data) do
            if m and m.id and models[m.id] == nil then
                models[#models + 1] = tostring(m.id)
            end
        end
        if #models == 0 then
            callback(false, nil, res)
            return
        end
        callback(true, models, res)
    end)
end

--- Dialog used to create or edit an endpoint.
--- @param ep table|nil endpoint to edit, nil to create a new one
--- @param index integer|nil endpoint index in self.endpoints
function OpenAI:showEndpointDialog(ep, index)
    local is_new = ep == nil
    ep = ep or {
        name = "",
        base_url = "",
        api_key = "",
        system_prompt = "",
        temperature = 0.7,
        timeout = 120,
        models = {},
        default_model = nil,
    }

    local config_dialog
    config_dialog = MultiInputDialog:new{
        title = is_new and _("Add endpoint") or T(_("Edit endpoint: %1"), ep.name),
        fields = {
            { text = ep.name, hint = _("Name") },
            { text = ep.base_url, hint = _("Base URL (e.g. http://host:11434/v1)") },
            { text = ep.api_key, hint = _("API key (empty if none)") },
            { text = table.concat(ep.models or {}, ", "), hint = _("Models (comma separated)") },
            { text = tostring(ep.system_prompt or ""), hint = _("System prompt (optional)") },
            { text = tostring(ep.temperature or 0.7), hint = _("Temperature (0–2)") },
            { text = tostring(ep.timeout or 120), hint = _("Request timeout (seconds)") },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(config_dialog)
                    end,
                },
                {
                    text = _("Apply"),
                    is_enter_default = true,
                    callback = function()
                        local fields = config_dialog:getFields()
                        local name = fields[1]:gsub("^%s+", ""):gsub("%s+$", "")
                        local base_url = fields[2]:gsub("^%s+", ""):gsub("%s+$", "")
                        local api_key = fields[3]:gsub("^%s+", ""):gsub("%s+$", "")

                        if name == "" then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("Endpoint name cannot be empty."),
                            })
                            return
                        end
                        if base_url == "" then
                            UIManager:show(InfoMessage:new{
                                icon = "notice-warning",
                                text = _("Base URL cannot be empty."),
                            })
                            return
                        end
                        if not base_url:match("^https?://") then
                            base_url = "http://" .. base_url
                        end
                        base_url = base_url:gsub("/+$", "")

                        local temperature = tonumber(fields[6])
                        if not temperature or temperature < 0 or temperature > 2 then
                            temperature = 0.7
                        end
                        local timeout = tonumber(fields[7])
                        if not timeout or timeout <= 0 then
                            timeout = 120
                        end

                        -- Rename consolidation: do not allow duplicate names
                        for _, other in ipairs(self.endpoints) do
                            if other ~= ep and other.name == name then
                                UIManager:show(InfoMessage:new{
                                    icon = "notice-warning",
                                    text = T(_("An endpoint named “%1” already exists."), name),
                                })
                                return
                            end
                        end

                        ep.name = name
                        ep.base_url = base_url
                        ep.api_key = api_key
                        ep.system_prompt = fields[5]
                        ep.temperature = temperature
                        ep.timeout = timeout

                        local models = {}
                        for m in fields[4]:gmatch("[^,%s]+") do
                            models[#models + 1] = m
                        end
                        ep.models = models

                        if is_new then
                            table.insert(self.endpoints, ep)
                            self.active_endpoint = self.active_endpoint or ep.name
                        end

                        UIManager:close(config_dialog)
                        self:saveSettings()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Endpoint “%1” saved."), ep.name),
                            timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(config_dialog)
    config_dialog:onShowKeyboard()
end

function OpenAI:deleteEndpoint(index)
    local ep = self.endpoints[index]
    if not ep then return end
    UIManager:show(MultiConfirmBox:new{
        text = T(_("Delete endpoint “%1”?"), ep.name),
        choice1_text = _("Cancel"),
        choice1_callback = function() end,
        choice2_text = _("Delete"),
        choice2_callback = function()
            table.remove(self.endpoints, index)
            if self.active_endpoint == ep.name and self.endpoints[1] then
                self.active_endpoint = self.endpoints[1].name
            elseif #self.endpoints == 0 then
                self.active_endpoint = nil
            end
            self:saveSettings()
            UIManager:show(InfoMessage:new{
                text = _("Endpoint deleted."),
                timeout = 2,
            })
        end,
    })
end

return OpenAI
