local M = {}
local state = {
  delay = 250,
  default_text = nil,
}
M.setup = function(opts)
  state.delay = opts.delay
  state.default_text = opts.default_text or 'deeznuts'
  state.namespace = vim.api.nvim_create_namespace 'ghost_text'
end

local function get_lines_until_cursor()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(0, 0, row, false)
  lines[#lines] = string.sub(lines[#lines], 1, col + 1)
  return lines
end

---@param text string
local function show_ghost_text(text)
  -- Get current cursor position
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local col = vim.api.nvim_win_get_cursor(0)[2]

  -- Create namespace (if not already created)
  local ns_id = vim.api.nvim_create_namespace 'ghost_text'

  -- Clear previous ghost text
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)

  -- Set new ghost text
  vim.api.nvim_buf_set_extmark(0, ns_id, row, col, {
    virt_text = { { text, 'Comment' } },
    virt_text_pos = 'overlay',
  })
end

function M.disable()
  if state.namespace then
    vim.api.nvim_buf_clear_namespace(0, state.namespace, 0, -1)
  end
  vim.api.nvim_clear_autocmds {
    event = { 'CursorMoved', 'CursorMovedI' },
  }
  local ns_id = vim.api.nvim_create_namespace 'ghost_text'
  vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
end

M.setup_autocommands = function(opts)
  opts = opts or {}
  opts.buf_number = opts.buf_number or 0
  vim.api.nvim_clear_autocmds {
    event = { 'CursorMoved', 'CursorMovedI' },
  }
  vim.api.nvim_create_autocmd({ 'TextChangedI' }, {
    callback = function()
      local ns_id = vim.api.nvim_create_namespace 'ghost_text'
      vim.api.nvim_buf_clear_namespace(opts.buf_number, ns_id, 0, -1)

      -- only show ghost if
      -- end of line
      -- more than 2 characters in line
      -- no request for autocomplete
      -- old autocomplete doesnt match
      show_ghost_text 'deeznuts'
    end,
  })

  vim.api.nvim_create_autocmd({ 'InsertLeave' }, {
    callback = function()
      if state.namespace then
        vim.api.nvim_buf_clear_namespace(0, state.namespace, 0, -1)
      end
      vim.api.nvim_clear_autocmds {
        event = { 'InsertLeave' },
      }
      local ns_id = vim.api.nvim_create_namespace 'ghost_text'
      vim.api.nvim_buf_clear_namespace(0, ns_id, 0, -1)
    end,
  })
end

-- M.setup_autocommands { buf_number = 0 }

vim.api.nvim_create_user_command('GhostTextEnable', function()
  M.setup_autocommands()
end, {})

vim.api.nvim_create_user_command('GhostTextDisable', function()
  M.disable()
end, {})
vim.keymap.set({ 'n', 't' }, '<leader>gt', M.setup_autocommands)
vim.keymap.set({ 'n', 't' }, '<leader>gT', M.disable)

return M
