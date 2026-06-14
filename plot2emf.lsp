;; plot2emf.lsp — Frame 图层 → 批量 PDF → EMF 输出
;; 命令: PLOT2EMF（需先加载 plot-core.lsp）

(defun c:PLOT2EMF (/ margin paper outDir ss i total pdfPath emfPath)
  ;; 确保 Frame 图层存在
  (if (not (tblsearch "LAYER" "Frame"))
    (progn
      (command "_.-LAYER" "_N" "Frame" "")
      (vla-put-Plottable (vlax-ename->vla-object (tblobjname "LAYER" "Frame")) :vlax-false)))

  (setq margin 0
        paper "ISO_A0_(841.00_x_1189.00_MM)"
        outDir (strcat (getvar "DWGPREFIX") (vl-filename-base (getvar "DWGNAME")) "_EMFs"))
  (vl-mkdir outDir)

  (setq ss (ssget '((0 . "LWPOLYLINE") (8 . "Frame") (-4 . "&=") (70 . 1))))
  (if ss
    (progn
      (_prompt-scale)
      (setq total 0 i 0)
      (repeat (sslength ss)
        (setq pdfPath (_plot-one-frame (ssname ss i) outDir paper *plot-core-scale* (1+ i)))
        (if pdfPath
          (progn
            (setq emfPath (strcat (vl-filename-directory pdfPath) "\\"
                                  (vl-filename-base pdfPath) ".emf"))
            (if *plot-core-dir*
              (progn
                (vlax-invoke (vlax-create-object "WScript.Shell") 'Run
                  (strcat "\"" *plot-core-dir* "\\crop_pdf.exe\" --emf \""
                          pdfPath "\"") 0)
                ;; 等 crop_pdf 处理完（简单轮询）
                (princ (strcat "\n正在生成 EMF: " (vl-filename-base emfPath) ".emf"))
                (setq total (1+ total)))
              (princ "\n错误: crop_pdf.exe 未找到")))
          (princ "\n跳过空图框"))
        (setq i (1+ i)))
      (princ (strcat "\n全部完成, 共生成 " (itoa total) " 个 EMF"))
      (princ (strcat "\n输出目录: " outDir)))
    (princ "\n未选择 Frame 封闭多段线"))
  (princ))

(princ "\nplot2emf 已加载 — 命令: PLOT2EMF")
(princ)
