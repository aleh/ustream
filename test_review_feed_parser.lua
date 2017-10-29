-- ujson, streaming-style JSON parser.
-- Copyright (C) 2017, Aleh Dzenisiuk. 

-- A simple test for the review_feed_parser module.

local max_mem = 0
local print_mem = function()
    collectgarbage()
    local m, _ = collectgarbage('count')
    if m > max_mem then max_mem = m end
    print(string.format("Memory: %dK (max %dK)", m, max_mem))
end

print_mem()

local parser = require("review_feed_parser").new({
    
    review = function(p, review)
        
        local stars = function(n)
            local result = ""
            for i = 1, 5 do
                if i <= n then
                    result = result .. "★ "
                else
                    result = result .. "☆ "
                end
            end
            return result
        end
        
        print(string.format(
            "---\n\n%s %s (by %s) #%s\n\n%s\n---\n", 
            stars(review.rating), review.title, review.author, review.id, review.content
        ))
    end,
    
    error = function(p, message)
        print("Oops: " .. message)
    end,
    
    done = function(p)
        print("Done")
    end
})

local f = io.open("test_review_feed.json")
while true do
    local line = f:read()
    if not line then break end
    parser:process(line)
    print_mem()
end

parser:finish()
parser = nil
print_mem()

f:close()
f = nil
print_mem()
