# AUR packaging

`PKGBUILD` for the claude-swap engine CLI — the piece of this stack that
runs on Arch Linux (Omarchy included). The Limitless app is macOS-only.

Publishing needs an AUR account and its SSH key:

```sh
git clone ssh://aur@aur.archlinux.org/claude-swap.git aur-claude-swap
cp PKGBUILD aur-claude-swap/ && cd aur-claude-swap
makepkg --printsrcinfo > .SRCINFO
makepkg -si         # build/install test on an Arch box first
git add PKGBUILD .SRCINFO && git commit -m "claude-swap 0.25.0" && git push
```

Note: `python-truststore` may need to come from the AUR itself on a
stock system; `python-textual` is in [extra].
