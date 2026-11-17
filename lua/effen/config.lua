local M = {}

M.defaults = {
  -- Keymaps. `prefix .. keys.x`; set a key (or `prefix`) to false to skip it.
  prefix = "<leader>f",
  keys = { new = "n", existing = "e", ret = "r", update = "u" },
  -- Global mark placed by `new`/`existing` and consumed by `return`.
  marker = "F",
  -- Sync declarations on save when a definition's signature changed.
  auto_update = true,
  -- Placeholder for types that could not be deduced (<Tab> jumps between them
  -- in the prototype prompt).
  unknown_type = "TYPE",
  -- Timeout for each LSP request while deducing types (ms).
  lsp_timeout = 1000,
  -- Put the function's opening brace on its own line.
  brace_newline = true,
  -- "ifndef" or "pragma" for newly created headers.
  header_guard = "ifndef",
  -- Header extension suggested when none exists yet, per language.
  header_ext = { c = "h", cpp = "hpp" },
  -- Floating windows.
  border = "rounded",
  float = { width = 0.8, height = 0.7 },
  -- Extra languages: { filetype = "module.name" | backend_table }
  languages = {},
}

local current = vim.deepcopy(M.defaults)

function M.setup(opts)
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return current
end

function M.get()
  return current
end

return M
