-- `existing`: jump to the definition of an existing function (LSP goto
-- definition) with the same marker and view options as `new`.
local M = {}

local api = vim.api
local util = require("effen.util")
local ui = require("effen.ui")
local lsp = require("effen.lsp")
local marker = require("effen.marker")

local function open_location(loc, view, from, title)
  marker.set(from.buf, from.row, from.col)
  local buf = vim.fn.bufadd(loc.path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  ui.open(buf, loc.row, loc.col, view ~= "here" and view or nil, title)
end

--- Entry point.
---@param opts? { view?: "here"|"vsplit"|"split"|"float" } skips the view picker
function M.run(opts)
  opts = opts or {}
  local buf = api.nvim_get_current_buf()
  local cursor = api.nvim_win_get_cursor(0)
  local from = { buf = buf, row = cursor[1] - 1, col = cursor[2] }
  local word = vim.fn.expand("<cword>")

  if #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/definition" }) == 0 then
    return util.warn("no LSP client with goto-definition attached")
  end
  local locs = lsp.locations(buf, "textDocument/definition", from.row, from.col)
  if #locs == 0 then
    return util.warn("no definition found for `" .. word .. "` (use new to create it)")
  end

  local function go(view)
    if not view then
      return
    end
    if #locs == 1 then
      return open_location(locs[1], view, from, word)
    end
    vim.ui.select(locs, {
      prompt = "Definitions of " .. word,
      format_item = function(l)
        return util.display_path(l.path) .. ":" .. (l.row + 1)
      end,
    }, function(choice)
      if choice then
        open_location(choice, view, from, word)
      end
    end)
  end

  if opts.view then
    return go(opts.view)
  end
  ui.pick_view("effen: " .. word, go)
end

return M
