#!/usr/bin/env resty

require "resty.core"

local lfs = require("lfs")
local cjson = require("cjson")

local data = require("autodoc-admin-api.data")

local KONG_PATH = os.getenv("KONG_PATH")
local KONG_VERSION = os.getenv("KONG_VERSION")

package.path = KONG_PATH .. "/?.lua;" .. KONG_PATH .. "/?/init.lua;" .. package.path

local Endpoints = require("kong.api.endpoints")

-- Minimal boilerplate so that module files can be loaded
_KONG = require("kong.meta")          -- luacheck: ignore
kong = require("kong.global").new()   -- luacheck: ignore
kong.db = require("kong.db").new({    -- luacheck: ignore
  database = "postgres",
})

--------------------------------------------------------------------------------

local methods = {
  "POST",
  "GET",
  "PATCH",
  "PUT",
  "DELETE",
}

local function sortedpairs(tbl)
  local keys = {}
  for key, _ in pairs(tbl) do
    table.insert(keys, key)
  end
  table.sort(keys)
  local i = 0
  return function()
    i = i + 1
    local k = keys[i]
    return k, tbl[k]
  end
end

local function render(template, subs)
  subs = setmetatable(subs, { __index = function(_, k)
    error("failed applying autodoc template: no variable ${" .. k .. "}")
  end })
  return (template:gsub("${([^}]+)}", subs))
end

local function get_or_create(tbl, key)
  local v = tbl[key]
  if not v then
    v = {}
    tbl[key] = v
  end
  return v
end

local function to_plural(singular)
  return singular .. "s"
end

local function to_singular(plural)
  return plural:gsub("s$", "")
end

local function title_case(word)
  return word:sub(1,1):upper() .. word:sub(2)
end

local function entity_to_api_path(entity)
  return "kong/api/routes/" .. entity .. ".lua"
end

local function entity_to_schema_path(entity)
  return "kong/db/schema/entities/" .. entity .. ".lua"
end

local function cjson_encode(value)
  return (cjson.encode(value):gsub("\\/", "/"):gsub(",", ", "))
end

-- A deterministic pseudo-UUID generator, to make autodoc idempotent.
local gen_uuid
do
  local uuids = {
    "9748f662-7711-4a90-8186-dc02f10eb0f5",
    "4e3ad2e4-0bc4-4638-8e34-c84a417ba39b",
    "a5fb8d9b-a99d-40e9-9d35-72d42a62d83a",
    "51e77dc2-8f3e-4afa-9d0e-0e3bbbcfd515",
    "fc73f2af-890d-4f9b-8363-af8945001f7f",
    "4506673d-c825-444c-a25b-602e3c2ec16e",
    "d35165e2-d03e-461a-bdeb-dad0a112abfe",
    "af8330d3-dbdc-48bd-b1be-55b98608834b",
    "a9daa3ba-8186-4a0d-96e8-00d80ce7240b",
    "127dfc88-ed57-45bf-b77a-a9d3a152ad31",
    "9aa116fd-ef4a-4efa-89bf-a0b17c4be982",
    "ba641b07-e74a-430a-ab46-94b61e5ea66b",
    "ec1a1f6f-2aa4-4e58-93ff-b56368f19b27",
    "a4407883-c166-43fd-80ca-3ca035b0cdb7",
    "01c23299-839c-49a5-a6d5-8864c09184af",
    "ce44eef5-41ed-47f6-baab-f725cecf98c7",
    "02621eee-8309-4bf6-b36b-a82017a5393e",
    "66c7b5c4-4aaf-4119-af1e-ee3ad75d0af4",
    "7fca84d6-7d37-4a74-a7b0-93e576089a41",
    "d044b7d4-3dc2-4bbc-8e9f-6b7a69416df6",
    "a9b2107f-a214-47b3-add4-46b942187924",
    "04fbeacf-a9f1-4a5d-ae4a-b0407445db3f",
    "43429efd-b3a5-4048-94cb-5cc4029909bb",
    "d26761d5-83a4-4f24-ac6c-cff276f2b79c",
    "91020192-062d-416f-a275-9addeeaffaf2",
    "a2e013e8-7623-4494-a347-6d29108ff68b",
    "147f5ef0-1ed6-4711-b77f-489262f8bff7",
    "a3ad71a8-6685-4b03-a101-980a953544f6",
    "b87eb55d-69a1-41d2-8653-8d706eecefc0",
    "4e8d95d4-40f2-4818-adcb-30e00c349618",
    "58c8ccbb-eafb-4566-991f-2ed4f678fa70",
    "ea29aaa3-3b2d-488c-b90c-56df8e0dd8c6",
    "4fe14415-73d5-4f00-9fbc-c72a0fccfcb2",
    "a3395f66-2af6-4c79-bea2-1b6933764f80",
    "885a0392-ef1b-4de3-aacf-af3f1697ce2c",
    "f5a9c0ca-bdbb-490f-8928-2ca95836239a",
    "173a6cee-90d1-40a7-89cf-0329eca780a6",
    "bdab0e47-4e37-4f0b-8fd0-87d95cc4addc",
    "f00c6da4-3679-4b44-b9fb-36a19bd3ae83",
    "0c61e164-6171-4837-8836-8f5298726d53",
  }
  gen_uuid = function()
    return assert(table.remove(uuids))
  end
end

--------------------------------------------------------------------------------
-- Unindent a multi-line string for proper indenting in
-- square brackets.
--
-- Ex:
--   unindent([[
--       hello world
--       foo bar
--   ]])
--
-- will return: "hello world\nfoo bar"
local function unindent(str)
  local min = 2^31
  local lines = {}
  str = (str:sub(-1) == "\n") and str or (str .. "\n")
  for line in str:gmatch("([^\n]*)\n") do
    local nonblank = line:match("()[^%s]")
    if nonblank and nonblank < min then
      min = nonblank
    end
    table.insert(lines, line)
  end
  for i, line in ipairs(lines) do
    lines[i] = line:sub(min)
  end
  return table.concat(lines, "\n")
end

local function each_field(fields)
  local i = 0
  return function()
    i = i + 1
    local f = fields[i]
    if f then
      local k = next(f)
      local v = f[k]
      return k, v
    end
  end
end

--------------------------------------------------------------------------------

local function gen_kind(finfo, field_data)
  if field_data.kind then
    return "<br>*"  .. field_data.kind .. "*"
  elseif finfo.required ~= true then
    return "<br>*optional*"
  else
    return ""
  end
end

local function gen_defaults(finfo)
  if finfo.default then
    return " Defaults to `" .. cjson_encode(finfo.default) .. "`."
  else
    return ""
  end
end

local function gen_notation(fname, finfo, field_data)
  if finfo.type == "array" then
    local form_example = {}
    local example = field_data.examples
                    and (field_data.examples[1] or field_data.examples[2])
                    or field_data.example
    for i, item in ipairs(example or finfo.default) do
      table.insert(form_example, fname .. "[]=" .. item)
      if i == 2 then
        break
      end
    end
    return [[ With form-encoded, the notation is `]] ..
           table.concat(form_example, "&") ..
           [[`. With JSON, use an Array.]]
  elseif finfo.type == "foreign" then
    return [[ With form-encoded, the notation is `]] ..
           fname .. [[.id=<]] .. fname ..
           [[_id>`. With JSON, use `"]] .. fname ..
           [[":{"id":"<]] .. fname .. [[_id>"}`.]]
  else
    return ""
  end
end

local function write_field(outfd, fname, finfo, fullname, field_data, entity_name)
  local kind = gen_kind(finfo, field_data)
  local description = assert(field_data.description,
                             "Missing description for " .. entity_name .. "." .. fullname)
                      :gsub("%s+", " ")
  local defaults = gen_defaults(finfo)
  local notation = gen_notation(fname, finfo, field_data)

  outfd:write("    `" .. fullname .. "`" .. kind .. " | " .. description .. defaults .. notation .. "\n")
end

local function process_field(outfd, entity_data, entity_name, fname, finfo, prefix)
  local fullname = (prefix or "") .. fname
  local field_data = entity_data.fields[fullname]
  if not field_data then
    if finfo.type == "record" then
      for rfname, rfinfo in each_field(finfo.fields) do
        process_field(outfd, entity_data, entity_name, rfname, rfinfo, fullname .. ".")
      end
      return
    else
      error("Missing autodoc data for field " .. entity_name .. "." .. fullname)
    end
  end

  if field_data.skip then
    return
  end

  write_field(outfd, fname, finfo, fullname, field_data, entity_name)
end

local function gen_example(exn, entity, fields, indent, prefix)
  local csv = {}
  for fname, finfo in each_field(fields) do
    local fullname = (prefix or "") .. fname

    local value
    local field_data = data.entities[entity].fields[fullname]
    if finfo.type == "record" and not finfo.abstract then
      value = gen_example(exn, entity, finfo.fields, indent .. "    ", fullname .. ".")
    elseif finfo.default ~= nil and field_data.examples == nil and field_data.example == nil then
      value = cjson_encode(finfo.default)
    else
      local example = field_data.examples and field_data.examples[exn]
      if example == nil then
        example = field_data.example
      end
      if example == nil then
        if finfo.uuid then
          example = gen_uuid()
        elseif finfo.type == "foreign" then
          example = { id = gen_uuid() }
        elseif finfo.timestamp then
          example = 1422386534
        elseif fname == "name" then
          example = "my-" .. to_singular(entity)
        end
      end
      if example ~= nil then
        value = cjson_encode(example)
      elseif not field_data.skip_in_example then
        error("missing example value for " .. entity .. "." .. fname)
      end
    end

    if value ~= nil then
      table.insert(csv, indent .. "    " .. '"' .. fname .. '": ' .. value)
    end
  end
  local out = {"{\n"}
  table.insert(out, table.concat(csv, ",\n"))
  table.insert(out, "\n")
  table.insert(out, indent .. "}")
  return table.concat(out)
end

local function write_entity_templates(outfd, entity)
  local schema = assert(require("kong.db.schema.entities." .. entity))
  local singular = to_singular(entity)

  local entity_data = assert(data.entities[entity],
                             "Missing autodoc entity data for " .. entity)
  assert(entity_data.fields, "Missing autodoc fields entry for " .. entity)

  outfd:write(singular .. "_body: |\n")
  outfd:write("    Attributes | Description\n")
  outfd:write("    ---:| ---\n")
  for fname, finfo in each_field(schema.fields) do
    process_field(outfd, entity_data, entity, fname, finfo)
  end

  if entity_data.extra_fields then
    for efname, efinfo in each_field(entity_data.extra_fields) do
      write_field(outfd, efname, efinfo, efname, efinfo, entity)
    end
  end

  outfd:write("\n")
  outfd:write(singular .. "_json: |\n")
  outfd:write("    " .. gen_example(1, entity, schema.fields, "    ") .. "\n")
  outfd:write("\n")
  outfd:write(singular .. "_data: |\n")
  outfd:write('    "data": [' .. gen_example(1, entity, schema.fields, "    ") .. ", ")
  outfd:write(gen_example(2, entity, schema.fields, "    ") .. "],\n")
  outfd:write("\n")
end


local function bold_text_section(outfd, title, content)
  if not content then
    return
  end
  outfd:write(title and ("*" .. title .. "*\n\n") or "")
  outfd:write(unindent(content) .. "\n")
  outfd:write("\n")
end

local function section(outfd, title, content)
  if not content then
    return
  end
  outfd:write(title and ("#### " .. title .. "\n\n") or "")
  outfd:write(unindent(content) .. "\n")
  outfd:write("\n")
end

local function write_endpoint(outfd, endpoint, ep_data)
  assert(ep_data, "Missing autodoc data for endpoint " .. endpoint)
  if ep_data.done or ep_data.skip then
    return
  end

  for _, method in ipairs(methods) do
    local meth_data = ep_data[method]
    if meth_data then
      assert(meth_data.title, "Missing autodoc info for " .. method .. " " .. endpoint)
      outfd:write("### " .. meth_data.title .. "\n")
      outfd:write("\n")
      section(outfd, nil, meth_data.description)
      local fk_endpoints = meth_data.fk_endpoints or {}
      section(outfd, nil, meth_data.endpoint)
      for _, fk_endpoint in ipairs(fk_endpoints) do
        section(outfd, nil, fk_endpoint)
      end
      bold_text_section(outfd, "Request Querystring Parameters", meth_data.request_query)
      bold_text_section(outfd, "Request Body", meth_data.request_body)
      section(outfd, nil, meth_data.details)
      bold_text_section(outfd, "Response", meth_data.response)
      outfd:write("---\n\n")
    end
  end
  ep_data.done = true
end

local function write_endpoints(outfd, info, all_endpoints)
  for endpoint, ep_data in sortedpairs(info.data) do
    if endpoint:match("^/") then
      write_endpoint(outfd, endpoint, ep_data)
      all_endpoints[endpoint] = ep_data
    end
  end
  return all_endpoints
end



local function write_general_section(outfd, filename, all_endpoints)
  local name = filename:match("/([^/]+)%.lua$")

  local general_data = assert(data.general[name],
                             "Missing autodoc data for " .. filename)

  outfd:write("---\n\n")
  outfd:write("## " .. general_data.title .. "\n")
  outfd:write("\n")

  assert(general_data.description,
         "Missing autodoc general description for " .. filename)

  outfd:write(unindent(general_data.description))
  outfd:write("\n\n")

  local info = {
    filename = filename,
    data = general_data,
    mod = assert(loadfile(KONG_PATH .. "/" .. filename))()
  }
  write_endpoints(outfd, info, all_endpoints)
end

local active_verbs = {
  GET = "retrieve",
  POST = "create",
  PATCH = "update",
  PUT = "create or update",
  DELETE = "delete",
}

local passive_verbs = {
  GET = "retrieved",
  POST = "created",
  PATCH = "updated",
  PUT = "created or updated",
  DELETE = "deleted",
}

local function adjust_for_method(subs, method)
  subs.method = method:lower()
  subs.METHOD = method:upper()
  subs.active_verb = active_verbs[subs.METHOD]
  subs.passive_verb = passive_verbs[subs.METHOD]
  subs.Active_verb = title_case(subs.active_verb)
  subs.Passive_verb = title_case(subs.passive_verb)
end

local gen_endpoint
do
  local template_keys = {
    "title",
    "description",
    "details",
    "request_querystring",
    "request_body",
    "response",
    "endpoint",
  }

  gen_endpoint = function(edata, templates, subs, endpoint, method, has_ek)
    local ep_data = get_or_create(edata, endpoint)
    if ep_data.skip then
      return
    end
    local meth_data = get_or_create(ep_data, method)
    assert(templates, "Missing autodoc templates definition for " .. endpoint)
    local meth_tpls = templates[method]
    assert(meth_tpls, "Missing autodoc templates definition for " .. method .. " " .. endpoint)
    adjust_for_method(subs, method)

    for _, k in ipairs(template_keys) do
      local tk = (k == "endpoint")
                 and (has_ek and "endpoint_w_ek" or "endpoint")
                 or k
      local template = meth_tpls[tk] or templates[tk]
      if meth_data[k] == nil and ep_data[k] ~= nil then
        meth_data[k] = ep_data[k]
      end
      if meth_data[k] == nil and template then
        meth_data[k] = render(template, subs)
      end
    end
  end
end

local function gen_fk_endpoint(edata, templates, subs, parent_endpoint, method, has_ek)
  local ep_data = assert(edata[parent_endpoint],
                         "Expected entity data to exist for endpoint " .. parent_endpoint)
  local meth_data = assert(ep_data[method]) -- get_or_create(ep_data, method)
  assert(templates, "Missing autodoc templates definition for " .. parent_endpoint)
  local meth_tpls = templates[method]
  assert(meth_tpls, "Missing autodoc templates definition for " .. method .. " " .. parent_endpoint)
  local tk = has_ek and "fk_endpoint_w_ek" or "fk_endpoint"
  local tpl = meth_tpls[tk] or templates[tk]
  assert(tpl, "Missing autodoc " .. tk .. " template for " .. method .. " " .. parent_endpoint)
  adjust_for_method(subs, method)

  assert(meth_data.title)
  local fk_endpoints = get_or_create(meth_data, "fk_endpoints")
  table.insert(fk_endpoints, render(tpl, subs))
end

local function gen_template_subs_table(edata, plural, schema, fedata, fplural)
  local singular = to_singular(plural)
  local subs = {
    ["Entity"] = edata.entity_title or title_case(singular),
    ["Entities"] = edata.entity_title_plural or title_case(plural),
    ["entity"] = edata.entity_lower or singular:lower(),
    ["entities"] = edata.entity_lower_plural or plural:lower(),
    ["entities_url"] = edata.entity_url_collection_name or plural,
    ["entity_url"] = edata.entity_url_name or singular,
    ["endpoint_key"] = edata.entity_endpoint_key or schema.endpoint_key or "name",
  }
  if fedata then
    local fsingular = to_singular(fplural)
    subs["ForeignEntity"] = fedata.entity_title or title_case(fsingular)
    subs["ForeignEntities"] = fedata.entity_title_plural or title_case(fplural)
    subs["foreign_entity"] = fedata.entity_lower or fsingular:lower()
    subs["foreign_entities"] = fedata.entity_lower_plural or fplural:lower()
    subs["foreign_entities_url"] = fedata.entity_url_collection_name or fplural
    subs["foreign_entity_url"] = fedata.entity_url_name or fsingular
  end
  return subs
end

local function prepare_entity(plural)
  local out = {}

  local entity_data = assert(data.entities[plural],
                             "Missing autodoc data for " .. plural)
  assert(entity_data.description,
         "Missing autodoc entity description for " .. plural)

  local schema = assert(loadfile(KONG_PATH .. "/" .. entity_to_schema_path(plural)))()
  local subs = gen_template_subs_table(entity_data, plural, schema)

  local title = entity_data.title or (subs.Entity .. " Object")
  table.insert(out, "## " .. title .. "\n")
  table.insert(out, "\n")

  table.insert(out, unindent(entity_data.description))
  table.insert(out, "\n\n")
  table.insert(out, "```json\n")
  table.insert(out, "{{ page." .. subs.entity .. "_json }}\n")
  table.insert(out, "```\n\n")

  if entity_data.details then
    table.insert(out, unindent(entity_data.details))
    table.insert(out, "\n\n")
  end

  local filename = "kong/api/routes/" .. plural .. ".lua"
  local mod = assert(loadfile(KONG_PATH .. "/" .. filename))()

  local collection_endpoint = "/" .. plural
  gen_endpoint(entity_data, data.collection_templates, subs, collection_endpoint, "GET")
  gen_endpoint(entity_data, data.collection_templates, subs, collection_endpoint, "POST")

  local entity_endpoint = "/" .. plural .. "/:" .. plural
  local has_ek = schema.endpoint_key ~= nil
  gen_endpoint(entity_data, data.entity_templates, subs, entity_endpoint, "GET", has_ek)
  gen_endpoint(entity_data, data.entity_templates, subs, entity_endpoint, "PUT", has_ek)
  gen_endpoint(entity_data, data.entity_templates, subs, entity_endpoint, "PATCH", has_ek)
  gen_endpoint(entity_data, data.entity_templates, subs, entity_endpoint, "DELETE", has_ek)

  return {
    filename = filename,
    entity = plural,
    schema = schema,
    intro = table.concat(out),
    data = entity_data,
    mod = mod,
  }
end

local function skip_fk_endpoint(edata, endpoint, method)
  local ret = edata
         and edata[endpoint]
         and ((edata[endpoint].endpoint == false)
              or (edata[endpoint][method] and edata[endpoint][method].endpoint == false))
  return ret
end

local function prepare_foreign_key_endpoints(entity_infos, entity)
  local einfo = entity_infos[entity]
  local edata = einfo.data

  for fname, finfo in each_field(einfo.schema.fields) do
    if finfo.type == "foreign" and not (data.known.nodoc_entities[finfo.reference]) then
      local foreigns = to_plural(fname)
      local feinfo = entity_infos[foreigns]
      local fedata = feinfo.data
      local subs = gen_template_subs_table(einfo.data, entity, einfo.schema, fedata, foreigns)
      local has_ek = einfo.schema.endpoint_key ~= nil

      local function gen_fk_endpoints(parent_endpoint, endpoint, meths, templates, srcdata, dstdata)
        for _, method in ipairs(meths) do
          if not skip_fk_endpoint(edata, endpoint, method) then
            gen_fk_endpoint(dstdata, templates, subs, parent_endpoint, method, has_ek)
            local ep_data = get_or_create(srcdata, endpoint)
            ep_data.done = true
          end
        end
      end

      gen_fk_endpoints(
        "/" .. entity,
        "/" .. foreigns .. "/:" .. foreigns .. "/" .. entity,
        {"GET", "POST"},
        data.collection_templates,
        fedata, edata
      )
      gen_fk_endpoints(
        "/" .. foreigns .. "/:" .. foreigns,
        "/" .. entity .. "/:" .. entity .. "/" .. fname,
        {"GET", "PUT", "PATCH", "DELETE"},
        data.entity_templates,
        edata, fedata
      )
    end
  end

end

--------------------------------------------------------------------------------

-- Check that all modules present in the Admin API are known by this script.
local function check_admin_api_modules()
  local file_set = {}
  for _, item in ipairs(data.known.general_files) do
    file_set[item] = "use"
    data.known.general_files[item] = true
  end
  for _, item in ipairs(data.known.entities) do
    file_set[entity_to_api_path(item)] = "use"
    data.known.entities[item] = true
  end
  for _, item in ipairs(data.known.nodoc_entities) do
    file_set[entity_to_api_path(item)] = "nodoc"
    data.known.nodoc_entities[item] = true
  end
  for _, item in ipairs(data.known.nodoc_files) do
    file_set[item] = "nodoc"
    data.known.nodoc_files[item] = true
  end

  for file in lfs.dir(KONG_PATH .. "/kong/api/routes") do
    if file:match("%.lua$") then
      local name = "kong/api/routes/" .. file
      if not file_set[name] then
        error("File " .. name .. " not known to autodoc-admin-api! "  ..
              "Please add to the data.known tables.")
      end
    end
  end
end

--------------------------------------------------------------------------------

local function main()
  check_admin_api_modules()

  local outpath = "app/" .. KONG_VERSION .. "/admin-api.md"
  local outfd = assert(io.open(outpath, "w+"))

  outfd:write("---\n")
  outfd:write("title: Admin API\n\n")
  for _, entity in ipairs(data.known.entities) do
    write_entity_templates(outfd, entity)
  end
  outfd:write("\n---\n")

  outfd:write(unindent(assert(data.intro, "Missing intro string in data.lua")))

  local all_endpoints = {}

  for _, item in ipairs(data.known.general_files) do
    write_general_section(outfd, item, all_endpoints)
  end

  local entity_infos = {}

  for _, entity in ipairs(data.known.entities) do
    local einfo = prepare_entity(entity)
    table.insert(entity_infos, einfo)
    entity_infos[entity] = einfo
  end

  for _, entity in ipairs(data.known.entities) do
    prepare_foreign_key_endpoints(entity_infos, entity)
  end

  for _, entity_info in ipairs(entity_infos) do
    outfd:write(entity_info.intro)
    write_endpoints(outfd, entity_info, all_endpoints)
  end

  -- Check that all endpoints were traversed
  for _, info in ipairs(entity_infos) do
    for endpoint, handler in pairs(info.mod) do
      if handler ~= Endpoints.not_found then
        assert(all_endpoints[endpoint],
               "Missing autodoc data for implemented endpoint " ..
               endpoint .. " -- did you document it in data.lua?")
        assert(all_endpoints[endpoint].done
               or all_endpoints[endpoint].skip,
               "Expected done mark in autodoc endpoint " .. endpoint)
      end
    end
  end

  outfd:write(unindent(assert(data.footer, "Missing footer string in data.lua")))

  outfd:close()
end

main()
