local M = {}

function M.check()
  local h = vim.health
  h.start("effen")
  if vim.fn.has("nvim-0.11") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.11 is required")
  end
  local buf = vim.api.nvim_get_current_buf()
  local lang = require("effen.lang").get(buf)
  if not lang then
    h.info("current buffer filetype '" .. vim.bo[buf].filetype .. "' is not handled; open a C/C++ file to check LSP")
    return
  end
  local clients = vim.lsp.get_clients({ bufnr = buf, method = "textDocument/hover" })
  if #clients == 0 then
    h.warn("no LSP client with hover attached; argument types will be left as placeholders")
  else
    for _, c in ipairs(clients) do
      h.ok("hover provided by " .. c.name)
    end
  end
end

return M
