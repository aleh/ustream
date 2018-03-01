-- ujson, streaming-style JSON parser.
-- Copyright (C) 2017-2018, Aleh Dzenisiuk. 

--[[
    Simple streaming-style JSON parser originally made for NodeMCU, but not using any APIs specific to it.

    Create an instance first:
    
    local parser = require("ujson").new() passing it a dictionary of parsing event handlers options:
    
        - 'element' = function(p, path, key, value, truncated)
            
            Called for every simple value (true, false, null, numbers and strings). 
            The `key` parameter is either a string key for this value in the enclosing dictionary 
            or a 1-based numeric index of it in the enclosing array.
        
            The `path` is an array of string keys or numeric indexes that can be followed to the value 
            in the full document. The first element of the path array is always an empty string (""), 
            the last element is the same as the `key` parameter.
                    
            For example, if we have the following document:
                { "test" : [ true, { "test2" : 2 }}
            and `element` callback is called for the "test2" key, then the `path` will have the following elements:
                "root", 2, "test2".
                
            You can can call p:string_for_path(path) to get a string representation of the path suitable for logging.
            
            For string values 'truncated' tells if the string was actually larger than `max_string_len` passed into the new() method.
        
        - 'begin_element' = function(p, path, key, type)
        - 'end_element' = function(p, path)
            
            These are called at a start and end of an array (type == '[') or a dictionary (type == '{'). 
            The `key` and `path` parameters are similar to the ones in the `element` callback.
            
        - 'error' = function(p, error)
            
            Called once when a parsing error is encountered. The corresponding call of `process` method will return false.
            
        - 'done' = function(p)
            
            Called once after the root object is successfully parsed.
            
        - 'max_string_len' = number
        
            This is the maximum length of a single string the parser will accept.
            
    Every handler returns `true` to indicate that the parsing can continue and `false` to mean that a parsing error 
    should be triggered.
    
    The data is fed via `process` method accepting a single string as a parameter. The method returns `false` 
    in case a parsing error has happend. 
    
    It is safe to call `process` even after the parsing has failed, it won't call the `error` callback more than once.
    
    The `finish` method should be called after all the data is fed. 
    An error will be triggered if there is not enough data in the incoming stream to complete the document.
]]--
return {
    
    new = function(options)
        
        -- As always, trying to prevent caching on NodeMCU
        package.loaded["ujson"] = nil
        
        -- Returning something as self, but for performance reasons using locals for the state.
        local self = {}
                        
        local handlers_begin_element = options.begin_element
        local handlers_end_element = options.end_element
        local handlers_element = options.element
        local handlers_error = options.error
        local handlers_done = options.done
        assert(handlers_begin_element and handlers_end_element and handlers_element and handlers_error and handlers_done)
        
        -- The state of the parser.
        local state = 'idle'
        
        -- Parser's stack (each character is an item) to remember if we are handling an array or a dictionary.
        local stack = ''
        
        -- The current key path array, such as { "key1", 12, "key2" }, where every string elements represents a
        -- dictionary key and a number element represents an index in an array.
        local path = {}
        
        -- The state of the tokenizer.
        local token_state = 'space'
        local token_substate, token_value, token_unicode_value
        local token_pos, expected_const
        local current_key, truncated
        
        -- Global position in the incoming data, used only to report errors. 
        -- TODO: perhaps not very useful and should be removed.
        local position = 0
        
        local max_token_len = 64
        local max_string_len = options.max_string_len or 1024
    
        local _cleanup = function()

            handlers_begin_element = nil
            handlers_end_element = nil
            handlers_element = nil
            handlers_error = nil
            handlers_done = nil
            
            stack = nil
            state = nil
            token_state = 'done'
            token_substate = nil
            token_value = nil
        end
        
        local _fail = function(msg, ...)
            if token_state ~= 'done' then
                -- _trace("failed: " .. msg, ...)
                handlers_error(self, string.format(msg, ...))
                _cleanup()
            end
        end
    
        local _done = function()
            if token_state ~= 'done' then
                -- _trace("done")
                handlers_done(self)
                _cleanup()
            end
        end        
    
        --[[
        local _trace = function(s, ...)
            print(string.format("ujson: " .. s, ...))
        end,
        ]]--
    
        -- Returns a string representation of a path suitable for diagnostics, 
        -- e.g. "root[2][\"test2\"]" for the example above.
        self.string_for_path = function(self, path)
            local result = "root"
            for k, v in ipairs(path) do
                if type(v) == 'string' then
                    if k ~= 1 then
                        result = result .. string.format("[%q]", v)
                    end
                elseif type(v) == 'number' then
                    result = result .. string.format("[%d]", v)
                else
                    assert(false)
                end
            end
            return result
        end
    
        local _begin_element = function(key, type)
            table.insert(path, key)
            -- _trace("%s begin %q", string_for_path(path), type)
            local result = handlers_begin_element(self, path, key, type)
            if not result then
                _fail("begin_element handler has failed")
            end
            return result
        end
    
        local _element = function(key, value, truncated)
            table.insert(path, key)
            -- _trace("%s %q -> '%s' (%s)", string_for_path(path), key, value, type(value))
            local result = handlers_element(self, path, key, value, truncated)
            table.remove(path)
            if not result then
                _fail("element handler has failed")
            end
            return result
        end
            
        local _pop_state = function()
        
            if stack:len() == 0 then
                return _fail("invalid parser state")
            end
        
            stack = stack:sub(1, -2)
            local prev_state = stack:sub(-1)
            if prev_state == 'A' then
                state = 'array-comma'
            elseif prev_state == 'D' then
                state = 'dict-comma'
            else
                _done()
            end
        
            return true
        end
        
        local _end_element = function()
            
            -- _trace("%s end", string_for_path(path))
            
            local result = handlers_end_element(self, path)
        
            current_key = path[#path]
            table.remove(path)
                        
            if not result then
                return _fail("end_element handler has failed")
            end
            
            if not _pop_state() then return false end
        
            return true
        end        
        
        local _process_token = function(token_type, token_value)
        
            token_state = 'space'
        
            --[[
            if token_type == token_value then
                _trace("token '%s'", token_type)
            else
                _trace("token '%s' -> '%s' (%s)", token_type, token_value, type(token_value))
            end
            ]]--
        
            if state == 'idle' then
                if token_type == '{' then
                    if not _begin_element('', '{') then return false end
                    stack = stack .. 'D'
                    state = 'dict-key'
                else
                    return _fail("expected an object (dictionary) in the root")
                end
            elseif state == 'dict-key' then
                if token_type == 'string' then
                    current_key = token_value
                    state = 'dict-colon'
                elseif token_type == '}' then
                    if not _end_element() then return false end
                else
                    return _fail("expected a string object key, got '%s'", token_type)
                end
            elseif state == 'dict-colon' then
                if token_type == ':' then
                    state = 'dict-value'
                else
                    return _fail("expected a colon, got '%s'", token_type)
                end
            elseif state == 'dict-value' or state == 'array-element' then
                if state == 'array-element' then
                    current_key = current_key + 1
                end
                if token_type == 'const' or token_type == 'string' or token_type == 'number' then
                    if state == 'dict-value' then
                        state = 'dict-comma'
                    else
                        state = 'array-comma'
                    end
                    if not _element(current_key, token_value, truncated) then return false end
                elseif token_type == '[' then
                    stack = stack .. 'A'
                    state = 'array-element'
                    if not _begin_element(current_key, '[') then return false end
                    current_key = 0
                elseif token_type == '{' then
                    stack = stack .. 'D'
                    state = 'dict-key'
                    if not _begin_element(current_key, '{') then return false end
                elseif token_type == ']' and state == 'array-element' then
                    if not _end_element() then return false end
                else
                    return _fail("expected a value, but got '%s'", token_type)
                end
            elseif state == 'array-comma' then
                if token_type == ',' then
                    state = 'array-element'
                elseif token_type == ']' then
                    if not _end_element() then return false end
                else
                    return _fail("expected a comma or end of array, but got '%s'", token_type)
                end
            elseif state == 'dict-comma' then
                if token_type == ',' then
                    state = 'dict-key'
                elseif token_type == '}' then
                    if not _end_element() then return false end
                end
            else
                return _fail("invalid parser state: '%s'", state)
            end
        
            return true
        end
        
        local _process_number_token = function()
            return _process_token('number', tonumber(token_value))
        end
        
        local _append_token_value = function(ch)
            if token_value:len() < max_token_len then
                token_value = token_value .. ch
                return true
            else
                return _fail("a token is too large")
            end
        end
    
        local _append_string_token_value = function(ch)
            if token_value:len() < max_string_len then
                token_value = token_value .. ch
            else
                truncated = true      
            end
            return true
        end        
    
        local _handle_number = function(ch)
        
            -- TODO: check if the token value is too long
        
            if token_substate == 'zero-or-digit' then
            
                -- Had a minus before.
                if ch == '0' then
                    -- Leading zero, expect a dot or the end of token afterwards.
                    token_substate = 'dot'
                    if not _append_token_value(ch) then return false end
                elseif string.find("123456789", ch, 1, true) then
                    -- Non-zero digit, any digit or dot can follow.
                    token_substate = 'digit'
                    if not _append_token_value(ch) then return false end                
                else
                    -- Something else, let's fail because we have only a minus so far.
                    return _fail("unexpected character in a number at %d", position + i)
                end
            
            elseif token_substate == 'dot' then
            
                -- After a leading zero now, expecting a dot or the end of the token here.
                if ch == '.' then
                    token_substate = 'fraction-digit'
                    if not _append_token_value(ch) then return false end                
                else
                    return _process_number_token(), true
                end
            
            elseif token_substate == 'digit' then
            
                -- Digits before the dot.
                if string.find("0123456789", ch, 1, true) then
                    if not _append_token_value(ch) then return false end                
                elseif ch == 'e' or ch == 'E' then
                    -- Exponent in a number without the fractional part
                    token_substate = 'exp-sign'
                    if not _append_token_value(ch) then return false end                
                elseif ch == '.' then
                    token_substate = 'fraction-digit'
                    if not _append_token_value(ch) then return false end                
                else
                    return _process_number_token(), true
                end
            
            elseif token_substate == 'fraction-digit' then
            
                -- Digits after the dot.
                if string.find("0123456789", ch, 1, true) then
                    if not _append_token_value(ch) then return false end                
                elseif ch == 'e' or ch == 'E' then
                    token_substate = 'exp-sign'
                    if not _append_token_value(ch) then return false end                
                else
                    return _process_number_token(), true
                end
            
            elseif token_substate == 'exp-sign' then
            
                if ch == '-' or ch == '+' then
                    token_substate = 'exp'
                    if not _append_token_value(ch) then return false end                
                else
                    -- Got something different from plus or minus, let's reevaluate the current character.
                    token_substate = 'exp'
                    return true, true
                end
            
            elseif token_substate == 'exp' then
            
                if string.find("0123456789", ch, 1, true) then
                    if not _append_token_value(ch) then return false end                
                else
                    return _process_number_token(), true
                end
            
            else
                return _fail("wrong parser state")
            end
        
            return true
        end
                    
        -- Called for every chunk of the data to be parsed. 
        -- Returns false, if the parsing has failed and no more data should be fed.
        self.process = function(self, data)
        
            if token_state == 'done' then return false end
        
            local i = 1                
            while i <= data:len() do
                local ch = data:sub(i, i)
                local reevaluate = false
                if token_state == 'space' then                
                    if string.find("\n\r\t ", ch, 1, true) then
                        -- Whitespace, just skipping. Could include more characters, but these alone are reasonable.
                    elseif string.find("{}[],:", ch, 1, true) then
                        -- All these characters are tokens on their own.
                        if not _process_token(ch, ch) then return false end
                    elseif ch == "\"" then
                        -- Beginning a string.
                        token_state = 'string'
                        token_value = ""
                        token_substate = 'char'
                        truncated = false
                    elseif string.find("-0123456789", ch, 1, true) then
                        -- Looks like start of a number.
                        token_state = 'number'
                        if ch == "-" then
                            token_substate = 'zero-or-digit'
                        elseif ch == "0" then
                            token_substate = 'dot'
                        else
                            token_substate = 'digit'
                        end
                        token_value = ch
                    elseif ch == "t" then
                        token_state = 'const'
                        expected_const = 'true'
                        token_pos = 1
                        token_value = true
                    elseif ch == "f" then
                        token_state = 'const'
                        expected_const = 'false'
                        token_pos = 1
                        token_value = false
                    elseif ch == "n" then
                        token_state = 'const'
                        expected_const = 'null'
                        token_value = nil
                        token_pos = 1
                    else
                        return _fail(string.format("invalid token at %d", position + i))
                    end
                elseif token_state == 'string' then
                    if token_substate == 'char' then
                        if ch == '"' then
                            if not _process_token('string', token_value) then return false end
                            token_state = 'space'
                        elseif ch == '\\' then
                            token_substate = 'escape-char'
                        else
                            if not _append_string_token_value(ch) then return false end
                            -- TODO: check if the string is too long
                        end
                    elseif token_substate == 'escape-char' then    
                        local p = string.find("\"\\/bfnrt", ch, 1, true)
                        if p then 
                            if not _append_string_token_value(string.sub("\"\\/\b\f\n\r\t", p, p)) then return false end
                            token_substate = 'char'
                        elseif ch == 'u' then
                            token_substate = 'unicode'
                            token_unicode_value = ""
                        else
                            return _fail("invalid escape character at %d", position + i)
                        end
                    elseif token_substate == 'unicode' then
                        if ch:match("%x") then
                            token_unicode_value = token_unicode_value .. ch
                            if token_unicode_value:len() == 4 then
                                token_substate = 'char'
                                local w = tonumber(token_unicode_value, 16)
                                local utf8 = ""
                                local shift_mask = function(x, disp, mask)
                                    local _bit
                                    if bit32 then 
                                        _bit = bit32
                                    else 
                                        _bit = bit
                                    end
                                    return _bit.band(_bit.rshift(x, disp), mask)
                                end
                                if w <= 127 then
                                    utf8 = string.char(w)
                                elseif w <= 2047 then
                                    utf8 = string.char(192 + shift_mask(w, 6, 31), 128 + shift_mask(w, 0, 63))
                                elseif w <= 65535 then
                                    utf8 = string.char(224 + shift_mask(w, 12, 15), 128 + shift_mask(w, 6, 63), 128 + shift_mask(w, 0, 63))
                                else
                                    assert(false)
                                end
                                if not _append_string_token_value(utf8) then return false end
                            end
                        else
                            return _fail("expected a hex digit at %d", position + i)
                        end
                    else
                        assert(false)
                    end
                elseif token_state == 'number' then
                    local succeeded
                    succeeded, reevaluate = _handle_number(ch)
                    if not succeeded then return false end
                elseif token_state == 'const' then
                    token_pos = token_pos + 1
                    if ch == expected_const:sub(token_pos, token_pos) then
                        if token_pos == expected_const:len() then
                            if not _process_token('const', token_value) then return false end
                        end
                    else
                        return _fail(string.format("expected %s at %d", token_value, position + i))
                    end
                elseif token_state == 'done' then 
                    return true
                end
            
                -- Jump to the next character unless we need to reevaluate it based on a different token state.
                if not reevaluate then
                    i = i + 1
                end
            end
        
            position = position + data:len()
        
            return true
        end
    
        -- Should be called when no more data is available. 
        -- The parser will verify that the end of the root object has been received.
        self.finish = function(self, data)
            if token_state == 'done' then
                return true
            else
                return _fail("the document is incomplete")
            end
        end
        
        return self
    end
}
