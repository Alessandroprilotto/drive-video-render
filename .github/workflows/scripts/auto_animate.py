#!/usr/bin/env python3
import os, sys, glob, math, cv2, numpy as np
import torch

# Args: IN_DIR OUT_DIR FPS WIDTH HEIGHT [SECS]
IN_DIR  = sys.argv[1] if len(sys.argv) > 1 else "./assets"
OUT_DIR = sys.argv[2] if len(sys.argv) > 2 else IN_DIR
FPS     = int(sys.argv[3]) if len(sys.argv) > 3 else 30
WIDTH   = int(sys.argv[4]) if len(sys.argv) > 4 else 1080
HEIGHT  = int(sys.argv[5]) if len(sys.argv) > 5 else 1920
SECS    = float(sys.argv[6]) if len(sys.argv) > 6 else 4.0  # loop breve, poi lo si ripete in ffmpeg

os.makedirs(OUT_DIR, exist_ok=True)

# Carica MiDaS small (CPU)
device = "cpu"
midas = torch.hub.load("intel-isl/MiDaS", "MiDaS_small")
midas.to(device)
midas.eval()
transforms = torch.hub.load("intel-isl/MiDaS", "transforms")
transform = transforms.small_transform

def load_first_existing(base_noext):
    # prova senza estensione, poi con le estensioni comuni
    if os.path.isfile(base_noext):
        return base_noext
    for ext in (".jpg",".jpeg",".png",".webp",".JPG",".PNG",".JPEG",".WEBP"):
        p = base_noext + ext
        if os.path.isfile(p):
            return p
    return None

def anim_path(i):
    return os.path.join(OUT_DIR, f"foto_{i}_anim.mp4")

def estimate_depth(img_bgr):
    img_rgb = cv2.cvtColor(img_bgr, cv2.COLOR_BGR2RGB)
    input_batch = transform(img_rgb).to(device)
    with torch.no_grad():
        pred = midas(input_batch)
        depth = torch.nn.functional.interpolate(
            pred.unsqueeze(1),
            size=img_rgb.shape[:2],
            mode="bicubic",
            align_corners=False,
        ).squeeze().cpu().numpy()
    # normalizza e inverti (valori alti = vicino)
    d = depth - depth.min()
    d = d / (d.max() + 1e-8)
    d = 1.0 - d
    return d

def make_parallax_video(img_path, out_path):
    img0 = cv2.imread(img_path, cv2.IMREAD_COLOR)
    if img0 is None: 
        return False
    # adatta a canvas 9:16 con letterbox
    h, w = img0.shape[:2]
    scale = min(WIDTH / w, HEIGHT / h)
    nw, nh = int(w * scale), int(h * scale)
    img = cv2.resize(img0, (nw, nh), interpolation=cv2.INTER_CUBIC)
    canvas = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    x0 = (WIDTH - nw) // 2
    y0 = (HEIGHT - nh) // 2
    canvas[y0:y0+nh, x0:x0+nw] = img

    # depth sulla immagine adattata
    depth = estimate_depth(canvas)
    depth = cv2.GaussianBlur(depth, (0,0), 3.0)

    # parametri movimento (delicati per look "bello")
    N = int(SECS * FPS)
    amp_x_fg, amp_y_fg = 10, 8    # pixel max zona vicina
    amp_x_bg, amp_y_bg = 3,  2    # pixel max zona lontana
    zoom_min, zoom_max = 1.00, 1.04

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    vw = cv2.VideoWriter(out_path, fourcc, FPS, (WIDTH, HEIGHT))
    if not vw.isOpened():
        raise RuntimeError("VideoWriter non apribile: " + out_path)

    yy, xx = np.meshgrid(np.arange(HEIGHT, dtype=np.float32), 
                         np.arange(WIDTH,  dtype=np.float32), indexing="ij")

    for t in range(N):
        # traiettorie morbide
        ph = 2*math.pi*t/N
        fx = math.sin(ph)   # -1..1
        fy = math.cos(ph*0.7)

        # peso foreground/background
        w_fg = depth              # vicino
        w_bg = 1.0 - depth        # lontano

        # shift per-pixel
        dx = w_fg*amp_x_fg*fx + w_bg*amp_x_bg*(-fx*0.4)
        dy = w_fg*amp_y_fg*fy + w_bg*amp_y_bg*(-fy*0.4)

        map_x = (xx + dx).astype(np.float32)
        map_y = (yy + dy).astype(np.float32)
        frame = cv2.remap(canvas, map_x, map_y, interpolation=cv2.INTER_LINEAR, 
                          borderMode=cv2.BORDER_REPLICATE)

        # leggerissima zoomata alternata
        z = zoom_min + (zoom_max-zoom_min) * (0.5+0.5*math.sin(ph*0.8))
        M = cv2.getRotationMatrix2D((WIDTH/2, HEIGHT/2), 0, z)
        frame = cv2.warpAffine(frame, M, (WIDTH, HEIGHT), flags=cv2.INTER_LINEAR, 
                               borderMode=cv2.BORDER_REPLICATE)

        vw.write(frame)

    vw.release()
    return True

# genera animati per foto_1..6 se esistono
for i in range(1, 7):
    foto_base = os.path.join(IN_DIR, f"foto_{i}")
    src = load_first_existing(foto_base)
    if not src:
        continue
    out = anim_path(i)
    try:
        ok = make_parallax_video(src, out)
        print(f"[auto_animate] scene {i}: {'OK' if ok else 'skip'} -> {out}")
    except Exception as e:
        print(f"[auto_animate] scene {i}: ERROR {e}")
