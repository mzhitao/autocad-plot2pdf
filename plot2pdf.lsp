;; plot2pdf.lsp — Frame 图层 → 选图框 → 逐框打印 + 高亮 → Python 裁剪
;;
;; 命令: PLOT2PDF

(vl-load-com)

(defun c:PLOT2PDF (/ frameSS i frameEnt frameObj ok
                    coords pts
                    ss j obj pmin pmax ll ur
                    minx miny maxx maxy w h margin
                    pdfPath outDir n
                    oldBg oldDia oldCmd total)

  ;; 1. 确保 Frame 图层存在, 然后选图框
  (if (not (tblsearch "LAYER" "Frame"))
    (progn
      (command "_.-LAYER" "_N" "Frame" "")
      (vla-put-Plottable (vlax-ename->vla-object (tblobjname "LAYER" "Frame")) :vlax-false)
      (princ "\nFrame图层中找不到图框，无法打印"))
    (progn
      (princ "\n选择图框(仅选 Frame 图层上的封闭多段线): ")
      (setq frameSS (ssget (list (cons 8 "Frame"))))
      (if (not frameSS)
        (princ "\n未选择图框，退出。")
        (progn
          ;; 2. 创建输出文件夹
      (setq outDir (strcat (getvar "DWGPREFIX")
                           (vl-filename-base (getvar "DWGNAME")) "_PDFs"))
      (vl-mkdir outDir)

      (princ (strcat "\n输出文件夹: " outDir))

      (setq margin 0.5 total 0 i 0)

      (repeat (sslength frameSS)
        (setq frameEnt (ssname frameSS i)
              frameObj (vlax-ename->vla-object frameEnt)
              i (1+ i))

        ;; 验证是否为封闭多段线(不限顶点数)
        (if (or (/= (vla-get-ObjectName frameObj) "AcDbPolyline")
                (not (vlax-get frameObj 'Closed)))
          (setq ok nil)
          (progn
            (setq coords (vlax-safearray->list (vlax-variant-value (vla-get-Coordinates frameObj))))
            (setq ok t)))

        (if (not ok)
          (setq ok t)
          (progn
            (vla-Highlight frameObj :vlax-true)
            ;; 构造多边形点表用于 WP 栏选
            (setq pts nil)
            (repeat (/ (length coords) 2)
              (setq pts (cons (list (car coords) (cadr coords)) pts)
                    coords (cddr coords)))

            (setq ss (ssget "WP" pts))
            (if ss
              (progn
                (setq minx 1e10 miny 1e10 maxx -1e10 maxy -1e10)
                (repeat (setq j (sslength ss))
                  (setq j (1- j)
                        obj (vlax-ename->vla-object (ssname ss j)))
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
                      "DWG To PDF - 1.pc3"
                      "A4" "M" "P" "N" "W"
                      (strcat (rtos (- minx margin) 2 6) "," (rtos (- miny margin) 2 6))
                      (strcat (rtos (+ maxx margin) 2 6) "," (rtos (+ maxy margin) 2 6))
                      "1=1" "0,0" "Y" "monochrome.ctb" "Y" "A"
                      pdfPath "N" "Y")
                    (while (= (logand (getvar "CMDACTIVE") 1) 1) (command ""))
                    (setvar "CMDECHO" oldCmd)
                    (setvar "FILEDIA" oldDia)
                    (setvar "BACKGROUNDPLOT" oldBg)
                    (vlax-invoke (vlax-create-object "WScript.Shell") 'Run
                      (strcat "python C:\\Users\\maozh\\lisp\\crop_pdf.py \""
                              pdfPath "\" " (rtos minx 2 6) " " (rtos miny 2 6) " "
                              (rtos maxx 2 6) " " (rtos maxy 2 6) " " (rtos margin 2 6)) 0)
                    (setq total (1+ total))
                    (vla-Highlight frameObj :vlax-false))))))))

            (princ (strcat "\n全部完成, 共生成 " (itoa total) " 个 PDF"))
            (princ (strcat "\n输出目录: " outDir))
            (princ)
          )
        )
      )
    )
  )

(princ "\nplot2pdf 已加载 — 命令: PLOT2PDF")
(princ)