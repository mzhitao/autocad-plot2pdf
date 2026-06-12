# PLOT2PDF — AutoCAD 图框批量打印 & 自动裁剪

## 概述

AutoCAD 内执行 `PLOT2PDF` 命令，选中 **Frame 图层** 上的封闭多段线作为图框，
逐框选内容 → 计算包围盒 → 打印为单独 PDF → Python 自动裁剪到最小尺寸。

## 文件说明

| 文件 | 说明 |
|------|------|
| `plot2pdf.lsp` | AutoCAD 命令脚本 (`PLOT2PDF`) |
| `crop_pdf.py` | PDF 裁剪脚本（自动检测内容边界 + DWG To PDF 驱动偏移补偿） |
| `requirements.txt` | Python 依赖（PyMuPDF） |

## 使用流程

1. 确保系统已安装 Python 3.10+ 和 PyMuPDF：`pip install PyMuPDF`
2. 将 `plot2pdf.lsp` 和 `crop_pdf.py` 放在**同一文件夹**
3. 文件放置方式（二选一）：
   - **方式 A**：直接丢到 DWG 所在目录 — 自动识别
   - **方式 B**：放在任意位置 → 设置系统环境变量 `PLOT2PDF_DIR = 所在文件夹路径`（方法见下）
4. 在 AutoCAD 中 `APPLOAD` 加载 `plot2pdf.lsp`
5. 在图形中绘制封闭多段线作为图框，放到 **Frame** 图层
6. 执行 `PLOT2PDF`
7. 选择图框（仅 Frame 图层上的封闭多段线）
8. 自动逐个打印至 `{dwgname}_PDFs\[width].pdf`
9. 同宽度文件自动编号 `[width](1).pdf`、`[width](2).pdf`…

### 设置环境变量（方式 B 需要）

打开 PowerShell，执行：

```
[Environment]::SetEnvironmentVariable("PLOT2PDF_DIR", "C:\你的\路径", "User")
```

然后重启 AutoCAD 使其生效。

## 输出

- 文件夹：`{DWG路径}/{DWG名}_PDFs/`
- 文件名：`[内容宽度mm].pdf`（方括号便于 Typst 提取）

## 裁剪原理

DWG To PDF 驱动有约 0.5mm 硬件偏移，导致内容整体偏向右上。
crop_pdf.py 计算内容在 PDF 页上的理论位置后，对右上额外补偿 0.5mm 确保不被切边。

## 依赖

- AutoCAD（任意版本）
- DWG To PDF - 1.pc3（AutoCAD 自带）
- monochrome.ctb（AutoCAD 自带）
- Python 3.10+
- `pip install PyMuPDF`
