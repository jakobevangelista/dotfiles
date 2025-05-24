return {
  {
    dir = '~/.config/nvim/lua/custom/plugins/betterchat/',
    dependancies = { 'nvim-lua/plenary.nvim' },
    config = function()
      local system_prompt =
        'You should replace the code that you are sent, only following the comments. Do not talk at all. Only output valid code. Do not provide any backticks that surround the code. Never ever output backticks like this ```. Any comment that is asking you for something should be removed after you satisfy them. Other comments should left alone. Do not output backticks'
      local helpful_prompt = 'You are a helpful assistant. What I have sent are my notes so far.'
      local betterchat = require 'betterchat'

      local function handle_open_router_spec_data(data_stream)
        local success, json = pcall(vim.json.decode, data_stream)
        if success then
          if json.choices and json.choices[1] and json.choices[1].text then
            local content = json.choices[1].text
            if content then
              betterchat.write_string_at_cursor(content)
            end
          end
        else
          print('non json ' .. data_stream)
        end
      end

      local function custom_make_openai_spec_curl_args(opts, prompt)
        local url = opts.url
        local api_key = opts.api_key_name and os.getenv(opts.api_key_name)
        local data = {
          prompt = prompt,
          model = opts.model,
          temperature = 0.7,
          stream = true,
        }
        local args = { '-N', '-X', 'POST', '-H', 'Content-Type: application/json', '-d', vim.json.encode(data) }
        if api_key then
          table.insert(args, '-H')
          table.insert(args, 'Authorization: Bearer ' .. api_key)
        end
        table.insert(args, url)
        return args
      end

      local function llama_405b_base()
        betterchat.invoke_llm_and_stream_into_editor({
          url = 'https://openrouter.ai/api/v1/chat/completions',
          model = 'meta-llama/llama-3.1-405b',
          api_key_name = 'OPEN_ROUTER_API_KEY',
          max_tokens = '128',
          replace = false,
        }, custom_make_openai_spec_curl_args, handle_open_router_spec_data)
      end

      local function groq_replace()
        betterchat.invoke_llm_and_stream_into_editor({
          url = 'https://api.groq.com/openai/v1/chat/completions',
          model = 'deepseek-r1-distill-llama-70b',
          api_key_name = 'GROQ_API_KEY',
          system_prompt = system_prompt,
          replace = true,
        }, betterchat.make_openai_spec_curl_args, betterchat.handle_openai_spec_data)
      end

      local function groq_help()
        betterchat.invoke_llm_and_stream_into_editor({
          url = 'https://api.groq.com/openai/v1/chat/completions',
          model = 'deepseek-r1-distill-llama-70b',
          api_key_name = 'GROQ_API_KEY',
          system_prompt = helpful_prompt,
          replace = false,
        }, betterchat.make_openai_spec_curl_args, betterchat.handle_openai_spec_data)
      end

      local function llama405b_replace()
        betterchat.invoke_llm_and_stream_into_editor({
          url = 'https://api.lambdalabs.com/v1/chat/completions',
          model = 'hermes-3-llama-3.1-405b-fp8',
          api_key_name = 'LAMBDA_API_KEY',
          system_prompt = system_prompt,
          replace = true,
        }, betterchat.make_openai_spec_curl_args, betterchat.handle_openai_spec_data)
      end

      local function llama405b_help()
        betterchat.invoke_llm_and_stream_into_editor({
          url = 'https://api.lambdalabs.com/v1/chat/completions',
          model = 'hermes-3-llama-3.1-405b-fp8',
          api_key_name = 'LAMBDA_API_KEY',
          system_prompt = helpful_prompt,
          replace = false,
        }, betterchat.make_openai_spec_curl_args, betterchat.handle_openai_spec_data)
      end

      local function o3_mini_help()
        betterchat.invoke_llm_and_stream_into_editor({
          url = 'https://api.openai.com/v1/chat/completions',
          model = 'o3-mini',
          api_key_name = 'OPENAI_API_KEY',
          system_prompt = helpful_prompt,
          replace = false,
        }, betterchat.make_openai_spec_curl_args, betterchat.handle_openai_spec_data, true)
      end
      local function o3_mini_help_high()
        betterchat.invoke_llm_and_stream_into_editor({
          url = 'https://api.openai.com/v1/chat/completions',
          model = 'o3-mini',
          api_key_name = 'OPENAI_API_KEY',
          system_prompt = helpful_prompt,
          replace = false,
        }, betterchat.make_openai_spec_curl_args, betterchat.handle_openai_spec_data, true)
      end
      local function o3_mini_replace()
        betterchat.invoke_llm_and_stream_into_editor({
          url = 'https://api.openai.com/v1/chat/completions',
          model = 'o1-preiew',
          api_key_name = 'OPENAI_API_KEY',
          system_prompt = system_prompt,
          replace = true,
        }, betterchat.make_openai_o3_high_spec_curl_args, betterchat.handle_openai_spec_data)
      end

      local function anthropic_help()
        betterchat.invoke_llm_and_stream_into_editor({
          url = 'https://api.anthropic.com/v1/messages',
          model = 'claude-3-7-sonnet-20250219',
          api_key_name = 'ANTHROPIC_API_KEY',
          system_prompt = helpful_prompt,
          replace = false,
        }, betterchat.make_anthropic_spec_curl_args, betterchat.handle_anthropic_spec_data)
      end

      local function anthropic_replace()
        betterchat.invoke_llm_and_stream_into_editor({
          url = 'https://api.anthropic.com/v1/messages',
          model = 'claude-3-5-sonnet-20241022',
          api_key_name = 'ANTHROPIC_API_KEY',
          system_prompt = system_prompt,
          replace = true,
        }, betterchat.make_anthropic_spec_curl_args, betterchat.handle_anthropic_spec_data)
      end

      vim.keymap.set({ 'n', 'v' }, '<leader>K', function()
        -- print 'trying'
        groq_replace()
      end, { desc = 'llm groq llama-r1' })
      vim.keymap.set({ 'n', 'v' }, '<leader>k', groq_help, { desc = 'llm groq_help llama-r1' })
      vim.keymap.set({ 'n', 'v' }, '<leader>l', o3_mini_help, { desc = 'llm o3_mini_help' })
      vim.keymap.set({ 'n', 'v' }, '<leader>L', o3_mini_help_high, { desc = 'llm o3_mini_help_high' })
      -- vim.keymap.set({ 'n', 'v' }, '<leader>L', o3_mini_replace, { desc = 'llm o3_mini_replace' })
      vim.keymap.set({ 'n', 'v' }, '<leader>i', function()
        -- print 'trying anthropic_help'
        anthropic_help()
      end, { desc = 'llm anthropic_help' })
      vim.keymap.set({ 'n', 'v' }, '<leader>I', function()
        -- print 'trying anthropic_replace'
        anthropic_replace()
      end, { desc = 'llm anthropic_replace' })
      vim.keymap.set({ 'n', 'v' }, '<leader>o', llama_405b_base, { desc = 'llama base' })
    end,
  },
}
