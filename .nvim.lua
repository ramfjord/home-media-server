-- Project-local nvim settings for home-media-server.
--
-- Requires `vim.o.exrc = true` in your global init.lua for nvim to
-- source this file; otherwise it's ignored. nvim prompts to trust the
-- file on first edit; once trusted it auto-loads.
--
-- All this file does today is tell the swank-lsp.nvim plugin how to
-- bring the LSP server up for this project: run `docker compose up -d
-- swank-lsp`, then attach to the TCP port the container's
-- dev-image.lisp publishes at .swank-lsp-port.

require("swank-lsp").setup({
  elp_extract = false,
  start_command = { "docker", "compose", "up", "-d", "swank-lsp" },
})
