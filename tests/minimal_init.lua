-- Minimal Neovim init for running tests with plenary.nvim.
-- Usage:
--   nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
--
-- Set PLENARY_DIR to override the default plenary path, e.g.:
--   PLENARY_DIR=~/.local/share/nvim/lazy/plenary.nvim nvim --headless ...

local plenary_dir = os.getenv("PLENARY_DIR")
  or (vim.fn.stdpath("data") .. "/lazy/plenary.nvim")

vim.opt.runtimepath:prepend(plenary_dir)
vim.opt.runtimepath:prepend(".")
