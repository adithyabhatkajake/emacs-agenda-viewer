;;; eav.el --- Emacs Agenda Viewer data extraction -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides functions to extract org-mode agenda data as JSON for the
;; Emacs Agenda Viewer web frontend.

;;; Code:

(require 'org)
(require 'json)

(defun eav--parse-timestamp (ts-string)
  "Parse an org timestamp string TS-STRING into an alist.
Handles repeaters (.+1d) and warning periods (-3d)."
  (when (and ts-string (string-match org-ts-regexp-both ts-string))
    (let* ((date-part (match-string 0 ts-string))
           (result `((raw . ,ts-string)
                     (date . ,date-part)))
           ;; Extract repeater if present: .+1d, ++1w, +1m etc.
           (repeater (when (string-match
                           "\\([.+]?\\+\\)\\([0-9]+\\)\\([hdwmy]\\)"
                           ts-string)
                       `((type . ,(match-string 1 ts-string))
                         (value . ,(string-to-number (match-string 2 ts-string)))
                         (unit . ,(match-string 3 ts-string)))))
           ;; Extract warning period if present: -3d
           (warning (when (string-match
                          "-\\([0-9]+\\)\\([hdwmy]\\)"
                          ts-string)
                      `((value . ,(string-to-number (match-string 1 ts-string)))
                        (unit . ,(match-string 2 ts-string))))))
      (when repeater
        (push (cons 'repeater repeater) result))
      (when warning
        (push (cons 'warning warning) result))
      result)))

(defun eav--get-heading-content ()
  "Get the body content of the current heading (excluding subheadings, drawers, and planning).
Collects non-drawer, non-planning text lines."
  (save-excursion
    (let* ((element (org-element-at-point))
           (contents-begin (org-element-property :contents-begin element))
           (contents-end (org-element-property :contents-end element))
           (lines nil))
      (when (and contents-begin contents-end)
        (goto-char contents-begin)
        ;; Find the end of body (before subheadings)
        (let ((body-end (save-excursion
                          (if (re-search-forward org-heading-regexp contents-end t)
                              (line-beginning-position)
                            contents-end))))
          (while (< (point) body-end)
            (cond
             ;; Skip planning lines
             ((looking-at "^[ \t]*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):")
              (forward-line 1))
             ;; Skip drawers (:PROPERTIES:, :LOGBOOK:, etc.)
             ((looking-at "^[ \t]*:[A-Z_]+:[ \t]*$")
              (if (re-search-forward "^[ \t]*:END:" body-end t)
                  (forward-line 1)
                (forward-line 1)))
             ;; Collect regular lines
             (t
              (push (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))
                    lines)
              (forward-line 1))))))
      (let ((text (string-trim (mapconcat #'identity (nreverse lines) "\n"))))
        (if (string-empty-p text) nil text)))))

(defun eav--extract-active-timestamps (text)
  "Extract active timestamps (not SCHEDULED/DEADLINE) from TEXT.
Returns a list of parsed timestamp alists."
  (when text
    (let (timestamps)
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (while (re-search-forward org-ts-regexp nil t)
          (let ((ts (match-string 0)))
            (push (eav--parse-timestamp ts) timestamps))))
      (nreverse timestamps))))

(defun eav--extract-task-at-point ()
  "Extract task data at point as an alist."
  (let* ((title (org-get-heading t t t t))
         (todo-state (org-get-todo-state))
         (priority (org-element-property :priority (org-element-at-point)))
         (local-tags (org-get-tags nil t))
         (all-tags (org-get-tags))
         (inherited-tags (seq-difference all-tags local-tags))
         (scheduled-str (org-entry-get nil "SCHEDULED"))
         (deadline-str (org-entry-get nil "DEADLINE"))
         (closed-str (org-entry-get nil "CLOSED"))
         (category (org-get-category))
         (level (org-current-level))
         (id (or (org-entry-get nil "ID") nil))
         (effort (org-entry-get nil "EFFORT"))
         (file (buffer-file-name))
         (pos (point))
         (parent-id nil)
         (notes (eav--get-heading-content))
         (active-timestamps (eav--extract-active-timestamps notes)))
    ;; Get parent heading info for hierarchy
    (save-excursion
      (when (and (> level 1) (org-up-heading-safe))
        (setq parent-id (or (org-entry-get nil "ID")
                            (format "%s::%d" file (point))))))
    ;; Build result - use json-null for null values, empty string fallback
    ;; where nil would be confused with empty list by json-encode
    (let ((result (list (cons 'id (or id (format "%s::%d" file pos)))
                        (cons 'title title)
                        (cons 'tags (vconcat local-tags))
                        (cons 'inheritedTags (vconcat inherited-tags))
                        (cons 'category category)
                        (cons 'level level)
                        (cons 'file file)
                        (cons 'pos pos))))
      ;; Add optional fields - only include if they have values
      (when todo-state (push (cons 'todoState todo-state) result))
      (when priority (push (cons 'priority (char-to-string priority)) result))
      (when scheduled-str
        (push (cons 'scheduled (eav--parse-timestamp scheduled-str)) result))
      (when deadline-str
        (push (cons 'deadline (eav--parse-timestamp deadline-str)) result))
      (when closed-str (push (cons 'closed closed-str) result))
      (when parent-id (push (cons 'parentId parent-id) result))
      (when effort (push (cons 'effort effort) result))
      (when notes (push (cons 'notes notes) result))
      (when active-timestamps
        (push (cons 'activeTimestamps (vconcat active-timestamps)) result))
      result)))

(defun eav-extract-all-tasks ()
  "Extract all tasks from agenda files as a JSON string."
  (let (results)
    (dolist (file (org-agenda-files))
      (when (file-exists-p file)
        (with-current-buffer (org-get-agenda-file-buffer file)
          (org-map-entries
           (lambda ()
             (push (eav--extract-task-at-point) results))
           nil 'file))))
    (json-encode (vconcat (nreverse results)))))

(defun eav-extract-active-tasks ()
  "Extract only non-DONE/non-KILL tasks from agenda files as JSON."
  (let (results)
    (dolist (file (org-agenda-files))
      (when (file-exists-p file)
        (with-current-buffer (org-get-agenda-file-buffer file)
          (org-map-entries
           (lambda ()
             (let ((state (org-get-todo-state)))
               (unless (member state '("DONE" "KILL" "[X]"))
                 (push (eav--extract-task-at-point) results))))
           nil 'file))))
    (json-encode (vconcat (nreverse results)))))

(defun eav-extract-tasks-for-file (file)
  "Extract tasks from a specific FILE as JSON."
  (let (results)
    (when (file-exists-p file)
      (with-current-buffer (org-get-agenda-file-buffer file)
        (org-map-entries
         (lambda ()
           (push (eav--extract-task-at-point) results))
         nil 'file)))
    (json-encode (vconcat (nreverse results)))))

(defun eav-get-agenda-files ()
  "Return agenda files as JSON."
  (let (results)
    (dolist (file (org-agenda-files))
      (when (file-exists-p file)
        (push `((path . ,file)
                (name . ,(file-name-base file))
                (category . ,(with-current-buffer (org-get-agenda-file-buffer file)
                               (or (org-get-category) (file-name-base file)))))
              results)))
    (json-encode (vconcat (nreverse results)))))

(defun eav-get-todo-keywords ()
  "Return configured TODO keywords as JSON."
  (json-encode
   `((sequences . ,(vconcat
                    (mapcar
                     (lambda (seq)
                       (let ((active nil)
                             (done nil)
                             (past-separator nil)
                             ;; Skip the first element (sequence/type/etc symbol)
                             (kws (cdr seq)))
                         (dolist (kw kws)
                           (if (string= kw "|")
                               (setq past-separator t)
                             (let ((clean-kw (replace-regexp-in-string "(.*)" "" kw)))
                               (if past-separator
                                   (push clean-kw done)
                                 (push clean-kw active)))))
                         `((active . ,(vconcat (nreverse active)))
                           (done . ,(vconcat (nreverse done))))))
                     org-todo-keywords))))))

(defun eav-get-config ()
  "Return org configuration values as JSON."
  (json-encode
   `((deadlineWarningDays . ,org-deadline-warning-days))))

(defun eav--agenda-entry-to-alist (entry)
  "Convert an org-agenda ENTRY string (with text properties) into an alist."
  (let* ((marker (get-text-property 0 'org-hd-marker entry))
         (file (when marker (buffer-file-name (marker-buffer marker))))
         (pos (when marker (marker-position marker)))
         (type (get-text-property 0 'type entry))
         (todo-state (get-text-property 0 'todo-state entry))
         ;; Priority: the text property 'priority is a computed urgency number, not
         ;; the character.  Read the actual priority from the heading via marker.
         (priority (when marker
                     (with-current-buffer (marker-buffer marker)
                       (save-excursion
                         (goto-char (marker-position marker))
                         (let ((p (org-element-property :priority (org-element-at-point))))
                           (when p (char-to-string p)))))))
         (tags-raw (get-text-property 0 'tags entry))
         (tags (cond
                ((null tags-raw) [])
                ((listp tags-raw)
                 ;; List of (possibly propertized) tag strings
                 (let (local inherited)
                   (dolist (tag tags-raw)
                     (let ((s (substring-no-properties tag)))
                       (if (get-text-property 0 'inherited tag)
                           (push s inherited)
                         (push s local))))
                   (vconcat (nreverse local))))
                ((stringp tags-raw)
                 (vconcat (split-string tags-raw ":" t)))
                (t [])))
         (category (or (get-text-property 0 'org-category entry) ""))
         (level (or (get-text-property 0 'level entry) 1))
         (effort (get-text-property 0 'effort entry))
         (warntime (get-text-property 0 'warntime entry))
         (time-of-day (get-text-property 0 'time-of-day entry))
         ;; extra contains org's computed date description like "In 3 d.:" or "1 d. ago:"
         (extra (let ((e (get-text-property 0 'extra entry)))
                  (when (and e (not (string-empty-p (string-trim e))))
                    (string-trim e))))
         ;; ts-date is the absolute date number for the triggering timestamp
         (ts-date-abs (get-text-property 0 'ts-date entry))
         (ts-date-str (when ts-date-abs
                        (let ((d (calendar-gregorian-from-absolute ts-date-abs)))
                          (format "%04d-%02d-%02d" (nth 2 d) (nth 0 d) (nth 1 d)))))
         (txt (get-text-property 0 'txt entry))
         ;; Clean the title: remove TODO keyword, priority cookie, and leading whitespace
         (title (if txt
                    (let ((clean (org-link-display-format (string-trim txt))))
                      ;; Remove leading TODO state + priority like "TODO [#A] "
                      (when (and todo-state (string-prefix-p todo-state clean))
                        (setq clean (string-trim-left (substring clean (length todo-state)))))
                      (when (string-match "^\\[#[A-Z]\\] " clean)
                        (setq clean (substring clean (match-end 0))))
                      ;; Remove trailing tag strings like "  :tag1:tag2:"
                      (when (string-match "\\s-+:[a-zA-Z0-9_@:]+:\\s-*$" clean)
                        (setq clean (substring clean 0 (match-beginning 0))))
                      (string-trim clean))
                  ""))
         ;; Extract inherited tags from the tags-raw property
         (inherited-tags (cond
                          ((and tags-raw (listp tags-raw))
                           (let (inherited)
                             (dolist (tag tags-raw)
                               (when (get-text-property 0 'inherited tag)
                                 (push (substring-no-properties tag) inherited)))
                             (vconcat (nreverse inherited))))
                          (t [])))
         ;; Get additional heading data from the marker
         (scheduled-str nil)
         (deadline-str nil)
         (id nil))
    ;; Visit the original heading to get scheduling/deadline/ID
    (when marker
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (goto-char pos)
          (setq scheduled-str (org-entry-get nil "SCHEDULED"))
          (setq deadline-str (org-entry-get nil "DEADLINE"))
          (setq id (org-entry-get nil "ID")))))
    ;; Build result
    (let ((result (list (cons 'id (or id (format "%s::%d" file pos)))
                        (cons 'title title)
                        (cons 'agendaType (or type ""))
                        (cons 'tags tags)
                        (cons 'inheritedTags inherited-tags)
                        (cons 'category category)
                        (cons 'level level)
                        (cons 'file (or file ""))
                        (cons 'pos (or pos 0)))))
      (when todo-state (push (cons 'todoState todo-state) result))
      (when priority (push (cons 'priority priority) result))
      (when scheduled-str
        (push (cons 'scheduled (eav--parse-timestamp scheduled-str)) result))
      (when deadline-str
        (push (cons 'deadline (eav--parse-timestamp deadline-str)) result))
      (when effort (push (cons 'effort effort) result))
      (when warntime (push (cons 'warntime warntime) result))
      (when time-of-day
        (push (cons 'timeOfDay (format "%02d:%02d"
                                       (/ time-of-day 100)
                                       (mod time-of-day 100)))
              result))
      (when extra (push (cons 'extra extra) result))
      (when ts-date-str (push (cons 'tsDate ts-date-str) result))
      result)))

(defun eav--date-to-calendar (date-string)
  "Convert DATE-STRING (YYYY-MM-DD) to calendar date (month day year)."
  (let ((parts (mapcar #'string-to-number (split-string date-string "-"))))
    (list (nth 1 parts) (nth 2 parts) (nth 0 parts))))

(defun eav-get-agenda-day (date-string)
  "Get all agenda entries for DATE-STRING (YYYY-MM-DD format) as JSON.
Uses org-agenda's own machinery to determine which entries appear."
  (require 'org-agenda)
  (let* ((date (eav--date-to-calendar date-string))
         (files (org-agenda-files nil 'ifmode))
         (all-entries nil))
    (dolist (file files)
      (when (file-exists-p file)
        (catch 'nextfile
          (org-check-agenda-file file)
          (let ((entries (org-agenda-get-day-entries
                          file date
                          :timestamp :scheduled :deadline :sexp)))
            (setq all-entries (append all-entries entries))))))
    (json-encode (vconcat (mapcar #'eav--agenda-entry-to-alist all-entries)))))

(defun eav-get-agenda-range (start-date end-date)
  "Get agenda entries for date range START-DATE to END-DATE (YYYY-MM-DD) as JSON."
  (require 'org-agenda)
  (let* ((start (eav--date-to-calendar start-date))
         (end (eav--date-to-calendar end-date))
         (files (org-agenda-files nil 'ifmode))
         (all-entries nil)
         ;; Iterate through each day in the range
         (current-abs (calendar-absolute-from-gregorian start))
         (end-abs (calendar-absolute-from-gregorian end)))
    (while (<= current-abs end-abs)
      (let ((date (calendar-gregorian-from-absolute current-abs))
            (day-entries nil))
        (dolist (file files)
          (when (file-exists-p file)
            (catch 'nextfile
              (org-check-agenda-file file)
              (let ((entries (org-agenda-get-day-entries
                              file date
                              :timestamp :scheduled :deadline :sexp)))
                (setq day-entries (append day-entries entries))))))
        ;; Tag each entry with the display date
        (dolist (entry day-entries)
          (let ((alist (eav--agenda-entry-to-alist entry)))
            (push (cons 'displayDate
                        (format "%04d-%02d-%02d" (nth 2 date) (nth 0 date) (nth 1 date)))
                  alist)
            (push alist all-entries))))
      (setq current-abs (1+ current-abs)))
    (json-encode (vconcat (nreverse all-entries)))))

(defun eav-clock-status ()
  "Return the current clock status as JSON."
  (require 'org-clock)
  (if (org-clocking-p)
      (let* ((marker org-clock-marker)
             (file (buffer-file-name (marker-buffer marker)))
             (pos (marker-position marker))
             (heading (substring-no-properties org-clock-heading))
             (start-time (float-time org-clock-start-time))
             (elapsed (floor (- (float-time) start-time))))
        (json-encode `((clocking . t)
                       (file . ,file)
                       (pos . ,pos)
                       (heading . ,heading)
                       (startTime . ,(format-time-string "%Y-%m-%dT%H:%M:%S" org-clock-start-time))
                       (elapsed . ,elapsed))))
    (json-encode '((clocking . :json-false)))))

(defun eav-clock-in (file pos)
  "Clock in to the heading at POS in FILE."
  (require 'org-clock)
  (with-current-buffer (find-file-noselect file)
    (goto-char pos)
    (org-clock-in))
  (json-encode '((success . t))))

(defun eav-clock-out ()
  "Clock out of the current task."
  (require 'org-clock)
  (when (org-clocking-p)
    (org-clock-out))
  (json-encode '((success . t))))

(defun eav-get-heading-notes (file pos)
  "Get the notes/body content of heading at POS in FILE as JSON."
  (let ((notes nil))
    (when (file-exists-p file)
      (with-current-buffer (find-file-noselect file)
        (goto-char pos)
        (setq notes (eav--get-heading-content))))
    (json-encode `((notes . ,(or notes ""))))))

(defun eav-set-heading-notes (file pos new-notes)
  "Set the notes/body content of heading at POS in FILE to NEW-NOTES.
Preserves planning lines, property drawers, and logbook drawers.
Replaces only the user-visible body text."
  (with-current-buffer (find-file-noselect file)
    (goto-char pos)
    (let* ((element (org-element-at-point))
           (contents-begin (org-element-property :contents-begin element))
           (contents-end (org-element-property :contents-end element))
           (user-regions nil))  ;; list of (start . end) for user text
      ;; If no contents area, create one after the heading line
      (if (not contents-begin)
          (progn
            (end-of-line)
            (insert "\n" new-notes "\n"))
        ;; Find all user-content regions (non-drawer, non-planning)
        (let ((body-end (save-excursion
                          (goto-char contents-begin)
                          (if (re-search-forward org-heading-regexp contents-end t)
                              (line-beginning-position)
                            contents-end)))
              (scan-pos contents-begin))
          (goto-char scan-pos)
          (while (< (point) body-end)
            (cond
             ;; Planning lines — skip
             ((looking-at "^[ \t]*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):")
              (forward-line 1))
             ;; Drawers — skip
             ((looking-at "^[ \t]*:[A-Z_]+:[ \t]*$")
              (if (re-search-forward "^[ \t]*:END:" body-end t)
                  (forward-line 1)
                (forward-line 1)))
             ;; User content line — mark region
             (t
              (let ((region-start (line-beginning-position)))
                ;; Advance through consecutive user lines
                (while (and (< (point) body-end)
                            (not (looking-at "^[ \t]*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):"))
                            (not (looking-at "^[ \t]*:[A-Z_]+:[ \t]*$")))
                  (forward-line 1))
                (push (cons region-start (point)) user-regions)))))
          ;; Delete user regions in reverse order (to preserve positions)
          (dolist (region (nreverse user-regions))
            (delete-region (car region) (cdr region)))
          ;; Insert new notes at the position of the first deleted region,
          ;; or after the last drawer/planning line
          (goto-char contents-begin)
          ;; Skip past planning and drawers to find insertion point
          (let ((insert-end (save-excursion
                              (if (re-search-forward org-heading-regexp contents-end t)
                                  (line-beginning-position)
                                contents-end))))
            (while (and (< (point) insert-end)
                        (or (looking-at "^[ \t]*\\(SCHEDULED\\|DEADLINE\\|CLOSED\\):")
                            (looking-at "^[ \t]*:[A-Z_]+:[ \t]*$")))
              (if (looking-at "^[ \t]*:[A-Z_]+:[ \t]*$")
                  (progn (re-search-forward "^[ \t]*:END:" insert-end t) (forward-line 1))
                (forward-line 1)))
            ;; Insert the new notes
            (when (and new-notes (not (string-empty-p new-notes)))
              (insert new-notes "\n")))))
      (save-buffer)))
  (json-encode '((success . t))))

(defun eav-set-todo-state (file pos state)
  "Set the TODO state of heading at POS in FILE to STATE."
  (with-current-buffer (find-file-noselect file)
    (goto-char pos)
    (org-todo state)
    (save-buffer))
  (json-encode '((success . t))))

(defun eav-set-priority (file pos priority)
  "Set the priority of heading at POS in FILE to PRIORITY character.
If PRIORITY is a space, remove the priority."
  (with-current-buffer (find-file-noselect file)
    (goto-char pos)
    (if (string= priority " ")
        (org-priority 'remove)
      (org-priority (string-to-char priority)))
    (save-buffer))
  (json-encode '((success . t))))

(defun eav-refile-task (source-file source-pos target-file target-pos)
  "Refile heading at SOURCE-POS in SOURCE-FILE to TARGET-POS in TARGET-FILE."
  (with-current-buffer (find-file-noselect source-file)
    (goto-char source-pos)
    (let ((org-refile-targets `((,target-file :maxlevel . 9))))
      (with-current-buffer (find-file-noselect target-file)
        (goto-char target-pos)
        (let ((rfloc (list
                      (org-get-heading t t t t)
                      target-file
                      nil
                      target-pos)))
          (with-current-buffer (find-file-noselect source-file)
            (goto-char source-pos)
            (org-refile nil nil rfloc)
            (save-buffer)))))
    (with-current-buffer (find-file-noselect target-file)
      (save-buffer)))
  (json-encode '((success . t))))

(defun eav-set-tags (file pos tags)
  "Set TAGS on heading at POS in FILE. TAGS is a list of tag strings."
  (with-current-buffer (find-file-noselect file)
    (goto-char pos)
    (org-set-tags tags)
    (save-buffer))
  (json-encode '((success . t))))

(defun eav-set-scheduled (file pos timestamp)
  "Set SCHEDULED timestamp on heading at POS in FILE.
If TIMESTAMP is empty, remove the scheduled date."
  (with-current-buffer (find-file-noselect file)
    (goto-char pos)
    (if (or (null timestamp) (string-empty-p timestamp))
        (org-schedule '(4))
      (org-schedule nil timestamp))
    (save-buffer))
  (json-encode '((success . t))))

(defun eav-set-deadline (file pos timestamp)
  "Set DEADLINE timestamp on heading at POS in FILE.
If TIMESTAMP is empty, remove the deadline."
  (with-current-buffer (find-file-noselect file)
    (goto-char pos)
    (if (or (null timestamp) (string-empty-p timestamp))
        (org-deadline '(4))
      (org-deadline nil timestamp))
    (save-buffer))
  (json-encode '((success . t))))

(provide 'eav)
;;; eav.el ends here
