;;; orgtbl-aggregate.el --- Create an aggregated Org table from another one  -*- coding:utf-8;-*-

;; Copyright (C) 2013, 2014, 2015, 2016, 2017, 2018, 2019, 2020, 2021  Thierry Banel

;; Authors:
;;   Thierry Banel tbanelwebmin at free dot fr
;;   Michael Brand michael dot ch dot brand at gmail dot com
;; Contributors:
;;   Eric Abrahamsen
;;   Alejandro Erickson alejandro dot erickson at gmail dot com
;;   Uwe Brauer
;;   Peking Duck
;;   Bill Hunker

;; Version: 1.0
;; Keywords: org, table, aggregation, filtering

;; orgtbl-aggregate is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; orgtbl-aggregate is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; A new org-mode table is automatically updated,
;; based on another table acting as a data source
;; and user-given specifications for how to perform aggregation.
;;
;; Example:
;; Starting from a source table of activities and quantities
;; (whatever they are) over several days,
;; 
;; #+TBLNAME: original
;; | Day       | Color | Level | Quantity |
;; |-----------+-------+-------+----------|
;; | Monday    | Red   |    30 |       11 |
;; | Monday    | Blue  |    25 |        3 |
;; | Tuesday   | Red   |    51 |       12 |
;; | Tuesday   | Red   |    45 |       15 |
;; | Tuesday   | Blue  |    33 |       18 |
;; | Wednesday | Red   |    27 |       23 |
;; | Wednesday | Blue  |    12 |       16 |
;; | Wednesday | Blue  |    15 |       15 |
;; | Thursday  | Red   |    39 |       24 |
;; | Thursday  | Red   |    41 |       29 |
;; | Thursday  | Red   |    49 |       30 |
;; | Friday    | Blue  |     7 |        5 |
;; | Friday    | Blue  |     6 |        8 |
;; | Friday    | Blue  |    11 |        9 |
;; 
;; an aggregation is built for each day (because several rows
;; exist for each day), typing C-c C-c
;; 
;; #+BEGIN: aggregate :table original :cols "Day mean(Level) sum(Quantity)"
;; | Day       | mean(Level) | sum(Quantity) |
;; |-----------+-------------+---------------|
;; | Monday    |        27.5 |            14 |
;; | Tuesday   |          43 |            45 |
;; | Wednesday |          18 |            54 |
;; | Thursday  |          43 |            83 |
;; | Friday    |           8 |            22 |
;; #+END
;;
;; A wizard can be used:
;; M-x org-insert-dblock:aggregate
;;
;; Full documentation here:
;;   https://github.com/tbanel/orgaggregate/blob/master/README.org

;;; Requires:
(require 'calc-ext)
(require 'org)
(require 'org-table)
(eval-when-compile (require 'cl-lib))
(require 'rx)
(cl-proclaim '(optimize (speed 3) (safety 0)))

;;; Code:

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; creating long lists in the right order may be done
;; - by (nconc)  but behavior is quadratic
;; - by (cons) (nreverse)
;; a third way involves keeping track of the last cons of the growing list
;; a cons at the head of the list is used for housekeeping
;; the actual list is (cdr ls)

(defsubst -appendable-list-create ()
  (let ((x (cons nil nil)))
    (setcar x x)))

(defmacro -appendable-list-append (ls value)
  `(setcar ,ls (setcdr (car ,ls) (cons ,value nil))))

(defmacro -appendable-list-get (ls)
  `(cdr ,ls))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The function (org-table-to-lisp) have been greatly enhanced
;; in Org Mode version 9.4
;; To benefit from this speedup in older versions of Org Mode,
;; this function is copied here with a slightly different name
;; It has also undergone near 2x speedup

(defun org-table-to-lisp-post-9-4 (&optional txt)
  "Convert the table at point to a Lisp structure.

The structure will be a list.  Each item is either the symbol `hline'
for a horizontal separator line, or a list of field values as strings.
The table is taken from the parameter TXT, or from the buffer at point."
  (if txt
      (with-temp-buffer
	(buffer-disable-undo)
        (insert txt)
        (goto-char (point-min))
        (org-table-to-lisp-post-9-4))
    (save-excursion
      (goto-char (org-table-begin))
      (let ((table nil)
	    (inhibit-changing-match-data t)
	    q
	    p
	    row)
        (while (re-search-forward "\\=[ \t]*|" nil t)
	  (if (looking-at "-")
	      (push 'hline table)
	    (setq row nil)
	    (while (progn (skip-chars-forward " \t") (not (eolp)))
	      (push
	       (buffer-substring-no-properties
		(setq q (point))
		(if (progn (skip-chars-forward "^|\n") (eolp))
		    (1- (point))
		  (setq p (1+ (point)))
		  (skip-chars-backward " \t" q)
		  (prog1 (point) (goto-char p))))
	       row))
	    (push (nreverse row) table))
	  (forward-line))
	(nreverse table)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Here is a bunch of useful utilities,
;; generic enough to be detached from the orgtbl-aggregate package.
;; For the time being, they are here.

(defun orgtbl-list-local-tables ()
  "Search for available tables in the current file."
  (interactive)
  (let ((tables))
    (save-excursion
      (goto-char (point-min))
      (while (let ((case-fold-search t))
	       (re-search-forward
		(rx bol
		    (* (any " \t")) "#+" (? "tbl") "name:"
		    (* (any " \t")) (group (* not-newline)))
		nil t))
	(push (match-string-no-properties 1) tables)))
    tables))

(defun orgtbl-get-distant-table (name-or-id)
  "Find a table in the current buffer named NAME-OR-ID
and returns it as a lisp list of lists.
An horizontal line is translated as the special symbol `hline'."
  (unless (stringp name-or-id)
    (setq name-or-id (format "%s" name-or-id)))
  (let (buffer loc)
    (save-excursion
      (goto-char (point-min))
      (if (let ((case-fold-search t))
	    (re-search-forward
	     ;; This concat is automatically done by new versions of rx
	     ;; using "literal". This appeared on june 26, 2019
	     ;; For older versions of Emacs, we fallback to concat
	     (concat
	      (rx bol
		  (* (any " \t")) "#+" (? "tbl") "name:"
		  (* (any " \t")))
	      (regexp-quote name-or-id)
	      (rx (* (any " \t"))
		  eol))
	     nil t))
	  (setq buffer (current-buffer)
		loc (match-beginning 0))
	(let ((id-loc (org-id-find name-or-id 'marker)))
	  (unless (and id-loc (markerp id-loc))
	    (error "Can't find remote table \"%s\"" name-or-id))
	  (setq buffer (marker-buffer id-loc)
		loc (marker-position id-loc))
	  (move-marker id-loc nil))))
    (with-current-buffer buffer
      (save-excursion
	(goto-char loc)
	(forward-char 1)
	(unless (and (re-search-forward "^\\(\\*+ \\)\\|[ \t]*|" nil t)
		     (not (match-beginning 1)))
	  (user-error "Cannot find a table at NAME or ID %s" name-or-id))
	(org-table-to-lisp-post-9-4)))))

(defun orgtbl-get-header-table (table &optional asstring)
  "Return the header of TABLE as a list of column names. When
ASSTRING is true, the result is a string which concatenates the
names of the columns.  TABLE may be a lisp list of rows, or the
name or id of a distant table.  The function takes care of
possibly missing headers, and in this case returns a list of $1,
$2, $3... column names.  Actual column names which are not fully
alphanumeric are quoted."
  (unless (consp table)
    (setq table (orgtbl-get-distant-table table)))
  (while (eq 'hline (car table))
    (setq table (cdr table)))
  (let ((header
	 (if (memq 'hline table)
	     (cl-loop for x in (car table)
		      collect
		      (if (string-match "^[[:word:]_$.]+$" x)
			  x
			(format "\"%s\"" x)))
	   (cl-loop for x in (car table)
		    for i from 1
		    collect (format "$%s" i)))))
    (if asstring
	(mapconcat #'identity header " ")
      header)))

(defun orgtbl-aggregate-make-spaces (n spaces-cache)
  "Makes a string of N spaces.
Caches results to avoid re-allocating again and again
the same string"
  (if (< n (length spaces-cache))
      (or (aref spaces-cache n)
	  (aset spaces-cache n (make-string n ? )))
    (make-string n ? )))

(defun orgtbl-insert-elisp-table (table)
  "Insert TABLE in current buffer at point.
TABLE is a list of lists of cells.  The list may contain the
special symbol 'hline to mean an horizontal line."
  (let* ((nbrows (length table))
	 (nbcols (cl-loop
		  for row in table
		  maximize (if (listp row) (length row) 0)))
	 (maxwidths  (make-list nbcols 1))
	 (numbers    (make-list nbcols 0))
	 (non-empty  (make-list nbcols 0))
	 (spaces-cache (make-vector 100 nil)))

    ;; compute maxwidths
    (cl-loop for row in table
	     do
	     (cl-loop for cell on row
		      for mx on maxwidths
		      for nu on numbers
		      for ne on non-empty
		      for cellnp = (or (car cell) "")
		      do (setcar cell cellnp)
		      if (string-match-p org-table-number-regexp cellnp)
		      do (setcar nu (1+ (car nu)))
		      unless (equal cellnp "")
		      do (setcar ne (1+ (car ne)))
		      if (< (car mx) (length cellnp))
		      do (setcar mx (length cellnp))))

    ;; change meaning of numbers from quantity of cells with numbers
    ;; to flags saying whether alignment should be left (number alignment)
    (cl-loop for nu on numbers
	     for ne in non-empty
	     do
	     (setcar nu (< (car nu) (* org-table-number-fraction ne))))

    ;; inactivating jit-lock-after-change boosts performance a lot
    (cl-letf (((symbol-function 'jit-lock-after-change) (lambda (a b c)) ))
      ;; insert well padded and aligned cells at current buffer position
      (cl-loop for row in table
	       do
	       ;; time optimization: surprisingly,
	       ;; (insert (concat a b c)) is faster than
	       ;; (insert a b c)
	       (insert
		(mapconcat
		 #'identity
		 (nconc
		  (if (listp row)
		      (cl-loop for cell in row
			       for mx in maxwidths
			       for nu in numbers
			       for pad = (- mx (length cell))
			       collect "| "
			       ;; no alignment
			       if (<= pad 0)
			       collect cell
			       ;; left alignment
			       else if nu
			       collect cell and
			       collect (orgtbl-aggregate-make-spaces pad spaces-cache)
			       ;; right alignment
			       else
			       collect (orgtbl-aggregate-make-spaces pad spaces-cache) and
			       collect cell
			       collect " ")
		    (cl-loop for bar = "|" then "+"
			     for mx in maxwidths
			     collect bar
			     collect (make-string (+ mx 2) ?-)))
		  (list "|\n"))
		 ""))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The venerable Calc is used thoroughly by the Aggregate package.
;; A few bugs were found.
;; The fixes are here for the time being

(require 'calc-arith)

(defun math-max-list (a b)
  (if b
      (if (or (Math-anglep (car b)) (eq (caar b) 'date)
	      (and (eq (car (car b)) 'intv) (math-intv-constp (car b)))
	      (math-infinitep (car b)))
	  (math-max-list (math-max a (car b)) (cdr b))
	(math-reject-arg (car b) 'anglep))
    a))

(defun math-min-list (a b)
  (if b
      (if (or (Math-anglep (car b)) (eq (caar b) 'date)
	      (and (eq (car (car b)) 'intv) (math-intv-constp (car b)))
	      (math-infinitep (car b)))
	  (math-min-list (math-min a (car b)) (cdr b))
	(math-reject-arg (car b) 'anglep))
    a))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The Aggregation package

(defun orgtbl-to-aggregated-table-colname-to-int (colname table &optional err)
  "Convert the column name into an integer (first column is numbered 1)
COLNAME may be:
- a dollar form, like $5 which is converted to 5
- an alphanumeric name which appears in the column header (if any)
- the special symbol `hline' which is converted into 0
If COLNAME is quoted (single or double quotes),
quotes are removed beforhand.
When COLNAME does not match any actual column,
an error is generated if ERR optional parameter is true
otherwise nil is returned."
  (if (symbolp colname)
      (setq colname (symbol-name colname)))
  (if (string-match
       (rx
	bol
	(or
	 (seq ?'  (group-n 1 (* (not (any ?' )))) ?' )
	 (seq ?\" (group-n 1 (* (not (any ?\")))) ?\"))
	eol)
       colname)
      (setq colname (match-string 1 colname)))
  ;; skip first hlines if any
  (while (not (listp (car table)))
    (setq table (cdr table)))
  (cond ((equal colname "")
	 (and err (user-error "Empty column name")))
	((equal colname "hline")
	 0)
	((string-match "^\\$\\([0-9]+\\)$" colname)
	 (let ((n (string-to-number (match-string 1 colname))))
	   (if (<= n (length (car table)))
	       n
	     (if err
		 (user-error "Column %s outside table" colname)))))
	(t
	 (or
	  (cl-loop
	   for h in (car table)
	   for i from 1
	   thereis (and (equal h colname) i))
	  (and
	   err
	   (user-error "Column %s not found in table" colname))))))

(defun orgtbl-to-aggregated-replace-colnames-nth (table expression)
  "Replace occurrences of column names in lisp EXPRESSION with
forms like (nth N row), N being the numbering of columns.  Doing
so, the EXPRESSION is ready to be computed against a table row."
  (cond
   ((listp expression)
    (cons (car expression)
	  (cl-loop for x in (cdr expression)
		   collect
		   (orgtbl-to-aggregated-replace-colnames-nth table x))))
   ((numberp expression)
    expression)
   (t
    (let ((n (orgtbl-to-aggregated-table-colname-to-int expression table)))
      (if n
	  (list 'nth n 'row)
	expression)))))

(defun split-string-with-quotes (string)
  "Like `split-string', but also allows single or double quotes
to protect space characters, and also single quotes to protect
double quotes and the other way around"
  (let ((l (length string))
	(start 0)
	(result (-appendable-list-create))
	)
    (save-match-data
      (while (and (< start l)
		  (string-match
		   (rx
		    (* (any " \f\t\n\r\v"))
		    (group
		     (+ (or
			 (seq ?'  (* (not (any ?')))  ?' )
			 (seq ?\" (* (not (any ?\"))) ?\")
			 (not (any " '\""))))))
		   string start))
	(-appendable-list-append result (match-string 1 string))
	(setq start (match-end 1))
	))
    (-appendable-list-get result)))

;; dynamic binding
(defvar orgtbl-aggregate-var-keycols)

(cl-defstruct outcol
  formula	; user-entered formula to compute output cells
  format	; user-entered formatter of output cell
  sort		; user-entered sorting instruction for output column
  invisible	; user-entered output column invisibility
  name		; user-entered output column name
  formula$	; derived formula with $N instead of input column names
  involved	; list of input columns numbers appearing in formula
  formula-frux	; derived formula in Calc format with Frux(N) for input columns
  key		; is this output column a key-column?
  )

(defun orgtbl-aggregate-parse-col (col table)
  "COL is a column specification. It is a string text:
\"formula;formatter;^sorting;<invisible>;'alternate_name'\"
This function parses it into a (outcol) structure
If there is no formatter or sorting or other specifier,
nil is given in place. The other fields of outcol are
filled here too, and nowhere else."
  ;; parse user specification
  (unless (string-match
	   (rx
	    bol
	    (group-n 1
		     (* (or
			 (seq ?'  (* (not (any ?')))  ?' )
			 (seq ?\" (* (not (any ?\"))) ?\")
			 (not (any ";'\"")))))
	    (*
	     ";"
	     (or
	      (seq     (group-n 2 (* (not (any "^;'\"<")))))
	      (seq "^" (group-n 3 (* (not (any "^;'\"<")))))
	      (seq "<" (group-n 4 (* (not (any "^;'\">")))) ">")
	      (seq "'" (group-n 5 (* (not (any "'")))) "'")))
	    eol)
	   col)
    (user-error "Bad column specification: %S" col))
  (let* ((formula   (match-string 1 col))
	 (format    (match-string 2 col))
	 (sort      (match-string 3 col))
	 (invisible (match-string 4 col))
	 (name      (match-string 5 col))

	 ;; list the input column numbers which are involved
	 ;; into formula
	 (involved  nil)

	 ;; create a derived formula in Calc format,
	 ;; where names of input columns are replaced with
	 ;; frux(N)
	 (frux
	  (replace-regexp-in-string
	   (rx
	    (or
	     (seq ?'  (* (not (any ?' ))) ?')
	     (seq ?\" (* (not (any ?\"))) ?\")
	     (seq (+ (any word "_$."))))
	    (? (* space) "("))
	   (lambda (var)
	     (save-match-data ;; save because we are called within a replace-regexp
	       (if (string-match (rx (group (+ (not (any "(")))) (* space) "(") var)
		   (if (member
			(match-string 1 var)
			'("mean" "meane" "gmean" "hmean" "median" "sum"
			  "min" "max" "prod" "pvar" "sdev" "psdev"
			  "corr" "cov" "pcov" "count" "span" "var"))
		       ;; aggregate functions with or without the leading "v"
		       ;; sum(X) and vsum(X) are equivalent
		       (format "v%s" var)
		     var)
		 ;; replace VAR if it is a column name
		 (let ((i (orgtbl-to-aggregated-table-colname-to-int
			   var
			   table)))
		   (if i
		       (progn
			 (unless (member i involved)
			   (push i involved))
			 (format "Frux(%s)" i))
		     var)))))
	   formula))

	 ;; create a derived formula where input column names
	 ;; are replaced with $N
	 (formula$
	  (replace-regexp-in-string
	   (rx "Frux(" (+ (any "0-9")) ")")
	   (lambda (var)
	     (save-match-data
	       (string-match
		(rx (group (+ (any "0-9"))))
		var)
	       (format "$%s" (match-string 1 var))))
	   frux))

	 ;; if a formula is just an input column name,
	 ;; then it is a key-grouping-column
	 (key
	  (if (string-match
	       (rx
		bol
		(group
		 (or (seq "'"  (* (not (any "'" ))) "'" )
		     (seq "\"" (* (not (any "\""))) "\"")
		     (+ (any word "_$."))))
		eol)
	       formula)
	      (orgtbl-to-aggregated-table-colname-to-int formula table t))))

    (if key (push key orgtbl-aggregate-var-keycols))

    (make-outcol
     :formula      formula
     :format       format
     :sort         sort
     :invisible    invisible
     :name         name
     :formula-frux (math-read-expr frux)
     :formula$     formula$
     :involved     involved
     :key          key)))

;; dynamic binding
(defvar orgtbl-aggregate-columns-sorting)

(cl-defstruct sorting
  strength
  colnum
  ascending
  extract
  compare)

(defun orgtbl-aggregate-prepare-sorting (aggcols)
  "Creates a liste of columns to be sorted into
orgtbl-aggregate-columns-sorting.
The liste contains sorting specifications as follows:
(sorting-strength
 column-number
 ascending-descending
 extract-function
 compare-function)
- sorting-strength is a number telling what column should be
  considered first:
  . lower number are considered first
  . nil are condirered last
- column-number is as in the user specification
  1 is the first user specified column
- ascending-descending is nil for ascending, t for descending
- extract-function converts the input cell (which is a string)
  into a comparable value
- compare-function compares two cells and answers nil if
  the first cell must come before the second"
  (cl-loop for col in aggcols
	   for sorting = (outcol-sort col)
	   for colnum from 0
	   if sorting
	   do (progn
		(unless (string-match (rx bol (group (any "aAnNtTfF")) (group (* (any num))) eol) sorting)
		  (user-error "Bad sorting specification: ^%s, expecting a/A/n/N/t/T and an optional number" sorting))
		(-appendable-list-append
		 orgtbl-aggregate-columns-sorting
		 (let ((strength 
			(if (equal (match-string 2 sorting) "")
			    nil
			  (string-to-number (match-string 2 sorting)))))
		   (pcase (match-string 1 sorting)
		     ("a" (record 'sorting strength colnum nil 'identity                        'string-lessp))
		     ("A" (record 'sorting strength colnum t   'identity                        'string-lessp))
		     ("n" (record 'sorting strength colnum nil 'string-to-number                '<           ))
		     ("N" (record 'sorting strength colnum t   'string-to-number                '<           ))
		     ("t" (record 'sorting strength colnum nil 'orgtbl-aggregate-string-to-time '<           ))
		     ("T" (record 'sorting strength colnum t   'orgtbl-aggregate-string-to-time '<           ))
		     ((or "f" "F") (user-error "f/F sorting specification not (yet) implemented"))
		     (_ (user-error "Bad sorting specification ^%s" sorting)))))))

  ;; major sorting columns must come before minor sorting columns
  (setq orgtbl-aggregate-columns-sorting
	(sort (-appendable-list-get orgtbl-aggregate-columns-sorting)
	      (lambda (a b)
		(if      (null (sorting-strength a))
		    (and (null (sorting-strength b))
			 (<      (sorting-colnum   a) (sorting-colnum   b)))
		  (or    (null (sorting-strength b))
		         (<      (sorting-strength a) (sorting-strength b))
			 (and (= (sorting-strength a) (sorting-strength b))
			      (< (sorting-colnum   a) (sorting-colnum   b)))))))
	))

(defun orgtbl-to-aggregated-table-add-group (groups hgroups row aggcond)
  "Add the source ROW to the GROUPS of rows.
If ROW fits a group within GROUPS, then it is added at the end
of this group. Otherwise a new group is added at the end of GROUPS,
containing this single ROW."
  (and (or (not aggcond)
	   (eval aggcond)) ;; this eval need the variable 'row to have a value
       (let ((gr (gethash row hgroups)))
	 (unless gr
	   (setq gr (-appendable-list-create))
	   (puthash row gr hgroups)
	   (-appendable-list-append groups gr))
	 (-appendable-list-append gr row))))

(defun orgtbl-aggregate-read-calc-expr (expr)
  "Interpret a string as either an org date or a calc expression"
  (cond
   ;; nil happens when a table is malformed
   ;; some columns are missing in some rows
   ((not expr) nil)
   ;; empty cell returned as nil,
   ;; to be processed later depending on modifier flags
   ((equal expr "") nil)
   ;; the purely numerical cell case arises very often
   ;; short-circuiting general functions boosts performance (a lot)
   ((and
     (string-match
      (rx bos
	  (? (any "+-")) (* (any "0-9"))
	  (? "." (* (any "0-9")))
	  (? "e" (? (any "+-")) (+ (any "0-9")))
	  eos)
      expr)
     (not (string-match (rx bos (* (any "+-.")) "e") expr)))
    (math-read-number expr))
   ;; Convert an Org-mode date to Calc internal representation
   ((string-match org-ts-regexp0 expr)
    (math-parse-date (replace-regexp-in-string " *[a-z]+[.]? *" " " expr)))
   ;; Convert a duration into a number of seconds
   ((string-match
     (rx bos
	 (group (any "0-9") (any "0-9"))
	 ":"
	 (group (any "0-9") (any "0-9"))
	 (? ":" (group (any "0-9") (any "0-9")))
	 eos)
     expr)
    (+
     (* 3600 (string-to-number (match-string 1 expr)))
     (*   60 (string-to-number (match-string 2 expr)))
     (if (match-string 3 expr) (string-to-number (match-string 3 expr)) 0)))
   ;; generic case: symbolic calc expression
   (t
    (math-simplify
     (calcFunc-expand
      (math-read-expr expr))))))

(defun orgtbl-aggregate-hash-test-equal (row1 row2)
  "Are two rows from the source table equal regarding the
key columns?"
  (cl-loop for idx in orgtbl-aggregate-var-keycols
	   always (string= (nth idx row1) (nth idx row2))))

;; for hashes, try to stay within the 2^29 fixnums
;; see (info "(elisp) Integer Basics")
;; { prime_next 123 ==> 127 }
;; { prime_prev ((2^29 - 256) / 127 ) ==> 4227323 }

(defun orgtbl-aggregate-hash-test-hash (row)
  "Compute a hash code from key columns."
  (let ((h 45235))
    (cl-loop for idx in orgtbl-aggregate-var-keycols
	     do
	     (cl-loop for c across (nth idx row)
		      do (setq h (% (* (+ h c) 127) 4227323))))
    h))

(defun orgtbl-create-table-aggregated (table params)
  "Convert the source TABLE, which is a list of lists of cells,
into an aggregated table compliant with the columns
specifications (in PARAMS entry :cols), ignoring source rows
which do not pass the filter (in PARAMS entry :cond)."
  (while (eq 'hline (car table))
    (setq table (cdr table)))
  (define-hash-table-test
    'orgtbl-aggregate-hash-test-name
    'orgtbl-aggregate-hash-test-equal
    'orgtbl-aggregate-hash-test-hash)
  (let ((groups (-appendable-list-create))
	(hgroups (make-hash-table :test 'orgtbl-aggregate-hash-test-name))
	(aggcols (plist-get params :cols))
	(aggcond (plist-get params :cond))
	(hline   (plist-get params :hline))
	;; a global variable, passed to the sort predicate
	(orgtbl-aggregate-columns-sorting (-appendable-list-create))
	;; another global variable
	(orgtbl-aggregate-var-keycols))
    (unless aggcols
      (setq aggcols (orgtbl-get-header-table table)))
    (if (stringp aggcols)
	(setq aggcols (split-string-with-quotes aggcols)))
    (cl-loop for col on aggcols
	     do (setcar col (orgtbl-aggregate-parse-col (car col) table)))
    (when aggcond
      (if (stringp aggcond)
	  (setq aggcond (read aggcond)))
      (setq aggcond
	    (orgtbl-to-aggregated-replace-colnames-nth table aggcond)))
    (setq hline
	  (cond ((null hline)
		 0)
		((numberp hline)
		 hline)
		((string-match-p (rx bol (or "yes" "t") eol) hline)
		 1)
		((string-match-p (rx bol (or "no" "nil") eol) hline)
		 0)
		((string-match-p "[0-9]+" hline)
		 (string-to-number hline))
		(t
		 (user-error ":hline parameter should be 0, 1, 2, 3, ... or yes, t, no, nil, not %S" hline))))

    ;; special case: no sorting column but :hline 1 required
    ;; then a hidden hline column is added
    (if (and (> hline 0)
	     (cl-loop for col in aggcols
		      never (outcol-sort col)))
	(push
	 (orgtbl-aggregate-parse-col "hline;^n;<>" table)
	 aggcols))

    (orgtbl-aggregate-prepare-sorting aggcols)

    ; split table into groups of rows
    (cl-loop with b = 0
	     with bs = "0"
	     for row in
	     (or (cdr (memq 'hline table)) ;; skip header if any
		 table)
	     do
	     (cond ((eq row 'hline)
		    (setq b (1+ b)
			  bs (number-to-string b)))
		   ((listp row)
		    (orgtbl-to-aggregated-table-add-group
		     groups
		     hgroups
		     (cons bs row)
		     aggcond))))
    
    (let ((result ;; pre-allocate all resulting rows
	   (cl-loop for x in (-appendable-list-get groups)
		    collect (-appendable-list-create)))
	  (all-$list
	   (cl-loop for x in (-appendable-list-get groups)
		    collect (make-vector (length (car table)) nil))))
      
      ;; inactivating those two functions boosts performance
      (cl-letf (((symbol-function 'math-read-preprocess-string) #'identity)
		((symbol-function 'calc-input-angle-units) (lambda (x) nil)))
	;; do aggregation
	(cl-loop for coldesc in aggcols
		 do
		 (orgtbl-to-aggregated-compute-sums-on-one-column
		  table groups result coldesc all-$list)))

      ;; sort table according to columns described in
      ;; orgtbl-aggregate-columns-sorting
      (if orgtbl-aggregate-columns-sorting ;; are there sorting instructions?
	  (setq result (sort result #'orgtbl-aggregate-sort-predicate)))

      ;; add hlines if requested
      (if (> hline 0)
	  (orgtbl-aggregate-add-hlines result hline))

      ;; add a header to the resulting table with column names
      ;; as they appear in :cols but without decorations
      (setq result
	    (cons
	     (cons nil
		   (cl-loop for column in aggcols
			    collect (or
				     (outcol-name    column)
				     (outcol-formula column))))
	     (cons 'hline result)))

      ;; remove invisible columns by modifying the table in-place
      ;; beware! it assumes that the actual list in -appendable-lists
      ;; is pointed to by the cdr of the -appendable-list
      (if (cl-loop for col in aggcols
		   thereis (outcol-invisible col))
	  (cl-loop for row in result
		   if (consp row)
		   do (cl-loop for col in aggcols
			       with cel = row
			       if (outcol-invisible col)
			       do    (setcdr cel (cddr cel))
			       else do (setq cel (cdr cel)))))

      ;; change appendable-lists to regular lists
      (cl-loop for row on result
	       if (consp (car row))
	       do (setcar row (-appendable-list-get (car row))))

      result)))

(defun orgtbl-aggregate-sort-predicate (linea lineb)
  "Compares LINEA & LINEB (which are Org Mode table rows)
according to orgtbl-aggregate-columns-sorting instructions.
Return nil if LINEA already comes before LINEB."
  (setq linea (-appendable-list-get linea))
  (setq lineb (-appendable-list-get lineb))
  (cl-loop for col in orgtbl-aggregate-columns-sorting
	   for colnum  = (sorting-colnum    col)
	   for desc    = (sorting-ascending col)
	   for extract = (sorting-extract   col)
	   for compare = (sorting-compare   col)
	   for cola = (funcall extract (nth colnum (if desc lineb linea)))
	   for colb = (funcall extract (nth colnum (if desc linea lineb)))
	   thereis (funcall compare cola colb)
	   until   (funcall compare colb cola)))

(defun orgtbl-aggregate-string-to-time (f)
  "Borrowed from org-table.el"
  (cond ((string-match org-ts-regexp-both f)
	 (float-time
	  (org-time-string-to-time (match-string 0 f))))
	((org-duration-p f) (org-duration-to-minutes f))
	((string-match "\\<[0-9]+:[0-9]\\{2\\}\\>" f)
	 (org-duration-to-minutes (match-string 0 f)))
	(t 0)))

(defun orgtbl-aggregate-add-hlines (result hline)
  "Adds hlines to RESULT between different blocks of rows.
Rows are compared on the first HLINE cells
of major sorting columns.
hlines are added in-place"
  (let ((colnums
	 (cl-loop for col in orgtbl-aggregate-columns-sorting
		  for n from 1 to hline
		  collect (sorting-colnum col))))
    (cl-loop for row on result
	     unless
	     (or (null oldrow)
		 (cl-loop for c in colnums
			  always (equal
				  (nth c (-appendable-list-get (car row)))
				  (nth c (-appendable-list-get (car oldrow))))))
	     do (setcdr oldrow (cons 'hline (cdr oldrow)))
	     for oldrow = row)))

(defun orgtbl-aggregate-fmt-settings (fmt)
  "Converts the FMT user-given format into
the FMT-SETTINGS assoc list"
  (let ((fmt-settings (plist-put () :fmt nil)))
    (when fmt
      ;; the following code was freely borrowed from org-table-eval-formula
      ;; not all settings extracted from fmt are used
      (while (string-match "\\([pnfse]\\)\\(-?[0-9]+\\)" fmt)
	(let ((c (string-to-char   (match-string 1 fmt)))
	      (n (string-to-number (match-string 2 fmt))))
	  (if (= c ?p)
	      (setq calc-internal-prec n)
	    (setq calc-float-format
		  (list (cdr (assoc c '((?n . float) (?f . fix)
					(?s . sci) (?e . eng))))
			n)))
	  (setq fmt (replace-match "" t t fmt))))
      (when (string-match "T" fmt)
	(plist-put fmt-settings :duration t)
	(plist-put fmt-settings :numbers  t)
	(plist-put fmt-settings :duration-output-format nil)
	(setq fmt (replace-match "" t t fmt)))
      (when (string-match "t" fmt)
	(plist-put fmt-settings :duration t)
	(plist-put fmt-settings :numbers  t)
	(plist-put fmt-settings :duration-output-format org-table-duration-custom-format)
	(setq fmt (replace-match "" t t fmt)))
      (when (string-match "U" fmt)
	(plist-put fmt-settings :duration t)
	(plist-put fmt-settings :numbers  t)
	(plist-put fmt-settings :duration-output-format 'hh:mm)
	(setq fmt (replace-match "" t t fmt)))
      (when (string-match "N" fmt)
	(plist-put fmt-settings :numbers  t)
	(setq fmt (replace-match "" t t fmt)))
      (when (string-match "L" fmt)
	(plist-put fmt-settings :literal t)
	(setq fmt (replace-match "" t t fmt)))
      (when (string-match "E" fmt)
	(plist-put fmt-settings :keep-empty t)
	(setq fmt (replace-match "" t t fmt)))
      (while (string-match "[DRFSQ]" fmt)
	(cl-case (string-to-char (match-string 0 fmt))
	  (?D (setq calc-angle-mode 'deg))
	  (?R (setq calc-angle-mode 'rad))
	  (?F (setq calc-prefer-frac t))
	  (?S (setq calc-symbolic-mode t))
	  (?Q (plist-put fmt-settings :noeval t)))
	(setq fmt (replace-match "" t t fmt)))
      (when (string-match "\\S-" fmt)
	(plist-put fmt-settings :fmt fmt)))
    fmt-settings))

(defmacro orgtbl-aggregate-calc-setting (setting &optional setting0)
  "Helper function to retrieve a Calc setting either from
org-calc-default-modes or from the setting itself"
  ;; plist-get would be fine, except that there is no way
  ;; to distinguish a value of nil from no value
  ;; so we fallback to memq
  `(let ((x (memq (quote ,setting) org-calc-default-modes)))
     (if x (cadr x)
       (or ,setting ,setting0))))

(defun orgtbl-to-aggregated-compute-sums-on-one-column (table groups result coldesc all-$list)
  "COLDESC is a formula given by the user in :cols, with an optional format.
This function applies the formula over all groups of rows.
Common Calc settings and formats are pre-computed before actually computing sums,
because they are the same for all groups.
RESULT is the list of expected resulting rows. At the beginning, all rows are
empty lists. A cell is appended to every rows at each call of this function."

  ;; within this (let), we locally set Calc settings that must be active
  ;; for all the calls to Calc:
  ;; (orgtbl-aggregate-read-calc-expr) and (math-format-value)
  (let ((calc-internal-prec 	      (orgtbl-aggregate-calc-setting calc-internal-prec))
	(calc-float-format  	      (orgtbl-aggregate-calc-setting calc-float-format ))
	(calc-angle-mode    	      (orgtbl-aggregate-calc-setting calc-angle-mode   ))
	(calc-prefer-frac   	      (orgtbl-aggregate-calc-setting calc-prefer-frac  ))
	(calc-symbolic-mode 	      (orgtbl-aggregate-calc-setting calc-symbolic-mode))
	(calc-date-format   	      (orgtbl-aggregate-calc-setting calc-date-format '(YYYY "-" MM "-" DD " " www (" " hh ":" mm))))
	(calc-display-working-message (orgtbl-aggregate-calc-setting calc-display-working-message))
	(fmt-settings nil)
	(case-fold-search nil))

    ;; get that out of the (let) because its purpose is to override
    ;; what the (let) has set
    (setq fmt-settings (orgtbl-aggregate-fmt-settings (outcol-format coldesc)))

    (cl-loop for group in (-appendable-list-get groups)
	     for row in result
	     for $list in all-$list
	     do
	     (-appendable-list-append
	      row
	      (orgtbl-to-aggregated-compute-one-sum
	       table
	       group
	       coldesc
	       fmt-settings
	       $list)))))

(defun orgtbl-to-aggregated-compute-one-sum (table group coldesc fmt-settings $list)
  "Apply a user given formula to one group of input rows.
The formula is contained in coldesc-formula-frux.
Column names have been replaced by Frux(3) forms.
Those Frux(N) froms are placeholders that will be replaced
by Calc vectors of values extracted from the input table,
in column N.
coldesc-involved is a list of columns numbers used by coldesc-formula-frux.
$LIST is a Lisp-vector of Calc-vectors of values from the input table
parsed by Calc. $LIST acts as a cache. When a value is missing, it is
computed, and stored in $LIST. But if there is already a value,
a re-computation is saved.
Return an output cell.
When coldesc-key is non-nil, then a key-column is considered,
and a cell from any row in the group is returned."
  (cond
   ;; key column
   ((outcol-key coldesc)
    (nth (outcol-key coldesc)
	 (car (-appendable-list-get group))))
   ;; do not evaluate
   ((plist-get fmt-settings :noeval)
    (outcol-formula$ coldesc))
   ;; vlist($3) alone, without parenthesis or other decoration
   ((string-match
     (rx bos (? ?v) "list"
	 (* (any " \t")) "(" (* (any " \t"))
	 "$" (group (+ (any "0-9")))
	 (* (any " \t")) ")" (* (any " \t")) eos)
     (outcol-formula$ coldesc))
    (mapconcat
     #'identity
     (cl-loop with i =
	      (string-to-number (match-string 1 (outcol-formula$ coldesc)))
	      for row in (-appendable-list-get group)
	      collect (nth i row))
     ", "))
   (t
    ;; all other cases: handle them to Calc
    (let ((calc-dollar-values
	   (orgtbl-to-aggregated-make-calc-$-list
	    table
	    group
	    fmt-settings
	    (outcol-involved coldesc)
	    $list))
	  (calc-command-flags nil)
	  (calc-next-why nil)
	  (calc-language 'flat)
	  (calc-dollar-used 0))
      (let ((ev
	     (math-format-value
	      (math-simplify
	       (calcFunc-expand	  ; yes, double expansion
		(calcFunc-expand  ; otherwise it is not fully expanded
		 (math-simplify
		  (orgtbl-to-aggregated-defrux
		    (outcol-formula-frux coldesc)
		    calc-dollar-values
		    (length (-appendable-list-get group)))))))
	      1000)))
	(cond
	 ((plist-get fmt-settings :fmt)
	  (format (plist-get fmt-settings :fmt) (string-to-number ev)))
	 ((plist-get fmt-settings :duration)
	  (org-table-time-seconds-to-string
	   (string-to-number ev)
	   (plist-get fmt-settings :duration-output-format)))
	 (t ev)))))))

(defun orgtbl-to-aggregated-defrux (formula-frux calc-dollar-values count)
  "Replaces all Frux(N) expressions in FORMULA-FRUX with
Calc-vectors found in CALC-DOLLAR-VALUES. It also replaces
vcount() forms with the actual number of rows in the current group"
  (cond
   ((not (consp formula-frux))
    formula-frux)
   ((memq (car formula-frux) '(calcFunc-Frux calcFunc-FRUX))
    (nth (1- (cadr formula-frux)) calc-dollar-values))
   ((eq (car formula-frux) 'calcFunc-vcount)
    count)
   (t
    (cl-loop
     for x in formula-frux
     collect (orgtbl-to-aggregated-defrux x calc-dollar-values count)))))

(defun orgtbl-to-aggregated-make-calc-$-list (table group fmt-settings involved $list)
  "Prepare a list of vectors that will use to replace Frux(N) expressions.
Frux(1) will be replaced by the first element of list, Frux(2) by the second an so on.
The vectors follow the Calc syntax: (vec a b c ...). They contain values
extracted from rows of the current GROUP. Vectors are created only for
column numbers in INVOLVED.
In FMT-SETTINGS, :KEEP-EMPTY is a flag to tell whether an empty cell
should be converted to NAN or ignored.
:NUMBERS is a flag to replace non numeric values by 0."
  (cl-loop
   for i in involved
   unless (aref $list (1- i))
   do (aset
       $list (1- i)
       (cons 'vec
	     (cl-loop for row in (-appendable-list-get group)
		      collect
		      (orgtbl-aggregate-read-calc-expr (nth i row))))))
  (cl-loop
   for vec across $list
   for i from 1
   collect
   (when (memq i involved)
     (let ((vecc
	    (if (plist-get fmt-settings :keep-empty)
		(cl-loop for x in vec
			 collect (if x x '(var nan var-nan)))
	      (cl-loop for x in vec
		       if x
		       collect x))))
       (if (plist-get fmt-settings :numbers)
	   (cl-loop for x on (cdr vecc)
		    unless (math-numberp (car x))
		    do (setcar x 0)))
       vecc))))

;; aggregation in Push mode

;;;###autoload
(defun orgtbl-to-aggregated-table (table params)
  "Convert the orgtbl-mode TABLE to another orgtbl-mode table
with material aggregated.
Grouping of rows is done for identical values of grouping columns.
For each group, aggregation (sum, mean, etc.) is done for other columns.
  
The source table must contain sending directives with the following format:
#+ORGTBL: SEND destination orgtbl-to-aggregated-table :cols ... :cond ...

The destination must be specified somewhere in the same file
with a block like this:
  #+BEGIN RECEIVE ORGTBL destination
  #+END RECEIVE ORGTBL destination

:cols     gives the specifications of the resulting columns.
          It is a space-separated list of column specifications.
          Example:
             P Q sum(X) max(X) mean(Y)
          Which means:
             group rows with similar values in columns P and Q,
             and for each group, compute the sum of elements in
             column X, etc.

          The specification for a resulting column may be:
             COL              the name of a grouping column in the source table
             hline            a special name for grouping rows separated
                              by horizontal lines
             count()          give the number of rows in each group
             list(COL)        list the values of the column for each group
             sum(COL)         compute the sum of the column for each group
             sum(COL1*COL2)   compute the sum of the product of two columns
                              for each group
             mean(COL)        compute the average of the column for each group
             mean(COL1*COL2)  compute the average of the product of two columns
                              for each group
             meane(COL)       compute the average along with the estimated error
             hmean(COL)       compute the harmonic average
             gmean(COL)       compute the geometric average
             median(COL)      give the middle element after sorting them
             max(COL)         gives the largest element of each group
             min(COL)         gives the smallest element of each group
             sdev(COL)        compute the standard deviation (divide by N-1)
             psdev(COL)       compute the population standard deviation (divide by N)
             pvar(COL)        compute the variance
             prod(COL)        compute the product
             cov(COL1,COL2)   compute the covariance of two columns
                              for each group (divide by N-1)
             pcov(COL1,COL2)  compute the population covariance of two columns
                              for each group (/N)
             corr(COL1,COL2)  compute the linear correlation of two columns

:cond     optional
          a lisp expression to filter out rows in the source table
          when the expression evaluate to nil for a given row of the source table,
          then this row is discarded in the resulting table
          Example:
             (equal Q \"b\")
          Which means: keep only source rows for which the column Q has the value b

Columns in the source table may be in the dollar form,
for example $3 to name the 3th column,
or by its name if the source table have a header.
If all column names are in the dollar form,
the table is supposed not to have a header.
The special column name \"hline\" takes values from zero and up
and is incremented by one for each horizontal line.

Example:
add a line like this one before your table
,#+ORGTBL: SEND aggregatedtable orgtbl-to-aggregated-table :cols \"sum(X) q sum(Y) mean(Z) sum(X*X)\"
then add somewhere in the same file the following lines:
,#+BEGIN RECEIVE ORGTBL aggregatedtable
,#+END RECEIVE ORGTBL aggregatedtable
Type C-c C-c into your source table

Note:
 This is the 'push' mode for aggregating a table.
 To use the 'pull' mode, look at the org-dblock-write:aggregate function.
"
  (interactive)
  (let ((aggregated-table
	 (orgtbl-create-table-aggregated table params)))
    (with-temp-buffer
      (buffer-disable-undo)
      (orgtbl-insert-elisp-table aggregated-table)
      (buffer-substring-no-properties (point-min) (1- (point-max))))))

;; aggregation in Pull mode

;;;###autoload
(defun org-dblock-write:aggregate (params)
  "Creates a table which is the aggregation of material from another table.
Grouping of rows is done for identical values of grouping columns.
For each group, aggregation (sum, mean, etc.) is done for other columns.

:table    name of the source table

:cols     gives the specifications of the resulting columns.
          It is a space-separated list of column specifications.
          Example:
             \"P Q sum(X) max(X) mean(Y)\"
          Which means:
             group rows with similar values in columns P and Q,
             and for each group, compute the sum of elements in
             column X, etc.

          The specification for a resulting column may be:
             COL              the name of a grouping column in the source table
             hline            a special name for grouping rows separated
                              by horizontal lines
             count()          give the number of rows in each group
             list(COL)        list the values of the column for each group
             sum(COL)         compute the sum of the column for each group
             sum(COL1*COL2)   compute the sum of the product of two columns
                              for each group
             mean(COL)        compute the average of the column for each group
             mean(COL1*COL2)  compute the average of the product of two columns
                              for each group
             meane(COL)       compute the average along with the estimated error
             hmean(COL)       compute the harmonic average
             gmean(COL)       compute the geometric average
             median(COL)      give the middle element after sorting them
             max(COL)         gives the largest element of each group
             min(COL)         gives the smallest element of each group
             sdev(COL)        compute the standard deviation (divide by N-1)
             psdev(COL)       compute the population standard deviation (divide by N)
             pvar(COL)        compute the variance
             prod(COL)        compute the product
             cov(COL1,COL2)   compute the covariance of two columns
                              for each group (divide by N-1)
             pcov(COL1,COL2)  compute the population covariance of two columns
                              for each group (/N)
             corr(COL1,COL2)  compute the linear correlation of two columns

:cond     optional
          a lisp expression to filter out rows in the source table
          when the expression evaluate to nil for a given row of the source table,
          then this row is discarded in the resulting table
          Example:
             (equal Q \"b\")
          Which means: keep only source rows for which the column Q has the value b

Columns in the source table may be in the dollar form,
for example $3 to name the 3th column,
or by its name if the source table have a header.
If all column names are in the dollar form,
the table is supposed not to have a header.
The special column name \"hline\" takes values from zero and up
and is incremented by one for each horizontal line.

Example:
- Create an empty dynamic block like this:
  #+BEGIN: aggregate :table originaltable :cols \"sum(X) Q sum(Y) mean(Z) sum(X*X)\"
  #+END
- Type C-c C-c over the BEGIN line
  this fills in the block with an aggregated table

Note:
 This is the 'pull' mode for aggregating a table.
 To use the 'push' mode, look at the orgtbl-to-aggregated-table function.
"
  (interactive)
  (let ((formula (plist-get params :formula))
	(content (plist-get params :content))
	(tblfm nil))
    (if (and content
	     (let ((case-fold-search t))
	       (string-match
		(rx bos (* (any " \t")) (group "#+" (? "tbl") "name:" (* not-newline)))
		content)))
	(insert (match-string 1 content) "\n"))
    (orgtbl-insert-elisp-table
     (orgtbl-create-table-aggregated
      (orgtbl-get-distant-table (plist-get params :table))
      params))

    (delete-char -1) ;; remove trailing \n which Org Mode will add again
    (if (and content
	     (let ((case-fold-search t))
	       (string-match
		(rx bol (* (any " \t")) (group "#+tblfm:" (* not-newline)))
		content)))
	(setq tblfm (match-string 1 content)))
    (when (stringp formula)
      (if tblfm
	  (unless (string-match (rx-to-string formula) tblfm)
	    (setq tblfm (format "%s::%s" tblfm formula)))
	(setq tblfm (format "#+TBLFM: %s" formula))))
    (when tblfm
      (end-of-line)
      (insert "\n" tblfm)
      (forward-line -1)
      (condition-case nil
	  (org-table-recalculate 'all)
	(args-out-of-range nil)))))

(defvar orgtbl-aggregate-history-cols ())

;;;###autoload
(defun org-insert-dblock:aggregate ()
  "Wizard to interactively insert an aggregate dynamic block."
  (interactive)
  (let* ((table
	  (completing-read
	   "Table name: "
	   (orgtbl-list-local-tables)
	   nil
	   'confirm))
	 (header
	  (condition-case err (orgtbl-get-header-table table t)
	    (t "$1 $2 $3 $4 ...")))
	 (aggcols
	  (replace-regexp-in-string
	   "\"" "'"
	   (read-string
	    (format "target columns (source columns are: %s): " header)
	    nil 'orgtbl-aggregate-history-cols)))
	 (aggcond
	  (read-string
	   (format
	    "condition (optional lisp function operating on: %s): "
	    header)
	   nil 'orgtbl-aggregate-history-cols))
	 (params (list :name "aggregate" :table table :cols aggcols)))
    (unless (equal aggcond "")
      (nconc params (list :cond (read aggcond))))
    (org-create-dblock params)
    (org-update-dblock)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; The Transposition package

(defun orgtbl-create-table-transposed (table cols aggcond)
  "Convert the source TABLE, which is a list of lists of cells,
into a transposed table compliant with the COLS source columns list,
ignoring source rows which do not pass the AGGCOND.
If COLS is nil, all source columns are taken.
If AGGCOND is nil, all source rows are taken"
  (if (stringp cols)
      (setq cols (split-string-with-quotes cols)))
  (setq cols
        (if cols
	    (cl-loop for column in cols
		     collect
		     (orgtbl-to-aggregated-table-colname-to-int column table t))
          (let ((head table))
	    (while (eq (car head) 'hline)
	      (setq head (cdr head)))
	    (cl-loop for x in (car head)
		     for i from 1
		     collect i))))
  (if aggcond
      (setq aggcond (orgtbl-to-aggregated-replace-colnames-nth table aggcond)))
  (let ((result (cl-loop for x in cols collect (list t)))
        (nhline 0))
    (cl-loop for row in table
	     do
	     (if (eq row 'hline)
		 (setq nhline (1+ nhline))
	       (setq row (cons nhline row)))
	     do
	     (when (or (eq row 'hline) (not aggcond) (eval aggcond))
	       (cl-loop
		for spec in cols
		for r in result
		do
		(nconc r (list (if (eq row 'hline) "" (nth spec row)))))))
    (cl-loop for row in result
	     do (pop row)
	     collect
	     (if (cl-loop for x in row
			  always (equal "" x))
		 'hline
	       row))))

;;;###autoload
(defun orgtbl-to-transposed-table (table params)
  "Convert the orgtbl-mode TABLE to a transposed version.
Rows become columns, columns become rows.

The source table must contain sending directives with the following format:
#+ORGTBL: SEND destination orgtbl-to-transposed-table :cols ... :cond ...

The destination must be specified somewhere in the same file
with a bloc like this:
  #+BEGIN RECEIVE ORGTBL destination
  #+END RECEIVE ORGTBL destination

:cols     optional, if omitted all source columns are taken.
          Columns specified here will become rows in the result.
          Valid specifications are
          - names as they appear in the first row of the source table
          - $N forms, starting from $1
          - the special hline column which is the numbering of
            blocks separated by horizontal lines in the source table

:cond     optional
          a lisp expression to filter out rows in the source table
          when the expression evaluate to nil for a given row of the source table,
          then this row is discarded in the resulting table
          Example:
             (equal Q \"b\")
          Which means: keep only source rows for which the column Q has the value b

Columns in the source table may be in the dollar form,
for example $3 to name the 3th column,
or by its name if the source table have a header.
If all column names are in the dollar form,
the table is supposed not to have a header.
The special column name \"hline\" takes values from zero and up
and is incremented by one for each horizontal line.

Horizontal lines are converted to empty columns,
and the other way around.

The destination must be specified somewhere in the same file
with a block like this:
  #+BEGIN RECEIVE ORGTBL destination_table_name
  #+END RECEIVE ORGTBL destination_table_name

Type C-c C-c in the source table to re-create the transposed version.

Note:
 This is the 'push' mode for transposing a table.
 To use the 'pull' mode, look at the org-dblock-write:transpose function.
"
  (interactive)
  (let ((transposed-table
	 (orgtbl-create-table-transposed
	  table
	  (plist-get params :cols)
	  (plist-get params :cond))))
    (with-temp-buffer
      (buffer-disable-undo)
      (orgtbl-insert-elisp-table transposed-table)
      (buffer-substring-no-properties (point-min) (1- (point-max))))))

;;;###autoload
(defun org-dblock-write:transpose (params)
  "Create a transposed version of the orgtbl TABLE
Rows become columns, columns become rows.

:table    names the source table

:cols     optional, if omitted all source columns are taken.
          Columns specified here will become rows in the result.
          Valid specifications are
          - names as they appear in the first row of the source table
          - $N forms, starting from $1
          - the special hline column which is the numbering of
            blocks separated by horizontal lines in the source table

:cond     optional
          a lisp expression to filter out rows in the source table
          when the expression evaluate to nil for a given row of the source table,
          then this row is discarded in the resulting table
          Example:
             (equal q \"b\")
          Which means: keep only source rows for which the column q has the value b

Columns in the source table may be in the dollar form,
for example $3 to name the 3th column,
or by its name if the source table have a header.
If all column names are in the dollar form,
the table is supposed not to have a header.
The special column name \"hline\" takes values from zero and up
and is incremented by one for each horizontal line.

Horizontal lines are converted to empty columns,
and the other way around.

- Create an empty dynamic block like this:
  #+BEGIN: aggregate :table originaltable
  #+END
- Type C-c C-c over the BEGIN line
  this fills in the block with the transposed table

Note:
 This is the 'pull' mode for transposing a table.
 To use the 'push' mode, look at the orgtbl-to-transposed-table function.
"
  (interactive)
  (let ((formula (plist-get params :formula))
	(content (plist-get params :content))
	(tblfm nil))
    (if (and content
	     (let ((case-fold-search t))
	       (string-match
		(rx bos (* (any " \t")) (group "#+" (? "tbl") "name:" (* not-newline)))
		content)))
	(insert (match-string 1 content) "\n"))
    (orgtbl-insert-elisp-table
     (orgtbl-create-table-transposed
      (orgtbl-get-distant-table (plist-get params :table))
      (plist-get params :cols)
      (plist-get params :cond)))
    (delete-char -1) ;; remove trailing \n which Org Mode will add again
    (if (and content
	     (let ((case-fold-search t))
	       (string-match
		(rx bol (* (any " \t")) (group "#+tblfm:" (* not-newline)))
		content)))
	(setq tblfm (match-string 1 content)))
    (when (stringp formula)
      (if tblfm
	  (unless (string-match (rx-to-string formula) tblfm)
	    (setq tblfm (format "%s::%s" tblfm formula)))
	(setq tblfm (format "#+TBLFM: %s" formula))))
    (when tblfm
      (end-of-line)
      (insert "\n" tblfm)
      (forward-line -1)
      (condition-case nil
	  (org-table-recalculate 'all)
	(args-out-of-range nil)))))

;;;###autoload
(defun org-insert-dblock:transpose ()
  "Wizard to interactively insert a transpose dynamic block."
  (interactive)
  (let* ((table
	  (completing-read
	   "Table name: "
	   (orgtbl-list-local-tables)
	   nil
	   'confirm))
	 (header
	  (condition-case err (orgtbl-get-header-table table t)
	    (t "$1 $2 $3 $4 ...")))
	 (aggcols
	  (replace-regexp-in-string
	   "\"" "'"
	   (read-string
	    (format
	     "target columns (empty for all) (source columns are: %s): "
	     header)
	    nil 'orgtbl-aggregate-history-cols)))
	 (aggcond
	  (read-string
	   (format
	    "condition (optional lisp function) (source columns: %s): "
	    header)
	   nil 'orgtbl-aggregate-history-cols))
	 (params (list :name "transpose" :table table)))
    (unless (equal aggcols "")
      (nconc params (list :cols aggcols)))
    (unless (equal aggcond "")
      (nconc params (list :cond (read aggcond))))
    (org-create-dblock params)
    (org-update-dblock)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; wizards

;; Insert a dynamic bloc with the C-c C-x x dispatcher
;;;###autoload
(eval-after-load 'org
  '(when (fboundp 'org-dynamic-block-define)
     (org-dynamic-block-define "aggregate" #'org-insert-dblock:aggregate)
     (org-dynamic-block-define "transpose" #'org-insert-dblock:transpose)))

(provide 'orgtbl-aggregate)
;;; orgtbl-aggregate.el ends here
