if vim.g.loaded_effen then
  return
end
vim.g.loaded_effen = true

-- :EffenNew [keys]  e.g. `:EffenNew h|a` skips the option picker
vim.api.nvim_create_user_command("EffenNew", function(a)
  require("effen").new({ keys = a.args ~= "" and a.args or nil })
end, { nargs = "?", desc = "Create a function from the call under the cursor" })

-- :EffenExisting [here|vsplit|split|float]  (no arg: view picker)
vim.api.nvim_create_user_command("EffenExisting", function(a)
  require("effen").existing({ view = a.args ~= "" and a.args or nil })
end, {
  nargs = "?",
  complete = function()
    return { "here", "vsplit", "split", "float" }
  end,
  desc = "Go to the definition of the function under the cursor, leaving a return marker",
})

vim.api.nvim_create_user_command("EffenReturn", function()
  require("effen").ret()
end, { desc = "Return to the effen marker" })

vim.api.nvim_create_user_command("EffenUpdate", function()
  require("effen").update()
end, { desc = "Update the declaration of the function under the cursor" })
