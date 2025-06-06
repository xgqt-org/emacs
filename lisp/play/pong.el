;;; pong.el --- classical implementation of pong  -*- lexical-binding:t -*-

;; Copyright (C) 1999-2025 Free Software Foundation, Inc.

;; Author: Benjamin Drieu <bdrieu@april.org>
;; Keywords: games

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

;; This is an implementation of the classical game pong.

;;; Code:

(eval-when-compile (require 'cl-lib))

(require 'gamegrid)

;;; Customization

(defgroup pong nil
  "Emacs Lisp implementation of the classical game pong."
  :tag "Pong"
  :group 'games)

(defcustom pong-buffer-name "*Pong*"
  "Name of the buffer used to play."
  :type '(string))

(defcustom pong-width 50
  "Width of the playfield."
  :type '(integer))

(defcustom pong-height (min 30 (- (frame-height) 6))
  "Height of the playfield."
  :type '(integer))

(defcustom pong-bat-width 3
  "Width of the bats for pong."
  :type '(integer))

(defcustom pong-blank-color "black"
  "Color used for background."
  :type 'color)

(defcustom pong-bat-color "yellow"
  "Color used for bats."
  :type 'color)

(defcustom pong-ball-color "red"
  "Color used for the ball."
  :type 'color)

(defcustom pong-border-color "white"
  "Color used for pong borders."
  :type 'color)

(defcustom pong-left-key "4"
  "Alternate key to press for bat 1 to go up (primary one is [left])."
  :type '(restricted-sexp :match-alternatives (stringp vectorp)))

(defcustom pong-right-key "6"
  "Alternate key to press for bat 1 to go down (primary one is [right])."
  :type '(restricted-sexp :match-alternatives (stringp vectorp)))

(defcustom pong-up-key "8"
  "Alternate key to press for bat 2 to go up (primary one is [up])."
  :type '(restricted-sexp :match-alternatives (stringp vectorp)))

(defcustom pong-down-key "2"
  "Alternate key to press for bat 2 to go down (primary one is [down])."
  :type '(restricted-sexp :match-alternatives (stringp vectorp)))

(defcustom pong-quit-key "q"
  "Key to press to quit pong."
  :type '(restricted-sexp :match-alternatives (stringp vectorp)))

(defcustom pong-pause-key "p"
  "Key to press to pause pong."
  :type '(restricted-sexp :match-alternatives (stringp vectorp)))

(defcustom pong-resume-key "p"
  "Key to press to resume pong."
  :type '(restricted-sexp :match-alternatives (stringp vectorp)))

(defcustom pong-timer-delay 0.1
  "Time to wait between every cycle."
  :type 'number)


;;; This is black magic.  Define colors used

(defvar pong-blank-options
  '(((glyph colorize)
     (t ?\040))
    ((color-x color-x)
     (mono-x grid-x)
     (color-tty color-tty))
    (((glyph color-x) [0 0 0])
     (color-tty pong-blank-color))))

(defvar pong-bat-options
  '(((glyph colorize)
     (emacs-tty ?O)
     (t ?\040))
    ((color-x color-x)
     (mono-x mono-x)
     (color-tty color-tty)
     (mono-tty mono-tty))
    (((glyph color-x) [1 1 0])
     (color-tty pong-bat-color))))

(defvar pong-ball-options
  '(((glyph colorize)
     (t ?\*))
    ((color-x color-x)
     (mono-x grid-x)
     (color-tty color-tty))
    (((glyph color-x) [1 0 0])
     (color-tty pong-ball-color))))

(defvar pong-border-options
  '(((glyph colorize)
     (t ?\+))
    ((color-x color-x)
     (mono-x grid-x)
     (color-tty color-tty))
    (((glyph color-x) [0.5 0.5 0.5])
     (color-tty pong-border-color))))

(defconst pong-blank	0)
(defconst pong-bat	1)
(defconst pong-ball	2)
(defconst pong-border	3)


;;; Determine initial positions for bats and ball

(defvar pong-xx nil
  "Horizontal speed of the ball.")

(defvar pong-yy nil
  "Vertical speed of the ball.")

(defvar pong-x nil
  "Horizontal position of the ball.")

(defvar pong-y nil
  "Vertical position of the ball.")

(defvar pong-bat-player1 nil
  "Vertical position of bat 1.")

(defvar pong-bat-player2 nil
  "Vertical position of bat 2.")

(defvar pong-score-player1 nil)
(defvar pong-score-player2 nil)

;;; Initialize maps

(defvar-keymap pong-mode-map
  :doc "Modemap for pong-mode."
  :name 'pong-mode-map
  "<left>"       #'pong-move-left
  "<right>"      #'pong-move-right
  "<up>"         #'pong-move-up
  "<down>"       #'pong-move-down
  pong-left-key  #'pong-move-left
  pong-right-key #'pong-move-right
  pong-up-key    #'pong-move-up
  pong-down-key  #'pong-move-down
  pong-quit-key  #'pong-quit
  pong-pause-key #'pong-pause)

(defvar-keymap pong-null-map
  :doc "Null map for pong-mode."
  :name 'pong-null-map)



;;; Fun stuff -- The code

(defun pong-display-options ()
  "Computes display options (required by gamegrid for colors)."
  (let ((options (make-vector 256 nil)))
    (dotimes (c 256)
      (aset options c
            (cond ((= c pong-blank)
                   pong-blank-options)
                  ((= c pong-bat)
                   pong-bat-options)
                  ((= c pong-ball)
                   pong-ball-options)
                  ((= c pong-border)
                   pong-border-options)
                  (t
                   '(nil nil nil)))))
    options))



(defun pong-init-buffer ()
  "Initialize pong buffer and draw stuff thanks to gamegrid library."
  (get-buffer-create pong-buffer-name)
  (switch-to-buffer pong-buffer-name)
  (use-local-map pong-mode-map)

  (setq gamegrid-use-glyphs t)
  (setq gamegrid-use-color t)
  (gamegrid-init (pong-display-options))

  (gamegrid-init-buffer pong-width
			(+ 2 pong-height)
			?\s)

  (let ((buffer-read-only nil))
    (dotimes (y pong-height)
      (dotimes (x pong-width)
        (gamegrid-set-cell x y pong-border)))
    (cl-loop for y from 1 to (- pong-height 2) do
             (cl-loop for x from 1 to (- pong-width 2) do
                      (gamegrid-set-cell x y pong-blank))))

  (cl-loop for y from pong-bat-player1
           to (1- (+ pong-bat-player1 pong-bat-width))
           do (gamegrid-set-cell 2 y pong-bat))
  (cl-loop for y from pong-bat-player2
           to (1- (+ pong-bat-player2 pong-bat-width))
           do (gamegrid-set-cell (- pong-width 3) y pong-bat)))


(defun pong-move-left ()
  "Move bat 1 up.
This is called left for historical reasons, since in some pong
implementations you move with left/right paddle."
  (interactive nil pong-mode)
  (if (> pong-bat-player1 1)
      (and
       (setq pong-bat-player1 (1- pong-bat-player1))
       (pong-update-bat 2 pong-bat-player1))))



(defun pong-move-right ()
  "Move bat 1 down."
  (interactive nil pong-mode)
  (if (< (+ pong-bat-player1 pong-bat-width) (1- pong-height))
      (and
       (setq pong-bat-player1 (1+ pong-bat-player1))
       (pong-update-bat 2 pong-bat-player1))))



(defun pong-move-up ()
  "Move bat 2 up."
  (interactive nil pong-mode)
  (if (> pong-bat-player2 1)
      (and
       (setq pong-bat-player2 (1- pong-bat-player2))
       (pong-update-bat (- pong-width 3) pong-bat-player2))))



(defun pong-move-down ()
  "Move bat 2 down."
  (interactive nil pong-mode)
  (if (< (+ pong-bat-player2 pong-bat-width) (1- pong-height))
      (and
       (setq pong-bat-player2 (1+ pong-bat-player2))
       (pong-update-bat (- pong-width 3) pong-bat-player2))))



(defun pong-update-bat (x y)
  "Move a bat (suppress a cell and draw another one on the other side)."

  (cond
   ((string-equal (buffer-name (current-buffer)) pong-buffer-name)
    (gamegrid-set-cell x y pong-bat)
    (gamegrid-set-cell x (1- (+ y pong-bat-width)) pong-bat)
    (if (> y 1)
	(gamegrid-set-cell x (1- y) pong-blank))
    (if (< (+ y pong-bat-width) (1- pong-height))
	(gamegrid-set-cell x (+ y pong-bat-width) pong-blank)))))



(defun pong-init ()
  "Initialize a game."

  (define-key pong-mode-map pong-pause-key 'pong-pause)

  (add-hook 'kill-buffer-hook 'pong-quit nil t)

  ;; Initialization of some variables
  (setq pong-bat-player1 (1+ (/ (- pong-height pong-bat-width) 2)))
  (setq pong-bat-player2 pong-bat-player1)
  (setq pong-xx -1)
  (setq pong-yy 0)
  (setq pong-x (/ pong-width 2))
  (setq pong-y (/ pong-height 2))

  (pong-init-buffer)
  (gamegrid-kill-timer)
  (gamegrid-start-timer pong-timer-delay 'pong-update-game)
  (pong-update-score))



(defun pong-update-game (pong-buffer)
  "\"Main\" function for pong.
It is called every pong-cycle-delay seconds and
updates ball and bats positions.  It is responsible of collision
detection and checks if a player scores."
  (if (not (eq (current-buffer) pong-buffer))
      (pong-pause)

    (let ((old-x pong-x)
	  (old-y pong-y))
      ;; Erase the last ball position.
      (when (and (> old-y 0)
                 (< old-y (- pong-height 1)))
        ;; If the ball hit the bat in the column where bats are positioned,
        ;; and therefore changed its x direction, draw again the bat cell.
        (if (or (and (= old-x 2) (< 0 pong-xx))
                (and (= old-x (- pong-width 3)) (> 0 pong-xx)))
            (gamegrid-set-cell old-x old-y pong-bat)
          (gamegrid-set-cell old-x old-y pong-blank)))

      ;; Update the ball position.
      (setq pong-x (+ pong-x pong-xx))
      ;; If the ball would go out of bounds, put it against the border.
      (cond
       ((<= (+ pong-y pong-yy) 0)
        (setq pong-yy (- pong-yy))
        (setq pong-y 1))
       ((>= (+ pong-y pong-yy) (- pong-height 1))
        (setq pong-yy (- pong-yy))
        (setq pong-y (- pong-height 2)))
       (t
        (setq pong-y (+ pong-y pong-yy))
        ;; Check if the ball is against the border now,
        ;; and change the y direction if it is.
        (when (or (<= pong-y 1) (>= pong-y (- pong-height 2)))
          (setq pong-yy (- pong-yy)))))

      ;; Draw the ball in its new position.
      (if (and (> pong-y 0)
	       (< pong-y (- pong-height 1)))
	  (gamegrid-set-cell pong-x pong-y pong-ball))

      ;; Hit bat, score a goal, or nothing.
      (cond
       ((and (or (= pong-x 3) (= pong-x 2))
             (> 0 pong-xx) ; Collide with the bat if headed towards it.
             (>= pong-y pong-bat-player1)
             (< pong-y (+ pong-bat-player1 pong-bat-width)))
        (setq pong-yy (+ pong-yy
			 (cond
			  ((= pong-y pong-bat-player1) -1)
			  ((= pong-y (1+ pong-bat-player1)) 0)
			  (t 1))))
        (setq pong-xx (- pong-xx)))

       ((and (or (= pong-x (- pong-width 4)) (= pong-x (- pong-width 3)))
             (< 0 pong-xx) ; Collide with the bat if headed towards it.
             (>= pong-y pong-bat-player2)
             (< pong-y (+ pong-bat-player2 pong-bat-width)))
	(setq pong-yy (+ pong-yy
			 (cond
			  ((= pong-y pong-bat-player2) -1)
			  ((= pong-y (1+ pong-bat-player2)) 0)
			  (t 1))))
	(setq pong-xx (- pong-xx)))

       ((< pong-x 1)
	(setq pong-score-player2 (1+ pong-score-player2))
	(pong-init))

       ((>= pong-x (- pong-width 1))
	(setq pong-score-player1 (1+ pong-score-player1))
	(pong-init))))))



(defun pong-update-score ()
  "Update score and print it on bottom of the game grid."
  (let* ((string (format "Score:  %d / %d"
                         pong-score-player1 pong-score-player2))
	 (len (length string)))
    (dotimes (x len)
      (if (string-equal (buffer-name (current-buffer)) pong-buffer-name)
          (gamegrid-set-cell x pong-height (aref string x))))))



(defun pong-pause ()
  "Pause the game."
  (interactive nil pong-mode)
  (gamegrid-kill-timer)
  ;; Oooohhh ugly.  I don't know why, gamegrid-kill-timer don't do the
  ;; jobs it is made for.  So I have to do it "by hand".  Anyway, next
  ;; line is harmless.
  (cancel-function-timers 'pong-update-game)
  (define-key pong-mode-map pong-resume-key 'pong-resume))



(defun pong-resume ()
  "Resume a paused game."
  (interactive nil pong-mode)
  (define-key pong-mode-map pong-pause-key 'pong-pause)
  (gamegrid-start-timer pong-timer-delay 'pong-update-game))



(defun pong-quit ()
  "Quit the game and kill the pong buffer."
  (interactive nil pong-mode)
  (gamegrid-kill-timer)
  ;; Be sure not to draw things in another buffer and wait for some
  ;; time.
  (run-with-timer pong-timer-delay nil 'kill-buffer pong-buffer-name))



;;;###autoload
(defun pong ()
  "Play pong and waste time.
This is an implementation of the classical game pong.
Move left and right bats and try to bounce the ball to your opponent.

pong-mode keybindings:\\<pong-mode-map>

\\{pong-mode-map}"
  (interactive)
  (setq pong-score-player1 0)
  (setq pong-score-player2 0)
  (pong-init))



(provide 'pong)

;;; pong.el ends here
