-- The return marker: a global mark set by `new`/`existing`, consumed by `return`.
local M = {}

local util = require("effen.util")

local function mark()
  return require("effen.config").get().marker
end

function M.set(buf, row, col)
  vim.api.nvim_buf_set_mark(buf, mark(), row + 1, col, {})
end

function M.get()
  local m = vim.api.nvim_get_mark(mark(), {})
  if m[1] == 0 then
    return nil
  end
  return { row = m[1] - 1, col = m[2], buf = m[3], name = m[4] }
end

--- Jumps back to the marker and removes it.
function M.jump_back()
  local m = M.get()
  if not m then
    return util.warn("no return marker set")
  end
  if vim.w.effen_float then
    vim.api.nvim_win_close(0, false)
  end
  vim.cmd("normal! `" .. mark())
  vim.cmd("delmarks " .. mark())
end

return M
