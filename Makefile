.PHONY: test fmt
test:
	nvim --headless -u NONE -l tests/run.lua

fmt:
	stylua lua plugin tests
