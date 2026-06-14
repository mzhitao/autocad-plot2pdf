;; plot-loader.lsp — 一键加载所有 plot 模块
;;
;; 由 install.ps1 部署到 %ProgramFiles%\PlotTools\
;; 自动加载同目录下的 plot-core.lsp 及所有 plot*.lsp

(defun _plot-load-modules (/ d f fs cfg cfg_fp cfg_str cfg_line)
  (vl-load-com)
  ;; 查找同目录下的文件（AutoCAD 支持路径需包含安装目录）
  (setq f (findfile "plot-core.lsp"))
  (if (not f)
    (setq f (if (vl-file-size (strcat (getvar "DWGPREFIX") "plot-core.lsp"))
              (strcat (getvar "DWGPREFIX") "plot-core.lsp"))))
  (if f
    (progn
      (setq d (vl-filename-directory f))
      ;; 从同目录读取 JSON 配置
      (setq cfg (if (vl-file-size (strcat d "\\plot-config.json"))
                  (progn
                    (setq cfg_fp (open (strcat d "\\plot-config.json") "r"))
                    (setq cfg_str "")
                    (while (setq cfg_line (read-line cfg_fp))
                      (setq cfg_str (strcat cfg_str cfg_line "\n")))
                    (close cfg_fp)
                    (json:read cfg_str))))
      (if (and cfg (not *plot-core-dir*))
        (setq *plot-core-dir* (cdr (assoc "crop_pdf_dir" cfg))))
      (load (strcat d "\\plot-core.lsp"))
      (setq fs (vl-directory-files d "plot*.lsp" 1))
      (foreach f fs
        (if (and (not (vl-string-search "core" f))
                 (not (vl-string-search "loader" f)))
          (progn
            (load (strcat d "\\" f))
            (princ (strcat "\n  已加载 " f)))))
      (princ "\n---\n命令: PLOT2PDF, PLOT2EMF"))
    (princ "\n错误: 未找到 plot-core.lsp，请用 install.ps1 安装")))

(_plot-load-modules)
(princ)
