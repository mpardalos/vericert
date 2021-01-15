;; Publishing projects, this one is for the zettelkasten
(require 'package)
(package-initialize)
(add-to-list 'package-archives '("org" . "https://orgmode.org/elpa/") t)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-refresh-contents)
(package-install 'org-plus-contrib)
(package-install 'htmlize)

(require 'org)
(require 'ox-publish)
(require 'ox-html)
(require 'htmlize)

(defvar vericert/header "")
(defvar vericert/site-attachments nil)
(defvar vericert/base "")

(setq vericert/base "/vericert")

(setq vericert/header (concat "<div id=\"left-bar\">
<header id=\"header\" class=\"status\">
<div class=\"logo\"><a href=\"" vericert/base "\">Vericert</a></div>
<nav id=\"navbar\">
<span><a href=\"" vericert/base "/docs/\">Documentation</a></span>
<span><a href=\"" vericert/base "/proof/\">Proof</a></span>
</nav>
<p>Vericert is the first formally verified high-level synthesis tool.</p>
</header>
<div id=\"toc\"></div>
</div>"))

(setq vericert/site-attachments
  (regexp-opt '("jpg" "jpeg" "gif" "png" "svg"
                "ico" "cur" "css" "js" "woff" "woff2" "ttf"
                "html" "pdf")))

(setq user-full-name nil)

(setq org-export-with-smart-quotes t
      org-export-with-section-numbers t
      org-export-with-toc t)

(setq org-html-divs '((preamble "div" "nothing")
                      (content "main" "content")
                      (postamble "footer" "postamble"))
      org-html-container-element "section"
      org-html-metadata-timestamp-format "%Y-%m-%d"
      org-html-checkbox-type 'html
      org-html-html5-fancy t
      org-html-validation-link nil
      org-html-doctype "html5"
      org-html-coding-system 'utf-8-unix
      org-html-head-include-default-style nil
      org-html-head-include-scripts nil)

(setq org-publish-project-alist
      (list
       (list "vericert-org"
             :base-directory "./"
             :base-extension "org"
             :exclude (regexp-opt '("README" "draft"))
             :html-head-extra
             (concat "<script src=\"https://cdnjs.cloudflare.com/ajax/libs/tocbot/4.11.1/tocbot.min.js\"></script>
<link rel=\"stylesheet\" href=\"https://cdnjs.cloudflare.com/ajax/libs/tocbot/4.11.1/tocbot.css\">
<link rel=\"preconnect\" href=\"https://fonts.gstatic.com\">
<link href=\"https://fonts.googleapis.com/css2?family=Alegreya:ital,wght@0,400;0,500;0,700;1,400;1,500;1,700&display=swap\" rel=\"stylesheet\">
<link rel=\"stylesheet\" href=\"" vericert/base "/css/fonts.css\" type=\"text/css\" />
<link rel=\"stylesheet\" href=\"" vericert/base "/css/org.css\" type=\"text/css\" media=\"screen\" />")
             :html-preamble t
             :html-preamble-format (list (list "en" vericert/header))
             :html-postamble t
             :html-postamble-format '(("en" "<script>tocbot.init({
  tocSelector: '#toc',
  contentSelector: '#content',
  headingSelector: 'h2, h3',
  hasInnerContainers: true,
});</script>"))
             :publishing-directory "./html"
             :publishing-function 'org-html-publish-to-html
             :recursive t)
       (list "vericert-assets"
             :base-directory "."
             :base-extension vericert/site-attachments
             :include '(".nojekyll")
             :exclude "html/"
             :publishing-directory "./html"
             :publishing-function 'org-publish-attachment
             :recursive t)
       (list "vericert" :components '("vericert-org" "vericert-assets"))))

(defun publish-vericert-docs ()
  "Publish Vericert documentation."
  (interactive)
  (org-publish "vericert" t))
