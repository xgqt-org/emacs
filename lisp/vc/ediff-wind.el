;;; ediff-wind.el --- window manipulation utilities  -*- lexical-binding:t -*-

;; Copyright (C) 1994-2025 Free Software Foundation, Inc.

;; Author: Michael Kifer <kifer@cs.stonybrook.edu>
;; Package: ediff

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(defvar icon-title-format)
(defvar ediff-diff-status)

(require 'ediff-init)
(require 'ediff-help)

(defgroup ediff-window nil
  "Ediff window manipulation."
  :prefix "ediff-"
  :group 'ediff
  :group 'frames)

(defcustom ediff-window-setup-function #'ediff-setup-windows-default
  "Function called to set up windows.
Ediff provides a choice of three functions:
 (1) `ediff-setup-windows-multiframe', which sets the control panel
     in a separate frame.
 (2) `ediff-setup-windows-plain', which does everything in one frame
 (3) `ediff-setup-windows-default' (the default), which does (1)
     on a graphical display and (2) on a text terminal.

The command \\[ediff-toggle-multiframe] can be used to toggle
between the multiframe display and the single frame display.  If
the multiframe function detects that one of the buffers A/B is
seen in some other frame, it will try to keep that buffer in that
frame.

If you don't like any of the two provided functions, write your own one.
The basic guidelines:
    1. It should leave the control buffer current and, if showing,
       the control window selected if showing these windows.
    2. It should set `ediff-window-A', `ediff-window-B', `ediff-window-C',
       and `ediff-control-window' to contain window objects that display
       the corresponding buffers or `nil' if the corresponding window
       is not shown.
    3. It should accept the following arguments:
       buffer-A, buffer-B, buffer-C, control-buffer
       Buffer C may not be used in jobs that compare only two buffers.
If you plan to do something fancy, take a close look at how the two
provided functions are written.

Set `ediff-select-control-window-on-setup' to nil to prevent the window
`ediff-control-window' being selected by ediff after this
function returns. "
  :type '(choice (const :tag "Choose Automatically" ediff-setup-windows-default)
		 (const :tag "Multi Frame" ediff-setup-windows-multiframe)
		 (const :tag "Single Frame" ediff-setup-windows-plain)
		 (function :tag "Other function"))
  :version "24.3")

(defcustom ediff-floating-control-frame nil
  "If non-nil, try making the control frame be floating rather than tiled.

If your X window manager makes the Ediff control frame a tiled one,
set this to a non-nil value, and Emacs will try to make it floating.
This only has effect on X displays."
  :type '(choice (const :tag "Control frame floats" t)
                 (const :tag "Control frame has default WM behavior" nil))
  :version "30.1")

(ediff-defvar-local ediff-multiframe nil
  "Indicates if we are in a multiframe setup.")

(ediff-defvar-local ediff-merge-window-share 0.45
  "Share of the frame occupied by the merge window (buffer C).")

(ediff-defvar-local ediff-control-window nil
  "The control window.")
(ediff-defvar-local ediff-window-A nil
  "Official window for buffer A.")
(ediff-defvar-local ediff-window-B nil
  "Official window for buffer B.")
(ediff-defvar-local ediff-window-C nil
  "Official window for buffer C.")
(ediff-defvar-local ediff-window-Ancestor nil
  "Official window for buffer Ancestor.")
(ediff-defvar-local ediff-window-config-saved ""
  "Ediff's window configuration.
Used to minimize the need to rearrange windows.")

;; Association between buff-type and ediff-window-*
(defconst ediff-window-alist
  '((A . ediff-window-A)
    (?A . ediff-window-A)
    (B . ediff-window-B)
    (?B . ediff-window-B)
    (C . ediff-window-C)
    (?C . ediff-window-C)
    (Ancestor . ediff-window-Ancestor)))


(defcustom ediff-split-window-function #'split-window-vertically
  "The function used to split the main window between buffer-A and buffer-B.
You can set it to a horizontal split instead of the default vertical split
by setting this variable to `split-window-horizontally'.
You can also have your own function to do fancy splits.
This variable has no effect when buffer-A/B are shown in different frames.
In this case, Ediff will use those frames to display these buffers."
  :type '(choice
	  (const :tag "Split vertically" split-window-vertically)
	  (const :tag "Split horizontally" split-window-horizontally)
	  function))

(defcustom ediff-merge-split-window-function #'split-window-horizontally
  "The function used to split the main window between buffer-A and buffer-B.
You can set it to a vertical split instead of the default horizontal split
by setting this variable to `split-window-vertically'.
You can also have your own function to do fancy splits.
This variable has no effect when buffer-A/B/C are shown in different frames.
In this case, Ediff will use those frames to display these buffers."
  :type '(choice
	  (const :tag "Split vertically" split-window-vertically)
	  (const :tag "Split horizontally" split-window-horizontally)
	  function))

(defconst ediff-control-frame-parameters
  (list
   '(name . "Ediff")
   ;;'(unsplittable . t)
   '(minibuffer . nil)
   '(user-position . t)
   '(vertical-scroll-bars . nil)
   '(menu-bar-lines . 0)
   '(tool-bar-lines . 0)
   '(left-fringe    . 0)
   '(right-fringe   . 0)
   ;; don't lower but auto-raise
   '(auto-lower . nil)
   '(auto-raise . t)
   '(visibility . nil)
   ;; make initial frame small to avoid distraction
   '(width . 1) '(height . 1)
   ;; Fullscreen control frames don't make sense (Bug#29026).
   '(fullscreen . nil)
   ;; this blocks queries from  window manager as to where to put
   ;; ediff's control frame. we put the frame outside the display,
   ;; so the initial frame won't jump all over the screen
   (cons 'top  (if (fboundp 'display-pixel-height)
		   (1+ (display-pixel-height))
		 3000))
   (cons 'left (if (fboundp 'display-pixel-width)
		   (1+ (display-pixel-width))
		 3000))
   )
  "Frame parameters for displaying Ediff Control Panel.
Used internally---not a user option.")

(ediff-defvar-local ediff-mouse-pixel-position nil
  "Position of the mouse.
Used to decide whether to warp the mouse into control frame.")
(make-obsolete-variable 'ediff-mouse-pixel-position "it is unused." "29.1")

;; not used for now
(defvar ediff-mouse-pixel-threshold 30
  "If mouse moved more than this many pixels, don't warp mouse into control window.")

(defcustom ediff-grab-mouse t
  "If t, Ediff will always grab the mouse and put it in the control frame.
If `maybe', Ediff will do it sometimes, but not after operations that require
relatively long time.  If nil, the mouse will be entirely user's
responsibility."
  :type 'boolean)

(defcustom ediff-control-frame-position-function #'ediff-make-frame-position
  "Function to call to determine the desired location for the control panel.
Expects three parameters: the control buffer, the desired width and height
of the control frame.  It returns an association list
of the form \((top . <position>) \(left . <position>))"
  :type 'function)

(defcustom ediff-control-frame-upward-shift 42
  "The upward shift of control frame from the top of buffer A's frame.
Measured in pixels.
This is used by the default control frame positioning function,
`ediff-make-frame-position'.  This variable is provided for easy
customization of the default control frame positioning."
  :type 'integer)

(defcustom ediff-narrow-control-frame-leftward-shift 3
  "The leftward shift of control frame from the right edge of buf A's frame.
Measured in characters.
This is used by the default control frame positioning function,
`ediff-make-frame-position' to adjust the position of the control frame
when it shows the short menu.  This variable is provided for easy
customization of the default."
  :type 'integer)

(defcustom ediff-wide-control-frame-rightward-shift 7
  "The rightward shift of control frame from the left edge of buf A's frame.
Measured in characters.
This is used by the default control frame positioning function,
`ediff-make-frame-position' to adjust the position of the control frame
when it shows the full menu.  This variable is provided for easy
customization of the default."
  :type 'integer)


;; Wide frame display

(ediff-defvar-local ediff-wide-display-p nil
  "If t, Ediff is using wide display.")
(ediff-defvar-local ediff-wide-display-orig-parameters nil
  "Frame parameters to restore when toggling the wide display off.")
(ediff-defvar-local ediff-wide-display-frame nil
  "Frame to be used for wide display.")
(ediff-defvar-local ediff-make-wide-display-function #'ediff-make-wide-display
  "The value is a function that is called to create a wide display.
The function is called without arguments.  It should resize the frame in
which buffers A, B, and C are to be displayed, and it should save the old
frame parameters in `ediff-wide-display-orig-parameters'.
The variable `ediff-wide-display-frame' should be set to contain
the frame used for the wide display.")

(ediff-defvar-local ediff-control-frame nil
  "Frame used for the control panel in a windowing system.")

(defcustom ediff-prefer-iconified-control-frame nil
  "If t, keep control panel iconified when help message is off.
This has effect only on a windowing system.
If t, hitting `?' to toggle control panel off iconifies it.

This is only useful for certain kinds of window managers, such as
TWM and its derivatives, since the window manager must permit
keyboard input to go into icons."
  :type 'boolean)

;;; Functions

(defmacro ediff-with-live-window (window &rest body)
  "Like `with-selected-window' but only if WINDOW is live.
If WINDOW is not live (or not a window) do nothing and don't evaluate
BODY, instead returning nil."
  (declare (indent 1) (debug (form body)))
  (cl-once-only (window)
    `(when (window-live-p ,window)
       (with-selected-window ,window
         ,@body))))

(defun ediff-get-window-by-clicking (_wind _prev-wind wind-number)
  (let (event)
    (message
     "Select windows by clicking.  Please click on Window %d " wind-number)
    (while (not (mouse-event-p (setq event
                                     (read--potential-mouse-event))))
      (if (sit-for 1) ; if sequence of events, wait till the final word
	  (beep 1))
      (message "Please click on Window %d " wind-number))
    (read--potential-mouse-event) ; discard event
    (posn-window (event-start event))))


;; Select the lowest window on the frame.
(defun ediff-select-lowest-window ()
  (let* ((lowest-window (selected-window))
	 (bottom-edge (car (cdr (cdr (cdr (window-edges))))))
	 (last-window (save-excursion
			(other-window -1) (selected-window)))
	 (window-search t))
    (while window-search
      (let* ((this-window (next-window))
	     (next-bottom-edge
	      (car (cdr (cdr (cdr (window-edges this-window)))))))
	(if (< bottom-edge next-bottom-edge)
	    (setq bottom-edge next-bottom-edge
		  lowest-window this-window))
	(select-window this-window)
	(when (eq last-window this-window)
	  (select-window lowest-window)
	  (setq window-search nil))))))


;;; Common window setup routines

;; Set up the window configuration.  If POS is given, set the points to
;; the beginnings of the buffers.
;; When 3way comparison is added, this will have to choose the appropriate
;; setup function based on ediff-job-name
(defun ediff-setup-windows (buffer-A buffer-B buffer-C control-buffer)
  ;; Make sure we are not in the minibuffer window when we try to delete
  ;; all other windows.
  (run-hooks 'ediff-before-setup-windows-hook)
  (if (eq (selected-window) (minibuffer-window))
      (other-window 1))

  ;; in case user did a no-no on a tty
  (or (display-graphic-p)
      (setq ediff-window-setup-function #'ediff-setup-windows-plain))

  (or (ediff-keep-window-config control-buffer)
      (funcall
       (with-current-buffer control-buffer ediff-window-setup-function)
       buffer-A buffer-B buffer-C control-buffer))
  (run-hooks 'ediff-after-setup-windows-hook))

(defun ediff-setup-windows-default (buffer-A buffer-B buffer-C control-buffer)
  (funcall (if (display-graphic-p)
	       #'ediff-setup-windows-multiframe
	     #'ediff-setup-windows-plain)
	   buffer-A buffer-B buffer-C control-buffer))

;; Just set up 3 windows.
;; Usually used without windowing systems
;; With windowing, we want to use dedicated frames.
(defun ediff-setup-windows-plain (buffer-A buffer-B buffer-C control-buffer)
  (with-current-buffer control-buffer
    (setq ediff-multiframe nil))
  (if ediff-merge-job
      (ediff-setup-windows-plain-merge
       buffer-A buffer-B buffer-C control-buffer)
    (ediff-setup-windows-plain-compare
     buffer-A buffer-B buffer-C control-buffer)))

(autoload 'ediff-setup-control-buffer "ediff-util")

(defun ediff-setup-windows-plain-merge (buf-A buf-B buf-C control-buffer)
  ;; skip dedicated and unsplittable frames
  (ediff-destroy-control-frame control-buffer)
  (let ((window-min-height 1)
	(with-Ancestor-p (with-current-buffer control-buffer
                           ediff-merge-with-ancestor-job))
	split-window-function
	merge-window-share merge-window-lines
	(buf-Ancestor (with-current-buffer control-buffer
                        ediff-ancestor-buffer))
	wind-A wind-B wind-C wind-Ancestor)
    (with-current-buffer control-buffer
      (setq merge-window-share ediff-merge-window-share
	    ;; this lets us have local versions of ediff-split-window-function
	    split-window-function ediff-split-window-function))
    (delete-other-windows)
    (set-window-dedicated-p (selected-window) nil)
    (split-window-vertically)
    (ediff-select-lowest-window)
    (ediff-setup-control-buffer control-buffer)

    ;; go to the upper window and split it betw A, B, and possibly C
    (other-window 1)
    (setq merge-window-lines
	  (max 2 (round (* (window-height) merge-window-share))))
    (switch-to-buffer buf-A)
    (setq wind-A (selected-window))

    (split-window-vertically (max 2 (- (window-height) merge-window-lines)))
    (if (eq (selected-window) wind-A)
	(other-window 1))
    (setq wind-C (selected-window))
    (switch-to-buffer buf-C)

    (when (and ediff-show-ancestor with-Ancestor-p)
      (select-window wind-C)
      (funcall split-window-function)
      (when (eq (selected-window) wind-C)
        (other-window 1))
      (switch-to-buffer buf-Ancestor)
      (setq wind-Ancestor (selected-window)))

    (select-window wind-A)
    (funcall split-window-function)

    (if (eq (selected-window) wind-A)
	(other-window 1))
    (switch-to-buffer buf-B)
    (setq wind-B (selected-window))

    (with-current-buffer control-buffer
      (setq ediff-window-A wind-A
	    ediff-window-B wind-B
	    ediff-window-C wind-C
            ediff-window-Ancestor wind-Ancestor))

    (ediff-select-lowest-window)
    (ediff-setup-control-buffer control-buffer)
    ))


;; This function handles all comparison jobs, including 3way jobs
(defun ediff-setup-windows-plain-compare (buf-A buf-B buf-C control-buffer)
  ;; skip dedicated and unsplittable frames
  (ediff-destroy-control-frame control-buffer)
  (let ((window-min-height 1)
        (window-combination-resize t)
	split-window-function
	three-way-comparison
	wind-A-start wind-B-start wind-A wind-B wind-C)
    (with-current-buffer control-buffer
      (setq wind-A-start (ediff-overlay-start
			  (ediff-get-value-according-to-buffer-type
			   'A ediff-narrow-bounds))
	    wind-B-start (ediff-overlay-start
			  (ediff-get-value-according-to-buffer-type
			   'B  ediff-narrow-bounds))
	    ;; this lets us have local versions of ediff-split-window-function
	    split-window-function ediff-split-window-function
	    three-way-comparison ediff-3way-comparison-job))
    ;; if in minibuffer go somewhere else
    (if (save-match-data
	  (string-match "\\*Minibuf-" (buffer-name (window-buffer))))
	(select-window (next-window nil 'ignore-minibuf)))
    (delete-other-windows)
    (set-window-dedicated-p (selected-window) nil)

    ;; go to the upper window and split it betw A, B, and possibly C
    (other-window 1)
    (switch-to-buffer buf-A)
    (setq wind-A (selected-window))
    (funcall split-window-function)

    (if (eq (selected-window) wind-A)
	(other-window 1))
    (switch-to-buffer buf-B)
    (setq wind-B (selected-window))

    (if three-way-comparison
	(progn
	  (funcall split-window-function)
	  (if (eq (selected-window) wind-B)
	      (other-window 1))
	  (switch-to-buffer buf-C)
	  (setq wind-C (selected-window))))

    (with-current-buffer control-buffer
      (setq ediff-window-A wind-A
	    ediff-window-B wind-B
	    ediff-window-C wind-C))

    ;; It is unlikely that we will want to implement 3way window comparison.
    ;; So, only buffers A and B are used here.
    (if ediff-windows-job
	(progn
	  (set-window-start wind-A wind-A-start)
	  (set-window-start wind-B wind-B-start)))

    (select-window (display-buffer-in-direction
                    control-buffer
                    '((direction . bottom))))
    (ediff-setup-control-buffer control-buffer)
    ))


;; dispatch an appropriate window setup function
(defun ediff-setup-windows-multiframe (buf-A buf-B buf-C control-buf)
  (with-current-buffer control-buf
    (setq ediff-multiframe t))
  (if ediff-merge-job
      (ediff-setup-windows-multiframe-merge buf-A buf-B buf-C control-buf)
    (ediff-setup-windows-multiframe-compare buf-A buf-B buf-C control-buf)))

(defun ediff-setup-windows-multiframe-merge (buf-A buf-B buf-C control-buf)
  ;; Algorithm:
  ;;   1. Never use frames that have dedicated windows in them---it is bad to
  ;;      destroy dedicated windows.
  ;;   2. If A and B are in the same frame but C's frame is different--- use one
  ;;      frame for A and B and use a separate frame for C.
  ;;   3. If C's frame is non-existent, then: if the first suitable
  ;;      non-dedicated frame  is different from A&B's, then use it for C.
  ;;      Otherwise, put A,B, and C in one frame.
  ;;   4. If buffers A, B, C are is separate frames, use them to display these
  ;;      buffers.

  ;;   Skip dedicated or iconified frames.
  ;;   Unsplittable frames are taken care of later.
  ;; (ediff-skip-unsuitable-frames 'ok-unsplittable)

  (let* ((window-min-height 1)
	 (wind-A (ediff-get-visible-buffer-window buf-A))
	 (wind-B (ediff-get-visible-buffer-window buf-B))
	 (wind-C (ediff-get-visible-buffer-window buf-C))
	 (buf-Ancestor (with-current-buffer control-buf
                         ediff-ancestor-buffer))
	 (wind-Ancestor (ediff-get-visible-buffer-window buf-Ancestor))
	 (frame-A (if wind-A (window-frame wind-A)))
	 (frame-B (if wind-B (window-frame wind-B)))
	 (frame-C (if wind-C (window-frame wind-C)))
	 (frame-Ancestor (if wind-Ancestor (window-frame wind-Ancestor)))
	 ;; on wide display, do things in one frame
	 (force-one-frame
	  (with-current-buffer control-buf ediff-wide-display-p))
	 ;; this lets us have local versions of ediff-split-window-function
	 (split-window-function
	  (with-current-buffer control-buf ediff-split-window-function))
	 (orig-wind (selected-window))
	 (orig-frame (selected-frame))
	 (use-same-frame (or force-one-frame
			     ;; A and C must be in one frame
			     (eq frame-A (or frame-C orig-frame))
			     ;; B and C must be in one frame
			     (eq frame-B (or frame-C orig-frame))
			     ;; A or B is not visible
			     (not (frame-live-p frame-A))
			     (not (frame-live-p frame-B))
			     ;; A or B is not suitable for display
			     (not (ediff-window-ok-for-display wind-A))
			     (not (ediff-window-ok-for-display wind-B))
			     ;; A and B in the same frame, and no good frame
			     ;; for C
			     (and (eq frame-A frame-B)
				  (not (frame-live-p frame-C)))
			     ))
	 ;; use-same-frame-for-AB implies wind A and B are ok for display
	 (use-same-frame-for-AB (and (not use-same-frame)
				     (eq frame-A frame-B)))
	 (merge-window-share (with-current-buffer control-buf
			       ediff-merge-window-share))
	 merge-window-lines
	 designated-minibuffer-frame ; ediff-merge-with-ancestor-job
     (with-Ancestor-p (with-current-buffer control-buf
                        ediff-merge-with-ancestor-job))
     (done-Ancestor (not with-Ancestor-p))
	 done-A done-B done-C)

    ;; buf-A on its own
    (if (and (window-live-p wind-A)
	     (null use-same-frame) ; implies wind-A is suitable
	     (null use-same-frame-for-AB))
	(progn ; buf A on its own
	  ;; buffer buf-A is seen in live wind-A
	  (select-window wind-A)
	  (delete-other-windows)
	  (setq wind-A (selected-window))
	  (setq done-A t)))

    ;; buf-B on its own
    (if (and (window-live-p wind-B)
	     (null use-same-frame) ; implies wind-B is suitable
	     (null use-same-frame-for-AB))
	(progn ; buf B on its own
	  ;; buffer buf-B is seen in live wind-B
	  (select-window wind-B)
	  (delete-other-windows)
	  (setq wind-B (selected-window))
	  (setq done-B t)))

    ;; buf-C on its own
    (if (and (window-live-p wind-C)
	     (ediff-window-ok-for-display wind-C)
	     (null use-same-frame)) ; buf C on its own
	(progn
	  ;; buffer buf-C is seen in live wind-C
	  (select-window wind-C)
	  (delete-other-windows)
	  (setq wind-C (selected-window))
	  (setq done-C t)))

    ;; buf-Ancestor on its own
    (if (and ediff-show-ancestor
             with-Ancestor-p
             (window-live-p wind-Ancestor)
             (ediff-window-ok-for-display wind-Ancestor)
             (null use-same-frame)) ; buf Ancestor on its own
        (progn
          ;; buffer buf-Ancestor is seen in live wind-Ancestor
          (select-window wind-Ancestor)
          (delete-other-windows)
          (setq wind-Ancestor (selected-window))
          (setq done-Ancestor t)))

    (if (and use-same-frame-for-AB  ; implies wind A and B are suitable
	     (window-live-p wind-A))
	(progn
	  ;; wind-A must already be displaying buf-A
	  (select-window wind-A)
	  (delete-other-windows)
	  (setq wind-A (selected-window))

	  (funcall split-window-function)
	  (if (eq (selected-window) wind-A)
	      (other-window 1))
	  (switch-to-buffer buf-B)
	  (setq wind-B (selected-window))

	  (setq done-A t
		done-B t)))

    (if use-same-frame
	(let ((window-min-height 1))
	  (if (and (eq frame-A frame-B)
		   (eq frame-B frame-C)
		   (eq frame-C frame-Ancestor)
		   (frame-live-p frame-A))
	      (select-frame frame-A)
	    ;; avoid dedicated and non-splittable windows
	    (ediff-skip-unsuitable-frames))
	  (delete-other-windows)
	  (setq merge-window-lines
		(max 2 (round (* (window-height) merge-window-share))))
	  (switch-to-buffer buf-A)
	  (setq wind-A (selected-window))

	  (split-window-vertically
	   (max 2 (- (window-height) merge-window-lines)))
	  (if (eq (selected-window) wind-A)
	      (other-window 1))
	  (setq wind-C (selected-window))
	  (switch-to-buffer buf-C)

      (when (and ediff-show-ancestor with-Ancestor-p)
        (select-window wind-C)
        (funcall split-window-function)
        (if (eq (selected-window) wind-C)
            (other-window 1))
        (switch-to-buffer buf-Ancestor)
        (setq wind-Ancestor (selected-window)))

	  (select-window wind-A)

	  (funcall split-window-function)
	  (if (eq (selected-window) wind-A)
	      (other-window 1))
	  (switch-to-buffer buf-B)
	  (setq wind-B (selected-window))

	  (setq done-A t
		done-B t
		done-C t
        done-Ancestor t)))

    (or done-A  ; Buf A to be set in its own frame,
	      ;;; or it was set before because use-same-frame = 1
	(progn
	  ;; Buf-A was not set up yet as it wasn't visible,
	  ;; and use-same-frame = nil, use-same-frame-for-AB = nil
	  (select-window orig-wind)
	  (delete-other-windows)
	  (switch-to-buffer buf-A)
	  (setq wind-A (selected-window))
	  ))
    (or done-B  ; Buf B to be set in its own frame,
	      ;;; or it was set before because use-same-frame = 1
	(progn
	  ;; Buf-B was not set up yet as it wasn't visible
	  ;; and use-same-frame = nil, use-same-frame-for-AB = nil
	  (select-window orig-wind)
	  (delete-other-windows)
	  (switch-to-buffer buf-B)
	  (setq wind-B (selected-window))
	  ))

    (or done-C  ; Buf C to be set in its own frame,
	      ;;; or it was set before because use-same-frame = 1
	(progn
	  ;; Buf-C was not set up yet as it wasn't visible
	  ;; and use-same-frame = nil
	  (select-window orig-wind)
	  (delete-other-windows)
	  (switch-to-buffer buf-C)
	  (setq wind-C (selected-window))
	  ))

    (or done-Ancestor  ; Buf Ancestor to be set in its own frame,
        (not ediff-show-ancestor)
	      ;;; or it was set before because use-same-frame = 1
        (progn
          ;; Buf-Ancestor was not set up yet as it wasn't visible
          ;; and use-same-frame = nil
          (select-window orig-wind)
          (delete-other-windows)
          (switch-to-buffer buf-Ancestor)
          (setq wind-Ancestor (selected-window))))

    (with-current-buffer control-buf
      (setq ediff-window-A wind-A
	    ediff-window-B wind-B
	    ediff-window-C wind-C
            ediff-window-Ancestor wind-Ancestor)
      (setq frame-A (window-frame ediff-window-A)
	    designated-minibuffer-frame
	    (window-frame (minibuffer-window frame-A))))

    (ediff-setup-control-frame control-buf designated-minibuffer-frame)
    ))

;; Window setup for all comparison jobs, including 3way comparisons
(defun ediff-setup-windows-multiframe-compare (buf-A buf-B buf-C control-buf)
  ;; Algorithm:
  ;;    If a buffer is seen in a frame, use that frame for that buffer.
  ;;    If it is not seen, use the current frame.
  ;;    If both buffers are not seen, they share the current frame.  If one
  ;;    of the buffers is not seen, it is placed in the current frame (where
  ;;    ediff started).  If that frame is displaying the other buffer, it is
  ;;    shared between the two buffers.
  ;;    However, if we decide to put both buffers in one frame
  ;;    and the selected frame isn't splittable, we create a new frame and
  ;;    put both buffers there, event if one of this buffers is visible in
  ;;    another frame.

  (let* ((window-min-height 1)
	 (wind-A (ediff-get-visible-buffer-window buf-A))
	 (wind-B (ediff-get-visible-buffer-window buf-B))
	 (wind-C (ediff-get-visible-buffer-window buf-C))
	 (frame-A (if wind-A (window-frame wind-A)))
	 (frame-B (if wind-B (window-frame wind-B)))
	 (frame-C (if wind-C (window-frame wind-C)))
	 (ctl-frame-exists-p (with-current-buffer control-buf
			       (frame-live-p ediff-control-frame)))
	 ;; on wide display, do things in one frame
	 (force-one-frame
	  (with-current-buffer control-buf ediff-wide-display-p))
	 ;; this lets us have local versions of ediff-split-window-function
	 (split-window-function
	  (with-current-buffer control-buf ediff-split-window-function))
	 (three-way-comparison
	  (with-current-buffer control-buf ediff-3way-comparison-job))
	 (use-same-frame (or force-one-frame
			     (eq frame-A frame-B)
			     (not (ediff-window-ok-for-display wind-A))
			     (not (ediff-window-ok-for-display wind-B))
			     (if three-way-comparison
				 (or (eq frame-A frame-C)
				     (eq frame-B frame-C)
				     (not (ediff-window-ok-for-display wind-C))
				     (not (frame-live-p frame-A))
				     (not (frame-live-p frame-B))
				     (not (frame-live-p frame-C))))
			     (and (not (frame-live-p frame-B))
				  (or ctl-frame-exists-p
				      (eq frame-A (selected-frame))))
			     (and (not (frame-live-p frame-A))
				  (or ctl-frame-exists-p
				      (eq frame-B (selected-frame))))))
         (window-combination-resize t)
	 wind-A-start wind-B-start
	 designated-minibuffer-frame)

    (with-current-buffer control-buf
      (setq wind-A-start (ediff-overlay-start
			  (ediff-get-value-according-to-buffer-type
			   'A ediff-narrow-bounds))
	    wind-B-start (ediff-overlay-start
			  (ediff-get-value-according-to-buffer-type
			   'B ediff-narrow-bounds))))

    (if use-same-frame
        (progn
	  (if (and (eq frame-A frame-B) (frame-live-p frame-A))
	      (select-frame frame-A)
	    ;; avoid dedicated and non-splittable windows
	    (ediff-skip-unsuitable-frames))
	  (delete-other-windows)
	  (switch-to-buffer buf-A)
	  (setq wind-A (selected-window))

          (funcall split-window-function)
	  (if (eq (selected-window) wind-A)
	      (other-window 1))
	  (switch-to-buffer buf-B)
	  (setq wind-B (selected-window))

	  (if three-way-comparison
	      (progn
		(funcall split-window-function) ; equally
		(if (memq (selected-window) (list wind-A wind-B))
		    (other-window 1))
		(switch-to-buffer buf-C)
		(setq wind-C (selected-window)))))

      (if (window-live-p wind-A)        ; buf-A on its own
	  (progn
	    ;; buffer buf-A is seen in live wind-A
	    (select-window wind-A)      ; must be displaying buf-A
	    (delete-other-windows)
	    (setq wind-A (selected-window))) ;FIXME: Why?
	;; Buf-A was not set up yet as it wasn't visible,
	;; and use-same-frame = nil
        ;; Skip dedicated or iconified frames.
        ;; Unsplittable frames are taken care of later.
        (ediff-skip-unsuitable-frames 'ok-unsplittable)
	(delete-other-windows)
	(switch-to-buffer buf-A)
	(setq wind-A (selected-window)))

      (if (window-live-p wind-B)        ; buf B on its own
	  (progn
	    ;; buffer buf-B is seen in live wind-B
	    (select-window wind-B)      ; must be displaying buf-B
	    (delete-other-windows)
	    (setq wind-B (selected-window))) ;FIXME: Why?
	;; Buf-B was not set up yet as it wasn't visible,
	;; and use-same-frame = nil
        ;; Skip dedicated or iconified frames.
        ;; Unsplittable frames are taken care of later.
        (ediff-skip-unsuitable-frames 'ok-unsplittable)
	(delete-other-windows)
	(switch-to-buffer buf-B)
	(setq wind-B (selected-window)))

      (if (window-live-p wind-C)        ; buf C on its own
	  (progn
	    ;; buffer buf-C is seen in live wind-C
	    (select-window wind-C)      ; must be displaying buf-C
	    (delete-other-windows)
	    (setq wind-C (selected-window))) ;FIXME: Why?
        (if three-way-comparison
	    (progn
	      ;; Buf-C was not set up yet as it wasn't visible,
	      ;; and use-same-frame = nil
              ;; Skip dedicated or iconified frames.
              ;; Unsplittable frames are taken care of later.
              (ediff-skip-unsuitable-frames 'ok-unsplittable)
	      (delete-other-windows)
	      (switch-to-buffer buf-C)
	      (setq wind-C (selected-window))
	      ))))

    (with-current-buffer control-buf
      (setq ediff-window-A wind-A
	    ediff-window-B wind-B
	    ediff-window-C wind-C)

      (setq frame-A (window-frame ediff-window-A)
	    designated-minibuffer-frame
	    (window-frame (minibuffer-window frame-A))))

    ;; It is unlikely that we'll implement a version of ediff-windows that
    ;; would compare 3 windows at once.  So, we don't use buffer C here.
    (if ediff-windows-job
	(progn
	  (set-window-start wind-A wind-A-start)
	  (set-window-start wind-B wind-B-start)))

    (ediff-setup-control-frame control-buf designated-minibuffer-frame)
    ))

(defun ediff-skip-unsuitable-frames (&optional ok-unsplittable)
  "Skip unsplittable frames and frames that have dedicated windows.
Create a new splittable frame if none is found."
  (if (display-graphic-p)
      (let ((wind-frame (window-frame))
            seen-windows)
	(while (and (not (memq (selected-window) seen-windows))
		    (or
		     (ediff-frame-has-dedicated-windows wind-frame)
		     (ediff-frame-iconified-p wind-frame)
		     ;; skip small windows
		     (< (frame-height wind-frame)
			(* 3 window-min-height))
		     (if ok-unsplittable
                         nil
                       (cdr (assq 'unsplittable (frame-parameters wind-frame))))))
	  ;; remember history
	  (setq seen-windows (cons (selected-window) seen-windows))
	  ;; try new window
	  (other-window 1 t)
	  (setq wind-frame (window-frame))
	  )
	(if (memq (selected-window) seen-windows)
	    ;; fed up, no appropriate frames
	    (setq wind-frame (make-frame '((unsplittable)))))

	(select-frame wind-frame)
	)))

(defun ediff-frame-has-dedicated-windows (frame)
  (let (ans)
    (walk-windows
     (lambda (wind) (if (window-dedicated-p wind)
			(setq ans t)))
     'ignore-minibuffer
     frame)
    ans))

;; window is ok, if it is only one window on the frame, not counting the
;; minibuffer, or none of the frame's windows is dedicated.
;; The idea is that it is bad to destroy dedicated windows while creating an
;; ediff window setup
(defun ediff-window-ok-for-display (wind)
  (and
   (window-live-p wind)
   (or
    ;; only one window
    (eq wind (next-window wind 'ignore-minibuffer (window-frame wind)))
    ;; none is dedicated (in multiframe setup)
    (not (ediff-frame-has-dedicated-windows (window-frame wind)))
    )))

(defvar x-fast-protocol-requests)
(declare-function x-change-window-property "xfns.c")

(defun ediff-frame-make-utility (frame)
  (let ((x-fast-protocol-requests t))
    (x-change-window-property
     "_NET_WM_WINDOW_TYPE" '("_NET_WM_WINDOW_TYPE_UTILITY")
     frame "ATOM" 32 t)
    (x-change-window-property
     "WM_TRANSIENT_FOR"
     (list (string-to-number (frame-parameter nil 'window-id)))
     frame "WINDOW" 32 t)))

;; Prepare or refresh control frame
(defun ediff-setup-control-frame (ctl-buffer designated-minibuffer-frame)
  (let ((window-min-height 1)
	ctl-frame-iconified-p dont-iconify-ctl-frame deiconify-ctl-frame
	ctl-frame old-ctl-frame lines
	;; user-grabbed-mouse
	fheight fwidth adjusted-parameters)

    (with-current-buffer ctl-buffer
      (run-hooks 'ediff-before-setup-control-frame-hook))

    (setq old-ctl-frame (with-current-buffer ctl-buffer ediff-control-frame))
    (with-current-buffer ctl-buffer
      (setq ctl-frame (if (frame-live-p old-ctl-frame)
			  old-ctl-frame
			(make-frame ediff-control-frame-parameters))
	    ediff-control-frame ctl-frame)
      ;; protect against undefined face-attribute
      (condition-case nil
	  (if (face-attribute 'mode-line :box)
	      (set-face-attribute 'mode-line ctl-frame :box nil))
	(error)))

    (setq ctl-frame-iconified-p (ediff-frame-iconified-p ctl-frame))
    (select-frame ctl-frame)
    (if (window-dedicated-p)
	()
      (delete-other-windows)
      (switch-to-buffer ctl-buffer))

    ;; must be before ediff-setup-control-buffer
    ;; just a precaution--we should be in ctl-buffer already
    (with-current-buffer ctl-buffer
      (make-local-variable 'frame-title-format)
      (make-local-variable 'icon-title-format))

    (ediff-setup-control-buffer ctl-buffer)
    (setq dont-iconify-ctl-frame
	  (not (string= ediff-help-message ediff-brief-help-message)))
    (setq deiconify-ctl-frame
	  (and (eq this-command 'ediff-toggle-help)
	       dont-iconify-ctl-frame))

    ;; 1 more line for the mode line
    (setq lines (1+ (count-lines (point-min) (point-max)))
	  fheight lines
          fwidth (max (+ (ediff-help-message-line-length) 2) 0)
	  adjusted-parameters
	  (list
	   ;; possibly change surrogate minibuffer
	   (cons 'minibuffer
		 (minibuffer-window
		  designated-minibuffer-frame))
	   (cons 'width fwidth)
	   (cons 'height fheight)
	   (cons 'user-position t)
	   ))

    ;; adjust autoraise
    (setq adjusted-parameters
	  (cons (if ediff-use-long-help-message
		    '(auto-raise . nil)
		  '(auto-raise . t))
		adjusted-parameters))

    ;; As a precaution, we call modify frame parameters twice, in
    ;; order to make sure that at least once we do it for
    ;; a non-iconified frame.  (It appears that in the Windows port of
    ;; Emacs, one can't modify frame parameters of iconified frames.)
    (if (eq system-type 'windows-nt)
	(modify-frame-parameters ctl-frame adjusted-parameters))

    (goto-char (point-min))

    (modify-frame-parameters ctl-frame adjusted-parameters)
    (when (and ediff-floating-control-frame (eq (window-system ctl-frame) 'x))
      (ediff-frame-make-utility ctl-frame))
    (make-frame-visible ctl-frame)

    ;; This works around a bug in 19.25 and earlier.  There, if frame gets
    ;; iconified, the current buffer changes to that of the frame that
    ;; becomes exposed as a result of this iconification.
    ;; So, we make sure the current buffer doesn't change.
    (select-frame ctl-frame)
    (ediff-refresh-control-frame)

    (cond ((and ediff-prefer-iconified-control-frame
		(not ctl-frame-iconified-p) (not dont-iconify-ctl-frame))
	   (iconify-frame ctl-frame))
	  ((or deiconify-ctl-frame (not ctl-frame-iconified-p))
	   (raise-frame ctl-frame)))

    (set-window-dedicated-p (selected-window) t)

    ;; Now move the frame.  We must do it separately due to an obscure bug in
    ;; XEmacs
    (modify-frame-parameters
     ctl-frame
     (funcall ediff-control-frame-position-function ctl-buffer fwidth fheight))

    ;; synchronize so the cursor will move to control frame
    ;; per RMS suggestion
    (if (display-graphic-p)
	(let ((count 7))
	  (sit-for .1)
	  (while (and (not (frame-visible-p ctl-frame)) (> count 0))
	    (setq count (1- count))
	    (sit-for .3))))

    (or (ediff-frame-iconified-p ctl-frame)
	;; don't warp the mouse, unless ediff-grab-mouse = t
	(ediff-reset-mouse ctl-frame
			   (or (eq this-command 'ediff-quit)
			       (not (eq ediff-grab-mouse t)))))

    (with-current-buffer ctl-buffer
      (run-hooks 'ediff-after-setup-control-frame-hook))))


(defun ediff-destroy-control-frame (ctl-buffer)
  (ediff-with-current-buffer ctl-buffer
    (if (and (display-graphic-p) (frame-live-p ediff-control-frame))
	(let ((ctl-frame ediff-control-frame))
	  (setq ediff-control-frame nil)
	  (delete-frame ctl-frame))))
  (if ediff-multiframe
      (ediff-skip-unsuitable-frames))
  ;;(ediff-reset-mouse nil)
  )


;; finds a good place to clip control frame
(defun ediff-make-frame-position (ctl-buffer ctl-frame-width ctl-frame-height)
  (with-current-buffer ctl-buffer
    (let* ((frame-A (window-frame ediff-window-A))
	   (frame-A-parameters (frame-parameters frame-A))
	   (frame-A-top (eval (cdr (assoc 'top frame-A-parameters)) t))
	   (frame-A-left (eval (cdr (assoc 'left frame-A-parameters)) t))
	   (frame-A-width (frame-width frame-A))
	   (ctl-frame ediff-control-frame)
	   horizontal-adjustment upward-adjustment
	   ctl-frame-top ctl-frame-left)

      ;; Multiple control frames are clipped based on the value of
      ;; ediff-control-buffer-number.  This is done in order not to obscure
      ;; other active control panels.
      (setq horizontal-adjustment (* 2 ediff-control-buffer-number)
	    upward-adjustment (* -14 ediff-control-buffer-number))

      (setq ctl-frame-top
	    (- frame-A-top upward-adjustment ediff-control-frame-upward-shift)
	    ctl-frame-left
	    (+ frame-A-left
	       (if ediff-use-long-help-message
		   (* (frame-char-width ctl-frame)
		      (+ ediff-wide-control-frame-rightward-shift
			 horizontal-adjustment))
		 (- (* frame-A-width (frame-char-width frame-A))
		    (* (frame-char-width ctl-frame)
		       (+ ctl-frame-width
			  ediff-narrow-control-frame-leftward-shift
			  horizontal-adjustment))))))
      (setq ctl-frame-top
	    (min ctl-frame-top
		 (- (display-pixel-height)
		    (* 2 ctl-frame-height
		       (frame-char-height ctl-frame))))
	    ctl-frame-left
	    (min ctl-frame-left
		 (- (display-pixel-width)
		    (* ctl-frame-width (frame-char-width ctl-frame)))))
      ;; keep ctl frame within the visible bounds
      (setq ctl-frame-top (max ctl-frame-top 1)
	    ctl-frame-left (max ctl-frame-left 1))

      (list (cons 'top ctl-frame-top)
	    (cons 'left ctl-frame-left))
      )))

(defun ediff-xemacs-select-frame-hook ()
  (declare (obsolete nil "28.1"))
  (if (and (equal (selected-frame) ediff-control-frame)
	   (not ediff-use-long-help-message))
      (raise-frame ediff-control-frame)))

(defun ediff-make-wide-display ()
  "Construct an alist of parameters for the wide display.
Saves the old frame parameters in `ediff-wide-display-orig-parameters'.
The frame to be resized is kept in `ediff-wide-display-frame'.
This function modifies only the left margin and the width of the display.
It assumes that it is called from within the control buffer."
  (if (not (fboundp 'display-pixel-width))
      (user-error "Can't determine display width"))
  (let* ((frame-A (window-frame ediff-window-A))
	 (frame-A-params (frame-parameters frame-A))
	 (cw (frame-char-width frame-A))
	 (wd (- (/ (display-pixel-width) cw) 5)))
    (setq ediff-wide-display-orig-parameters
	  (list (cons 'left (max 0 (eval (cdr (assoc 'left frame-A-params)) t)))
		(cons 'width (cdr (assoc 'width frame-A-params))))
	  ediff-wide-display-frame frame-A)
    (modify-frame-parameters
     frame-A `((left . ,cw) (width . ,wd) (user-position . t)))))


;; Revise the mode line to display which difference we have selected
;; Also resets mode lines of buffers A/B, since they may be clobbered by
;; other invocations of Ediff.
(defun ediff-refresh-mode-lines ()
  (let (buf-A-state-diff buf-B-state-diff buf-C-state-diff buf-C-state-merge)

    (if (ediff-valid-difference-p)
	(setq
	 buf-C-state-diff (ediff-get-state-of-diff ediff-current-difference 'C)
	 buf-C-state-merge (ediff-get-state-of-merge ediff-current-difference)
	 buf-A-state-diff (ediff-get-state-of-diff ediff-current-difference 'A)
	 buf-B-state-diff (ediff-get-state-of-diff ediff-current-difference 'B)
	 buf-A-state-diff (if buf-A-state-diff
			      (format "[%s] " buf-A-state-diff)
			    "")
	 buf-B-state-diff (if buf-B-state-diff
			      (format "[%s] " buf-B-state-diff)
			    "")
	 buf-C-state-diff (if (and (ediff-buffer-live-p ediff-buffer-C)
				   (or buf-C-state-diff buf-C-state-merge))
			      (format "[%s%s%s] "
				      (or buf-C-state-diff "")
				      (if buf-C-state-merge
					  (concat " " buf-C-state-merge)
					"")
				      (if (ediff-get-state-of-ancestor
					   ediff-current-difference)
					  " AncestorEmpty"
					"")
				      )
			    ""))
      (setq buf-A-state-diff ""
	    buf-B-state-diff ""
	    buf-C-state-diff ""))

    ;; control buffer format
    (setq mode-line-format
	  (if (ediff-narrow-control-frame-p)
	      (list "   " mode-line-buffer-identification)
	    (list "-- " mode-line-buffer-identification
                  (list 'ediff-use-long-help-message "        Quick Help"))))
    ;; control buffer id
    (setq mode-line-buffer-identification
	  (if (ediff-narrow-control-frame-p)
	      (ediff-make-narrow-control-buffer-id 'skip-name)
	    (ediff-make-wide-control-buffer-id)))
    ;; Force mode-line redisplay
    (force-mode-line-update)

    (if (and (display-graphic-p) (frame-live-p ediff-control-frame))
	(ediff-refresh-control-frame))

    (ediff-with-current-buffer ediff-buffer-A
      (setq ediff-diff-status buf-A-state-diff)
      (ediff-strip-mode-line-format)
      (setq mode-line-format
	    (list " A: " 'ediff-diff-status mode-line-format))
      (force-mode-line-update))
    (ediff-with-current-buffer ediff-buffer-B
      (setq ediff-diff-status buf-B-state-diff)
      (ediff-strip-mode-line-format)
      (setq mode-line-format
	    (list " B: " 'ediff-diff-status mode-line-format))
      (force-mode-line-update))
    (if ediff-3way-job
	(ediff-with-current-buffer ediff-buffer-C
	  (setq ediff-diff-status buf-C-state-diff)
	  (ediff-strip-mode-line-format)
	  (setq mode-line-format
		(list " C: " 'ediff-diff-status mode-line-format))
	  (force-mode-line-update)))
    (if (ediff-buffer-live-p ediff-ancestor-buffer)
	(ediff-with-current-buffer ediff-ancestor-buffer
	  (ediff-strip-mode-line-format)
	  ;; we keep the second dummy string in the mode line format of the
	  ;; ancestor, since for other buffers Ediff prepends 2 strings and
	  ;; ediff-strip-mode-line-format expects that.
	  (setq mode-line-format
		(list " Ancestor: "
		      (cond ((not (stringp buf-C-state-merge))
			     "")
			    ((string-match "prefer-A" buf-C-state-merge)
			     "[=diff(B)] ")
			    ((string-match "prefer-B" buf-C-state-merge)
			     "[=diff(A)] ")
			    (t ""))
		      mode-line-format))))
    ))


(defun ediff-refresh-control-frame ()
  ;; Set frame/icon titles.
  (modify-frame-parameters
   ediff-control-frame
   (list (cons 'title (ediff-make-base-title))
	 (cons 'icon-name (ediff-make-narrow-control-buffer-id)))))


(defun ediff-make-narrow-control-buffer-id (&optional skip-name)
  (concat
   (if skip-name
       " "
     (ediff-make-base-title))
   (cond ((< ediff-current-difference 0)
	  (format " _/%d" ediff-number-of-differences))
	 ((>= ediff-current-difference ediff-number-of-differences)
	  (format " $/%d" ediff-number-of-differences))
	 (t
	  (format " %d/%d"
		  (1+ ediff-current-difference)
		  ediff-number-of-differences)))))

(defun ediff-make-base-title ()
  (concat
   (cdr (assoc 'name ediff-control-frame-parameters))
   ediff-control-buffer-suffix))

(defun ediff-make-wide-control-buffer-id ()
  (list
   (concat "%b   "
           (propertize
            (cond ((< ediff-current-difference 0)
                   (format "At start of %d diffs"
                           ediff-number-of-differences))
                  ((>= ediff-current-difference ediff-number-of-differences)
                   (format "At end of %d diffs"
                           ediff-number-of-differences))
                  (t
                   (format "diff %d of %d"
                           (1+ ediff-current-difference)
                           ediff-number-of-differences)))
            'face 'mode-line-buffer-id))))

;; If buff is not live, return nil
(defun ediff-get-visible-buffer-window (buff)
  (if (ediff-buffer-live-p buff)
      (get-buffer-window buff 'visible)))


;;; Functions to decide when to redraw windows

(defun ediff-keep-window-config (control-buf)
  (and (eq control-buf (current-buffer))
       (/= (buffer-size) 0)
       (ediff-with-current-buffer control-buf
	 (let ((ctl-wind ediff-control-window)
	       (A-wind ediff-window-A)
	       (B-wind ediff-window-B)
	       (C-wind ediff-window-C)
               (ancestor-job ediff-merge-with-ancestor-job)
               (Ancestor-wind ediff-window-Ancestor))

	   (and
	    (ediff-window-visible-p A-wind)
	    (ediff-window-visible-p B-wind)
	    ;; if buffer C is defined then take it into account
	    (or (not ediff-3way-job)
		(ediff-window-visible-p C-wind))
            (or (not ancestor-job)
                (not ediff-show-ancestor)
                (ediff-window-visible-p Ancestor-wind))
	    (eq (window-buffer A-wind) ediff-buffer-A)
	    (eq (window-buffer B-wind) ediff-buffer-B)
	    (or (not ediff-3way-job)
		(eq (window-buffer C-wind) ediff-buffer-C))
            (or (not ancestor-job)
                (not ediff-show-ancestor)
                (eq (window-buffer Ancestor-wind) ediff-ancestor-buffer))
	    (string= ediff-window-config-saved
		     (format "%S%S%S%S%S%S%S%S"
			     ctl-wind A-wind B-wind C-wind Ancestor-wind
			     ediff-split-window-function
			     (ediff-multiframe-setup-p)
			     ediff-wide-display-p)))))))

(defun ediff-compute-toolbar-width ()
  (declare (obsolete nil "28.1"))
  0)

(provide 'ediff-wind)
;;; ediff-wind.el ends here
