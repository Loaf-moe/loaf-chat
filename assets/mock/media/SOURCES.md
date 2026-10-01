# sample media

All generated, so there is nothing to license. Run in this folder:

```
ffmpeg -f lavfi -i testsrc2=size=1600x1200 -frames:v 1 -q:v 4 oven.jpg
ffmpeg -f lavfi -i testsrc2=size=900x1600 -frames:v 1 -q:v 4 tall.jpg
ffmpeg -f lavfi -i testsrc2=size=320x240:rate=10 -t 2 crumb.gif
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=30 -f lavfi -i sine=frequency=440 -t 4 -c:v libx264 -pix_fmt yuv420p -movflags +faststart -c:a aac -shortest proof.mp4
```

`recipe.pdf` is a hand-written one-page PDF saying "rye, water, salt".
