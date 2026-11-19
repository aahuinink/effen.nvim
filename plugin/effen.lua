if vim.g.loaded_effen then
  return
end
vim.g.loaded_effen = true

local cmd = vim.api.nvim_create_user_command

-- :EffenNew [keys]  e.g. `:EffenNew h|a` skips the option picker
cmd("EffenNew", function(a)
  require("effen").new({ keys = a.args ~= "" and a.args or nil })
end, { nargs = "?", desc = "Create a function from the call under the cursor" })

-- :EffenEnter [here|vsplit|split|float]  (no arg: view picker)
cmd("EffenEnter", function(a)
  require("effen").enter({ view = a.args ~= "" and a.args or nil })
end, {
  nargs = "?",
  complete = function()
    return { "here", "vsplit", "split", "float" }
  end,
  desc = "Enter the definition of the function under the cursor, leaving a return marker",
})

cmd("EffenReturn", function()
  require("effen").ret()
end, { desc = "Return to the effen marker" })

cmd("EffenUpdate", function()
  require("effen").update()
end, { desc = "Update the declaration of the function under the cursor" })

-- :'<,'>EffenWrap [keys]  (a plain line range wraps whole lines)
cmd("EffenWrap", function(a)
  local opts = { keys = a.args ~= "" and a.args or nil }
  if a.range > 0 then
    local err
    opts.region, err = require("effen.wrap").command_region(0, a.line1, a.line2)
    if not opts.region then
      return vim.notify("effen: " .. err, vim.log.levels.WARN)
    end
  end
  require("effen").wrap(opts)
end, { nargs = "?", range = true, desc = "Move the selected code into a new function" })
