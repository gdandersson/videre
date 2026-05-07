# videre

> videre is latin and means _to see_

It's a supersimple macOS image viewer. The aim is fast startup of app and nothing extra.

# Installation

1. Download release
2. Unzip file
3. Copy "Videre" to Applications
4. Change "Open with.." on the extensions you desire (.jpg, .png, .heic etc) (and click "Change All..")

You can also run it from the commandline:
> /Applications/Videre.app/Contents/MacOS/videre [filename]

# Key shortcuts

|Key|Description|
|---|-----------|
|i|Show/hide info window|
|f|Enter/exit full screen mode|
|left/right arrow|Cycle between image files (sorted by filename)|
|+|Zoom in|
|-|Zoom out|
|=|Zoom to 100%|
|esc/cmd + q|Quit|

# Supported fileformats

To get an output of what's supported on your version, run:
> Videre.app/Contents/MacOS/videre --list-fileformats

On macOS 15, it shows:
|avif|
|bmp|
|gif|
|heic|
|heif|
|jpeg|
|jpg|
|png|
|tif|
|tiff|
|webp|
