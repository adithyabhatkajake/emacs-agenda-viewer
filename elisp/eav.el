;;; eav.el --- Emacs Agenda Viewer data extraction -*- lexical-binding: t; -*-

;;; Commentary:
;; Provides functions to extract org-mode agenda data as JSON for the
;; Emacs Agenda Viewer web frontend.

;;; Code:

(require 'org)
(require 'org-element)
(require 'json)

(defun eav--ts-component (year month day hour minute)
  "Build an alist for one end of a timestamp.
Omits HOUR/MINUTE when nil so consumers can distinguish date-only from
timed timestamps."
  (let ((parts `((year . ,year) (month . ,month) (day . ,day))))
    (when hour (setq parts (append parts `((hour . ,hour)))))
    (when minute (setq parts (append parts `((minute . ,minute)))))
    parts))

(defun eav--unit-to-char (unit-sym)
  "Map a repeater/warning unit symbol (`hour', `day', ...) to org's single-char form."
  (pcase unit-sym
    ('hour "h") ('day "d") ('week "w") ('month "m") ('year "y")
    (_ (and unit-sym (substring (symbol-name unit-sym) 0 1)))))

(defun eav--repeater-type-to-string (sym)
  "Map an org-element repeater-type symbol to its source syntax."
  (pcase sym
    ('cumulate "+") ('catch-up "++") ('restart ".+")
    (_ (and sym (symbol-name sym)))))

(defun eav--timestamp-element-to-alist (ts)
  "Convert an org-element timestamp TS into a JSON-friendly alist.
Uses org's own parser output, so range/time-of-day/repeater/warning
info comes straight from org without any regex re-parsing."
  (when ts
    (let* ((raw (org-element-property :raw-value ts))
           (type (org-element-property :type ts))
           (range-type (org-element-property :range-type ts))
           (y1 (org-element-property :year-start ts))
           (m1 (org-element-property :month-start ts))
           (d1 (org-element-property :day-start ts))
           (h1 (org-element-property :hour-start ts))
           (mn1 (org-element-property :minute-start ts))
           (y2 (org-element-property :year-end ts))
           (m2 (org-element-property :month-end ts))
           (d2 (org-element-property :day-end ts))
           (h2 (org-element-property :hour-end ts))
           (mn2 (org-element-property :minute-end ts))
           (rep-type (org-element-property :repeater-type ts))
           (rep-value (org-element-property :repeater-value ts))
           (rep-unit (org-element-property :repeater-unit ts))
           (warn-value (org-element-property :warning-value ts))
           (warn-unit (org-element-property :warning-unit ts))
           ;; Preserve legacy `date' field: the first bracket substring.
           (date-part (and raw
                           (string-match org-ts-regexp-both raw)
                           (match-string 0 raw)))
           (result `((raw . ,raw)
                     (date . ,(or date-part raw))
                     (type . ,(and type (symbol-name type)))
                     (start . ,(eav--ts-component y1 m1 d1 h1 mn1)))))
      (when range-type
        (push (cons 'rangeType (symbol-name range-type)) result))
      (when (or y2 m2 d2)
        (push (cons 'end (eav--ts-component y2 m2 d2 h2 mn2)) result))
      (when (and rep-type (not (eq rep-type 'none)))
        (push (cons 'repeater
                    `((type . ,(eav--repeater-type-to-string rep-type))
                      (value . ,rep-value)
                      (unit . ,(eav--unit-to-char rep-unit))))
              result))
      (when (and warn-value warn-unit)
        (push (cons 'warning
                    `((value . ,warn-value)
                      (unit . ,(eav--unit-to-char warn-unit))))
              result))
      (nreverse result))))

(defun eav--parse-timestamp (ts-string)
  "Parse an org timestamp TS-STRING into a structured alist.
Delegates to `org-element-timestamp-parser' so range/time-of-day/repeater
/warning semantics match org's own interpretation."
  (when (and ts-string (not (string-empty-p ts-string)))
    (with-temp-buffer
      (insert ts-string)
      (goto-char (point-min))
      (eav--timestamp-element-to-alist (org-element-timestamp-parser)))))

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
  "Extract active timestamps and ranges from TEXT.
Returns a list of parsed timestamp alists. Uses org's own parser so
`<a>--<b>' ranges come back as a single structured entry."
  (when text
    (let (timestamps)
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (while (re-search-forward org-ts-regexp nil t)
          (goto-char (match-beginning 0))
          (let ((ts (org-element-timestamp-parser)))
            (if ts
                (progn
                  (push (eav--timestamp-element-to-alist ts) timestamps)
                  (goto-char (or (org-element-property :end ts)
                                 (match-end 0))))
              (goto-char (match-end 0))))))
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
      ;; Custom properties (skip the org built-ins already surfaced separately).
      (let* ((all-props (org-entry-properties nil 'standard))
             (skip '("CATEGORY" "ID" "EFFORT"))
             (filtered (cl-remove-if (lambda (kv) (member (car kv) skip)) all-props)))
        (when filtered
          (push (cons 'properties filtered) result)))
      result)))

(defun eav-set-property (file pos key value)
  "Set custom property KEY to VALUE on the heading at POS in FILE.
If VALUE is the empty string, the property is removed."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char pos)
      (org-back-to-heading t)
      (if (or (null value) (string-empty-p value))
          (org-entry-delete nil key)
        (org-entry-put nil key value))
      (save-buffer)))
  (json-encode '((success . t))))

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

(defun eav--format-clock-stamp (epoch)
  "Format EPOCH (integer seconds) as an inactive org timestamp string."
  (format-time-string "[%Y-%m-%d %a %H:%M]" (seconds-to-time epoch)))

(defun eav-add-clock-entry (file pos start-epoch end-epoch)
  "Append a CLOCK line to the LOGBOOK drawer of the heading at POS in FILE.
START-EPOCH and END-EPOCH are integer Unix timestamps (seconds).
Mirrors the format `org-clock-out' produces: `CLOCK: [start]--[end] =>  H:MM'."
  (require 'org-clock)
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char pos)
      (org-back-to-heading t)
      (let* ((start (eav--format-clock-stamp start-epoch))
             (end   (eav--format-clock-stamp end-epoch))
             (secs  (max 0 (- end-epoch start-epoch)))
             (mins  (/ secs 60))
             (h     (/ mins 60))
             (m     (mod mins 60))
             (line  (format "CLOCK: %s--%s =>  %d:%02d" start end h m)))
        ;; Find or create LOGBOOK drawer; insert as the first entry inside it.
        (let* ((element (org-element-at-point))
               (end-of-meta (save-excursion
                              (org-end-of-meta-data t)
                              (point))))
          (goto-char end-of-meta)
          (if (save-excursion
                (goto-char (org-entry-beginning-position))
                (re-search-forward "^[ \t]*:LOGBOOK:[ \t]*$"
                                   (save-excursion (outline-next-heading) (point))
                                   t))
              ;; Drawer exists — insert line right after :LOGBOOK:
              (progn
                (forward-line 1)
                (insert "  " line "\n"))
            ;; No drawer — create one
            (insert ":LOGBOOK:\n  " line "\n:END:\n"))))
      (save-buffer)))
  (json-encode '((success . t))))

(defun eav--propagate-checkbox-parents (beg end)
  "Fix parent checkbox states for all plain lists between BEG and END.
Delegates to `org-list-struct-fix-box' so parent items become [X] when every
descendant is checked, [-] when some descendants are checked or in-progress,
and [ ] otherwise — matching org's own cookie-aggregation behavior."
  (save-excursion
    (goto-char beg)
    (let ((seen-starts nil)
          (item-re "^[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\|[A-Za-z][.)]\\)[ \t]+\\[[ Xx-]\\]"))
      (while (re-search-forward item-re end t)
        (let ((line-start (line-beginning-position)))
          (save-excursion
            (goto-char line-start)
            (let* ((struct (ignore-errors (org-list-struct)))
                   (list-beg (and struct (caar struct))))
              (when (and struct list-beg (not (member list-beg seen-starts)))
                (push list-beg seen-starts)
                (let ((parents (org-list-parents-alist struct))
                      (prevs (org-list-prevs-alist struct))
                      (old-struct (copy-tree struct)))
                  (org-list-struct-fix-box struct parents prevs)
                  (org-list-struct-apply-struct struct old-struct))))))))))

(defun eav-get-heading-notes (file pos)
  "Get the notes/body content of heading at POS in FILE as JSON.
Also returns parsed active timestamps found in the body so the frontend
can render them as formatted chips without re-parsing."
  (let ((notes nil)
        (timestamps nil))
    (when (file-exists-p file)
      (with-current-buffer (find-file-noselect file)
        (goto-char pos)
        (setq notes (eav--get-heading-content))
        (setq timestamps (eav--extract-active-timestamps notes))))
    (json-encode `((notes . ,(or notes ""))
                   (activeTimestamps . ,(vconcat (or timestamps [])))))))

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
              (let ((insert-beg (point)))
                (insert new-notes "\n")
                ;; Propagate parent checkbox states via org's list machinery.
                (eav--propagate-checkbox-parents insert-beg (point)))))))
      (save-buffer)
      ;; Re-read body so the caller sees the propagated parent states.
      (goto-char pos)
      (let* ((final (eav--get-heading-content))
             (timestamps (eav--extract-active-timestamps final)))
        (json-encode `((success . t)
                       (notes . ,(or final ""))
                       (activeTimestamps . ,(vconcat (or timestamps [])))))))))

(defun eav-get-refile-targets ()
  "Return refile targets as JSON.
Each target is an alist with name, file, and pos."
  (require 'org-refile)
  ;; org-refile-get-targets needs to be called from an org buffer
  (let* ((default-buf (org-get-agenda-file-buffer (car (org-agenda-files))))
         (targets (with-current-buffer default-buf
                    (org-refile-get-targets default-buf)))
         results)
    (dolist (target targets)
      (let* ((name (nth 0 target))
             (file (nth 1 target))
             (raw-pos (nth 3 target))
             (pos (cond ((markerp raw-pos) (marker-position raw-pos))
                        ((numberp raw-pos) raw-pos)
                        (t nil))))
        (when (and file pos)
          (push (list (cons 'name name)
                      (cons 'file (expand-file-name file))
                      (cons 'pos pos))
                results))))
    (json-encode (vconcat (nreverse results)))))

(defun eav-refile-to-target (source-file source-pos target-file target-pos)
  "Refile heading at SOURCE-POS in SOURCE-FILE to TARGET-POS in TARGET-FILE."
  (let ((target-name ""))
    (with-current-buffer (find-file-noselect source-file)
      (goto-char source-pos)
      (org-back-to-heading t)
      (org-refile nil nil (list target-name target-file nil target-pos))
      (save-buffer))
    ;; Save target buffer too
    (with-current-buffer (find-file-noselect target-file)
      (save-buffer)))
  (json-encode '((success . t))))

(defun eav-set-title (file pos title)
  "Set the heading title at POS in FILE to TITLE.
Preserves TODO state, priority, and tags."
  (with-current-buffer (find-file-noselect file)
    (goto-char pos)
    (org-back-to-heading t)
    (org-edit-headline title)
    (save-buffer))
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

;;; ---- Capture ----

(defun eav--resolve-capture-file (file-spec)
  "Resolve FILE-SPEC from a capture template target to an absolute path.
Returns nil if the file cannot be resolved (e.g., it's a function)."
  (cond
   ((null file-spec) nil)
   ((stringp file-spec)
    (if (string-empty-p file-spec)
        (and (boundp 'org-default-notes-file)
             (expand-file-name org-default-notes-file org-directory))
      (expand-file-name file-spec org-directory)))
   ((symbolp file-spec)
    (let ((val (and (boundp file-spec) (symbol-value file-spec))))
      (when (stringp val)
        (expand-file-name val org-directory))))
   (t nil)))

(defun eav--parse-template-prompts (template-str)
  "Parse %^{prompt} fields from TEMPLATE-STR.
Returns a vector of alists with name, type, and options."
  (let (prompts)
    (when (stringp template-str)
      (with-temp-buffer
        (insert template-str)
        (goto-char (point-min))
        (while (re-search-forward "%\\^\\(?:{\\([^}]*\\)}\\)?\\([gGtTuUpCL]\\)?" nil t)
          (let* ((braces (match-string 1))
                 (key (match-string 2))
                 (parts (when braces (split-string braces "|")))
                 (name (or (car parts) ""))
                 (options (cdr parts))
                 (type (cond
                        ((member key '("g" "G")) "tags")
                        ((member key '("t" "T" "u" "U")) "date")
                        ((equal key "p") "property")
                        (t "string"))))
            (push (list (cons 'name name)
                        (cons 'type type)
                        (cons 'options (vconcat (or options []))))
                  prompts)))))
    (vconcat (nreverse prompts))))

(defun eav-get-capture-templates ()
  "Return org-capture-templates metadata as JSON."
  (require 'org-capture)
  (let (results)
    (dolist (entry org-capture-templates)
      (if (= (length entry) 2)
          ;; Group header: ("n" "Capture Notes")
          (push (list (cons 'key (nth 0 entry))
                      (cons 'description (nth 1 entry))
                      (cons 'isGroup t)
                      (cons 'webSupported :json-false))
                results)
        ;; Full template entry
        (let* ((key (nth 0 entry))
               (desc (nth 1 entry))
               (type (symbol-name (nth 2 entry)))
               (target (nth 3 entry))
               (template (nth 4 entry))
               (plist (nthcdr 5 entry))
               (target-type (symbol-name (car target)))
               (target-file (eav--resolve-capture-file (nth 1 target)))
               (target-headline (when (member (car target)
                                              '(file+headline file+olp))
                                  (let ((h (nth 2 target)))
                                    (cond ((stringp h) h)
                                          ((and (symbolp h) (boundp h))
                                           (symbol-value h))
                                          (t nil)))))
               (template-str (when (stringp template) template))
               (template-is-fn (and (listp template)
                                    (eq (car template) 'function)))
               (target-is-fn (member (car target) '(function)))
               (web-supported (and (not target-is-fn)
                                   (not template-is-fn)
                                   target-file
                                   (stringp template)))
               (prompts (eav--parse-template-prompts template-str))
               (result (list (cons 'key key)
                             (cons 'description desc)
                             (cons 'type type)
                             (cons 'isGroup :json-false)
                             (cons 'targetType target-type)
                             (cons 'webSupported (if web-supported t :json-false))
                             (cons 'prompts prompts))))
          (when target-file
            (push (cons 'targetFile target-file) result))
          (when target-headline
            (push (cons 'targetHeadline target-headline) result))
          (when template-str
            (push (cons 'template template-str) result))
          (when template-is-fn
            (push (cons 'templateIsFunction t) result))
          (push (nreverse result) results))))
    (json-encode (vconcat (nreverse results)))))

(defun eav-capture (template-key title &optional priority scheduled deadline)
  "Execute org-capture non-interactively for TEMPLATE-KEY.
TITLE is inserted where %? would be.
PRIORITY is a single character string (\"A\", \"B\", etc.) or nil.
SCHEDULED and DEADLINE are org timestamp strings or nil.

Flow: org-capture runs its full pipeline --
  1. `org-capture-fill-template' expands %u, %t, %<...>, %a, %i, %^{...}
  2. `org-capture-place-entry' inserts the expanded template into the target buffer
  3. `org-capture--position-cursor' finds %? -- we advise this to insert TITLE there
  4. `:immediate-finish' causes `org-capture-finalize' to save and clean up
  5. After finalize, we visit the captured entry to set priority/scheduled/deadline"
  (require 'org-capture)
  (let* ((entry (assoc template-key org-capture-templates))
         (plist (nthcdr 5 entry))
         (had-immediate (plist-get plist :immediate-finish)))
    (unless entry
      (error "Unknown capture template key: %s" template-key))
    ;; Temporarily force :immediate-finish
    (unless had-immediate
      (setcdr (nthcdr 4 entry)
              (plist-put (copy-sequence plist) :immediate-finish t)))
    (unwind-protect
        ;; Advise org-capture--position-cursor to insert TITLE at %?
        ;; instead of just removing %? (which is the default behavior)
        (cl-letf (((symbol-function 'org-capture--position-cursor)
                   (lambda (beg end)
                     (goto-char beg)
                     (when (search-forward "%?" end t)
                       (replace-match title t t)))))
          (org-capture nil template-key))
      ;; Restore original plist
      (unless had-immediate
        (setcdr (nthcdr 4 entry) plist)))
    ;; Set priority/scheduled/deadline on the captured entry
    (when (or priority scheduled deadline)
      (let ((marker org-capture-last-stored-marker))
        (when (and marker (marker-buffer marker))
          (with-current-buffer (marker-buffer marker)
            (save-excursion
              (goto-char marker)
              (org-back-to-heading t)
              (when priority
                (org-priority (string-to-char priority)))
              (when scheduled
                (org-schedule nil scheduled))
              (when deadline
                (org-deadline nil deadline))
              (save-buffer))))))
    (json-encode '((success . t)))))

(provide 'eav)
;;; eav.el ends here
