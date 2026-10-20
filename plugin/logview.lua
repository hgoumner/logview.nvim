if vim.g.loaded_logview then
  return
end
vim.g.loaded_logview = true

require("logview").setup()
