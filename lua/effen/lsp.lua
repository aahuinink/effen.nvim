-- Thin synchronous LSP helpers (clangd-flavoured hover parsing).
local M = {}

local function timeout()
  return require("effen.config").get().lsp_timeout
end

--- Sends `method` for the position (row, col) and returns the first
--- non-empty result plus the client that produced it.
function M.request(buf, method, row, col)
  local clients = vim.lsp.get_clients({ bufnr = buf, method = method })
  if #clients == 0 then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local uri = vim.uri_from_bufnr(buf)
  for _, client in ipairs(clients) do
    local ok, character = pcall(vim.str_utfindex, line, client.offset_encoding or "utf-16", col, false)
    if not ok then
      character = col
    end
    local params = { textDocument = { uri = uri }, position = { line = row, character = character } }
    local resp = client:request_sync(method, params, timeout(), buf)
    if resp and resp.result and not vim.tbl_isempty(resp.result) then
      return resp.result, client
    end
  end
end

function M.has_hover(buf)
  return #vim.lsp.get_clients({ bufnr = buf, method = "textDocument/hover" }) > 0
end

--- Parses hover markdown into { kind, name, type, ret, expansion }.
function M.parse_hover(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  local info = {}
  info.kind, info.name = value:match("###%s*([%w%s]-)%s*`([^`]*)`")
  info.kind = info.kind and vim.trim(info.kind):lower()
  info.type = value:match("Type:%s*`([^`]+)`")
  info.ret = value:match("→%s*`([^`]+)`") or value:match("Returns?:?%s*`([^`]+)`")
  info.expansion = value:match("// Expands to\n(.-)\n```")
  if not info.type and not info.ret then
    -- generic fallback: declaration in the first code block, e.g. `int count = 0`
    local code = value:match("```%w*\n(.-)\n```")
    if code then
      local decl = vim.trim((code:gsub("//[^\n]*", ""):gsub("\n", " ")))
      decl = decl:gsub("%s*=.*$", ""):gsub(";$", "")
      local ty, name = decl:match("^(.-[%s%*&])([%a_][%w_]*)$")
      if ty then
        if decl:match("%)%s*$") == nil then
          info.type = vim.trim(ty:gsub("^static%s+", ""):gsub("^extern%s+", ""))
          info.name = info.name or name
        end
      else
        local ret = decl:match("^(.-[%s%*&])[%a_][%w_]*%s*%(")
        info.ret = ret and vim.trim(ret)
      end
    end
  end
  return info
end

--- Hover info at (row, col), or nil.
function M.hover(buf, row, col)
  local result = M.request(buf, "textDocument/hover", row, col)
  if not result or not result.contents then
    return nil
  end
  local c = result.contents
  local value
  if type(c) == "string" then
    value = c
  elseif c.value then
    value = c.value
  elseif vim.islist(c) then
    local parts = {}
    for _, item in ipairs(c) do
      parts[#parts + 1] = type(item) == "string" and item or item.value
    end
    value = table.concat(parts, "\n")
  end
  return M.parse_hover(value)
end

--- Locations returned by a location request (`textDocument/definition`,
--- `.../declaration`, ...) as { path, row, col } with 0-based byte columns.
function M.locations(buf, method, row, col)
  local result, client = M.request(buf, method, row, col)
  if not result then
    return {}
  end
  if result.uri or result.targetUri then
    result = { result }
  end
  local util = require("effen.util")
  local out = {}
  for _, loc in ipairs(result) do
    local uri = loc.uri or loc.targetUri
    local range = loc.targetSelectionRange or loc.range or loc.targetRange
    if uri and range then
      local path = vim.uri_to_fname(uri)
      local lrow, character = range.start.line, range.start.character
      local text = (util.file_lines(path) or {})[lrow + 1] or ""
      local ok, bcol = pcall(vim.str_byteindex, text, client.offset_encoding or "utf-16", character, false)
      out[#out + 1] = { path = path, row = lrow, col = ok and bcol or character }
    end
  end
  return out
end

--- Locations of the declaration of the symbol at (row, col).
function M.declarations(buf, row, col)
  return M.locations(buf, "textDocument/declaration", row, col)
end

return M
