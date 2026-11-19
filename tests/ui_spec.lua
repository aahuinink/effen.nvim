-- Drives the real keymaps/floats in a child Neovim over RPC.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local nvim = vim.v.progpath

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.writefile({ "int main(void) {", "  int n = 1;", "  compute(n);", "  return 0;", "}" }, dir .. "/main.c")

local child = vim.fn.jobstart({ nvim, "--embed", "--headless", "-u", "NONE", "-i", "NONE" }, { rpc = true })
local function lua(code, ...)
  return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end
local function input(keys)
  vim.rpcrequest(child, "nvim_input", keys)
  vim.wait(150)
end

lua(
  [[
  vim.opt.rtp:prepend(...)
  vim.cmd("filetype on")
  vim.g.mapleader = " "
  vim.cmd("runtime plugin/effen.lua")
  require("effen").setup({})
]],
  root
)
lua("vim.cmd.edit(...)", dir .. "/main.c")
lua("vim.api.nvim_win_set_cursor(0, { 3, 3 })")

describe("ui", function()
  it("picker -> prototype float with selected placeholder -> header prompt", function()
    input(" fnn")
    eq(
      true,
      lua(
        "for _, w in ipairs(vim.api.nvim_list_wins()) do if vim.api.nvim_win_get_config(w).relative ~= '' then return true end end return false"
      )
    )
    input("h")
    input("|")
    input("<CR>")
    -- prototype prompt: `TYPE` is selected in select mode, typing replaces it
    eq("s", lua("return vim.api.nvim_get_mode().mode"))
    eq("void compute(TYPE n)", lua("return vim.api.nvim_get_current_line()"))
    input("int")
    eq("void compute(int n)", lua("return vim.api.nvim_get_current_line()"))
    input("<CR>")
    -- header prompt prefilled with main.h
    eq(true, lua("return vim.api.nvim_get_current_line():match('main%.h$') ~= nil"))
    input("<CR>")
    eq(true, vim.tbl_contains(vim.fn.readfile(dir .. "/main.h"), "void compute(int n);"))
    eq(2, lua("return #vim.api.nvim_tabpage_list_wins(0)")) -- vsplit
    eq(
      "void compute(int n)",
      lua("return vim.api.nvim_buf_get_lines(0, vim.fn.line('.') - 3, vim.fn.line('.') - 2, false)[1]")
    )
  end)

  it("<Esc> in the picker cancels", function()
    lua("vim.cmd('only'); vim.api.nvim_win_set_cursor(0, { 4, 3 })")
    local before = lua("return vim.api.nvim_buf_line_count(0)")
    input(" fnn")
    input("<Esc>")
    eq(before, lua("return vim.api.nvim_buf_line_count(0)"))
    eq(1, lua("return #vim.api.nvim_list_wins()"))
  end)

  it("return marker goes back", function()
    input(" fnr")
    eq(5, lua("return vim.fn.line('.')")) -- shifted by `#include` + blank line
  end)

  it("[m] modifiers + [f] float view, return closes the float", function()
    lua("vim.api.nvim_buf_set_lines(0, 5, 5, false, { '  reset();' }); vim.api.nvim_win_set_cursor(0, { 6, 3 })")
    input(" fnn")
    input("m")
    input("f")
    input("<CR>")
    eq("i", lua("return vim.api.nvim_get_mode().mode"))
    eq(0, lua("return vim.api.nvim_win_get_cursor(0)[2]"))
    input("static <CR>")
    eq(true, lua("return vim.w.effen_float == true"))
    eq(
      "static void reset(void)",
      lua("return vim.api.nvim_buf_get_lines(0, vim.fn.line('.') - 3, vim.fn.line('.') - 2, false)[1]")
    )
    eq(true, vim.tbl_contains(lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"), "static void reset(void);"))
    input(" fnr")
    eq(1, lua("return #vim.api.nvim_list_wins()"))
    eq(8, lua("return vim.fn.line('.')")) -- shifted by the forward declaration
  end)

  it("wrap: visual selection -> picker -> name pre-selected -> replace copies in file", function()
    vim.fn.writefile({
      "int main(void) {",
      "  int a = 2, b = 3;",
      "  int x = a * b + 1;",
      "  int y = b * a + 1;",
      "  return x + y;",
      "}",
    }, dir .. "/wrap.c")
    lua("vim.cmd('only'); vim.cmd.edit(...); vim.api.nvim_win_set_cursor(0, { 3, 10 })", dir .. "/wrap.c")
    input("v8l")
    input(" fnw")
    input("<CR>") -- append
    eq("s", lua("return vim.api.nvim_get_mode().mode"))
    eq("int extracted(int a, int b)", lua("return vim.api.nvim_get_current_line()"))
    input("mad<CR>")
    input("f") -- replace copies in this file
    local ls = lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
    eq({
      "int mad(int a, int b);",
      "",
      "int main(void) {",
      "  int a = 2, b = 3;",
      "  int x = mad(a, b);",
      "  int y = mad(b, a);",
      "  return x + y;",
      "}",
      "",
      "int mad(int a, int b)",
      "{",
      "\treturn a * b + 1;", -- -u NONE: noexpandtab
      "}",
    }, ls)
    eq(12, lua("return vim.fn.line('.')")) -- in the new body
    input(" fnr")
    eq(5, lua("return vim.fn.line('.')"))
  end)

  it("new on a header declaration: definition prompt -> source file prompt", function()
    vim.fn.writefile({ "#pragma once", "int area(int w, int);" }, dir .. "/shape.h")
    lua("vim.cmd('only'); vim.cmd.edit(...); vim.api.nvim_win_set_cursor(0, { 2, 6 })", dir .. "/shape.h")
    input(" fnn")
    input("<CR>")
    eq("int area(int w, int arg2)", lua("return vim.api.nvim_get_current_line()"))
    input("<CR>")
    eq(true, lua("return vim.api.nvim_get_current_line():match('shape%.c$') ~= nil"))
    input("<CR>")
    eq(dir .. "/shape.c", lua("return vim.api.nvim_buf_get_name(0)"))
    eq({ '#include "shape.h"', "", "int area(int w, int arg2)", "{", "\t", "}" }, vim.fn.readfile(dir .. "/shape.c"))
    input(" fnr")
    eq(dir .. "/shape.h", lua("return vim.api.nvim_buf_get_name(0)"))
  end)
end)

vim.fn.jobstop(child)
vim.fn.delete(dir, "rf")
