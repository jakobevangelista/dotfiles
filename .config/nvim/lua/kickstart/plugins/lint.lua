return {
  { -- Linting
    'mfussenegger/nvim-lint',
    event = { 'BufReadPre', 'BufNewFile' },
    config = function()
      local lint = require 'lint'
      lint.linters_by_ft = {}

      if vim.fn.executable 'eslint_d' == 1 then
        lint.linters_by_ft.javascript = { 'eslint_d' }
        lint.linters_by_ft.typescript = { 'eslint_d' }
        lint.linters_by_ft.javascriptreact = { 'eslint_d' }
        lint.linters_by_ft.typescriptreact = { 'eslint_d' }
      end

      if vim.fn.executable 'markdownlint' == 1 then
        lint.linters_by_ft.markdown = { 'markdownlint' }
      end

      if vim.fn.executable 'golangci-lint' == 1 then
        lint.linters_by_ft.go = { 'golangcilint' }

        -- nvim-lint's bundled arguments still target golangci-lint v1.
        -- Override them with the v2 JSON output flags expected by the parser.
        lint.linters.golangcilint.args = {
          'run',
          '--output.json.path=stdout',
          '--issues-exit-code=0',
          '--show-stats=false',
          '.',
        }
      end

      local lint_augroup = vim.api.nvim_create_augroup('lint', { clear = true })
      vim.api.nvim_create_autocmd('BufWritePost', {
        desc = 'Lint the saved buffer',
        group = lint_augroup,
        callback = function(event)
          if vim.bo[event.buf].filetype ~= 'go' then
            lint.try_lint()
            return
          end

          local filename = vim.api.nvim_buf_get_name(event.buf)
          local cwd = vim.fs.root(filename, { 'go.work', 'go.mod', '.git' }) or vim.fs.dirname(filename)
          lint.try_lint(nil, { cwd = cwd })
        end,
      })
    end,
  },
}
