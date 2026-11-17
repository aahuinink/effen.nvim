-- Keeps declarations in sync with definitions.
--
-- Every definition in a tracked buffer gets an extmark at the start of its
-- signature together with the signature it had at the last snapshot (buffer
-- load / last write). When the signature under an extmark changed, the
-- declaration that matched the *old* signature is rewritten. Using the old
-- signature makes renames and C++ overloads work.
local M = {}

local api = vim.api
local util = require("effen.util")
local langs = require("effen.lang")

local ns = api.nvim_create_namespace("effen-sync")
local snaps = {} ---@type table<integer, table<integer, table>>
local extra_decl_files = {} ---@type table<string, table<string, boolean>>

local function entry(lang, d)
  return {
    proto = d.proto,
    norm = lang.normalize_type(d.text),
  }
end

local function buf_lines(buf)
  return api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- Remembers that declarations for functions defined in `def_path` may live
--- in `decl_path` (used when a definition goes to a new file without header).
function M.register(def_path, decl_path)
  def_path, decl_path = util.abspath(def_path), util.abspath(decl_path)
  extra_decl_files[def_path] = extra_decl_files[def_path] or {}
  extra_decl_files[def_path][decl_path] = true
end

--- Snapshots every definition in `buf`.
function M.take(buf)
  local lang = langs.get(buf)
  if not lang or not api.nvim_buf_is_loaded(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local snap = {}
  for _, d in ipairs(lang.definitions(buf_lines(buf))) do
    local id = api.nvim_buf_set_extmark(buf, ns, d.srow, d.scol, {})
    snap[id] = entry(lang, d)
  end
  snaps[buf] = snap
end

local function def_at_row(lang, buf, row)
  for _, d in ipairs(lang.definitions(buf_lines(buf))) do
    if d.srow <= row and (d.body_end_row or d.erow) >= row then
      return d
    end
  end
end

--- Snapshots just the definition containing `row` (leaves other pending
--- changes in the buffer alone).
function M.track(buf, row)
  local lang = langs.get(buf)
  local d = lang and def_at_row(lang, buf, row)
  if not d then
    return
  end
  snaps[buf] = snaps[buf] or {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, { d.srow, 0 }, { d.erow, d.ecol }, {})) do
    snaps[buf][m[1]] = nil
    api.nvim_buf_del_extmark(buf, ns, m[1])
  end
  local id = api.nvim_buf_set_extmark(buf, ns, d.srow, d.scol, {})
  snaps[buf][id] = entry(lang, d)
end

--- The snapshot entry belonging to definition `d`, if any.
local function old_entry(buf, d)
  local snap = snaps[buf]
  if not snap then
    return nil
  end
  local marks = api.nvim_buf_get_extmarks(buf, ns, { d.srow, 0 }, { d.erow, d.ecol }, {})
  local found
  for _, m in ipairs(marks) do
    local e = snap[m[1]]
    if e then
      if e.proto.base == d.proto.base then
        return e, m[1]
      end
      found = found or e
    end
  end
  return found
end

--- Files that may contain declarations for definitions in `buf`.
local function candidate_files(lang, buf)
  local path = util.abspath(api.nvim_buf_get_name(buf))
  local dir = vim.fs.dirname(path)
  local seen, out = {}, {}
  local function add(p)
    p = util.abspath(p)
    if not seen[p] and (vim.fn.filereadable(p) == 1 or util.loaded_buf(p)) then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  add(path)
  for _, p in ipairs(lang.includes(buf_lines(buf), dir)) do
    add(p)
  end
  for _, p in ipairs(lang.header_candidates(path)) do
    add(p)
  end
  for p in pairs(extra_decl_files[path] or {}) do
    add(p)
  end
  return out
end

local function replace_decl(path, decl, text, current_buf)
  local b = util.loaded_buf(path)
  local was_modified = b and vim.bo[b].modified
  if not b then
    b = util.ensure_buffer(path)
  end
  api.nvim_buf_set_text(b, decl.srow, decl.scol, decl.erow, decl.ecol + 1, { text })
  if b == current_buf then
    return
  end
  if was_modified then
    util.warn(util.display_path(path) .. " had unsaved changes; updated declaration left unsaved")
  else
    util.save(b)
  end
end

--- Updates the declaration(s) of definition `d` in `buf`. `old` is the
--- snapshot entry of its previous signature (or nil to match by name).
---@return boolean changed
function M.apply(buf, lang, d, old, quiet)
  old = old and old.proto or d.proto
  local files = candidate_files(lang, buf)
  local exact, best, best_score = {}, nil, -1
  for _, path in ipairs(files) do
    local lines = util.file_lines(path) or {}
    for _, decl in ipairs(lang.declarations(lines)) do
      local p = decl.proto
      if p.base == d.proto.base and lang.same_types(p, d.proto) then
        local now = lang.declaration_from_definition(d.proto, p)
        if lang.normalize_type(now) == lang.normalize_type(decl.text .. ";") then
          if not quiet then
            util.notify("declaration already up to date")
          end
          return false
        end
      end
      if p.base == old.base then
        if lang.same_types(p, old) then
          exact[#exact + 1] = { path = path, decl = decl }
        else
          local score = #p.params == #old.params and 1 or 0
          if score > best_score then
            best, best_score = { path = path, decl = decl }, score
          end
        end
      end
    end
  end
  local targets = #exact > 0 and exact or (best and { best }) or {}
  if #targets == 0 then
    if not quiet then
      util.warn("no declaration of `" .. old.base .. "` found")
    end
    return false
  end
  -- edit bottom-up per file so earlier positions stay valid
  table.sort(targets, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.decl.srow > b.decl.srow
  end)
  for _, t in ipairs(targets) do
    local text = lang.declaration_from_definition(d.proto, t.decl.proto)
    replace_decl(t.path, t.decl, text, buf)
    util.notify("updated declaration in " .. util.display_path(t.path) .. ": " .. text)
  end
  return true
end

--- `update` keymap: sync the declaration of the definition under the cursor.
function M.update_at_cursor()
  local buf = api.nvim_get_current_buf()
  local lang = langs.get(buf)
  if not lang then
    return
  end
  local row = api.nvim_win_get_cursor(0)[1] - 1
  local d = def_at_row(lang, buf, row)
  if not d then
    return util.notify("not inside a function definition")
  end
  M.apply(buf, lang, d, old_entry(buf, d), false)
  M.track(buf, d.srow)
end

--- BufWritePre: sync every definition whose signature changed since the last
--- snapshot.
function M.on_write(buf)
  local lang = langs.get(buf)
  if not lang or not snaps[buf] then
    return
  end
  local changed = {}
  for _, d in ipairs(lang.definitions(buf_lines(buf))) do
    local old = old_entry(buf, d)
    if old and old.norm ~= lang.normalize_type(d.text) then
      changed[#changed + 1] = { d = d, old = old }
    end
  end
  -- apply bottom-up so declarations in this buffer don't shift later defs
  for i = #changed, 1, -1 do
    local ok, err = pcall(M.apply, buf, lang, changed[i].d, changed[i].old, true)
    if not ok then
      util.err("declaration sync failed: " .. tostring(err))
    end
  end
end

function M.forget(buf)
  snaps[buf] = nil
end

return M
