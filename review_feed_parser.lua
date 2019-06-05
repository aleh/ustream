-- ujson, streaming-style JSON parser.
-- Copyright (C) 2017, Aleh Dzenisiuk. 

--[[

    As a test for ujson parser, here is a parser for a JSON feed of iOS app reviews, 
    such as the one returned by this URL:
    https://itunes.apple.com/us/rss/customerreviews/id=389801252/sortby=mostrecent/json
    (Put your own ID instead of Instagram's.)
    
    Usage:
    
    -- Create an instance first.
    local parser = require("review_feed_parser").new({
        review = function(p, review)
            -- Called for every review found in the feed.
            -- Use review.rating, review.title. review.author, review.id, review.content here.
            -- ...
        end,
        error = function(p, message)
            -- ...
        end,    
        done = function(p)
            -- ...
        end
    })

    -- Feed your review feed JSON piece by piece and finish when you have not more data. 
    -- Expect your callbacks to be called each time enough data is accumulated.
    parser:process(part1)
    ...
    parser:process(partN)
    parser:finish()

]]--
return {
    
    new = function(handlers)

        -- Don't want the module to be cached on NodeMCU. Depends on the file name :/
        package.loaded["review_feed_parser"] = nil
        
        -- We do return a self, but store most of the things in locals for better performance on NodeMCU again.
        local self = {}
        
        local handlers_review = handlers.review        
        local handlers_error = handlers.error
        local handlers_done = handlers.done
        
        local parser = nil
        local in_article = false
        local review = nil
        local done = false
        
        local is_article_path = function(path)
            return #path == 4 and path[2] == "feed" and path[3] == "entry" and type(path[4]) == "number" and path[4] > 1
        end
                
        local cleanup = function()
            done = true
            parser = nil
            in_article = nil
            review = nil
            handlers_review = nil
            handlers_error = nil
            handlers_done = nil
        end
        
        self.process = function(self, data)
            if parser then
                return parser:process(data)
            else
                return false
            end
        end
    
        self.finish = function(self)
            if parser then
                return parser:finish()
            else
                return false
            end
        end    
        
        parser = require("ujson")(
			
            function(p, path, key, type)
                if not in_article and is_article_path(path) then
                    in_article = true
                    review = {}
                end
                return true
            end,
            
            function(p, path, key, value, truncated)
                
                -- print(p:string_for_path(path), value)
                if not in_article then return true end
                
                if path[5] == "content" and path[6] == "label" then
                    if truncated then
                        review.content = value .. "..."
                    else
                        review.content = value
                    end
                elseif path[5] == "title" and path[6] == "label" then
                    review.title = value
                elseif path[5] == "id" and path[6] == "label" then
                    -- Forcing the ID to fit 31 bits by using last 9 digits so it works with integer-only
                    -- versions of NodeMCU that allows only 32-bit signed integers.
                    review.id = tonumber(value:sub(-9))
                elseif path[5] == "author" and path[6] == "name" and path[7] == "label"then
                    review.author = value
                elseif path[5] == "im:rating" and path[6] == "label" then
                    review.rating = tonumber(value)
                end
                
                return true
            end,
            
			function(p, path)
                if in_article and is_article_path(path) then
                    in_article = false
                    handlers_review(self, review)
                end
                return true
            end,
            
			function(p)
                if not done then
                    handlers_done(self)
                    cleanup(self)
                end
            end,
            
			function(p, error)
                if not done then
                    handlers_error(self, error)
                    cleanup(self)
                end
            end,
				
			512
        )
        
        return self
    end
}
