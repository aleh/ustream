# µstream. Streaming-style HTTP and JSON parsing in Lua for NodeMCU

[NodeMCU](http://www.nodemcu.com/index_en.html) devices are very memory constrained. For example, on a system I am
tinkering with there is about 20-30KB of heap when my RSS-checking Lua script has a chance to run. The default JSON
parser and HTTP socket wrapper however assume that there is enough memory to fit the entire response. Practically that
means that even a 8KB page can be challenging to download and parse using the standard modules.

A streaming-style HTTP client would parse the response on the fly and return the body in small chunks (~1.5KB) while
they are read from the network layer. This way it would be possible to process the response piece by piece without
putting everything into memory first. This is something that `uhttp_request` module is doing by pairing the standard
socket with a streaming-style HTTP parser from `uhttp_parser`.

These chunks of the response can be written into a file one by one for later use, or, in case the body is in JSON
format, parsed using JSON streaming parser, `ujson`. This one can process data in chunks again and notify the client
code about every key/value pair and start/end of the enclosed objects as soon as they are found without storing them,
so little memory is needed to traverse the whole document and pick only the pieces needed.

## uhttp

Here is an example of a download function (part of `uhttp_request`) that writes an HTTP response directly into a file without using much memory:

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
                    completed(false, string.format("Expected 200, got %d", code))
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

Instead of writing the data into a file you could process it some other way. 

(Note that a logical step of using a JSON parser here is not feasible as the parser itself (code) takes too much memory and is very slow, so I am downloading data into a file first and process it afterwards.)

Here is how you can use `download()` function from `uhttp_request`:

    local request = require("uhttp_request")()
    request:download(
        host, path, port,
        "filename.json",
        function(succeeded, message)
            -- Let's make sure to not hold any memory after the request is done.
            request = nil
            if succeeded then
                -- Work with your file on flash.
            else
                -- Something failed, check diagnostic info in 'message'.
            end
        end
    )

Example of using `uhttp_parser` alone:

    local parser = require("uhttp_parser")(
        function(p, code, phrase)
            print(string.format("Status: %d '%s'", code, phrase))
            return true
        end,
        -- Called for every header.
        function(p, name, value)
            print(string.format("Header: '%s': '%s'", name, value))
            return true
        end,
        -- This is called multiple times as well as data is fed via process().
		function(p, data)
            print(string.format("Data: '%s'", data))
            return true
        end,
        -- Called once. The leftover is unused part of the data in the last call to process().
        function(p, leftover)
            print(string.format("Done. Leftover: '%s'", leftover))
        end,
        function(p, error)
            print(string.format("Error: %s", error))
        end
    )

    parser:process("HTTP/1.1")
    parser:process(" 200 OK\r\n")
    parser:process("Connection: keep-alive\r\n")
    parser:process("Date: Sat, 30")
    parser:process(" Sep 2017 23:17:54 GMT\r\n")
    parser:process("Content-Length:")
    parser:process(" 39\r\n")
    parser:process("\r\n")
    parser:process("Body. ")
    parser:process("Will we support chunked encoding? Extra stuff here, not part of the content")
    assert(parser:finish())

## ujson

