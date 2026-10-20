describe("OpenAI client plugin", function()
    local OpenAI, plugin, UIManager

    setup(function()
        require("commonrequire")
        OpenAI = dofile("plugins/openaiclient.koplugin/main.lua")
        local ui = { menu = { registerToMainMenu = function() end } }
        plugin = OpenAI:new{ ui = ui }
        plugin:init()
        UIManager = require("ui/uimanager")
    end)

    local function close_all()
        for i = #UIManager._window_stack, 1, -1 do
            UIManager:close(UIManager._window_stack[i].widget)
        end
    end

    teardown(function()
        close_all()
    end)

    it("loads default endpoint and builds menus", function()
        assert.is_truthy(plugin.endpoints)
        assert.are.equal(1, #plugin.endpoints)
        local sub = plugin:buildMainSubMenu()
        assert.are.equal(2, #sub)
        local eps = plugin:buildEndpointsSubMenu()
        assert.is_truthy(eps)
    end)

    it("requires only things that exist", function()
        assert.is_function(plugin.chat)
        assert.is_function(plugin.apiRequest)
    end)

    it("shows model menu without error", function()
        local ep = plugin:getActiveEndpoint()
        local called
        plugin:showModelMenu(ep, true, function(m) called = m end)
        -- Close without selecting.
        close_all()
        assert.is_nil(called)
    end)

    it("shows chat dialog without error", function()
        local ep = plugin:getActiveEndpoint()
        plugin:showChatDialog(ep, ep.default_model)
        close_all()
    end)

    it("handles long replies without crashing", function()
        local long = string.rep("word ", 5000)
        plugin:handleChatResponse({ code = 200, body = '{"choices":[{"message":{"content":"' .. long .. '"}}]}' })
        close_all()
    end)

    it("sends prompt through apiRequest with a mocked response", function()
        local ep = plugin:getActiveEndpoint()
        local captured
        plugin.apiRequest = function(_, _ep, _method, _path, body, _headers, callback)
            captured = body
            callback({ code = 200, body = '{"choices":[{"message":{"content":"hi"}}]}' })
        end
        plugin:sendPrompt(ep, ep.default_model, "hello")
        close_all()
        assert.is_truthy(captured)
        assert.is_truthy(captured:find("hello", 1, true))
    end)

    it("handles error responses without crashing", function()
        plugin:handleChatResponse({ code = 401, body = '{"error":{"message":"Invalid","code":"invalid_api_key"}}' })
        close_all()
        plugin:handleChatResponse({ error = { message = "boom" } })
        close_all()
    end)
end)

describe("OpenAI client plugin with legacy settings", function()
    local OpenAI, plugin, UIManager

    setup(function()
        require("commonrequire")
        G_reader_settings:saveSetting("openaiclient_endpoints", {
            { name = "Legacy", base_url = "http://127.0.0.1:1", api_key = "" },
        })
        G_reader_settings:saveSetting("openaiclient_active_endpoint", "Legacy")
        OpenAI = dofile("plugins/openaiclient.koplugin/main.lua")
        plugin = OpenAI:new{ ui = { menu = { registerToMainMenu = function() end } } }
        plugin:init()
        UIManager = require("ui/uimanager")
    end)

    teardown(function()
        for i = #UIManager._window_stack, 1, -1 do
            UIManager:close(UIManager._window_stack[i].widget)
        end
    end)

    it("normalizes missing model lists instead of crashing", function()
        local ep = plugin:getActiveEndpoint()
        assert.are.same({}, ep.models)
        plugin:showModelMenu(ep, true, function() end)
    end)
end)
