local M = {}

M.defaults = {
  -- Keymaps. `prefix .. keys.x`; set a key (or `prefix`) to false to skip it.
  -- `wrap` is a visual-mode mapping, the others are normal-mode.
  prefix = "<leader>fn",
  keys = { new = "n", enter = "e", ret = "r", update = "u", wrap = "w" },
  -- Global mark placed by `new`/`enter`/`wrap` and consumed by `return`.
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
  -- Function name suggested (and pre-selected) in the wrap prototype prompt.
  wrap_name = "extracted",
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
  opts = opts or {}
  -- `keys.existing` was renamed to `keys.enter`
  if opts.keys and opts.keys.existing ~= nil and opts.keys.enter == nil then
    opts = vim.deepcopy(opts)
    opts.keys.enter, opts.keys.existing = opts.keys.existing, nil
  end
  current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  return current
end

function M.get()
  return current
end

return M
