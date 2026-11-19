-- `wrap`: move the selected code into a new function (extract function), then
-- optionally replace copies of that code in the file or the whole project.
local M = {}

local api = vim.api
local util = require("effen.util")
local ui = require("effen.ui")
local lsp = require("effen.lsp")
local langs = require("effen.lang")
local marker = require("effen.marker")
local sync = require("effen.sync")
local new = require("effen.new")

local ns = api.nvim_create_namespace("effen-wrap")

local function config()
  return require("effen.config").get()
end

--- Region of the last visual selection in `buf`.
local function visual_region(buf)
  local mode = vim.fn.visualmode()
  local s = api.nvim_buf_get_mark(buf, "<")
  local e = api.nvim_buf_get_mark(buf, ">")
  if s[1] == 0 or e[1] == 0 then
    return nil, "select the code to wrap first"
  end
  if mode == "\22" then
    return nil, "blockwise selections are not supported"
  end
  local srow, erow = s[1] - 1, e[1] - 1
  local eline = api.nvim_buf_get_lines(buf, erow, erow + 1, false)[1] or ""
  if mode == "V" then
    return { srow = srow, scol = 0, erow = erow, ecol = #eline, linewise = true }
  end
  local ecol = math.min(e[2], #eline)
  if ecol < #eline then
    ecol = ecol + 1 + vim.str_utf_end(eline, ecol + 1) -- include the last character
  end
  return { srow = srow, scol = s[2], erow = erow, ecol = ecol }
end

--- Region for a `:[range]EffenWrap` command: the visual selection when the
--- range is the one `:'<,'>` gives, otherwise whole lines.
function M.command_region(buf, line1, line2)
  local s, e = api.nvim_buf_get_mark(buf, "<"), api.nvim_buf_get_mark(buf, ">")
  if s[1] == line1 and e[1] == line2 then
    return visual_region(buf)
  end
  local last = api.nvim_buf_get_lines(buf, line2 - 1, line2, false)[1] or ""
  return { srow = line1 - 1, scol = 0, erow = line2 - 1, ecol = #last, linewise = true }
end

--- Files of the project containing `path` with one of `exts`.
local function project_files(path, exts)
  local want = {}
  for _, e in ipairs(exts) do
    want[e] = true
  end
  local files = {}
  local root = vim.fs.root(path, { ".git" })
  if root and vim.fn.executable("git") == 1 then
    local r = vim.system({ "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard" }, { text = true })
      :wait()
    if r.code == 0 then
      for _, f in ipairs(vim.split(r.stdout, "\n", { trimempty = true })) do
        files[#files + 1] = vim.fs.joinpath(root, f)
      end
    else
      root = nil
    end
  else
    root = nil
  end
  if not root then
    root = vim.fs.root(path, { "compile_commands.json", "CMakeLists.txt", "Makefile", "meson.build" })
      or vim.fn.getcwd()
    for name, kind in
      vim.fs.dir(root, {
        depth = 20,
        skip = function(dir)
          return not dir:match("^%.") and dir ~= "build" and dir ~= "node_modules"
        end,
      })
    do
      if kind == "file" then
        files[#files + 1] = vim.fs.joinpath(root, name)
      end
    end
  end
  local out = {}
  for _, f in ipairs(files) do
    if want[vim.fn.fnamemodify(f, ":e")] and vim.fn.getfsize(f) < 2 * 1024 * 1024 then
      out[#out + 1] = util.abspath(f)
    end
  end
  return out
end

--- Replaces `hits` in `b` (bottom-up). Returns extmark ids at each copy.
local function apply(b, hits)
  table.sort(hits, function(x, y)
    return x.srow > y.srow or (x.srow == y.srow and x.scol > y.scol)
  end)
  local marks = {}
  for _, h in ipairs(hits) do
    local before = (api.nvim_buf_get_lines(b, h.srow, h.srow + 1, false)[1] or ""):sub(1, h.scol)
    local after = (api.nvim_buf_get_lines(b, h.erow, h.erow + 1, false)[1] or ""):sub(h.ecol + 1)
    if #h.lines > 1 and util.is_blank(before) and util.is_blank(after) then
      local ls = {}
      for i, s in ipairs(h.lines) do
        ls[i] = before .. s
      end
      api.nvim_buf_set_lines(b, h.srow, h.erow + 1, false, ls)
    else
      api.nvim_buf_set_text(b, h.srow, h.scol, h.erow, h.ecol, { table.concat(h.lines, " ") })
    end
    marks[#marks + 1] = api.nvim_buf_set_extmark(b, ns, h.srow, h.scol, {})
  end
  return marks
end

--- Replaces copies of the wrapped code. Returns quickfix items.
local function replace_copies(ctx, bld, scope, def)
  local buf, lang, flags = ctx.buf, ctx.lang, ctx.flags
  local here = util.abspath(api.nvim_buf_get_name(buf))
  local function exclude_for(path)
    if util.abspath(path) == def.path then
      return { def.srow, def.erow }
    end
  end

  local touched = {} ---@type { buf: integer, marks: integer[] }[]
  local hits = lang.wrap_find(api.nvim_buf_get_lines(buf, 0, -1, false), ctx.an, bld, exclude_for(here))
  if #hits > 0 then
    touched[#touched + 1] = { buf = buf, marks = apply(buf, hits) }
  end

  if scope == "project" then
    local static = bld.proto.prefix:match("%f[%w_]static%f[^%w_]")
    local decl = lang.declaration_text(ctx.proto)
    local skipped = 0
    for _, path in ipairs(project_files(here, lang.extensions())) do
      if path ~= here then
        local lines = util.file_lines(path) or {}
        local fh = lang.wrap_find(lines, ctx.an, bld, exclude_for(path))
        if #fh > 0 and static and path ~= def.path then
          skipped = skipped + #fh
        elseif #fh > 0 then
          local was_loaded = util.loaded_buf(path) ~= nil
          local b = util.ensure_buffer(path)
          local was_modified = was_loaded and vim.bo[b].modified
          local marks = apply(b, fh)
          if flags.header then
            if path ~= ctx.header_path then
              lang.ensure_include(b, ctx.header_path)
            end
          else -- also in a new definition file: copies sit above the definition
            lang.insert_forward_declaration(b, decl)
            sync.register(def.path, path)
          end
          if was_modified then
            util.warn(util.display_path(path) .. " had unsaved changes; replacements left unsaved")
          else
            util.save(b)
          end
          touched[#touched + 1] = { buf = b, marks = marks }
        end
      end
    end
    if skipped > 0 then
      util.warn(("%s is static: left %d copies in other files alone"):format(bld.proto.base, skipped))
    end
  end

  local items = {}
  for _, t in ipairs(touched) do
    for _, id in ipairs(t.marks) do
      local m = api.nvim_buf_get_extmark_by_id(t.buf, ns, id, {})
      if m[1] then
        items[#items + 1] = {
          bufnr = t.buf,
          lnum = m[1] + 1,
          col = m[2] + 1,
          text = vim.trim(api.nvim_buf_get_lines(t.buf, m[1], m[1] + 1, false)[1] or ""),
        }
      end
      api.nvim_buf_del_extmark(t.buf, ns, id)
    end
  end
  table.sort(items, function(a, b)
    if a.bufnr ~= b.bufnr then
      return a.bufnr < b.bufnr
    end
    return a.lnum < b.lnum
  end)
  return items
end

local function execute(ctx, opts)
  local buf, lang, flags, an, r = ctx.buf, ctx.lang, ctx.flags, ctx.an, ctx.region
  local bld, err = lang.wrap_build(an, ctx.proto, util.indent_unit(buf))
  if not bld then
    return util.err(err)
  end
  local name = bld.proto.base

  -- 1. the selection becomes the call
  local call_col = r.scol
  if an.mode == "stmt" and r.linewise then
    local indent = (api.nvim_buf_get_lines(buf, r.srow, r.srow + 1, false)[1] or ""):match("^%s*")
    local ls = {}
    for i, s in ipairs(bld.replacement) do
      ls[i] = indent .. s
    end
    api.nvim_buf_set_lines(buf, r.srow, r.erow + 1, false, ls)
    call_col = #indent
  else
    api.nvim_buf_set_text(buf, r.srow, r.scol, r.erow, r.ecol, { table.concat(bld.replacement, " ") })
  end
  if not flags.later then
    marker.set(buf, r.srow, call_col)
  end

  -- 2. declaration + definition
  local def_buf, start, body, count = new.place(ctx, function()
    return lang.definition_lines(ctx.proto, nil, bld.body)
  end)
  local body_mark = api.nvim_buf_set_extmark(def_buf, ns, start + body, 0, {})
  for _, w in ipairs(an.warnings) do
    util.warn(w)
  end

  -- 3. copies
  local function finish(scope)
    local def = {
      path = util.abspath(api.nvim_buf_get_name(def_buf)),
      srow = start,
      erow = start + count - 1,
    }
    local items = scope and replace_copies(ctx, bld, scope, def) or {}
    local pos = api.nvim_buf_get_extmark_by_id(def_buf, ns, body_mark, {})
    api.nvim_buf_del_extmark(def_buf, ns, body_mark)
    local msg = "wrapped into " .. name
    if #items > 0 then
      vim.fn.setqflist({}, " ", { title = "effen: copies replaced by " .. name, items = items })
      msg = msg .. ("; replaced %d %s (:copen to review)"):format(#items, #items == 1 and "copy" or "copies")
    elseif scope then
      msg = msg .. "; no copies found"
    end
    util.notify(msg)
    if not flags.later and pos[1] then
      local line = api.nvim_buf_get_lines(def_buf, pos[1], pos[1] + 1, false)[1] or ""
      ui.open(def_buf, pos[1], #line:match("^%s*"), flags.view, name)
    end
  end

  if opts.replace ~= nil then
    return finish(opts.replace ~= "none" and opts.replace or nil)
  end
  local in_file = #lang.wrap_find(api.nvim_buf_get_lines(buf, 0, -1, false), an, bld, (def_buf == buf) and {
    start,
    start + count - 1,
  } or nil)
  ui.pick_scope("effen: copies of " .. name, in_file, finish)
end

--- Entry point.
---@param opts? { region?: table, keys?: string, prototype?: string, header?: string, source?: string, replace?: "file"|"project"|"none" }
--- `region`: { srow, scol, erow, ecol, linewise } (0-based, ecol exclusive;
--- default: the last visual selection); `keys`: option keys (skips the
--- picker); `prototype`: skips the prototype prompt; `header`/`source`:
--- paths; `replace`: skips the "replace copies" prompt.
function M.run(opts)
  opts = opts or {}
  local buf = api.nvim_get_current_buf()
  local lang = langs.get(buf)
  if not lang or not lang.wrap_analyze then
    return util.warn("filetype '" .. vim.bo[buf].filetype .. "' is not supported")
  end
  local r, err = opts.region, nil
  if not r then
    r, err = visual_region(buf)
    if not r then
      return util.warn(err)
    end
  end

  local env = {}
  if lsp.has_hover(buf) then
    env.hover = function(row, col)
      return lsp.hover(buf, row, col)
    end
  end
  if #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/definition" }) > 0 then
    env.locate = function(row, col)
      return lsp.locations(buf, "textDocument/definition", row, col)
    end
  end
  local an
  an, err = lang.wrap_analyze(buf, r, env)
  if not an then
    return util.warn(err)
  end

  local default_name = config().wrap_name
  local ctx = { buf = buf, lang = lang, an = an, region = r, call = { name = default_name } }

  local function prompt()
    local steps = {}
    steps[#steps + 1] = function(next)
      if opts.prototype then
        ctx.proto = opts.prototype
        return next()
      end
      local default = lang.format_prototype(lang.wrap_signature(an, default_name))
      ui.input({
        title = ctx.flags.modifiers and "Wrap: prototype (add modifiers)" or "Wrap: prototype",
        default = default,
        cursor = ctx.flags.modifiers and "start" or nil,
        placeholder = config().unknown_type,
        select = default_name,
      }, function(v)
        if v then
          ctx.proto = vim.trim(v):gsub(";%s*$", "")
          next()
        end
      end)
    end
    new.path_steps(ctx, opts, steps)
    new.run_steps(steps, function()
      execute(ctx, opts)
    end)
  end

  if opts.keys then
    ctx.flags = ui.parse_keys(opts.keys)
    return prompt()
  end
  ui.pick_flags(function(flags)
    if flags then
      ctx.flags = flags
      prompt()
    end
  end, "effen: wrap")
end

return M
