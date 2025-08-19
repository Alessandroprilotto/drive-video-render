#!/usr/bin/env python3
import os, sys, cv2, numpy as np
from PIL import Image
import torch
from torchvision import transforms
from torchvision.models.segmentation import deeplabv3_resnet50

IN_DIR  = sys.argv[1] if len(sys.argv)>1 else "./assets"
OUT_DIR = sys.argv[2] if len(sys.argv)>2 else IN_DIR
WIDTH   = int(sys.argv[3]) if len(sys.argv)>3 else 1080
HEIGHT  = int(sys.argv[4]) if len(sys.argv)>4 else 1920

os.makedirs(OUT_DIR, exist_ok=True)
device = "cpu"

# DeepLabV3 (pretrained COCO/VOC 21 classi tipiche: include person e sky)
model = deeplabv3_resnet50(weights="DEFAULT").to(device).eval()
tfm = transforms.Compose([
    transforms.ToTensor(),
    transforms.Normalize(mean=(0.485,0.456,0.406), std=(0.229,0.224,0.225))
])

# class index hint (VOC-like): person=15, sky=10 (fallback se mapping differisce)
IDX_PERSON = 15
IDX_SKY = 10

def first_existing(noext):
    exts = ["",".jpg",".jpeg",".png",".webp",".JPG",".JPEG",".PNG",".WEBP"]
    for e in exts:
        p = os.path.join(IN_DIR, noext+e)
        if os.path.isfile(p): return p
    return None

def letterbox(img):
    h, w = img.shape[:2]
    scale = min(WIDTH/w, HEIGHT/h)
    nw, nh = int(w*scale), int(h*scale)
    resized = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_CUBIC)
    canvas = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    x0, y0 = (WIDTH-nw)//2, (HEIGHT-nh)//2
    canvas[y0:y0+nh, x0:x0+nw] = resized
    return canvas

def save_mask(mask, path):
    # mask uint8 0/255
    Image.fromarray(mask).save(path)

for i in range(1,7):
    src = first_existing(f"foto_{i}")
    if not src: 
        continue
    bgr = cv2.imread(src, cv2.IMREAD_COLOR)
    if bgr is None: 
        continue
    canvas = letterbox(bgr)
    rgb = cv2.cvtColor(canvas, cv2.COLOR_BGR2RGB)
    x = tfm(Image.fromarray(rgb)).unsqueeze(0).to(device)

    with torch.no_grad():
        out = model(x)["out"][0]  # [C,H,W]
    pred = out.argmax(0).cpu().numpy().astype(np.int32)

    # person mask
    mp = (pred == IDX_PERSON).astype(np.uint8)*255
    # sky mask
    ms = (pred == IDX_SKY).astype(np.uint8)*255

    # pulizia e bordo morbido
    k = max(1, WIDTH//540)  # adattivo
    mp = cv2.medianBlur(mp, 2*k+1)
    ms = cv2.medianBlur(ms, 2*k+1)
    if mp.max()>0:
        mp = cv2.GaussianBlur(mp,(0,0),2.0)
        save_mask(mp, os.path.join(OUT_DIR, f"mask_person_{i}.png"))
    if ms.max()>0:
        ms = cv2.GaussianBlur(ms,(0,0),2.0)
        save_mask(ms, os.path.join(OUT_DIR, f"mask_sky_{i}.png"))
    print(f"[auto_masks] foto_{i}: person={mp.max()>0}, sky={ms.max()>0}")
