;;; eav-bridge.el --- UNIX-socket bridge from eavd to eav.el  -*- lexical-binding: t; -*-

;; Author: Adithya Bhat
;; Keywords: org-mode, agenda, ipc

;;; Commentary:
;;
;; A persistent socket dispatcher that lets the Rust daemon (eavd) call into
;; eav.el's mutation surface without paying an `emacsclient --eval` startup
;; per request.
;;
;; Wire format
;; -----------
;; Length-prefixed JSON frames over a UNIX domain socket:
;;   <u32 big-endian length> <JSON bytes>
;;
;; Request shape:
;;   {"id": 42, "method": "write.set-state",
;;    "params": {"file": "...", "pos": 1234, "state": "DONE"}}
;;
;; Response (success):
;;   {"id": 42, "ok": true, "result": <method-specific JSON>}
;;
;; Response (error):
;;   {"id": 42, "ok": false, "error": {"code": "<code>", "message": "..."}}
;;
;; Server-pushed event (no id):
;;   {"event": "after-save", "params": {"file": "..."}}
;;
;; Method registry below maps each method name to an existing `eav-*' helper
;; in `eav.el'. eav-bridge.el is purely a transport layer; all org semantics
;; remain in `eav.el'.
;;
;; Lifecycle
;; ---------
;; `eav-bridge-start' opens the socket and registers the event hooks.
;; `eav-bridge-stop' shuts it down. The daemon auto-loads this file on
;; first connect (see `eavd` startup).

;;; Code:

(require 'json)
(require 'org)
(require 'eav)

(defgroup eav-bridge nil
  "Persistent IPC bridge to the Emacs Agenda Viewer daemon."
  :group 'org)

(defcustom eav-bridge-socket-path
  (expand-file-name (format "eav-bridge-%d.sock"
                            (user-uid))
                    (or (getenv "XDG_RUNTIME_DIR")
                        temporary-file-directory))
  "UNIX socket path the bridge listens on."
  :type 'string
  :group 'eav-bridge)

(defcustom eav-bridge-protocol-version 1
  "Wire-protocol version. Bumped when the frame format changes."
  :type 'integer
  :group 'eav-bridge)

(defvar eav-bridge--server nil
  "The active server `process' object, or nil.")

(defvar eav-bridge--connections nil
  "Alist of (PROCESS . BUFFER) for each active client connection.")

;; ----------------------------------------------------------------------------
;; Method registry
;; ----------------------------------------------------------------------------

(defvar eav-bridge--methods
  '(;; --- reads (proxied; most live in eavd's index) ---
    ("read.config"            . eav-bridge--read-config)
    ("read.notes"             . eav-bridge--read-notes)
    ("read.outline-path"      . eav-bridge--read-outline-path)
    ("read.refile-targets"    . eav-bridge--read-refile-targets)
    ("read.capture-templates" . eav-bridge--read-capture-templates)
    ("read.sexp-entries"      . eav-bridge--read-sexp-entries)
    ("read.clock-status"      . eav-bridge--read-clock-status)
    ("read.tasks"             . eav-bridge--read-tasks)
    ("read.tasks-for-file"    . eav-bridge--read-tasks-for-file)
    ("read.agenda-day"        . eav-bridge--read-agenda-day)
    ("read.agenda-range"      . eav-bridge--read-agenda-range)

    ;; --- writes ---
    ("write.set-state"        . eav-bridge--write-set-state)
    ("write.set-priority"     . eav-bridge--write-set-priority)
    ("write.set-title"        . eav-bridge--write-set-title)
    ("write.set-tags"         . eav-bridge--write-set-tags)
    ("write.set-scheduled"    . eav-bridge--write-set-scheduled)
    ("write.set-deadline"     . eav-bridge--write-set-deadline)
    ("write.set-property"     . eav-bridge--write-set-property)
    ("write.set-notes"        . eav-bridge--write-set-notes)
    ("write.refile"           . eav-bridge--write-refile)
    ("write.archive"          . eav-bridge--write-archive)
    ("write.capture"          . eav-bridge--write-capture)
    ("write.insert-entry"     . eav-bridge--write-insert-entry)
    ("write.clock-in"         . eav-bridge--write-clock-in)
    ("write.clock-out"        . eav-bridge--write-clock-out)
    ("write.clock-log"        . eav-bridge--write-clock-log)
    ("write.clock-tidy"       . eav-bridge--write-clock-tidy)

    ;; --- meta ---
    ("ping"                   . eav-bridge--ping)
    ("hello"                  . eav-bridge--hello))
  "Mapping from wire method name to elisp dispatcher function.
Each handler receives one arg (the params alist) and returns either
the result alist on success, or `(error . (CODE . MESSAGE))' on failure.")

;; ----------------------------------------------------------------------------
;; Dispatcher implementations
;; ----------------------------------------------------------------------------

(defun eav-bridge--p (params key)
  "Read string PARAMS KEY (Lisp accessor for either symbol or string keys)."
  (or (cdr (assoc key params))
      (cdr (assq (intern key) params))))

(defun eav-bridge--p-int (params key)
  "Read PARAMS KEY as a number (accepts numeric or stringified int)."
  (let ((v (eav-bridge--p params key)))
    (cond ((numberp v) v)
          ((stringp v) (string-to-number v))
          (t nil))))

(defun eav-bridge--decode (json-str)
  "Decode JSON-STR returned by an eav-* function back into a Lisp object."
  (let ((json-object-type 'alist)
        (json-array-type 'vector)
        (json-key-type 'symbol))
    (json-read-from-string json-str)))

(defun eav-bridge--ping (_params)
  `((pong . t) (version . ,eav-bridge-protocol-version)))

(defun eav-bridge--hello (_params)
  `((name . "eav-bridge")
    (version . ,eav-bridge-protocol-version)
    (emacs . ,emacs-version)))

(defun eav-bridge--read-config (_params)
  `((files . ,(eav-bridge--decode (eav-get-agenda-files)))
    (keywords . ,(eav-bridge--decode (eav-get-todo-keywords)))
    (priorities . ,(eav-bridge--decode (eav-get-priorities)))
    (config . ,(eav-bridge--decode (eav-get-config)))
    (listConfig . ,(eav-bridge--decode (eav-get-list-config)))))

(defun eav-bridge--read-notes (params)
  (eav-bridge--decode
   (eav-get-heading-notes (eav-bridge--p params "file")
                          (eav-bridge--p-int params "pos"))))

(defun eav-bridge--read-outline-path (params)
  (eav-bridge--decode
   (eav-get-outline-path (eav-bridge--p params "file")
                         (eav-bridge--p-int params "pos"))))

(defun eav-bridge--read-refile-targets (_params)
  (eav-bridge--decode (eav-get-refile-targets)))

(defun eav-bridge--read-capture-templates (_params)
  (eav-bridge--decode (eav-get-capture-templates)))

(defun eav-bridge--read-clock-status (_params)
  (eav-bridge--decode (eav-clock-status)))

(defun eav-bridge--read-tasks (params)
  (let ((all (eav-bridge--p params "all")))
    (eav-bridge--decode
     (if (and all (not (eq all :json-false)))
         (eav-extract-all-tasks)
       (eav-extract-active-tasks)))))

(defun eav-bridge--read-tasks-for-file (params)
  (eav-bridge--decode
   (eav-extract-tasks-for-file (eav-bridge--p params "file"))))

(defun eav-bridge--read-agenda-day (params)
  (eav-bridge--decode
   (eav-get-agenda-day (eav-bridge--p params "date"))))

(defun eav-bridge--read-agenda-range (params)
  (eav-bridge--decode
   (eav-get-agenda-range (eav-bridge--p params "start")
                         (eav-bridge--p params "end"))))

(defun eav-bridge--read-sexp-entries (params)
  "Return sexp/diary entries that fire on PARAMS DATE.
Iterates `org-agenda-files', evaluating only `:sexp' entries via
`org-agenda-get-day-entries'."
  (require 'org-agenda)
  (let* ((date-string (eav-bridge--p params "date"))
         (date (eav--date-to-calendar date-string))
         (files (org-agenda-files nil 'ifmode))
         (results nil))
    (dolist (file files)
      (when (file-exists-p file)
        (catch 'nextfile
          (org-check-agenda-file file)
          (let ((entries (org-agenda-get-day-entries file date :sexp)))
            (dolist (entry entries)
              (let ((alist (eav--agenda-entry-to-alist entry)))
                (push (cons 'displayDate date-string) alist)
                (push alist results)))))))
    (vconcat (nreverse results))))

(defun eav-bridge--write-set-state (params)
  (eav-set-todo-state (eav-bridge--p params "file")
                      (eav-bridge--p-int params "pos")
                      (eav-bridge--p params "state"))
  '((success . t)))

(defun eav-bridge--write-set-priority (params)
  (eav-set-priority (eav-bridge--p params "file")
                    (eav-bridge--p-int params "pos")
                    (eav-bridge--p params "priority"))
  '((success . t)))

(defun eav-bridge--write-set-title (params)
  (eav-set-title (eav-bridge--p params "file")
                 (eav-bridge--p-int params "pos")
                 (eav-bridge--p params "title"))
  '((success . t)))

(defun eav-bridge--write-set-tags (params)
  (let ((tags (eav-bridge--p params "tags")))
    (eav-set-tags (eav-bridge--p params "file")
                  (eav-bridge--p-int params "pos")
                  (cond ((listp tags) tags)
                        ((vectorp tags) (append tags nil))
                        (t nil))))
  '((success . t)))

(defun eav-bridge--write-set-scheduled (params)
  (eav-set-scheduled (eav-bridge--p params "file")
                     (eav-bridge--p-int params "pos")
                     (eav-bridge--p params "timestamp"))
  '((success . t)))

(defun eav-bridge--write-set-deadline (params)
  (eav-set-deadline (eav-bridge--p params "file")
                    (eav-bridge--p-int params "pos")
                    (eav-bridge--p params "timestamp"))
  '((success . t)))

(defun eav-bridge--write-set-property (params)
  (eav-set-property (eav-bridge--p params "file")
                    (eav-bridge--p-int params "pos")
                    (eav-bridge--p params "key")
                    (eav-bridge--p params "value"))
  '((success . t)))

(defun eav-bridge--write-set-notes (params)
  (eav-bridge--decode
   (eav-set-heading-notes (eav-bridge--p params "file")
                          (eav-bridge--p-int params "pos")
                          (or (eav-bridge--p params "notes") ""))))

(defun eav-bridge--write-refile (params)
  (eav-refile-task (eav-bridge--p params "sourceFile")
                   (eav-bridge--p-int params "sourcePos")
                   (eav-bridge--p params "targetFile")
                   (eav-bridge--p-int params "targetPos"))
  '((success . t)))

(defun eav-bridge--write-archive (params)
  (eav-archive-task (eav-bridge--p params "file")
                    (eav-bridge--p-int params "pos"))
  '((success . t)))

(defun eav-bridge--write-capture (params)
  (let ((answers (eav-bridge--p params "promptAnswers")))
    (eav-capture (eav-bridge--p params "templateKey")
                 (eav-bridge--p params "title")
                 (eav-bridge--p params "priority")
                 (eav-bridge--p params "scheduled")
                 (eav-bridge--p params "deadline")
                 (cond ((listp answers) answers)
                       ((vectorp answers) (append answers nil))
                       (t nil))))
  '((success . t)))

(defun eav-bridge--write-insert-entry (params)
  (let ((olp (eav-bridge--p params "olp")))
    (eav-insert-entry (eav-bridge--p params "file")
                      (eav-bridge--p params "targetType")
                      (eav-bridge--p params "entryText")
                      (eav-bridge--p params "headline")
                      (cond ((listp olp) olp)
                            ((vectorp olp) (append olp nil))
                            (t nil))
                      (eav-bridge--p params "prepend")))
  '((success . t)))

(defun eav-bridge--write-clock-in (params)
  (eav-clock-in (eav-bridge--p params "file")
                (eav-bridge--p-int params "pos"))
  '((success . t)))

(defun eav-bridge--write-clock-out (_params)
  (eav-clock-out)
  '((success . t)))

(defun eav-bridge--write-clock-log (params)
  (eav-add-clock-entry (eav-bridge--p params "file")
                       (eav-bridge--p-int params "pos")
                       (eav-bridge--p-int params "start")
                       (eav-bridge--p-int params "end"))
  '((success . t)))

(defun eav-bridge--write-clock-tidy (params)
  (let* ((res (eav-tidy-clocks (eav-bridge--p params "file")
                               (eav-bridge--p-int params "pos")))
         (parsed (eav-bridge--decode res)))
    parsed))

;; ----------------------------------------------------------------------------
;; Frame I/O
;; ----------------------------------------------------------------------------

(defun eav-bridge--encode-u32be (n)
  "Encode N as a 4-byte big-endian unsigned integer string."
  (unibyte-string (logand (lsh n -24) #xff)
                  (logand (lsh n -16) #xff)
                  (logand (lsh n -8) #xff)
                  (logand n #xff)))

(defun eav-bridge--decode-u32be (str)
  "Decode the first 4 bytes of STR as a big-endian unsigned integer."
  (let* ((b0 (aref str 0))
         (b1 (aref str 1))
         (b2 (aref str 2))
         (b3 (aref str 3)))
    (logior (lsh b0 24) (lsh b1 16) (lsh b2 8) b3)))

(defun eav-bridge--send-frame (proc payload)
  "Send PAYLOAD (a string) to PROC framed with a u32-be length prefix."
  (let* ((bytes (encode-coding-string payload 'utf-8))
         (frame (concat (eav-bridge--encode-u32be (length bytes)) bytes)))
    (process-send-string proc frame)))

(defun eav-bridge--send-response (proc id ok payload-or-error)
  (let ((payload
         (json-encode
          (if ok
              `((id . ,id) (ok . t) (result . ,payload-or-error))
            `((id . ,id) (ok . :json-false)
              (error . ,(let ((code (car payload-or-error))
                              (msg (cdr payload-or-error)))
                          `((code . ,code) (message . ,msg)))))))))
    (eav-bridge--send-frame proc payload)))

(defun eav-bridge--push-event (event params)
  "Broadcast an event frame to every connected client."
  (let ((payload (json-encode `((event . ,event) (params . ,params)))))
    (dolist (entry eav-bridge--connections)
      (let ((proc (car entry)))
        (when (and proc (process-live-p proc))
          (ignore-errors (eav-bridge--send-frame proc payload)))))))

(defun eav-bridge--handle-message (proc raw)
  "Decode RAW JSON, dispatch the call, send the response over PROC."
  (let* ((json-object-type 'alist)
         (json-array-type 'vector)
         (json-key-type 'symbol)
         (msg (condition-case err (json-read-from-string raw)
                (error
                 (eav-bridge--send-response proc 0 nil
                  (cons "parse-error"
                        (format "json: %s" (error-message-string err))))
                 (signal (car err) (cdr err)))))
         (id (or (cdr (assq 'id msg)) 0))
         (method (cdr (assq 'method msg)))
         (params (cdr (assq 'params msg))))
    (let ((handler (cdr (assoc method eav-bridge--methods))))
      (cond
       ((null handler)
        (eav-bridge--send-response
         proc id nil (cons "unknown-method" (format "no method %S" method))))
       (t
        (condition-case err
            (let ((result (funcall handler params)))
              (eav-bridge--send-response proc id t result))
          (error
           (eav-bridge--send-response
            proc id nil
            (cons "exception" (error-message-string err))))))))))

(defun eav-bridge--filter (proc input)
  "Process filter for incoming bytes; reassembles framed JSON requests."
  (let* ((entry (assq proc eav-bridge--connections))
         (buffer (cdr entry)))
    (unless buffer
      (setq buffer (generate-new-buffer (format " *eav-bridge-buf-%s*" proc)))
      (setf (alist-get proc eav-bridge--connections) buffer)
      (with-current-buffer buffer (set-buffer-multibyte nil)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (insert input)
      ;; Pull as many complete frames as we have.
      (let (continue)
        (setq continue t)
        (while (and continue (>= (- (point-max) (point-min)) 4))
          (goto-char (point-min))
          (let* ((header (buffer-substring-no-properties 1 5))
                 (len (eav-bridge--decode-u32be header)))
            (if (>= (- (point-max) (point-min)) (+ 4 len))
                (let ((payload (buffer-substring-no-properties 5 (+ 5 len))))
                  (delete-region (point-min) (+ 5 len))
                  (eav-bridge--handle-message
                   proc (decode-coding-string payload 'utf-8)))
              (setq continue nil))))))))

(defun eav-bridge--sentinel (proc event)
  "Track connection lifecycle. EVENT is the textual status string."
  (when (or (string-prefix-p "deleted" event)
            (string-prefix-p "connection broken" event)
            (string-prefix-p "failed" event)
            (string-prefix-p "killed" event)
            (string-prefix-p "finished" event))
    (let ((entry (assq proc eav-bridge--connections)))
      (when entry
        (when (buffer-live-p (cdr entry)) (kill-buffer (cdr entry)))
        (setq eav-bridge--connections
              (assq-delete-all proc eav-bridge--connections))))))

(defun eav-bridge--accept (server client _msg)
  "Accept a new client CLIENT on SERVER."
  (set-process-query-on-exit-flag client nil)
  (set-process-coding-system client 'binary 'binary)
  (setf (alist-get client eav-bridge--connections)
        (let ((b (generate-new-buffer (format " *eav-bridge-buf-%s*" client))))
          (with-current-buffer b (set-buffer-multibyte nil))
          b))
  (set-process-filter client #'eav-bridge--filter)
  (set-process-sentinel client #'eav-bridge--sentinel))

;; ----------------------------------------------------------------------------
;; Server lifecycle
;; ----------------------------------------------------------------------------

;;;###autoload
(defun eav-bridge-start (&optional path)
  "Start the bridge listening on PATH (or `eav-bridge-socket-path').
A previously-running server on the same socket is replaced."
  (interactive)
  (when eav-bridge--server
    (eav-bridge-stop))
  (let ((sock (or path eav-bridge-socket-path)))
    (when (file-exists-p sock)
      (delete-file sock))
    (setq eav-bridge--server
          (make-network-process
           :name "eav-bridge"
           :family 'local
           :service sock
           :server t
           :coding 'binary
           :sentinel #'eav-bridge--sentinel
           :log #'eav-bridge--accept))
    (eav-bridge--register-hooks)
    (message "eav-bridge listening on %s" sock)
    sock))

;;;###autoload
(defun eav-bridge-stop ()
  "Shut down the bridge."
  (interactive)
  (eav-bridge--unregister-hooks)
  (when eav-bridge--server
    (delete-process eav-bridge--server)
    (setq eav-bridge--server nil))
  (dolist (entry eav-bridge--connections)
    (when (process-live-p (car entry))
      (delete-process (car entry)))
    (when (buffer-live-p (cdr entry))
      (kill-buffer (cdr entry))))
  (setq eav-bridge--connections nil)
  (when (file-exists-p eav-bridge-socket-path)
    (ignore-errors (delete-file eav-bridge-socket-path)))
  (message "eav-bridge stopped"))

;; ----------------------------------------------------------------------------
;; Event hooks → server-pushed events
;; ----------------------------------------------------------------------------

(defun eav-bridge--on-after-save ()
  (when (and (derived-mode-p 'org-mode) buffer-file-name)
    (eav-bridge--push-event
     "after-save" `((file . ,buffer-file-name)))))

(defun eav-bridge--on-todo-state-change ()
  (when (and buffer-file-name (org-at-heading-p))
    (eav-bridge--push-event
     "todo-state-changed"
     `((file . ,buffer-file-name)
       (pos . ,(point))
       (state . ,(or (org-get-todo-state) :json-null))))))

(defun eav-bridge--on-clock-event (kind)
  (require 'org-clock)
  (let* ((marker (and (boundp 'org-clock-marker) org-clock-marker))
         (file (when (and marker (marker-buffer marker))
                 (buffer-file-name (marker-buffer marker))))
         (pos (when marker (marker-position marker))))
    (eav-bridge--push-event
     "clock-event"
     `((kind . ,kind)
       (file . ,(or file :json-null))
       (pos . ,(or pos :json-null))))))

(defvar eav-bridge--clock-in-handler
  (lambda () (eav-bridge--on-clock-event "in")))
(defvar eav-bridge--clock-out-handler
  (lambda () (eav-bridge--on-clock-event "out")))
(defvar eav-bridge--clock-cancel-handler
  (lambda () (eav-bridge--on-clock-event "cancel")))

(defun eav-bridge--register-hooks ()
  (add-hook 'after-save-hook #'eav-bridge--on-after-save)
  (add-hook 'org-after-todo-state-change-hook #'eav-bridge--on-todo-state-change)
  (with-eval-after-load 'org-clock
    (add-hook 'org-clock-in-hook eav-bridge--clock-in-handler)
    (add-hook 'org-clock-out-hook eav-bridge--clock-out-handler)
    (add-hook 'org-clock-cancel-hook eav-bridge--clock-cancel-handler)))

(defun eav-bridge--unregister-hooks ()
  (remove-hook 'after-save-hook #'eav-bridge--on-after-save)
  (remove-hook 'org-after-todo-state-change-hook #'eav-bridge--on-todo-state-change)
  (when (boundp 'org-clock-in-hook)
    (remove-hook 'org-clock-in-hook eav-bridge--clock-in-handler))
  (when (boundp 'org-clock-out-hook)
    (remove-hook 'org-clock-out-hook eav-bridge--clock-out-handler))
  (when (boundp 'org-clock-cancel-hook)
    (remove-hook 'org-clock-cancel-hook eav-bridge--clock-cancel-handler)))

(provide 'eav-bridge)
;;; eav-bridge.el ends here
