-- uhttp, streaming-style HTTP parser and client for NodeMCU.
-- Copyright (C) 2017-2018, Aleh Dzenisiuk. 

--[[
    Streaming HTTP request based on uhttp:parser and NodeMCU's net:socket modules.
    'Streaming' means that the whole response does not have to be held in memory before it is given to the user of the module.
]]--
local request = {
        
    new = function()
        
        -- Avoid caching of the module on NodeMCU.
        package.loaded["uhttp"] = nil        
        
        local socket, handlers, parser
    
        -- TODO: allow to pass tracing function to new()
        local _trace = function(s, ...)
            print(string.format("uhttp: " .. s, ...))
        end
        
        local _cleanup = function()
            
            if socket then
                
                -- In newer versions of NodeMCU calling close() is not safe in case there is no connection.
                pcall(function() socket:close() end)
                socket = nil
        
                handlers = nil
        
                if parser then
                    parser:finish()
                    parser = nil
                end
            end
        end
    
        local cancel = function(self)
            if socket then
                pcall(function() socket:close() end)
                socket = nil
            end
        end
    
        local _error = function(message)
            if socket then
                _trace("Error: %s", message)
                handlers.error(self, message)
                _cleanup()
            end
        end
    
        local _done = function()
            if socket then
                _trace("Done")
                handlers.done(self)
                _cleanup()
            end        
        end
    
        local fetch = function(self, host, path, port, _handlers)
            
            handlers = _handlers
        
            parser = require('uhttp_parser').new({
                status = function(p, code, phrase)
                    -- _trace("Status: %d '%s'", code, phrase)
                    return handlers.status(self, code, phrase)
                end,
                header = function(p, name, value)
                    -- _trace("Header: '%s': '%s'", name, value)
                    return handlers.header(self, name, value)
                end,
                body = function(p, data)
                    -- _trace("Body: '%s'", data)
                    return handlers.body(self, data)
                end,
                done = function(p)
                    _done()
                end,
                error = function(p, error)
                    _error(error)
                end
            })
    
            socket = net.createConnection(net.TCP, 0)
            socket:on("connection", function(sck)
                _trace("Sending request...")
                sck:send(
                    "GET " .. path .. " HTTP/1.1\r\n" ..
                    "Host: " .. host .. "\r\n" ..
                    "Connection: close\r\n" ..
                    "\r\n"
                )
            end)
            socket:on("sent", function(sck)
                _trace("Sent")
            end)
            
            -- How many data chunks are scheduled for processing but are not really processed yet.
            local num_chunks_scheduled = 0
            
            socket:on("receive", function(sck, data)
                                
                -- Our processing can take some time depending on what's happening together with HTTP parsing, 
                -- so we schedule the processing as the next event and we throttle the socket using hold/unhold.
                -- Otherwise there is a risk that too much data is coming and overflowing the memory 
                -- while we are busy processing.
                num_chunks_scheduled = num_chunks_scheduled + 1
                if num_chunks_scheduled == 1 then
                    sck:hold()
                end
                
                node.task.post(0, function()
                    _trace("Received %d byte(s)", data:len())
                    parser:process(data)
                    num_chunks_scheduled = num_chunks_scheduled - 1
                    node.task.post(0, function()
                        if num_chunks_scheduled == 0 then
                            sck:unhold()
                        end
                    end)
                end)
            end)
            
            socket:on("disconnection", function(sck, error)
                -- Schedule the actual handling for the next event because some chunks can be 
                -- still scheduled for processing.
                node.task.post(0, function()
                    if error and error ~= 0 then
                        _trace("Disconnected with error: %d", error)
                    else
                        _trace("Disconnected cleanly")
                    end
                    if parser then
                        parser:finish()
                    end
                end)
            end)
        
            _trace("Connecting to %s:%d...", host, port)
            socket:connect(port, host)
        end
        
        -- Fetches a resources at the given host/path/port and saves it into a file.
        local download = function(self, host, path, port, filename, completed)
                        
            local f = file.open(filename, "w+")
            if not f then
                completed(false, "could not open the file")
                return false
            end
            
            self:fetch(host, path, port, {
                status = function(p, code, phrase)
                    if code == 200 then
                        return true
                    else
                        _trace("Expected 200, got %d", code)
                        return false
                    end
                end,
                header = function(p, name, value)
                    return true
                end,
                body = function(p, data)
                    -- Because write() returns nil instead of false.
                    if f:write(data) then return true else return false end
                end,
                done = function(p)
                    f:close()
                    completed(true)
                end,
                error = function(p, error)
                    f:close()
                    completed(false, error)
                end
            })
            
            return true
        end        
        
        return {
            cancel = cancel,
            fetch = fetch,
            download = download
        }
    end
}

return { 
    request = request,
    parser = uhttp_parser
}
