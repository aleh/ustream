local uhttp = require("uhttp")

local parser = uhttp.parser:new({
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
parser:process("HTTP/1.1")
parser:process(" 200 OK\r\n")
parser:process("Connection: keep-alive\r\n")
parser:process("Server: meinheld/0.6.1\r\n")
parser:process("Date: Sat, 30 Sep 2017 23:17:54 GMT\r\n")
parser:process("Content-Type: application/json\r\n")
parser:process("Content-Length: 39\r\n")
parser:process("\r\n")
parser:process("Body. ")
parser:process("Will we support chunked encoding? Extra stuff here, not part of the content")
parser:finish()
