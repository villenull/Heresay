# Mockups

`right-click-menu.html` is the source for `docs/images/right-click-menu.png`. That image
is a mockup, not a screenshot, so it is regenerated rather than re-photographed whenever
the menu entries change.

The app mark in it is a copy of the `$appIcon` geometry in `app/Progress.ps1`, which is
the single definition of the logo — see `installer/assets/New-AppMark.ps1`. If the mark
changes there, update the inline `<svg>` here to match.

Regenerate (any Chromium-based browser; the flags are the same for Edge):

```
chrome --headless --disable-gpu --hide-scrollbars \
       --force-device-scale-factor=2 --window-size=332,402 \
       --screenshot=right-click-menu.png right-click-menu.html
```

That yields the 664x804 image the README embeds at width 360.
