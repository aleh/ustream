-- ujson, streaming-style JSON parser.
-- Copyright (C) 2017-2018, Aleh Dzenisiuk. 

-- A simple test for the review_feed_parser module.

local prev_heap
local log_heap = function(msg)
	
	collectgarbage()
	
    local h, _ = collectgarbage('count')
	h = h * 1024
	
    if prev_heap then
        if msg then
            print(string.format("Heap: %d (%+d, %s)", h, h - prev_heap, msg))
        else
            print(string.format("Heap: %d (%+d)", h, h - prev_heap))
        end
    else
        print(string.format("Heap: %d", h))
    end
	
    prev_heap = h
end

log_heap()

local parser = require("review_feed_parser")(
    
	function(p, review) -- review
        
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
        
		if false then
	        print(string.format(
	            "---\n\n%s %s (by %s) #%s\n\n%s\n---\n", 
	            stars(review.rating), review.title, review.author, review.id, review.content
	        ))
		end
		
		log_heap()		
    end,
    
	function(p) -- done
        print("Done")
    end,
	
	function(p, message) -- error
        print("Oops: " .. message)
    end
)

log_heap("created parser")

local f = io.open("test_review_feed.json")
while true do
    local line = f:read()
    if not line then break end
    parser:process(line)
end

parser:finish()
parser = nil
log_heap("done parsing")

f:close()
f = nil
log_heap()
