Put `demo.gif` here (the README header image).

Record on macOS:
1. Cmd+Shift+5 → "Record Selected Portion", select the widget, record ~8s
   (hover the pet once, toggle mini mode once).
2. Convert: `ffmpeg -i demo.mov -vf "fps=15,scale=480:-1:flags=lanczos" -loop 0 demo.gif`
   (brew install ffmpeg). Keep it under ~5 MB.
