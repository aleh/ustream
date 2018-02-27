-- uhttp, streaming-style HTTP parser and client for NodeMCU.
-- Copyright (C) 2017, Aleh Dzenisiuk. 

local parser_new = function () 
    return require("uhttp").parser.new({
        status = function(p, code, phrase)
            print(string.format("Status: %d '%s'", code, phrase))
            return true
        end,
        header = function(p, name, value)
            print(string.format("Header: '%s': '%s'", name, value))
            return true
        end,
        body = function(p, data)
            print(string.format("Data: '%s'", data))
            return true
        end,
        done = function(p, leftover)
            print(string.format("Done. Leftover: '%s'", leftover))
        end,
        error = function(p, error)
            print(string.format("Error: %s", error))
        end
    })
end

local p = parser_new()
p:process("HTTP/1.1")
p:process(" 200 OK\r\n")
p:process("Connection: keep-alive\r\n")
p:process("Server: meinheld/0.6.1\r\n")
p:process("Date: Sat, 30 Sep 2017 23:17:54 GMT\r\n")
p:process("Content-Type: application/json\r\n")
p:process("Content-Length: 39\r\n")
p:process("\r\n")
p:process("Body. ")
p:process("Will we support chunked encoding? Extra stuff here, not part of the content")
assert(p:finish())

local p = parser_new()
p:process("HTTP/1.1")
p:process(" 200 OK\r\n")
p:process("Connection: keep-alive\r\n")
p:process("Server: meinheld/0.6.1\r\n")
p:process("Date: Sat, 30 Sep 2017 23:17:54 GMT\r\n")
p:process("Content-Type: application/json\r\n")
p:process("Transfer-Coding: chunked\r\n")
p:process("\r\n")
p:process("00010\r\n")
p:process("Body. ")
p:process("Will we su000010\r\npport chunked en000007\r\ncoding?0\r\nExtra stuff here, not part of the content")
assert(p:finish())

local p = parser_new()
p:process("HTTP/1.1")
p:process(" 200 OK\r\n")
p:process("Connection: keep-alive\r\n")
p:process("Server: meinheld/0.6.1\r\n")
p:process("Date: Sat, 30 Sep 2017 23:17:54 GMT\r\n")
p:process("Content-Type: application/json\r\n")
p:process("Transfer-Coding: chunked\r\n")
p:process("\r\n")
p:process("00010\r\n")
p:process("Body. ")
p:process("Will we su")
assert(not p:finish())

local p = parser_new()
p:process("HTTP/1.1")
p:process(" 200 OK\r\n")
p:process("Connection: keep-alive\r\n")
p:process("Server: meinheld/0.6.1\r\n")
p:process("Date: Sat, 30 Sep 2017 23:17:54 GMT\r\n")
p:process("Content-Type: application/json\r\n")
p:process("Transfer-Coding: chunked\r\n")
p:process("\r\n")
p:process("00010\r\n")
p:process("Body. ")
p:process("Will we su0000\r\nExtra")
assert(p:finish())
assert(not p:process("Stuff after finish()\r\n"))
