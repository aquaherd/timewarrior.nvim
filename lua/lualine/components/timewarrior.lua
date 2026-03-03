local M = require("lualine.component"):extend()

function M:update_status()
  return require("timewarrior").current_activity()
end

return M
