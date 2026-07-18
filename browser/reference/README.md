Put deterministic sender media here.

Expected default file path:
- browser/reference/reference.mp4

If you have a YUV source, convert once (example):
```
ffmpeg -f rawvideo -pixel_format yuv420p -video_size 1280x720 -framerate 30 -i input.yuv -c:v libx264 -pix_fmt yuv420p reference.mp4
```