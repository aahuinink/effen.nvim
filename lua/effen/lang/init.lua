-- Language registry: maps a filetype to a backend module. Add a language by
-- implementing the interface documented in lang/c_family.lua and calling
-- `require("effen.lang").register(ft, module_or_name)` (or via the
-- `languages` setup option).
local M = {}

local registry = {
  c = "effen.lang.c",
  cpp = "effen.lang.cpp",
  objc = "effen.lang.c",
  objcpp = "effen.lang.cpp",
  cuda = "effen.lang.cpp",
}

function M.register(ft, backend)
  registry[ft] = backend
end

function M.for_filetype(ft)
  local b = registry[ft]
  if type(b) == "string" then
    b = require(b)
  end
  return b
end

function M.get(buf)
  return M.for_filetype(vim.bo[buf or 0].filetype)
end

function M.filetypes()
  return vim.tbl_keys(registry)
end

return M
