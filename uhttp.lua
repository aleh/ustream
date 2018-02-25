-- uhttp, streaming-style HTTP parser and client for NodeMCU.
-- Copyright (C) 2017, Aleh Dzenisiuk. 

--[[
    Simple streaming parser for HTTP responses. 
    
    First create an instance by calling `parser.new()` with a dictionary of event handlers, 
    then call process() on that instance for every chunk of data coming from the network,
    and then finish() when the connection is closed.
        
    The dictionary of handlers must contain the following functions:
    
    - status = function(p, code, phrase)
        Called once when the status line is parsed.
        
    - header = function(p, name, value)
        Called after status and before the body for every header.
        
    - body = function(p, data)
        Called zero or more times for every chunk of the body data.
        
    - done = function(p, leftover) 
        Called once after the body has been received successfully, nothing is called afterwards. 
        The `leftover` parmeter contains unparsed data from the last call to process().
        
    - error = function(p, error)
        Called once after an error, nothing is called afterwards.
        
    The status(), header() and body() callbacks must return `true` in order to continue the parsing.        
]]--
local uhttp_parser = {

    new = function(handlers)
        
        package.loaded["uhttp"] = nil
        
        local handlers_status = handlers.status
        local handlers_header = handlers.header
        local handlers_body = handlers.body
        local handlers_done = handlers.done
        local handlers_error = handlers.error
        
        local line = ""
        local line_state = 'before-lf'
        local state = 'status-line'
        local content_length = -1
        local actual_content_length = 0
        local body_left_over = nil
            
        local _cleanup = function()
            
            handlers_status = nil
            handlers_header = nil
            handlers_body = nil
            handlers_done = nil
            handlers_error = nil
            
            line = nil
            line_state = nil
            -- Mark as completed, so further calls of `process` will do nothing.
            state = 'done'
            body_left_over = nil
        end

        local _fail = function(message)
            handlers_error(self, message)
            _cleanup()
            return false
        end

        local _done = function()
            handlers_done(self, body_left_over)
            _cleanup()
            return true
        end

        local _append_to_line = function(data)
            if line:len() + data:len() <= 256 then
                line = line .. data
                return true
            else
                return _fail("too long line in the header")
            end
        end

        local _process_status = function(code, phrase)
            if handlers_status(self, code, phrase) then
                return true
            else
                return _fail("status handler has failed")
            end
        end

        local _process_header = function(name, value)
    
            -- First let's check headers we might be interested in.
            if name == "content-length" then
                content_length = tonumber(value)
            end
    
            -- Then call the handlers.
            if handlers_header(self, name, value) then
                return true
            else
                return _fail("header handler has failed")
            end
        end
    
        local _process_body = function(data)
    
            local actual_data = data
            local done = false
            
            if content_length >= 0 then
                -- How many bytes we are still ready to accept.
                local left = content_length - actual_content_length
                if data:len() >= left then
                    -- OK, no more, we are done after that.
                    done = true
                    actual_data = data:sub(1, left)
                    body_left_over = data:sub(left + 1, -1)
                end
            end
        
            actual_content_length = actual_content_length + actual_data:len()            
    
            if not handlers_body(self, actual_data) then
                return _fail("body handler has failed")
            end
    
            if done then
                return _done()
            else
                return true
            end
        end  

        local _process_line = function()
    
            if state == 'status-line' then
        
                -- Status line
                local code, phrase = line:match("^HTTP/1.[01] (%d+) (.+)$")
                if code == nil then
                    return _fail("Invalid status line")
                end
        
                if not _process_status(tonumber(code), phrase) then return false end
        
                state = 'header'
        
            elseif state == 'header' then
        
                -- Headers
                if line:len() == 0 then
                    line_state = 'body'
                    state = 'body'
                    return true
                else
                    local name, value = line:match("^([^%c ()<>@,;:\\\"{}\255]+):%s*(.+)%s*$")
                    if name == nil then
                        return _fail("Invalid header")
                    else
                        name = name:lower()
                        if not _process_header(name, value) then return false end
                    end
                end
        
            else
                return _fail("Invalid parser state")
            end
    
            line = ""
            return true
        end

        -- This is fed with chunks of data coming from the socket. 
        -- Returns false if an error was encountered, true otherwise.
        local process = function(_self, data)
            
            -- Safeguard against the client missing 'error' event.
            if state == 'done' then return false end
            
            local i = 1
            local len = data:len()
            while i <= len do
                if line_state == 'before-lf' then
                    local nl_start, nl_end = data:find("\13", i, true)
                    if nl_start ~= nil then
                        -- Got a CR, append everything before it to our line.
                        if not _append_to_line(data:sub(i, nl_start - 1)) then return false end
                        line_state = 'lf'
                        i = nl_start + 1
                    else
                        -- No CR till the end of the current data, let's append everything for now and be done with it.
                        return _append_to_line(data:sub(i, len))
                    end
                elseif line_state == 'lf' then
                    if data:byte(i) == 10 then
                        -- OK, got an LF, let's simply eat it and process what we have got so far.
                        line_state = 'before-lf'
                        i = i + 1
                        if not _process_line() then return false end
                    else
                        -- No LF, let's be strict.
                        return _fail("Missing an LF after a CR")
                    end
                elseif line_state == 'body' then
                    return _process_body(data:sub(i, len))
                else
                    return _fail("Invalid line state")
                end
            end
    
            return true
        end

        -- Called when a corresponding connection is closed. Will fail if not everything has been received. 
        local finish = function(_self)
                
            if state == 'done' then return true end
    
            if state ~= 'body' then
                return _fail("Connection closed before got to the body")
            end
    
            if content_length >= 0 and actual_content_length < content_length then
                return _fail(string.format("Connection closed too early (expected %d bytes, got %d)", content_length, actual_content_length))
            end
    
            body_left_over = ''
    
            return _done()
        end
                
        return { process = process, finish = finish }
    end
}

--[[
    Streaming HTTP request based on uhttp:parser and NodeMCU's net:socket modules.
    'Streaming' means that the whole response does not have to be held in memory before it is given to the user of the module.
]]--
local request = {
        
    new = function()
        
        -- Avoid caching of the module on NodeMCU.
        package.loaded["uhttp"] = nil        
        
        local socket, handlers, parser
    
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
        
            parser = uhttp_parser.new({
                status = function(p, code, phrase)
                    -- self:_trace("Status: %d '%s'", code, phrase)
                    return handlers.status(self, code, phrase)
                end,
                header = function(p, name, value)
                    --self:_trace("Header: '%s': '%s'", name, value)
                    return handlers.header(self, name, value)
                end,
                body = function(p, data)
                    -- self:_trace("Body: '%s'", data)
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
            
            socket:on("receive", function(sck, data)
                _trace("Received %d byte(s)", data:len())
                parser:process(data)
            end)
            
            socket:on("disconnection", function(sck, error)
                if error and error ~= 0 then
                    _trace("Disconnected with error: %d", error)
                else
                    _trace("Disconnected cleanly")
                end
                if parser then
                    parser:finish()
                end
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
