;;; citar-denote.el --- Minor mode to integrate Citar and Denote -*- lexical-binding: t -*-

;; Copyright (C) 2022-2023 Peter Prevos

;; Author: Peter Prevos <peter@prevos.net>
;; Maintainer: Peter Prevos <peter@prevos.net>
;; Homepage: https://github.com/pprevos/citar-denote
;; Version: 1.5
;; Package-Requires: ((emacs "28.1") (citar "1.1") (denote "1.2.0") (dash "2.19.1"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; A minor-mode integrating 'citar' and 'denote'.
;;
;; Provides the following interactive functions:
;;
;; 1. Create a new bibliographic note: `citar-create-note'
;; 2. Add citation key(s) to existing or convert to bibliographic note: `citar-denote-add-citekey'
;; 3. Remove a reference from a bibliographic note: `citar-denote-remove-citekey'
;; 4. Open a note related to a bibliographic entry: `citar-denote-open-note'
;; 5. Access resources related to the references of a bibliographic note: `citar-denote-dwim'
;; 6. Find Denote file(s) citing the current reference(s): `citar-denote-find-reference'
;; 7. Find a citation in Denote files: `citar-denote-find-citation'
;; 8. Find bibliographic entries not cited or referenced in Denote files: `citar-denote-find-nocite'
;;
;;; Code:

(require 'denote)
(require 'dash)
(require 'citar)
(eval-when-compile (require 'subr-x))

(defgroup citar-denote ()
  "Creating and accessing bibliography files with Citar and Denote."
  :group 'files)

(defcustom citar-denote-keyword "bib"
  "Denote keyword (file tag) to indicate bibliographical notes."
  :group 'citar-denote
  :type 'string)

(defcustom citar-denote-file-type (or denote-file-type nil)
  "File Type used by Citar-Denote.
Default is `denote-file-type' or org if the former is nil.  Users
can use Markdown or plain text for their bibliographic notes."
  :group 'citar-denote
  :type '(choice
          (const :tag "Unspecified (defaults to Org)" nil)
          (const :tag "Org mode (default)" org)
          (const :tag "Markdown (YAML front matter)" markdown-yaml)
          (const :tag "Markdown (TOML front matter)" markdown-toml)
          (const :tag "Plain text" text)))

(defcustom citar-denote-subdir 'nil
  "Ask for a subdirectory when creating a new bibliographic note."
  ;; https://github.com/pprevos/citar-denote/issues/11
  :group 'citar-denote
  :type 'boolean)

(defcustom citar-denote-title-format "title"
  "Title for new bibliographic notes.
- \"title\": Extract title (or short title) from entry
- \"author-year\": Author-year citation style
- \"full\": Full citation
- nil: Citekey as-is

When using \"author-year\", you can also configure `citar-denote-title-format-authors' and `citar-denote-title-format-andstr'."
  :group 'citar-denote
  :type  '(choice
           (const :tag "Title" "title")
           (const :tag "Author (Year)" "author-year")
           (const :tag "Full citation" "full")
           (const :tag "Citekey" nil)))

(defcustom citar-denote-title-format-authors 1
  "Maximum authors in \"author-year\" for `citar-denote-title-format`."
  :group 'citar-denote
  :type  'integer)

(defcustom citar-denote-title-format-andstr "and"
  "Connecting authors in \"author-year\" for `citar-denote-note-title`."
  :group 'citar-denote
  :type  'string)

(defvar citar-denote-file-types
  `((org
     :reference-format "#+reference:  %s\n"
     :reference-regex "^#\\+reference\\s-*:")
    (markdown-yaml
     :reference-format "reference:  %s\n"
     :reference-regex "^reference\\s-*:")
    (markdown-toml
     :reference-format "reference  = %s\n"
     :reference-regex "^reference\\s-*=")
    (text
     :reference-format "reference:  %s\n"
     :reference-regex "^reference\\s-*:"))
  "Alist of `citar-denote-file-types' and their format properties.

Each element is of the form (SYMBOL . PROPERTY-LIST).  SYMBOL is
one of those specified in `citar-denote-file-type'.

PROPERTY-LIST is a plist that consists of three elements:

- `:reference-format' Front matter identifier for citation key.
- `:reference-regex' Regexp to look for the citekey in a bibliographic notes.")

(defvar citar-denote-files-regexp (concat "_" citar-denote-keyword)
  "Regexp used to look for file names of bibliographic notes.
The default assumes \"_bib\" tag is part of the file name.
Configurable with `citar-denote-keyword'.")

(defvar citar-denote-citekey-regex "@[a-zA-Z0-9:?-]+"
  "Regular expression to extract citation keys.")

;; Auxiliary functions

(defun citar-denote-reference-format (file-type)
  "Return the reference format associated to FILE-TYPE."
  (plist-get
   (alist-get file-type citar-denote-file-types)
   :reference-format))

(defun citar-denote-reference-regex (file-type)
  "Return the reference regex associated to FILE-TYPE."
  (plist-get
   (alist-get file-type citar-denote-file-types)
   :reference-regex))

(defun citar-denote-keywords-prompt ()
  "Prompt for one or more keywords and include `citar-denote-keyword'."
  (let ((choice (denote--keywords-crm (denote-keywords))))
    (unless (member citar-denote-keyword choice)
      (setq choice (append (list citar-denote-keyword) choice)))
    (if denote-sort-keywords
        (sort choice #'string-lessp)
      choice)))

(defun citar-denote-add-reference (citekey file-type)
  "Add reference property with CITEKEY in front matter with FILE-TYPE.

`citar-denote-add-citekey' is the interactive version of this function."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^\n" nil t)
    (forward-line -1)
    (if (not (eq file-type 'org))
        (forward-line -1))
    (insert
     (format (citar-denote-reference-format file-type) citekey))))

(defun citar-denote-retrieve-references (file)
  "Return reference key value(s) from FILE front matter."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let ((trims "[ \t\n\r]+")
          (file-type (denote-filetype-heuristics file)))
      (when (re-search-forward
             (citar-denote-reference-regex file-type) nil t 1)
        (split-string
         (string-trim
          (buffer-substring-no-properties (point) (line-end-position))
          trims trims) ";")))))

(defun citar-denote-get-notes (&optional citekeys)
  ;; TODO: Use xref to find references
  "Return Denote files associated with the CITEKEYS citation keys.
If CITEKEYS is omitted, return all Denote files tagged with
`citar-denote-keyword'."
  (let ((files (make-hash-table :test 'equal)))
    (prog1 files
      (dolist (file (denote-directory-files-matching-regexp
                     citar-denote-files-regexp))
        (let ((keys-in-file (citar-denote-retrieve-references file)))
          (dolist (key keys-in-file)
            (if citekeys
                (dolist (k citekeys)
                  (when (string= k key)
                    (push file (gethash key files))))
              (push file (gethash key files))))))
      (maphash
       (lambda (key filelist)
         (puthash key (nreverse filelist) files)) files))))

(defun citar-denote-retrieve-cite-files (citekey)
  "Return unique file names containing CITEKEY."
  (let ((files (denote-directory-text-only-files)))
    (delete-dups
     (mapcar
      #'xref-location-group
      (mapcar #'xref-match-item-location
              (xref-matches-in-files (format "@%s" citekey) files))))))

(defun citar-denote-has-notes ()
  "Return predicate testing whether entry has associated denote files.
See documentation for `citar-has-notes'."
  (let ((notes (citar-denote-get-notes)))
    (unless (hash-table-empty-p notes)
      (lambda (citekey) (and (gethash citekey notes) t)))))

(defun citar-denote-has-citekeys (citekeys)
  "Return predicate testing whether entry has associated CITEKEYS."
  (let ((citar-entries (citar-get-entries))
        (citekey-entries (make-hash-table :test 'equal)))
    (mapc (lambda (key)
            (puthash key (gethash key citar-entries) citekey-entries))
          citekeys)
    (unless (hash-table-empty-p citekey-entries)
      (lambda (citekey) (and (gethash citekey citekey-entries) t)))))

(defun citar-denote-remove-bibkey (file)
  "Remove `citar-denote-bibkey' from FILE."
  (let* ((file-type (denote-filetype-heuristics file))
         (keywords (denote-retrieve-keywords-value file file-type)))
    (denote--rewrite-keywords
     file
     (delete citar-denote-keyword keywords)
     file-type)
    (denote-rename-file-using-front-matter file t)))

(defun citar-denote-extract-citations ()
  "Extract citations from all Denote files."
  ;; Extract lines with citations
  (let* ((xrefs (xref-matches-in-files
                 citar-denote-citekey-regex
                 (denote-directory-text-only-files)))
         (citations (mapcar #'substring-no-properties
                            (mapcar #'xref-match-item-summary xrefs))))
    ;; Clean results
    (delete-dups
     (mapcar
      (lambda (cite)
        (replace-regexp-in-string
         "\\[cite:\\|@\\|\\]\\|\\;" ""
         (substring
          cite (string-match citar-denote-citekey-regex cite))))
      citations))))

(defun citar-denote-generate-title (citekey)
  "Generate title for new bibliographic note using CITEKEY.
Either title, author/year, full reference or citation key, based on `citar-denote-title-format'."
  ;; https://github.com/pprevos/citar-denote/issues/15
  (let ((title (citar-get-value "title" citekey))
        (author-names (or (citar-get-value "author" citekey)
                          (citar-get-value "editor" citekey)))
        (year (or (citar-get-value "year" citekey)
                  (citar-get-value "date" citekey)
                  (citar-get-value "issued" citekey))))
    (cond ((equal citar-denote-title-format "title")
           title)
          ((equal citar-denote-title-format "author-year")
           (concat (citar--shorten-names
                    author-names
                    citar-denote-title-format-authors
                    citar-denote-title-format-andstr)
                   " (" year ")"))
          ((equal citar-denote-title-format "full")
           (let ((ref (citar-format-reference (list citekey))))
                (substring ref 0 (- (length ref) 2))))
          (t citekey))))

;;;###autoload
(defun citar-denote-create-note (citekey &optional _entry)
  "Create a bibliography note for CITEKEY with properties ENTRY.

The file type for the new note is determined by `citar-denote-file-type'.
The title of the new note is set by `citar-denote-title-format'.
When `citar-denote-subdir' is non-nil, prompt for a subdirectory."
  (denote
   (read-string "Title: " (citar-denote-generate-title citekey))
   (citar-denote-keywords-prompt)
   citar-denote-file-type
   (when citar-denote-subdir (denote-subdirectory-prompt)))
  (citar-denote-add-reference citekey citar-denote-file-type))

;; Interactive functions

;;;###autoload
(defun citar-denote-open-note ()
  "Open a bibliographic note."
  (interactive)
  (let* ((citekeys (citar-select-refs :filter (citar-denote-has-notes)))
         (file (citar--select-resource
                citekeys :notes t :create-notes t)))
    (find-file (cdr file))))

;;;###autoload
(defun citar-denote-dwim ()
  "Access attachments, notes and links of a bibliographic reference."
  (interactive)
  ;; TODO: Generalise this function with embark
  ;; Any citation keys in the note?
  (if-let* ((keys (citar-denote-retrieve-references (buffer-file-name)))
            (key (if (= (length keys) 1)
                    (car keys)
                  (citar-select-ref
                   :filter (citar-denote-has-citekeys keys)))))
      (citar-open (list key))
    (if (denote-file-is-note-p (buffer-file-name))
        (when (yes-or-no-p "Current buffer does not reference a citation key.  Add a reference? ")
          (citar-denote-add-citekey)
          (citar-denote-dwim))
      (user-error "Buffer is not a Denote file"))))

;;;###autoload
(defun citar-denote-open-reference-entry ()
  "Open bibliographic entry associated with a bibliographic reference."
  (interactive)
  (if-let* ((keys (citar-denote-retrieve-references (buffer-file-name)))
            (key (if (= (length keys) 1)
                    (car keys)
                  (citar-select-ref
                   :filter (citar-denote-has-citekeys keys)))))
      (citar-open-entry key)
    (if (denote-file-is-note-p (buffer-file-name))
        (when (yes-or-no-p "Current buffer does not reference a citation key.  Add a reference? ")
          (citar-denote-add-citekey)
          (citar-denote-open-reference-entry))
      (user-error "Buffer is not a Denote file"))))

;;;###autoload
(defun citar-denote-add-citekey ()
  "Add citation key(s) to existing or convert to bibliographic note."
  (interactive)
  (if-let* ((file (buffer-file-name))
            ((denote-file-is-note-p file))
            (file-type (denote-filetype-heuristics file))
            (citekeys (citar-select-refs))
            (references (mapconcat 'identity citekeys ";")))
      ;; Check whether reference line already exists
      (if-let (keys (citar-denote-retrieve-references file))
          ;; Append reference list
          (save-excursion
            (goto-char (point-min))
            (re-search-forward (citar-denote-reference-regex file-type))
            (end-of-line)
            (insert (concat ";" references))
            (save-buffer))
        ;; Add new citation keys
        (progn (citar-denote-add-reference references file-type)
               (denote-keywords-add (list citar-denote-keyword))
               (save-buffer)))
    (user-error "Buffer is not a Denote file")))

;;;###autoload
(defun citar-denote-remove-citekey ()
  "Remove a reference from a bibliographic note."
  (interactive)
  (let* ((file (buffer-file-name))
         (file-type (denote-filetype-heuristics file))
         (citekeys (citar-denote-retrieve-references file))
         (selected (if (< (length citekeys) 2)
                       (car citekeys)
                     (citar-select-ref
                      :filter (citar-denote-has-citekeys citekeys))))
         (new-citekeys (delete selected citekeys)))
    (if (denote-file-is-note-p file)
        (save-excursion
          ;; Remove references line
          (goto-char (point-min))
          (re-search-forward (citar-denote-reference-regex file-type))
          (move-beginning-of-line nil)
          (kill-line 1)
          ;; Add new line or remove file tags when applicable
          (if (> (length new-citekeys) 0)
              (citar-denote-add-reference
               (mapconcat 'identity new-citekeys ";") file-type)
            (citar-denote-remove-bibkey file))
          (save-buffer))
      (user-error "Buffer is not a Denote file"))))

;;;###autoload
(defun citar-denote-find-citation ()
  "Find a citation in Denote files."
  (interactive)
  (let* ((citations (citar-denote-extract-citations))
         (citekey (citar-select-ref
                   :filter (citar-denote-has-citekeys citations)))
         (files (citar-denote-retrieve-cite-files citekey)))
    (find-file (denote-get-path-by-id
                (denote-extract-id-from-string
                 (denote-link--find-file-prompt files))))
    (search-forward citekey)))

;;;###autoload
(defun citar-denote-find-reference ()
  "Find Denote file(s) citing the current reference(s)."
  (interactive)
  (let ((file (buffer-file-name)))
    (if (denote-file-is-note-p file)
        (let* ((citekeys (citar-denote-retrieve-references file))
               (citekey (when citekeys
                          (if (= (length citekeys) 1)
                              (car citekeys)
                            (citar-select-ref
                             :filter
                             (citar-denote-has-citekeys citekeys)))))
               (files (delete file
                              (citar-denote-retrieve-cite-files citekey))))
          (cond
           (files
            (find-file (denote-get-path-by-id
                        (denote-extract-id-from-string
                         (denote-link--find-file-prompt files))))
            ;; TODO: Find citekey
            )
           ((null citekey)
            (when (yes-or-no-p
                   "Current buffer does not reference a citation key.  Add a reference ?")
              (citar-denote-add-citekey)
              (citar-denote-find-reference)))
           (t
            (user-error "No citation found in other Denote files"))))
      (user-error "Buffer is not a Denote file"))))

(defun citar-denote-find-nocite ()
  "Find bibliographic entries not cited or referenced in Denote files."
  (let* ((all-items (hash-table-keys (citar-get-entries)))
         (used-citations (citar-denote-extract-citations))
         (setreferences
          (hash-table-keys (citar-denote-get-notes)))
         (all-citations
          (delete-dups (append used-citations references)))
         (unused (-difference all-items all-citations)))
     (citar-select-refs
      :multiple t
      :filter (citar-denote-has-citekeys unused))))

;;;###autoload
(defun citar-denote-cite-nocite ()
  "Cite bibliographic entries not cited or referenced in Denote files."
  (interactive)
  (if (denote-file-is-note-p (buffer-file-name))
      (citar-insert-citation (citar-denote-find-nocite))
    (user-error "Buffer is not a Denote file")))

;;;###autoload
(defun citar-denote-note-nocite ()
  "Create note for bibliographic entries not cited or referenced in Denote files."
  (interactive)
  (citar-create-note (car (citar-denote-find-nocite))))

;; Citar integration

(defconst citar-denote-config
  (list :name "Denote"
        :category 'file
        :items #'citar-denote-get-notes
        :hasitems #'citar-denote-has-notes
        :open #'find-file
        :create #'citar-denote-create-note)
  "Instructing citar to use citar-denote functions.")

(defconst citar-denote-orig-source
  citar-notes-source
  "Store the `citar-notes-source' value prior to enabling `citar-denote-mode'.")

(defvar citar-notes-source)

(defvar citar-notes-sources)

;; Initialise minor mode

(defun citar-denote-setup ()
  "Setup `citar-denote-mode'."
  (citar-register-notes-source
   'citar-denote-source citar-denote-config)
  (setq citar-notes-source 'citar-denote-source))

(defun citar-denote-reset ()
  "Reset citar to default values."
  (setq citar-notes-source citar-denote-orig-source)
  (citar-remove-notes-source 'citar-denote))

;;;###autoload
(define-minor-mode citar-denote-mode
  "Toggle integration between Citar and Denote."
  :global t
  :group 'citar
  :lighter " citar-denote"
  (if citar-denote-mode
      (citar-denote-setup)
    (citar-denote-reset)))

(provide 'citar-denote)
;;; citar-denote.el ends here
