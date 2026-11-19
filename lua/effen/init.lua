-- effen: generate C/C++ functions from undeclared calls, or from selected code.
local M = {}

local config = require("effen.config")

function M.new(opts)
  require("effen.new").run(opts)
end

function M.enter(opts)
  require("effen.enter").run(opts)
end
M.existing = M.enter -- old name

function M.wrap(opts)
  require("effen.wrap").run(opts)
end

function M.ret()
  require("effen.marker").jump_back()
end

function M.update()
  require("effen.sync").update_at_cursor()
end

local function set_keymaps(cfg)
  if not cfg.prefix then
    return
  end
  local maps = {
    { "n", cfg.keys.new, M.new, "Function: new from call" },
    { "n", cfg.keys.enter, M.enter, "Function: enter definition (with marker)" },
    { "n", cfg.keys.ret, M.ret, "Function: return to marker" },
    { "n", cfg.keys.update, M.update, "Function: update declaration" },
    {
      "x",
      cfg.keys.wrap,
      function()
        -- leave visual mode first so the '< '> marks are set
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        M.wrap()
      end,
      "Function: wrap selection into a new function",
    },
  }
  for _, m in ipairs(maps) do
    if m[2] then
      vim.keymap.set(m[1], cfg.prefix .. m[2], function()
        m[3]()
      end, { desc = m[4] })
    end
  end
end

function M.setup(opts)
  local cfg = config.setup(opts)
  local langs = require("effen.lang")
  for ft, backend in pairs(cfg.languages or {}) do
    langs.register(ft, backend)
  end
  set_keymaps(cfg)

  local sync = require("effen.sync")
  local group = vim.api.nvim_create_augroup("effen", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = langs.filetypes(),
    callback = function(ev)
      sync.take(ev.buf)
    end,
  })
  if cfg.auto_update then
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      callback = function(ev)
        if langs.get(ev.buf) then
          sync.on_write(ev.buf)
        end
      end,
    })
  end
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if langs.get(ev.buf) then
        sync.take(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      sync.forget(ev.buf)
    end,
  })
  -- buffers already open when setup runs (lazy-loading on ft)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and langs.get(b) then
      sync.take(b)
    end
  end
end

return M
