{ lib, darwinUsername, ... }:
{
  homebrew = {
    brews = [ "node@24" "opencode" ];
    casks = [ "1password-cli" "font-geist-mono-nerd-font" ];
  };

  home-manager.users.${darwinUsername} = {
    # node@24 is keg-only; keep project-specific runtimes free to override it.
    home.sessionPath = lib.mkBefore [ "/opt/homebrew/opt/node@24/bin" ];

    # Private keys stay in 1Password. Enable its SSH agent in Settings > Developer.
    home.file.".ssh/config".text = ''
      Host github.com
        User git

      Host odin
        User jakob

      Host *
        IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    '';
  };
}
