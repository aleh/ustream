# µstream

Streaming-style HTTP and JSON parsing in Lua for NodeMCU.

NodeMCU devices are very much memory constrained. For example, on a particular system I am tinkering with there is about 20KB of heap when my RSS-checking Lua script has a chance to run. The default JSON and HTTP socket wrappers however assume that there is enough memory to fit the entire response. Practically that means that I cannot even download a 8KB google's home page using the default wrapper.

A streaming-style HTTP socket would return bytes in the chunks similar in size to what's the network stack is returning (about 1.5KB), so I could process this data piece by piece without putting it into memory first. This is something that `uhttp` class is trying to solve by wrapping the standard socket together with a streaming-style HTTP parser.

This piece-by-piece processing means parsing JSON in my case and that's why the `ujson` class. I want this to be done in a similar memory efficient manner, i.e. when my callbacks are notified about every key/value pair and start/end of the enclosed object, but I don't need much memory to traverse the whole document and pick only the bits I need (should be the order of the max string length currently, though implementing begin/end events for every string should be straghtforward).
