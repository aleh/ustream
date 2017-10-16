-- ujson, streaming-style JSON parser.
-- Copyright (C) 2017, Aleh Dzenisiuk. 

--[[
    Simple streaming-style JSON parser originally made for NodeMCU, but not using any APIs specific to it.

    Import as usual:
    
    local ujson = require("ujson")
    
    Then create an instance using ujson:new() passing a dictionary of parsing event handlers:
    
        - 'element' = function(p, path, key, value)
            
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
        
        - 'begin_element' = function(p, path, key, type)
        - 'end_element' = function(p, path)
            
            These are called at a start and end of an array (type == '[') or a dictionary (type == '{'). 
            The `key` and `path` parameters are similar to the ones in the `element` callback.
            
        - 'error' = function(p, error)
            
            Called once when a parsing error is encountered. The corresponding call of `process` method will return false.
            
        - 'done' = function(p)
            
            Called once after the root object is successfully parsed.
            
    Every handler returns `true` to indicate that the parsing can continue and `false` to mean that a parsing error 
    should be triggered.
    
    The data is fed via `process` method accepting a single string as a parameter. The method returns `false` 
    in case a parsing error has happend. 
    
    It is safe to call `process` even after the parsing has failed, it won't call the `error` callback more than once.
    
    The `finish` method should be called after all the data is fed. An error will be triggered if there is not enough data 
    in the incoming stream to complete the document.
]]--
local ujson = {
    
    new = function(self, handlers)        
        o = {}
        setmetatable(o, self)
        self.__index = self
        o:_begin(handlers)
        return o
    end,
    
    _begin = function(self, handlers)
        self.handlers = handlers
        -- The state of the parser.
        self.state = 'idle'
        -- Parser's stack (each character is an item) to remember if we are handling an array or a dictionary.
        self.stack = ''
        -- The current key path array, such as { "key1", 12, "key2" }, where every string elements represents a dictionary key 
        -- and a number element represents an index in an array.
        self.path = {}
        -- The state of the tokenizer.
        self.token_state = 'space'
        -- Global position in the incoming data, used only to report errors. TODO: perhaps not very useful and should be removed.
        self.position = 0
    end,
    
    _cleanup = function(self)
        self.handlers = nil
        self.stack = nil
        self.token_state = 'done'
        self.token_substate = nil
        self.token_value = nil
    end,
    
    _trace = function(self, s, ...)
        print(string.format("ujson: " .. s, ...))
    end,
    
    -- For the fiven document path returns a string suitable for diagnostics, 
    -- e.g. "root[2][\"test2\"]" for the example above.
    string_for_path = function(self, path)
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
    end,
    
    _begin_element = function(self, key, type)
        table.insert(self.path, key)
        -- self:_trace("%s begin %q", self:string_for_path(path), type)
        if self.handlers.begin_element then
            return self.handlers.begin_element(self, self.path, key, type)
        else
            return true
        end
    end,
    
    _element = function(self, key, value)
        table.insert(self.path, key)
        -- self:_trace("%s %q -> '%s' (%s)", self:string_for_path(path), key, value, type(value))
        local result = self.handlers.element(self, self.path, key, value)        
        table.remove(self.path)
        return result
    end,
    
    _end_element = function(self)
        
        -- self:_trace("%s end", self:string_for_path(path))
        
        local result
        if self.handlers.end_element then
            result = self.handlers.end_element(self, self.path)
        else
            result = true
        end
        
        table.remove(self.path, key)
        return result
    end,
    
    _fail = function(self, msg, ...)
        if self.state ~= 'done' then
            -- self:_trace("failed: " .. msg, ...)
            self.handlers.error(self, string.format(msg, ...))
            self:_cleanup()
        end
    end,
    
    _done = function(self)
        if self.state ~= 'done' then
            self.state = 'done'
            -- self:_trace("done")
            self.handlers.done(self)
            self:_cleanup()
        end
    end,
    
    _pop_state = function(self)
        
        if self.stack:len() == 0 then
            assert(false)
            return self:_fail("invalid parser state")
        end
        
        self.stack = self.stack:sub(1, -2)
        local prev_state = self.stack:sub(-1)
        if prev_state == 'A' then
            self.state = 'array-comma'
        elseif prev_state == 'D' then
            self.state = 'dict-comma'
        else
            self:_done()
        end
        
        return true
    end,
        
    _process_token = function(self, token_type, token_value)
        
        self.token_state = 'space'
        
        --[[
        if token_type == token_value then
            self:_trace("token '%s'", token_type)
        else
            self:_trace("token '%s' -> '%s' (%s)", token_type, token_value, type(token_value))
        end
        ]]--
        
        if self.state == 'idle' then
            if token_type == '{' then
                if not self:_begin_element('', '{') then 
                    return self:_fail("_begin_element handler has failed")
                end
                self.stack = self.stack .. 'D'
                self.state = 'dict-key'
            else
                return self:_fail("expected an object (dictionary) in the root")
            end
        elseif self.state == 'dict-key' then
            if token_type == 'string' then
                self.current_key = token_value
                self.state = 'dict-colon'
            elseif token_type == '}' then
                if not self:_end_element() then
                    return self:_fail("end_object handler has failed")
                end
                if not self:_pop_state() then return false end
            else
                return self:_fail("expected a string object key, got '%s'", token_type)
            end
        elseif self.state == 'dict-colon' then
            if token_type == ':' then
                self.state = 'dict-value'
            else
                return self:_fail("expected a colon, got '%s'", token_type)
            end
        elseif self.state == 'dict-value' or self.state == 'array-element' then
            if self.state == 'array-element' then
                self.current_key = self.current_key + 1
            end
            if token_type == 'const' or token_type == 'string' or token_type == 'number' then
                if self.state == 'dict-value' then
                    self.state = 'dict-comma'
                else
                    self.state = 'array-comma'
                end
                self:_element(self.current_key, token_value)
            elseif token_type == '[' then
                self.stack = self.stack .. 'A'
                self.state = 'array-element'
                if not self:_begin_element(self.current_key, '[') then
                    return self:_fail("begin_element handler has failed")
                end
                self.current_key = 0
            elseif token_type == '{' then
                self.stack = self.stack .. 'D'
                self.state = 'dict-key'
                if not self:_begin_element(self.current_key, '{') then
                    return self:_fail("begin_element handler has failed")
                end
            elseif token_type == ']' and self.state == 'array-element' then
                if not self:_pop_state() then return false end
                if not self:_end_element() then 
                    return self:_fail("end_element handler has failed") 
                end
            else
                return self:_fail("expected a value, but got '%s'", token_type)
            end
        elseif self.state == 'array-comma' then
            if token_type == ',' then
                self.state = 'array-element'
            elseif token_type == ']' then
                if not self:_pop_state() then return false end
                if not self:_end_element() then 
                    return self:_fail("end_element handler has failed") 
                end
            else
                return self:_fail("expected a comma or end of array, but got '%s'", token_type)
            end
        elseif self.state == 'dict-comma' then
            if token_type == ',' then
                self.state = 'dict-key'
            elseif token_type == '}' then
                if not self:_pop_state() then return false end
                if not self:_end_element() then
                    return self:_fail("_end_object() failed")
                end
            end
        else
            assert(false)
            return self:_fail("invalid parser state: '%s'", self.state)
        end
        
        return true
    end,
        
    _process_number_token = function(self)
        return self:_process_token('number', tonumber(self.token_value))
    end,
    
    _handle_number = function(self, ch)
        
        -- TODO: check if the token value is too long
        
        if self.token_substate == 'zero-or-digit' then
            
            -- Had a minus before.
            if ch == '0' then
                -- Leading zero, expect a dot or the end of token afterwards.
                self.token_substate = 'dot'
                self.token_value = self.token_value .. ch
            elseif string.find("123456789", ch, 1, true) then
                -- Non-zero digit, any digit or dot can follow.
                self.token_substate = 'digit'
                self.token_value = self.token_value .. ch                
            else
                -- Something else, let's fail because we have only a minus so far.
                return self:_fail("unexpected character in a number at %d", self.position + i)
            end
            
        elseif self.token_substate == 'dot' then
            
            -- After a leading zero now, expecting a dot or the end of the token here.
            if ch == '.' then
                self.token_substate = 'fraction-digit'
                self.token_value = self.token_value .. ch
            else
                return self:_process_number_token(), true
            end
            
        elseif self.token_substate == 'digit' then
            
            -- Digits before the dot.
            if string.find("0123456789", ch, 1, true) then
                self.token_value = self.token_value .. ch
            elseif ch == 'e' or ch == 'E' then
                -- Exponent in a number without the fractional part
                self.token_substate = 'exp-sign'
                self.token_value = self.token_value .. ch
            elseif ch == '.' then
                self.token_substate = 'fraction-digit'
                self.token_value = self.token_value .. ch
            else
                return self:_process_number_token(), true
            end
            
        elseif self.token_substate == 'fraction-digit' then
            
            -- Digits after the dot.
            if string.find("0123456789", ch, 1, true) then
                self.token_value = self.token_value .. ch
            elseif ch == 'e' or ch == 'E' then
                self.token_substate = 'exp-sign'
                self.token_value = self.token_value .. ch
            else
                return self:_process_number_token(), true
            end
            
        elseif self.token_substate == 'exp-sign' then
            
            if ch == '-' or ch == '+' then
                self.token_substate = 'exp'
                self.token_value = self.token_value .. ch
            else
                -- Got something different from plus or minus, let's reevaluate the current character.
                self.token_substate = 'exp'
                return true, true
            end
            
        elseif self.token_substate == 'exp' then
            
            if string.find("0123456789", ch, 1, true) then
                self.token_value = self.token_value .. ch
            else
                return self:_process_number_token(), true
            end
            
        else
            assert(false)
            return self:_fail("unexpected parser state")
        end
        
        return true
    end,
    
    -- Called for every chunk of the data to be parsed. 
    -- Returns false, if the parsing has failed and no more data should be fed.
    process = function(self, data)
        
        if self.token_state == 'done' then return false end
        
        local i = 1                
        while i <= data:len() do
            local ch = data:sub(i, i)
            local reevaluate = false
            if self.token_state == 'space' then                
                if string.find("\n\r\t ", ch, 1, true) then
                    -- Whitespace, just skipping. Could include more characters, but these alone are reasonable.
                elseif string.find("{}[],:", ch, 1, true) then
                    -- All these characters are tokens on their own.
                    if not self:_process_token(ch, ch) then return false end
                elseif ch == "\"" then
                    -- Beginning a string.
                    self.token_state = 'string'
                    self.token_value = ""
                    self.token_substate = 'char'
                elseif string.find("-0123456789", ch, 1, true) then
                    -- Looks like start of a number.
                    self.token_state = 'number'
                    if ch == "-" then
                        self.token_substate = 'zero-or-digit'
                    elseif ch == "0" then
                        self.token_substate = 'dot'
                    else
                        self.token_substate = 'digit'
                    end
                    self.token_value = ch
                elseif ch == "t" then
                    self.token_state = 'const'
                    self.expected_const = 'true'
                    self.token_pos = 1
                    self.token_value = true
                elseif ch == "f" then
                    self.token_state = 'const'
                    self.expected_const = 'false'
                    self.token_pos = 1
                    self.token_value = false
                elseif ch == "n" then
                    self.token_state = 'const'
                    self.expected_const = 'null'
                    self.token_value = nil
                    self.token_pos = 1
                else
                    return self:_fail(string.format("invalid token at %d", self.position + i))
                end
            elseif self.token_state == 'string' then
                
                if self.token_substate == 'char' then
                    if ch == '"' then
                        if not self:_process_token('string', self.token_value) then return false end
                        self.token_state = 'space'
                    elseif ch == '\\' then
                        self.token_substate = 'escape-char'
                    else
                        self.token_value = self.token_value .. ch
                        -- TODO: check if the string is too long
                    end
                elseif self.token_substate == 'escape-char' then    
                    local p = string.find("\\/bfnrt", ch, 1, true)
                    if p then 
                        self.token_value = self.token_value .. string.sub("\\/\b\f\n\r\t", p, p)
                        self.token_substate = 'char'
                    elseif ch == 'u' then
                        self.token_substate = 'unicode'
                        self.token_unicode_value = ""
                    else
                        return self:_fail("invalid escape character at %d", self.position + i)
                    end
                elseif self.token_substate == 'unicode' then
                    if ch:match("%x") then
                        self.token_unicode_value = self.token_unicode_value .. ch
                        if self.token_unicode_value:len() == 4 then
                            self.token_substate = 'char'
                            local w = tonumber(self.token_unicode_value, 16)
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
                            self.token_value = self.token_value .. utf8
                        end
                    else
                        return self:_fail("expected a hex digit at %d", self.position + i)
                    end
                else
                    assert(false)
                end

            elseif self.token_state == 'number' then
                local succeeded
                succeeded, reevaluate = self:_handle_number(ch)
                if not succeeded then return false end
            elseif self.token_state == 'const' then
                self.token_pos = self.token_pos + 1
                if ch == self.expected_const:sub(self.token_pos, self.token_pos) then
                    if self.token_pos == self.expected_const:len() then
                        if not self:_process_token('const', self.token_value) then return false end
                    end
                else
                    return self:_fail(string.format("expected %s at %d", self.token_value, self.position + i))
                end
            elseif self.token_state == 'done' then 
                return true
            end
            
            -- Jump to the next character unless we need to reevaluate it based on a different token state.
            if not reevaluate then
                i = i + 1
            end
        end
        
        self.position = self.position + data:len()
        
        return true
    end,
    
    -- Should be called when no more data is available. 
    -- The parser will verify that the end of the root object has been received.
    finish = function(self, data)
        if self.state == 'done' then
            return true
        else
            return self:_fail("the document is incomplete")
        end
    end
}

return ujson

