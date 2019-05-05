# µstream. Streaming-style HTTP and JSON parsing in Lua for NodeMCU

[NodeMCU](http://www.nodemcu.com/index_en.html) devices are very much memory constrained. For example, on a system I am tinkering with there is about 20-30KB of heap when my RSS-checking Lua script has a chance to run. The default JSON and HTTP socket wrappers however assume that there is enough memory to fit the entire response. Practically that means that I cannot even download a 8KB google's home page using the default HTTP client.

A streaming-style HTTP client would return bytes in chunks similar in size to what's the network stack is returning (1.5-5.5KB), so I could process this data piece by piece without putting everything into memory first. This is something that `uhttp` class is trying to solve by wrapping the standard socket together with a streaming-style HTTP parser.

This piece-by-piece processing means writing the body of the response into a file, so it can be later parsed by a JSON parser (hence `ujson` class here). I want this to be done in a similar memory efficient manner, i.e. my callbacks are notified about every key/value pair and start/end of the enclosed object, but I don't need much memory to traverse the whole document and pick only the bits I need (should be the order of the max string length currently, though implementing begin/end events for every string should be straghtforward).

## uhttp

Here is an example of a download function (part of `uhttp.request`) that writes an HTTP response directly into a file without using much memory:

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

Instead of writing the data into a file you could process the data some other way. 

Note the the logical step of using a JSON parser here is not feasible as the parser itself (code) takes too much memory and is very slow, so I am downloading data into a file first and process it afterwards.

Here is how you can use the download() function:

    local request = require("uhttp_request").new()
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

Example of using the HTTP parser alone:

    local parser = require("uhttp_parser").new({
        status = function(p, code, phrase)
            print(string.format("Status: %d '%s'", code, phrase))
            return true
        end,
        -- Called for every header.
        header = function(p, name, value)
            print(string.format("Header: '%s': '%s'", name, value))
            return true
        end,
        -- This is called multiple times as well as data is fed via process().
        body = function(p, data)
            print(string.format("Data: '%s'", data))
            return true
        end,
        -- Called once. The leftover is unused part of the data in the last call to process().
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
    parser:process("Date: Sat, 30")
    parser:process(" Sep 2017 23:17:54 GMT\r\n")
    parser:process("Content-Length:")
    parser:process(" 39\r\n")
    parser:process("\r\n")
    parser:process("Body. ")
    parser:process("Will we support chunked encoding? Extra stuff here, not part of the content")
    assert(parser:finish())

## ujson

