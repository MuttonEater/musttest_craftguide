local function serialize_stack(stack)
	return { stack:get_name() or "", stack:get_definition().type == "tool" and stack:get_wear() or stack:get_count() }
end

-- Handle non-standard recipes with multiple output items.
-- Reference: musttest_game/mods/craft_register/init.lua
local function serialize_output(output)
	if type(output) == "string" then
		-- If it's a string, it is very possibly an itemstring.
		return { count = 1, items = { serialize_stack(ItemStack(output)) }}

	elseif type(output) == "table" then
		-- If it is a table, it could represent different things:
		--   - An ItemStack serialized in its table representation.
		--   - An output of a recipe with a non-standard craft method.

		if output.name and output.name ~= "" then
			-- It must be the table representation of an ItemStack.
			return { count = 1, items = { serialize_stack(ItemStack(output)) }}

		elseif type(output.output) == "string" then
			-- It's the output of a non-standard craft recipe, with a single output.
			return { count = 1, items = { serialize_stack(ItemStack(output.output)) }}
		else
			-- Here it could still be the output of a non-standard craft recipe with
			-- single craft result, in its table representation. We assume it isn't.

			-- It's the output of a non-standard craft recipe, with multiple outputs.
			local ret = { count = #output.output, items = {} }
			for _, v in ipairs(output.output) do
				table.insert(ret.items, serialize_stack(ItemStack(v)))
			end
			return ret
		end
	end
end

item_defs = {}
usages = {}
crafts = {}
groups = {}

local mt_registered_items = minetest.registered_items
local mt_get_item_group = minetest.get_item_group

local function get_craft_recipes(def_name)
	local item_crafts = minetest.get_all_craft_recipes(def_name)
	if not item_crafts then
		return
	end

	for index, craft in ipairs(item_crafts) do
		local craft_items = {}
		local width = craft.width > 0 and craft.width or 1

		for i = #craft.items, width, -width do
			local keep_line
			for j = i, math.max(1, i - width), -1 do
				local item = craft.items[j]
				if item and item ~= "" then
					keep_line = true
					break
				end
			end

			if not keep_line then
				for j = i, math.max(1, i - width), -1 do
					table.remove(craft.items, j)
				end
			end
		end

		local maxidx = 1
		for index, item in pairs(craft.items) do
			craft_items[index] = serialize_stack(ItemStack(item))
			maxidx = math.max(maxidx, index)
		end

		for i = 1, maxidx do
			if not craft_items[i] then
				craft_items[i] = {}
			end
		end

		local craft_index = #crafts
		item_crafts[index] = craft_index

		table.insert(crafts, {
			method = craft.method,
			type = craft.type,
			shapeless = craft.width == 0,
			width = craft.width ~= 0 and math.min(#craft_items, craft.width),
			items = craft_items,
			output = serialize_output(craft.output) -- serialize_stack(stack)
		})

		for _, item in pairs(craft.items or {}) do
			local itemname = ItemStack(item):get_name()

			if not item_defs[itemname] then
				usages[itemname] = usages[itemname] or {}
				if not modlib.table.find(usages[itemname], craft_index) then
					table.insert(usages[itemname], craft_index)
				end
			else
				local tab = item_defs[itemname].usages
				if not tab then
					tab = {}
					item_defs[itemname].usages = tab
				end
				if not modlib.table.find(tab, craft_index) then
					table.insert(tab, craft_index)
				end
			end

			-- If the recipe item is a group, must add this recipe to every other
			-- item having this group! Sigh.
			if string.find(itemname, "^group:") then
				local group_name = string.sub(itemname, 7)
				local group_names = string.split(group_name, ",")

				-- Iterate over all registered items and check if they have this group.
				for k, v in pairs(mt_registered_items) do
					-- Handle multiple groups correctly: the item must be in *all* the
					-- listed groups, if more.
					local has_groups = true
					for _, gn in ipairs(group_names) do
						if mt_get_item_group(k, gn) == 0 then
							has_groups = false
							break
						end
					end

					if has_groups then
						local itemname = ItemStack(k):get_name()
						if not item_defs[itemname] then
							usages[itemname] = usages[itemname] or {}
							if not modlib.table.find(usages[itemname], craft_index) then
								table.insert(usages[itemname], craft_index)
							end
						else
							local tab = item_defs[itemname].usages
							if not tab then
								tab = {}
								item_defs[itemname].usages = tab
							end
							if not modlib.table.find(tab, craft_index) then
								table.insert(tab, craft_index)
							end
						end
					end
				end -- for k, v
			end -- if string.find(itemname, "^group:")

		end -- for _, item in ipairs(craft.items or {}) do
	end

	return item_crafts
end


local handle = io.open(minetest.get_modpath("online_craftguide") .. "/docs/index.html", "w")
function minetest_to_html(text)
	local previous_color
	return text:gsub("<", "&lt;"):gsub("'", "&apos;"):gsub('"', "&quot;"):gsub("\n", "<br>"):gsub("\27E", ""):gsub("\27%((%a)@(.-)%)", function(type, args)
		if type == "c" and previous_color ~= args then
			local retval = (previous_color and "</span>" or "") .. "<span style='color: " .. args .. " !important;'>"
			previous_color = args
			return retval
		end
		return ""
	end) .. (previous_color and "</span>" or "")
end

function minetest_to_searchable(text)
	return text:gsub("\27%((%a)@(.-)%)", ""):gsub("\27E", ""):lower()
end

function add_item(name, def)
	if def.groups and def.groups.not_in_creative_inventory then
		return
	end

	-- if def.groups and def.groups.not_in_craft_guide then
	-- 	return
	-- end

	if def.description == "" then
		return
	end

	local def_name = def.name
	local item = item_defs[def_name]
	if not item then
		local title, description = unpack(modlib.text.split(def.description, "\n", 2))
		title = title and string.trim(title) or nil
		description = description and string.trim(description) or nil

		item = {
			crafts = get_craft_recipes(def_name),
			title = minetest_to_html(title),
			description = description and minetest_to_html(description) or nil,
			searchable_description = minetest_to_searchable(def.description),
			type = def.type,
			groups = def.groups,
			usages = usages[def.name]
		}

		if def.groups then
			for group, rating in pairs(def.groups) do
				groups[group] = groups[group] or {}
				groups[group][def_name] = rating
			end
		end

		item_defs[def_name] = item
	end

	if name ~= def_name then
		item.aliases = item.aliases or {}
		table.insert(item.aliases, name)
	end
end

function preprocess_html(text)
	local regex = [[(<svg%s+class=['"]bi%sbi%-)(.-)(['"].->.-</svg>)]]
	local replaced

	return text:gsub(regex, function(_, match)
		local svg = modlib.file.read(minetest.get_modpath("online_craftguide") .. "/node_modules/bootstrap-icons/icons/" .. match:match"%S+" .. ".svg")
		return svg:gsub(regex, function(before, _, after)
			return before .. match .. after
		end):gsub("\n", "")
	end):gsub([[<script%s*src=['"]online_craftguide['"]>.-</script>]], function()
		if replaced then
			error("multiple script tags")
		end
		replaced = true
		return "<script>items = " .. minetest.write_json(item_defs) .. "; crafts = " .. minetest.write_json(crafts) .. "; groups = " .. minetest.write_json(groups) .. "</script>"
	end)
end

minetest.register_on_mods_loaded(function()
	for name, def in pairs(minetest.registered_items) do
		add_item(name, def)
	end

	-- Remove items if they don't have any crafts, nor usages.
	for name, def in pairs(item_defs) do
		if (not def.crafts or #def.crafts == 0) and (not def.usages or #def.usages == 0) then
			item_defs[name] = nil
		end
	end

	for _, item in pairs(item_defs) do
		if item.aliases then
			table.sort(item.aliases)
		end
	end
	local html = preprocess_html(modlib.file.read(modlib.mod.get_resource("online_craftguide", "index.html")))
	handle:write(html)
	handle:close()
end)
