;; plot2pdf.lsp — Frame 图层 → 逐框打印 + 高亮 → exe 裁剪
;;
;; 命令: PLOT2PDF
;; 配合: crop_pdf.exe（和本文件放在同一目录）
;;
;; 交互式操作: 每次选一个图框或输入关键字调整设置

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

(defun c:PLOT2PDF (/ frameEnt frameObj coords pts ss obj
                     pmin pmax ll ur minx miny maxx maxy
                     w h margin paper
                     pdfPath outDir n
                     oldBg oldDia oldCmd total sel)

  ;; 确保 Frame 图层存在
  (if (not (tblsearch "LAYER" "Frame"))
    (progn
      (command "_.-LAYER" "_N" "Frame" "")
      (vla-put-Plottable (vlax-ename->vla-object (tblobjname "LAYER" "Frame")) :vlax-false)))

  (setq margin 0.5 paper "A0"
        outDir (strcat (getvar "DWGPREFIX") (vl-filename-base (getvar "DWGNAME")) "_PDFs")
        total 0)
  (vl-mkdir outDir)

  (while
    (progn
      (princ (strcat "\n当前设置: 边距=" (rtos margin 2 1) ", 纸张=" paper))
      (initget "边距 纸张")
      (setq sel (entsel "\n选择图框或 [边距(M)/纸张(P)] <退出>: "))

      (cond
        ((= sel "边距")
         (setq n (getreal (strcat "\n边距 <" (rtos margin 2 1) ">: ")))
         (if n (setq margin n))
         t)

        ((= sel "纸张")
         (initget "A0 A1 A2 A3 A4")
         (setq n (getkword (strcat "\n纸张 [A0/A1/A2/A3/A4] <" paper ">: ")))
         (if n (setq paper n))
         t)

        ((= (type sel) 'LIST)
         (setq frameEnt (car sel)
               frameObj (vlax-ename->vla-object frameEnt))
         (if (and (= (vla-get-ObjectName frameObj) "AcDbPolyline")
                  (vlax-get frameObj 'Closed)
                  (wcmatch (vla-get-Layer frameObj) "Frame"))
           (progn
             (vla-Highlight frameObj :vlax-true)
             (setq coords (vlax-safearray->list
                            (vlax-variant-value (vla-get-Coordinates frameObj))))
             (setq pts nil)
             (repeat (/ (length coords) 2)
               (setq pts (cons (list (car coords) (cadr coords)) pts)
                     coords (cddr coords)))
             (setq ss (ssget "WP" pts))
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
                             maxy (max maxy (cadr ll) (cadr ur))))))
                 (if (not (or (= minx 1e10) (= miny 1e10)))
                   (progn
                     (setq w (- maxx minx) h (- maxy miny)
                           pdfPath (strcat outDir "\\[" (rtos w 2 2) "].pdf")
                           n 0)
                     (while (vl-file-size pdfPath)
                       (setq n (1+ n)
                             pdfPath (strcat outDir "\\[" (rtos w 2 2) "](" (itoa n) ").pdf")))
                     (setq oldBg (getvar "BACKGROUNDPLOT")
                           oldDia (getvar "FILEDIA")
                           oldCmd (getvar "CMDECHO"))
                     (setvar "BACKGROUNDPLOT" 0)
                     (setvar "FILEDIA" 0)
                     (setvar "CMDECHO" 0)
                     (princ (strcat "\n正在打印 " (vl-filename-base pdfPath) ".pdf"))
                     (command "_.-PLOT"
                       "Y" "Model"
                       *plot2pdf-pc3*
                       paper "M" "P" "N" "W"
                       (strcat (rtos (- minx margin) 2 6) "," (rtos (- miny margin) 2 6))
                       (strcat (rtos (+ maxx margin) 2 6) "," (rtos (+ maxy margin) 2 6))
                       "1=1" "0,0" "Y" "monochrome.ctb" "Y" "A"
                       pdfPath "N" "Y")
                     (while (= (logand (getvar "CMDACTIVE") 1) 1) (command ""))
                     (setvar "CMDECHO" oldCmd)
                     (setvar "FILEDIA" oldDia)
                     (setvar "BACKGROUNDPLOT" oldBg)
                     (if *plot2pdf-dir*
                       (vlax-invoke (vlax-create-object "WScript.Shell") 'Run
                         (strcat "\"" *plot2pdf-dir* "\\crop_pdf.exe\" \""
                                 pdfPath "\" " (rtos minx 2 6) " " (rtos miny 2 6) " "
                                 (rtos maxx 2 6) " " (rtos maxy 2 6) " " (rtos margin 2 6)
                                 " \"" (if *plot2pdf-pc3-path* *plot2pdf-pc3-path* "") "\""
                                 " 0.5 0.3 -0.2") 0)
                       (princ "\n错误: crop_pdf.exe 未找到，跳过裁剪。"))
                     (setq total (1+ total))))
               )
             (vla-Highlight frameObj :vlax-false)
             t)
           (progn
             (princ "\n所选对象不是 Frame 图层上的封闭多段线")
             t)))

        ((= sel nil) nil)))
  (princ (strcat "\n全部完成, 共生成 " (itoa total) " 个 PDF"))
  (princ (strcat "\n输出目录: " outDir))
  (princ))

(princ "\nplot2pdf 已加载 — 命令: PLOT2PDF")
(princ)
