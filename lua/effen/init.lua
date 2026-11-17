-- effen: generate C/C++ functions from undeclared calls.
local M = {}

local config = require("effen.config")

function M.new(opts)
  require("effen.new").run(opts)
end

function M.existing(opts)
  require("effen.existing").run(opts)
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
    { cfg.keys.new, M.new, "Function: new from call" },
    { cfg.keys.existing, M.existing, "Function: go to definition (with marker)" },
    { cfg.keys.ret, M.ret, "Function: return to marker" },
    { cfg.keys.update, M.update, "Function: update declaration" },
  }
  for _, m in ipairs(maps) do
    if m[1] then
      vim.keymap.set("n", cfg.prefix .. m[1], function()
        m[2]()
      end, { desc = m[3] })
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
