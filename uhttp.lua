-- uhttp. Streaming-style HTTP client for NodeMCU.
-- Copyright (C) 2017, Aleh Dzenisiuk. 

--[[
    Simple streaming parser for HTTP responses. 
    
    First create an instance using parser:new() with a dictionary of event handlers, 
    then call process() on that instance for every chunk of data coming from the network,
    and then finish() when the connection is closed.
]]--
local parser = {

    --[[ 
        Resests the state of the parser, so it's ready for new data. 
        
        The dictionary of handlers must contain the following functions:
        
        - status = function(p, code, phrase)
            Called once when the status line is parsed.
            
        - header = function(p, name, value)
            Called after status and before body for every header.
            
        - body = function(p, data)
            Called zero or more times for every chunk of body data.
            
        - done = function(p, leftover) 
            Called once after the body has been received successfully, nothing is called afterwards. 
            The `leftover` parmeter contains unparsed data from the last call to process().
            
        - error = function(p, error)
            Called once after an error, nothing is called afterwards.
            
        The status(), header() and body() callbacks must return `true` in order to continue the parsing.
    ]]--
    new = function(self, handlers)
        o = {}
        setmetatable(o, self)
        self.__index = self
        o:_begin(handlers)
        return o
    end,
    
    _begin = function(self, handlers)
        self.handlers = handlers
        self.line = ""
        self.line_state = 'before-lf'
        self.state = 'status-line'
        self.content_length = -1
        self.actual_content_length = 0
    end,
    
    _cleanup = function(self)
        self.handlers = nil
        self.line = nil
        self.line_state = nil
        self.body_left_over = nil
        -- Mark as completed, so further calls of `process` will do nothing.
        self.state = 'done'
    end,

    _fail = function(self, message)
        if not self.handlers then
            assert(false, "Working with the parser after it has finished or after an error occured?")
        end
        self.handlers.error(self, message)
        self:_cleanup()
        return false
    end,
    
    _done = function(self)
        self.handlers.done(self, self.body_left_over)
        self:_cleanup()
        return true
    end,

    _append_to_line = function(self, data)
        self.line = self.line .. data
        if self.line:len() > 256 then
            self:_fail("Very long line in the header")
            return false
        else
            return true
        end
    end,
    
    _process_status = function(self, code, phrase)
        if self.handlers.status(self, code, phrase) then
            return true
        else
            return self:_fail("Status handler indicated error")
        end
    end,    
    
    _process_header = function(self, name, value)
        
        -- First let's check headers we might be interested in.
        if name == "content-length" then
            self.content_length = tonumber(value)
        end
        
        -- Then call the handlers.
        if self.handlers.header(self, name, value) then
            return true
        else
            return self:_fail("Header handler indicated error")
        end
    end,
        
    _process_body = function(self, data)
        
        local actual_data = data
        local done = false
                
        if self.content_length >= 0 then
            -- How many bytes we are still ready to accept.
            local left = self.content_length - self.actual_content_length
            if data:len() >= left then
                -- OK, no more, we are done after that.
                done = true
                actual_data = data:sub(1, left)
                self.body_left_over = data:sub(left + 1, -1)
            end
        end
            
        self.actual_content_length = self.actual_content_length + actual_data:len()            
        
        if not self.handlers.body(self, actual_data) then
            return self:_fail("Body data handler has failed")
        end
        
        if done then
            return self:_done()
        else
            return true
        end
    end,    
    
    _process_line = function(self)
        
        if self.state == 'status-line' then
            
            -- Status line
            local code, phrase = self.line:match("^HTTP/1.1 (%d+) (.+)$")
            if code == nil then
                return self:_fail("Invalid status line")
            end
            
            if not self:_process_status(tonumber(code), phrase) then return false end
            
            self.state = 'header'
            
        elseif self.state == 'header' then
            
            -- Headers
            if self.line:len() == 0 then
                self.line_state = 'body'
                self.state = 'body'
                return true
            else
                local name, value = self.line:match("^([^%c ()<>@,;:\\\"{}\255]+):%s*(.+)%s*$")
                if name == nil then
                    return self:_fail("Invalid header")
                else
                    name = name:lower()
                    if not self:_process_header(name, value) then return false end
                end
            end
            
        else
            return self:_fail("Invalid parser state")
        end
        
        self.line = ""
        return true
    end,
    
    -- This is fed with chunks of data coming from the socket. 
    -- Returns false if an error was encountered, true otherwise.
    process = function(self, data)
        
        -- Safeguard against the client missing 'error' event.
        if self.state == 'done' then return false end
        
        local i = 1
        local len = data:len()
        while i <= len do
            if self.line_state == 'before-lf' then
                local nl_start, nl_end = data:find("\13", i, true)
                if nl_start ~= nil then
                    -- Got a CR, append everything before it to our line.
                    if not self:_append_to_line(data:sub(i, nl_start - 1)) then return false end
                    self.line_state = 'lf'
                    i = nl_start + 1
                else
                    -- No CR till the end of the current data, let's append everything for now and be done with it.
                    return self:_append_to_line(data:sub(i, len))
                end
            elseif self.line_state == 'lf' then
                if data:byte(i) == 10 then
                    -- OK, got an LF, let's simply eat it and process what we have got so far.
                    self.line_state = 'before-lf'
                    i = i + 1
                    if not self:_process_line() then return false end
                else
                    -- No LF, let's be strict.
                    return self:_fail("Missing an LF after a CR")
                end
            elseif self.line_state == 'body' then
                return self:_process_body(data:sub(i, len))
            else
                return self:_fail("Invalid line state")
            end
        end
        
        return true
    end,
    
    -- Called when a corresponding connection is closed. Will fail if not everything has been received. 
    finish = function(self)
        
        if self.state == 'done' then return true end
        
        if self.state ~= 'body' then
            return self:_fail("Connection closed before got to the body")
        end
        
        if self.content_length >= 0 and self.content_length ~= self.actual_body_length then
            return self:_fail("Connection closed before the body was received completely")
        end
        
        self.body_left_over = ''
        
        return self:_done()
    end
}

--[[
    Streaming HTTP request based on uhttp:parser and net:socket modules.
    'Streaming' means that the whole response does not have to be held in memory before it is given to the user of the module.
    NOTE: this is not complete yet.
]]--
local request = {
        
    new = function(self)
        o = {}
        setmetatable(o, self)
        self.__index = self
        return o
    end,
    
    _trace = function(self, s, ...)
        print(string.format("uhttp: " .. s, unpack(arg)))
    end,
        
    _cleanup = function(self)
        
        if self.socket == nil then return end
                    
        self.socket:close()
        self.socket = nil
        
        self.handlers = nil
        
        self.parser = nil

        -- self:_trace("Cleaned up")
    end,
    
    cancel = function(self)
        self:_cleanup()
    end,
    
    _error = function(self, message)
        if self.socket then
            self:_trace("error: %s", message)
            self.handlers.error(self, message)
            self:_cleanup()
        end
    end,
    
    _done = function(self)
        if self.socket then
            self:_trace("Done")
            self.handlers.done(self)
            self:_cleanup()
        end        
    end,
    
    download = function(self, host, path, port, filename, completed)
        local f = file.open(filename, "w")
        if not f then
            completed(false, "could not open the file")
            return
        end
        self:fetch(host, path, port, {
            status = function(p, code, phrase)
                if code == 200 then
                    return true
                else
                    self:_trace("Expected %d", code)
                    return false
                end
            end,
            header = function(p, name, value)
                return true
            end,
            body = function(p, data)
                if f:write(data) then
                    return true
                else
                    -- Because write() returns nil instead of false.
                    return false
                end
            end,
            done = function(p)
                f:close()
                completed(true)
            end,
            error = function(p, error)
                f:close()
                self:_error(error)
                completed(false, error)
            end
        })
    end,
    
    fetch = function(self, host, path, port, handlers)
        
        self.handlers = handlers
        
        self.parser = parser:new({
            status = function(p, code, phrase)
                -- self:_trace("Status: %d '%s'", code, phrase)
                return self.handlers.status(self, code, phrase)
            end,
            header = function(p, name, value)
                --self:_trace("Header: '%s': '%s'", name, value)
                return self.handlers.header(self, name, value)
            end,
            body = function(p, data)
                -- self:_trace("Body: '%s'", data)
                return self.handlers.body(self, data)
            end,
            done = function(p)
                self:_done()
            end,
            error = function(p, error)
                self:_error(error)
            end
        })
    
        self.socket = net.createConnection(net.TCP, 0)
        self.socket:on("connection", function(sck)
            self:_trace("Sending request...")
            sck:send(
                "GET " .. path .. " HTTP/1.1\r\n" ..
                "Host: " .. host .. "\r\n" ..
                "Connection: close\r\n" ..
                "\r\n"
            )
        end)
        self.socket:on("sent", function(sck)
            self:_trace("Sent")
        end)
        self.socket:on("receive", function(sck, data)
            self:_trace("Received %d byte(s)", data:len())
            self.parser:process(data)
        end)
        self.socket:on("disconnection", function(sck, error)
            if error then
                self:_trace("Disconnected with error: %s", error)
            else
                self:_trace("Disconnected cleanly")
            end
            self.parser:finish()
        end)
        
        self:_trace("Connecting to %s:%d...", host, port)
        self.socket:connect(port, host)
    end
}

return { 
    request = request,
    parser = parser
}
