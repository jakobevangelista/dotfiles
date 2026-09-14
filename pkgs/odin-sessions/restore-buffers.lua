-- Restore backed-up unsaved buffer contents in the newly launched editor only.
local path = vim.env.ODIN_RESCUE_EDITOR_STATE
local saved = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
for _, item in ipairs(saved.buffers) do
  if item.modified and item.buftype == '' and item.name ~= '' then
    local buffer = vim.fn.bufnr(item.name)
    if buffer == -1 then buffer = vim.fn.bufadd(item.name) end
    vim.fn.bufload(buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, item.lines)
    vim.bo[buffer].modified = true
  end
end
