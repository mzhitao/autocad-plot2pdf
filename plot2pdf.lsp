;; plot2pdf.lsp — Frame 图层 → 批量打印 PDF → exe 裁剪
;;
;; 命令: PLOT2PDF
;; 配合: crop_pdf.exe（和本文件放在同一目录）

(vl-load-com)

;; 自动定位 crop_pdf.exe 所在目录
(setq *plot2pdf-dir*
  (cond
    ((vl-file-size (strcat (getvar "DWGPREFIX") "crop_pdf.exe"))
      (getvar "DWGPREFIX"))
    ((getenv "PLOT2PDF_DIR"))))

;; 只用默认的 DWG To PDF.pc3（系统自带，无需任何自定义）
(setq *plot2pdf-pc3* "DWG To PDF.pc3"
      *plot2pdf-pc3-path* nil)
(if (and (setq f (findfile *plot2pdf-pc3*)) (= 'STR (type f)))
  (setq *plot2pdf-pc3-path* f))

;; 内部函数: 处理一个图框（frameEnt）→ 打印 + 裁剪
(defun _plot-one-frame (frameEnt outDir margin paper scale idx / frameObj coords pts ss obj
                        pmin pmax ll ur minx miny maxx maxy w h pdfPath n
                        oldBg oldDia oldCmd ret winEnt)
  (setq frameObj (vlax-ename->vla-object frameEnt)
        ret 0)
  (vla-Highlight frameObj :vlax-true)
  (setq coords (vlax-safearray->list
                 (vlax-variant-value (vla-get-Coordinates frameObj)))
        pts nil)
  (repeat (/ (length coords) 2)
    (setq pts (cons (list (car coords) (cadr coords)) pts)
          coords (cddr coords)))
  ;; WP = 完全在框内，排除 Frame 图层（图框只作选择器）
  (setq ss (ssget "WP" pts '((8 . "~Frame"))))
  (if ss
    (progn
      (setq minx 1e10 miny 1e10 maxx -1e10 maxy -1e10)
      (repeat (setq n (sslength ss))
        (setq n (1- n)
              obj (vlax-ename->vla-object (ssname ss n)))
        (if (not (vl-catch-all-error-p
                   (vl-catch-all-apply
                     'vla-GetBoundingBox (list obj 'pmin 'pmax))))
          (progn
            (setq ll (vlax-safearray->list pmin)
                  ur (vlax-safearray->list pmax))
            (setq minx (min minx (car ll) (car ur))
                  miny (min miny (cadr ll) (cadr ur))
                  maxx (max maxx (car ll) (car ur))
                  maxy (max maxy (cadr ll) (cadr ur)))
          )))
      (if (not (or (= minx 1e10) (= miny 1e10)))
        (progn
          (setq w (- maxx minx) h (- maxy miny)
                pdfPath (strcat outDir "\\" (itoa idx) "-" (rtos w 2 1) ".pdf"))
          (setq oldBg (getvar "BACKGROUNDPLOT")
                oldDia (getvar "FILEDIA")
                oldCmd (getvar "CMDECHO"))
          (setvar "BACKGROUNDPLOT" 0)
          (setvar "FILEDIA" 0)
          (setvar "CMDECHO" 0)
          (setvar "NOMUTT" 1)
          (princ (strcat "\n正在打印 " (vl-filename-base pdfPath) ".pdf"))
          ;; 在模型空间画出打印边界（红色矩形，_PlotWindow 图层，不打印）
          (if (not (tblsearch "LAYER" "_PlotWindow"))
            (command "_.-LAYER" "_N" "_PlotWindow" "_C" "1" "_PlotWindow" "_P" "N" "_PlotWindow" ""))
          (setq winEnt (entmakex
            (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                  '(90 . 4) '(70 . 1) (cons 8 "_PlotWindow")
                  (cons 10 (list (- minx margin) (- miny margin)))
                  (cons 10 (list (+ maxx margin) (- miny margin)))
                  (cons 10 (list (+ maxx margin) (+ maxy margin)))
                  (cons 10 (list (- minx margin) (+ maxy margin))))))
          ;; command 打印（VLA 在当前 AutoCAD 不支持，改用 -PLOT）
          (command "_.-PLOT"
            "Y" "Model"
            *plot2pdf-pc3*
            paper "M" "P" "N" "W"
            (strcat (rtos (- minx margin) 2 6) "," (rtos (- miny margin) 2 6))
            (strcat (rtos (+ maxx margin) 2 6) "," (rtos (+ maxy margin) 2 6))
            (strcat "1=" (rtos scale 2 4)) "0,0" "Y" "monochrome.ctb" "Y" "A"
            pdfPath "N" "Y")
          (while (= (logand (getvar "CMDACTIVE") 1) 1) (command ""))
          (entdel winEnt)
          (setvar "NOMUTT" 0)
          (setvar "CMDECHO" oldCmd)
          (setvar "FILEDIA" oldDia)
          (setvar "BACKGROUNDPLOT" oldBg)
          (if *plot2pdf-dir*
            (progn
              (vlax-invoke (vlax-create-object "WScript.Shell") 'Run
                (strcat "\"" *plot2pdf-dir* "\\crop_pdf.exe\" \""
                        pdfPath "\" \"1.0\"") 0)
              (setq ret 1))
            (princ "\n错误: crop_pdf.exe 未找到，跳过裁剪。"))))))
  (vla-Highlight frameObj :vlax-false)
  ret)

;; 辅助：比例值 → 友好字符串（整数显示 "1"，实数显示 "0.59"）
(defun fmt-scale (s)
  (if (= (fix s) s)
    (itoa (fix s))
    (rtos s 2 2)))

;; 全局变量，跨命令保留上次使用的比例
(setq *plot2pdf-scale* 1)

(defun c:PLOT2PDF (/ margin paper outDir ss i total n p1 p2 d pm)

  ;; 确保 Frame 图层存在
  (if (not (tblsearch "LAYER" "Frame"))
    (progn
      (command "_.-LAYER" "_N" "Frame" "")
      (vla-put-Plottable (vlax-ename->vla-object (tblobjname "LAYER" "Frame")) :vlax-false)))

  (setq margin 0 paper "ISO_A0_(841.00_x_1189.00_MM)"
        outDir (strcat (getvar "DWGPREFIX") (vl-filename-base (getvar "DWGNAME")) "_PDFs"))
  (vl-mkdir outDir)

  (setq ss (ssget '((0 . "LWPOLYLINE") (8 . "Frame") (-4 . "&=") (70 . 1))))
  (if ss
    (progn
      (princ (strcat "\n当前比例 = 1:" (fmt-scale *plot2pdf-scale*)))
      (initget "R")
      (setq n (getreal (strcat "\n输入比例 (1:N) 或 [参照(R)] <" (fmt-scale *plot2pdf-scale*) ">: ")))
      (cond
        ((= n "R")
          (setq d (getdist "\n模型空间两点距离: "))
          (if (and d (> d 0))
            (progn
              (setq pm (getreal "\n对应图纸上的长度(mm): "))
              (if (and pm (> pm 0))
                (setq *plot2pdf-scale* (/ d pm))
                (princ "\n无效长度，比例未更改")))
            (princ "\n无效距离，比例未更改"))
          (princ (strcat "\n比例已设为 1:" (fmt-scale *plot2pdf-scale*))))
         ((numberp n)
         (setq *plot2pdf-scale* n)
            (princ (strcat "\n比例已设为 1:" (fmt-scale *plot2pdf-scale*)))))
        (setq total 0 i 0)
       (repeat (sslength ss)
         (setq total (+ total (_plot-one-frame (ssname ss i) outDir margin paper *plot2pdf-scale* (1+ i)))
               i (1+ i)))
      (princ (strcat "\n全部完成, 共生成 " (itoa total) " 个 PDF"))
      (princ (strcat "\n输出目录: " outDir)))
    (princ "\n未选择 Frame 封闭多段线"))
  (princ))
(princ "\nplot2pdf 已加载 — 命令: PLOT2PDF")
(princ)
