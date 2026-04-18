;;; eav-tests.el --- ERT tests for eav.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Fixture-based tests: each fixture file under tests/fixtures/ has one
;; heading per scenario, and each test looks up the relevant heading,
;; exercises the matching code path, and compares against an expected
;; result (either inline or from an :EXPECTED: property on the heading).
;;
;; Run with:
;;   npm test
;; or directly:
;;   emacs -batch -l ert -l elisp/eav-tests.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)

(defvar eav-tests--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this test file.")

(load (expand-file-name "eav.el" eav-tests--dir))

(defun eav-tests--fixture (name)
  "Return absolute path to fixture file NAME."
  (expand-file-name (concat "tests/fixtures/" name) eav-tests--dir))

(defun eav-tests--copy-fixture (name)
  "Copy fixture NAME to a fresh temp file and return its path.
Tests that MUTATE a fixture should use this so the committed fixture
stays untouched."
  (let* ((src (eav-tests--fixture name))
         (dst (make-temp-file "eav-test-" nil ".org")))
    (copy-file src dst t)
    dst))

(defun eav-tests--find-heading (file title)
  "Return the buffer position of heading with TITLE in FILE, or nil."
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char (point-min))
      (catch 'found
        (while (re-search-forward org-heading-regexp nil t)
          (when (equal (org-get-heading t t t t) title)
            (throw 'found (line-beginning-position))))
        nil))))

(defun eav-tests--heading-body (file title)
  "Return the body text of heading TITLE in FILE."
  (let ((pos (eav-tests--find-heading file title)))
    (when pos
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (goto-char pos)
          (eav--get-heading-content))))))

(defun eav-tests--heading-property (file title property)
  "Return PROPERTY value on heading TITLE in FILE."
  (let ((pos (eav-tests--find-heading file title)))
    (when pos
      (with-current-buffer (find-file-noselect file)
        (save-excursion
          (goto-char pos)
          (org-entry-get nil property))))))

(defun eav-tests--decode-expected (s)
  "Turn a literal `\\n' in S into a real newline — we store expected
values on a single line inside an org property drawer."
  (replace-regexp-in-string "\\\\n" "\n" s))

;;; ========================================================================
;;; Timestamp parsing — unit-level (no fixture needed)
;;; ========================================================================

(ert-deftest eav-parse-active-date-only ()
  (let ((ts (eav--parse-timestamp "<2026-04-18 Sat>")))
    (should (equal (alist-get 'type ts) "active"))
    (should (null (alist-get 'rangeType ts)))
    (should (equal (alist-get 'year (alist-get 'start ts)) 2026))
    (should (null (alist-get 'hour (alist-get 'start ts))))))

(ert-deftest eav-parse-active-with-time ()
  (let ((ts (eav--parse-timestamp "<2026-04-18 Sat 14:30>")))
    (should (equal (alist-get 'hour (alist-get 'start ts)) 14))
    (should (equal (alist-get 'minute (alist-get 'start ts)) 30))))

(ert-deftest eav-parse-inactive ()
  (should (equal (alist-get 'type (eav--parse-timestamp "[2026-04-18 Sat]"))
                 "inactive")))

(ert-deftest eav-parse-time-range-same-day ()
  (let ((ts (eav--parse-timestamp "<2026-04-18 Sat 14:30-16:00>")))
    (should (equal (alist-get 'type ts) "active-range"))
    (should (equal (alist-get 'rangeType ts) "timerange"))
    (should (equal (alist-get 'hour (alist-get 'end ts)) 16))
    (should (equal (alist-get 'day (alist-get 'end ts)) 18))))

(ert-deftest eav-parse-range-across-midnight ()
  (let ((ts (eav--parse-timestamp
             "<2026-04-18 Sat 19:00>--<2026-04-19 Sun 01:00>")))
    (should (equal (alist-get 'rangeType ts) "daterange"))
    (should (equal (alist-get 'day (alist-get 'start ts)) 18))
    (should (equal (alist-get 'day (alist-get 'end ts)) 19))))

(ert-deftest eav-parse-repeater-types ()
  "All three repeater syntaxes (+, ++, .+) round-trip."
  (dolist (case '(("<2026-04-18 Sat +1w>"  "+"  1 "w")
                  ("<2026-04-18 Sat ++1m>" "++" 1 "m")
                  ("<2026-04-18 Sat .+1d>" ".+" 1 "d")))
    (let* ((ts (eav--parse-timestamp (nth 0 case)))
           (rep (alist-get 'repeater ts)))
      (should (equal (alist-get 'type rep) (nth 1 case)))
      (should (equal (alist-get 'value rep) (nth 2 case)))
      (should (equal (alist-get 'unit rep) (nth 3 case))))))

(ert-deftest eav-parse-warning ()
  (let ((warn (alist-get 'warning
                         (eav--parse-timestamp "<2026-04-18 Sat -3d>"))))
    (should (equal (alist-get 'value warn) 3))
    (should (equal (alist-get 'unit warn) "d"))))

(ert-deftest eav-parse-empty-returns-nil ()
  (should (null (eav--parse-timestamp "")))
  (should (null (eav--parse-timestamp nil))))

;;; ========================================================================
;;; Calendar events — fixture-driven
;;; ========================================================================

(defun eav-tests--body-ts (title)
  "Return the active timestamps parsed from the body of TITLE in
calendar-events.org."
  (eav--extract-active-timestamps
   (eav-tests--heading-body (eav-tests--fixture "calendar-events.org") title)))

(defun eav-tests--planning (title key)
  "Return a parsed timestamp from planning line KEY (SCHEDULED/DEADLINE)
on heading TITLE in calendar-events.org."
  (let ((pos (eav-tests--find-heading
              (eav-tests--fixture "calendar-events.org") title)))
    (when pos
      (with-current-buffer (find-file-noselect
                            (eav-tests--fixture "calendar-events.org"))
        (save-excursion
          (goto-char pos)
          (eav--parse-timestamp (org-entry-get nil key)))))))

(ert-deftest eav-fixture-single-date ()
  (let* ((tss (eav-tests--body-ts "single date"))
         (ts (car tss)))
    (should (equal (length tss) 1))
    (should (equal (alist-get 'type ts) "active"))
    (should (null (alist-get 'hour (alist-get 'start ts))))))

(ert-deftest eav-fixture-date-with-time ()
  (let ((ts (car (eav-tests--body-ts "date with time"))))
    (should (equal (alist-get 'hour (alist-get 'start ts)) 14))
    (should (equal (alist-get 'minute (alist-get 'start ts)) 30))))

(ert-deftest eav-fixture-time-range-same-day ()
  (let ((ts (car (eav-tests--body-ts "time range same day"))))
    (should (equal (alist-get 'rangeType ts) "timerange"))
    (should (equal (alist-get 'hour (alist-get 'end ts)) 16))))

(ert-deftest eav-fixture-range-across-midnight ()
  "The motivating bug: `<a>--<b>' comes back as ONE entry with both ends,
not two separate timestamps."
  (let* ((tss (eav-tests--body-ts "range across midnight"))
         (ts (car tss)))
    (should (equal (length tss) 1))
    (should (equal (alist-get 'rangeType ts) "daterange"))
    (should (equal (alist-get 'day (alist-get 'start ts)) 18))
    (should (equal (alist-get 'hour (alist-get 'start ts)) 19))
    (should (equal (alist-get 'day (alist-get 'end ts)) 19))
    (should (equal (alist-get 'hour (alist-get 'end ts)) 1))))

(ert-deftest eav-fixture-multi-day-range-no-time ()
  (let ((ts (car (eav-tests--body-ts "multi-day range"))))
    (should (equal (alist-get 'rangeType ts) "daterange"))
    (should (null (alist-get 'hour (alist-get 'start ts))))
    (should (equal (alist-get 'day (alist-get 'end ts)) 22))))

(ert-deftest eav-fixture-repeaters ()
  (should (equal (alist-get 'type
                            (alist-get 'repeater
                                       (car (eav-tests--body-ts "repeater weekly"))))
                 "+"))
  (should (equal (alist-get 'type
                            (alist-get 'repeater
                                       (car (eav-tests--body-ts "repeater catch-up"))))
                 "++"))
  (should (equal (alist-get 'type
                            (alist-get 'repeater
                                       (car (eav-tests--body-ts "repeater restart"))))
                 ".+")))

(ert-deftest eav-fixture-warning ()
  (let ((warn (alist-get 'warning
                         (car (eav-tests--body-ts "warning period")))))
    (should (equal (alist-get 'value warn) 3))
    (should (equal (alist-get 'unit warn) "d"))))

(ert-deftest eav-fixture-scheduled-planning ()
  "SCHEDULED: planning lines parse through `eav--parse-timestamp' too —
not just bracketed timestamps in the body."
  (let ((s (eav-tests--planning "scheduled only" "SCHEDULED")))
    (should (equal (alist-get 'type s) "active"))
    (should (equal (alist-get 'day (alist-get 'start s)) 18))))

(ert-deftest eav-fixture-deadline-with-warning ()
  (let* ((d (eav-tests--planning "deadline with warning" "DEADLINE"))
         (warn (alist-get 'warning d)))
    (should (equal (alist-get 'value warn) 3))
    (should (equal (alist-get 'unit warn) "d"))))

(ert-deftest eav-fixture-scheduled-with-repeater ()
  (let ((rep (alist-get 'repeater
                        (eav-tests--planning "scheduled with repeater" "SCHEDULED"))))
    (should (equal (alist-get 'type rep) ".+"))
    (should (equal (alist-get 'unit rep) "d"))))

(ert-deftest eav-fixture-multiple-timestamps ()
  (let ((tss (eav-tests--body-ts "multiple timestamps in body")))
    (should (equal (length tss) 2))
    (should (equal (alist-get 'day (alist-get 'start (nth 0 tss))) 18))
    (should (equal (alist-get 'day (alist-get 'start (nth 1 tss))) 20))))

(ert-deftest eav-fixture-inactive-ignored-in-body ()
  "`eav--extract-active-timestamps' only picks up active `<>' timestamps,
since `org-ts-regexp' doesn't match inactive `[]'."
  (let ((tss (eav-tests--body-ts "inactive timestamp in body")))
    (should (equal (length tss) 1))
    (should (equal (alist-get 'type (car tss)) "active"))))

(ert-deftest eav-fixture-event-with-location ()
  "A calendar-style event (timestamp range on one line, location on the
next) parses the timestamp without being confused by the following text."
  (let* ((title "event with location")
         (tss (eav-tests--body-ts title))
         (ts (car tss))
         (body (eav-tests--heading-body
                (eav-tests--fixture "calendar-events.org") title)))
    (should (equal (length tss) 1))
    (should (equal (alist-get 'rangeType ts) "daterange"))
    (should (string-match-p "Bissy Common Fremont" body))))

;;; ========================================================================
;;; Nested checklists — fixture-driven propagation tests
;;; ========================================================================

(defun eav-tests--run-propagation (title)
  "Load the nested-lists fixture, save the body of TITLE verbatim (which
triggers `eav--propagate-checkbox-parents'), then return the resulting
body with leading/trailing blank lines trimmed."
  (let* ((tmp (eav-tests--copy-fixture "nested-lists.org"))
         (pos (eav-tests--find-heading tmp title))
         (body (eav-tests--heading-body tmp title))
         result)
    (unwind-protect
        (progn
          (eav-set-heading-notes tmp pos body)
          (setq result (eav-tests--heading-body tmp title)))
      ;; Cleanup: kill buffer without saving (already saved by set-heading-notes
      ;; but we don't want it writing back to tmp post-test) and remove tmp file.
      (let ((buf (get-file-buffer tmp)))
        (when buf
          (with-current-buffer buf (set-buffer-modified-p nil))
          (kill-buffer buf)))
      (when (file-exists-p tmp) (delete-file tmp)))
    (string-trim (or result ""))))

(defun eav-tests--expected-for (title)
  "Fetch the :EXPECTED: property for TITLE in the nested-lists fixture,
decoding embedded `\\n' back into real newlines."
  (eav-tests--decode-expected
   (or (eav-tests--heading-property
        (eav-tests--fixture "nested-lists.org") title "EXPECTED")
       (error "Fixture heading %s has no :EXPECTED: property" title))))

(defmacro eav-tests--define-propagation-test (name title)
  "Define an ERT test NAME that compares propagation output for TITLE
against that heading's :EXPECTED: property."
  `(ert-deftest ,name ()
     (let ((actual (eav-tests--run-propagation ,title))
           (expected (eav-tests--expected-for ,title)))
       (should (equal actual expected)))))

(eav-tests--define-propagation-test
 eav-nested-dash-all-checked
 "dash: all children checked → parent X")

(eav-tests--define-propagation-test
 eav-nested-dash-mixed
 "dash: mixed children → parent dash")

(eav-tests--define-propagation-test
 eav-nested-dash-all-unchecked
 "dash: all children unchecked → parent stays blank")

(eav-tests--define-propagation-test
 eav-nested-dash-in-progress-child
 "dash: one in-progress child → parent dash")

(eav-tests--define-propagation-test
 eav-nested-plus-all-checked
 "plus: all children checked → parent X")

(eav-tests--define-propagation-test
 eav-nested-plus-mixed
 "plus: mixed → parent dash")

(eav-tests--define-propagation-test
 eav-nested-star-indented
 "star-indented: all checked → parent X")

(eav-tests--define-propagation-test
 eav-nested-ordered-dot
 "ordered numeric dot: all checked → parent X")

(eav-tests--define-propagation-test
 eav-nested-ordered-paren
 "ordered numeric paren: all checked → parent X")

(eav-tests--define-propagation-test
 eav-nested-three-level-all-checked
 "three-level all checked → all ancestors X")

(eav-tests--define-propagation-test
 eav-nested-three-level-mixed
 "three-level mixed → chain of dashes")

(eav-tests--define-propagation-test
 eav-nested-mixed-bullet-styles
 "mixed bullet styles in one list")

(provide 'eav-tests)
;;; eav-tests.el ends here
