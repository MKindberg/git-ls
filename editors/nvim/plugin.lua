local M = {}
M.setup = function()
    vim.lsp.config.git_ls = {
        cmd = { "git-ls" },
        filetypes = { "gitconfig" },
    }
    vim.lsp.enable("git_ls")
end
return M
