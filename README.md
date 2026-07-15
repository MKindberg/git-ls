# git-ls

A language server for git config files. A bit rough around the edges but still working decently. Supports Hover, Formatting and Diagnostics, see Issues for known issues.

## Installation

### Neovim
Download the binary from releases and put it in your PATH or use Mason by adding `"github:mkindberg/git-ls"` as a registry in the config.
Install the plugin and run its setup function, eg in Lazy.nvim: `{"mkindberg/git-ls", config = true}`, or set it up manually by adding the following code to your config

```lua
 vim.lsp.config.ghostty = {
     cmd = {"ghostty-ls"},
     filetypes = {"ghostty"},
 }
 vim.lsp.enable("ghostty")
```
