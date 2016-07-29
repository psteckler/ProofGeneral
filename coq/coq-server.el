;;; -*- lexical-binding: t -*-

;; coq-server.el -- code related to server mode for Coq in Proof General

(require 'xml)
(require 'thingatpt)

(require 'coq-tq)
(require 'proof-queue)
(require 'proof-server)
(require 'proof-script)
(require 'pg-goals)
(require 'coq-response)
(require 'coq-stateinfo)
(require 'coq-xml)
(require 'cl-lib)

(eval-when-compile 
  (require 'cl))

(defvar coq-server--pending-edit-at-state-id nil
  "State id for an Edit_at command sent, until we get a response.")

(defvar coq-server--pending-add-count 0)

(defvar coq-server--start-of-focus-state-id nil
  "When re-opening a proof, this is the state id of the current focus.
If we undo to point before the span with this state id, the focus 
is gone and we have to close the secondary locked span."
  )

(defvar coq-server--current-span nil
  "Span associated with last response")

(defvar coq-server--retraction-on-error nil
  "Was the last retraction due to an error")

;; buffer for gluing coqtop responses into XML
;; leading space makes buffer invisible, for the most part
(defvar coq-server--response-buffer-name " *coq-responses*")
(defvar coq-server-response-buffer (get-buffer-create coq-server--response-buffer-name))

;; buffer for gluing coqtop out-of-band responses into XML
(defvar coq-server--oob-buffer-name " *coq-oob*")
(defvar coq-server-oob-buffer (get-buffer-create coq-server--oob-buffer-name))

(defvar coq-server-transaction-queue nil)

(defvar end-of-response-regexp "</value>")

;; we see feedback and value-fail messages twice, once for Goal, again for Status
;; see Bug 4850
;; process each one just once, because they have effects; use table to know if they've been seen
;; to prevent this table from taking too much space, we clear it just as each Add is sent
(defvar coq-server--error-fail-tbl (make-hash-table :test 'equal))

;; table mapping state ids to spans created by processingin feedbacks
;; we make values weak; spans can be deleted from buffer without necessarily
;;  deleting from this table
(defvar coq-server--processing-span-tbl (make-hash-table :test 'equal :weakness 'value))

;; table mapping state ids to spans
;; values are weak, because spans can be deleted, as on a retract
(defvar coq-server--span-state-id-tbl (make-hash-table :test 'equal :weakness 'key-and-value))

;; hook function to count how many Adds are pending
;; comments generate items with null element
(defun count-addable (items ct) ; helper for coq-server-count-pending-adds
  (if (null items)
      ct
    (let ((item (car items)))
      (if (nth 1 item)
	  (count-addable (cdr items) (1+ ct))
	(count-addable (cdr items) ct)))))

(defun coq-server-count-pending-adds ()
  (setq coq-server--pending-add-count (count-addable proof-action-list 0)))

;; not the *response* buffer seen by user
(defun coq-server--append-response (s)
  (goto-char (point-max))
  (insert s))

(defun coq-server--unescape-string (s)
  (replace-regexp-in-string "&nbsp;" " " s))

;; XML parser does not understand &nbsp;
(defun coq-server--unescape-buffer ()
  (let ((contents (buffer-string)))
    (erase-buffer)
    (insert (coq-server--unescape-string contents))
    (goto-char (point-min))))

(defun coq-server--get-next-xml ()
  (ignore-errors ; returns nil if no XML available
    (goto-char (point-min))
    (when (equal (current-buffer) coq-server-response-buffer)
      (message "BUFFER: %s" (buffer-string)))
    (let ((xml (xml-parse-tag-1)))
      (when xml
	(delete-region (point-min) (point))
	(when (equal (current-buffer) coq-server-response-buffer)
	  (message "AFTER DELETION, BUFFER: %s" (buffer-string))))
      xml)))

;; retract to particular state id, get Status, optionally get Goal
(defun coq-server--send-retraction (state-id &optional get-goal)
  (message "SENDING RETRACTION TO STATE: %s" state-id)
  (setq coq-server--pending-edit-at-state-id state-id)
  (proof-server-send-to-prover (coq-xml-edit-at state-id))
  (when get-goal
    (proof-server-send-to-prover (coq-xml-goal)))
  (proof-server-send-to-prover (coq-xml-status)))

(defun coq-server--clear-response-buffer ()
  (coq--display-response "")
  (pg-response-clear-displays))

(defun coq-server--clear-goals-buffer ()
  (pg-goals-display "" nil))

(defun coq-server-start-transaction-queue ()
  (setq coq-server-transaction-queue (tq-create proof-server-process 'coq-server-process-oob)))

;; clear response buffer when we Add an item from the Coq script
(add-hook 'proof-server-insert-hook 'coq-server--clear-response-buffer)
;; start transaction queue after coqtop process started
(add-hook 'proof-server-init-hook 'coq-server-start-transaction-queue)

;; Unicode!
(defvar impl-bar-char ?―)

;;; goal formatting

(defun coq-server--goal-id (goal)
  (coq-xml-body1 (nth 2 goal)))

(defun coq-server--goal-hypotheses (goal)
  (let ((goal-hypos (nth 3 goal)))
     (let* ((richpp-hypos
	     (cl-remove-if 'null
			   (mapcar (lambda (hy) (coq-xml-at-path hy '(richpp (_))))
				   (coq-xml-body goal-hypos))))
	    (flattened-hypos 
	     (mapcar (lambda (rhy) `(_ nil ,(flatten-pp (coq-xml-body rhy))))
		     richpp-hypos)))
       (or 
	;; 8.6
	flattened-hypos 
	;; 8.5
	(coq-xml-body goal-hypos)))))

(defun coq-server--goal-goal (goal)
  (let ((goal-goal (nth 4 goal)))
    (or 
     ;; 8.6
     (let ((richpp-goal (coq-xml-at-path goal-goal '(richpp (_)))))
       (and richpp-goal
	    (flatten-pp (coq-xml-body richpp-goal))))
     ;; 8.5
     (coq-xml-body1 goal-goal))))

(defvar goal-indent " ")

;; make a pretty goal 
(defun coq-server--format-goal-with-hypotheses (goal hyps)
  (let* ((nl "\n")
	 (nl-indent (concat nl goal-indent))
	 (min-width 5)   ; minimum width of implication bar
	 (padding-len 1) ; on either side of hypotheses or goals
	 (padding (make-string padding-len ?\s))
	 (hyps-text (mapcar 'coq-xml-body1 hyps))
	 (formatted-hyps (mapconcat 'identity hyps-text (concat nl-indent padding)))
	 (hyps-width (apply 'max (cons 0 (mapcar 'length hyps-text)))) ; cons 0 in case empty
	 (goal-width (length goal))
	 (width (max min-width (+ (max hyps-width goal-width) (* 2 padding-len))))
	 (goal-offset (/ (- width goal-width) 2)))
    (concat goal-indent padding formatted-hyps nl             ; hypotheses
	    goal-indent (make-string width impl-bar-char) nl  ; implication bar
            goal-indent (make-string goal-offset ?\s) goal))) ; the goal

(defun coq-server--format-goal-no-hypotheses (goal)
  (concat goal-indent goal))

;; invariant: goals is non-empty
(defun coq-server--display-goals (goals)
  (let* ((num-goals (length goals))
	 (goal1 (car goals))
	 (goals-rest (cdr goals))
	 (goal-counter 1))
    (message "num goals: %s" num-goals)
    (message "goal 1: %s" goal1)
    (message "goal-rest: %s" goals-rest)
    (message "POINT 1")
    (with-temp-buffer
      (if (= num-goals 1)
	  (insert "1 subgoal")
	(insert (format "%d subgoals" num-goals)))
      (insert "\n\n")
      (message "POINT 2")
      (insert (format "subgoal 1 (ID %s):\n" (coq-server--goal-id goal1)))
      (message "POINT 3")
      (insert (coq-server--format-goal-with-hypotheses 
	       (coq-server--goal-goal goal1)
	       (coq-server--goal-hypotheses goal1)))
      (message "POINT 4")
      (insert "\n\n")
      (dolist (goal goals-rest)
	(message "POINT 5")
	(setq goal-counter (1+ goal-counter))
	(insert (format "\nsubgoal %s (ID %s):\n" goal-counter (coq-server--goal-id goal)))
	(insert (coq-server--format-goal-no-hypotheses 
		 (coq-server--goal-goal goal))))
      (pg-goals-display (buffer-string) t))))

;; update global state in response to status
(defun coq-server--handle-status (maybe-current-proof all-proofs current-proof-id)
  (let ((curr-proof-opt-val (coq-xml-val maybe-current-proof)))
    (if (string-equal curr-proof-opt-val 'some)
	(let* ((curr-proof-string (coq-xml-body1 maybe-current-proof))
	       (curr-proof-name (coq-xml-body1 curr-proof-string)))
	  (setq coq-current-proof-name curr-proof-name))
      (setq coq-current-proof-name nil)))
  (let* ((pending-proof-strings (coq-xml-body all-proofs))
	 (pending-proofs (mapcar 'coq-xml-body1 pending-proof-strings)))
    (setq coq-pending-proofs pending-proofs))
  (let* ((proof-state-id-string (coq-xml-body1 current-proof-id))
	 (proof-state-id (string-to-number proof-state-id-string)))
    (setq coq-proof-state-id proof-state-id))
  ;; used to be called as a hook at end of proof-done-advancing
  (coq-set-state-infos))

;; no current goal
(defvar coq-server--value-empty-goals-footprint
  '(value (option)))

(defun coq-server--value-empty-goals-p (xml)
  (equal (coq-xml-footprint xml) 
	 coq-server--value-empty-goals-footprint))

(defun coq-server--handle-empty-goals ()
  (coq-server--clear-goals-buffer))

;; use path instead of footprint, because inner bits may vary
(defun coq-server--value-goals-p (xml)
  (coq-xml-at-path xml '(value (option (goals)))))

(defun coq-server--handle-goal (goal)
  ;; nothing to do, apparently
  (and nil goal)) ;; prevents compiler warning

(defun coq-server--handle-goals (xml)
  (let* ((all-goals (coq-xml-body (coq-xml-at-path xml '(value (option (goals))))))
	 (current-goals (coq-xml-body (nth 0 all-goals)))
	 (bg-goals (coq-xml-body (nth 1 all-goals)))
	 (shelved-goals (coq-xml-body (nth 2 all-goals)))
	 (abandoned-goals (coq-xml-body (nth 3 all-goals))))
    (message "current-goals: %s" current-goals)
    (if current-goals
	(progn
	  (dolist (goal current-goals)
	    (coq-server--handle-goal goal))
	  (coq-server--display-goals current-goals))
      (progn
	(setq proof-prover-proof-completed 0)
	;; clear goals display
	(coq-server--clear-goals-buffer)
	;; mimic the coqtop REPL, though it would be better to come via XML
	(coq--display-response "No more subgoals.")))
    (when bg-goals
      (dolist (goal bg-goals)
	(coq-server--handle-goal goal)))
    (when shelved-goals
      (dolist (goal shelved-goals)
	(coq-server--handle-goal goal)))
    (when abandoned-goals
      (dolist (goal abandoned-goals)
	(coq-server--handle-goal goal)))))

(defun coq-server--handle-item (item)
  (pcase (or (stringp item) (coq-xml-tag item))
    (`status 
     (let* ((status-items (coq-xml-body item))
	    ;; ignoring module path of proof
	    (maybe-current-proof (nth 1 status-items))
	    (all-proofs (nth 2 status-items))
	    (current-proof-id (nth 3 status-items)))
       (coq-server--handle-status maybe-current-proof all-proofs current-proof-id)))
    (t)))

;; inefficient, but number of spans should be small
(defun coq-server--state-id-precedes (state-id-1 state-id-2)
  "Does STATE-ID-1 occur in a span before that for STATE-ID-2?"
  (let ((span1 (coq-server--get-span-with-state-id state-id-1))
	(span2 (coq-server--get-span-with-state-id state-id-2)))
    (< (span-start span1) (span-start span2))))

(defun coq-server--get-span-with-predicate (pred &optional span-list)
  (with-current-buffer proof-script-buffer
    (let* ((all-spans (or span-list (overlays-in (point-min) (point-max)))))
      (cl-find-if pred all-spans))))

;; we could use the predicate mechanism, but this happens a lot
;; so use hash table
(defun coq-server--get-span-with-state-id (state-id)
  (gethash state-id coq-server--span-state-id-tbl))

;; error coloring heuristic 
(defun coq-server--error-span-at-end-of-locked (error-span)
  (let* ((locked-span (coq-server--get-span-with-predicate
		       (lambda (span) 
			 (equal (span-property span 'face) 'proof-locked-face))))
	 (locked-end (span-end locked-span))
	 (error-end (span-end error-span)))
    (message "error-span: %s  error-end: %s locked-end: %s" error-span error-end locked-end)
    (>= error-end locked-end)))

;; make pending Edit_at state id current
(defun coq-server--consume-edit-at-state-id ()
  (message "SETTING CURR STATE ID TO EDIT AT ID: %s" coq-server--pending-edit-at-state-id)
  (setq coq-current-state-id coq-server--pending-edit-at-state-id)
  (setq coq-server--pending-edit-at-state-id nil))

(defvar coq-server--value-simple-backtrack-footprint 
  '(value (union (unit))))

(defun coq-server--value-simple-backtrack-p (xml)
  (message "TESTING FOR SIMPLE BACKTRACK")
  (message "pending-edit-at-id: %s" coq-server--pending-edit-at-state-id)
  (message "EQUAL FOOTPRINTS: %s" (equal (coq-xml-footprint xml)
	      coq-server--value-simple-backtrack-footprint))
  (and coq-server--pending-edit-at-state-id 
       (equal (coq-xml-footprint xml)
	      coq-server--value-simple-backtrack-footprint)))

;; Edit_at, get new focus
(defvar coq-server--value-new-focus-footprint 
  '(value (union (pair (state_id) (pair (state_id) (state_id))))))

(defun coq-server--value-new-focus-p (xml)
  (and (equal (coq-xml-footprint xml)
	      coq-server--value-new-focus-footprint)
       (string-equal (coq-xml-at-path 
		      xml
		      '(value (union val)))
		     "in_r")))

;; extract state ids from value response after focus open
(defun coq-server--new-focus-state-ids (xml)
  (let* ((outer-pair 
	  (coq-xml-at-path 
	   xml
	   '(value (union (pair)))))
	 (focus-start-state-id 
	  (coq-xml-at-path 
	   outer-pair
	   '(pair (state_id val))))
	 (inner-pair 
	  (coq-xml-at-path 
	   outer-pair
	   '(pair (state_id) (pair))))
	 (focus-end-state-id 
	  (coq-xml-at-path 
	   inner-pair
	   '(pair (state_id val))))
	 (last-tip-state-id 
	  (coq-xml-at-path 
	   inner-pair
	   '(pair (state_id) (state_id val)))))
    (list focus-start-state-id focus-end-state-id last-tip-state-id)))

;; value on Init
(defvar coq-server--value-init-state-id-footprint
  '(value (state_id)))

(defun coq-server--value-init-state-id-p (xml)
  (equal (coq-xml-footprint xml) 
	 coq-server--value-init-state-id-footprint))

(defun coq-server--value-init-state-id (xml)
  (coq-xml-at-path 
   xml
   '(value (state_id val))))

(defun coq-server--set-init-state-id (xml)
  (let ((state-id (coq-server--value-init-state-id xml)))
    (setq coq-retract-buffer-state-id state-id)
    (coq-server--update-state-id state-id)))

;; value when updating state id from an Add
(defvar coq-server--value-new-state-id-footprint
  '(value (pair (state_id) (pair (union (unit)) (string)))))

(defun coq-server--value-new-state-id-p (xml)
  (equal (coq-xml-footprint xml) 
	 coq-server--value-new-state-id-footprint))

(defun coq-server--set-new-state-id (xml)
  (let ((state-id (coq-xml-at-path 
		   xml
		   '(value (pair (state_id val))))))
    (coq-server--update-state-id-and-process state-id)))

;; Add'ing past end of focus
(defvar coq-server--value-end-focus-footprint 
  '(value (pair (state_id) (pair (union (state_id)) (string)))))

(defun coq-server--value-end-focus-p (xml) 
  (and (equal (coq-xml-footprint xml) coq-server--value-end-focus-footprint)
       (string-equal (coq-xml-at-path 
		      xml 
		      '(value (pair (state_id) (pair (union val))))) 
		     "in_r")))

(defun coq-server--end-focus-qed-state-id (xml)
  (coq-xml-at-path 
   xml 
   '(value (pair (state_id val)))))

(defun coq-server--end-focus-new-tip-state-id (xml)
  (coq-xml-at-path 
   xml 
   '(value (pair (state_id) (pair (union (state_id val)))))))

(defun coq-server--register-state-id (span state-id)
  (coq-set-span-state-id span state-id)
  (puthash state-id span coq-server--span-state-id-tbl))

(defun coq-server--end-focus (xml)
  (message "END FOCUS")
  (let ((qed-state-id (coq-server--end-focus-qed-state-id xml))
	(new-tip-state-id (coq-server--end-focus-new-tip-state-id xml)))
    (coq-server--register-state-id coq-server--current-span qed-state-id)
    (setq coq-current-state-id new-tip-state-id)
    (setq coq-server--start-of-focus-state-id nil)
    (coq-server--merge-locked-spans)))

(defun coq-server--simple-backtrack ()
  ;; delete all spans marked for deletion
  (with-current-buffer proof-script-buffer
    (let* ((retract-span (coq-server--get-span-with-state-id coq-server--pending-edit-at-state-id))
	   (start (or (and retract-span (1+ (span-end retract-span)))
		      (point-min))))
      (let ((all-spans (overlays-in start (point-max))))
	(mapc (lambda (span)
		(when (and (span-property span 'marked-for-deletion)
			   (not (span-property span 'self-removing)))
		  (span-delete span)))
	      all-spans))))
  (coq-server--consume-edit-at-state-id))

(defun coq-server--new-focus-backtrack (xml)
  (message "NEW FOCUS BACKTRACK")
  ;; new focus produces secondary locked span, which extends from
  ;; end of new focus to last tip
  ;; primary locked span is from start of script to the edit at state id
  ;; want a secondary locked span just past focus end to old tip
  (let* ((state-ids (coq-server--new-focus-state-ids xml))
	 (focus-start-state-id (nth 0 state-ids))
	 (focus-end-state-id (nth 1 state-ids))
	 (last-tip-state-id (nth 2 state-ids)))
    ;; if focus end and last tip are the same, treat as simple backtrack
    (if (equal focus-end-state-id last-tip-state-id)
	(coq-server--simple-backtrack)
      ;; multiple else's
      (setq coq-server--start-of-focus-state-id focus-start-state-id)
      (coq-server--create-secondary-locked-span focus-end-state-id last-tip-state-id)
      (coq-server--consume-edit-at-state-id))))

(defun coq-server--create-secondary-locked-span (focus-end-state-id last-tip-state-id)
  (message "MAKING SECONDARY SPAN, LAST TIP: %s" last-tip-state-id)
  (with-current-buffer proof-script-buffer
    (let* ((all-spans (overlays-in (point-min) (point-max)))
	   (marked-spans (cl-remove-if-not 
			  (lambda (span) (span-property span 'marked-for-deletion)) 
			  all-spans))
	   (sorted-marked-spans 
	    (sort marked-spans (lambda (sp1 sp2) (< (span-start sp1) (span-start sp2)))))
	   (last-tip-span (coq-server--get-span-with-state-id last-tip-state-id))
	   found-focus-end
	   secondary-span-start
	   secondary-span-end)
      (setq secondary-span-end (span-end last-tip-span))
      (message "GOT VARIABLES")
      ;; delete spans within focus, because they're unprocessed now
      ;; leave spans beneath the focus, because we'll skip past them 
      ;;  when merging primary, secondary locked regions
      (dolist (span sorted-marked-spans)
	(message "LOOKING AT MARKED SPAN: %s" span)
	(if found-focus-end
	    (progn
	      (let ((curr-span-start (span-start span)))
		;; the first span past the end of the focus starts the secondary span
		(unless secondary-span-start 
		  (setq secondary-span-start curr-span-start))
		;; don't delete the span 
		(span-unmark-delete span)))
	  ;; look for focus end
	  (let ((span-state-id (span-property span 'state-id)))
	    (if (and span-state-id (equal span-state-id focus-end-state-id))
		(setq found-focus-end t)
	      (span-delete span)))))
      ;; skip past whitespace for secondary span
      (save-excursion
	(goto-char secondary-span-start)
	(skip-chars-forward " \t\n")
	(beginning-of-thing 'sentence)
	(setq secondary-span-start (point)))
      (let* ((span (span-make secondary-span-start secondary-span-end)))
	(span-set-property span 'start-closed t) ;; TODO what are these for?
	(span-set-property span 'end-closed t)
	(span-set-property span 'face 'proof-secondary-locked-face)
	(put-text-property secondary-span-start secondary-span-end 'read-only t proof-script-buffer)
	(setq proof-locked-secondary-span span)))))

(defun coq-server--remove-secondary-locked-span (&optional delete-spans)
  (let ((start (span-start proof-locked-secondary-span))
	(end (span-end proof-locked-secondary-span)))
    ;; remove read-only property
    (with-current-buffer proof-script-buffer
      (span-delete proof-locked-secondary-span)
      (setq proof-locked-secondary-span nil)
      (setq inhibit-read-only t) ; "special trick"
      (remove-list-of-text-properties start end (list 'read-only))
      (setq inhibit-read-only nil)
      ;; delete unless merging primary, secondary locked regions 
      ;; spans following primary locked region are valid
      (when delete-spans
	(let* ((candidate-spans (overlays-in start end))
	       (relevant-spans 
		(cl-remove-if-not 
		 (lambda (span) (or (span-property span 'type) (span-property span 'idiom)))
		 candidate-spans)))
	  (mapc 'span-delete relevant-spans))))))

(defun coq-server--merge-locked-spans ()
  (with-current-buffer proof-script-buffer
    (let ((new-end (span-end proof-locked-secondary-span)))
      (coq-server--remove-secondary-locked-span)
      ;; proof-done-advancing uses this to set merged locked end
      (setq proof-merged-locked-end new-end))))

;; did we backtrack to a point before the current focus
(defun coq-server--backtrack-before-focus-p (xml)
  (and (coq-server--value-simple-backtrack-p xml) ; response otherwise looks like simple backtrack
       coq-server--start-of-focus-state-id 
       (or (equal coq-server--pending-edit-at-state-id coq-retract-buffer-state-id)
	   (coq-server--state-id-precedes 
	    coq-server--pending-edit-at-state-id 
	    coq-server--start-of-focus-state-id))))

(defun coq-server--before-focus-backtrack ()
  ;; retract to before a re-opened proof
  (assert proof-locked-secondary-span)
  (coq-server--remove-secondary-locked-span t)
  (setq coq-server--start-of-focus-state-id nil)
  (coq-server--consume-edit-at-state-id))

(defun coq-server--update-state-id (state-id)
  (setq coq-current-state-id state-id)
  (when coq-server--current-span
    (coq-server--register-state-id coq-server--current-span state-id)))

(defun coq-server--update-state-id-and-process (state-id)
  (coq-server--update-state-id state-id)
  (message "UPDATING STATE ID: %s PENDING ADDS: %s" state-id coq-server--pending-add-count)
  (when (> coq-server--pending-add-count 0)
    (setq coq-server--pending-add-count (1- coq-server--pending-add-count)))
  ;; gotten response from all Adds, ask for goals/status
  (when (= coq-server--pending-add-count 0)
    (proof-server-send-to-prover (coq-xml-goal))
    (proof-server-send-to-prover (coq-xml-status)))
    ;; if we've gotten responses from all Add's, ask for goals/status
  ;; processed good value, ready to send next item
  (proof-server-exec-loop))

(defun coq-server--handle-failure-value (xml)
  ;; don't clear pending edit-at state id here
  ;; because we may get failures from Status/Goals before the edit-at value
  (message "HANDLING FAILURE VALUE: %s" xml)
  ;; we usually see the failure twice, once for Goal, again for Status
  (let ((last-valid-state-id (coq-xml-at-path xml '(value (state_id val)))))
    (unless (or (equal last-valid-state-id coq-current-state-id)
		(gethash xml coq-server--error-fail-tbl))
      (puthash xml t coq-server--error-fail-tbl)
      (let ((last-valid-span (coq-server--get-span-with-state-id last-valid-state-id)))
	(with-current-buffer proof-script-buffer
	  (goto-char (span-end last-valid-span))
	  (proof-retract-until-point))))))

(defun coq-server--handle-good-value (xml)
  (message "good value: %s" xml)
  (cond
   ((coq-server--backtrack-before-focus-p xml)
    ;; retract before current focus
    (message "BACKTRACK BEFORE FOCUS")
    (coq-server--before-focus-backtrack))
   ((coq-server--value-new-focus-p xml)
     ;; retract re-opens a proof
    (message "REOPENED PROOF")
    (coq-server--new-focus-backtrack xml))
   ((coq-server--value-simple-backtrack-p xml)
     ;; simple backtrack
    (message "SIMPLE BACKTRACK")
    (coq-server--simple-backtrack))
   ((coq-server--value-end-focus-p xml) 
    (message "SIMPLE END FOCUS")
    ;; close of focus after Add
    (coq-server--end-focus xml))
   ((coq-server--value-init-state-id-p xml) 
    (message "INIT STATE ID")
    ;; Init, get first state id
    (coq-server--set-init-state-id xml))
   ((coq-server--value-new-state-id-p xml) 
    (message "NEW STATE ID")
    ;; Add that updates state id
    (coq-server--set-new-state-id xml))
   ((coq-server--value-empty-goals-p xml)
    (message "EMPTY GOALS")
    ;; Response to Goals, with no current goals
    (coq-server--handle-empty-goals))
   ((coq-server--value-goals-p xml)
    (message "NONEMPTY GOALS")
    ;; Response to Goals, some current goals
    (coq-server--handle-goals xml))
   (t 
    (error "Unknown good value response"))))

;; we distinguish value responses by their syntactic structure
;; and a little bit by some global state
;; can we do better?
(defun coq-server--handle-value (xml)
  (let ((status (coq-xml-val xml)))
    (pcase status
      ("fail"
       (coq-server--handle-failure-value xml))
      ("good"
       (coq-server--handle-good-value xml)))))

;; delay creating the XML so it will have the right state-id
;; the returned lambda captures the passed item, which is why 
;; this file needs lexical binding
;; side-effect of the thunk: clear feedback message table
(defun coq-server-make-add-command-thunk (cmd span)
  (lambda () 
    (clrhash coq-server--error-fail-tbl)
    (list (coq-xml-add-item cmd) span)))

(defun coq-server--display-error (error-state-id error-msg error-start error-stop)
  (message "DISPLAYING ERROR, STATE ID: %S MSG: %s" error-state-id error-msg)
  (let ((error-span (coq-server--get-span-with-state-id error-state-id)))
    ;; decide where to show error
    (if (coq-server--error-span-at-end-of-locked error-span)
	(progn
	  (coq-server--clear-response-buffer)
	  (coq--display-response error-msg)
	  ;; on retraction, keep error in response buffer
	  (setq coq-server--retraction-on-error t) 
	  (coq--highlight-error error-span error-start error-stop))
      ;; error in middle of processed region
      ;; indelibly color the error 
      (let ((span-processing (gethash error-state-id coq-server--processing-span-tbl)))
       ;; may get several processed feedbacks for one processingin
       ;; use first one
	(when span-processing
	   (progn
	     (remhash error-state-id coq-server--processing-span-tbl)
	     (span-delete span-processing))))
      (coq--mark-error error-span error-msg))))

;; this is for 8.5
(defun coq-server--handle-errormsg (xml)
  ;; memoize this errormsg response
  (puthash xml t coq-server--error-fail-tbl)
  (let* ((loc (coq-xml-at-path 
	       xml 
	       '(feedback (state_id) (feedback_content (loc)))))
	 (error-start (string-to-number (coq-xml-attr-value loc 'start)))
	 (error-stop (string-to-number (coq-xml-attr-value loc 'stop)))
	 (msg-string (coq-xml-at-path 
		      xml 
		      '(feedback (state_id) (feedback_content (loc) (string)))))
	 (error-msg (coq-xml-body1 msg-string))
	 (error-state-id (coq-xml-at-path 
			  xml 
			  '(feedback (state_id val)))))
    (coq-server--display-error error-state-id error-msg error-start error-stop)))

;; discard tags in richpp-formatted strings
;; TODO : use that information
(defun flatten-pp (items)
  (mapconcat (lambda (it)
	       (if (and (consp it) (consp (cdr it)))
		   (flatten-pp (cddr it))
		 it))
	     items ""))

;; this is for 8.6
(defun coq-server--handle-error (xml)
  (message "HANDLING ERROR: %s" xml)
  ;; memoize this response
  (puthash xml t coq-server--error-fail-tbl)
  ;; TODO what happens when there's no location?
  (let* ((loc (coq-xml-at-path 
	       xml 
	       '(feedback (state_id) 
			  (feedback_content (message (message_level) (option (loc)))))))
	 (error-start (string-to-number (coq-xml-attr-value loc 'start)))
	 (error-stop (string-to-number (coq-xml-attr-value loc 'stop)))
	 (msg-string (coq-xml-at-path 
		      xml 
		      '(feedback (state_id) 
				 (feedback_content (message (message_level) (option (loc)) (richpp (_)))))))
	 (error-msg (flatten-pp (coq-xml-body msg-string)))
	 (error-state-id (coq-xml-at-path 
			  xml 
			  '(feedback (state_id val)))))
    (coq-server--display-error error-state-id error-msg error-start error-stop)))

(defun coq-server--handle-feedback (xml)
  (pcase (coq-xml-at-path xml '(feedback (_) (feedback_content val)))
    ("processingin"
     (message "GOT PROCESSINGIN")
     (with-current-buffer proof-script-buffer
       (let* ((state-id (coq-xml-at-path xml '(feedback (state_id val))))
	      (span-with-state-id (coq-server--get-span-with-state-id state-id)))
	 (when span-with-state-id ; can see feedbacks with state id not yet associated with a span
	   (save-excursion
	     (goto-char (span-start span-with-state-id))
	     (skip-chars-forward " \t\n")
	     (beginning-of-thing 'sentence)
	     (let ((span-processing (span-make (point) (span-end span-with-state-id))))
	       (span-set-property span-processing 'processing-in t)
	       (span-set-property span-processing 'face 'proof-processing-face)
	       (puthash state-id span-processing coq-server--processing-span-tbl)))))))
    ("processed"
     (message "GOT PROCESSED")
     (let* ((state-id (coq-xml-at-path xml '(feedback (state_id val))))
	    (span-processing (gethash state-id coq-server--processing-span-tbl)))
       ;; may get several processed feedbacks for one processingin
       ;; only need to use first one
       (when span-processing
	   (progn
	     (remhash state-id coq-server--processing-span-tbl)
	     (span-delete span-processing)))))
    ("errormsg" ; 8.5-only
     (message "GOT ERRORMSG")
     (unless (gethash xml coq-server--error-fail-tbl)
       (coq-server--handle-errormsg xml)))
    ("message" ; 8.6
     (message "GOT MESSAGE")
     (unless (gethash xml coq-server--error-fail-tbl)
       (let ((msg-level 
	      (coq-xml-at-path 
	       xml 
	       '(feedback (_) (feedback_content (message (message_level val)))))))
	 (when (or (equal msg-level "warning") ;; TODO have we seen a warning in the wild?
		   (equal msg-level "error") )
	   (coq-server--handle-error xml)))))
    (t)))

;; syntax of messages differs in 8.5 and 8.6, handle both cases
;; TODO : dispatch on version, maybe
(defun coq-server--handle-message (xml)
  (message "Handling message: %s" xml)
  (let* ((message-str-8.5 (coq-xml-at-path xml '(message (message_level) (string))))
	 ;; The _ below is a wildcard in our search path, but the tag is actually _
	 ;; something of a delicious irony
	 (message-str (or message-str-8.5 
			  (coq-xml-at-path xml '(message (message_level) (option) (richpp (_))))))
	 (msg (coq-server--unescape-string (coq-xml-body1 message-str))))
     (coq--display-response msg)))

;; process XML response from Coq
(defun coq-server-process-response (response span)
  (with-current-buffer coq-server-response-buffer
    (coq-server--append-response response)
    (coq-server--unescape-buffer)
    ;; maybe should pass this instead
    (setq coq-server--current-span span) 
    (let ((xml (coq-server--get-next-xml)))
      (while xml
	(message "XML: %s FOOTPRINT: %s" xml (coq-xml-footprint xml))
	(pcase (coq-xml-tag xml)
	  (`value (coq-server--handle-value xml))
	  (`feedback (coq-server--handle-feedback xml))
	  (`message (coq-server--handle-message xml))
	  (t (message "unknown coqtop response %s" xml)))
	(setq xml (coq-server--get-next-xml))))))

;; process OOB response from Coq
(defun coq-server-process-oob (oob)
  (with-current-buffer coq-server-oob-buffer
    (message "PROCESSING OOB: %s" oob)
    (coq-server--append-response oob)
    (coq-server--unescape-buffer)
    (let ((xml (coq-server--get-next-xml)))
      (while xml
	(message "OOB XML: %s" xml)
	(coq-server--handle-feedback xml) ; OOB data always feedback
	(setq xml (coq-server--get-next-xml))))))

(defun coq-server-handle-tq-response (unused response span)
  (coq-server-process-response response span)
  ;; needed to advance proof-action-list
  (proof-server-manage-output response))

;; send data to Coq by sending to process
;; called by proof-server-send-to-prover
;; do not call directly
(defun coq-server-send-to-prover (s)
  (tq-enqueue coq-server-transaction-queue s end-of-response-regexp
	      ;; "closure" argument, passed to handler below
	      nil 
	      ;; handler gets closure and coqtop response
	      'coq-server-handle-tq-response))

(provide 'coq-server)
