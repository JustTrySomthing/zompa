local zompado = require("zompado")
local count = 0

function love.load()
    count = tonumber(zompado.load("progress")) or 0
end

local function add()
    count = count + 1
    local saved, errorMessage = zompado.save("progress", tostring(count))
    if not saved then print(errorMessage) end
end

function love.mousepressed(_, _, button)
    if button == 1 then add() end
end

function love.keypressed(key)
    if key == "space" then add() end
end

function love.draw()
    local width, height = love.graphics.getDimensions()
    love.graphics.clear(0.10, 0.07, 0.18)
    love.graphics.setColor(1, 0.86, 0.44)
    love.graphics.printf(tostring(count), 0, height / 2 - 20, width, "center")
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf("Tap or press Space", 0, height / 2 + 12, width, "center")
end
