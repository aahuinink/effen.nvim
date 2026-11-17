-- Generic helpers shared by every language backend.
local M = {}

--- Joins `lines` into one string and keeps a mapping between 1-based string
--- indices and 0-based buffer (row, col) positions.
---@param lines string[]
---@param base_row? integer buffer row of lines[1] (0-based, default 0)
function M.text(lines, base_row)
  local starts = {}
  local pos = 1
  for i, l in ipairs(lines) do
    starts[i] = pos
    pos = pos + #l + 1
  end
  local T = { str = table.concat(lines, "\n"), starts = starts, base = base_row or 0 }

  --- 1-based string index -> 0-based row, col
  function T.pos(i)
    local lo, hi = 1, #starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= i then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return T.base + lo - 1, i - (starts[lo] or 1)
  end

  --- 0-based row, col -> 1-based string index
  function T.index(row, col)
    return starts[row - T.base + 1] + col
  end

  return T
end

function M.notify(msg, level)
  vim.notify("effen: " .. msg, level or vim.log.levels.INFO)
end

function M.warn(msg)
  M.notify(msg, vim.log.levels.WARN)
end

function M.err(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

function M.is_blank(s)
  return s == nil or s:match("^%s*$") ~= nil
end

function M.abspath(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

--- Path for display in prompts: relative to cwd when possible.
function M.display_path(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

--- Returns the loaded buffer for `path`, or nil.
function M.loaded_buf(path)
  local b = vim.fn.bufnr(M.abspath(path))
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
    return b
  end
end

--- Lines of `path`, from its buffer when loaded, otherwise from disk.
function M.file_lines(path)
  local b = M.loaded_buf(path)
  if b then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path)
  end
end

--- Loads (or creates) a buffer for `path`.
---@return integer bufnr, boolean created true when the file did not exist on disk
function M.ensure_buffer(path)
  path = M.abspath(path)
  local created = vim.fn.filereadable(path) == 0 and M.loaded_buf(path) == nil
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  vim.bo[b].buflisted = true
  return b, created
end

--- Writes `buf` to disk, creating parent directories.
function M.save(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  vim.fn.mkdir(vim.fs.dirname(name), "p")
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent write")
  end)
end

--- Indentation unit for `buf` based on its options.
function M.indent_unit(buf)
  if vim.bo[buf].expandtab then
    local sw = vim.bo[buf].shiftwidth
    if sw == 0 then
      sw = vim.bo[buf].tabstop
    end
    return string.rep(" ", sw)
  end
  return "\t"
end

--- Returns `t` with leading/trailing whitespace removed plus the number of
--- leading characters that were dropped.
function M.trim_lead(s)
  local lead = #s:match("^%s*")
  return vim.trim(s), lead
end

return M
