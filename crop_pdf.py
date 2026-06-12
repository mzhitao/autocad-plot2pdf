"""crop_pdf.py — 裁剪 PDF 到模型空间最小包围矩形

用法:
  python crop_pdf.py <PDF> <minx> <miny> <maxx> <maxy> <margin> [comp]

数学推导:
  绘图窗口左下角 (minx-margin, miny-margin) 对应 PDF 原点 (0,0)。
  内容在 PDF 上位于 (margin-comp, margin-comp) 到 (margin+w-comp, margin+h-comp) 点。
  comp 补偿 DWG To PDF 驱动的固定硬件偏移 (默认 0.5mm)。
"""
import sys, os, fitz

pdf = sys.argv[1]
minx, miny, maxx, maxy = map(float, sys.argv[2:6])
margin = float(sys.argv[6])
comp = float(sys.argv[7]) if len(sys.argv) > 7 else 0.5

mm2pt = 72 / 25.4
off = (margin - comp) * mm2pt
w = (maxx - minx) * mm2pt
h = (maxy - miny) * mm2pt

doc = fitz.open(pdf)
page = doc[0]
pad_tr = 0.5 * mm2pt
rect = fitz.Rect(off, off, off + w + pad_tr, off + h + pad_tr)
page.set_cropbox(rect)
page.set_mediabox(rect)
tmp = pdf + ".tmp"
doc.save(tmp, incremental=False, encryption=0)
doc.close()
os.replace(tmp, pdf)
