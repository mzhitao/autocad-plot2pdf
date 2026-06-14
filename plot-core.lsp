;; plot-core.lsp — 打印公共核心
;;
;; 提供:
;;   *plot-core-dir*     — crop_pdf.exe 所在目录
;;   *plot-core-pc3*     — PDF 打印驱动
;;   *plot-core-pc3-path*— PC3 完整路径
;;   *plot-core-scale*   — 全局比例
;;   fmt-scale           — 比例格式化
;;   _plot-one-frame     — 处理单个图框 → 返回 PDF 路径

(vl-load-com)

;; 自动定位 crop_pdf.exe 所在目录
(if (not *plot-core-dir*)
  (setq *plot-core-dir*
    (if (vl-file-size (strcat (getvar "DWGPREFIX") "crop_pdf.exe"))
      (getvar "DWGPREFIX")
      (getenv "PLOT2PDF_DIR"))))

;; 只用默认的 DWG To PDF.pc3
(if (not *plot-core-pc3*)
  (setq *plot-core-pc3* "DWG To PDF.pc3"))
(or *plot-core-pc3-path* (setq *plot-core-pc3-path* (findfile *plot-core-pc3*)))

;; 全局比例
(if (not *plot-core-scale*) (setq *plot-core-scale* 1))

;; 比例值 → 友好字符串
(defun fmt-scale (s)
  (if (= (fix s) s) (itoa (fix s)) (rtos s 2 2)))

;; 处理一个图框 + 内部对象
;; frameEnt — 图框实体名
;; outDir   — 输出目录
;; paper    — 纸张名（仅用于 -PLOT 命令）
;; scale    — 打印比例
;; idx      — 序号
;; 返回 pdfPath（字符串）或 nil
(defun _plot-one-frame (frameEnt outDir paper scale idx / frameObj coords pts ss obj
                         pmin pmax ll ur minx miny maxx maxy w h pdfPath n
                         oldBg oldDia oldCmd winEnt)
  (setq frameObj (vlax-ename->vla-object frameEnt))
  (vla-Highlight frameObj :vlax-true)
  (setq coords (vlax-safearray->list
                 (vlax-variant-value (vla-get-Coordinates frameObj)))
        pts nil)
  (repeat (/ (length coords) 2)
    (setq pts (cons (list (car coords) (cadr coords)) pts)
          coords (cddr coords)))
  ;; WP 选择框内对象，排除 Frame 图层
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
                  maxy (max maxy (cadr ll) (cadr ur))))))
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
          ;; 画打印边界矩形（_PlotWindow 图层，不打印）
          (if (not (tblsearch "LAYER" "_PlotWindow"))
            (command "_.-LAYER" "_N" "_PlotWindow" "_C" "1" "_PlotWindow" "_P" "N" "_PlotWindow" ""))
          (setq winEnt (entmakex
            (list '(0 . "LWPOLYLINE") '(100 . "AcDbEntity") '(100 . "AcDbPolyline")
                  '(90 . 4) '(70 . 1) (cons 8 "_PlotWindow")
                  (cons 10 (list (- minx 0) (- miny 0)))
                  (cons 10 (list (+ maxx 0) (- miny 0)))
                  (cons 10 (list (+ maxx 0) (+ maxy 0)))
                  (cons 10 (list (- minx 0) (+ maxy 0))))))
          (command "_.-PLOT"
            "Y" "Model"
            *plot-core-pc3*
            paper "M" "P" "N" "W"
            (strcat (rtos minx 2 6) "," (rtos miny 2 6))
            (strcat (rtos maxx 2 6) "," (rtos maxy 2 6))
            (strcat "1=" (rtos scale 2 4)) "0,0" "Y" "monochrome.ctb" "Y" "A"
            pdfPath "N" "Y")
          (while (= (logand (getvar "CMDACTIVE") 1) 1) (command ""))
          (entdel winEnt)
          (setvar "NOMUTT" 0)
          (setvar "CMDECHO" oldCmd)
          (setvar "FILEDIA" oldDia)
          (setvar "BACKGROUNDPLOT" oldBg)
          pdfPath)
        (progn (princ "\n错误: 无法计算对象包围盒") nil)))
    (progn (princ "\n图框内无有效对象") nil))
  (vla-Highlight frameObj :vlax-false))

;; 交互式比例输入
(defun _prompt-scale (/ n d pm)
  (princ (strcat "\n当前比例 = 1:" (fmt-scale *plot-core-scale*)))
  (initget "R")
  (setq n (getreal (strcat "\n输入比例 (1:N) 或 [参照(R)] <" (fmt-scale *plot-core-scale*) ">: ")))
  (cond
    ((= n "R")
      (setq d (getdist "\n模型空间两点距离: "))
      (if (and d (> d 0))
        (progn
          (setq pm (getreal "\n对应图纸上的长度(mm): "))
          (if (and pm (> pm 0))
            (setq *plot-core-scale* (/ d pm))
            (princ "\n无效长度，比例未更改")))
        (princ "\n无效距离，比例未更改"))
      (princ (strcat "\n比例已设为 1:" (fmt-scale *plot-core-scale*))))
    ((numberp n)
      (if (> n 0)
        (setq *plot-core-scale* n)
        (princ "\n比例必须大于 0"))
      (princ (strcat "\n比例已设为 1:" (fmt-scale *plot-core-scale*))))
    (t (princ (strcat "\n保持比例 1:" (fmt-scale *plot-core-scale*)))))
  *plot-core-scale*)

(princ "\nplot-core 已加载")
(princ)
