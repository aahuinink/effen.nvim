-- End-to-end tests against a real clangd. Skipped when clangd is missing.
local clangd = vim.env.CLANGD
if not clangd or clangd == "" then
  clangd = vim.fn.exepath("clangd")
end
if clangd == "" then
  local mason = vim.fn.stdpath("data") .. "/mason/bin/clangd"
  clangd = vim.fn.executable(mason) == 1 and mason or ""
end
if clangd == "" then
  print("clangd not found, skipping integration tests")
  return
end

local ff = require("effen")
ff.setup({})

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local function write(name, lines)
  vim.fn.writefile(lines, dir .. "/" .. name)
end
local function read(name)
  return vim.fn.readfile(dir .. "/" .. name)
end
local function contains(lines, s)
  for _, l in ipairs(lines) do
    if l == s then
      return true
    end
  end
  return false
end

write("main.c", {
  "#include <stdio.h>",
  "",
  "int main(void) {",
  "  int count = 3;",
  "  char buf[64];",
  "  double ratio = compute(count, buf, 2.5f);",
  "  log_msg(buf);",
  "  return 0;",
  "}",
})

vim.cmd("edit " .. dir .. "/main.c")
local buf = vim.api.nvim_get_current_buf()
vim.lsp.start({ name = "clangd", cmd = { clangd }, root_dir = dir })
local lsp = require("effen.lsp")
local ready = vim.wait(20000, function()
  local info = lsp.hover(buf, 3, 7)
  return info ~= nil and info.type == "int"
end, 200)

describe("clangd integration", function()
  it("clangd answers hover", function()
    eq(true, ready)
  end)

  it("new: header declaration + append definition + marker", function()
    vim.api.nvim_win_set_cursor(0, { 6, 18 }) -- on `compute`
    ff.new({ keys = "ha", confirm = false, header = dir .. "/main.h" })
    local h = read("main.h")
    eq(true, contains(h, "double compute(int count, char *buf, float arg3);"), vim.inspect(h))
    eq("#ifndef MAIN_H", h[1])
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq('#include "main.h"', lines[2])
    eq(true, contains(lines, "double compute(int count, char *buf, float arg3)"))
    -- cursor is in the new body
    local cur = vim.api.nvim_win_get_cursor(0)
    eq("{", lines[cur[1] - 1])
    -- marker on the original call line (shifted by the inserted include)
    local m = vim.api.nvim_get_mark("F", {})
    eq(7, m[1])
  end)

  it("return jumps back and clears the marker", function()
    ff.ret()
    eq(7, vim.api.nvim_win_get_cursor(0)[1])
    eq(0, vim.api.nvim_get_mark("F", {})[1])
  end)

  it("update on save rewrites the header declaration", function()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l == "double compute(int count, char *buf, float arg3)" then
        vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { "double compute(int count, const char *buf, float scale)" })
      end
    end
    vim.cmd("write")
    local h = read("main.h")
    eq(true, contains(h, "double compute(int count, const char *buf, float scale);"), vim.inspect(h))
    eq(false, contains(h, "double compute(int count, char *buf, float arg3);"))
  end)

  it("new: separate source file with forward declaration, no jump", function()
    vim.api.nvim_win_set_cursor(0, { 8, 3 }) -- on `log_msg`
    ff.new({ keys = "nl", confirm = false, source = dir .. "/log.c" })
    eq(true, contains(read("log.c"), "void log_msg(char *buf)"), vim.inspect(read("log.c")))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq(true, contains(lines, "void log_msg(char *buf);"), vim.inspect(lines))
    eq(buf, vim.api.nvim_get_current_buf()) -- `l`: no jump
    eq(0, vim.api.nvim_get_mark("F", {})[1]) -- and no marker
  end)

  it("manual update from the other file renames the forward declaration", function()
    vim.cmd("write") -- save main.c so the sync may write it
    vim.cmd("edit " .. dir .. "/log.c")
    local lbuf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(lbuf, 0, 1, false, { "void log_message(const char *buf, int level)" })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    ff.update()
    local main = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    eq(true, contains(main, "void log_message(const char *buf, int level);"), vim.inspect(main))
    eq(false, vim.bo[buf].modified) -- written because it had no unsaved changes
  end)

  local function goto_call(name)
    vim.cmd("only")
    vim.api.nvim_set_current_buf(buf)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local s = l:find(name .. "(", 1, true)
      if s and l:find("=", 1, true) then
        vim.api.nvim_win_set_cursor(0, { i, s })
        return i
      end
    end
  end

  it("enter: jumps to the definition in a split and sets the marker", function()
    local call_line = goto_call("compute")
    ff.enter({ view = "vsplit" })
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    local cur = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    eq("double compute(int count, const char *buf, float scale)", line)
    eq("compute", line:sub(cur[2] + 1, cur[2] + 7)) -- cursor on the name
    eq(call_line, vim.api.nvim_get_mark("F", {})[1])
    ff.ret()
    eq(call_line, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("enter: view picker key opens a float; return closes it", function()
    local call_line = goto_call("compute")
    vim.api.nvim_feedkeys("f", "t", false) -- consumed by the picker
    ff.enter()
    eq(true, vim.w.effen_float == true)
    eq("double compute(int count, const char *buf, float scale)", vim.api.nvim_get_current_line())
    ff.ret()
    eq(1, #vim.api.nvim_list_wins())
    eq(call_line, vim.api.nvim_win_get_cursor(0)[1])
  end)
end)

describe("clangd wrap", function()
  write("calc.c", {
    "static int g_scale = 3;",
    "static int helper(int v) { return v; }",
    "int calc(int n) {",
    "  int base = n + 1;",
    "  long out = helper(base) * g_scale + n;",
    "  return out;",
    "}",
  })
  vim.cmd("only")
  vim.cmd("edit " .. dir .. "/calc.c")
  local cbuf = vim.api.nvim_get_current_buf()
  vim.lsp.start({ name = "clangd", cmd = { clangd }, root_dir = dir })
  local up = vim.wait(20000, function()
    local info = lsp.hover(cbuf, 3, 7)
    return info ~= nil and info.type == "int"
  end, 200)

  it("locals become parameters, globals and functions don't; return type from hover", function()
    eq(true, up)
    local lang = require("effen.lang").get(cbuf)
    local env = {
      hover = function(r, c)
        return lsp.hover(cbuf, r, c)
      end,
      locate = function(r, c)
        return lsp.locations(cbuf, "textDocument/definition", r, c)
      end,
    }
    local an = assert(lang.wrap_analyze(cbuf, { srow = 4, scol = 13, erow = 4, ecol = 39 }, env))
    eq("int extracted(int base, int n)", lang.format_prototype(lang.wrap_signature(an, "extracted")))
  end)
end)

describe("clangd new from declaration", function()
  it("a lone declaration is not mistaken for its own definition", function()
    write("decl.c", { "int lonely(int x);", "", "int main(void) { return lonely(1); }" })
    vim.cmd("only")
    vim.cmd("edit " .. dir .. "/decl.c")
    local dbuf = vim.api.nvim_get_current_buf()
    vim.lsp.start({ name = "clangd", cmd = { clangd }, root_dir = dir })
    vim.wait(20000, function()
      return lsp.hover(dbuf, 0, 5) ~= nil
    end, 200)
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    ff.new({ keys = "al", confirm = false })
    eq(true, contains(vim.api.nvim_buf_get_lines(dbuf, 0, -1, false), "int lonely(int x)"))
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    local before = vim.api.nvim_buf_get_lines(dbuf, 0, -1, false)
    ff.new({ keys = "al", confirm = false }) -- now defined: refused
    eq(before, vim.api.nvim_buf_get_lines(dbuf, 0, -1, false))
  end)
end)

for _, c in ipairs(vim.lsp.get_clients()) do
  c:stop(true)
end
vim.fn.delete(dir, "rf")
