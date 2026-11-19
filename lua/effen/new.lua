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

--- Adds `decl` to the header `ctx.header_path` (created with a guard when
--- missing) and writes it if it had no unsaved changes.
local function add_to_header(ctx, decl)
  local lang = ctx.lang
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

--- Inserts the declaration of `ctx.proto` (into the header, or as a forward
--- declaration) and appends the definition (to the current file or to
--- `ctx.source_path`). `make_lines(def_buf)` returns the definition lines
--- and the offset of the body line.
---@return integer def_buf, integer start 0-based row of the definition, integer body, integer count
function M.place(ctx, make_lines)
  local buf, lang, flags = ctx.buf, ctx.lang, ctx.flags
  local src_path = util.abspath(api.nvim_buf_get_name(buf))

  local decl = lang.declaration_text(ctx.proto)
  if flags.header then
    add_to_header(ctx, decl)
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

  local lines, body = make_lines(def_buf)
  local start = append(def_buf, lines)
  if def_buf ~= buf then
    util.save(def_buf)
  end
  sync.track(def_buf, start)
  return def_buf, start, body, #lines
end

---@param ctx ff.NewCtx
local function execute(ctx)
  local buf, lang, flags = ctx.buf, ctx.lang, ctx.flags
  local p = lang.parse_proto(ctx.proto)
  if not p then
    return util.err("could not parse prototype: " .. ctx.proto)
  end

  -- the user renamed the function in the prompt: rename the call too
  if p.base ~= ctx.call.name then
    api.nvim_buf_set_text(buf, ctx.call.row, ctx.call.name_col, ctx.call.row, ctx.call.name_end, { p.base })
  end

  if not flags.later then
    marker.set(buf, ctx.cursor[1], ctx.cursor[2])
  end

  local def_buf, start, body = M.place(ctx, function(b)
    return lang.definition_lines(ctx.proto, util.indent_unit(b))
  end)

  if flags.later then
    return util.notify("created " .. p.base)
  end
  local body_line = api.nvim_buf_get_lines(def_buf, start + body, start + body + 1, false)[1] or ""
  ui.open(def_buf, start + body, #body_line, flags.view, p.base)
end

-- From a declaration -----------------------------------------------------------

local ns = api.nvim_create_namespace("effen-new")

--- "file:line" of an existing definition of declaration `d`, if any.
local function existing_definition(buf, lang, d)
  local here = util.abspath(api.nvim_buf_get_name(buf))
  local files = { here }
  if lang.is_header(here) then
    vim.list_extend(files, lang.source_candidates(here))
  end
  for _, path in ipairs(files) do
    for _, def in ipairs(lang.definitions(util.file_lines(path) or {})) do
      if def.proto.base == d.proto.base and lang.same_types(def.proto, d.proto) then
        return util.display_path(path) .. ":" .. (def.srow + 1)
      end
    end
  end
  -- clangd answers goto-definition on a lone declaration with the declaration
  for _, loc in ipairs(lsp.locations(buf, "textDocument/definition", d.name_row, d.name_col)) do
    local same = util.abspath(loc.path) == here and loc.row >= d.srow and loc.row <= d.erow
    if not same then
      return util.display_path(loc.path) .. ":" .. (loc.row + 1)
    end
  end
end

--- Existing same-named source file of a header.
local function paired_source(lang, header)
  for _, p in ipairs(lang.source_candidates(header)) do
    if vim.fn.filereadable(p) == 1 or util.loaded_buf(p) then
      return util.abspath(p)
    end
  end
end

--- Deletes rows/cols of declaration `d` from `buf`, dropping lines it leaves blank.
local function remove_declaration(buf, d)
  local first = api.nvim_buf_get_lines(buf, d.srow, d.srow + 1, false)[1]
  local last = api.nvim_buf_get_lines(buf, d.erow, d.erow + 1, false)[1]
  if util.is_blank(first:sub(1, d.scol)) and util.is_blank(last:sub(d.ecol + 2)) then
    api.nvim_buf_set_lines(buf, d.srow, d.erow + 1, false, {})
  else
    api.nvim_buf_set_text(buf, d.srow, d.scol, d.erow, d.ecol + 1, { "" })
  end
end

local function execute_from_declaration(ctx)
  local buf, lang, flags, d = ctx.buf, ctx.lang, ctx.flags, ctx.decl
  local np = lang.parse_proto(ctx.proto)
  if not np then
    return util.err("could not parse prototype: " .. ctx.proto)
  end
  local here = util.abspath(api.nvim_buf_get_name(buf))
  local in_header = lang.is_header(here)
  local at = api.nvim_buf_set_extmark(buf, ns, ctx.cursor[1], ctx.cursor[2], {})

  -- the declaration: follow edits made in the prompt, move it with `h`
  local decl = table.concat(api.nvim_buf_get_text(buf, d.srow, d.scol, d.erow, d.ecol + 1, {}), "\n")
  local changed = lang.normalize_type(ctx.proto) ~= lang.normalize_type(ctx.default_proto)
  if changed then
    decl = lang.declaration_from_definition(np, d.proto)
  end
  local header = in_header and here or nil
  if flags.header and not in_header then
    remove_declaration(buf, d)
    add_to_header(ctx, decl)
    lang.ensure_include(buf, ctx.header_path)
    header = ctx.header_path
  elseif changed then
    api.nvim_buf_set_text(buf, d.srow, d.scol, d.erow, d.ecol + 1, { decl })
  end

  -- the definition: this file, or the header's source file, or a new file
  local def_buf = buf
  if ctx.source_path then
    local created
    def_buf, created = util.ensure_buffer(ctx.source_path)
    if created then
      api.nvim_buf_set_lines(def_buf, 0, -1, false, { "" })
    end
    if header then
      lang.ensure_include(def_buf, header)
    else
      sync.register(ctx.source_path, here)
    end
  end
  local lines, body = lang.definition_lines(ctx.proto, util.indent_unit(def_buf))
  local start = append(def_buf, lines)
  if def_buf ~= buf then
    util.save(def_buf)
  end
  sync.track(def_buf, start)

  local m = api.nvim_buf_get_extmark_by_id(buf, ns, at, {})
  api.nvim_buf_del_extmark(buf, ns, at)
  if flags.later then
    return util.notify("created the definition of " .. np.base)
  end
  marker.set(buf, m[1], m[2])
  local body_line = api.nvim_buf_get_lines(def_buf, start + body, start + body + 1, false)[1] or ""
  ui.open(def_buf, start + body, #body_line, flags.view, np.base)
end

local function prompt_from_declaration(ctx, opts)
  local lang, flags, d = ctx.lang, ctx.flags, ctx.decl
  local here = util.abspath(api.nvim_buf_get_name(ctx.buf))
  ctx.default_proto = lang.definition_proto(d.proto)
  if flags.header and lang.is_header(here) then
    util.notify("the declaration is already in a header; ignoring `h`")
    flags.header = false
  end

  local steps = {}
  steps[#steps + 1] = function(next)
    if opts.prototype or opts.confirm == false then
      ctx.proto = opts.prototype or ctx.default_proto
      return next()
    end
    ui.input({
      title = flags.modifiers and "Definition (add modifiers)" or "Definition",
      default = ctx.default_proto,
      cursor = flags.modifiers and "start" or "end",
      placeholder = config().unknown_type,
    }, function(v)
      if v then
        ctx.proto = vim.trim(v):gsub("[;{]%s*$", "")
        next()
      end
    end)
  end
  M.path_steps(ctx, opts, steps)
  if flags.action == "append" and lang.is_header(here) then
    -- a definition belongs in the header's source file
    steps[#steps + 1] = function(next)
      local paired = opts.source and util.abspath(opts.source) or paired_source(lang, here)
      if paired then
        ctx.source_path = paired
        return next()
      end
      local default = lang.source_candidates(here)[1]
      ui.input({ title = "Source file", default = util.display_path(default) }, function(v)
        if v then
          ctx.source_path = util.abspath(vim.fn.expand(v))
          next()
        end
      end)
    end
  end
  M.run_steps(steps, function()
    execute_from_declaration(ctx)
  end)
end

--- Appends the header / new source file prompts that `ctx.flags` require.
function M.path_steps(ctx, opts, steps)
  local lang, flags = ctx.lang, ctx.flags
  local src = api.nvim_buf_get_name(ctx.buf)
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
      local fallback = ctx.call and ctx.call.name or ctx.decl.proto.base
      local default = opts.source or lang.default_source(src, p and p.base or fallback)
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
  return steps
end

--- Runs `steps` (each `fn(next)`, possibly async) in order, then `final()`.
function M.run_steps(steps, final)
  local function run(i)
    if i > #steps then
      local ok, err = xpcall(final, debug.traceback)
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

--- Prompts for the remaining inputs then executes.
---@param ctx ff.NewCtx
---@param opts table
local function prompt_and_execute(ctx, opts)
  local lang, flags = ctx.lang, ctx.flags

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
  M.path_steps(ctx, opts, steps)
  M.run_steps(steps, function()
    execute(ctx)
  end)
end

--- Entry point. On a function declaration, creates its definition; on a call
--- of an undeclared function, deduces the prototype and creates both.
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

  local decl = lang.declaration_at and lang.declaration_at(buf, row, col)
  if decl then
    local defined = existing_definition(buf, lang, decl)
    if defined then
      return util.warn("`" .. decl.proto.base .. "` is already defined at " .. defined)
    end
    local ctx = { buf = buf, lang = lang, decl = decl, cursor = { row, col } }
    if opts.keys then
      ctx.flags = ui.parse_keys(opts.keys)
      return prompt_from_declaration(ctx, opts)
    end
    return ui.pick_flags(function(flags)
      if flags then
        ctx.flags = flags
        prompt_from_declaration(ctx, opts)
      end
    end, "effen: define " .. decl.proto.base)
  end

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
