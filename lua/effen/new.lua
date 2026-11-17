-- `new`: create a function from an undeclared call under the cursor.
local M = {}

local api = vim.api
local util = require("effen.util")
local ui = require("effen.ui")
local lsp = require("effen.lsp")
local langs = require("effen.lang")
local marker = require("effen.marker")
local sync = require("effen.sync")

local function config()
  return require("effen.config").get()
end

--- Returns "file:line" of an existing declaration of the call's function.
local function existing_declaration(buf, call)
  local here = util.abspath(api.nvim_buf_get_name(buf))
  for _, loc in ipairs(lsp.declarations(buf, call.row, call.name_col)) do
    if not (util.abspath(loc.path) == here and loc.row == call.row) then
      return util.display_path(loc.path) .. ":" .. (loc.row + 1)
    end
  end
end

--- Appends `lines` to `buf` separated by a blank line; returns the 0-based
--- row of the first appended line.
local function append(buf, lines)
  local all = api.nvim_buf_get_lines(buf, 0, -1, false)
  if #all == 1 and all[1] == "" then
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return 0
  end
  local last = #all
  while last > 0 and util.is_blank(all[last]) do
    last = last - 1
  end
  local ins = vim.list_extend({ "" }, lines)
  if last == 0 then
    ins = lines
  end
  api.nvim_buf_set_lines(buf, last, -1, false, ins)
  return last + #ins - #lines
end

---@class ff.NewCtx
---@field buf integer
---@field lang table
---@field call table
---@field cursor integer[] 0-based row, col
---@field flags table
---@field proto string
---@field header_path string|nil
---@field source_path string|nil

---@param ctx ff.NewCtx
local function execute(ctx)
  local buf, lang, flags = ctx.buf, ctx.lang, ctx.flags
  local p = lang.parse_proto(ctx.proto)
  if not p then
    return util.err("could not parse prototype: " .. ctx.proto)
  end
  local src_path = util.abspath(api.nvim_buf_get_name(buf))

  -- the user renamed the function in the prompt: rename the call too
  if p.base ~= ctx.call.name then
    api.nvim_buf_set_text(buf, ctx.call.row, ctx.call.name_col, ctx.call.row, ctx.call.name_end, { p.base })
  end

  if not flags.later then
    marker.set(buf, ctx.cursor[1], ctx.cursor[2])
  end

  local decl = lang.declaration_text(ctx.proto)
  if flags.header then
    local hbuf, created = util.ensure_buffer(ctx.header_path)
    local was_modified = vim.bo[hbuf].modified
    if created or util.is_blank(table.concat(api.nvim_buf_get_lines(hbuf, 0, -1, false))) then
      api.nvim_buf_set_lines(hbuf, 0, -1, false, lang.new_header_lines(ctx.header_path))
    end
    lang.insert_declaration(hbuf, decl)
    if was_modified then
      util.warn(util.display_path(ctx.header_path) .. " has unsaved changes; not writing it")
    else
      util.save(hbuf)
    end
    lang.ensure_include(buf, ctx.header_path)
  else
    lang.insert_forward_declaration(buf, decl)
  end

  local def_buf
  if flags.action == "new" then
    local created
    def_buf, created = util.ensure_buffer(ctx.source_path)
    if created and flags.header then
      api.nvim_buf_set_lines(def_buf, 0, -1, false, { "" })
    end
    if flags.header then
      lang.ensure_include(def_buf, ctx.header_path)
    else
      sync.register(ctx.source_path, src_path)
    end
  else
    def_buf = buf
  end

  local lines, body = lang.definition_lines(ctx.proto, util.indent_unit(def_buf))
  local start = append(def_buf, lines)
  if def_buf ~= buf then
    util.save(def_buf)
  end
  sync.track(def_buf, start)

  if flags.later then
    return util.notify("created " .. p.base)
  end
  local body_line = api.nvim_buf_get_lines(def_buf, start + body, start + body + 1, false)[1] or ""
  ui.open(def_buf, start + body, #body_line, flags.view, p.base)
end

--- Prompts for the remaining inputs then executes.
---@param ctx ff.NewCtx
---@param opts table
local function prompt_and_execute(ctx, opts)
  local lang, flags = ctx.lang, ctx.flags
  local src = api.nvim_buf_get_name(ctx.buf)

  local steps = {}
  steps[#steps + 1] = function(next)
    if opts.prototype then
      ctx.proto = opts.prototype
      return next()
    end
    local hover = function(row, col)
      return lsp.hover(ctx.buf, row, col)
    end
    local sig = lang.deduce_signature(ctx.buf, ctx.call, hover)
    if opts.confirm == false then
      ctx.proto = lang.format_prototype(sig)
      return next()
    end
    ui.input({
      title = flags.modifiers and "Prototype (add modifiers)" or "Prototype",
      default = lang.format_prototype(sig),
      cursor = flags.modifiers and "start" or "end",
      placeholder = config().unknown_type,
    }, function(v)
      if v then
        ctx.proto = vim.trim(v):gsub(";%s*$", "")
        next()
      end
    end)
  end
  if flags.header then
    steps[#steps + 1] = function(next)
      local default = opts.header or lang.default_header(src)
      if opts.header then
        ctx.header_path = util.abspath(default)
        return next()
      end
      ui.input({ title = "Header file", default = util.display_path(default) }, function(v)
        if v then
          ctx.header_path = util.abspath(vim.fn.expand(v))
          next()
        end
      end)
    end
  end
  if flags.action == "new" then
    steps[#steps + 1] = function(next)
      local p = ctx.proto and lang.parse_proto(ctx.proto)
      local default = opts.source or lang.default_source(src, p and p.base or ctx.call.name)
      if opts.source then
        ctx.source_path = util.abspath(default)
        return next()
      end
      ui.input({ title = "New source file", default = util.display_path(default) }, function(v)
        if v then
          ctx.source_path = util.abspath(vim.fn.expand(v))
          next()
        end
      end)
    end
  end

  local function run(i)
    if i > #steps then
      local ok, err = pcall(execute, ctx)
      if not ok then
        util.err(tostring(err))
      end
      return
    end
    steps[i](function()
      run(i + 1)
    end)
  end
  run(1)
end

--- Entry point.
---@param opts? { keys?: string, prototype?: string, confirm?: boolean, header?: string, source?: string }
--- `keys`: option keys (skips the picker); `prototype`: use instead of deducing;
--- `confirm = false`: accept the deduced prototype; `header`/`source`: paths
--- (skip those prompts).
function M.run(opts)
  opts = opts or {}
  local buf = api.nvim_get_current_buf()
  local lang = langs.get(buf)
  if not lang then
    return util.warn("filetype '" .. vim.bo[buf].filetype .. "' is not supported")
  end
  local cursor = api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local call, err = lang.parse_call(buf, row, col)
  if not call then
    return util.warn(err)
  end
  local existing = existing_declaration(buf, call)
  if existing then
    return util.warn("`" .. call.name .. "` is already declared at " .. existing)
  end

  local ctx = { buf = buf, lang = lang, call = call, cursor = { row, col } }
  if opts.keys then
    ctx.flags = ui.parse_keys(opts.keys)
    return prompt_and_execute(ctx, opts)
  end
  ui.pick_flags(function(flags)
    if flags then
      ctx.flags = flags
      prompt_and_execute(ctx, opts)
    end
  end)
end

return M
