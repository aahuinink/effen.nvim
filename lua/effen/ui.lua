-- Floating prompts: a rename-style one-line input and the `new` option picker.
local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("effen-ui")

local function border()
  return require("effen.config").get().border
end

--- Rename-style floating input.
--- `select`: text to select initially (e.g. a default name, typing replaces
--- it); otherwise the first `placeholder` is selected. <Tab> jumps between
--- placeholders.
---@param opts { title: string, default?: string, cursor?: "start"|"end", placeholder?: string, select?: string }
---@param on_done fun(value: string|nil)
function M.input(opts, on_done)
  local default = opts.default or ""
  local title = " " .. opts.title .. " "
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, { default })

  local function width_for(text)
    return math.max(math.min(math.max(#text + 4, #title + 2, 40), vim.o.columns - 6), 1)
  end

  local win = api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width_for(default),
    height = 1,
    style = "minimal",
    border = border(),
    title = title,
    title_pos = "left",
  })
  vim.wo[win].wrap = false
  vim.wo[win].sidescrolloff = 4

  local done = false
  local function finish(value)
    if done then
      return
    end
    done = true
    vim.cmd("stopinsert")
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
    vim.schedule(function()
      if value ~= nil and vim.trim(value) == "" then
        value = nil
      end
      on_done(value)
    end)
  end

  local function confirm()
    finish(api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end

  local map = function(modes, lhs, rhs, extra)
    vim.keymap.set(modes, lhs, rhs, vim.tbl_extend("force", { buffer = buf, nowait = true }, extra or {}))
  end
  map({ "i", "n", "s" }, "<CR>", confirm)
  map("n", "<Esc>", function()
    finish(nil)
  end)
  map("n", "q", function()
    finish(nil)
  end)
  map({ "i", "s" }, "<C-c>", function()
    finish(nil)
  end)

  local ph = opts.placeholder
  local function select_keys(col1, len)
    -- selects `len` bytes starting at the 1-based column `col1`
    len = len or #ph
    local keys = "<Esc><Cmd>call cursor(1," .. col1 .. ")<CR>v"
    if len > 1 then
      keys = keys .. (len - 1) .. "l"
    end
    return keys .. "<C-g>"
  end
  if ph and ph ~= "" then
    map({ "i", "s", "n" }, "<Tab>", function()
      local line = api.nvim_get_current_line()
      local cur = api.nvim_win_get_cursor(0)[2]
      local s = line:find(ph, cur + 2, true) or line:find(ph, 1, true)
      if not s then
        return ""
      end
      return select_keys(s)
    end, { expr = true })
  end

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_set_width(win, width_for(api.nvim_buf_get_lines(buf, 0, 1, false)[1]))
      end
    end,
  })
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      finish(nil)
    end,
  })

  local first, len = ph and ph ~= "" and default:find(ph, 1, true), nil
  if opts.select and opts.select ~= "" then
    local s = default:find(opts.select, 1, true)
    if s then
      first, len = s, #opts.select
    end
  end
  if opts.cursor == "start" then
    api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("startinsert")
  elseif first then
    api.nvim_win_set_cursor(win, { 1, first - 1 })
    local keys = select_keys(first, len):gsub("^<Esc>", "")
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "n", false)
  else
    vim.cmd("startinsert!")
  end
end

-- Option picker ---------------------------------------------------------------

local VIEWS = { ["|"] = "vsplit", ["_"] = "split", f = "float" }

--- Applies option keys (e.g. "mh|") to a flags table. Returns the action
--- ("append"/"new") if one of the keys was an action key.
function M.apply_key(flags, key)
  if key == "m" then
    flags.modifiers = not flags.modifiers
  elseif VIEWS[key] then
    flags.view = flags.view ~= VIEWS[key] and VIEWS[key] or nil
  elseif key == "h" then
    flags.header = not flags.header
  elseif key == "l" then
    flags.later = not flags.later
  elseif key == "a" or key == "\r" then
    return "append"
  elseif key == "n" then
    return "new"
  end
end

--- Parses a key string like "h|a" into flags (non-interactive use).
function M.parse_keys(keys)
  local flags = { action = "append" }
  for key in keys:gmatch(".") do
    local action = M.apply_key(flags, key)
    if action then
      flags.action = action
    end
  end
  return flags
end

local function picker_lines(flags)
  local function box(on)
    return on and "[x]" or "[ ]"
  end
  return {
    " " .. box(flags.modifiers) .. " m  modifiers",
    " " .. box(flags.header) .. " h  declaration in header",
    " " .. box(flags.later) .. " l  later (don't jump)",
    " " .. box(flags.view == "vsplit") .. " |  vsplit  " .. box(flags.view == "split") .. " _  split  " .. box(
      flags.view == "float"
    ) .. " f  float",
    "",
    " a/<CR> append here   n new file   <Esc> cancel",
  }
end

--- Generic blocking key picker shown in a float under the cursor.
--- `lines_fn()` returns the lines to show (re-rendered after every key),
--- `handle(key)` returns a non-nil result to finish. <Esc>/q/<C-c> cancel.
local function run_picker(title, lines_fn, handle)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local lines = lines_fn()
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local win = api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width + 1,
    height = #lines,
    style = "minimal",
    border = border(),
    title = " " .. title .. " ",
    title_pos = "left",
    focusable = false,
    noautocmd = true,
  })

  local function render()
    local ls = lines_fn()
    api.nvim_buf_set_lines(buf, 0, -1, false, ls)
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, l in ipairs(ls) do
      for s, e in l:gmatch("()%[x%]()") do
        api.nvim_buf_set_extmark(buf, ns, i - 1, s - 1, { end_col = e - 1, hl_group = "DiagnosticOk" })
      end
    end
    api.nvim_buf_set_extmark(buf, ns, #ls - 1, 0, { end_col = #ls[#ls], hl_group = "Comment" })
  end

  local result
  while true do
    render()
    vim.cmd("redraw")
    local ok, key = pcall(vim.fn.getcharstr)
    if not ok or key == "\27" or key == "q" or key == "\3" then
      break
    end
    result = handle(key)
    if result ~= nil then
      break
    end
  end
  if api.nvim_win_is_valid(win) then
    api.nvim_win_close(win, true)
  end
  return result
end

--- Shows the `new`/`wrap` option picker and blocks until an action is chosen.
---@param on_done fun(flags: table|nil)
---@param title? string
function M.pick_flags(on_done, title)
  local flags = {}
  local result = run_picker(title or "effen: new", function()
    return picker_lines(flags)
  end, function(key)
    local action = M.apply_key(flags, key)
    if action then
      flags.action = action
      return flags
    end
  end)
  on_done(result)
end

--- Keys of the view picker; each one acts immediately.
M.VIEW_KEYS = { ["\r"] = "here", e = "here", ["|"] = "vsplit", _ = "split", f = "float" }

--- Shows the view picker (used by `existing`).
---@param on_done fun(view: string|nil) "here"|"vsplit"|"split"|"float", nil = cancelled
function M.pick_view(title, on_done)
  local result = run_picker(title, function()
    return {
      " e/<CR> here   | vsplit   _ split   f float",
      " <Esc> cancel",
    }
  end, function(key)
    return M.VIEW_KEYS[key]
  end)
  on_done(result)
end

--- Asks where to replace copies of wrapped code (used by `wrap`).
---@param count integer copies found in the current file
---@param on_done fun(scope: "file"|"project"|nil)
function M.pick_scope(title, count, on_done)
  local found = count == 1 and "1 copy" or (count .. " copies")
  local result = run_picker(title, function()
    return {
      " f  replace copies in this file (" .. found .. ")",
      " p  replace copies in the whole project",
      " n/<Esc> leave them",
    }
  end, function(key)
    if key == "n" then
      return false
    end
    return ({ f = "file", p = "project" })[key]
  end)
  on_done(result or nil)
end

--- Opens `buf` at (row, col) using `view` ("vsplit", "split", "float", nil).
function M.open(buf, row, col, view, title)
  if view == "vsplit" then
    vim.cmd("vsplit")
  elseif view == "split" then
    vim.cmd("split")
  elseif view == "float" then
    local f = require("effen.config").get().float
    local width = math.floor(vim.o.columns * f.width)
    local height = math.floor(vim.o.lines * f.height)
    local win = api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      border = border(),
      title = title and (" " .. title .. " ") or nil,
      title_pos = title and "center" or nil,
    })
    vim.w[win].effen_float = true
  end
  if view ~= "float" then
    vim.cmd("normal! m'")
    api.nvim_win_set_buf(0, buf)
  end
  api.nvim_win_set_cursor(0, { row + 1, col })
  vim.cmd("normal! zz")
end

return M
