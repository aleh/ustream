local ujson = require("ujson")

function test(msg, ...)
    print(string.format(msg, ...))
end

p = ujson:new({
    error = function(p, error)
        print("Error: " .. error)
    end,
    begin_element = function(p, path, key, type)
        return true
    end,
    element = function(p, path, key, value)
        print(p:string_for_path(path))
        if path[2] == "array" and path[4] == "key" then
            print(value)
        end
        return true
    end,
    end_element = function(p, path)
        return true
    end,
    done = function(p)
        print("Done")
    end
})

p:process('{')
p:process('"test" : "😀 emoji and')
p:process(' time\\u23f0\t",')
p:process('"test-bool" : true,')
p:process('"test-nil" : null,')
p:process('"0": 0, "-0": -0, "123": 123, "123": -123, "fixed" : 0.123, "exp1" : 0.123e-5, "exp1" : 0.123e+5, "exp3" : 6e5,')
p:process('"array-empty": [],')
p:process('"array": [1, 2, true, null, false, { "key" : "value" }],')
p:process('"array-empty-2": [],')
p:process('}')
p:finish()
