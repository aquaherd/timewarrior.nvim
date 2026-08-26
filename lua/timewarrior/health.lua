local M = {}

function M.check()
  vim.health.start("timewarrior")

  if vim.fn.executable("timew") == 1 then
    local version = vim.fn.system("timew --version"):match("([^\n]+)")
    vim.health.ok("'timew' found: " .. (version or "unknown version"))
  else
    vim.health.error("'timew' not found in PATH — commands will fail")
  end

  vim.health.info("Neovim " .. vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch)
end

return M
