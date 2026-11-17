-- Minimal test runner: nvim --headless -u NONE -l tests/run.lua [file...]
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("filetype on")

local failures, passed = 0, 0
local current

_G.describe = function(name, fn)
  current = name
  fn()
end

_G.it = function(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures = failures + 1
    io.stderr:write(("FAIL %s :: %s\n%s\n\n"):format(current or "", name, err))
  end
end

_G.eq = function(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(("%s\nexpected: %s\n  actual: %s"):format(msg or "not equal", vim.inspect(expected), vim.inspect(actual)), 2)
  end
end

local files = _G.arg and #_G.arg > 0 and _G.arg or vim.fn.glob(root .. "/tests/*_spec.lua", false, true)
for _, f in ipairs(files) do
  dofile(f)
end

io.stdout:write(("%d passed, %d failed\n"):format(passed, failures))
os.exit(failures == 0 and 0 or 1)
