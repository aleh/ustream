-- uhttp, streaming-style HTTP parser and client for NodeMCU.
-- Copyright (C) 2017-2018, Aleh Dzenisiuk. 

--[[
    Simple streaming parser for HTTP responses. 
    
    Create an instance by passing your parsing event callbacks to the function returned by `require('uhttp_parser')`. 
		
	Then call process() on that instance for every chunk of data coming from the network, and finish() after 
	the connection is closed.

	The above function returned by `require` accepts callbacks in the following order:
		 
    - status, function(p, code, phrase)
        Called once when the status line is parsed.
        
    - header, function(p, name, value)
        Called after status and before the body for every parsed header.
        
    - body, function(p, data)
        Called zero or more times for every chunk of the body data.
        
    - done, function(p, leftover) 
        Called once after the body has been received successfully, nothing is called afterwards. 
        The `leftover` parmeter contains unparsed data from the last call to process().
        
    - error, function(p, error)
        Called once after an error, nothing is called afterwards.
        
    The status(), header() and body() callbacks must return `true` in order to continue parsing.
	
	(Note that a table of callbacks was used initially, but trying to squeeze more RAM for NodeMCU now.)
]]--

return function(status_callback, header_callback, body_callback, done_callback, error_callback)

	-- As always, we don't want to be cached in the table of loaded modules in case regular `require` is used.
	package.loaded["uhttp_parser"] = nil
        
    local line = ""
    local line_state = 'before-lf'
    local state = 'status-line'
    local content_length = -1
    local actual_content_length = 0
    local body_leftover = nil
    -- True, if the transfer coding is 'chunked'.
    local chunked = false

    local _cleanup = function()
        
        status_callback = nil
        header_callback = nil
        body_callback = nil
        done_callback = nil
        error_callback = nil
        
        line = nil
        line_state = nil
        -- Mark as completed, so further calls of `process` will do nothing.
        state = 'done'
        body_leftover = nil
    end

    local _fail = function(message)
        error_callback(self, message)
        _cleanup()
        return false
    end

    local _done = function()
        done_callback(self, body_leftover)
        _cleanup()
        return true
    end

    local _append_to_line = function(data)
        if line:len() + data:len() <= 256 then
            line = line .. data
            return true
        else
            return _fail("too long header line")
        end
    end

    local _process_status = function(code, phrase)
        if status_callback(self, code, phrase) then
            return true
        else
            return _fail("status callback failed")
        end
    end

    local _process_header = function(name, value)

        -- First let's check headers we might be interested in.
        if name == "content-length" then
            content_length = tonumber(value)
        end
        if name == "transfer-encoding" then
            if value == 'chunked' then
                chunked = true
            else
                return _fail(string.format("unsupported transfer-encoding: '%s'", value))
            end
        end

        -- Then call the handlers.
        if header_callback(self, name, value) then
            return true
        else
            return _fail("header callback failed")
        end
    end
    
    local chunk_size_string = ''
    local chunk_size = 0
    local chunk_state = 'size'
    -- Up to these many bytes will be returned to the body handler in case of chunked document.
    local max_bytes_to_grab = 256
    
    local _process_body = function(data)
        
        if chunked then
            -- When Transfer-Coding is set to 'chunked', then we need to parse it a bit.
            local i = 1
            local len = data:len()
            while i <= len do
            
                if chunk_state == 'size' then
                
                    -- Expecting the size of the next chunk, a hexadecimal number.
                    local ch = data:sub(i, i)
                    i = i + 1         
                               
                    if ch:match('%x') then
                        chunk_size_string = chunk_size_string .. ch                        
                        if chunk_size_string:len() > 8 then
                            -- Of course there can be leading zeros, but it's weird to have too many  
                            -- and we need a limit anyway.
                            return _fail(string.format("chunk size string too long: %q", data:sub(i - 8)))
                        end
                    elseif ch == "\r" then
                        if chunk_size_string:len() > 0 then
                            chunk_state = 'size-lf'
                        else
                            return _fail("no chunk size")
                        end
                    elseif ch == ';' then
                        return _fail("chunk extensions not supported")
                    else
                        return _fail("unexpected char in a chunk header")
                    end
                
                elseif chunk_state == 'size-lf' then
                
                    -- Expecting LF after the chunk size.
                    local ch = data:sub(i, i)
                    i = i + 1
                
                    if ch ~= "\n" then
                        return _fail("missing LF in a chunk header")
                    else
                        chunk_size = tonumber(chunk_size_string, 16)                            
                        assert(chunk_size ~= nil)
                        chunk_size_string = ''                            
                    
                        if chunk_size < 0 then
                            -- Don't let an integer overflow to confuse us.
                            return _fail("too big chunk size")
                        end
                    
                        if chunk_size == 0 then
                            -- The last chunk has zero size.
                            -- OK, done. Don't need to check what's after, let's finish now.
                            -- And we don't support the leftover (trailer) in this case.
                            chunk_state = 'end'
                            body_leftover = data:sub(i)
                            return _done()
                        else
                            -- OK, ready for the body of the chunk.
                            chunk_state = 'body'
                        end
                    end
                    
                elseif chunk_state == 'body-cr' then

                    local ch = data:sub(i, i)
                    i = i + 1
                    
                    if ch == '\r' then
                        chunk_state = 'body-lf'
                    else
                        return _fail("expected CR after chunk")
                    end

                elseif chunk_state == 'body-lf' then

                    local ch = data:sub(i, i)
                    i = i + 1
                    
                    if ch == '\n' then
                        chunk_state = 'size'
                    else
                        return _fail("expected LF after chunk")
                    end
                
                elseif chunk_state == 'body' then

                    repeat
                        
                        -- We can pass up to chunk_size bytes to the handler subject to limits below:
                        local bytes_to_grab = chunk_size
                        
                        -- 1) we cannot pass more than the data we have so far;
                        local bytes_left = data:len() - i + 1 
                        if bytes_to_grab > bytes_left then
                            bytes_to_grab = bytes_left
                        end
                        
                        -- 2) and we cannot pass more than we are allowed to pass at a time to avoid making a copy
                        -- of the whole input data (which can be 5K, quite a chunk on NodeMCU).
                        if bytes_to_grab > max_bytes_to_grab then
                            bytes_to_grab = max_bytes_to_grab
                        end
                        
                        local actual_data = data:sub(i, i + bytes_to_grab - 1)
                        if not body_callback(self, actual_data) then
                            return _fail("body callback failed")
                        end
                        
                        i = i + bytes_to_grab
                        actual_content_length = actual_content_length + bytes_to_grab
                        chunk_size = chunk_size - bytes_to_grab
                        
                        if chunk_size == 0 then
                            -- OK, this chunk is over, need CR/LF afterwards
                            chunk_state = 'body-cr'
                            break
                        end
                        
                    until i > data:len()
                    
                else
                    return _fail("invalid state")
                end
            end            
        else
            local actual_data = data
            local done = false
        
            if content_length >= 0 then
                -- How many bytes we are still ready to accept.
                local left = content_length - actual_content_length
                if data:len() >= left then
                    -- OK, no more, we are done after that.
                    done = true
                    actual_data = data:sub(1, left)
                    body_leftover = data:sub(left + 1, -1)
                end
            end
            
            actual_content_length = actual_content_length + actual_data:len()            

            if not body_callback(self, actual_data) then
                return _fail("body callback failed")
            end

            if done then
                return _done()
            else
                return true
            end            
        end
    end  

    local _process_line = function()

        if state == 'status-line' then
    
            -- Status line
            local code, phrase = line:match("^HTTP/1.[01] (%d+) (.+)$")
            if code == nil then
                return _fail("invalid status line")
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
                    return _fail("invalid header")
                else
                    name = name:lower()
                    if not _process_header(name, value) then return false end
                end
            end
    
        else
            return _fail("invalid state")
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
                    return _fail("expected LF after a CR")
                end
            elseif line_state == 'body' then
                return _process_body(data:sub(i, len))
            else
                return _fail("invalid line state")
            end
        end

        return true
    end

    -- Called when a corresponding connection is closed. Will fail if not everything has been received. 
    local finish = function(_self)
            
        if state == 'done' then return true end

        if state ~= 'body' then
            return _fail("connection closed before got to the body")
        end

        if content_length >= 0 and actual_content_length < content_length then
            return _fail(string.format("connection closed too early (expected %d bytes, got %d)", content_length, actual_content_length))
        end
        
        if chunked and state ~= 'end' then
            return _fail("connection closed too early (have not seen the zero chunk)")
        end

        body_leftover = ''

        return _done()
    end
            
    return { process = process, finish = finish }
end
