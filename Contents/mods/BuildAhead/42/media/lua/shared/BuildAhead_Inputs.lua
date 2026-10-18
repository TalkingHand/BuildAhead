-- Material bans: fill a BuildLogic's inputs the way autoPopulateInputs does,
-- but never with banned item types. Shared: the client uses it for the
-- scheduler's entities, and in multiplayer the server uses it in
-- ISBuildIsoEntity:create, because the server rebuilds the entity from the
-- ISBuildIsoEntity.new arguments only and would pick the inputs again itself.

BuildAheadInputs = BuildAheadInputs or {}

function BuildAheadInputs.hasAny(bans)
    if type(bans) ~= "table" then return false end
    for _, v in pairs(bans) do
        if v then return true end
    end
    return false
end

-- bans: { ["Base.Plank"] = true }; containers: ArrayList of ItemContainer.
-- Manual selection, offering the items one by one until each input is
-- satisfied. Without bans this is plain autoPopulateInputs.
function BuildAheadInputs.fill(logic, bans, containers)
    if not BuildAheadInputs.hasAny(bans) then
        if logic:isManualSelectInputs() then logic:setManualSelectInputs(false) end
        logic:autoPopulateInputs()
        return
    end
    logic:setManualSelectInputs(true)
    local recipe = logic:getRecipe()
    local inputs = recipe and recipe:getInputs()
    if not inputs then return end
    local data = logic:getRecipeData()
    for i = 0, inputs:size() - 1 do
        local d = data:getDataForInputScript(inputs:get(i))
        if d then logic:clearManualInputsFor(d) end
    end
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        local d = data:getDataForInputScript(input)
        if d and not input:isAutomationOnly() and input:getResourceType() == ResourceType.Item then
            -- not logic:isInputSatisfied: BuildLogic answers from a cache that
            -- still holds the auto-populated items until an offer succeeds
            local possible = input:getPossibleInputItems()
            for k = 0, possible:size() - 1 do
                local fullType = possible:get(k):getFullName()
                if not bans[fullType] then
                    for c = 0, containers:size() - 1 do
                        local items = containers:get(c):getAllTypeEvalRecurse(fullType, ISBuildIsoEntity.predicateMaterial)
                        for n = 0, items:size() - 1 do
                            if d:isInputItemsSatisfied() then break end
                            logic:offerInputItem(items:get(n))
                        end
                        if d:isInputItemsSatisfied() then break end
                    end
                end
                if d:isInputItemsSatisfied() then break end
            end
        end
    end
end
