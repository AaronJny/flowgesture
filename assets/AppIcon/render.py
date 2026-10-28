#!/usr/bin/env python3
"""Rebuild original FlowGesture icon assets. Requires Python 3 and Pillow (artwork tooling only)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter
import math
ROOT = Path(__file__).resolve().parent
# A single continuous gesture: broad motion, a loop, and a decisive upward finish.
CURVES = [((278,650),(390,710),(698,590),(735,415)),((735,415),(775,225),(536,256),(506,406)),((506,406),(475,549),(622,551),(700,449))]

def points(scale):
    out=[]
    for a,b,c,d in CURVES:
        for i in range(101):
            t=i/100; u=1-t
            out.append(((u*u*u*a[0]+3*u*u*t*b[0]+3*u*t*t*c[0]+t*t*t*d[0])*scale,(u*u*u*a[1]+3*u*u*t*b[1]+3*u*t*t*c[1]+t*t*t*d[1])*scale))
    return out

def mark(im, color, scale, width=64):
    dr=ImageDraw.Draw(im); p=points(scale); w=round(width*scale)
    dr.line(p,fill=color,width=w,joint='curve')
    r=w/2
    for x,y in p: dr.ellipse((x-r,y-r,x+r,y+r),fill=color)
    # Short directional tip: integrated into the gesture rather than a cursor pasted on top.
    tip=[(621*scale,447*scale),(709*scale,430*scale),(695*scale,519*scale)]
    dr.line(tip,fill=color,width=round(48*scale),joint='curve')
    for x,y in (tip[0],tip[-1]):
        r=24*scale; dr.ellipse((x-r,y-r,x+r,y+r),fill=color)

s=2; n=1024*s
im=Image.new('RGBA',(n,n)); mask=Image.new('L',(n,n)); ImageDraw.Draw(mask).rounded_rectangle((72*s,72*s,952*s,952*s),radius=196*s,fill=255)
# Rounded tile with restrained radial light; transparent outer margin matches macOS app icons.
pix=im.load()
for y in range(n):
    for x in range(n):
        t=min(1,max(0,(x/n*.32+y/n*.68)))
        glow=max(0,1-math.hypot(x/n-.24,y/n-.18)/.8)
        pix[x,y]=(round(24+43*t+3*glow),round(179-108*t+28*glow),round(220+11*t+12*glow),255)
im.putalpha(mask)
shadow=Image.new('RGBA',(n,n)); mark(shadow,(18,40,112,85),s); shadow=shadow.filter(ImageFilter.GaussianBlur(9*s)); im.alpha_composite(shadow)
mark(im,(255,255,255,255),s)
im=im.resize((1024,1024),Image.Resampling.LANCZOS); im.save(ROOT/'AppIcon.png')
iconset=ROOT/'AppIcon.iconset'; iconset.mkdir(exist_ok=True)
for size in (16,32,128,256,512):
    for factor in (1,2):
        suffix='@2x' if factor==2 else ''
        im.resize((size*factor,size*factor),Image.Resampling.LANCZOS).save(iconset/f'icon_{size}x{size}{suffix}.png')
# Template: cropped original mark, black alpha. AppKit supplies light/dark menu-bar tint.
menu=Image.new('RGBA',(1024,1024)); mark(menu,(0,0,0,255),1,width=70)
menu=menu.crop((230,235,790,740))
for size,suffix in ((18,''),(36,'@2x')):
    canvas=Image.new('RGBA',(size,size)); resized=menu.resize((size,size-2*(size//18)),Image.Resampling.LANCZOS); canvas.alpha_composite(resized,(0,size//18)); canvas.save(ROOT.parent/'MenuBar'/f'MenuBarTemplate{suffix}.png')
# Visual QA contact sheet, not part of application bundle.
sheet=Image.new('RGB',(700,400),'#eceef3')
for size,x,y in ((256,20,20),(128,310,20),(64,470,20),(32,565,20),(16,620,20)):
    tile=im.resize((size,size),Image.Resampling.LANCZOS);sheet.paste(tile,(x,y),tile)
for bg,x in (('#fafafa',310),('#242735',470)):
    ImageDraw.Draw(sheet).rectangle((x,200,x+130,280),fill=bg)
    for size,dx in ((18,15),(36,55)):
        icon=Image.open(ROOT.parent/'MenuBar'/('MenuBarTemplate'+('@2x' if size==36 else '')+'.png'))
        if bg=='#242735': icon.paste((255,255,255),mask=icon.getchannel('A'))
        sheet.paste(icon,(x+dx,220),icon)
sheet.save(ROOT/'preview.png')
