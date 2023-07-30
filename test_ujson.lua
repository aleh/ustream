bit32 = require('bit32')

local p = require("ujson")(
    function(p, path, key, type) -- begin_element
        return true
    end,
	function(p, path, key, value) -- element
        print(p:string_for_path(path))
        if path[2] == "array" and path[4] == "key" then
            print(value)
        end
        return true
    end,
    function(p, path) -- end_element
        return true
    end,
	function(p) -- done
        print("Done")
    end,
	function(p, error) -- error
        print("Error: " .. error)
    end
)

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
