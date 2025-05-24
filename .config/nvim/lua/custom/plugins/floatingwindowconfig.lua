return {
  {
    dir = '~/.config/nvim/lua/custom/plugins/floatingwindow/',
    config = function()
      local floatingwindow = require 'floatingwindow'

      vim.api.nvim_create_user_command('Floaterminal', floatingwindow.toggleWindow, {})
      vim.keymap.set({ 'n', 't' }, '<leader>tt', floatingwindow.toggleWindow)
    end,
  },
}
