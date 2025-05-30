;;; message.el --- composing mail and news messages -*- lexical-binding: t -*-

;; Copyright (C) 1996-2025 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: mail, news

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

;; This mode provides mail-sending facilities from within Emacs.  It
;; consists mainly of large chunks of code from the sendmail.el,
;; gnus-msg.el and rnewspost.el files.

;;; Code:

(require 'cl-lib)
(require 'mailheader)
(require 'gmm-utils)
(require 'mail-utils)
;; Only for the trivial macros mail-header-from, mail-header-date
;; mail-header-references, mail-header-subject, mail-header-id
(eval-when-compile (require 'nnheader))
;; This is apparently necessary even though things are autoloaded.
;; Because we dynamically bind mail-abbrev-mode-regexp, we'd better
;; require mailabbrev here.
(require 'mailabbrev)
(require 'mail-parse)
(require 'mml)
(require 'rfc822)
(require 'dired)
(require 'mm-util)
(require 'rfc2047)
(require 'puny)
(require 'rmc)                          ; read-multiple-choice
(require 'subr-x)
(require 'yank-media)
(require 'mailcap)
(require 'sendmail)

(autoload 'mailclient-send-it "mailclient")

(defvar gnus-message-group-art)
(defvar gnus-list-identifiers) ; gnus-sum is required where necessary
(defvar rmail-enable-mime-composing)

(defgroup message '((user-mail-address custom-variable)
		    (user-full-name custom-variable))
  "Mail and news message composing."
  :link '(custom-manual "(message)Top")
  :group 'mail
  :group 'news)

(defgroup message-various nil
  "Various Message Variables."
  :link '(custom-manual "(message)Various Message Variables")
  :group 'message)

(defgroup message-buffers nil
  "Message Buffers."
  :link '(custom-manual "(message)Message Buffers")
  :group 'message)

(defgroup message-sending nil
  "Message Sending."
  :link '(custom-manual "(message)Sending Variables")
  :group 'message)

(defgroup message-interface nil
  "Message Interface."
  :link '(custom-manual "(message)Interface")
  :group 'message)

(defgroup message-forwarding nil
  "Message Forwarding."
  :link '(custom-manual "(message)Forwarding")
  :group 'message-interface)

(defgroup message-insertion nil
  "Message Insertion."
  :link '(custom-manual "(message)Insertion")
  :group 'message)

(defgroup message-headers nil
  "Message Headers."
  :link '(custom-manual "(message)Message Headers")
  :group 'message)

(defgroup message-news nil
  "Composing News Messages."
  :group 'message)

(defgroup message-mail nil
  "Composing Mail Messages."
  :group 'message)

(defgroup message-faces nil
  "Faces used for message composing."
  :group 'message
  :group 'faces)

(defcustom message-header-use-obsolete-in-reply-to nil
  "Include extra information in the In-Reply-To header.
This form has been obsolete since RFC 2822."
  :group 'message-headers
  :version "31.1"
  :type 'boolean)

(defcustom message-directory "~/Mail/"
  "Directory from which all other mail file variables are derived."
  :group 'message-various
  :type 'directory)

(defcustom message-max-buffers 10
  "How many buffers to keep before starting to kill them off."
  :group 'message-buffers
  :type 'integer)

(defcustom message-send-rename-function #'message-default-send-rename-function
  "Function called to rename the buffer after sending it."
  :group 'message-buffers
  :version "28.1"
  :type 'function)

(defcustom message-fcc-handler-function #'message-output
  "A function called to save outgoing articles.
This function will be called with the name of the file to store the
article in.  The default function is `message-output' which saves in Unix
mailbox format."
  :type '(radio (function-item message-output)
		(function :tag "Other"))
  :group 'message-sending)

(defcustom message-fcc-externalize-attachments nil
  "If non-nil, attachments are included as external parts in Fcc copies."
  :version "22.1"
  :type 'boolean
  :group 'message-sending)

(defcustom message-courtesy-message
  "The following message is a courtesy copy of an article\nthat has been posted to %s as well.\n\n"
  "This is inserted at the start of a mailed copy of a posted message.
If the string contains the format spec \"%s\", the Newsgroups
the article has been posted to will be inserted there.
If this variable is nil, no such courtesy message will be added."
  :group 'message-sending
  :type '(radio string (const nil)))

(defcustom message-ignored-bounced-headers
  "^\\(Received\\|Return-Path\\|Delivered-To\\|DKIM-Signature\\|X-Hashcash\\):"
  "Regexp that matches headers to be removed in resent bounced mail."
  :group 'message-interface
  :type 'regexp)

(defcustom message-from-style 'angles
  "Specifies how \"From\" headers look.

If nil, they contain just the return address like:
	king@grassland.com
If `parens', they look like:
	king@grassland.com (Elvis Parsley)
If `angles', they look like:
	Elvis Parsley <king@grassland.com>

Otherwise, most addresses look like `angles', but they look like
`parens' if `angles' would need quoting and `parens' would not."
  :version "27.1"
  :type '(choice (const :tag "simple" nil)
		 (const parens)
		 (const angles)
		 (const default))
  :group 'message-headers)
(make-obsolete-variable
 'message-from-style
 "Only the `angles' value is valid according to RFC2822" "27.1")


(defcustom message-insert-canlock t
  "Whether to insert a Cancel-Lock header in news postings."
  :version "22.1"
  :group 'message-headers
  :type 'boolean)

(defcustom message-syntax-checks
  (if message-insert-canlock '((sender . disabled)) nil)
  "Controls what syntax checks should not be performed on outgoing posts.
To disable checking of long signatures, for instance, add
 `(signature . disabled)' to this list.

Don't touch this variable unless you really know what you're doing.

See the Message manual for the meanings of the valid syntax check
types."
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(alist
	  :key-type symbol
	  :value-type (const disabled)
	  :options (approved bogus-recipient continuation-headers
		    control-chars empty existing-newsgroups from illegible-text
		    invisible-text long-header-lines long-lines message-id
		    multiple-headers new-text newgroups quoting-style
		    repeated-newsgroups reply-to sender sendsys shoot
		    shorten-followup-to signature size subject subject-cmsg
		    valid-newsgroups)))

(defcustom message-required-headers '((optional . References)
				      From)
  "Headers to be generated or prompted for when sending a message.
Also see `message-required-news-headers' and
`message-required-mail-headers'."
  :version "22.1"
  :group 'message-news
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(repeat sexp))

(defcustom message-draft-headers '(References From)
  "Headers to be generated when saving a draft message."
  :version "28.1"
  :group 'message-news
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(repeat sexp))

(defcustom message-required-news-headers
  '(From Newsgroups Subject Date Message-ID
	 (optional . Organization)
	 (optional . User-Agent))
  "Headers to be generated or prompted for when posting an article.
RFC977 and RFC1036 require From, Date, Newsgroups, Subject,
Message-ID.  Organization, Lines, In-Reply-To, Expires, and
User-Agent are optional.  If you don't want message to insert some
header, remove it from this list."
  :group 'message-news
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(repeat sexp))

(defcustom message-required-mail-headers
  '(From Subject Date (optional . In-Reply-To) Message-ID
	 (optional . User-Agent))
  "Headers to be generated or prompted for when mailing a message.
It is recommended that From, Date, To, Subject and Message-ID be
included.  Organization and User-Agent are optional."
  :group 'message-mail
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(repeat sexp))

(defcustom message-prune-recipient-rules nil
  "Rules for how to prune the list of recipients when doing wide replies.
This is a list of regexps and regexp matches."
  :version "24.1"
  :group 'message-mail
  :group 'message-headers
  :link '(custom-manual "(message)Wide Reply")
  :type '(repeat regexp))

(defcustom message-deletable-headers '(Message-ID Date Lines)
  "Headers to delete if present and previously generated by message."
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(repeat (symbol :tag "Header")))

(defcustom message-ignored-news-headers
  "^NNTP-Posting-Host:\\|^Xref:\\|^[BGF]cc:\\|^Resent-Fcc:\\|^X-Draft-From:\\|^X-Gnus-Agent-Meta-Information:\\|^X-Message-SMTP-Method:\\|^X-Gnus-Delayed:"
  "Regexp of headers to be removed unconditionally before posting."
  :group 'message-news
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(repeat :value-to-internal (lambda (widget value)
				      (custom-split-regexp-maybe value))
		 :match (lambda (widget value)
			  (or (stringp value)
			      (widget-editable-list-match widget value)))
		 regexp))

(defcustom message-ignored-mail-headers
  "^\\([GF]cc\\|Resent-Fcc\\|Xref\\|X-Draft-From\\|X-Gnus-Agent-Meta-Information\\):"
  "Regexp of headers to be removed unconditionally before mailing."
  :group 'message-mail
  :group 'message-headers
  :link '(custom-manual "(message)Mail Headers")
  :type 'regexp)

(defcustom message-ignored-supersedes-headers "^Path:\\|^Date\\|^NNTP-Posting-Host:\\|^Xref:\\|^Lines:\\|^Received:\\|^X-From-Line:\\|^X-Trace:\\|^X-ID:\\|^X-Complaints-To:\\|Return-Path:\\|^Supersedes:\\|^NNTP-Posting-Date:\\|^X-Trace:\\|^X-Complaints-To:\\|^Cancel-Lock:\\|^Cancel-Key:\\|^X-Hashcash:\\|^X-Payment:\\|^Approved:\\|^Injection-Date:\\|^Injection-Info:"
  "Header lines matching this regexp will be deleted before posting.
It's best to delete old Path and Date headers before posting to avoid
any confusion."
  :group 'message-interface
  :link '(custom-manual "(message)Superseding")
  :type '(repeat :value-to-internal (lambda (widget value)
				      (custom-split-regexp-maybe value))
		 :match (lambda (widget value)
			  (or (stringp value)
			      (widget-editable-list-match widget value)))
		 regexp))

(defcustom message-subject-re-regexp
  (mail--wrap-re-regexp
   (concat
    "\\("
    (string-join mail-re-regexps "\\|")
    "\\)"))
  "Regexp matching \"Re: \" in the subject line.
Matching is done case-insensitively.
Initialized from the value of `mail-re-regexps', which is easier to
customize."
  :group 'message-various
  :link '(custom-manual "(message)Message Headers")
  :type 'regexp
  :set-after '(mail-re-regexps)
  :version "31.1")

(defcustom message-screenshot-command '("import" "png:-")
  "Command to take a screenshot.
The command should insert a PNG in the current buffer."
  :group 'message-various
  :type '(repeat string)
  :version "28.1")

;;; Start of variables adopted from `message-utils.el'.

(defcustom message-subject-trailing-was-query t
  "What to do with trailing \"(was: <old subject>)\" in subject lines.
If nil, leave the subject unchanged.  If it is the symbol `ask', query
the user what to do.  In this case, the subject is matched against
`message-subject-trailing-was-ask-regexp'.  If
`message-subject-trailing-was-query' is t, always strip the trailing
old subject.  In this case, `message-subject-trailing-was-regexp' is
used."
  :version "24.1"
  :type '(choice (const :tag "never" nil)
		 (const :tag "always strip" t)
		 (const ask))
  :link '(custom-manual "(message)Message Headers")
  :group 'message-various)

(defcustom message-subject-trailing-was-ask-regexp
  "[ \t]*\\([[(]+[Ww][Aa][Ss].*[])]+\\)"
  "Regexp matching \"(was: <old subject>)\" in the subject line.

The function `message-strip-subject-trailing-was' uses this regexp if
`message-subject-trailing-was-query' is set to the symbol `ask'.  If
the variable is t instead of `ask', use
`message-subject-trailing-was-regexp' instead.

It is okay to create some false positives here, as the user is asked."
  :version "22.1"
  :group 'message-various
  :link '(custom-manual "(message)Message Headers")
  :type 'regexp)

(defcustom message-subject-trailing-was-regexp
  "[ \t]*\\((*[Ww][Aa][Ss]:.*)\\)"
  "Regexp matching \"(was: <old subject>)\" in the subject line.

If `message-subject-trailing-was-query' is set to t, the subject is
matched against `message-subject-trailing-was-regexp' in
`message-strip-subject-trailing-was'.  You should use a regexp creating very
few false positives here."
  :version "22.1"
  :group 'message-various
  :link '(custom-manual "(message)Message Headers")
  :type 'regexp)

;;; marking inserted text

(defcustom message-mark-insert-begin
  "--8<---------------cut here---------------start------------->8---\n"
  "How to mark the beginning of some inserted text."
  :version "22.1"
  :type 'string
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-various)

(defcustom message-mark-insert-end
  "--8<---------------cut here---------------end--------------->8---\n"
  "How to mark the end of some inserted text."
  :version "22.1"
  :type 'string
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-various)

(defcustom message-archive-header "X-No-Archive: Yes\n"
  "Header to insert when you don't want your article to be archived.
Archives \(such as groups.google.com) respect this header."
  :version "22.1"
  :type 'string
  :link '(custom-manual "(message)Header Commands")
  :group 'message-various)

(defcustom message-archive-note
  "X-No-Archive: Yes - save https://groups.google.com/"
  "Note to insert why you wouldn't want this posting archived.
If nil, don't insert any text in the body."
  :version "22.1"
  :type '(radio string (const nil))
  :link '(custom-manual "(message)Header Commands")
  :group 'message-various)

;;; Crossposts and Followups
;; inspired by JoH-followup-to by Jochem Huhman <joh  at gmx.de>
;; new suggestions by R. Weikusat <rw at another.de>

(defvar-local message-cross-post-old-target nil
  "Old target for cross-posts or follow-ups.")

(defcustom message-cross-post-default t
  "When non-nil `message-cross-post-followup-to' will perform a crosspost.
If nil, `message-cross-post-followup-to' will only do a followup.  Note that
you can explicitly override this setting by calling
`message-cross-post-followup-to' with a prefix."
  :version "22.1"
  :type 'boolean
  :group 'message-various)

(defcustom message-cross-post-note "Crosspost & Followup-To: "
  "Note to insert before signature to notify of cross-post and follow-up."
  :version "22.1"
  :type 'string
  :group 'message-various)

(defcustom message-followup-to-note "Followup-To: "
  "Note to insert before signature to notify of follow-up only."
  :version "22.1"
  :type 'string
  :group 'message-various)

(defcustom message-cross-post-note-function #'message-cross-post-insert-note
  "Function to use to insert note about Crosspost or Followup-To.
The function will be called with four arguments.  The function should not only
insert a note, but also ensure old notes are deleted.  See the documentation
for `message-cross-post-insert-note'."
  :version "22.1"
  :type 'function
  :group 'message-various)

;;; End of variables adopted from `message-utils.el'.

(defcustom message-signature-separator "^-- $"
  "Regexp matching the signature separator.
This variable is used to strip off the signature from quoted text
when `message-cite-function' is
`message-cite-original-without-signature'.  Most useful values
are \"^-- $\" (strict) and \"^-- *$\" (loose; allow missing
whitespace)."
  :type '(choice (const :tag "strict" "^-- $")
		 (const :tag "loose" "^-- *$")
		 regexp)
  :version "22.3" ;; Gnus 5.10.12 (changed default)
  :link '(custom-manual "(message)Various Message Variables")
  :group 'message-various)

(defcustom message-elide-ellipsis "\n[...]\n\n"
  "The string which is inserted for elided text.
This is a `format-spec' string, and you can use %l to say how
many lines were removed, and %c to say how many characters were
removed."
  :type 'string
  :link '(custom-manual "(message)Various Commands")
  :group 'message-various)

(defcustom message-interactive mail-interactive
  "Non-nil means when sending a message wait for and display errors.
A value of nil means let mailer mail back a message to report errors."
  :version "23.2"
  :group 'message-sending
  :group 'message-mail
  :link '(custom-manual "(message)Sending Variables")
  :type 'boolean)

(defcustom message-confirm-send nil
  "When non-nil, ask for confirmation when sending a message."
  :group 'message-sending
  :group 'message-mail
  :version "23.1" ;; No Gnus
  :link '(custom-manual "(message)Sending Variables")
  :type 'boolean)

(defcustom message-generate-new-buffers 'unsent
  "Say whether to create a new message buffer to compose a message.
Valid values include:

nil
  Generate the buffer name in the Message way (e.g., *mail*, *news*,
  *mail to whom*, *news on group*, etc.) and continue editing in the
  existing buffer of that name.  If there is no such buffer, it will
  be newly created.

`unique' or t
  Create the new buffer with the name generated in the Message way.

`unsent'
  Similar to `unique' but the buffer name begins with \"*unsent \".

`standard'
  Similar to nil but the buffer name is simpler like *mail message*.

function
  If this is a function, call that function with three parameters:
  The type, the To address and the group name (any of these may be nil).
  The function should return the new buffer name."
  :version "24.1"
  :group 'message-buffers
  :link '(custom-manual "(message)Message Buffers")
  :type '(choice (const nil)
		 (sexp :tag "unique" :format "unique\n" :value unique
		       :match (lambda (widget value) (memq value '(unique t))))
		 (const unsent)
		 (const standard)
		 (function :format "\n    %{%t%}: %v")))

(defcustom message-kill-buffer-on-exit nil
  "Non-nil means that the message buffer will be killed after sending a message."
  :group 'message-buffers
  :link '(custom-manual "(message)Message Buffers")
  :type 'boolean)

(defcustom message-kill-buffer-query t
  "Non-nil means that killing a modified message buffer has to be confirmed.
This is used by `message-kill-buffer'."
  :version "23.1" ;; No Gnus
  :group 'message-buffers
  :type 'boolean)

(defcustom message-user-organization
  (or (getenv "ORGANIZATION") t)
  "String to be used as an Organization header.
If t, use `message-user-organization-file'."
  :group 'message-headers
  :type '(choice string
		 (const :tag "consult file" t)))

(defcustom message-user-organization-file
  (let (orgfile)
    (dolist (f (list "/etc/organization"
		     "/etc/news/organization"
		     "/usr/lib/news/organization"))
      (when (file-readable-p f)
	(setq orgfile f)))
    orgfile)
  "Local news organization file."
  :type '(choice (const nil) file)
  :link '(custom-manual "(message)News Headers")
  :group 'message-headers)

(defcustom message-make-forward-subject-function
  (list #'message-forward-subject-name-subject)
  "List of functions called to generate subject headers for forwarded messages.
The subject generated by the previous function is passed into each
successive function.

The provided functions are:

* `message-forward-subject-author-subject' Source of article (author or
      newsgroup), in brackets followed by the subject
* `message-forward-subject-name-subject' Source of article (name of author
      or newsgroup), in brackets followed by the subject
* `message-forward-subject-fwd' Subject of article with `Fwd:' prepended
      to it."
  :group 'message-forwarding
  :link '(custom-manual "(message)Forwarding")
  :version "27.1"
  :type '(repeat :tag "List of functions"
                 (radio (function-item message-forward-subject-author-subject)
                        (function-item message-forward-subject-fwd)
                        (function-item message-forward-subject-name-subject)
                        (function))))

(defcustom message-forward-as-mime nil
  "Non-nil means forward messages as an inline/rfc822 MIME section.
Otherwise, directly inline the old message in the forwarded
message.

When forwarding as MIME, certain MIME-related headers in the
forwarded message may be removed/altered to ensure that the
resulting mail is syntactically valid."
  :version "27.1"
  :group 'message-forwarding
  :link '(custom-manual "(message)Forwarding")
  :type 'boolean)

(defcustom message-forward-show-mml 'best
  "Non-nil means show forwarded messages as MML (decoded from MIME).
Otherwise, forwarded messages are unchanged.
Can also be the symbol `best' to indicate that MML should be
used, except when it is a bad idea to use MML.  One example where
it is a bad idea is when forwarding a signed or encrypted
message, because converting MIME to MML would invalidate the
digital signature."
  :version "21.1"
  :group 'message-forwarding
  :type '(choice (const :tag "use MML" t)
		 (const :tag "don't use MML " nil)
		 (const :tag "use MML when appropriate" best)))

(defcustom message-forward-before-signature t
  "Non-nil means put forwarded message before signature, else after."
  :group 'message-forwarding
  :type 'boolean)

(defcustom message-wash-forwarded-subjects nil
  "Non-nil means try to remove as much cruft as possible from the subject.
Done before generating the new subject of a forward."
  :group 'message-forwarding
  :link '(custom-manual "(message)Forwarding")
  :type 'boolean)

(defcustom message-ignored-resent-headers
  ;; `Delivered-To' needs to be removed because some mailers use it to
  ;; detect loops, so if you resend a message to an address that ultimately
  ;; comes back to you (e.g. a mailing-list to which you subscribe, in which
  ;; case you may be removed from the list on the grounds that mail to you
  ;; bounced with a "mailing loop" error).
  "^Return-receipt\\|^X-Gnus\\|^Gnus-Warning:\\|^>?From \\|^Delivered-To:\
\\|^X-Content-Length:\\|^X-UIDL:"
  "All headers that match this regexp will be deleted when resending a message."
  :version "24.4"
  :group 'message-interface
  :link '(custom-manual "(message)Resending")
  :type '(repeat :value-to-internal (lambda (widget value)
				      (custom-split-regexp-maybe value))
		 :match (lambda (widget value)
			  (or (stringp value)
			      (widget-editable-list-match widget value)))
		 regexp))

(defcustom message-forward-ignored-headers "^Content-Transfer-Encoding:\\|^X-Gnus"
  "All headers that match this regexp will be deleted when forwarding a message.
Also see `message-forward-included-headers' -- both variables are applied.
In addition, see `message-forward-included-mime-headers'.

This may also be a list of regexps."
  :version "21.1"
  :group 'message-forwarding
  :type '(repeat :value-to-internal (lambda (widget value)
				      (custom-split-regexp-maybe value))
		 :match (lambda (widget value)
			  (or (stringp value)
			      (widget-editable-list-match widget value)))
		 regexp))

(defcustom message-forward-included-headers
  '("^From:" "^Subject:" "^Date:" "^To:" "^Cc:")
  "If non-nil, delete non-matching headers when forwarding a message.
Only headers that match this regexp will be included.  This
variable should be a regexp or a list of regexps.

Also see `message-forward-ignored-headers' -- both variables are applied.
In addition, see `message-forward-included-mime-headers'.

When forwarding messages as MIME, but when
`message-forward-show-mml' results in MML not being used,
`message-forward-included-mime-headers' take precedence."
  :version "27.1"
  :group 'message-forwarding
  :type '(repeat :value-to-internal (lambda (widget value)
				      (custom-split-regexp-maybe value))
		 :match (lambda (widget value)
			  (or (stringp value)
			      (widget-editable-list-match widget value)))
		 regexp))

(defcustom message-forward-included-mime-headers
  '("^Content-Type:" "^MIME-Version:")
  "When forwarding as MIME, but not using MML, don't delete these headers.
Also see `message-forward-ignored-headers' and
`message-forward-ignored-headers'.

When forwarding messages as MIME, but when
`message-forward-show-mml' results in MML not being used,
`message-forward-included-mime-headers' take precedence."
  :version "28.1"
  :group 'message-forwarding
  :type '(repeat :value-to-internal (lambda (widget value)
				      (custom-split-regexp-maybe value))
		 :match (lambda (widget value)
			  (or (stringp value)
			      (widget-editable-list-match widget value)))
		 regexp))

(defcustom message-ignored-cited-headers "."
  "Delete these headers from the messages you yank."
  :group 'message-insertion
  :link '(custom-manual "(message)Insertion Variables")
  :type 'regexp)

(defcustom message-cite-prefix-regexp mail-citation-prefix-regexp
  "Regexp matching the longest possible citation prefix on a line."
  :version "24.1"
  :group 'message-insertion
  :link '(custom-manual "(message)Insertion Variables")
  :type 'regexp
  :set (lambda (symbol value)
	 (prog1
	     (custom-set-default symbol value)
	   (if (boundp 'gnus-message-cite-prefix-regexp)
	       (setq gnus-message-cite-prefix-regexp
		     (concat "^\\(?:" value "\\)"))))))

(defcustom message-cite-level-function (lambda (s) (cl-count ?> s))
  "A function to determine the level of cited text.
The function accepts 1 parameter which is the matched prefix."
  :type 'function
  :version "27.1")

(defcustom message-cancel-message "I am canceling my own article.\n"
  "Message to be inserted in the cancel message."
  :group 'message-interface
  :link '(custom-manual "(message)Canceling News")
  :type 'string)

(defun message-send-mail-function ()
  "Return suitable value for the variable `message-send-mail-function'."
  (declare (obsolete nil "27.1"))
  (require 'sendmail)
  (defvar sendmail-program)
  (cond ((executable-find sendmail-program)
	 #'message-send-mail-with-sendmail)
	((bound-and-true-p smtpmail-default-smtp-server)
	 #'message-smtpmail-send-it)
	(t
	 #'message-send-mail-with-mailclient)))

(defun message-default-send-mail-function ()
  (cond ((eq send-mail-function #'feedmail-send-it) #'feedmail-send-it)
	((eq send-mail-function #'sendmail-query-once) #'sendmail-query-once)
        ((eq send-mail-function #'sendmail-send-it)
         #'message-send-mail-with-sendmail)
	(t #'message-use-send-mail-function)))

(defun message--default-send-mail-function ()
  "Use the setting of `send-mail-function' if applicable."
  (funcall (message-default-send-mail-function)))

;; Useful to set in site-init.el
(defcustom message-send-mail-function #'message--default-send-mail-function
  "Function to call to send the current buffer as mail.
The headers should be delimited by a line whose contents match the
variable `mail-header-separator'.

Valid values include `message-send-mail-with-sendmail'
`message-send-mail-with-mh', `message-send-mail-with-qmail',
`message-smtpmail-send-it', `smtpmail-send-it',
`feedmail-send-it' and `message-send-mail-with-mailclient'.  The
default is system dependent and determined by the function
`message-send-mail-function'.

See also `send-mail-function'."
  :type '(radio (function-item message--default-send-mail-function)
		(function-item message-send-mail-with-sendmail)
		(function-item message-send-mail-with-mh)
		(function-item message-send-mail-with-qmail)
		(function-item message-smtpmail-send-it)
                (function-item :doc "Use SMTPmail package." smtpmail-send-it)
		(function-item feedmail-send-it)
                (function-item message-send-mail-with-mailclient)
 		(function :tag "Other"))
  :group 'message-sending
  :version "27.1"
  :initialize #'custom-initialize-default
  :link '(custom-manual "(message)Mail Variables")
  :group 'message-mail)

(defcustom message-send-news-function #'message-send-news
  "Function to call to send the current buffer as news.
The headers should be delimited by a line whose contents match the
variable `mail-header-separator'."
  :group 'message-sending
  :group 'message-news
  :link '(custom-manual "(message)News Variables")
  :type 'function)

(defcustom message-reply-to-function #'ignore
  "If non-nil, function that should return a list of headers.
This function should pick out addresses from the To, Cc, and From headers
and respond with new To and Cc headers."
  :group 'message-interface
  :link '(custom-manual "(message)Reply")
  :version "28.1"
  :type 'function)

(defcustom message-wide-reply-to-function #'ignore
  "If non-nil, function that should return a list of headers.
This function should pick out addresses from the To, Cc, and From headers
and respond with new To and Cc headers."
  :group 'message-interface
  :link '(custom-manual "(message)Wide Reply")
  :version "28.1"
  :type 'function)

(defcustom message-followup-to-function #'ignore
  "If non-nil, function that should return a list of headers.
This function should pick out addresses from the To, Cc, and From headers
and respond with new To and Cc headers."
  :group 'message-interface
  :link '(custom-manual "(message)Followup")
  :version "28.1"
  :type 'function)

(defcustom message-extra-wide-headers nil
  "If non-nil, a list of additional address headers.
These are used when composing a wide reply."
  :group 'message-sending
  :type '(repeat string))

(defcustom message-use-followup-to 'ask
  "Specifies what to do with Followup-To header.
If nil, always ignore the header.  If it is t, use its value, but
query before using the \"poster\" value.  If it is the symbol `ask',
always query the user whether to use the value.  If it is the symbol
`use', always use the value."
  :group 'message-interface
  :link '(custom-manual "(message)Followup")
  :type '(choice (const :tag "ignore" nil)
		 (const :tag "use & query" t)
		 (const use)
		 (const ask)))

(defcustom message-use-mail-followup-to 'use
  "Specifies what to do with Mail-Followup-To header.
If nil, always ignore the header.  If it is the symbol `ask', always
query the user whether to use the value.  If it is the symbol `use',
always use the value."
  :version "22.1"
  :group 'message-interface
  :link '(custom-manual "(message)Mailing Lists")
  :type '(choice (const :tag "ignore" nil)
		 (const use)
		 (const ask)))

(defcustom message-subscribed-address-functions nil
  "Specifies functions for determining list subscription.
If nil, do not attempt to determine list subscription with functions.
If non-nil, this variable contains a list of functions which return
regular expressions to match lists.  These functions can be used in
conjunction with `message-subscribed-regexps' and
`message-subscribed-addresses'."
  :version "22.1"
  :group 'message-interface
  :link '(custom-manual "(message)Mailing Lists")
  :type '(repeat sexp))

(defcustom message-subscribed-address-file nil
  "A file containing addresses the user is subscribed to.
If nil, do not look at any files to determine list subscriptions.  If
non-nil, each line of this file should be a mailing list address."
  :version "22.1"
  :group 'message-interface
  :link '(custom-manual "(message)Mailing Lists")
  :type '(radio file (const nil)))

(defcustom message-subscribed-addresses nil
  "Specifies a list of addresses the user is subscribed to.
If nil, do not use any predefined list subscriptions.  This list of
addresses can be used in conjunction with
`message-subscribed-address-functions' and `message-subscribed-regexps'."
  :version "22.1"
  :group 'message-interface
  :link '(custom-manual "(message)Mailing Lists")
  :type '(repeat string))

(defcustom message-subscribed-regexps nil
  "Specifies a list of addresses the user is subscribed to.
If nil, do not use any predefined list subscriptions.  This list of
regular expressions can be used in conjunction with
`message-subscribed-address-functions' and `message-subscribed-addresses'."
  :version "22.1"
  :group 'message-interface
  :link '(custom-manual "(message)Mailing Lists")
  :type '(repeat regexp))

(defcustom message-allow-no-recipients 'ask
  "Specifies what to do when there are no recipients other than Gcc/Fcc.
If it is the symbol `always', the posting is allowed.  If it is the
symbol `never', the posting is not allowed.  If it is the symbol
`ask', you are prompted."
  :version "22.1"
  :group 'message-interface
  :link '(custom-manual "(message)Message Headers")
  :type '(choice (const always)
		 (const never)
		 (const ask)))

(defcustom message-sendmail-f-is-evil
  ;; FIXME: This is related to `mail-specify-envelope-from' but works
  ;; differently (bug#36937).
  nil
  "Non-nil means don't add \"-f username\" to the \"sendmail\" command line.
The \"sendmail\" program has a useful feature to let you set the
envelope FROM address via a command line option, \"-f\".
Unfortunately, it also has a widely disliked default behavior of
disclosing your actual user name anyway by inserting an
unattractive warning in the headers.  It looks something like
this:

  X-Authentication-Warning: u1.example.com: niceguy set
      sender to niceguy@example.com using -f

It is possible to configure \"sendmail\" to not do this, but such a
reconfiguration is not an option for some users.

Note that this user option is mostly useful for actual \"sendmail\"
installations, which are rare these days."
  :group 'message-sending
  :link '(custom-manual "(message)Mail Variables")
  :type 'boolean)

(defcustom message-sendmail-envelope-from
  'obey-mail-envelope-from
  "Envelope-from when sending mail with sendmail.
If this is `obey-mail-envelope-from', then use
`mail-envelope-from' to decide what to do.  If it is nil, use
`user-mail-address'.  If it is the symbol `header', use the
\"From:\" header of the message."
  :version "27.1"
  :type '(choice (string :tag "From name")
		 (const :tag "Use From: header from message" header)
		 (const :tag "Obey `mail-envelope-from'"
		        obey-mail-envelope-from)
		 (const :tag "Use `user-mail-address'" nil))
  :link '(custom-manual "(message)Mail Variables")
  :group 'message-sending)

(defun message--sendmail-envelope-from ()
  (if (eq message-sendmail-envelope-from 'obey-mail-envelope-from)
      (if (boundp 'mail-envelope-from) mail-envelope-from)
    message-sendmail-envelope-from))

(defcustom message-sendmail-extra-arguments nil
  "Additional arguments to `sendmail-program'.
A list of strings, e.g. (\"-a\" \"account\") for msmtp."
  :version "23.1" ;; No Gnus
  :type '(repeat string)
  ;; :link '(custom-manual "(message)Mail Variables")
  :group 'message-sending)

;; qmail-related stuff
(defcustom message-qmail-inject-program "/var/qmail/bin/qmail-inject"
  "Location of the qmail-inject program."
  :group 'message-sending
  :link '(custom-manual "(message)Mail Variables")
  :type 'file)

(defcustom message-qmail-inject-args nil
  "Arguments passed to qmail-inject programs.
This should be a list of strings, one string for each argument.
It may also be a function.

For e.g., if you wish to set the envelope sender address so that bounces
go to the right place or to deal with listserv's usage of that address, you
might set this variable to (\"-f\" \"you@some.where\")."
  :group 'message-sending
  :link '(custom-manual "(message)Mail Variables")
  :type '(choice (function)
		 (repeat string)))

(defvar gnus-post-method)
(defvar gnus-select-method)
(defcustom message-post-method
  (cond ((and (boundp 'gnus-post-method)
	      (listp gnus-post-method)
	      gnus-post-method)
	 gnus-post-method)
	((boundp 'gnus-select-method)
	 gnus-select-method)
	(t '(nnspool "")))
  "Method used to post news.
Note that when posting from inside Gnus, for instance, this
variable isn't used."
  :group 'message-news
  :group 'message-sending
  ;; This should be the `gnus-select-method' widget, but that might
  ;; create a dependence to `gnus.el'.
  :type 'sexp)

(defcustom message-generate-headers-first nil
  "Which headers should be generated before starting to compose a message.
If t, generate all required headers.  This can also be a list of headers to
generate.  The variables `message-required-news-headers' and
`message-required-mail-headers' specify which headers to generate.

Note that the variable `message-deletable-headers' specifies headers which
are to be deleted and then re-generated before sending, so this variable
will not have a visible effect for those headers."
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(choice (const :tag "None" nil)
		 (const :tag "All" t)
		 (repeat (sexp :tag "Header"))))

(defcustom message-fill-column 72
  "Column beyond which automatic line-wrapping should happen.
Local value for message buffers.  If non-nil, also turn on
auto-fill in message buffers."
  :group 'message-various
  ;; :link '(custom-manual "(message)Message Headers")
  :type '(choice (const :tag "Don't turn on auto fill" nil)
		 (integer)))

(defcustom message-setup-hook nil
  "Normal hook, run each time a new outgoing message is initialized.
The function `message-setup' runs this hook."
  :group 'message-various
  :link '(custom-manual "(message)Various Message Variables")
  :type 'hook)

(defcustom message-cancel-hook nil
  "Hook run when canceling articles."
  :group 'message-various
  :link '(custom-manual "(message)Various Message Variables")
  :type 'hook)

(defcustom message-signature-setup-hook nil
  "Normal hook, run each time a new outgoing message is initialized.
It is run after the headers have been inserted and before
the signature is inserted."
  :group 'message-various
  :link '(custom-manual "(message)Various Message Variables")
  :type 'hook)

(defcustom message-mode-hook nil
  "Hook run in message mode buffers."
  :group 'message-various
  :type 'hook)

(defcustom message-header-hook nil
  "Hook run in a message mode buffer narrowed to the headers."
  :group 'message-various
  :type 'hook)

(defcustom message-header-setup-hook nil
  "Hook called narrowed to the headers when setting up a message buffer."
  :group 'message-various
  :link '(custom-manual "(message)Various Message Variables")
  :type 'hook)

(defcustom message-minibuffer-local-map
  (let ((map (make-sparse-keymap 'message-minibuffer-local-map)))
    (set-keymap-parent map minibuffer-local-map)
    map)
  "Keymap for `message-read-from-minibuffer'."
  ;; FIXME improve type.
  :type '(restricted-sexp :match-alternatives (symbolp keymapp))
  :version "22.1"
  :group 'message-various)

(defcustom message-citation-line-function #'message-insert-citation-line
  "Function called to insert the \"Whomever writes:\" line.

Predefined functions include `message-insert-citation-line' and
`message-insert-formatted-citation-line' (see the variable
`message-citation-line-format').

Note that Gnus provides a feature where the reader can click on
`writes:' to hide the cited text.  If you change this line too much,
people who read your message will have to change their Gnus
configuration.  See the variable `gnus-cite-attribution-suffix'."
  :type '(choice
	  (function-item :tag "plain" message-insert-citation-line)
	  (function-item :tag "formatted" message-insert-formatted-citation-line)
	  (function :tag "Other"))
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-insertion)

(defcustom message-citation-line-format "On %a, %b %d %Y, %N wrote:\n"
  "Format of the \"Whomever writes:\" line.

The string is formatted using `format-spec'.  The following constructs
are replaced:

  %f   The full From, e.g. \"John Doe <john.doe@example.invalid>\".
  %n   The mail address, e.g. \"john.doe@example.invalid\".
  %N   The real name if present, e.g.: \"John Doe\", else fall
       back to the mail address.
  %F   The first name if present, e.g.: \"John\", else fall
       back to the mail address.
  %L   The last name if present, e.g.: \"Doe\".

All other format specifiers are passed to `format-time-string'
which is called using the date from the article your replying to, but
the date in the formatted string will be expressed in the author's
time zone as much as possible.
Extracting the first (%F) and last name (%L) is done heuristically,
so you should always check it yourself.

Please also read the note in the documentation of
`message-citation-line-function'."
  :type '(choice (const :tag "Plain" "%f writes:")
		 (const :tag "Include date" "On %a, %b %d %Y, %n wrote:")
		 string)
  :link '(custom-manual "(message)Insertion Variables")
  :version "23.1" ;; No Gnus
  :group 'message-insertion)

(defcustom message-yank-prefix mail-yank-prefix
  "Prefix inserted on the lines of yanked messages.
Fix `message-cite-prefix-regexp' if it is set to an abnormal value.
See also `message-yank-cited-prefix' and `message-yank-empty-prefix'."
  :version "23.2"
  :type 'string
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-insertion)

(defcustom message-yank-cited-prefix ">"
  "Prefix inserted on cited lines of yanked messages.
Fix `message-cite-prefix-regexp' if it is set to an abnormal value.
See also `message-yank-prefix' and `message-yank-empty-prefix'."
  :version "22.1"
  :type 'string
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-insertion)

(defcustom message-yank-empty-prefix ">"
  "Prefix inserted on empty lines of yanked messages.
See also `message-yank-prefix' and `message-yank-cited-prefix'."
  :version "22.1"
  :type 'string
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-insertion)

(defcustom message-indentation-spaces mail-indentation-spaces
  "Number of spaces to insert at the beginning of each cited line.
Used by `message-yank-original' via `message-yank-cite'."
  :version "23.2"
  :group 'message-insertion
  :link '(custom-manual "(message)Insertion Variables")
  :type 'integer)

(defcustom message-cite-function #'message-cite-original-without-signature
  "Function for citing an original message.
Predefined functions include `message-cite-original' and
`message-cite-original-without-signature'.
Note that these functions use `mail-citation-hook' if that is non-nil."
  :type '(radio (function-item message-cite-original)
		(function-item message-cite-original-without-signature)
		(function-item sc-cite-original)
		(function :tag "Other"))
  :link '(custom-manual "(message)Insertion Variables")
  :version "22.3" ;; Gnus 5.10.12 (changed default)
  :group 'message-insertion)

(defcustom message-indent-citation-function #'message-indent-citation
  "Function for modifying a citation just inserted in the mail buffer.
This can also be a list of functions.  Each function can find the
citation between (point) and (mark t).  And each function should leave
point and mark around the citation text as modified."
  :type '(choice function
                 (repeat function))
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-insertion)

(defcustom message-signature mail-signature
  "String to be inserted at the end of the message buffer.
If nil, don't insert a signature.
If t, insert `message-signature-file'.
If a function or form, insert its result.
See `mail-signature' for the recommended format of a signature.
Also see `message-signature-insert-empty-line'."
  :version "23.2"
  :type '(choice string
                 (const :tag "None" nil)
                 (const :tag "Contents of signature file" t)
                 function sexp)
  :risky t
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-insertion)

(defcustom message-signature-file mail-signature-file
  "Name of file containing the text inserted at end of message buffer.
Ignored if the named file doesn't exist.
If nil, don't insert a signature.
If a path is specified, the value of `message-signature-directory' is ignored,
even if set."
  :version "23.2"
  :type '(choice file (const :tags "None" nil))
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-insertion)

(defcustom message-signature-directory nil
  "Name of directory containing signature files.
Comes in handy if you have many such files, handled via posting styles for
instance.
If nil, `message-signature-file' is expected to specify the directory if
needed."
  :type '(choice string (const :tags "None" nil))
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-insertion)

(defcustom message-signature-insert-empty-line t
  "If non-nil, insert an empty line before the signature separator."
  :version "22.1"
  :type 'boolean
  :link '(custom-manual "(message)Insertion Variables")
  :group 'message-insertion)

(defcustom message-cite-reply-position 'traditional
  "Where the reply should be positioned.
If `traditional', reply inline.
If `above', reply above quoted text.
If `below', reply below quoted text.

Note: Many newsgroups frown upon nontraditional reply styles.
You probably want to set this variable only for specific groups,
e.g. using `gnus-posting-styles':

  (eval (setq-local message-cite-reply-position \\='above))"
  :version "24.1"
  :type '(choice (const :tag "Reply inline" traditional)
		 (const :tag "Reply above" above)
		 (const :tag "Reply below" below))
  :group 'message-insertion)

(defcustom message-cite-style nil
  "The overall style to be used when yanking cited text.
Value is either nil (no variable overrides) or a let-style list
of pairs (VARIABLE VALUE) that will be bound in
`message-yank-original' to do the quoting.

Presets to impersonate popular mail agents are found in the
message-cite-style-* variables.  This variable is intended for
use in `gnus-posting-styles', such as:

  ((posting-from-work-p) (eval (setq-local message-cite-style
                                           message-cite-style-outlook)))"
  :version "24.1"
  :group 'message-insertion
  :type '(choice (const :tag "Do not override variables" :value nil)
		 (const :tag "MS Outlook" :value message-cite-style-outlook)
		 (const :tag "Mozilla Thunderbird" :value message-cite-style-thunderbird)
		 (const :tag "Gmail" :value message-cite-style-gmail)
		 (variable :tag "User-specified")))

(defconst message-cite-style-outlook
  '((message-cite-function  'message-cite-original)
    (message-citation-line-function  'message-insert-formatted-citation-line)
    (message-cite-reply-position 'above)
    (message-yank-prefix  "")
    (message-yank-cited-prefix  "")
    (message-yank-empty-prefix  "")
    (message-citation-line-format  "\n\n-----------------------\nOn %a, %b %d %Y, %N wrote:\n"))
  "Message citation style used by MS Outlook.  Use with `message-cite-style'.")

(defconst message-cite-style-thunderbird
  '((message-cite-function  'message-cite-original)
    (message-citation-line-function  'message-insert-formatted-citation-line)
    (message-cite-reply-position 'above)
    (message-yank-prefix  "> ")
    (message-yank-cited-prefix  ">")
    (message-yank-empty-prefix  ">")
    (message-citation-line-format "On %D %R %p, %N wrote:"))
  "Message citation style used by Mozilla Thunderbird.
Use with `message-cite-style'.")

(defconst message-cite-style-gmail
  '((message-cite-function  'message-cite-original)
    (message-citation-line-function  'message-insert-formatted-citation-line)
    (message-cite-reply-position 'above)
    (message-yank-prefix  "    ")
    (message-yank-cited-prefix  "    ")
    (message-yank-empty-prefix  "    ")
    (message-citation-line-format "On %e %B %Y %R, %f wrote:\n"))
  "Message citation style used by Gmail.  Use with `message-cite-style'.")

(defcustom message-distribution-function nil
  "Function called to return a Distribution header."
  :group 'message-news
  :group 'message-headers
  :link '(custom-manual "(message)News Headers")
  :type '(choice function (const nil)))

(defcustom message-expires 14
  "Number of days before your article expires."
  :group 'message-news
  :group 'message-headers
  :link '(custom-manual "(message)News Headers")
  :type 'integer)

(defcustom message-user-path nil
  "If nil, use the NNTP server name in the Path header.
If stringp, use this; if non-nil, use no host name (user name only)."
  :group 'message-news
  :group 'message-headers
  :link '(custom-manual "(message)News Headers")
  :type '(choice (const :tag "nntp" nil)
		 (string :tag "name")
		 (sexp :tag "none" :format "%t" t)))

;; This can be the name of a buffer, or a cons cell (FUNCTION . ARGS)
;; for yanking the original buffer.
(defvar message-reply-buffer nil)
(defvar message-reply-headers nil
  "The headers of the current replied article.
It is a vector of the following headers:
[number subject from date id references chars lines xref extra].")
(defvar message-newsreader nil)
(defvar message-mailer nil)
(defvar message-sent-message-via nil)
(defvar message-checksum nil)
(defvar message-send-actions nil
  "A list of actions to be performed upon successful sending of a message.")
(defvar message-return-action nil
  "Action to return to the caller after sending or postponing a message.")
(defvar message-exit-actions nil
  "A list of actions to be performed upon exiting after sending a message.")
(defvar message-kill-actions nil
  "A list of actions to be performed before killing a message buffer.")
(defvar message-postpone-actions nil
  "A list of actions to be performed after postponing a message.")

(define-widget 'message-header-lines 'text
  "All header lines must be LFD terminated."
  :format "%{%t%}:%n%v"
  :valid-regexp "^\\'"
  :error "All header lines must be newline terminated")

(defcustom message-default-headers ""
  "Header lines to be inserted in outgoing messages.
This can be set to a string containing or a function returning
header lines to be inserted before you edit the message, so you
can edit or delete these lines.  If set to a function, it is
called and its result is inserted."
  :version "23.2"
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(choice
          (message-header-lines :tag "String")
          (function :tag "Function")))

(defcustom message-default-mail-headers
  ;; Ease the transition from mail-mode to message-mode.  See bugs#4431, 5555.
  (concat (if (and (boundp 'mail-default-reply-to)
		   (stringp mail-default-reply-to))
	      (format "Reply-To: %s\n" mail-default-reply-to))
	  (if (and (boundp 'mail-self-blind)
		   mail-self-blind)
	      (format "Bcc: %s\n" user-mail-address))
	  (if (and (boundp 'mail-archive-file-name)
		   (stringp mail-archive-file-name))
	      (format "Fcc: %s\n" mail-archive-file-name))
	  mail-default-headers)
  "A string of header lines to be inserted in outgoing mails."
  :version "23.2"
  :group 'message-headers
  :group 'message-mail
  :link '(custom-manual "(message)Mail Headers")
  :type 'message-header-lines)

(defcustom message-default-news-headers ""
  "A string of header lines to be inserted in outgoing news articles."
  :group 'message-headers
  :group 'message-news
  :link '(custom-manual "(message)News Headers")
  :type 'message-header-lines)

;; Note: could use /usr/ucb/mail instead of sendmail;
;; options -t, and -v if not interactive.
(defcustom message-mailer-swallows-blank-line
  (if (and (string-match "sparc-sun-sunos\\(\\'\\|[^5]\\)"
			 system-configuration)
	   (file-readable-p "/etc/sendmail.cf")
	   (with-temp-buffer
             (insert-file-contents "/etc/sendmail.cf")
             (goto-char (point-min))
             (let ((case-fold-search nil))
               (re-search-forward "^OR\\>" nil t))))
      ;; According to RFC 822 and its successors, the field name must
      ;; consist of printable US-ASCII characters other than colon,
      ;; i.e., decimal 33-56 and 59-126.
      '(looking-at "[ \t]\\|[][!\"#$%&'()*+,./0-9;<=>?@A-Z\\^_`a-z{|}~-]+:"))
  "Set this non-nil if the system's mailer runs the header and body together.
\(This problem exists on Sunos 4 when sendmail is run in remote mode.)
The value should be an expression to test whether the problem will
actually occur."
  :group 'message-sending
  :link '(custom-manual "(message)Mail Variables")
  :risky t
  :type 'sexp)

;;;###autoload
(define-mail-user-agent 'message-user-agent
  'message-mail 'message-send-and-exit
  'message-kill-buffer 'message-send-hook)

(defvar message-mh-deletable-headers '(Message-ID Date Lines Sender)
  "If non-nil, delete the deletable headers before feeding to mh.")

(defvar message-send-method-alist
  '((news message-news-p message-send-via-news)
    (mail message-mail-p message-send-via-mail))
  "Alist of ways to send outgoing messages.
Each element has the form

  (TYPE PREDICATE FUNCTION)

where TYPE is a symbol that names the method; PREDICATE is a function
called without any parameters to determine whether the message is
a message of type TYPE; and FUNCTION is a function to be called if
PREDICATE returns non-nil.  FUNCTION is called with one parameter --
the prefix.")

(defcustom message-mail-alias-type 'abbrev
  "What alias expansion type to use in Message buffers.
The default is `abbrev', which uses mailabbrev.  `ecomplete' uses
an electric completion mode.  nil switches mail aliases off.
This can also be a list of values."
  :group 'message
  :link '(custom-manual "(message)Mail Aliases")
  :type '(choice (const :tag "Use Mailabbrev" abbrev)
                 (const :tag "Use ecomplete" ecomplete)
                 (set (const :tag "Use Mailabbrev" abbrev)
                      (const :tag "Use ecomplete" ecomplete))))

(defcustom message-self-insert-commands '(self-insert-command)
  "List of `self-insert-command's used to trigger ecomplete.
When one of those commands is invoked to enter a character in To or Cc
header, ecomplete will suggest the candidates of recipients (see also
`message-mail-alias-type').  If you use some tool to enter non-ASCII
text and it replaces `self-insert-command' with the other command, e.g.
`egg-self-insert-command', you may want to add it to this list."
  :group 'message-various
  :type '(repeat function))

(defcustom message-auto-save-directory
  (if (file-writable-p message-directory)
      (file-name-as-directory (expand-file-name "drafts" message-directory))
    "~/")
  "Directory where Message auto-saves buffers if Gnus isn't running.
If nil, Message won't auto-save, whether or not Gnus is running."
  :group 'message-buffers
  :link '(custom-manual "(message)Various Message Variables")
  :type '(choice directory (const :tag "Don't auto-save" nil)))

(defcustom message-default-charset (and (not enable-multibyte-characters)
					'iso-8859-1)
  "Default charset used in non-MULE Emacsen.
If nil, you might be asked to input the charset."
  :version "21.1"
  :group 'message
  :link '(custom-manual "(message)Various Message Variables")
  :type 'symbol)
(make-obsolete-variable
 'message-default-charset
 "The default charset comes from the language environment" "26.1")

(defcustom message-dont-reply-to-names mail-dont-reply-to-names
  "Addresses to prune when doing wide replies.
This can be a regexp, a list of regexps or a predicate function.
Also, a value of nil means exclude `user-mail-address' only.

If a function email is passed as the argument."
  :version "24.3"
  :group 'message
  :link '(custom-manual "(message)Wide Reply")
  :type '(choice (const :tag "Yourself" nil)
                 regexp
                 (repeat :tag "Regexp List" regexp)
                 function))

(defsubst message-dont-reply-to-names ()
  (if (functionp message-dont-reply-to-names)
      message-dont-reply-to-names
    (gmm-regexp-concat message-dont-reply-to-names)))

(defcustom message-shoot-gnksa-feet nil
  "A list of GNKSA feet you are allowed to shoot.
Gnus gives you all the opportunity you could possibly want for
shooting yourself in the foot.  Also, Gnus allows you to shoot the
feet of Good Net-Keeping Seal of Approval.  The following are foot
candidates:
`empty-article'     Allow you to post an empty article;
`quoted-text-only'  Allow you to post quoted text only;
`multiple-copies'   Allow you to post multiple copies;
`cancel-messages'   Allow you to cancel or supersede messages from
		    your other email addresses;
`canlock-verify'    Allow you to cancel messages without verifying canlock."
  :group 'message
  :type '(set (const empty-article) (const quoted-text-only)
	      (const multiple-copies) (const cancel-messages)
	      (const canlock-verify)))

(defsubst message-gnksa-enable-p (feature)
  (or (not (listp message-shoot-gnksa-feet))
      (memq feature message-shoot-gnksa-feet)))

(defcustom message-hidden-headers '("^References:" "^Face:" "^X-Face:"
				    "^X-Draft-From:" "^In-Reply-To:")
  "Regexp of headers to be hidden when composing new messages.
This can also be a list of regexps to match headers.  Or a list
starting with `not' and followed by regexps."
  :version "29.1"
  :group 'message
  :link '(custom-manual "(message)Message Headers")
  :type '(choice
	  :format "%{%t%}: %[Value Type%] %v"
	  (regexp :menu-tag "regexp" :format "regexp\n%t: %v")
	  (repeat :menu-tag "(regexp ...)" :format "(regexp ...)\n%v%i"
		  (regexp :format "%t: %v"))
	  (cons :menu-tag "(not regexp ...)" :format "(not regexp ...)\n%v"
		(const not)
		(repeat :format "%v%i"
			(regexp :format "%t: %v")))))

(defcustom message-cite-articles-with-x-no-archive t
  "If non-nil, cite text from articles that has X-No-Archive set."
  :group 'message
  :type 'boolean)

;;; Internal variables.
;;; Well, not really internal.

(defvar message-mode-syntax-table
  (let ((table (copy-syntax-table text-mode-syntax-table)))
    (modify-syntax-entry ?% ". " table)
    (modify-syntax-entry ?> ". " table)
    (modify-syntax-entry ?< ". " table)
    table)
  "Syntax table used while in Message mode.")

(defface message-header-to
  '((((class color)
      (background dark))
     :foreground "DarkOliveGreen1" :weight bold)
    (((class color)
      (background light))
     :foreground "MidnightBlue" :weight bold)
    (t
     :weight bold :slant italic))
  "Face used for displaying To headers."
  :group 'message-faces)

(defface message-header-cc
  '((((class color)
      (background dark))
     :foreground "chartreuse1" :weight bold)
    (((class color)
      (background light))
     :foreground "MidnightBlue")
    (t
     :weight bold))
  "Face used for displaying Cc headers."
  :group 'message-faces)

(defface message-header-subject
  '((((class color)
      (background dark))
     :foreground "OliveDrab1")
    (((class color)
      (background light))
     :foreground "navy blue" :weight bold)
    (t
     :weight bold))
  "Face used for displaying Subject headers."
  :group 'message-faces)

(defface message-header-newsgroups
  '((((class color)
      (background dark))
     :foreground "yellow" :weight bold :slant italic)
    (((class color)
      (background light))
     :foreground "blue4" :weight bold :slant italic)
    (t
     :weight bold :slant italic))
  "Face used for displaying Newsgroups headers."
  :group 'message-faces)

(defface message-header-other
  '((((class color)
      (background dark))
     :foreground "VioletRed1")
    (((class color)
      (background light))
     :foreground "steel blue")
    (t
     :weight bold :slant italic))
  "Face used for displaying other headers."
  :group 'message-faces)

(defface message-header-name
  '((((class color)
      (background dark))
     :foreground "green")
    (((class color)
      (background light))
     :foreground "cornflower blue")
    (t
     :weight bold))
  "Face used for displaying header names."
  :group 'message-faces)

(defface message-header-xheader
  '((((class color)
      (background dark))
     :foreground "DeepSkyBlue1")
    (((class color)
      (background light))
     :foreground "blue")
    (t
     :weight bold))
  "Face used for displaying X-Header headers."
  :group 'message-faces)

(defface message-separator
  '((((class color)
      (background dark))
     :foreground "LightSkyBlue1")
    (((class color)
      (background light))
     :foreground "brown")
    (t
     :weight bold))
  "Face used for displaying the separator."
  :group 'message-faces)

(defface message-cited-text-1
  '((((class color)
      (background dark))
     (:foreground "LightPink1"))
    (((class color)
      (background light))
     (:foreground "red1"))
    (t
     (:weight bold)))
  "Face used for displaying 1st-level cited text."
  :group 'message-faces)

(defface message-cited-text-2
  '((((class color)
      (background dark))
     (:foreground "forest green"))
    (((class color)
      (background light))
     (:foreground "red4"))
    (t
     (:weight bold)))
  "Face used for displaying 2nd-level cited text."
  :group 'message-faces)

(defface message-cited-text-3
  '((((class color)
      (background dark))
     (:foreground "goldenrod3"))
    (((class color)
      (background light))
     (:foreground "OliveDrab4"))
    (t
     (:weight bold)))
  "Face used for displaying 3rd-level cited text."
  :group 'message-faces)

(defface message-cited-text-4
  '((((class color)
      (background dark))
     (:foreground "chocolate3"))
    (((class color)
      (background light))
     (:foreground "SteelBlue4"))
    (t
     (:weight bold)))
  "Face used for displaying 4th-level cited text."
  :group 'message-faces)

;; backward-compatibility alias
(put 'message-cited-text 'face-alias 'message-cited-text-1)
(put 'message-cited-text 'obsolete-face "26.1")

(defface message-mml
  '((((class color)
      (background dark))
     :foreground "MediumSpringGreen")
    (((class color)
      (background light))
     :foreground "ForestGreen")
    (t
     :weight bold))
  "Face used for displaying MML."
  :group 'message-faces)

(defface message-signature-separator '((t :weight bold))
  "Face used for displaying the signature separator."
  :group 'message-faces
  :version "28.1")

(defun message-match-to-eoh (_limit)
  (let ((start (point)))
    (rfc822-goto-eoh)
    ;; Typical situation: some temporary change causes the header to be
    ;; incorrect, so EOH comes earlier than intended: the last lines of the
    ;; intended headers are now not considered part of the header any more,
    ;; so they don't have the multiline property set.  When the change is
    ;; completed and the header has its correct shape again, the lack of the
    ;; multiline property means we won't rehighlight the last lines of
    ;; the header.
    (if (< (point) start)
        nil                             ;No header within start..limit.
      ;; Here we disregard LIMIT so that we may extend the area again.
      (set-match-data (list start (point)))
      (point))))

(defun message-font-lock-make-cited-text-matcher (level maxlevel)
  "Generate the matcher for cited text.
LEVEL is the citation level to be matched and MAXLEVEL is the
number of levels specified in the faces `message-cited-text-*'."
  (lambda (limit)
    (let (matched)
      ;; Keep search until `message-cite-level-function' returns the level
      ;; we want to match.
      (while (and (re-search-forward (concat "^\\("
                                             message-cite-prefix-regexp
                                             "\\).*")
                                     limit t)
		  (not (setq matched
                             (save-match-data
                               (= (1- level)
				  (mod
                                   (1- (funcall message-cite-level-function
						(match-string 1)))
                                   maxlevel)))))))
      matched)))

(defvar message-font-lock-keywords
  (nconc
   (let ((content "[ \t]*\\(.+\\(\n[ \t].*\\)*\\)\n?"))
     `((message-match-to-eoh
	(,(concat "^\\([Tt]o:\\)" content)
	 (progn (goto-char (match-beginning 0)) (match-end 0)) nil
	 (1 'message-header-name)
	 (2 'message-header-to nil t))
	(,(concat "^\\(^[GBF]?[Cc][Cc]:\\|^[Rr]eply-[Tt]o:\\)" content)
	 (progn (goto-char (match-beginning 0)) (match-end 0)) nil
	 (1 'message-header-name)
	 (2 'message-header-cc nil t))
	(,(concat "^\\([Ss]ubject:\\)" content)
	 (progn (goto-char (match-beginning 0)) (match-end 0)) nil
	 (1 'message-header-name)
	 (2 'message-header-subject nil t))
	(,(concat "^\\([Nn]ewsgroups:\\|Followup-[Tt]o:\\)" content)
	 (progn (goto-char (match-beginning 0)) (match-end 0)) nil
	 (1 'message-header-name)
	 (2 'message-header-newsgroups nil t))
	(,(concat "^\\(X-[A-Za-z0-9-]+:\\|In-Reply-To:\\)" content)
	 (progn (goto-char (match-beginning 0)) (match-end 0)) nil
	 (1 'message-header-name)
	 (2 'message-header-xheader))
	(,(concat "^\\([A-Z][^: \n\t]+:\\)" content)
	 (progn (goto-char (match-beginning 0)) (match-end 0)) nil
         (1 'message-header-name)
         (2 'message-header-other nil t)))
       (,(lambda (limit)
           (and mail-header-separator
		(not (equal mail-header-separator ""))
		(re-search-forward
                 (concat "^" (regexp-quote mail-header-separator) "$")
                 limit t)))
	0 'message-separator)
       ("<#/?\\(?:multipart\\|part\\|external\\|mml\\|secure\\)[^>]*>"
	0 'message-mml)))
   ;; Additional font locks to highlight different levels of cited text
   (let ((maxlevel 1)
         (level 1)
         cited-text-face
         keywords)
     ;; Compute the max level.
     (while (setq cited-text-face
                  (intern-soft (format "message-cited-text-%d" maxlevel)))
       (setq maxlevel (1+ maxlevel)))
     (setq maxlevel (1- maxlevel))
     ;; Generate the keywords.
     (while (setq cited-text-face
                  (intern-soft (format "message-cited-text-%d" level)))
       (setq keywords
             (cons
              `(,(message-font-lock-make-cited-text-matcher level maxlevel)
                (0 ',cited-text-face))
              keywords))
       (setq level (1+ level)))
     keywords)
   ;; Match signature.  This `field' stuff ensures that hitting `RET'
   ;; after the signature separator doesn't remove the trailing space.
   (list
    '(message--match-signature (0 '( face message-signature-separator
                                     rear-nonsticky t
                                     field signature)))))
  "Additional expressions to highlight in Message mode.")

(defun message--match-signature (limit)
  (save-excursion
    (and (re-search-forward message-signature-separator limit t)
         ;; It's the last one in the buffer.
         (not (save-excursion
                (re-search-forward message-signature-separator nil t))))))

(defvar message-face-alist
  '((bold . message-bold-region)
    (underline . underline-region)
    (default . (lambda (b e)
		 (message-unbold-region b e)
		 (ununderline-region b e))))
  "Alist of mail and news faces for facemenu.
The cdr of each entry is a function for applying the face to a region.")

(defcustom message-send-hook nil
  "Hook run before sending messages.
This hook is run quite early when sending."
  :group 'message-various
  :options '(ispell-message)
  :link '(custom-manual "(message)Various Message Variables")
  :type 'hook)

(defcustom message-send-mail-hook nil
  "Hook run before sending mail messages.
This hook is run very late -- just before the message is sent as
mail."
  :group 'message-various
  :link '(custom-manual "(message)Various Message Variables")
  :type 'hook)

(defcustom message-send-news-hook nil
  "Hook run before sending news messages.
This hook is run very late -- just before the message is sent as
news."
  :group 'message-various
  :link '(custom-manual "(message)Various Message Variables")
  :type 'hook)

(defcustom message-sent-hook nil
  "Hook run after sending messages."
  :group 'message-various
  :type 'hook)

(defvar message-send-coding-system 'binary
  "Coding system to encode outgoing mail.")

(defvar message-draft-coding-system mm-auto-save-coding-system
  "Coding system to compose mail.")

(defcustom message-send-mail-partially-limit nil
  "The limitation of messages sent as message/partial.
The lower bound of message size in characters, beyond which the message
should be sent in several parts.  If it is nil, the size is unlimited."
  :version "24.1"
  :group 'message-buffers
  :link '(custom-manual "(message)Mail Variables")
  :type '(choice (const :tag "unlimited" nil)
		 (integer 1000000)))

(defcustom message-alternative-emails nil
  "Regexp or predicate function matching alternative email addresses.
The first address in the To, Cc or From headers of the original
article matching this variable is used as the From field of
outgoing messages.

If a function, an email string is passed as the argument.

This variable has precedence over posting styles and anything that runs
off `message-setup-hook'."
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(choice (const :tag "Always use primary" nil)
		 regexp
                 function))

(defcustom message-hierarchical-addresses nil
  "A list of hierarchical mail address definitions.

Inside each entry, the first address is the \"top\" address, and
subsequent addresses are subaddresses; this is used to indicate that
mail sent to the first address will automatically be delivered to the
subaddresses.  So if the first address appears in the recipient list
for a message, the subaddresses will be removed (if present) before
the mail is sent.  All addresses in this structure should be
downcased."
  :version "22.1"
  :group 'message-headers
  :type '(repeat (repeat string)))

(defcustom message-mail-user-agent nil
  "Your preferred package for composing and sending email when using message.el.
Like `mail-user-agent' (which see), this specifies the package you prefer
to use for composing and sending email messages.
The value can be anything accepted by `mail-user-agent', and in addition
it can be nil or t.  If the value is nil, use the Gnus native Mail User
Agent (MUA); if it is t, use the value of `mail-user-agent'.
For more about mail user agents, see Info node `(emacs)Mail Methods'"
  :version "22.1"
  :type '(radio (const :tag "Gnus native"
		       :format "%t\n"
		       nil)
		(const :tag "`mail-user-agent'"
		       :format "%t\n"
		       t)
		(function-item :tag "Default Emacs mail"
			       :format "%t\n"
			       sendmail-user-agent)
		(function-item :tag "Emacs interface to MH"
			       :format "%t\n"
			       mh-e-user-agent)
		(function :tag "Other"))
  :version "21.1"
  :group 'message)

(defcustom message-wide-reply-confirm-recipients nil
  "Whether to confirm a wide reply to multiple email recipients.
If this variable is nil, don't ask whether to reply to all recipients.
If this variable is non-nil, pose the question \"Reply to all
recipients?\" before a wide reply to multiple recipients.  If the user
answers yes, reply to all recipients as usual.  If the user answers
no, only reply back to the author."
  :version "22.1"
  :group 'message-headers
  :link '(custom-manual "(message)Wide Reply")
  :type 'boolean)

(defcustom message-user-fqdn nil
  "Domain part of Message-IDs."
  :version "22.1"
  :group 'message-headers
  :link '(custom-manual "(message)News Headers")
  :type '(radio (const :format "%v  " nil)
		(string :format "FQDN: %v")))

(defcustom message-use-idna t
  "Whether to encode non-ASCII in domain names into ASCII according to IDNA."
  :version "26.1"
  :group 'message-headers
  :link '(custom-manual "(message)IDNA")
  :type '(choice (const :tag "Ask" ask)
		 (const :tag "Never" nil)
		 (const :tag "Always" t)))

(defcustom message-generate-hashcash nil
  "Whether to generate X-Hashcash: headers.
If t, always generate hashcash headers.  If `opportunistic',
only generate hashcash headers if it can be done without the user
waiting (i.e., only asynchronously).  If nil, don't generate
hashcash headers.

You must have the \"hashcash\" binary installed, see `hashcash-program'."
  :version "24.1"
  :group 'message-headers
  :link '(custom-manual "(message)Mail Headers")
  :type '(choice (const :tag "Always" t)
		 (const :tag "Never" nil)
		 (const :tag "Opportunistic" opportunistic)))
(make-obsolete-variable 'message-generate-hashcash "it does nothing." "31.1")

;;; Internal variables.

(defvar message-inhibit-body-encoding nil)
(defvar message-sending-message "Sending...")
(defvar message-buffer-list nil)
(defvar message-this-is-news nil)
(defvar message-this-is-mail nil)
(defvar message-draft-article nil)
(defvar message-mime-part nil)
(defvar message-posting-charset nil)
(defvar message-inserted-headers nil)
(defvar message-inhibit-ecomplete nil)

;; Byte-compiler warning
(defvar gnus-active-hashtb)
(defvar gnus-read-active-file)

;;; Regexp matching the delimiter of messages in UNIX mail format
;;; (UNIX From lines), minus the initial ^.  It should be a copy
;;; of rmail.el's rmail-unix-mail-delimiter.
(defvar message-unix-mail-delimiter
  (let ((time-zone-regexp
	 (concat "\\([A-Z]?[A-Z]?[A-Z][A-Z]\\( DST\\)?"
		 "\\|[-+]?[0-9][0-9][0-9][0-9]"
		 "\\|"
		 "\\) *")))
    (concat
     "From "

     ;; Many things can happen to an RFC 822 (or later) mailbox before it is
     ;; put into a `From' line.  The leading phrase can be stripped, e.g.
     ;; `Joe <@w.x:joe@y.z>' -> `<@w.x:joe@y.z>'.  The <> can be stripped, e.g.
     ;; `<@x.y:joe@y.z>' -> `@x.y:joe@y.z'.  Everything starting with a CRLF
     ;; can be removed, e.g.
     ;;		From: joe@y.z (Joe	K
     ;;			User)
     ;; can yield `From joe@y.z (Joe	K Fri Mar 22 08:11:15 1996', and
     ;;		From: Joe User
     ;;			<joe@y.z>
     ;; can yield `From Joe User Fri Mar 22 08:11:15 1996'.
     ;; The mailbox can be removed or be replaced by white space, e.g.
     ;;		From: "Joe User"{space}{tab}
     ;;			<joe@y.z>
     ;; can yield `From {space}{tab} Fri Mar 22 08:11:15 1996',
     ;; where {space} and {tab} represent the Ascii space and tab characters.
     ;; We want to match the results of any of these manglings.
     ;; The following regexp rejects names whose first characters are
     ;; obviously bogus, but after that anything goes.
     "\\([^\0-\b\n-\r\^?].*\\)?"

     ;; The time the message was sent.
     "\\([^\0-\r \^?]+\\) +"		; day of the week
     "\\([^\0-\r \^?]+\\) +"		; month
     "\\([0-3]?[0-9]\\) +"		; day of month
     "\\([0-2][0-9]:[0-5][0-9]\\(:[0-6][0-9]\\)?\\) *" ; time of day

     ;; Perhaps a time zone, specified by an abbreviation, or by a
     ;; numeric offset.
     time-zone-regexp

     ;; The year.
     " \\([0-9][0-9]+\\) *"

     ;; On some systems the time zone can appear after the year, too.
     time-zone-regexp

     ;; Old uucp cruft.
     "\\(remote from .*\\)?"

     "\n"))
  "Regexp matching the delimiter of messages in UNIX mail format.")

(defvar message-unsent-separator
  (concat "^ *---+ +Unsent message follows +---+ *$\\|"
	  "^ *---+ +Returned message +---+ *$\\|"
	  "^Start of returned message$\\|"
	  "^ *---+ +Original message +---+ *$\\|"
	  "^ *--+ +begin message +--+ *$\\|"
	  "^ *---+ +Original message follows +---+ *$\\|"
	  "^ *---+ +Undelivered message follows +---+ *$\\|"
	  "^------ This is a copy of the message, including all the headers. ------ *$\\|"
	  "^|? *---+ +Message text follows: +---+ *|?$")
  "A regexp that matches the separator before the text of a failed message.")

(defvar message-field-fillers
  '((To message-fill-field-address)
    (Cc message-fill-field-address)
    (From message-fill-field-address))
  "Alist of header names/filler functions.")

(defvar message-header-format-alist
  '((From)
    (Newsgroups)
    (To)
    (Cc)
    (Subject)
    (In-Reply-To)
    (Fcc)
    (Bcc)
    (Date)
    (Organization)
    (Distribution)
    (Lines)
    (Expires)
    (Message-ID)
    (References . message-shorten-references)
    (User-Agent))
  "Alist used for formatting headers.")

(defvar-local message-options nil
  "Some saved answers when sending message.")

(defvar message-send-mail-real-function nil
  "Internal send mail function.")

(defvar message-bogus-system-names "\\`localhost\\.\\|\\.local\\'"
  "The regexp of bogus system names.")

(defvar message-encoded-mail-cache nil
  "After sending a message, the encoded version is cached in this variable.")

(autoload 'gnus-alive-p "gnus-util")
(autoload 'gnus-delay-article "gnus-delay")
(autoload 'gnus-extract-address-components "gnus-util")
(autoload 'gnus-find-method-for-group "gnus")
(autoload 'gnus-get-buffer-create "gnus")
(autoload 'gnus-group-name-charset "gnus-group")
(autoload 'gnus-group-name-decode "gnus-group")
(autoload 'gnus-groups-from-server "gnus")
(autoload 'gnus-open-server "gnus-int")
(autoload 'gnus-output-to-mail "gnus-util")
(autoload 'gnus-output-to-rmail "gnus-rmail")
(autoload 'gnus-request-post "gnus-int")
(autoload 'gnus-server-string "gnus")
(autoload 'message-setup-toolbar "messagexmas")
(autoload 'mh-new-draft-name "mh-comp")
(autoload 'mh-send-letter "mh-comp")
(autoload 'nndraft-request-associate-buffer "nndraft")
(autoload 'nndraft-request-expire-articles "nndraft")
(autoload 'nnvirtual-find-group-art "nnvirtual")
(autoload 'rmail-msg-is-pruned "rmail")
(autoload 'rmail-output "rmailout")

(defun message-kill-all-overlays ()
  (mapcar #'delete-overlay (overlays-in (point-min) (point-max))))



;;;
;;; Utility functions.
;;;

(defmacro message-y-or-n-p (question show &rest text)
  "Ask QUESTION, displaying remaining args in a temporary buffer if SHOW."
  `(message-talkative-question 'y-or-n-p ,question ,show ,@text))

(defsubst message-delete-line (&optional n)
  "Delete the current line (and the next N lines)."
  (declare (obsolete delete-line "29.1"))
  (delete-region (progn (beginning-of-line) (point))
		 (progn (forward-line (or n 1)) (point))))

(defun message-mark-active-p ()
  "Non-nil means the mark and region are currently active in this buffer."
  (declare (obsolete mark-active "29.1"))
  mark-active)

(defun message-unquote-tokens (elems)
  "Remove double quotes (\") from strings in list ELEMS."
  (mapcar (lambda (item)
	    (while (string-match "^\\(.*\\)\"\\(.*\\)$" item)
	      (setq item (concat (match-string 1 item)
				 (match-string 2 item))))
	    item)
	  elems))

(defun message-tokenize-header (header &optional separator)
  "Split HEADER into a list of header elements.
SEPARATOR is a string of characters to be used as separators.  \",\"
is used by default."
  (if (not header)
      nil
    (let ((regexp (format "[%s]+" (or separator ",")))
	  (first t)
	  beg quoted elems paren)
      (with-temp-buffer
	(mm-enable-multibyte)
	(setq beg (point-min))
	(insert header)
	(goto-char (point-min))
	(while (not (eobp))
	  (if first
	      (setq first nil)
	    (forward-char 1))
	  (cond ((and (> (point) beg)
		      (or (eobp)
			  (and (looking-at regexp)
			       (not quoted)
			       (not paren))))
		 (push (buffer-substring beg (point)) elems)
		 (setq beg (match-end 0)))
		((eq (char-after) ?\")
		 (setq quoted (not quoted)))
		((and (eq (char-after) ?\()
		      (not quoted))
		 (setq paren t))
		((and (eq (char-after) ?\))
		      (not quoted))
		 (setq paren nil))))
	(nreverse elems)))))

(autoload 'nnheader-insert-file-contents "nnheader")

(defun message-mail-file-mbox-p (file)
  "Say whether FILE looks like a Unix mbox file."
  (when (and (file-exists-p file)
	     (file-readable-p file)
	     (file-regular-p file))
    (with-temp-buffer
      (nnheader-insert-file-contents file)
      (goto-char (point-min))
      (looking-at message-unix-mail-delimiter))))

(defun message-fetch-field (header &optional first)
  "Return the value of the header field named HEADER.
Continuation lines are folded (i.e., newlines are removed).
Surrounding whitespace is also removed.

By default, if there's more than one header field named HEADER,
all the values are returned as one concatenated string, and
values are comma-separated.

If FIRST is non-nil, only the first value is returned.

The buffer is expected to be narrowed to just the header of the message;
see `message-narrow-to-headers-or-head'."
  (let* ((value (mail-fetch-field header nil (not first))))
    (when value
      (while (string-match "\n[\t ]+" value)
	(setq value (replace-match " " t t value)))
      ;; If the initial or final line is blank (just a newline), then
      ;; we have initial or trailing white space; remove it.
      (string-trim value))))

(defun message-field-value (header &optional first)
  "The same as `message-fetch-field', only narrow to the headers first."
  (save-excursion
    (save-restriction
      (message-narrow-to-headers-or-head)
      (message-fetch-field header first))))

(defun message-narrow-to-field ()
  "Narrow the buffer to the header on the current line."
  (beginning-of-line)
  (while (looking-at "[ \t]")
    (forward-line -1))
  (narrow-to-region
   (point)
   (progn
     (forward-line 1)
     (if (re-search-forward "^[^ \n\t]" nil t)
         (line-beginning-position)
       (point-max))))
  (goto-char (point-min)))

(defun message-add-header (&rest headers)
  "Add the HEADERS to the message header, skipping those already present."
  (while headers
    (let (hclean)
      (unless (string-match "^\\([^:]+\\):[ \t]*[^ \t]" (car headers))
	(error "Invalid header `%s'" (car headers)))
      (setq hclean (match-string 1 (car headers)))
      (save-restriction
	(message-narrow-to-headers)
	(unless (re-search-forward (concat "^" (regexp-quote hclean) ":") nil t)
	  (goto-char (point-max))
	  (if (string-match "\n$" (car headers))
	      (insert (car headers))
	    (insert (car headers) ?\n)))))
    (setq headers (cdr headers))))

(defmacro message-with-reply-buffer (&rest forms)
  "Evaluate FORMS in the reply buffer, if it exists."
  (declare (indent 0) (debug t))
  `(when (buffer-live-p message-reply-buffer)
     (with-current-buffer message-reply-buffer
       ,@forms)))

(defun message-fetch-reply-field (header)
  "Fetch field HEADER from the message we're replying to."
  (message-with-reply-buffer
    (save-restriction
      (mail-narrow-to-head)
      (message-fetch-field header))))

(defun message-strip-list-identifiers (subject)
  "Remove list identifiers in `gnus-list-identifiers' from string SUBJECT."
  (require 'gnus-sum)			; for gnus-list-identifiers
  (let ((regexp (if (stringp gnus-list-identifiers)
		    gnus-list-identifiers
		  (mapconcat #'identity gnus-list-identifiers " *\\|"))))
    (if (and (not (equal regexp ""))
             (string-match (concat "\\(\\(\\(Re: +\\)?\\(" regexp
                                   " *\\)\\)+\\(Re: +\\)?\\)")
                           subject))
	(concat (substring subject 0 (match-beginning 1))
		(or (match-string 3 subject)
		    (match-string 5 subject))
		(substring subject
			   (match-end 1)))
      subject)))

(defun message-strip-subject-re (subject)
  "Remove \"Re:\" from subject lines in string SUBJECT.
This uses `mail-re-regexps', matching is done case-insensitively."
  (let ((case-fold-search t))
    (if (string-match message-subject-re-regexp subject)
        (substring subject (match-end 0))
      subject)))

(defcustom message-replacement-char "."
  "Replacement character used instead of unprintable or not decodable chars."
  :group 'message-various
  :version "22.1" ;; Gnus 5.10.9
  :type '(choice string
		 (const ".")
		 (const "?")))

;; FIXME: We also should call `message-strip-subject-encoded-words'
;; when forwarding.  Probably in `message-make-forward-subject' and
;; `message-forward-make-body'.

(defun message-strip-subject-encoded-words (subject)
  "Fix non-decodable words in SUBJECT."
  ;; Cf. `gnus-simplify-subject-fully'.
  (let* ((case-fold-search t)
	 (replacement-chars (format "[%s%s%s]"
				    message-replacement-char
				    message-replacement-char
				    message-replacement-char))
	 (enc-word-re "=\\?\\([^?]+\\)\\?\\([QB]\\)\\?\\([^?]+\\)\\(\\?=\\)")
	 cs-string
	 (have-marker
	  (with-temp-buffer
	    (insert subject)
	    (goto-char (point-min))
	    (when (re-search-forward enc-word-re nil t)
	      (setq cs-string (match-string 1)))))
	 cs-coding q-or-b word-beg word-end)
    (if (or (not have-marker) ;; No encoded word found...
	    ;; ... or double encoding was correct:
	    (and (stringp cs-string)
		 (setq cs-string (downcase cs-string))
		 (mm-coding-system-p (intern cs-string))
		 (not (prog1
			  (y-or-n-p
			   (format "\
Decoded Subject \"%s\"
contains a valid encoded word.  Decode again? "
				   subject))
			(setq cs-coding (intern cs-string))))))
	subject
      (with-temp-buffer
	(insert subject)
	(goto-char (point-min))
	(while (re-search-forward enc-word-re nil t)
	  (setq cs-string (downcase (match-string 1))
		q-or-b    (match-string 2)
		word-beg (match-beginning 0)
		word-end (match-end 0))
	  (setq cs-coding
		(if (mm-coding-system-p (intern cs-string))
		    (setq cs-coding (intern cs-string))
		  nil))
	  ;; No double encoded subject? => bogus charset.
	  (unless cs-coding
	    (setq cs-coding
		  (read-coding-system
		   (format-message "\
Decoded Subject \"%s\"
contains an encoded word.  The charset `%s' is unknown or invalid.
Hit RET to replace non-decodable characters with \"%s\" or enter replacement
charset: "
			   subject cs-string message-replacement-char)))
	    (if cs-coding
		(replace-match (concat "=?" (symbol-name cs-coding)
				       "?\\2?\\3\\4\\5"))
	      (save-excursion
		(goto-char word-beg)
		(re-search-forward "=\\?\\([^?]+\\)\\?\\([QB]\\)\\?" word-end t)
		(replace-match "")
		;; QP or base64
		(if (string-match "\\`Q\\'" q-or-b)
		    ;; QP
		    (progn
		      (message "Replacing non-decodable characters with \"%s\"."
			       message-replacement-char)
		      (while (re-search-forward "\\(=[A-F0-9][A-F0-9]\\)+"
						word-end t)
			(replace-match message-replacement-char)))
		  ;; base64
		  (message "Replacing non-decodable characters with \"%s\"."
			   replacement-chars)
		  (re-search-forward "[^?]+" word-end t)
		  (replace-match replacement-chars))
		(re-search-forward "\\?=")
		(replace-match "")))))
	(rfc2047-decode-region (point-min) (point-max))
	(buffer-string)))))

;;; Start of functions adopted from `message-utils.el'.

(defun message-strip-subject-trailing-was (subject)
  "Remove trailing \"(was: <old subject>)\" from SUBJECT lines.
Leading \"Re: \" is not stripped by this function.  Use the function
`message-strip-subject-re' for this."
  (or
   (let ((query message-subject-trailing-was-query) new)
     (and query
          (string-match (if (eq query 'ask)
                            message-subject-trailing-was-ask-regexp
                          message-subject-trailing-was-regexp)
                        subject)
          (setq new (substring subject 0 (match-beginning 0)))
          (or (not (eq query 'ask))
              (message-y-or-n-p
               "Strip `(was: <old subject>)' in subject? " t
               (concat
                "Strip `(was: <old subject>)' in subject "
                "and use the new one instead?\n\n"
                "Current subject is:   \"" subject "\"\n\n"
                "New subject would be: \"" new "\"\n\n"
                "See the variable `message-subject-trailing-was-query' "
                "to get rid of this query.")))
          new))
   subject))

;;; Suggested by Jonas Steverud  @  www.dtek.chalmers.se/~d4jonas/

(defun message-change-subject (new-subject)
  "Ask for NEW-SUBJECT header, append (was: <Old Subject>)."
  (interactive
   (list
    (read-from-minibuffer "New subject: "))
   message-mode)
  (cond ((and (not (or (null new-subject) ; new subject not empty
		       (zerop (string-width new-subject))
		       (string-match "^[ \t]*$" new-subject))))
	 (save-excursion
	   (let ((old-subject
		  (save-restriction
		    (message-narrow-to-headers)
		    (message-fetch-field "Subject"))))
	     (cond ((not old-subject)
		    (error "No current subject"))
		   ((not (string-match
			  (concat "^[ \t]*"
				  (regexp-quote new-subject)
				  "[ \t]*$")
			  old-subject))  ; yes, it really is a new subject
		    ;; delete eventual Re: prefix
		    (setq old-subject
			  (message-strip-subject-re old-subject))
		    (message-goto-subject)
		    (delete-line)
		    (insert (concat "Subject: "
				    new-subject
				    " (was: "
				    old-subject ")\n")))))))))

(defun message-mark-inserted-region (beg end &optional verbatim)
  "Mark some region in the current article with enclosing tags.
See `message-mark-insert-begin' and `message-mark-insert-end'.
If VERBATIM, use slrn style verbatim marks (\"#v+\" and \"#v-\")."
  (interactive "r\nP" message-mode)
  (save-excursion
    ;; add to the end of the region first, otherwise end would be invalid
    (goto-char end)
    (unless (bolp)
      (insert "\n"))
    (insert (if verbatim "#v-\n" message-mark-insert-end))
    (goto-char beg)
    (insert (if verbatim "#v+\n" message-mark-insert-begin))))

(defun message-mark-insert-file (file &optional verbatim)
  "Insert FILE at point, marking it with enclosing tags.
See `message-mark-insert-begin' and `message-mark-insert-end'.
If VERBATIM, use slrn style verbatim marks (\"#v+\" and \"#v-\")."
  (interactive "fFile to insert: \nP" message-mode)
    ;; reverse insertion to get correct result.
  (let ((p (point)))
    (insert (if verbatim "#v-\n" message-mark-insert-end))
    (goto-char p)
    (insert-file-contents file)
    (goto-char p)
    (insert (if verbatim "#v+\n" message-mark-insert-begin))))

(defun message-add-archive-header ()
  "Insert \"X-No-Archive: Yes\" in the header and a note in the body.
The note can be customized using `message-archive-note'.  When called with a
prefix argument, ask for a text to insert.  If you don't want the note in the
body, set  `message-archive-note' to nil."
  (interactive nil message-mode)
  (if current-prefix-arg
      (setq message-archive-note
	    (read-from-minibuffer "Reason for No-Archive: "
				  (cons message-archive-note 0))))
    (save-excursion
      (if (message-goto-signature)
	  (re-search-backward message-signature-separator))
      (when message-archive-note
	(insert message-archive-note)
	(newline))
      (message-add-header message-archive-header)
      (message-sort-headers)))

(defun message-cross-post-followup-to-header (target-group)
  "Mangles FollowUp-To and Newsgroups header to point to TARGET-GROUP.
With prefix-argument just set Follow-Up, don't cross-post."
  (interactive
   (list				; Completion based on Gnus
    (replace-regexp-in-string
     "\\`.*:" ""
     (completing-read "Followup To: "
		      (if (boundp 'gnus-newsrc-alist)
			  gnus-newsrc-alist)
		      nil nil '("poster" . 0)
		      (if (boundp 'gnus-group-history)
			  'gnus-group-history))))
   message-mode)
  (message-remove-header "Follow[Uu]p-[Tt]o" t)
  (message-goto-newsgroups)
  (beginning-of-line)
  ;; if we already did a crosspost before, kill old target
  (if (and message-cross-post-old-target
	   (re-search-forward
	    (regexp-quote (concat "," message-cross-post-old-target))
	    nil t))
      (replace-match ""))
  ;; unless (followup is to poster or user explicitly asked not
  ;; to cross-post, or target-group is already in Newsgroups)
  ;; add target-group to Newsgroups line.
  (cond ((and (or
	       ;; def: cross-post, req:no
	       (and message-cross-post-default (not current-prefix-arg))
	       ;; def: no-cross-post, req:yes
	       (and (not message-cross-post-default) current-prefix-arg))
	      (not (string-match "poster" target-group))
	      (not (string-match (regexp-quote target-group)
				 (message-fetch-field "Newsgroups"))))
	 (end-of-line)
	 (insert (concat "," target-group))))
  (end-of-line) ; ensure Followup: comes after Newsgroups:
  ;; unless new followup would be identical to Newsgroups line
  ;; make a new Followup-To line
  (if (not (string-match (concat "^[ \t]*"
				 target-group
				 "[ \t]*$")
			 (message-fetch-field "Newsgroups")))
      (insert (concat "\nFollowup-To: " target-group)))
  (setq message-cross-post-old-target target-group))

(defun message-cross-post-insert-note (target-group cross-post in-old
						    _old-groups)
  "Insert a in message body note about a set Followup or Crosspost.
If there have been previous notes, delete them.  TARGET-GROUP specifies the
group to Followup-To.  When CROSS-POST is t, insert note about
crossposting.  IN-OLD specifies whether TARGET-GROUP is a member of
OLD-GROUPS.  OLD-GROUPS lists the old-groups the posting would have
been made to before the user asked for a Crosspost."
  ;; start scanning body for previous uses
  (message-goto-signature)
  (let ((head (re-search-backward
	       (concat "^" mail-header-separator)
	       nil t))) ; just search in body
    (message-goto-signature)
    (while (re-search-backward
	    (concat "^" (regexp-quote message-cross-post-note) ".*")
	    head t)
      (delete-line))
    (message-goto-signature)
    (while (re-search-backward
	    (concat "^" (regexp-quote message-followup-to-note) ".*")
	    head t)
      (delete-line))
    ;; insert new note
    (if (message-goto-signature)
	(re-search-backward message-signature-separator))
    (if (or in-old
	    (not cross-post)
	    (string-match "^[ \t]*poster[ \t]*$" target-group))
	(insert (concat message-followup-to-note target-group "\n"))
      (insert (concat message-cross-post-note target-group "\n")))))

(defun message-cross-post-followup-to (target-group)
  "Crossposts message and set Followup-To to TARGET-GROUP.
With prefix-argument just set Follow-Up, don't cross-post."
  (interactive
   (list				; Completion based on Gnus
    (replace-regexp-in-string
     "\\`.*:" ""
     (completing-read "Followup To: "
		      (if (boundp 'gnus-newsrc-alist)
			  gnus-newsrc-alist)
		      nil nil '("poster" . 0)
		      (if (boundp 'gnus-group-history)
			  'gnus-group-history))))
   message-mode)
  (when (fboundp 'gnus-group-real-name)
    (setq target-group (gnus-group-real-name target-group)))
  (cond ((not (or (null target-group) ; new subject not empty
		  (zerop (string-width target-group))
		  (string-match "^[ \t]*$" target-group)))
	 (save-excursion
	   (let* ((old-groups (message-fetch-field "Newsgroups"))
		  (in-old (string-match
			   (regexp-quote target-group)
			   (or old-groups ""))))
	     ;; check whether target exactly matches old Newsgroups
	     (cond ((not old-groups)
		    (error "No current newsgroup"))
		   ((or (not in-old)
			(not (string-match
			      (concat "^[ \t]*"
				      (regexp-quote target-group)
				      "[ \t]*$")
			      old-groups)))
		    ;; yes, Newsgroups line must change
		    (message-cross-post-followup-to-header target-group)
		    ;; insert note whether we do cross-post or followup-to
		    (funcall message-cross-post-note-function
			     target-group
			     (if (or (and message-cross-post-default
					  (not current-prefix-arg))
				     (and (not message-cross-post-default)
					  current-prefix-arg)) t)
			     in-old old-groups))))))))

;;; Reduce To: to Cc: or Bcc: header

(defun message-reduce-to-to-cc ()
 "Replace contents of To: header with contents of Cc: or Bcc: header."
 (interactive nil message-mode)
 (let ((cc-content
	(save-restriction (message-narrow-to-headers)
			  (message-fetch-field "cc")))
       (bcc nil))
   (if (and (not cc-content)
	    (setq cc-content
		  (save-restriction
		    (message-narrow-to-headers)
		    (message-fetch-field "bcc"))))
       (setq bcc t))
   (cond (cc-content
	  (save-excursion
	    (message-goto-to)
	    (delete-line)
	    (insert (concat "To: " cc-content "\n"))
	    (save-restriction
	      (message-narrow-to-headers)
	      (message-remove-header (if bcc
					 "bcc"
				       "cc"))))))))

;;; End of functions adopted from `message-utils.el'.

(defun message-remove-header (header &optional is-regexp first reverse)
  "Remove HEADER in the narrowed buffer.
If IS-REGEXP, HEADER is a regular expression.
If FIRST, only remove the first instance of the header.
If REVERSE, remove headers that doesn't match HEADER.
Return the number of headers removed."
  (goto-char (point-min))
  (let ((regexp (if is-regexp header (concat "^" (regexp-quote header) ":")))
	(number 0)
	(case-fold-search t)
	last)
    (while (and (not (eobp))
		(not last))
      (if (if reverse
	      (and (not (looking-at regexp))
		   ;; Don't remove things not looking like header.
		   (looking-at "[!-9;-~]+:"))
	    (looking-at regexp))
	  (progn
            (incf number)
	    (when first
	      (setq last t))
	    (delete-region
	     (point)
	     ;; There might be a continuation header, so we have to search
	     ;; until we find a new non-continuation line.
	     (progn
	       (forward-line 1)
	       (if (re-search-forward "^[^ \t]" nil t)
		   (goto-char (match-beginning 0))
		 (point-max)))))
	(forward-line 1)
	(if (re-search-forward "^[^ \t]" nil t)
	    (goto-char (match-beginning 0))
	  (goto-char (point-max)))))
    number))

(defun message-remove-first-header (header)
  "Remove the first instance of HEADER if there is more than one."
  (let ((count 0)
	(regexp (concat "^" (regexp-quote header) ":")))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward regexp nil t)
        (incf count)))
    (while (> count 1)
      (message-remove-header header nil t)
      (decf count))))

(defun message-narrow-to-headers ()
  "Narrow the buffer to the head of the message."
  (widen)
  (narrow-to-region
   (goto-char (point-min))
   (if (re-search-forward
	(concat "^" (regexp-quote mail-header-separator) "\n") nil t)
       (match-beginning 0)
     (point-max)))
  (goto-char (point-min)))

(defun message-narrow-to-head-1 ()
  "Like `message-narrow-to-head'.  Don't widen."
  (narrow-to-region
   (goto-char (point-min))
   (if (search-forward "\n\n" nil 1)
       (1- (point))
     (point-max)))
  (goto-char (point-min)))

;; FIXME: clarify difference: message-narrow-to-head,
;; message-narrow-to-headers-or-head, message-narrow-to-headers
(defun message-narrow-to-head ()
  "Narrow the buffer to the head of the message.
Point is left at the beginning of the narrowed-to region."
  (widen)
  (message-narrow-to-head-1))

(defun message-narrow-to-headers-or-head ()
  "Narrow the buffer to the head of the message."
  (widen)
  (narrow-to-region
   (goto-char (point-min))
   (if (re-search-forward (concat "\\(\n\\)\n\\|^\\("
				  (regexp-quote mail-header-separator)
				  "\n\\)")
			  nil t)
       (or (match-end 1) (match-beginning 2))
     (point-max)))
  (goto-char (point-min)))

(defun message-news-p ()
  "Say whether the current buffer contains a news message."
  (and (not message-this-is-mail)
       (or message-this-is-news
	   (save-excursion
	     (save-restriction
	       (message-narrow-to-headers)
	       (and (message-fetch-field "newsgroups")
		    (not (message-fetch-field "posted-to"))))))))

(defun message-mail-p ()
  "Say whether the current buffer contains a mail message."
  (and (not message-this-is-news)
       (or message-this-is-mail
	   (save-excursion
	     (save-restriction
	       (message-narrow-to-headers)
	       (or (message-fetch-field "to")
		   (message-fetch-field "cc")
		   (message-fetch-field "bcc")))))))

(defun message-subscribed-p ()
  "Say whether we need to insert a MFT header."
  (or message-subscribed-regexps
      message-subscribed-addresses
      message-subscribed-address-file
      message-subscribed-address-functions))

(defun message-next-header ()
  "Go to the beginning of the next header."
  (beginning-of-line)
  (or (eobp) (forward-char 1))
  (not (if (re-search-forward "^[^ \t]" nil t)
	   (beginning-of-line)
	 (goto-char (point-max)))))

(defun message-sort-headers-1 ()
  "Sort the buffer as headers using `message-rank' text props."
  (goto-char (point-min))
  (require 'sort)
  (sort-subr
   nil 'message-next-header
   (lambda ()
     (message-next-header)
     (unless (bobp)
       (forward-char -1)))
   (lambda ()
     (or (get-text-property (point) 'message-rank)
	 10000))))

(defun message-sort-headers ()
  "Sort headers of the current message according to `message-header-format-alist'."
  (interactive nil message-mode)
  (save-excursion
    (save-restriction
      (let ((max (1+ (length message-header-format-alist))))
	(message-narrow-to-headers)
	(while (re-search-forward "^[^ \n]+:" nil t)
	  (put-text-property
	   (match-beginning 0) (1+ (match-beginning 0))
	   'message-rank
           (- max (length
                   (memq (assq (intern (buffer-substring
					(match-beginning 0) (1- (match-end 0))))
			       message-header-format-alist)
			 message-header-format-alist))))))
      (message-sort-headers-1))))

(defun message-kill-address ()
  "Kill the address under point."
  (interactive nil message-mode)
  (let ((start (point)))
    (message-skip-to-next-address)
    (kill-region start (if (bolp) (1- (point)) (point)))))


(autoload 'Info-goto-node "info")
(defvar mml2015-use)

(defun message-info (&optional arg)
  "Display the Message manual.

Prefixed with one \\[universal-argument], display the Emacs MIME
manual.  With two \\[universal-argument]'s, display the EasyPG or
PGG manual, depending on the value of `mml2015-use'."
  (interactive "p")
  (info (format "(%s)Top"
		(cond ((eq arg 16)
		       (require 'mml2015)
		       mml2015-use)
		      ((eq arg  4) 'emacs-mime)
		      ((and (not (booleanp arg))
			    (symbolp arg))
		       arg)
		      (t
		       'message)))))

(defun message-all-recipients ()
  "Return a list of all recipients in the message, looking at TO, Cc and Bcc.

Each recipient is in the format of `mail-extract-address-components'."
  (mapcan (lambda (header)
            (let ((header-value (message-fetch-field header)))
              (and
               header-value
               (mail-extract-address-components header-value t))))
          '("To" "Cc" "Bcc")))

(defun message-all-epg-keys-available-p ()
  "Return non-nil if the pgp keyring has a public key for each recipient."
  (require 'epa)
  (let ((context (epg-make-context epa-protocol)))
    (catch 'break
      (dolist (recipient (message-all-recipients))
        (let ((recipient-email (cadr recipient)))
          (when (and recipient-email (not (epg-list-keys context recipient-email)))
            (throw 'break nil))))
      t)))

(defun message-sign-encrypt-if-all-keys-available ()
  "Add MML tag to encrypt message when there is a key for each recipient.

Consider adding this function to `message-send-hook' to
systematically send encrypted emails when possible."
  (when (message-all-epg-keys-available-p)
    (mml-secure-message-sign-encrypt)))

(defcustom message-openpgp-header nil
  "Specification for the \"OpenPGP\" header of outgoing messages.

The value must be a list of three elements, all strings:
- Key ID, in hexadecimal form;
- Key URL or ASCII armored key; and
- Protection preference, one of: \"unprotected\", \"sign\",
  \"encrypt\" or \"signencrypt\".

Each of the elements may be nil, in which case its part in the
OpenPGP header will be left out.  If all the values are nil,
or `message-openpgp-header' is itself nil, the OpenPGP header
will not be inserted."
  :type '(choice
	  (const :tag "Don't add OpenPGP header" nil)
	  (list :tag "Use OpenPGP header"
		(choice (string :tag "ID")
			(const :tag "No ID" nil))
		(choice (string :tag "Key")
			(const :tag "No Key" nil))
                (choice (const :tag "Unprotected" "unprotected")
			(const :tag "Sign" "sign")
			(const :tag "Encrypt" "encrypt")
                        (const :tag "Sign and Encrypt" "signencrypt")
                        (other :tag "None" nil))))
  :version "28.1")

(defun message-add-openpgp-header ()
  "Add OpenPGP header to point to public key.

Header will be constructed as specified in `message-openpgp-header'.

Consider adding this function to `message-header-setup-hook'"
  ;; See https://tools.ietf.org/html/draft-josefsson-openpgp-mailnews-header
  (when (and message-openpgp-header
	     (or (nth 0 message-openpgp-header)
		 (nth 1 message-openpgp-header)
		 (nth 2 message-openpgp-header)))
    (message-add-header
     (with-temp-buffer
       (insert "OpenPGP: ")
       ;; add ID
       (let (need-sep)
	 (when (nth 0 message-openpgp-header)
	   (insert "id=" (nth 0 message-openpgp-header))
	   (setq need-sep t))
	 ;; add URL
	 (when (nth 1 message-openpgp-header)
	   (when need-sep (insert "; "))
	   (insert "url=\"" (nth 1 message-openpgp-header) "\"")
	   (setq need-sep t))
	 ;; add preference
	 (when (nth 2 message-openpgp-header)
	   (when need-sep (insert "; "))
	   (insert "preference=" (nth 2 message-openpgp-header))))
       ;; insert header
       (buffer-string)))
    (message-sort-headers)))



;;;
;;; Message mode
;;;

;;; Set up keymap.

(defvar-keymap message-mode-map
  :full t :parent text-mode-map
  :doc "Message Mode keymap."
  "C-c ?" #'describe-mode

  "C-c C-f C-t" #'message-goto-to
  "C-c C-f C-o" #'message-goto-from
  "C-c C-f C-b" #'message-goto-bcc
  "C-c C-f C-w" #'message-goto-fcc
  "C-c C-f C-c" #'message-goto-cc
  "C-c C-f C-s" #'message-goto-subject
  "C-c C-f C-r" #'message-goto-reply-to
  "C-c C-f C-n" #'message-goto-newsgroups
  "C-c C-f C-d" #'message-goto-distribution
  "C-c C-f C-f" #'message-goto-followup-to
  "C-c C-f C-m" #'message-goto-mail-followup-to
  "C-c C-f C-k" #'message-goto-keywords
  "C-c C-f C-u" #'message-goto-summary
  "C-c C-f C-i" #'message-insert-or-toggle-importance
  "C-c C-f C-a" #'message-generate-unsubscribed-mail-followup-to

  ;; modify headers (and insert notes in body)
  "C-c C-f s"    #'message-change-subject
  ;;
  "C-c C-f x"    #'message-cross-post-followup-to
  ;; prefix+message-cross-post-followup-to = same without cross-post
  "C-c C-f t"    #'message-reduce-to-to-cc
  "C-c C-f a"    #'message-add-archive-header
  ;; mark inserted text
  "C-c M-m" #'message-mark-inserted-region
  "C-c M-f" #'message-mark-insert-file

  "C-c C-b" #'message-goto-body
  "C-c C-i" #'message-goto-signature

  "C-c C-t" #'message-insert-to
  "C-c C-f w" #'message-insert-wide-reply
  "C-c C-n" #'message-insert-newsgroups
  "C-c C-l" #'message-to-list-only
  "C-c C-f C-e" #'message-insert-expires
  "C-c C-u" #'message-insert-or-toggle-importance
  "C-c M-n" #'message-insert-disposition-notification-to

  "C-c C-y" #'message-yank-original
  "C-c C-M-y" #'message-yank-buffer
  "C-c C-q" #'message-fill-yanked-message
  "C-c C-w" #'message-insert-signature
  "C-c M-h" #'message-insert-headers
  "C-c C-r" #'message-caesar-buffer-body
  "C-c C-o" #'message-sort-headers
  "C-c M-r" #'message-rename-buffer

  "C-c C-c" #'message-send-and-exit
  "C-c C-s" #'message-send
  "C-c C-k" #'message-kill-buffer
  "C-c C-d" #'message-dont-send
  "C-c C-j" #'gnus-delay-article

  "C-c M-k" #'message-kill-address
  "C-c C-e" #'message-elide-region
  "C-c C-v" #'message-delete-not-region
  "C-c C-z" #'message-kill-to-signature
  "M-RET" #'message-newline-and-reformat
  "<remap> <split-line>"  #'message-split-line

  "C-c C-a" #'mml-attach-file
  "C-c C-p" #'message-insert-screenshot

  "C-a" #'message-beginning-of-line
  "TAB" #'message-tab

  "M-n" #'message-display-abbrev)

(easy-menu-define message-mode-menu message-mode-map
  "Message Menu."
  '("Message"
    ["Yank Original" message-yank-original
     :active message-reply-buffer]
    ["Fill Yanked Message" message-fill-yanked-message]
    ["Insert Signature" message-insert-signature]
    ["Caesar (rot13) Message" message-caesar-buffer-body]
    ["Caesar (rot13) Region" message-caesar-region
     :active mark-active]
    ["Elide Region" message-elide-region
     :active mark-active
     :help "Replace text in region with an ellipsis"]
    ["Delete Outside Region" message-delete-not-region
     :active mark-active
     :help "Delete all quoted text outside region"]
    ["Kill To Signature" message-kill-to-signature]
    ["Newline and Reformat" message-newline-and-reformat]
    ["Rename buffer" message-rename-buffer]
    ["Spellcheck" ispell-message
     :help "Spellcheck this message"]
    "----"
    ["Insert Region Marked" message-mark-inserted-region
     :active mark-active
     :help "Mark region with enclosing tags"]
    ["Insert File Marked..." message-mark-insert-file
     :help "Insert file at point marked with enclosing tags"]
    ["Attach File..." mml-attach-file]
    ["Insert Screenshot" message-insert-screenshot]
    "----"
    ["Send Message" message-send-and-exit
     :help "Send this message"]
    ["Postpone Message" message-dont-send
     :help "File this draft message and exit"]
    ["Send at Specific Time..." gnus-delay-article
     :help "Ask, then arrange to send message at that time"]
    ["Kill Message" message-kill-buffer
     :help "Delete this message without sending"]
    "----"
    ["Message manual" message-info
     :help "Display the Message manual"]))

(easy-menu-define message-mode-field-menu message-mode-map
  "Field Menu."
  '("Field"
    ["To" message-goto-to]
    ["From" message-goto-from]
    ["Subject" message-goto-subject]
    ["Change subject..." message-change-subject]
    ["Cc" message-goto-cc]
    ["Bcc" message-goto-bcc]
    ["Fcc" message-goto-fcc]
    ["Reply-To" message-goto-reply-to]
    ["Flag As Important" message-insert-importance-high
     :help "Mark this message as important"]
    ["Flag As Unimportant" message-insert-importance-low
     :help "Mark this message as unimportant"]
    ["Request Receipt" message-insert-disposition-notification-to
     :help "Request a receipt notification"]
    "----"
    ;; (typical) news stuff
    ["Summary" message-goto-summary]
    ["Keywords" message-goto-keywords]
    ["Newsgroups" message-goto-newsgroups]
    ["Fetch Newsgroups" message-insert-newsgroups]
    ["Followup-To" message-goto-followup-to]
    ["Crosspost / Followup-To..." message-cross-post-followup-to]
    ["Distribution" message-goto-distribution]
    ["Expires" message-insert-expires]
    ["X-No-Archive" message-add-archive-header]
    "----"
    ;; (typical) mailing-lists stuff
    ["Fetch To" message-insert-to
     :help "Insert a To header that points to the author."]
    ["Fetch To and Cc" message-insert-wide-reply
     :help "Insert To and Cc headers as if you were doing a wide reply."]
    "----"
    ["Send to list only" message-to-list-only]
    ["Mail-Followup-To" message-goto-mail-followup-to]
    ["Unsubscribed list post" message-generate-unsubscribed-mail-followup-to
     :help "Insert a reasonable `Mail-Followup-To:' header."]
    ["Reduce To: to Cc:" message-reduce-to-to-cc]
    "----"
    ["Sort Headers" message-sort-headers]
    ["Encode non-ASCII domain names" message-idna-to-ascii-rhs]
    ;; We hide `message-hidden-headers' by narrowing the buffer.
    ["Show Hidden Headers" message-widen-and-recenter]
    ["Goto Body" message-goto-body]
    ["Goto Signature" message-goto-signature]))

(defvar message-tool-bar-map nil)

(defvar facemenu-add-face-function)
(defvar facemenu-remove-face-function)

;;; Forbidden properties
;;
;; We use `after-change-functions' to keep special text properties
;; that interfere with the normal function of message mode out of the
;; buffer.

(defcustom message-strip-special-text-properties t
  "Strip special properties from the message buffer.

Emacs has a number of special text properties which can break message
composing in various ways.  If this option is set, message will strip
these properties from the message composition buffer.  However, some
packages requires these properties to be present in order to work.
If you use one of these packages, turn this option off, and hope the
message composition doesn't break too bad."
  :version "22.1"
  :group 'message-various
  :link '(custom-manual "(message)Various Message Variables")
  :type 'boolean)

(defvar message-forbidden-properties
  ;; No reason this should be clutter up customize.  We make it a
  ;; property list (rather than a list of property symbols), to be
  ;; directly useful for `remove-text-properties'.
  '(field nil read-only nil invisible nil intangible nil
	  mouse-face nil modification-hooks nil insert-in-front-hooks nil
	  insert-behind-hooks nil point-entered nil point-left nil)
  ;; Other special properties:
  ;; category, face, display: probably doesn't do any harm.
  ;; fontified: is used by font-lock.
  ;; syntax-table, local-map: I dunno.
  "Property list of with properties forbidden in message buffers.
The values of the properties are ignored, only the property names are used.")

(defun message-tamago-not-in-use-p (pos)
  "Return t when tamago version 4 is not in use at the cursor position.
Tamago version 4 is a popular input method for writing Japanese text.
It uses the properties `intangible', `invisible', `modification-hooks'
and `read-only' when translating ascii or kana text to kanji text.
These properties are essential to work, so we should never strip them."
  (not (and (boundp 'egg-modefull-mode)
	    (symbol-value 'egg-modefull-mode)
	    (or (memq (get-text-property pos 'intangible)
		      '(its-part-1 its-part-2))
		(get-text-property pos 'egg-end)
		(get-text-property pos 'egg-lang)
		(get-text-property pos 'egg-start)))))

(defsubst message-mail-alias-type-p (type)
  (if (atom message-mail-alias-type)
      (eq message-mail-alias-type type)
    (memq type message-mail-alias-type)))

(defun message-strip-forbidden-properties (begin end &optional _old-length)
  "Strip forbidden properties between BEGIN and END, ignoring the third arg.
This function is intended to be called from `after-change-functions'.
See also `message-forbidden-properties'."
  (when (and (message-mail-alias-type-p 'ecomplete)
	     (memq this-command message-self-insert-commands))
    (message-display-abbrev))
  (when (and message-strip-special-text-properties
	     (message-tamago-not-in-use-p begin))
    (let ((inhibit-read-only t))
      (remove-text-properties begin end message-forbidden-properties))))

(defvar message-smileys '(":-)" ":)"
                          ":-(" ":("
                          ";-)" ";)")
  "A list of recognized smiley faces in `message-mode'.")

(defun message--syntax-propertize (beg end)
  "Syntax-propertize certain message text specially."
  (with-syntax-table message-mode-syntax-table
    (let ((citation-regexp (concat "^" message-cite-prefix-regexp ".*$"))
          (smiley-regexp (regexp-opt message-smileys)))
      (goto-char beg)
      (while (search-forward-regexp citation-regexp
                                    end 'noerror)
	(let ((start (match-beginning 0))
              (end (match-end 0)))
          (add-text-properties start (1+ start)
                               `(syntax-table ,(string-to-syntax "<")))
          (add-text-properties end (min (1+ end) (point-max))
                               `(syntax-table ,(string-to-syntax ">")))))
      (goto-char beg)
      (while (search-forward-regexp smiley-regexp
				    end 'noerror)
	(add-text-properties (match-beginning 0) (match-end 0)
                             `(syntax-table ,(string-to-syntax ".")))))))

;;;###autoload
(define-derived-mode message-mode text-mode "Message"
  "Major mode for editing mail and news to be sent.
Like `text-mode', but with these additional commands:

\\{message-mode-map}"
  (setq-local message-reply-buffer nil)
  (setq-local message-inserted-headers nil)
  (setq-local message-send-actions nil)
  (setq-local message-return-action nil)
  (setq-local message-exit-actions nil)
  (setq-local message-kill-actions nil)
  (setq-local message-postpone-actions nil)
  (setq-local message-draft-article nil)
  (setq buffer-offer-save t)
  (setq-local facemenu-add-face-function
       (lambda (face end)
	 (let ((face-fun (cdr (assq face message-face-alist))))
	   (if face-fun
	       (funcall face-fun (point) end)
	     (error "Face %s not configured for %s mode" face mode-name)))
	 ""))
  (setq-local facemenu-remove-face-function t)
  (setq-local message-reply-headers nil)
  (make-local-variable 'message-newsreader)
  (make-local-variable 'message-mailer)
  (make-local-variable 'message-post-method)
  (setq-local message-sent-message-via nil)
  (setq-local message-checksum nil)
  (setq-local message-mime-part 0)
  (message-setup-fill-variables)
  (yank-media-handler "image/.*" #'message--yank-media-image-handler)
  (when message-fill-column
    (setq fill-column message-fill-column)
    (turn-on-auto-fill))
  ;; Allow using comment commands to add/remove quoting.
  ;; (setq-local comment-start message-yank-prefix)
  (when message-yank-prefix
    (setq-local comment-start message-yank-prefix)
    (setq-local comment-start-skip
                (concat "^" (regexp-quote message-yank-prefix) "[ \t]*")))
  (setq-local font-lock-defaults '(message-font-lock-keywords t))
  (if (boundp 'tool-bar-map)
      (setq-local tool-bar-map (message-make-tool-bar)))
  ;; Mmmm... Forbidden properties...
  (add-hook 'after-change-functions #'message-strip-forbidden-properties
	    nil 'local)
  ;; Allow mail alias things.
  (cond
   ((message-mail-alias-type-p 'abbrev)
    (mail-abbrevs-setup))
   ((message-mail-alias-type-p 'ecomplete)
    (ecomplete-setup)))
  (add-hook 'completion-at-point-functions #'message-completion-function nil t)
  (unless buffer-file-name
    (message-set-auto-save-file-name))
  (unless (buffer-base-buffer)
    ;; Don't enable multibyte on an indirect buffer.  Maybe enabling
    ;; multibyte is not necessary at all. -- zsh
    (mm-enable-multibyte))
  (setq-local indent-tabs-mode nil) ; No tabs for indentation.
  (mml-mode)
  ;; Syntactic fontification. Helps `show-paren-mode',
  ;; `electric-pair-mode', and C-M-* navigation by syntactically
  ;; excluding citations and other artifacts.
  ;;
  (setq-local syntax-propertize-function #'message--syntax-propertize)
  (setq-local parse-sexp-ignore-comments t)
  (setq-local message-encoded-mail-cache nil)
  (setq-local image-crop-buffer-text-function #'message--update-image-crop))

(defun message-setup-fill-variables ()
  "Setup message fill variables."
  (setq-local fill-paragraph-function #'message-fill-paragraph)
  (let ((quote-prefix-regexp
	 ;; User should change message-cite-prefix-regexp if
	 ;; message-yank-prefix is set to an abnormal value.
	 (concat "\\(" message-cite-prefix-regexp "\\)[ \t]*")))
    (setq-local paragraph-start
                (concat
                 (regexp-quote mail-header-separator) "$\\|"
                 "[ \t]*$\\|"			; blank lines
                 "-- $\\|"			; signature delimiter
                 "---+$\\|"		   ; delimiters for forwarded messages
                 page-delimiter "$\\|"	; spoiler warnings
                 ".*wrote:$\\|"		; attribution lines
                 quote-prefix-regexp "$\\|"	; empty lines in quoted text
                                        ; mml tags
                 "<#!*/?\\(multipart\\|part\\|external\\|mml\\|secure\\)"))
    (setq-local paragraph-separate paragraph-start)
    (setq-local adaptive-fill-regexp
                (concat quote-prefix-regexp "\\|" adaptive-fill-regexp))
    (setq-local adaptive-fill-first-line-regexp
                (concat quote-prefix-regexp "\\|"
                        adaptive-fill-first-line-regexp)))
  (setq-local auto-fill-inhibit-regexp nil)
  (setq-local normal-auto-fill-function #'message-do-auto-fill))



;;;
;;; Message mode commands
;;;

;;; Movement commands

(defun message-goto-to ()
  "Move point to the To header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "To"))

(defun message-goto-from ()
  "Move point to the From header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "From"))

(defun message-goto-subject ()
  "Move point to the Subject header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Subject"))

(defun message-goto-cc ()
  "Move point to the Cc header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Cc" "To"))

(defun message-goto-bcc ()
  "Move point to the Bcc  header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Bcc" "Cc" "To"))

(defun message-goto-fcc ()
  "Move point to the Fcc header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Fcc" "To" "Newsgroups"))

(defun message-goto-reply-to ()
  "Move point to the Reply-To header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Reply-To" "Subject"))

(defun message-goto-newsgroups ()
  "Move point to the Newsgroups header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Newsgroups"))

(defun message-goto-distribution ()
  "Move point to the Distribution header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Distribution"))

(defun message-goto-followup-to ()
  "Move point to the Followup-To header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Followup-To" "Newsgroups"))

(defun message-goto-mail-followup-to ()
  "Move point to the Mail-Followup-To header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Mail-Followup-To" "To"))

(defun message-goto-keywords ()
  "Move point to the Keywords header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Keywords" "Subject"))

(defun message-goto-summary ()
  "Move point to the Summary header or insert an empty one."
  (interactive nil message-mode)
  (push-mark)
  (message-position-on-field "Summary" "Subject"))

(define-obsolete-function-alias 'message-goto-body-1 #'message-goto-body "27.1")
(defun message-goto-body (&optional interactive)
  "Move point to the beginning of the message body.
Returns point."
  (interactive "p" message-mode)
  (when interactive
    (when (looking-at "[ \t]*\n")
    (expand-abbrev))
    (push-mark))
  (goto-char (point-min))
  (or (search-forward (concat "\n" mail-header-separator "\n") nil t)
      ;; If the message is mangled, find the end of the headers the
      ;; hard way.
      (progn
	;; Skip past all headers and continuation lines.
	(while (looking-at "[^\t\n :]+:\\|[\t ]+[^\t\n ]")
	  (forward-line 1))
	;; We're now at the first empty line, so perhaps move past it.
	(when (and (eolp)
		   (not (eobp)))
	  (forward-line 1))
	(point))))

(defun message-in-body-p ()
  "Return t if point is in the message body."
  (>= (point)
      (save-excursion
	(message-goto-body))))

(defun message-goto-eoh (&optional interactive)
  "Move point to the end of the headers."
  (interactive "p" message-mode)
  (message-goto-body interactive)
  (forward-line -1))

(defun message-goto-signature ()
  "Move point to the beginning of the message signature.
If there is no signature in the article, go to the end and
return nil."
  (interactive nil message-mode)
  (push-mark)
  (goto-char (point-min))
  (if (re-search-forward message-signature-separator nil t)
      (forward-line 1)
    (goto-char (point-max))
    nil))

(defun message-generate-unsubscribed-mail-followup-to (&optional include-cc)
  "Insert a reasonable MFT header in a post to an unsubscribed list.
When making original posts to a mailing list you are not subscribed to,
you have to type in a MFT header by hand.  The contents, usually, are
the addresses of the list and your own address.  This function inserts
such a header automatically.  It fetches the contents of the To: header
in the current mail buffer, and appends the current `user-mail-address'.

If the optional argument INCLUDE-CC is non-nil, the addresses in the
Cc: header are also put into the MFT."

  (interactive "P" message-mode)
  (let* (cc tos)
    (save-restriction
      (message-narrow-to-headers)
      (message-remove-header "Mail-Followup-To")
      (setq cc (and include-cc (message-fetch-field "Cc")))
      (setq tos (if cc
		    (concat (message-fetch-field "To") "," cc)
		  (message-fetch-field "To"))))
    (message-goto-mail-followup-to)
    (insert (concat tos ", " user-mail-address))))



(defun message-insert-to (&optional force)
  "Insert a To header that points to the author of the article being replied to.
If the original author requested not to be sent mail, don't insert unless the
prefix FORCE is given."
  (interactive "P" message-mode)
  (let* ((mct (message-fetch-reply-field "mail-copies-to"))
	 (dont (and mct (or (equal (downcase mct) "never")
			    (equal (downcase mct) "nobody"))))
	 (to (or (message-fetch-reply-field "mail-reply-to")
		 (message-fetch-reply-field "reply-to")
		 (message-fetch-reply-field "from"))))
    (when (and dont to)
      (message
       (if force
	   "Ignoring the user request not to have copies sent via mail"
	 "Complying with the user request not to have copies sent via mail")))
    (when (and force (not to))
      (error "No mail address in the article"))
    (when (and to (or force (not dont)))
      (message-carefully-insert-headers (list (cons 'To to))))))

(defun message-insert-wide-reply ()
  "Insert To and Cc headers as if you were doing a wide reply."
  (interactive nil message-mode)
  (let ((headers (message-with-reply-buffer
		   (message-get-reply-headers t))))
    (message-carefully-insert-headers headers)))

(defcustom message-header-synonyms
  '((To Cc Bcc)
    (Original-To))
  "List of lists of header synonyms.
E.g., if this list contains a member list with elements `Cc' and `To',
then `message-carefully-insert-headers' will not insert a `To' header
when the message is already `Cc'ed to the recipient."
  :version "22.1"
  :group 'message-headers
  :link '(custom-manual "(message)Message Headers")
  :type '(repeat sexp))

(defun message-carefully-insert-headers (headers)
  "Insert the HEADERS, an alist, into the message buffer.
Does not insert the headers when they are already present there
or in the synonym headers, defined by `message-header-synonyms'."
  ;; FIXME: Should compare only the address and not the full name.  Comparison
  ;; should be done case-folded (and with `string=' rather than
  ;; `string-match').
  ;; (mail-strip-quoted-names "Foo Bar <foo@bar>, bla@fasel (Bla Fasel)")
  (dolist (header headers)
    (let* ((header-name (symbol-name (car header)))
	   (new-header (cdr header))
	   (synonyms (cl-loop for synonym in message-header-synonyms
			      when (memq (car header) synonym) return synonym))
	   (old-header
	    (cl-loop for synonym in synonyms
		     for old-header = (mail-fetch-field (symbol-name synonym))
		     when (and old-header (string-match new-header old-header))
		     return synonym)))
      (if old-header
	  (message "already have `%s' in `%s'" new-header old-header)
	(when (and (message-position-on-field header-name)
		   (setq old-header (mail-fetch-field header-name))
		   (not (string-match "\\` *\\'" old-header)))
	  (insert ", "))
	(insert new-header)))))

(defun message-widen-reply ()
  "Widen the reply to include maximum recipients."
  (interactive nil message-mode)
  (let ((follow-to
         (and (buffer-live-p message-reply-buffer)
	      (with-current-buffer message-reply-buffer
		(message-get-reply-headers t)))))
    (save-excursion
      (save-restriction
	(message-narrow-to-headers)
	(dolist (elem follow-to)
	  (message-remove-header (symbol-name (car elem)))
	  (goto-char (point-min))
	  (insert (symbol-name (car elem)) ": "
		  (cdr elem) "\n"))))))

(defun message-insert-newsgroups ()
  "Insert the Newsgroups header from the article being replied to."
  (interactive nil message-mode)
  (let ((old-newsgroups (mail-fetch-field "newsgroups"))
	(new-newsgroups (message-fetch-reply-field "newsgroups"))
	(first t)
	insert-newsgroups)
    (message-position-on-field "Newsgroups")
    (cond
     ((not new-newsgroups)
      (error "No Newsgroups to insert"))
     ((not old-newsgroups)
      (insert new-newsgroups))
     (t
      (setq new-newsgroups (split-string new-newsgroups "[, ]+")
	    old-newsgroups (split-string old-newsgroups "[, ]+"))
      (dolist (group new-newsgroups)
	(unless (member group old-newsgroups)
	  (push group insert-newsgroups)))
      (if (null insert-newsgroups)
	  (error "Newgroup%s already in the header"
		 (if (> (length new-newsgroups) 1)
		     "s" ""))
	(when old-newsgroups
	  (setq first nil))
	(dolist (group insert-newsgroups)
	  (unless first
	    (insert ","))
	  (setq first nil)
	  (insert group)))))))



;;; Various commands

(defun message-widen-and-recenter ()
  "Widen the buffer and go to the start."
  (interactive nil message-mode)
  (widen)
  (goto-char (point-min)))

(defun message-delete-not-region (beg end)
  "Delete everything in the body of the current message outside of the region."
  (interactive "r" message-mode)
  (let (citeprefix)
    (save-excursion
      (goto-char beg)
      ;; snarf citation prefix, if appropriate
      (unless (eq (point) (progn (beginning-of-line) (point)))
	(when (looking-at message-cite-prefix-regexp)
	  (setq citeprefix (match-string 0))))
      (goto-char end)
      (delete-region (point) (if (not (message-goto-signature))
				 (point)
			       (forward-line -2)
			       (point)))
      (insert "\n")
      (goto-char beg)
      (delete-region beg (progn (message-goto-body)
				(forward-line 2)
				(point)))
      (when citeprefix
	(insert citeprefix))))
  (when (message-goto-signature)
    (forward-line -2)))

(defun message-kill-to-signature (&optional arg)
  "Kill all text up to the signature.
If a numeric argument or prefix arg is given, leave that number
of lines before the signature intact."
  (interactive "P" message-mode)
  (save-excursion
    (save-restriction
      (let ((point (point)))
	(narrow-to-region point (point-max))
	(message-goto-signature)
	(unless (eobp)
	  (if (and arg (numberp arg))
	      (forward-line (- -1 arg))
	    (end-of-line -1)))
	(unless (= point (point))
	  (kill-region point (point))
	  (unless (bolp)
	    (insert "\n")))))))

(defun message-newline-and-reformat (&optional arg not-break)
  "Insert four newlines, and then reformat if inside quoted text.
Prefix arg means justify as well.

This function tries to guess what the quote prefix is based on
the text on the current line before point.  If point is at the
start of the line, the formatted text (if any) is filled without
a quote prefix."
  (interactive (list (if current-prefix-arg 'full)) message-mode)
  (unless (message-in-body-p)
    (error "This command only works in the body of the message"))
  (let (quoted point beg end leading-space bolp fill-paragraph-function)
    (setq point (point))
    (beginning-of-line)
    (setq beg (point))
    (setq bolp (= beg point))
    ;; Find first line of the paragraph.
    (if not-break
	(while (and (not (eobp))
		    (not (looking-at message-cite-prefix-regexp))
		    (looking-at paragraph-start))
	  (forward-line 1)))
    ;; Find the prefix
    (when (looking-at message-cite-prefix-regexp)
      (setq quoted (match-string 0))
      (goto-char (match-end 0))
      (let ((after (point)))
        ;; This is a line with no text after the cite prefix.  In that
        ;; case, the trailing space is commonly not present, so look
        ;; around for other lines that have some data.
        (when (looking-at-p "\n")
          (let ((regexp (concat "^" message-cite-prefix-regexp "[ \t]")))
            (when (or (re-search-backward regexp nil t)
                      (re-search-forward regexp nil t))
              (goto-char (1- (match-end 0))))))
        (looking-at "[ \t]*")
        (setq leading-space (match-string 0))
        (goto-char after)))
    (if (and quoted
	     (not not-break)
	     (not bolp)
	     (< (- point beg) (length quoted)))
	;; break inside the cite prefix.
	(setq quoted nil
	      end nil))
    (if quoted
	(progn
	  (forward-line 1)
	  (while (and (not (eobp))
		      (not (looking-at paragraph-separate))
		      (looking-at message-cite-prefix-regexp)
		      (equal quoted (match-string 0)))
	    (goto-char (match-end 0))
	    (looking-at "[ \t]*")
	    (when (> (length leading-space) (length (match-string 0)))
	      (setq leading-space (match-string 0)))
	    (forward-line 1))
	  (setq end (point))
	  (goto-char beg)
	  (while (and (if (bobp) nil (forward-line -1) t)
		      (not (looking-at paragraph-start))
		      (looking-at message-cite-prefix-regexp)
		      (equal quoted (match-string 0)))
	    (setq beg (point))
	    (goto-char (match-end 0))
	    (looking-at "[ \t]*")
	    (if (> (length leading-space) (length (match-string 0)))
		(setq leading-space (match-string 0)))))
      (while (and (not (eobp))
		  (not (looking-at paragraph-separate))
		  (not (looking-at message-cite-prefix-regexp)))
	(forward-line 1))
      (setq end (point))
      (goto-char beg)
      (while (and (if (bobp) nil (forward-line -1) t)
		  (not (looking-at paragraph-start))
		  (not (looking-at message-cite-prefix-regexp)))
	(setq beg (point))))
    (goto-char point)
    (save-restriction
      (narrow-to-region beg end)
      (if not-break
	  (setq point nil)
	(if bolp
	    (newline)
	  (newline)
	  (newline))
	(setq point (point))
	;; (newline 2) doesn't mark both newline's as hard, so call
	;; newline twice. -jas
	(newline)
	(newline)
	(delete-region (point) (re-search-forward "[ \t]*"))
	(when (and quoted (not bolp))
	  (insert quoted leading-space)))
      (undo-boundary)
      (if quoted
	  (let* ((adaptive-fill-regexp
		  (regexp-quote (concat quoted leading-space)))
		 (adaptive-fill-first-line-regexp
		  adaptive-fill-regexp ))
	    (fill-paragraph arg))
	(fill-paragraph arg))
      (if point (goto-char point)))))

(defun message-fill-paragraph (&optional arg)
  "Message specific function to fill a paragraph.
This function is used as the value of `fill-paragraph-function' in
Message buffers and is not meant to be called directly."
  (interactive (list (if current-prefix-arg 'full)) message-mode)
  (if (message-point-in-header-p)
      (message-fill-field)
    (message-newline-and-reformat arg t))
  t)

(defun message-point-in-header-p ()
  "Return t if point is in the header."
  (save-excursion
    (save-restriction
      (widen)
      (let ((bound (+ (line-end-position) 1)) case-fold-search)
        (goto-char (point-min))
        (not (search-forward (concat "\n" mail-header-separator "\n")
                             bound t))))))

(defun message-do-auto-fill ()
  "Like `do-auto-fill', but don't fill in message header."
  (unless (message-point-in-header-p)
    (let ((paragraph-separate (default-value 'paragraph-separate)))
      (do-auto-fill))))

(defun message-insert-signature (&optional force)
  "Insert a signature at the end of the buffer.

See the documentation for the `message-signature' variable for
more information.

If FORCE is 0 (or when called interactively), the global values
of the signature variables will be consulted if the local ones
are null."
  (interactive (list 0) message-mode)
  (let ((message-signature message-signature)
	(message-signature-file message-signature-file))
    ;; If called interactively and there's no signature to insert,
    ;; consult the global values to see whether there's anything they
    ;; have to say for themselves.  This can happen when using
    ;; `gnus-posting-styles', for instance.
    (when (and (null message-signature)
	       (null message-signature-file)
	       (eq force 0))
      (setq message-signature (default-value 'message-signature)
	    message-signature-file (default-value 'message-signature-file)))
    (let* ((signature
	    (cond
	     ((and (null message-signature)
		   (eq force 0))
	      (save-excursion
		(goto-char (point-max))
		(not (re-search-backward message-signature-separator nil t))))
	     ((and (null message-signature)
		   force)
	      t)
	     ((functionp message-signature)
	      (funcall message-signature))
	     ((listp message-signature)
	      (eval message-signature t))
	     (t message-signature)))
	   signature-file)
      (setq signature
	    (cond ((stringp signature)
		   signature)
		  ((and (eq t signature) message-signature-file)
		   (setq signature-file
			 (if (and message-signature-directory
				  ;; don't actually use the signature directory
				  ;; if message-signature-file contains a path.
				  (not (file-name-directory
					message-signature-file)))
			     (expand-file-name message-signature-file
					       message-signature-directory)
			   message-signature-file))
		   (file-exists-p signature-file))))
      (when signature
	(goto-char (point-max))
	;; Insert the signature.
	(unless (bolp)
	  (newline))
	(when message-signature-insert-empty-line
	  (newline))
	(insert "-- ")
	(newline)
	(if (eq signature t)
	    (insert-file-contents signature-file)
	  (insert signature))
	(goto-char (point-max))
	(or (bolp) (newline))))))

(defun message-insert-importance-high ()
  "Insert header to mark message as important."
  (interactive nil message-mode)
  (save-excursion
    (save-restriction
      (message-narrow-to-headers)
      (message-remove-header "Importance"))
    (message-goto-eoh)
    (insert "Importance: high\n")))

(defun message-insert-importance-low ()
  "Insert header to mark message as unimportant."
  (interactive nil message-mode)
  (save-excursion
    (save-restriction
      (message-narrow-to-headers)
      (message-remove-header "Importance"))
    (message-goto-eoh)
    (insert "Importance: low\n")))

(defun message-insert-or-toggle-importance ()
  "Insert a \"Importance: high\" header, or cycle through the header values.
The three allowed values according to RFC 1327 are `high', `normal'
and `low'."
  (interactive nil message-mode)
  (save-excursion
    (let ((new "high")
	  cur)
      (save-restriction
	(message-narrow-to-headers)
	(when (setq cur (message-fetch-field "Importance"))
	  (message-remove-header "Importance")
	  (setq new (cond ((string= cur "high")
			   "low")
			  ((string= cur "low")
			   "normal")
			  (t
			   "high")))))
      (message-goto-eoh)
      (insert (format "Importance: %s\n" new)))))

(defun message-insert-disposition-notification-to ()
  "Request a disposition notification (return receipt) to this message.
Note that this should not be used in newsgroups."
  (interactive nil message-mode)
  (save-excursion
    (save-restriction
      (message-narrow-to-headers)
      (message-remove-header "Disposition-Notification-To"))
    (message-goto-eoh)
    (insert (format "Disposition-Notification-To: %s\n"
		    (or (message-field-value "Reply-To")
			(message-field-value "From")
			(message-make-from))))))

(defun message-elide-region (b e)
  "Elide the text in the region.
An ellipsis (from `message-elide-ellipsis') will be inserted where the
text was killed."
  (interactive "r" message-mode)
  (let ((lines (count-lines b e))
        (chars (- e b)))
    (kill-region b e)
    (insert (format-spec message-elide-ellipsis
                         `((?l . ,lines)
                           (?c . ,chars))))))

(defvar message-caesar-translation-table nil)

(defun message-caesar-region (b e &optional n)
  "Caesar rotate region B to E by N, default 13, for decrypting netnews."
  (interactive
   (list
    (min (point) (or (mark t) (point)))
    (max (point) (or (mark t) (point)))
    (when current-prefix-arg
      (prefix-numeric-value current-prefix-arg)))
   message-mode)

  (setq n (if (numberp n) (mod n 26) 13)) ;canonize N
  (unless (or (zerop n)		        ; no action needed for a rot of 0
	      (= b e))			; no region to rotate
    ;; We build the table, if necessary.
    (when (or (not message-caesar-translation-table)
	      (/= (aref message-caesar-translation-table ?a) (+ ?a n)))
      (setq message-caesar-translation-table
	    (message-make-caesar-translation-table n)))
    (translate-region b e message-caesar-translation-table)))

(defun message-make-caesar-translation-table (n)
  "Create a rot table with offset N."
  (let ((i -1)
	(table (make-string 256 0)))
    (while (< (incf i) 256)
      (aset table i i))
    (concat
     (substring table 0 ?A)
     (substring table (+ ?A n) (+ ?A n (- 26 n)))
     (substring table ?A (+ ?A n))
     (substring table (+ ?A 26) ?a)
     (substring table (+ ?a n) (+ ?a n (- 26 n)))
     (substring table ?a (+ ?a n))
     (substring table (+ ?a 26) 255))))

(defun message-caesar-buffer-body (&optional rotnum wide)
  "Caesar rotate all letters in the current buffer by 13 places.
Used to encode/decode possibly offensive messages (commonly in rec.humor).
With prefix arg, specifies the number of places to rotate each letter forward.
Mail and Usenet news headers are not rotated unless WIDE is non-nil."
  (interactive (if current-prefix-arg
		   (list (prefix-numeric-value current-prefix-arg))
		 (list nil))
	       message-mode)
  (save-excursion
    (save-restriction
      (when (and (not wide) (message-goto-body))
	(narrow-to-region (point) (point-max)))
      (message-caesar-region (point-min) (point-max) rotnum))))

(defun message-pipe-buffer-body (program)
  "Pipe the message body in the current buffer through PROGRAM."
  (save-excursion
    (save-restriction
      (when (message-goto-body)
	(narrow-to-region (point) (point-max)))
      (shell-command-on-region
       (point-min) (point-max) program nil t))))

(defun message-rename-buffer (&optional enter-string)
  "Rename the *message* buffer to \"*message* RECIPIENT\".
If the function is run with a prefix, it will ask for a new buffer
name, rather than giving an automatic name."
  (interactive "Pbuffer name: " message-mode)
  (save-excursion
    (save-restriction
      (goto-char (point-min))
      (narrow-to-region (point)
			(search-forward mail-header-separator nil 'end))
      (let* ((mail-to (or
		       (if (message-news-p) (message-fetch-field "Newsgroups")
			 (message-fetch-field "To"))
		       ""))
	     (mail-trimmed-to
	      (if (string-match "," mail-to)
		  (concat (substring mail-to 0 (match-beginning 0)) ", ...")
		mail-to))
	     (name-default (concat "*message* " mail-trimmed-to))
	     (name (if enter-string
		       (read-string "New buffer name: " name-default)
		     name-default)))
	(rename-buffer name t)))))

(defun message-fill-yanked-message (&optional justifyp)
  "Fill the paragraphs of a message yanked into this one.
Numeric argument means justify as well."
  (interactive "P" message-mode)
  (save-excursion
    (goto-char (point-min))
    (search-forward (concat "\n" mail-header-separator "\n") nil t)
    (let ((fill-prefix message-yank-prefix))
      (fill-individual-paragraphs (point) (point-max) justifyp))))

(defun message-indent-citation (&optional start end yank-only)
  "Modify text just inserted from a message to be cited.
The inserted text should be the region.
When this function returns, the region is again around the modified text.

Normally, indent each nonblank line `message-indentation-spaces' spaces.
However, if `message-yank-prefix' is non-nil, insert that prefix on each line."
  (unless start (setq start (point)))
  (unless yank-only
    ;; Remove unwanted headers.
    (when message-ignored-cited-headers
      (let (all-removed)
	(save-restriction
	  (narrow-to-region
	   (goto-char start)
	   (if (search-forward "\n\n" nil t)
	       (1- (point))
	     (point)))
	  (message-remove-header message-ignored-cited-headers t)
	  (when (= (point-min) (point-max))
	    (setq all-removed t))
	  (goto-char (point-max)))
	(if all-removed
	    (goto-char start)
	  (forward-line 1))))
    ;; Delete blank lines at the start of the cited text.
    (while (and (eolp) (not (eobp)))
      (delete-line))
    ;; Delete blank lines at the end of the buffer.
    (goto-char (point-max))
    (unless (eq (preceding-char) ?\n)
      (insert "\n"))
    (while (and (zerop (forward-line -1))
		(looking-at "$"))
      (delete-line)))
  ;; Do the indentation.
  (if (null message-yank-prefix)
      (indent-rigidly start (or end (mark t)) message-indentation-spaces)
    (save-excursion
      (goto-char start)
      (while (< (point) (or end (mark t)))
	(cond ((looking-at ">")
	       (insert message-yank-cited-prefix))
	      ((looking-at "^$")
	       (insert message-yank-empty-prefix))
	      (t
	       (insert message-yank-prefix)))
	(forward-line 1))))
  (goto-char start))

(defun message-remove-blank-cited-lines (&optional remove)
  "Remove cited lines containing only blanks.
If REMOVE is non-nil, remove newlines, too.

To use this automatically, you may add this function to
`gnus-message-setup-hook'."
  (interactive "P" message-mode)
  (let ((citexp (concat "^\\("
			(concat message-yank-cited-prefix "\\|")
			message-yank-prefix
			"\\)+ *\n")))
    (message "Removing `%s'" citexp)
    (save-excursion
      (message-goto-body)
      (while (re-search-forward citexp nil t)
	(replace-match (if remove "" "\n"))))))

(defun message--yank-original-internal (arg)
  (let ((modified (buffer-modified-p))
	body-text)
	(when (and message-reply-buffer
		   message-cite-function)
	  (when (equal message-cite-reply-position 'above)
	    (save-excursion
	      (setq body-text
		    (buffer-substring (message-goto-body)
				      (point-max)))
	      (delete-region (message-goto-body) (point-max))))
	  (if (bufferp message-reply-buffer)
	      (delete-windows-on message-reply-buffer t))
	  (push-mark (save-excursion
		       (cond
			((bufferp message-reply-buffer)
			 (insert-buffer-substring message-reply-buffer))
			((and (consp message-reply-buffer)
			      (functionp (car message-reply-buffer)))
			 (apply (car message-reply-buffer)
				(cdr message-reply-buffer))))
		       (unless (bolp)
			 (insert ?\n))
		       (point)))
	  (unless arg
	    (funcall message-cite-function)
	    (unless (eq (char-before (mark t)) ?\n)
	      (let ((pt (point)))
		(goto-char (mark t))
		(insert-before-markers ?\n)
		(goto-char pt))))
	  (pcase message-cite-reply-position
	    ('above
	     (message-goto-body)
	     (insert body-text)
	     (insert (if (bolp) "\n" "\n\n"))
	     (message-goto-body))
	    ('below
	     (message-goto-signature)))
	  ;; Add a `message-setup-very-last-hook' here?
	  ;; Add `gnus-article-highlight-citation' here?
	  (unless modified
        (setq message-checksum (message-checksum))))))

(defun message-yank-original (&optional arg)
  "Insert the message being replied to, if any.
Puts point before the text and mark after.
Normally indents each nonblank line ARG spaces (default 3).  However,
if `message-yank-prefix' is non-nil, insert that prefix on each line.

This function uses `message-cite-function' to do the actual citing.

Just \\[universal-argument] as argument means don't indent, insert no
prefix, and don't delete any headers."
  (interactive "P" message-mode)
  ;; eval the let forms contained in message-cite-style
  (let ((bindings (if (symbolp message-cite-style)
	              (symbol-value message-cite-style)
	            message-cite-style)))
    (cl-progv (mapcar #'car bindings)
        (mapcar (lambda (binding) (eval (cadr binding) t)) bindings)
      (message--yank-original-internal arg))))

(defun message-yank-buffer (buffer)
  "Insert BUFFER into the current buffer and quote it."
  (interactive "bYank buffer: " message-mode)
  (let ((message-reply-buffer (get-buffer buffer)))
    (save-window-excursion
      (message-yank-original))))

(defun message-buffers ()
  "Return a list of active message buffers."
  (let (buffers)
    (save-current-buffer
      (dolist (buffer (buffer-list t))
	(set-buffer buffer)
	(when (and (derived-mode-p 'message-mode)
		   (null message-sent-message-via))
	  (push (buffer-name buffer) buffers))))
    (nreverse buffers)))

(defun message-cite-original-1 (strip-signature)
  "Cite an original message.
If STRIP-SIGNATURE is non-nil, strips off the signature from the
original message.

This function uses `mail-citation-hook' if that is non-nil."
  (if (and (boundp 'mail-citation-hook)
	   mail-citation-hook)
      (run-hooks 'mail-citation-hook)
    (let* ((start (point))
	   (end (mark t))
	   (x-no-archive nil)
	   (functions
	    (when message-indent-citation-function
	      (if (listp message-indent-citation-function)
		  message-indent-citation-function
		(list message-indent-citation-function))))
	   ;; This function may be called by `gnus-summary-yank-message' and
	   ;; may insert a different article from the original.  So, we will
	   ;; modify the value of `message-reply-headers' with that article.
	   (message-reply-headers
	    (save-restriction
	      (narrow-to-region start end)
	      (message-narrow-to-head-1)
	      (setq x-no-archive (message-fetch-field "x-no-archive"))
	      (make-full-mail-header
               0
	       (or (message-fetch-field "subject") "none")
	       (or (message-fetch-field "from") "nobody")
	       (message-fetch-field "date")
	       (message-fetch-field "message-id" t)
	       (message-fetch-field "references")
	       0 0 ""))))
      (mml-quote-region start end)
      (when strip-signature
	;; Allow undoing.
	(undo-boundary)
	(goto-char end)
	(when (re-search-backward message-signature-separator start t)
	  ;; Also peel off any blank lines before the signature.
	  (forward-line -1)
	  (while (looking-at "^[ \t]*$")
	    (forward-line -1))
	  (forward-line 1)
	  (delete-region (point) end)
	  (unless (search-backward "\n\n" start t)
	    ;; Insert a blank line if it is peeled off.
	    (insert "\n"))))
      (goto-char start)
      (mapc #'funcall functions)
      (when message-citation-line-function
	(unless (bolp)
	  (insert "\n"))
	(funcall message-citation-line-function))
      (when (and x-no-archive
		 (not message-cite-articles-with-x-no-archive)
		 (string-match "yes" x-no-archive))
	(undo-boundary)
	(delete-region (point) (mark t))
	(insert "> [Quoted text removed due to X-No-Archive]\n")
	(push-mark)
	(forward-line -1)))))

(defun message-cite-original ()
  "Cite function in the standard Message manner."
  (message-cite-original-1 nil))

(autoload 'gnus-date-get-time "gnus-util")

(defun message-insert-formatted-citation-line (&optional from date tz)
  "Function that inserts a formatted citation line.
The optional FROM, and DATE are strings containing the contents of
the From header and the Date header respectively.

The optional TZ is omitted or nil for Emacs local time, t for
Universal Time, `wall' for system wall clock time, or a string as
in the TZ environment variable.  It can also be a list (as from
`current-time-zone') or an integer (as from `decode-time')
applied without consideration for daylight saving time.

See `message-citation-line-format'."
  ;; The optional args are for testing/debugging.  They will disappear later.
  ;; Example:
  ;; (with-temp-buffer
  ;;   (message-insert-formatted-citation-line
  ;;    "John Doe <john.doe@example.invalid>"
  ;;    (message-make-date))
  ;;   (buffer-string))
  (when (or message-reply-headers (and from date))
    (unless from
      (setq from (mail-header-from message-reply-headers)))
    (let* ((data (ignore-errors
                   (funcall (or (bound-and-true-p
                                 gnus-extract-address-components)
                                #'mail-extract-address-components)
                            from)))
	   (name (car data))
	   (fname name)
	   (lname name)
           (net (cadr data))
           (name-or-net (or name net from))
	   (time
            (when (string-match-p "%[^FLNfn]" message-citation-line-format)
	      (cond ((numberp (car-safe date)) date) ;; backward compatibility
		    (date (gnus-date-get-time date))
		    (t
		     (gnus-date-get-time
		      (setq date (mail-header-date message-reply-headers)))))))
	   (tz (or tz
		   (when (stringp date)
		     (nth 8 (parse-time-string date)))))
           spec)
      (when (stringp name)
        ;; Guess first name and last name:
        (let* ((names (seq-filter
                       (lambda (s)
                         (string-match-p (rx bos (+ (in word ?. ?-)) eos) s))
                       (split-string name "[ \t]+")))
               (count (length names)))
          (cond ((= count 1)
                 (setq fname (car names)
                       lname ""))
                ((or (= count 2) (= count 3))
                 (setq fname (car names)
                       lname (string-join (cdr names) " ")))
                ((> count 3)
                 (setq fname (string-join (take 2 names) " ")
                       lname (string-join (nthcdr 2 names) " "))))
          (when (string-match "\\(.*\\),\\'" fname)
            (let ((newlname (match-string 1 fname)))
              (setq fname lname lname newlname)))))
      ;; The following letters are not used in `format-time-string':
      (push (cons ?E "<E>") spec)
      (push (cons ?F (or fname name-or-net)) spec)
      ;; We might want to use "" instead of "<X>" later.
      (push (cons ?J "<J>") spec)
      (push (cons ?K "<K>") spec)
      (push (cons ?L lname) spec)
      (push (cons ?N name-or-net) spec)
      (push (cons ?O "<O>") spec)
      (push (cons ?P "<P>") spec)
      (push (cons ?Q "<Q>") spec)
      (push (cons ?f from) spec)
      (push (cons ?i "<i>") spec)
      (push (cons ?n net) spec)
      (push (cons ?o "<o>") spec)
      (push (cons ?q "<q>") spec)
      (push (cons ?t "<t>") spec)
      (push (cons ?v "<v>") spec)
      ;; Delegate the rest to `format-time-string':
      (dolist (c (nconc (number-sequence ?A ?Z)
                        (number-sequence ?a ?z)))
        (unless (assq c spec)
          (push (cons c (condition-case nil
                            (format-time-string (format "%%%c" c) time tz)
                          (error (format ">%c<" c))))
                spec)))
      (insert (format-spec message-citation-line-format spec)))
    (newline)))

(defun message-cite-original-without-signature ()
  "Cite function in the standard Message manner.
This function strips off the signature from the original message."
  (message-cite-original-1 t))

(defun message-insert-citation-line ()
  "Insert a simple citation line."
  (when message-reply-headers
    (insert (mail-header-from message-reply-headers) " writes:")
    (newline)
    (newline)))

(defun message-position-on-field (header &rest afters)
  "Move point to header HEADER or insert it if not found.

If HEADER is not present, insert it with an empty value, after any
headers specified in AFTERS."
  (let ((case-fold-search t))
    (save-restriction
      (narrow-to-region
       (goto-char (point-min))
       (progn
	 (re-search-forward
	  (concat "^" (regexp-quote mail-header-separator) "$"))
	 (match-beginning 0)))
      (goto-char (point-min))
      (if (re-search-forward (concat "^" (regexp-quote header) ":") nil t)
	  (progn
	    (re-search-forward "^[^ \t]" nil 'move)
	    (beginning-of-line)
	    (skip-chars-backward "\n")
	    t)
	(while (and afters
		    (not (re-search-forward
			  (concat "^" (regexp-quote (car afters)) ":")
			  nil t)))
	  (pop afters))
	(when afters
	  (re-search-forward "^[^ \t]" nil 'move)
	  (beginning-of-line))
	(insert header ": \n")
	(forward-char -1)
	nil))))



;;;
;;; Sending messages
;;;

(defun message-send-and-exit (&optional arg)
  "Send message like `message-send', then, if no errors, exit from mail buffer.
The usage of ARG is defined by the instance that called Message.
It should typically alter the sending method in some way or other."
  (interactive "P" message-mode)
  (let ((buf (current-buffer))
	(position (point-marker))
	(actions message-exit-actions))
    (when (and (message-send arg)
               (buffer-live-p buf))
      (if message-kill-buffer-on-exit
	  (kill-buffer buf)
	;; Restore the point in the message buffer.
	(save-window-excursion
	  (switch-to-buffer buf)
	  (set-window-point nil position)
	  (set-marker position nil))
	(message-bury buf))
      (message-do-actions actions)
      t)))

(defun message-dont-send ()
  "Don't send the message you have been editing.
Instead, just auto-save the buffer and then bury it."
  (interactive nil message-mode)
  (set-buffer-modified-p t)
  (save-buffer)
  (let ((actions message-postpone-actions))
    (message-bury (current-buffer))
    (message-do-actions actions)))

(defun message-kill-buffer ()
  "Kill the current buffer."
  (interactive nil message-mode)
  (when (or (not (buffer-modified-p))
	    (not message-kill-buffer-query)
	    (yes-or-no-p "Message modified; kill anyway? "))
    (let ((actions message-kill-actions)
	  (draft-article message-draft-article)
	  (auto-save-file-name buffer-auto-save-file-name)
	  (file-name buffer-file-name)
	  (modified (buffer-modified-p)))
      (setq buffer-file-name nil)
      (kill-buffer (current-buffer))
      (when (and (or (and auto-save-file-name
			  (file-exists-p auto-save-file-name))
		     (and file-name
			  (file-exists-p file-name)))
		 (progn
		   ;; If the message buffer has lived in a dedicated window,
		   ;; `kill-buffer' has killed the frame.  Thus the
		   ;; `yes-or-no-p' may show up in a lowered frame.  Make sure
		   ;; that the user can see the question by raising the
		   ;; current frame:
		   (raise-frame)
		   (yes-or-no-p (format "Remove the backup file%s? "
					(if modified " too" "")))))
	(ignore-errors
	  (delete-file auto-save-file-name))
	(let ((message-draft-article draft-article))
	  (message-disassociate-draft)))
      (message-do-actions actions))))

(defun message-bury (buffer)
  "Bury this mail BUFFER."
  ;; Note that this is not quite the same as (bury-buffer buffer),
  ;; since bury-buffer does extra stuff with a nil argument.
  ;; Eg https://lists.gnu.org/r/emacs-devel/2014-01/msg00539.html
  (with-current-buffer buffer (bury-buffer))
  (if message-return-action
      (apply (car message-return-action) (cdr message-return-action))))

(autoload 'mml-secure-bcc-is-safe "mml-sec")

(defcustom message-server-alist nil
  "Alist of rules to generate \"X-Message-SMTP-Method\" header.
The header will be inserted just before the message is sent.
Elements should be of the form (COND . METHOD).
If COND is a string, METHOD will be inserted if the \"From\"
address compares equal with COND.
If COND is a function, METHOD will be inserted if COND returns
a non-nil value when called in the message buffer without any
arguments.  If METHOD is nil in this case, the return value of
the function will be inserted instead.

Note: if the buffer already has a \"X-Message-SMTP-Method\"
header, these rules are ignored, and the header is left
unchanged."
  :type '(alist :key-type (choice
                           (string :tag "From Address")
                           (function :tag "Predicate"))
                :value-type string)
  :version "29.1"
  :group 'message-sending)

(defun message-update-smtp-method-header ()
  "Insert an X-Message-SMTP-Method header according to `message-server-alist'."
  (unless (message-fetch-field "X-Message-SMTP-Method")
    (let ((from (cadr (mail-extract-address-components
                       (save-restriction
                         (widen)
                         (message-narrow-to-headers-or-head)
                         (message-fetch-field "From")))))
          method)
      (catch 'exit
        (dolist (server message-server-alist)
          (cond ((functionp (car server))
                 (let ((res (funcall (car server))))
                   (when res
                     (setq method (or (cdr server) res))
                     (throw 'exit nil))))
                ((and (stringp (car server))
                      (string-equal-ignore-case (car server) from))
                 (setq method (cdr server))
                 (throw 'exit nil)))))
      (when method
        (message-add-header (concat "X-Message-SMTP-Method: " method))))))

(defun message-send (&optional arg)
  "Send the message in the current buffer.
If `message-interactive' is non-nil, wait for success indication or
error messages, and inform user.
Otherwise any failure is reported in a message back to the user from
the mailer.
The usage of ARG is defined by the instance that called Message.
It should typically alter the sending method in some way or other."
  (interactive "P" message-mode)
  ;; Make it possible to undo the coming changes.
  (undo-boundary)
  (let ((inhibit-read-only t))
    (put-text-property (point-min) (point-max) 'read-only nil))
  (message-update-smtp-method-header)
  (message-fix-before-sending)
  (run-hooks 'message-send-hook)
  (mml-secure-bcc-is-safe)
  (when message-confirm-send
    (or (y-or-n-p "Send message? ")
	(keyboard-quit)))
  (when (and (not (mml-secure-is-encrypted-p))
	     (mml-secure-is-encrypted-p 'anywhere)
	     (not (yes-or-no-p "This message has a <#secure tag, but is not going to be encrypted.  Send anyway?")))
    (error "Aborting sending"))
  (message message-sending-message)
  (let ((alist message-send-method-alist)
	(success t)
	elem sent dont-barf-on-no-method
	(message-options message-options))
    (message-options-set-recipient)
    (while (and success
		(setq elem (pop alist)))
      (when (funcall (cadr elem))
	(when (and (or (not (memq (car elem)
				  message-sent-message-via))
		       (message-fetch-field "supersedes")
		       (if (or (message-gnksa-enable-p 'multiple-copies)
			       (not (eq (car elem) 'news)))
			   (y-or-n-p
			    (format
			     "Already sent message via %s; resend? "
			     (car elem)))
			 (error "Denied posting -- multiple copies")))
		   (setq success (funcall (caddr elem) arg)))
	  (setq sent t))))
    (unless (or sent
		(not success)
		(let ((fcc (message-fetch-field "Fcc"))
		      (gcc (message-fetch-field "Gcc")))
		  (when (or fcc gcc)
		    (setq dont-barf-on-no-method
			  (or (eq message-allow-no-recipients 'always)
			      (and (not (eq message-allow-no-recipients 'never))
				   (y-or-n-p
				    (format "No receiver, perform %s anyway? "
					    (cond ((and fcc gcc) "Fcc and Gcc")
						  (fcc "Fcc")
						  (t "Gcc"))))))))))
      (error "No methods specified to send by"))
    (when (or dont-barf-on-no-method
	      (and success sent))
      (message-do-fcc)
      (save-excursion
	(run-hooks 'message-sent-hook))
      (message "Sending...done")
      ;; Do ecomplete address snarfing.
      (when (and (message-mail-alias-type-p 'ecomplete)
		 (not message-inhibit-ecomplete))
	(message-put-addresses-in-ecomplete))
      ;; Mark the buffer as unmodified and delete auto-save.
      (set-buffer-modified-p nil)
      (delete-auto-save-file-if-necessary t)
      (message-disassociate-draft)
      ;; Delete other mail buffers and stuff.
      (message-do-send-housekeeping)
      (message-do-actions message-send-actions)
      ;; Return success.
      t)))

(defun message-send-via-mail (arg)
  "Send the current message via mail."
  (message-send-mail arg))

(defun message-send-via-news (arg)
  "Send the current message via news."
  (funcall message-send-news-function arg))

(defmacro message-check (type &rest forms)
  "Eval FORMS if TYPE is to be checked."
  (declare (indent 1) (debug t))
  `(or (message-check-element ,type)
       (save-excursion
	 ,@forms)))

(defun message-text-with-property (prop &optional start end reverse)
  "Return a list of start and end positions where the text has PROP.
START and END bound the search, they default to `point-min' and
`point-max' respectively.  If REVERSE is non-nil, find text which does
not have PROP."
  (unless start
    (setq start (point-min)))
  (unless end
    (setq end (point-max)))
  (let (next regions)
    (if reverse
	(while (and start
		    (setq start (text-property-any start end prop nil)))
	  (setq next (next-single-property-change start prop nil end))
	  (push (cons start (or next end)) regions)
	  (setq start next))
      (while (and start
		  (or (get-text-property start prop)
		      (and (setq start (next-single-property-change
					start prop nil end))
			   (get-text-property start prop))))
	(setq next (text-property-any start end prop nil))
	(push (cons start (or next end)) regions)
	(setq start next)))
    (nreverse regions)))

(defcustom message-bogus-addresses
  '("noreply" "nospam" "invalid" "@.*@" "[^[:ascii:]].*@" "[ \t]")
  "List of regexps of potentially bogus mail addresses.
See `message-check-recipients' how to setup checking.

This list should make it possible to catch typos or warn about
spam-trap addresses.  It doesn't aim to verify strict RFC
conformance."
  :version "26.1"			; @@ -> @.*@
  :group 'message-headers
  :type '(choice
	  (const :tag "None" nil)
	  (list
	   (set :inline t
		(const "noreply")
		(const "nospam")
		(const "invalid")
		(const :tag "duplicate @" "@.*@")
		(const :tag "non-ascii local part" "[^[:ascii:]].*@")
		(const :tag "`_' in domain part" "@.*_")
		(const :tag "whitespace" "[ \t]"))
	   (repeat :inline t
		   :tag "Other"
		   (regexp)))))

(defun message-fix-before-sending ()
  "Do various things to make the message nice before sending it."
  ;; Make sure there's a newline at the end of the message.
  (goto-char (point-max))
  (unless (bolp)
    (insert "\n"))
  ;; Make the hidden headers visible.
  (widen)
  ;; Sort headers before sending the message.
  (message-sort-headers)
  ;; Make invisible text visible.
  ;; It doesn't seem as if this is useful, since the invisible property
  ;; is clobbered by an after-change hook anyhow.
  (message-check 'invisible-text
    (let ((regions (message-text-with-property 'invisible))
	  from to)
      (when regions
	(while regions
	  (setq from (caar regions)
		to (cdar regions)
		regions (cdr regions))
	  (put-text-property from to 'invisible nil)
	  (overlay-put (make-overlay from to) 'face 'highlight))
	(unless (yes-or-no-p
		 "Invisible text found and made visible; continue sending? ")
	  (error "Invisible text found and made visible")))))
  (message-check 'illegible-text
    (let (char found choice nul-chars)
      (goto-char (point-min))
      (setq nul-chars (save-excursion
			(search-forward "\000" nil t)))
      (while (progn
	       (skip-chars-forward mm-7bit-chars)
	       (when (get-text-property (point) 'no-illegible-text)
		 ;; There is a signed or encrypted raw message part
		 ;; that is considered to be safe.
		 (goto-char (or (next-single-property-change
				 (point) 'no-illegible-text)
				(point-max))))
	       (setq char (char-after)))
	(when (or (< char 128)
		  (and enable-multibyte-characters
		       (memq (char-charset char)
			     '(eight-bit-control eight-bit-graphic
						 ;; Emacs 23, Bug#1770:
						 eight-bit
						 control-1))
		       (not (get-text-property
			     (point) 'untranslated-utf-8))))
	  (overlay-put (make-overlay (point) (1+ (point))) 'face 'highlight)
	  (setq found t))
	(forward-char))
      (when found
	(setq choice
	      (car
	       (read-multiple-choice
		(if nul-chars
		    "NUL characters found, which may cause problems.  Continue sending?"
		  "Non-printable characters found.  Continue sending?")
		`((?d "delete" "Remove non-printable characters and send")
		  (?r "replace"
		      ,(format
			"Replace non-printable characters with \"%s\" and send"
			message-replacement-char))
		  (?u "url-encode" "Use URL %hex encoding")
		  (?s "send" "Send as is without removing anything")
		  (?e "edit" "Continue editing")))))
	(if (eq choice ?e)
	  (error "Non-printable characters"))
	(goto-char (point-min))
	(skip-chars-forward mm-7bit-chars)
	(while (not (eobp))
	  (when (let ((char (char-after)))
		  (or (< char 128)
		      (and enable-multibyte-characters
			   ;; FIXME: Wrong for Emacs 23 (unicode) and for
			   ;; things like undecodable utf-8 (in Emacs 21?).
			   ;; Should at least use find-coding-systems-region.
			   ;; -- fx
			   (memq (char-charset char)
				 '(eight-bit-control eight-bit-graphic
						     ;; Emacs 23, Bug#1770:
						     eight-bit
						     control-1))
			   (not (get-text-property
				 (point) 'untranslated-utf-8)))))
	    (cond
	     ((eq choice ?i)
	      (message-kill-all-overlays))
	     ((eq choice ?u)
	      (let ((char (get-byte (point))))
		(delete-char 1)
		(insert (format "%%%x" char))))
	     (t
	      (delete-char 1)
	      (when (eq choice ?r)
		(insert message-replacement-char)))))
	  (forward-char)
	  (skip-chars-forward mm-7bit-chars)))))
  (message-check 'bogus-recipient
    ;; Warn before sending a mail to an invalid address.
    (message-check-recipients)))

(defun message-bogus-recipient-p (recipients)
  "Check if a mail address in RECIPIENTS looks bogus.

RECIPIENTS is a mail header.  Return a list of potentially bogus
addresses.  If none is found, return nil.

An address might be bogus if there's a matching entry in
`message-bogus-addresses'."
  ;; FIXME: How about "foo@subdomain", when the MTA adds ".domain.tld"?
  (let (found)
    (mapc (lambda (address)
	    (setq address (or (cadr address) ""))
	    (when (or (string= "" address)
		      (and message-bogus-addresses
			   (let ((re
				  (if (listp message-bogus-addresses)
				      (mapconcat #'identity
						 message-bogus-addresses
						 "\\|")
				    message-bogus-addresses)))
			     (string-match re address))))
              (push address found)))
	  (mail-extract-address-components recipients t))
    found))

(defun message-check-recipients ()
  "Warn before composing or sending a mail to an invalid address.

This function could be useful in `message-setup-hook'."
  (interactive nil message-mode)
  (save-restriction
    (message-narrow-to-headers)
    (dolist (hdr '("To" "Cc" "Bcc"))
      (let ((addr (message-fetch-field hdr)))
	(when (stringp addr)
	  ;; First check for syntactically invalid addresses.
	  (dolist (address (mail-header-parse-addresses addr t))
	    (unless (mail-header-parse-addresses address)
	      (unless (y-or-n-p
		       (format "Email address %s looks invalid; send anyway?"
			       address))
		(user-error "Invalid address %s" address))))
	  ;; Then check for likely-bogus addresses.
	  (dolist (bog (message-bogus-recipient-p addr))
	    (and bog
		 (not (y-or-n-p
		       (format-message
			"Address `%s'%s might be bogus.  Continue? "
			bog
			;; If the encoded version of the email address
			;; is different from the unencoded version,
			;; then we likely have invisible characters or
			;; the like.  Display the encoded version,
			;; too.
			(let ((encoded (rfc2047-encode-string bog)))
			  (if (string= encoded bog)
			      ""
			    (format " (%s)" encoded))))))
		 (user-error "Bogus address"))))))))

(custom-add-option 'message-setup-hook 'message-check-recipients)

(defun message-add-action (action &rest types)
  "Add ACTION to be performed when doing an exit of type TYPES.
Valid types are `send', `return', `exit', `kill' and `postpone'."
  (while types
    (add-to-list (intern (format "message-%s-actions" (pop types)))
		 action)))

(defun message-delete-action (action &rest types)
  "Delete ACTION from lists of actions performed when doing an exit of type TYPES."
  (let (var)
    (while types
      (set (setq var (intern (format "message-%s-actions" (pop types))))
	   (delq action (symbol-value var))))))

(defun message-do-actions (actions)
  "Perform all actions in ACTIONS."
  ;; Now perform actions on successful sending.
  (dolist (action actions)
    (ignore-errors
      (cond
       ;; A simple function.
       ((functionp action)
	(funcall action))
       ;; Something to be evalled.
       (t
	(eval action t))))))

(defun message-send-mail-partially ()
  "Send mail as message/partial."
  ;; replace the header delimiter with a blank line
  (goto-char (point-min))
  (re-search-forward
   (concat "^" (regexp-quote mail-header-separator) "\n"))
  (replace-match "\n")
  (run-hooks 'message-send-mail-hook)
  (let ((p (goto-char (point-min)))
	(tembuf (message-generate-new-buffer-clone-locals " message temp"))
	(curbuf (current-buffer))
	(id (message-make-message-id)) (n 1)
        plist total header)
    (while (not (eobp))
      (if (< (point-max) (+ p message-send-mail-partially-limit))
	  (goto-char (point-max))
	(goto-char (+ p message-send-mail-partially-limit))
	(beginning-of-line)
	(if (<= (point) p) (forward-line 1))) ;; In case of bad message.
      (push p plist)
      (setq p (point)))
    (setq total (length plist))
    (push (point-max) plist)
    (setq plist (nreverse plist))
    (unwind-protect
	(save-excursion
	  (setq p (pop plist))
	  (while plist
	    (set-buffer curbuf)
	    (copy-to-buffer tembuf p (car plist))
	    (set-buffer tembuf)
	    (goto-char (point-min))
	    (if header
		(progn
		  (goto-char (point-min))
		  (narrow-to-region (point) (point))
		  (insert header))
	      (message-goto-eoh)
	      (setq header (buffer-substring (point-min) (point)))
	      (goto-char (point-min))
	      (narrow-to-region (point) (point))
	      (insert header)
	      (message-remove-header "Mime-Version")
	      (message-remove-header "Content-Type")
	      (message-remove-header "Content-Transfer-Encoding")
	      (message-remove-header "Message-ID")
	      (message-remove-header "Lines")
	      (goto-char (point-max))
	      (insert "Mime-Version: 1.0\n")
	      (setq header (buffer-string)))
	    (goto-char (point-max))
	    (insert (format "Content-Type: message/partial; id=\"%s\"; number=%d; total=%d\n\n"
			    id n total))
	    (forward-char -1)
	    (let ((mail-header-separator ""))
	      (when (memq 'Message-ID message-required-mail-headers)
		(insert "Message-ID: " (message-make-message-id) "\n"))
	      (when (memq 'Lines message-required-mail-headers)
		(insert "Lines: " (message-make-lines) "\n"))
	      (message-goto-subject)
	      (end-of-line)
	      (insert (format " (%d/%d)" n total))
	      (widen)
	      (if message-send-mail-real-function
		  (funcall message-send-mail-real-function)
		(message-multi-smtp-send-mail)))
	    (setq n (+ n 1))
	    (setq p (pop plist))
	    (erase-buffer)))
      (kill-buffer tembuf))))

(defun message--check-continuation-headers ()
  (message-check 'continuation-headers
    (goto-char (point-min))
    (while (re-search-forward "^[^ \t\n][^ \t\n:]*[ \t\n]" nil t)
      (goto-char (match-beginning 0))
      (if (y-or-n-p "Fix continuation lines? ")
          (insert " ")
        (forward-line 1)
        (unless (y-or-n-p "Send anyway? ")
          (error "Failed to send the message"))))))

(defun message--send-mail-maybe-partially ()
  (if (or (not message-send-mail-partially-limit)
          (< (buffer-size) message-send-mail-partially-limit)
          (not (message-y-or-n-p
                "The message size is too large, split? "
                t
                "\
The message size, "
                (/ (buffer-size) 1000)
                (substitute-command-keys "KB, is too large.

Some mail gateways (MTA's) bounce large messages.  To avoid the
problem, answer \\`y', and the message will be split into several
smaller pieces, the size of each is about ")
                (/ message-send-mail-partially-limit 1000)
                (substitute-command-keys
                 "KB except the last
one.

However, some mail readers (MUA's) can't read split messages, i.e.,
mails in message/partially format.  Answer \\`n', and the message
will be sent in one piece.

The size limit is controlled by `message-send-mail-partially-limit'.
If you always want Gnus to send messages in one piece, set
`message-send-mail-partially-limit' to nil.
"))))
      (progn
        (message "Sending via mail...")
        (if message-send-mail-real-function
            (funcall message-send-mail-real-function)
          (message-multi-smtp-send-mail)))
    (message-send-mail-partially)))

(defun message-send-mail (&optional _)
  (require 'mail-utils)
  (let* ((tembuf (message-generate-new-buffer-clone-locals " message temp"))
	 (case-fold-search nil)
	 (news (message-news-p))
	 (mailbuf (current-buffer))
	 (message-this-is-mail t)
	 ;; gnus-setup-posting-charset is autoloaded in mml.el (FIXME
	 ;; maybe it should not be), which this file requires.  Hence
	 ;; the fboundp test is always true.  Loading it from gnus-msg
	 ;; loads many Gnus files (Bug#5642).  If
	 ;; gnus-group-posting-charset-alist hasn't been customized,
	 ;; this is just going to return nil anyway.  FIXME it would
	 ;; be good to improve this further, because even if g-g-p-c-a
	 ;; has been customized, that is likely to just be for news.
	 ;; Eg either move the definition from gnus-msg, or separate out
	 ;; the mail and news parts.
	 (message-posting-charset
	  (if (and (fboundp 'gnus-setup-posting-charset)
		   (boundp 'gnus-group-posting-charset-alist))
	      (gnus-setup-posting-charset nil)
	    message-posting-charset))
	 (headers message-required-mail-headers)
	 options)
    (save-restriction
      (message-narrow-to-headers)
      ;; Generate the Mail-Followup-To header if the header is not there...
      (if (and (message-subscribed-p)
	       (not (mail-fetch-field "mail-followup-to")))
	  (setq headers
		(cons
		 (cons "Mail-Followup-To" (message-make-mail-followup-to))
		 message-required-mail-headers))
	;; otherwise, delete the MFT header if the field is empty
	(when (equal "" (mail-fetch-field "mail-followup-to"))
	  (message-remove-header "Mail-Followup-To")))
      ;; Insert some headers.
      (let ((message-deletable-headers
	     (if news nil message-deletable-headers)))
	(message-generate-headers headers))
      ;; Check continuation headers.
      (message--check-continuation-headers)
      (message--fold-long-headers)
      ;; Let the user do all of the above.
      (run-hooks 'message-header-hook))
    (setq options message-options)
    (unwind-protect
	(with-current-buffer tembuf
	  (erase-buffer)
	  (setq message-options options)
	  ;; Avoid copying text props (except hard newlines).
	  (insert (with-current-buffer mailbuf
		    (mml-buffer-substring-no-properties-except-some
		     (point-min) (point-max))))
	  (message-encode-message-body)
	  (message--cache-encoded mailbuf)
	  (save-restriction
	    (message-narrow-to-headers)
	    ;; We (re)generate the Lines header.
	    (when (memq 'Lines message-required-mail-headers)
	      (message-generate-headers '(Lines)))
	    ;; Remove some headers.
	    (message-remove-header message-ignored-mail-headers t)
            (mail-encode-encoded-word-buffer)
	    ;; Then check for suspicious addresses.
            (dolist (hdr '("To" "Cc" "Bcc"))
              (let ((addr (message-fetch-field hdr)))
	        (when (stringp addr)
	          (dolist (address (mail-header-parse-addresses addr t))
	            (when-let* ((warning (textsec-suspicious-p
                                          address 'email-address-header)))
	              (unless (y-or-n-p
		               (format "Suspicious address: %s; send anyway?"
                                       warning))
		        (user-error "Suspicious address %s" address))))))))
	  (goto-char (point-max))
	  ;; require one newline at the end.
	  (or (= (preceding-char) ?\n)
	      (insert ?\n))
	  (message-cleanup-headers)
	  ;; FIXME: we're inserting the courtesy copy after encoding.
	  ;; This is wrong if the courtesy copy string contains
	  ;; non-ASCII characters. -- jh
	  (when
	      (save-restriction
		(message-narrow-to-headers)
		(and news
		     (not (message-fetch-field "List-Post"))
		     (not (message-fetch-field "List-ID"))
		     (or (message-fetch-field "cc")
			 (message-fetch-field "bcc")
			 (message-fetch-field "to"))
		     (let ((content-type (message-fetch-field
					  "content-type")))
		       (and
			(or
			 (not content-type)
			 (string= "text/plain"
				  (car
				   (mail-header-parse-content-type
				    content-type))))
			(not
			 (string= "base64"
				  (message-fetch-field
				   "content-transfer-encoding")))))))
	    (message-insert-courtesy-copy
	     (with-current-buffer mailbuf
	       message-courtesy-message)))
          ;; If this was set, `sendmail-program' takes care of encoding.
          (unless message-inhibit-body-encoding
            ;; Let's make sure we encoded everything in the buffer.
            (cl-assert (save-excursion
                         (goto-char (point-min))
                         (not (re-search-forward "[^\000-\377]" nil t)))))
          (mm-disable-multibyte)
          (message--send-mail-maybe-partially)
	  (setq options message-options))
      (kill-buffer tembuf))
    (set-buffer mailbuf)
    (setq message-options options)
    (push 'mail message-sent-message-via)))

(defun message--cache-encoded (mailbuf)
  ;; Store the encoded buffer data for possible reuse later
  ;; when doing Fcc/Gcc handling.  This avoids having to do
  ;; things like re-GPG-encoding secure parts.
  (let ((encoded (buffer-string)))
    (with-current-buffer mailbuf
      (setq message-encoded-mail-cache encoded))))

(defun message--fold-long-headers ()
  "Fold too-long header lines.
Each line should be no more than 79 characters long."
  (goto-char (point-min))
  (while (not (eobp))
    (if (and (looking-at "[^:]+:")
             (> (- (line-end-position) (point)) 79))
	(goto-char (mail-header-fold-field))
      (forward-line 1))))

(defvar sendmail-program)
(defvar smtpmail-smtp-server)
(defvar smtpmail-smtp-service)
(defvar smtpmail-smtp-user)
(defvar smtpmail-stream-type)
(defvar smtpmail-store-queue-variables)

(defun message-multi-smtp-send-mail ()
  "Send the current buffer to `message-send-mail-function'.
Or, if there's a header that specifies a different method, use
that instead."
  (let ((method (message-field-value "X-Message-SMTP-Method"))
        send-function)
    (if (not method)
        (funcall message-send-mail-function)
      (message-remove-header "X-Message-SMTP-Method")
      (setq method (split-string method))
      (setq send-function
            (symbol-function
             (intern-soft (format "message-send-mail-with-%s" (car method)))))
      (cond
       ((equal (car method) "smtp")
        (require 'smtpmail)
        (let* ((smtpmail-store-queue-variables t)
               (smtpmail-smtp-server (nth 1 method))
               (service (nth 2 method))
               (port (string-to-number service))
               ;; If we're talking to the TLS SMTP port, then force a
               ;; TLS connection.
               (smtpmail-stream-type (if (= port 465)
                                         'tls
                                       smtpmail-stream-type))
               (smtpmail-smtp-service (if (> port 0) port service))
               (smtpmail-smtp-user (or (nth 3 method) smtpmail-smtp-user)))
          (message-smtpmail-send-it)))
       (send-function
        (funcall send-function))
       (t
        (error "Unknown mail method %s" method))))))

(defun message-send-mail-with-sendmail ()
  "Send off the prepared buffer with sendmail."
  (require 'sendmail)
  (let ((errbuf (if message-interactive
		    (message-generate-new-buffer-clone-locals
		     " sendmail errors")
		  0))
	resend-to-addresses delimline)
    (unwind-protect
	(progn
	  (let ((case-fold-search t))
	    (save-restriction
	      (message-narrow-to-headers)
	      (setq resend-to-addresses (message-fetch-field "resent-to")))
	    ;; Change header-delimiter to be what sendmail expects.
	    (goto-char (point-min))
	    (re-search-forward
	     (concat "^" (regexp-quote mail-header-separator) "\n"))
	    (replace-match "\n")
	    (backward-char 1)
	    (setq delimline (point-marker))
	    (run-hooks 'message-send-mail-hook)
	    ;; Insert an extra newline if we need it to work around
	    ;; Sun's bug that swallows newlines.
	    (goto-char (1+ delimline))
	    (when (eval message-mailer-swallows-blank-line t)
	      (newline))
	    (when message-interactive
	      (with-current-buffer errbuf
		(erase-buffer))))
	  (let* ((default-directory "/")
		 (coding-system-for-write message-send-coding-system)
		 (cpr (apply
		       #'call-process-region
		       (append
			(list (point-min) (point-max) sendmail-program
			      nil errbuf nil "-oi")
			message-sendmail-extra-arguments
			;; Always specify who from,
			;; since some systems have broken sendmails.
			;; But some systems are more broken with -f, so
			;; we'll let users override this.
			(and (null message-sendmail-f-is-evil)
			     (list "-f" (message-sendmail-envelope-from)))
			;; These mean "report errors by mail"
			;; and "deliver in background".
			(if (null message-interactive) '("-oem" "-odb"))
			;; Get the addresses from the message
			;; unless this is a resend.
			;; We must not do that for a resend
			;; because we would find the original addresses.
			;; For a resend, include the specific addresses.
			(if resend-to-addresses
			    (list resend-to-addresses)
			  '("-t"))))))
	    (unless (or (null cpr) (and (numberp cpr) (zerop cpr)))
	      (when errbuf
		(pop-to-buffer errbuf)
		(setq errbuf nil))
	      (error "Sending...failed with exit value %d" cpr)))
	  (when message-interactive
	    (with-current-buffer errbuf
	      (goto-char (point-min))
	      (while (re-search-forward "\n+ *" nil t)
		(replace-match "; "))
	      (if (not (zerop (buffer-size)))
		  (error "Sending...failed to %s"
			 (buffer-string))))))
      (when (buffer-live-p errbuf)
	(kill-buffer errbuf)))))

(defun message-send-mail-with-qmail ()
  "Pass the prepared message buffer to qmail-inject.
Refer to the documentation for the variable `message-send-mail-function'
to find out how to use this."
  ;; replace the header delimiter with a blank line
  (goto-char (point-min))
  (re-search-forward
   (concat "^" (regexp-quote mail-header-separator) "\n"))
  (replace-match "\n")
  (run-hooks 'message-send-mail-hook)
  ;; send the message
  (pcase
      (let ((coding-system-for-write message-send-coding-system))
	(apply
	 #'call-process-region (point-min) (point-max)
	 message-qmail-inject-program nil nil nil
	 ;; qmail-inject's default behavior is to look for addresses on the
	 ;; command line; if there're none, it scans the headers.
	 ;; yes, it does The Right Thing w.r.t. Resent-To and its kin.
	 ;;
	 ;; in general, ALL of qmail-inject's defaults are perfect for simply
	 ;; reading a formatted (i. e., at least a To: or Resent-To header)
	 ;; message from stdin.
	 ;;
	 ;; qmail also has the advantage of not having been raped by
	 ;; various vendors, so we don't have to allow for that, either --
	 ;; compare this with message-send-mail-with-sendmail and weep
	 ;; for sendmail's lost innocence.
	 ;;
	 ;; all this is way cool coz it lets us keep the arguments entirely
	 ;; free for -inject-arguments -- a big win for the user and for us
	 ;; since we don't have to play that double-guessing game and the user
	 ;; gets full control (no gestapo'ish -f's, for instance).  --sj
	 (if (functionp message-qmail-inject-args)
	     (funcall message-qmail-inject-args)
	   message-qmail-inject-args)))
    ;; qmail-inject doesn't say anything on its stdout/stderr,
    ;; we have to look at the retval instead
    (0 nil)
    (100 (error "qmail-inject reported permanent failure"))
    (111 (error "qmail-inject reported transient failure"))
    ;; should never happen
    (_   (error "qmail-inject reported unknown failure"))))

(defvar mh-previous-window-config)

(defun message-send-mail-with-mh ()
  "Send the prepared message buffer with mh."
  (let ((mh-previous-window-config nil)
	(name (mh-new-draft-name)))
    (setq buffer-file-name name)
    ;; MH wants to generate these headers itself.
    (when message-mh-deletable-headers
      (let ((headers message-mh-deletable-headers))
	(while headers
	  (goto-char (point-min))
	  (when (re-search-forward
		 (concat "^" (symbol-name (car headers)) ": *") nil t)
	    (delete-line))
	  (pop headers))))
    (run-hooks 'message-send-mail-hook)
    ;; Pass it on to mh.
    (mh-send-letter)))

(defun message-use-send-mail-function ()
  (run-hooks 'message-send-mail-hook)
  (funcall send-mail-function))

(defun message-smtpmail-send-it ()
  "Send the prepared message buffer with `smtpmail-send-it'.
The only difference from `smtpmail-send-it' is that this command
evaluates `message-send-mail-hook' just before sending a message.
It is useful if your ISP requires the POP-before-SMTP
authentication.  See the Gnus manual for details."
  (declare (obsolete message-use-send-mail-function "27.1"))
  (run-hooks 'message-send-mail-hook)
  (smtpmail-send-it))

(defun message-send-mail-with-mailclient ()
  "Send the prepared message buffer with `mailclient-send-it'.
The only difference from `mailclient-send-it' is that this
command evaluates `message-send-mail-hook' just before sending a message."
  (declare (obsolete message-use-send-mail-function "27.1"))
  (run-hooks 'message-send-mail-hook)
  (mailclient-send-it))

(defun message-canlock-generate ()
  "Return a string that is non-trivial to guess.
Do not use this for anything important, it is cryptographically weak."
  (secure-hash 'sha1 'iv-auto 128))

(defvar canlock-password)
(defvar canlock-password-for-verify)

(defun message-canlock-password ()
  "The password used by message for cancel locks.
This is the value of `canlock-password', if that option is non-nil.
Otherwise, generate and save a value for `canlock-password' first."
  (require 'canlock)
  (unless canlock-password
    (customize-save-variable 'canlock-password (message-canlock-generate))
    (setq canlock-password-for-verify canlock-password))
  canlock-password)

(defun message-insert-canlock ()
  (when message-insert-canlock
    (message-canlock-password)
    (canlock-insert-header)))

(autoload 'nnheader-get-report "nnheader")

(declare-function gnus-setup-posting-charset "gnus-msg" (group))

(defun message-send-news (&optional arg)
  (require 'gnus-msg)
  (let* ((tembuf (message-generate-new-buffer-clone-locals " *message temp*"))
	 (case-fold-search nil)
	 (method (if (functionp message-post-method)
		     (funcall message-post-method arg)
		   message-post-method))
	 (newsgroups-field (save-restriction
			    (message-narrow-to-headers-or-head)
			    (message-fetch-field "Newsgroups")))
	 (followup-field (save-restriction
			   (message-narrow-to-headers-or-head)
			   (message-fetch-field "Followup-To")))
	 ;; BUG: We really need to get the charset for each name in the
	 ;; Newsgroups and Followup-To lines to allow crossposting
	 ;; between group names with incompatible character sets.
	 ;; -- Per Abrahamsen <abraham@dina.kvl.dk> 2001-10-08.
	 (group-field-charset
	  (gnus-group-name-charset method newsgroups-field))
	 (followup-field-charset
	  (gnus-group-name-charset method (or followup-field "")))
	 (rfc2047-header-encoding-alist
	  (append (when group-field-charset
		    (list (cons "Newsgroups" group-field-charset)))
		  (when followup-field-charset
		    (list (cons "Followup-To" followup-field-charset)))
		  rfc2047-header-encoding-alist))
	 (messbuf (current-buffer))
	 (message-syntax-checks
	  (if (and arg
		   (listp message-syntax-checks))
	      (cons '(existing-newsgroups . disabled)
		    message-syntax-checks)
	    message-syntax-checks))
	 (message-this-is-news t)
	 (message-posting-charset
	  (gnus-setup-posting-charset newsgroups-field))
	 result)
    (if (not (message-check-news-body-syntax))
	nil
      (save-restriction
	(message-narrow-to-headers)
	;; Insert some headers.
	(message-generate-headers message-required-news-headers)
	(message-insert-canlock)
	;; Let the user do all of the above.
	(run-hooks 'message-header-hook))
      ;; Note: This check will be disabled by the ".*" default value for
      ;; gnus-group-name-charset-group-alist. -- Pa 2001-10-07.
      (when (and group-field-charset
		 (listp message-syntax-checks))
	(setq message-syntax-checks
	      (cons '(valid-newsgroups . disabled)
		    message-syntax-checks)))
      (message-cleanup-headers)
      (if (not (let ((message-post-method method))
		 (message-check-news-syntax)))
	  nil
	(unwind-protect
	    (with-current-buffer tembuf
	      (buffer-disable-undo)
	      (erase-buffer)
	      ;; Avoid copying text props (except hard newlines).
	      (insert
	       (with-current-buffer messbuf
		 (mml-buffer-substring-no-properties-except-some
		  (point-min) (point-max))))
	      (message-encode-message-body)
	      (message--cache-encoded messbuf)
	      ;; Remove some headers.
	      (save-restriction
		(message-narrow-to-headers)
		;; We (re)generate the Lines header.
		(when (memq 'Lines message-required-mail-headers)
		  (message-generate-headers '(Lines)))
		;; Remove some headers.
		(message-remove-header message-ignored-news-headers t)
                (mail-encode-encoded-word-buffer))
	      (goto-char (point-max))
	      ;; require one newline at the end.
	      (or (= (preceding-char) ?\n)
		  (insert ?\n))
	      (let ((case-fold-search t))
		;; Remove the delimiter.
		(goto-char (point-min))
		(re-search-forward
		 (concat "^" (regexp-quote mail-header-separator) "\n"))
		(replace-match "\n")
		(backward-char 1))
	      (run-hooks 'message-send-news-hook)
	      (gnus-open-server method)
	      (message "Sending news via %s..." (gnus-server-string method))
	      (setq result (let ((mail-header-separator ""))
			     (gnus-request-post method))))
	  (kill-buffer tembuf))
	(set-buffer messbuf)
	(if result
	    (push 'news message-sent-message-via)
	  (message "Couldn't send message via news: %s"
		   (nnheader-get-report (car method)))
	  nil)))))

;;;
;;; Header generation & syntax checking.
;;;

(defun message-check-element (type)
  "Return non-nil if this TYPE is not to be checked."
  (if (eq message-syntax-checks 'dont-check-for-anything-just-trust-me)
      t
    (let ((able (assq type message-syntax-checks)))
      (and (consp able)
	   (eq (cdr able) 'disabled)))))

(defun message-check-news-syntax ()
  "Check the syntax of the message."
  (save-excursion
    (save-restriction
      (widen)
      ;; We narrow to the headers and check them first.
      (save-excursion
	(save-restriction
	  (message-narrow-to-headers)
	  (message-check-news-header-syntax))))))

(defun message-check-news-header-syntax ()
  (and
   ;; Check Newsgroups header.
   (message-check 'newsgroups
     (let ((group (message-fetch-field "newsgroups")))
       (or
	(and group
	     (not (string-match "\\`[ \t]*\\'" group)))
	(ignore
	 (message
	  "The newsgroups field is empty or missing.  Posting is denied.")))))
   ;; Check the Subject header.
   (message-check 'subject
     (let* ((case-fold-search t)
	    (subject (message-fetch-field "subject")))
       (or
	(and subject
	     (not (string-match "\\`[ \t]*\\'" subject)))
	(ignore
	 (message
	  "The subject field is empty or missing.  Posting is denied.")))))
   ;; Check for commands in Subject.
   (message-check 'subject-cmsg
     (if (string-match "^cmsg " (message-fetch-field "subject"))
	 (y-or-n-p
	  "The control code \"cmsg\" is in the subject.  Really post? ")
       t))
   ;; Check long header lines.
   (message-check 'long-header-lines
     (let ((header nil)
	   (length 0)
	   found)
       (while (and (not found)
		   (re-search-forward "^\\([^ \t:]+\\): " nil t))
	 (if (> (- (point) (match-beginning 0)) 998)
	     (setq found t
		   length (- (point) (match-beginning 0)))
	   (setq header (match-string-no-properties 1)))
	 (forward-line 1))
       (if found
	   (y-or-n-p (format "Your %s header is too long (%d).  Really post? "
			     header length))
	 t)))
   ;; Check for multiple identical headers.
   (message-check 'multiple-headers
     (let (found)
       (while (and (not found)
		   (re-search-forward "^[^ \t:]+: " nil t))
	 (save-excursion
	   (or (re-search-forward
		(concat "^"
			(regexp-quote
			 (setq found
			       (buffer-substring
				(match-beginning 0) (- (match-end 0) 2))))
			":")
		nil t)
	       (setq found nil))))
       (if found
	   (y-or-n-p (format "Multiple %s headers.  Really post? " found))
	 t)))
   ;; Check for Version and Sendsys.
   (message-check 'sendsys
     (if (re-search-forward "^Sendsys:\\|^Version:" nil t)
	 (y-or-n-p
	  (format "The article contains a %s command.  Really post? "
		  (buffer-substring (match-beginning 0)
				    (1- (match-end 0)))))
       t))
   ;; See whether we can shorten Followup-To.
   (message-check 'shorten-followup-to
     (let ((newsgroups (message-fetch-field "newsgroups"))
	   (followup-to (message-fetch-field "followup-to"))
	   to)
       (when (and newsgroups
		  (string-search "," newsgroups)
		  (not followup-to)
		  (not
		   (zerop
		    (length
		     (setq to (completing-read
                               (format-prompt "Followups to" "no Followup-To header")
			       (mapcar #'list
				       (cons "poster"
					     (message-tokenize-header
					      newsgroups)))))))))
	 (goto-char (point-min))
	 (insert "Followup-To: " to "\n"))
       t))
   ;; Check "Shoot me".
   (message-check 'shoot
     (if (re-search-forward
	  "Message-ID.*.mail-host-address-is-not-set" nil t)
	 (y-or-n-p "You appear to have a misconfigured system.  Really post? ")
       t))
   ;; Check for Approved.
   (message-check 'approved
     (if (re-search-forward "^Approved:" nil t)
	 (y-or-n-p "The article contains an Approved header.  Really post? ")
       t))
   ;; Check the Message-ID header.
   (message-check 'message-id
     (let* ((case-fold-search t)
	    (message-id (message-fetch-field "message-id" t)))
       (or (not message-id)
	   ;; Is there an @ in the ID?
	   (and (string-search "@" message-id)
		;; Is there a dot in the ID?
		(string-match "@[^.]*\\." message-id)
		;; Does the ID end with a dot?
		(not (string-search ".>" message-id)))
	   (y-or-n-p
	    (format "The Message-ID looks strange: \"%s\".  Really post? "
		    message-id)))))
   ;; Check the Newsgroups & Followup-To headers.
   (message-check 'existing-newsgroups
     (let* ((case-fold-search t)
	    (newsgroups (message-fetch-field "newsgroups"))
	    (followup-to (message-fetch-field "followup-to"))
	    (groups (message-tokenize-header
		     (if followup-to
			 (concat newsgroups "," followup-to)
		       newsgroups)))
	    (post-method (if (functionp message-post-method)
			     (funcall message-post-method)
			   message-post-method))
	    ;; KLUDGE to handle nnvirtual groups.  Doing this right
	    ;; would probably involve a new nnoo function.
	    ;; -- Per Abrahamsen <abraham@dina.kvl.dk>, 2001-10-17.
	    (method (if (and (consp post-method)
			     (eq (car post-method) 'nnvirtual)
			     gnus-message-group-art)
			(let ((group (car (nnvirtual-find-group-art
					   (car gnus-message-group-art)
					   (cdr gnus-message-group-art)))))
			  (gnus-find-method-for-group group))
		      post-method))
	    (known-groups
	     (mapcar (lambda (n)
		       (gnus-group-name-decode
			(gnus-group-real-name n)
			(gnus-group-name-charset method n)))
		     (gnus-groups-from-server method)))
	    errors)
       (while groups
	 (when (and (not (equal (car groups) "poster"))
		    (not (member (car groups) known-groups))
		    (not (member (car groups) errors)))
	   (push (car groups) errors))
	 (pop groups))
       (cond
	;; Gnus is not running.
	((or (not (and (boundp 'gnus-active-hashtb)
		       gnus-active-hashtb))
	     (not (boundp 'gnus-read-active-file)))
	 t)
	;; We don't have all the group names.
	((and (or (not gnus-read-active-file)
		  (eq gnus-read-active-file 'some))
	      errors)
	 (y-or-n-p
	  (format
	   "Really use %s possibly unknown group%s: %s? "
	   (if (= (length errors) 1) "this" "these")
	   (if (= (length errors) 1) "" "s")
	   (mapconcat #'identity errors ", "))))
	;; There were no errors.
	((not errors)
	 t)
	;; There are unknown groups.
	(t
	 (y-or-n-p
	  (format
	   "Really post to %s unknown group%s: %s? "
	   (if (= (length errors) 1) "this" "these")
	   (if (= (length errors) 1) "" "s")
	   (mapconcat #'identity errors ", ")))))))
   (progn (message--check-continuation-headers) t)
   ;; Check the Newsgroups & Followup-To headers for syntax errors.
   (message-check 'valid-newsgroups
     (let ((case-fold-search t)
	   (headers '("Newsgroups" "Followup-To"))
	   header error)
       (while (and headers (not error))
	 (when (setq header (mail-fetch-field (car headers)))
	   (if (or
		(not
		 (string-match
		  "\\`\\([-+_&.a-zA-Z0-9]+\\)?\\(,[-+_&.a-zA-Z0-9]+\\)*\\'"
		  header))
		(memq
		 nil (mapcar
		      (lambda (g)
			(not (string-match "\\.\\'\\|\\.\\." g)))
		      (message-tokenize-header header ","))))
	       (setq error t)))
	 (unless error
	   (pop headers)))
       (if (not error)
	   t
	 (y-or-n-p
	  (format "The %s header looks odd: \"%s\".  Really post? "
		  (car headers) header)))))
   (message-check 'repeated-newsgroups
     (let ((case-fold-search t)
	   (headers '("Newsgroups" "Followup-To"))
	   header error groups group)
       (while (and headers
		   (not error))
	 (when (setq header (mail-fetch-field (pop headers)))
	   (setq groups (message-tokenize-header header ","))
	   (while (setq group (pop groups))
	     (when (member group groups)
	       (setq error group
		     groups nil)))))
       (if (not error)
	   t
	 (y-or-n-p
	  (format "Group %s is repeated in headers.  Really post? " error)))))
   ;; Check the From header.
   (message-check 'from
     (let* ((case-fold-search t)
	    (from (message-fetch-field "from"))
	    ad)
       (cond
	((not from)
	 (message "There is no From line.  Posting is denied.")
	 nil)
	((or (not (string-match
		   "@[^\\.]*\\."
		   (setq ad (nth 1 (mail-extract-address-components
				    from))))) ;larsi@ifi
	     (string-search ".." ad)	;larsi@ifi..uio
	     (string-search "@." ad)	;larsi@.ifi.uio
	     (string-match "\\.$" ad)	;larsi@ifi.uio.
	     (not (string-match "^[^@]+@[^@]+$" ad)) ;larsi.ifi.uio
	     (string-match "(.*).*(.*)" from)) ;(lars) (lars)
	 (message
	  "Denied posting -- the From looks strange: \"%s\"." from)
	 nil)
	((let ((addresses (rfc822-addresses from)))
	   ;; `rfc822-addresses' returns a string if parsing fails.
	   (while (and (consp addresses)
		       (not (eq (string-to-char (car addresses)) ?\()))
	     (setq addresses (cdr addresses)))
	   addresses)
	 (message
	  "Denied posting -- bad From address: \"%s\"." from)
	 nil)
	(t t))))
   ;; Check the Reply-To header.
   (message-check 'reply-to
     (let* ((case-fold-search t)
	    (reply-to (message-fetch-field "reply-to"))
	    ad)
       (cond
	((not reply-to)
	 t)
	((string-search "," reply-to)
	 (y-or-n-p
	  (format "Multiple Reply-To addresses: \"%s\". Really post? "
		  reply-to)))
	((or (not (string-match
		   "@[^\\.]*\\."
		   (setq ad (nth 1 (mail-extract-address-components
				    reply-to))))) ;larsi@ifi
	     (string-search ".." ad)	;larsi@ifi..uio
	     (string-search "@." ad)	;larsi@.ifi.uio
	     (string-match "\\.$" ad)	;larsi@ifi.uio.
	     (not (string-match "^[^@]+@[^@]+$" ad)) ;larsi.ifi.uio
	     (string-match "(.*).*(.*)" reply-to)) ;(lars) (lars)
	 (y-or-n-p
	  (format
	   "The Reply-To looks strange: \"%s\". Really post? "
	   reply-to)))
	(t t))))))

(defun message-check-news-body-syntax ()
  (and
   ;; Check for long lines.
   (message-check 'long-lines
     (goto-char (point-min))
     (re-search-forward
      (concat "^" (regexp-quote mail-header-separator) "$"))
     (forward-line 1)
     (while (and
	     (or (looking-at
		  "<#\\(/\\)?\\(multipart\\|part\\|external\\|mml\\)")
		 (let ((p (point)))
		   (end-of-line)
		   (< (- (point) p) 80)))
	     (zerop (forward-line 1))))
     (or (bolp)
	 (eobp)
	 (y-or-n-p
	  "You have lines longer than 79 characters.  Really post? ")))
   ;; Check whether the article is empty.
   (message-check 'empty
     (goto-char (point-min))
     (re-search-forward
      (concat "^" (regexp-quote mail-header-separator) "$"))
     (forward-line 1)
     (let ((b (point)))
       (goto-char (point-max))
       (re-search-backward message-signature-separator nil t)
       (beginning-of-line)
       (or (re-search-backward "[^ \n\t]" b t)
	   (if (message-gnksa-enable-p 'empty-article)
	       (y-or-n-p "Empty article.  Really post? ")
	     (message "Denied posting -- Empty article.")
	     nil))))
   ;; Check for control characters.
   (message-check 'control-chars
     (if (re-search-forward
	  (eval-when-compile
            (decode-coding-string "[\000-\007\013\015-\032\034-\037\200-\237]"
                                  'binary))
	  nil t)
	 (y-or-n-p
	  "The article contains control characters.  Really post? ")
       t))
   ;; Check excessive size.
   (message-check 'size
     (if (> (buffer-size) 60000)
	 (y-or-n-p
	  (format "The article is %d octets long.  Really post? "
		  (buffer-size)))
       t))
   ;; Check whether any new text has been added.
   (message-check 'new-text
     (or
      (not message-checksum)
      (not (equal (message-checksum) message-checksum))
      (if (message-gnksa-enable-p 'quoted-text-only)
	  (y-or-n-p
	   "It looks like no new text has been added.  Really post? ")
	(message "Denied posting -- no new text has been added.")
	nil)))
   ;; Check the length of the signature.
   (message-check 'signature
     (let (sig-start sig-end)
       (goto-char (point-max))
       (if (not (re-search-backward message-signature-separator nil t))
	   t
         (setq sig-start (1+ (line-end-position)))
	 (setq sig-end
	       (if (re-search-forward
		    "<#/?\\(multipart\\|part\\|external\\|mml\\)" nil t)
                   (- (line-beginning-position) 1)
		 (point-max)))
	 (if (>= (count-lines sig-start sig-end) 5)
	     (if (message-gnksa-enable-p 'signature)
		 (y-or-n-p
		  (format "Signature is excessively long (%d lines).  Really post? "
			  (count-lines sig-start sig-end)))
	       (message "Denied posting -- Excessive signature.")
	       nil)
	   t))))
   ;; Ensure that text follows last quoted portion.
   (message-check 'quoting-style
     (goto-char (point-max))
     (let ((no-problem t))
       (when (search-backward-regexp "^>[^\n]*\n" nil t)
	 (setq no-problem (search-forward-regexp "^[ \t]*[^>\n]" nil t)))
       (if no-problem
	   t
	 (if (message-gnksa-enable-p 'quoted-text-only)
	     (y-or-n-p "Your text should follow quoted text.  Really post? ")
	   ;; Ensure that
	   (goto-char (point-min))
	   (re-search-forward
	    (concat "^" (regexp-quote mail-header-separator) "$"))
	   (if (search-forward-regexp "^[ \t]*[^>\n]" nil t)
	       (y-or-n-p "Your text should follow quoted text.  Really post? ")
	     (message "Denied posting -- only quoted text.")
	     nil)))))))

(defun message--rotate-fixnum-left (n)
  "Rotate the fixnum N left by one bit in a fixnum word.
The result is a fixnum."
  (logior (if (natnump n) 0 1)
	  (ash (cond ((< (ash most-positive-fixnum -1) n)
		      (logior n most-negative-fixnum))
		     ((< n (ash most-negative-fixnum -1))
		      (logand n most-positive-fixnum))
		     (n))
	       1)))

(defun message-checksum ()
  "Return a \"checksum\" for the current buffer."
  (let ((sum 0))
    (save-excursion
      (goto-char (point-min))
      (re-search-forward
       (concat "^" (regexp-quote mail-header-separator) "$"))
      (while (not (eobp))
	(when (not (looking-at "[ \t\n]"))
	  (setq sum (logxor (message--rotate-fixnum-left sum)
			    (char-after))))
	(forward-char 1)))
    sum))

(defun message-do-fcc ()
  "Process Fcc headers in the current buffer."
  (let ((case-fold-search t)
	(buf (current-buffer))
	(encoded-cache message-encoded-mail-cache)
	(mml-externalize-attachments message-fcc-externalize-attachments)
	(file (message-field-value "fcc" t))
	list)
    (when file
      (with-temp-buffer
	(insert-buffer-substring buf)
	(message-clone-locals buf)
	;; Avoid re-doing things like GPG-encoding secret parts, unless
	;; the user has requested that attachments be externalized, in
	;; which case we have to re-encode the message body.
	(if (or mml-externalize-attachments (not encoded-cache))
	    (message-encode-message-body)
	  (erase-buffer)
	  (insert encoded-cache))
	(save-restriction
	  (message-narrow-to-headers)
	  (while (setq file (message-fetch-field "fcc" t))
	    (push file list)
	    (message-remove-header "fcc" nil t))
          (let ((rfc2047-header-encoding-alist
		 (cons '("Newsgroups" . default)
		       rfc2047-header-encoding-alist)))
	    (mail-encode-encoded-word-buffer)))
	(goto-char (point-min))
	(when (re-search-forward
	       (concat "^" (regexp-quote mail-header-separator) "$")
	       nil t)
	  (replace-match "" t t ))
	;; Process Fcc operations.
	(while list
	  (setq file (pop list))
	  (if (string-match "^[ \t]*|[ \t]*\\(.*\\)[ \t]*$" file)
	      ;; Pipe the article to the program in question.
	      (call-shell-region (point-min) (point-max) (match-string 1 file))
	    ;; Save the article.
	    (setq file (expand-file-name file))
	    (unless (file-exists-p (file-name-directory file))
	      (make-directory (file-name-directory file) t))
	    (if (and message-fcc-handler-function
		     (not (eq message-fcc-handler-function 'rmail-output)))
		(funcall message-fcc-handler-function file)
	      ;; FIXME this option, rmail-output (also used if
	      ;; message-fcc-handler-function is nil) is not
	      ;; documented anywhere AFAICS.  It should work in Emacs
	      ;; 23; I suspect it does not work in Emacs 22.
	      ;; FIXME I don't see the need for the two different cases here.
	      ;; mail-use-rfc822 makes no difference (in Emacs 23),and
	      ;; the third argument just controls \"Wrote file\" message.
	      (if (and (file-readable-p file) (mail-file-babyl-p file))
		  (rmail-output file 1 nil t)
		(let ((mail-use-rfc822 t))
		  (rmail-output file 1 t t))))))))))

(defun message-output (filename)
  "Append this article to Unix/babyl mail file FILENAME."
  (if (or (and (file-readable-p filename)
	       (mail-file-babyl-p filename))
	  ;; gnus-output-to-mail does the wrong thing with live, mbox
	  ;; Rmail buffers in Emacs 23.
          ;; https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=597255
	  (let ((buff (find-buffer-visiting filename)))
	    (and buff (with-current-buffer buff
			(eq major-mode 'rmail-mode)))))
      (gnus-output-to-rmail filename t)
    (gnus-output-to-mail filename t)))

(defun message-cleanup-headers ()
  "Do various automatic cleanups of the headers."
  ;; Remove empty lines in the header.
  (save-restriction
    (message-narrow-to-headers)
    ;; Remove blank lines.
    (while (re-search-forward "^[ \t]*\n" nil t)
      (replace-match "" t t))

    ;; Correct Newsgroups and Followup-To headers:  Change sequence of
    ;; spaces to comma and eliminate spaces around commas.  Eliminate
    ;; embedded line breaks.
    (goto-char (point-min))
    (while (re-search-forward "^\\(Newsgroups\\|Followup-To\\): +" nil t)
      (save-restriction
	(narrow-to-region
	 (point)
	 (if (re-search-forward "^[^ \t]" nil t)
	     (match-beginning 0)
	   (forward-line 1)
	   (point)))
	(goto-char (point-min))
	(while (re-search-forward "\n[ \t]+" nil t)
	  (replace-match " " t t))     ;No line breaks (too confusing)
	(goto-char (point-min))
	(while (re-search-forward "[ \t\n]*,[ \t\n]*\\|[ \t]+" nil t)
	  (replace-match "," t t))
	(goto-char (point-min))
	;; Remove trailing commas.
	(when (re-search-forward ",+$" nil t)
	  (replace-match "" t t))))))

(defun message-make-date (&optional now)
  "Make a valid data header.
If NOW, use that time instead."
  (let ((system-time-locale "C"))
    (format-time-string "%a, %d %b %Y %T %z" now)))

(defun message-insert-expires (days)
  "Insert the Expires header.  Expiry in DAYS days."
  (interactive "NExpire article in how many days? " message-mode)
  (save-excursion
    (message-position-on-field "Expires" "X-Draft-From")
    (insert (message-make-expires-date days))))

(defun message-make-expires-date (days)
  "Make date string for the Expires header.  Expiry in DAYS days.

In posting styles use `(\"Expires\" (make-expires-date 30))'."
  (let* ((cur (decode-time nil nil 'integer))
	 (nday (+ days (decoded-time-day cur))))
    (setf (decoded-time-day cur) nday)
    (message-make-date (encode-time cur))))

(defun message-make-message-id ()
  "Make a unique Message-ID."
  (concat "<" (message-unique-id)
	  (let ((psubject (save-excursion (message-fetch-field "subject")))
		(psupersedes
		 (save-excursion (message-fetch-field "supersedes"))))
	    (if (or
		 (and message-reply-headers
		      (mail-header-references message-reply-headers)
		      (mail-header-subject message-reply-headers)
		      psubject
		      (not (string=
			    (message-strip-subject-re
			     (mail-header-subject message-reply-headers))
			    (message-strip-subject-re psubject))))
		 (and psupersedes
		      (string-search "_-_@" psupersedes)))
		"_-_" ""))
	  "@" (message-make-fqdn) ">"))

(defvar message-unique-id-char nil)

;; If you ever change this function, make sure the new version
;; cannot generate IDs that the old version could.
;; You might for example insert a "." somewhere (not next to another dot
;; or string boundary), or modify the "fsf" string.
(defun message-unique-id ()
  ;; Don't use fractional seconds from timestamp; they may be unsupported.
  ;; Instead we use this randomly inited counter.
  (setq message-unique-id-char
	;; 2^16 * 25 just fits into 4 digits i base 36.
	(let ((base (* 25 25)))
	  (if message-unique-id-char
	      (% (1+ message-unique-id-char) base)
	    (random base))))
  (let ((tm (time-convert nil 'integer)))
    (concat
     (if (or (eq system-type 'ms-dos)
	     ;; message-number-base36 doesn't handle bigints.
	     (floatp (user-uid)))
	 (let ((user (downcase (user-login-name))))
	   (while (string-match "[^a-z0-9_]" user)
	     (aset user (match-beginning 0) ?_))
	   user)
       (message-number-base36 (user-uid) -1))
     (message-number-base36 (+ (ash tm -16)
			       (ash (% message-unique-id-char 25) 16))
			    4)
     (message-number-base36 (+ (logand tm #xffff)
			       (ash (/ message-unique-id-char 25) 16))
			    4)
     ;; Append a given name, because while the generated ID is unique
     ;; to this newsreader, other newsreaders might otherwise generate
     ;; the same ID via another algorithm.
     ".fsf")))

(defun message-number-base36 (num len)
  (if (if (< len 0)
	  (<= num 0)
	(= len 0))
      ""
    (concat (message-number-base36 (/ num 36) (1- len))
	    (char-to-string (aref "zyxwvutsrqponmlkjihgfedcba9876543210"
				  (% num 36))))))

(defun message-make-organization ()
  "Make an Organization header."
  (let* ((organization
	  (when message-user-organization
	    (if (functionp message-user-organization)
		(funcall message-user-organization)
	      message-user-organization))))
    (with-temp-buffer
      (mm-enable-multibyte)
      (cond ((stringp organization)
	     (insert organization))
	    ((and (eq t organization)
		  message-user-organization-file
		  (file-exists-p message-user-organization-file))
	     (insert-file-contents message-user-organization-file)))
      (goto-char (point-min))
      (while (re-search-forward "[\t\n]+" nil t)
	(replace-match "" t t))
      (unless (zerop (buffer-size))
	(buffer-string)))))

(defun message-make-lines ()
  "Count the number of lines and return numeric string."
  (save-excursion
    (save-restriction
      (widen)
      (message-goto-body)
      (int-to-string (count-lines (point) (point-max))))))

(defun message-make-references ()
  "Return the References header for this message."
  (when message-reply-headers
    (let ((message-id (mail-header-id message-reply-headers))
	  (references (mail-header-references message-reply-headers)))
      (if (or references message-id)
	  (concat (or references "") (and references " ")
		  (or message-id ""))
	nil))))

(defun message-make-in-reply-to ()
  "Return the In-Reply-To header for this message."
  (when message-reply-headers
    (let ((from (mail-header-from message-reply-headers))
          (date (mail-header-date message-reply-headers))
          (msg-id (mail-header-id message-reply-headers)))
      (when from
        (let ((name (mail-extract-address-components from)))
          (concat
           msg-id
           (when message-header-use-obsolete-in-reply-to
             (concat
              (if msg-id " (")
              (if (car name)
                  (if (string-match "[^[:ascii:]]" (car name))
                      ;; Quote a string containing non-ASCII characters.
                      ;; It will make the RFC2047 encoder cause an error
                      ;; if there are special characters.
                      (mm-with-multibyte-buffer
                        (insert (car name))
                        (goto-char (point-min))
                        (while (search-forward "\"" nil t)
                          (when (prog2
                                    (backward-char)
                                    (evenp (skip-chars-backward "\\\\"))
                                  (goto-char (match-beginning 0)))
                            (insert "\\"))
                          (forward-char))
                        ;; Those quotes will be removed by the RFC2047 encoder.
                        (concat "\"" (buffer-string) "\""))
                    (car name))
                (nth 1 name))
              "'s message of \""
              (if (or (not date) (string= date ""))
                  "(unknown date)" date)
              "\"" (if msg-id ")")))))))))

(defun message-make-distribution ()
  "Make a Distribution header."
  (let ((orig-distribution (message-fetch-reply-field "distribution")))
    (cond ((functionp message-distribution-function)
	   (funcall message-distribution-function))
	  (t orig-distribution))))

(defun message-make-expires ()
  "Return an Expires header based on `message-expires'."
  (let ((future (* 60 60 24 message-expires)))
    ;; Add the future to current.
    (message-make-date (time-add nil future))))

(defun message-make-path ()
  "Return uucp path."
  (let ((login-name (user-login-name)))
    (cond ((null message-user-path)
	   (concat (system-name) "!" login-name))
	  ((stringp message-user-path)
	   ;; Support GENERICPATH.  Suggested by vixie@decwrl.dec.com.
	   (concat message-user-path "!" login-name))
	  (t login-name))))

(defun message-make-from (&optional name address)
  "Make a From header."
  (let* ((style message-from-style)
	 (login (or address (message-make-address)))
	 (fullname (or name user-full-name (user-full-name))))
    (when (string= fullname "&")
      (setq fullname (user-login-name)))
    (with-temp-buffer
      (mm-enable-multibyte)
      (cond
       ((or (null style)
	    (equal fullname ""))
	(insert login))
       ((or (eq style 'angles)
	    (and (not (eq style 'parens))
		 ;; Use angles if no quoting is needed, or if parens would
		 ;; need quoting too.
		 (or (not (string-match "[^- !#-'*+/-9=?A-Z^-~]" fullname))
		     (let ((tmp (concat fullname nil)))
		       (while (string-match "([^()]*)" tmp)
			 (aset tmp (match-beginning 0) ?-)
			 (aset tmp (1- (match-end 0)) ?-))
		       (string-match "[\\()]" tmp)))))
	(insert fullname)
	(goto-char (point-min))
	;; Look for a character that cannot appear unquoted
	;; according to RFC 822 (or later).
	(when (re-search-forward "[^- !#-'*+/-9=?A-Z^-~]" nil 1)
	  ;; Quote fullname, escaping specials.
	  (goto-char (point-min))
	  (insert "\"")
	  (while (re-search-forward "[\"\\]" nil 1)
	    (replace-match "\\\\\\&" t))
	  (insert "\""))
	(insert " <" login ">"))
       (t				; 'parens or default
	(insert login " (")
	(let ((fullname-start (point)))
	  (insert fullname)
	  (goto-char fullname-start)
	  ;; \ and nonmatching parentheses must be escaped in comments.
	  ;; Escape every instance of ()\ ...
	  (while (re-search-forward "[()\\]" nil 1)
	    (replace-match "\\\\\\&" t))
	  ;; ... then undo escaping of matching parentheses,
	  ;; including matching nested parentheses.
	  (goto-char fullname-start)
	  (while (re-search-forward
		  "\\(\\=\\|[^\\]\\(\\\\\\\\\\)*\\)\\\\(\\(\\([^\\]\\|\\\\\\\\\\)*\\)\\\\)"
		  nil 1)
	    (replace-match "\\1(\\3)" t)
	    (goto-char fullname-start)))
	(insert ")")))
      (buffer-string))))

(defun message-make-sender ()
  "Return the \"real\" user address.
This function tries to ignore all user modifications, and
give as trustworthy answer as possible."
  (concat (user-login-name) "@" (system-name)))

(defun message-make-address ()
  "Make the address of the user."
  (or (message-user-mail-address)
      (concat (user-login-name) "@" (message-make-domain))))

(defun message-user-mail-address ()
  "Return the pertinent part of `user-mail-address'."
  (when (and user-mail-address
	     (string-match "@.*\\." user-mail-address))
    (if (string-search " " user-mail-address)
	(nth 1 (mail-extract-address-components user-mail-address))
      user-mail-address)))

(defun message-sendmail-envelope-from ()
  "Return the envelope from."
  (cond ((eq (message--sendmail-envelope-from) 'header)
	 (nth 1 (mail-extract-address-components
		 (message-fetch-field "from"))))
	((stringp (message--sendmail-envelope-from))
	 (message--sendmail-envelope-from))
	(t
	 (message-make-address))))

(defun message-make-fqdn ()
  "Return user's fully qualified domain name."
  (let* ((sysname (system-name))
	 (user-mail (message-user-mail-address))
	 (user-domain
	  (if (and user-mail
		   (string-match "@\\(.*\\)\\'" user-mail))
	      (match-string 1 user-mail)))
	 (case-fold-search t))
    (cond
     ((and message-user-fqdn
	   (stringp message-user-fqdn)
	   (not (string-match message-bogus-system-names message-user-fqdn)))
      ;; `message-user-fqdn' seems to be valid
      message-user-fqdn)
     ;; A system name without any dots is unlikely to be a good fully
     ;; qualified domain name.
     ((and (string-search "." sysname)
	   (not (string-match message-bogus-system-names sysname)))
      ;; `system-name' returned the right result.
      sysname)
     ;; Try `mail-host-address'.
     ((and (stringp mail-host-address)
	   (not (string-match message-bogus-system-names mail-host-address)))
      mail-host-address)
     ;; We try `user-mail-address' as a backup.
     ((and user-domain
	   (stringp user-domain)
	   (not (string-match message-bogus-system-names user-domain)))
      user-domain)
     ;; Default to this bogus thing.
     (t
      (concat sysname ".mail-host-address-is-not-set")))))

(defun message-make-domain ()
  "Return the domain name."
  (or mail-host-address
      (message-make-fqdn)))

(defun message-to-list-only ()
  "Send a message to the list only.
Remove all addresses but the list address from To and Cc headers."
  (interactive nil message-mode)
  (let ((listaddr (message-make-mail-followup-to t)))
    (when listaddr
      (save-excursion
	(message-remove-header "to")
	(message-remove-header "cc")
	(message-position-on-field "To" "X-Draft-From")
	(insert listaddr)))))

(defun message-make-mail-followup-to (&optional only-show-subscribed)
  "Return the Mail-Followup-To header.
If passed the optional argument ONLY-SHOW-SUBSCRIBED only return the
subscribed address (and not the additional To and Cc header contents)."
  (let* ((case-fold-search t)
	 (to (message-fetch-field "To"))
	 (cc (message-fetch-field "cc"))
	 (msg-recipients (concat to (and to cc ", ") cc))
	 (recipients
	  (mapcar #'mail-strip-quoted-names
		  (message-tokenize-header msg-recipients)))
	 (file-regexps
	  (if message-subscribed-address-file
	      (let (begin end item re)
		(save-excursion
		  (with-temp-buffer
		    (insert-file-contents message-subscribed-address-file)
		    (while (not (eobp))
		      (setq begin (point))
		      (forward-line 1)
		      (setq end (point))
		      (if (bolp) (setq end (1- end)))
		      (setq item (regexp-quote (buffer-substring begin end)))
		      (if re (setq re (concat re "\\|" item))
			(setq re (concat "\\`\\(" item))))
		    (and re (list (concat re "\\)\\'"))))))))
	 (mft-regexps (apply #'append message-subscribed-regexps
			     (mapcar #'regexp-quote
				     message-subscribed-addresses)
			     file-regexps
			     (mapcar #'funcall
				     message-subscribed-address-functions))))
    (save-match-data
      (let ((list
	     (cl-loop for recipient in recipients
	              when (cl-loop for regexp in mft-regexps
		                    thereis (string-match regexp recipient))
	              return recipient)))
	(when list
	  (if only-show-subscribed
	      list
	    msg-recipients))))))

(defun message-idna-to-ascii-rhs-1 (header)
  "Interactively potentially IDNA encode domain names in HEADER."
  (let ((field (message-fetch-field header))
        ace)
    (when field
      (dolist (rhs
	       (delete-dups
		(mapcar (lambda (rhs) (or (cadr (split-string rhs "@")) ""))
			(mapcar #'downcase
				(mapcar
				 (lambda (elem)
				   (or (cadr elem)
				       ""))
				 (mail-extract-address-components field t))))))
	;; Note that `rhs' will be "" if the address does not have
	;; the domain part, i.e., if it is a local user's address.
	(setq ace (if (string-match "\\`[[:ascii:]]*\\'" rhs)
		      rhs
		    (downcase (puny-encode-domain rhs))))
	(when (and (not (equal rhs ace))
		   (or (not (eq message-use-idna 'ask))
		       (y-or-n-p (format "Replace %s with %s in %s:? "
					 rhs ace header))))
	  (goto-char (point-min))
	  (while (re-search-forward (concat "^" header ":") nil t)
	    (message-narrow-to-field)
	    (while (search-forward (concat "@" rhs) nil t)
	      (replace-match (concat "@" ace) t t))
	    (goto-char (point-max))
	    (widen)))))))

(defun message-idna-to-ascii-rhs ()
  "Possibly IDNA encode non-ASCII domain names in From:, To: and Cc: headers."
  (interactive nil message-mode)
  (when message-use-idna
    (save-excursion
      (save-restriction
	;; `message-narrow-to-head' that recognizes only the first empty
	;; line as the message header separator used to be used here.
	;; However, since there is the "--text follows this line--" line
	;; normally, it failed in narrowing to the headers and potentially
	;; caused the IDNA encoding on lines that look like headers in
	;; the message body.
	(message-narrow-to-headers-or-head)
	(message-idna-to-ascii-rhs-1 "From")
	(message-idna-to-ascii-rhs-1 "To")
	(message-idna-to-ascii-rhs-1 "Reply-To")
	(message-idna-to-ascii-rhs-1 "Mail-Reply-To")
	(message-idna-to-ascii-rhs-1 "Mail-Followup-To")
	(message-idna-to-ascii-rhs-1 "Cc")))))

(defun message-generate-headers (headers)
  "Prepare article HEADERS.
Headers already prepared in the buffer are not modified."
  (setq headers (append headers message-required-headers))
  (save-restriction
    (message-narrow-to-headers)
    (let* ((header-values
	    (list 'Date (message-make-date)
		  'Message-ID (message-make-message-id)
		  'Organization (message-make-organization)
		  'From (message-make-from)
		  'Path (message-make-path)
		  'Subject nil
		  'Newsgroups nil
		  'In-Reply-To (message-make-in-reply-to)
		  'References (message-make-references)
		  'To nil
		  'Distribution (message-make-distribution)
		  'Lines (message-make-lines)
		  'User-Agent message-newsreader
		  'Expires (message-make-expires)))
	   (case-fold-search t)
	   (optionalp nil)
	   header value elem header-string)
      ;; First we remove any old generated headers.
      (let ((headers message-deletable-headers))
	(unless (buffer-modified-p)
	  (setq headers (delq 'Message-ID (copy-sequence headers))))
	(while headers
	  (goto-char (point-min))
	  (and (re-search-forward
		(concat "^" (symbol-name (car headers)) ": *") nil t)
	       (get-text-property (1+ (match-beginning 0)) 'message-deletable)
	       (delete-line))
	  (pop headers)))
      ;; Go through all the required headers and see if they are in the
      ;; articles already.  If they are not, or are empty, they are
      ;; inserted automatically - except for Subject, Newsgroups and
      ;; Distribution.
      (while headers
	(goto-char (point-min))
	(setq elem (pop headers))
	(if (consp elem)
	    (if (eq (car elem) 'optional)
		(setq header (cdr elem)
		      optionalp t)
	      (setq header (car elem)))
	  (setq header elem))
	(setq header-string  (if (stringp header)
				 header
			       (symbol-name header)))
	(when (or (not (re-search-forward
			(concat "^"
				(regexp-quote (downcase header-string))
				":")
			nil t))
		  (progn
		    ;; The header was found.  We insert a space after the
		    ;; colon, if there is none.
		    (if (/= (char-after) ? ) (insert " ") (forward-char 1))
		    ;; Find out whether the header is empty.
		    (looking-at "[ \t]*\n[^ \t]")))
	  ;; So we find out what value we should insert.
	  (setq value
		(cond
		 ((and (consp elem)
		       (eq (car elem) 'optional)
		       (not (member header-string message-inserted-headers)))
		  ;; This is an optional header.  If the cdr of this
		  ;; is something that is nil, then we do not insert
		  ;; this header.
		  (setq header (cdr elem))
		  (or (and (functionp (cdr elem))
			   (funcall (cdr elem)))
		      (and (symbolp (cdr elem))
			   (plist-get header-values (cdr elem)))))
		 ((consp elem)
		  ;; The element is a cons.  Either the cdr is a
		  ;; string to be inserted verbatim, or it is a
		  ;; function, and we insert the value returned from
		  ;; this function.
		  (or (and (stringp (cdr elem))
			   (cdr elem))
		      (and (functionp (cdr elem))
			   (funcall (cdr elem)))))
		 ((and (symbolp header)
		       (plist-member header-values header))
		  ;; The element is a symbol.  We insert the value of
		  ;; this symbol, if any.
		  (plist-get header-values header))
		 ((not (message-check-element
			(intern (downcase (symbol-name header)))))
		  ;; We couldn't generate a value for this header,
		  ;; so we just ask the user.
		  (read-from-minibuffer
		   (format "Empty header for %s; enter value: " header)))))
	  ;; Finally insert the header.
	  (when (and value
		     (not (equal value "")))
	    (save-excursion
	      (if (bolp)
		  (progn
		    ;; This header didn't exist, so we insert it.
		    (goto-char (point-max))
		    (let ((formatter
			   (cdr (assq header message-header-format-alist))))
		      (if formatter
			  (funcall formatter header value)
			(insert header-string ": " value))
		      (push header-string message-inserted-headers)
		      (goto-char (message-fill-field))
		      ;; We check whether the value was ended by a
		      ;; newline.  If not, we insert one.
		      (unless (bolp)
			(insert "\n"))
		      (forward-line -1)))
		;; The value of this header was empty, so we clear
		;; totally and insert the new value.
                (delete-region (point) (line-end-position))
		;; If the header is optional, and the header was
		;; empty, we can't insert it anyway.
		(unless optionalp
		  (push header-string message-inserted-headers)
		  (insert value)
		  (message-fill-field)))
	      ;; Add the deletable property to the headers that require it.
	      (and (memq header message-deletable-headers)
		   (progn (beginning-of-line) (looking-at "[^:]+: "))
		   (add-text-properties
		    (point) (match-end 0)
		    '(message-deletable t face italic) (current-buffer)))))))
      ;; Insert new Sender if the From is strange.
      (let ((from (message-fetch-field "from"))
	    (sender (message-fetch-field "sender"))
	    (secure-sender (message-make-sender)))
	(when (and from
		   (not (message-check-element 'sender))
		   (not (string=
			 (downcase
			  (cadr (mail-extract-address-components from)))
			 (downcase secure-sender)))
		   (or (null sender)
		       (not
			(string=
			 (downcase
			  (cadr (mail-extract-address-components sender)))
			 (downcase secure-sender)))))
	  (goto-char (point-min))
	  ;; Rename any old Sender headers to Original-Sender.
	  (when (re-search-forward "^\\(Original-\\)*Sender:" nil t)
	    (beginning-of-line)
	    (insert "Original-")
	    (beginning-of-line))
	  (when (or (message-news-p)
		    (string-match "@.+\\.." secure-sender))
	    (insert "Sender: " secure-sender "\n"))))
      ;; Check for IDNA
      (message-idna-to-ascii-rhs))))

(defun message-insert-courtesy-copy (message)
  "Insert a courtesy message in mail copies of combined messages."
  (let (newsgroups)
    (save-excursion
      (save-restriction
	(message-narrow-to-headers)
	(when (setq newsgroups (message-fetch-field "newsgroups"))
	  (goto-char (point-max))
	  (insert "Posted-To: " newsgroups "\n")))
      (forward-line 1)
      (when message
	(cond
	 ((string-match "%s" message)
	  (insert (format message newsgroups)))
	 (t
	  (insert message)))))))

;;;
;;; Setting up a message buffer
;;;

(defun message-skip-to-next-address ()
  (let ((end (save-excursion
	       (message-next-header)
	       (point)))
	quoted char)
    (when (looking-at ",")
      (forward-char 1))
    (while (and (not (= (point) end))
		(or (not (eq char ?,))
		    quoted))
      (skip-chars-forward "^,\"" end)
      (when (eq (setq char (following-char)) ?\")
	(setq quoted (not quoted)))
      (unless (= (point) end)
	(forward-char 1)))
    (skip-chars-forward " \t\n")))

(defun message-split-line ()
  "Split current line, moving portion beyond point vertically down.
If the current line has `message-yank-prefix', insert it on the new line."
  (interactive "*" message-mode)
  (split-line message-yank-prefix))

(defun message-insert-header (header value)
  (insert (capitalize (symbol-name header))
	  ": "
	  (if (consp value) (car value) value)))

(defun message-field-name ()
  (save-excursion
    (goto-char (point-min))
    (when (looking-at "\\([^:]+\\):")
      (intern (capitalize (match-string 1))))))

(defun message-fill-field ()
  (save-excursion
    (save-restriction
      (message-narrow-to-field)
      (let ((field-name (message-field-name)))
	(funcall (or (cadr (assq field-name message-field-fillers))
		     'message-fill-field-general)))
      (point-max))))

(defun message-fill-field-address ()
  (let (end last)
    (while (not end)
      (message-skip-to-next-address)
      (cond ((bolp)
	     (end-of-line 0)
	     (setq end 1))
	    ((eobp)
	     (setq end 0)))
      (when (and (> (current-column) 78)
		 last)
	(save-excursion
	  (goto-char last)
	  (delete-char (- (skip-chars-backward " \t")))
	  (insert "\n\t")))
      (setq last (point)))
    (forward-line end)))

(defun message-fill-field-general ()
  (let ((begin (point))
	(fill-column 78)
	(fill-prefix "\t"))
    (while (and (search-forward "\n" nil t)
		(not (eobp)))
      (replace-match " " t t))
    (fill-region-as-paragraph begin (point-max))
    ;; Tapdance around looong Message-IDs.
    (forward-line -1)
    (when (looking-at "[ \t]*$")
      (delete-line))
    (goto-char begin)
    (search-forward ":" nil t)
    (when (looking-at "\n[ \t]+")
      (replace-match " " t t))
    (goto-char (point-max))))

(defun message-shorten-1 (list cut surplus)
  "Cut SURPLUS elements out of LIST, beginning with CUTth one."
  (setcdr (nthcdr (- cut 2) list)
	  (nthcdr (+ (- cut 2) surplus 1) list)))

(defun message-shorten-references (header references)
  "Trim REFERENCES to be 21 Message-ID long or less, and fold them.
When sending via news, also check that the REFERENCES are less
than 988 characters long, and if they are not, trim them until
they are."
  ;; 21 is the number suggested by USAGE.
  (let ((maxcount 21)
	(count 0)
	(cut 2)
	refs)
    (with-temp-buffer
      (insert references)
      (goto-char (point-min))
      ;; Cons a list of valid references.  GNKSA says we must not include MIDs
      ;; with whitespace or missing brackets (7.a "Does not propagate broken
      ;; Message-IDs in original References").
      (while (re-search-forward "<[^ <]+@[^ <]+>" nil t)
	(push (match-string 0) refs))
      (setq refs (nreverse refs)
	    count (length refs)))

    ;; If the list has more than MAXCOUNT elements, trim it by
    ;; removing the CUTth element and the required number of
    ;; elements that follow.
    (when (> count maxcount)
      (let ((surplus (- count maxcount)))
	(message-shorten-1 refs cut surplus)
        (decf count surplus)))

    ;; When sending via news, make sure the total folded length will
    ;; be less than 998 characters.  This is to cater to broken INN
    ;; 2.3 which counts the total number of characters in a header
    ;; rather than the physical line length of each line, as it should.
    ;;
    ;; This hack should be removed when it's believed than INN 2.3 is
    ;; no longer widely used.
    ;;
    ;; At this point the headers have not been generated, thus we use
    ;; message-this-is-news directly.
    (when message-this-is-news
      (while (< 998
		(with-temp-buffer
		  (message-insert-header
		   header (mapconcat #'identity refs " "))
		  (buffer-size)))
	(message-shorten-1 refs cut 1)))
    ;; Finally, collect the references back into a string and insert
    ;; it into the buffer.
    (message-insert-header header (mapconcat #'identity refs " "))))

(defun message-position-point ()
  "Move point to where the user probably wants to find it."
  (message-narrow-to-headers)
  (cond
   ((re-search-forward "^[^:]+:[ \t]*$" nil t)
    (search-backward ":" )
    (widen)
    (forward-char 1)
    (if (eq (char-after) ? )
	(forward-char 1)
      (insert " ")))
   (t
    (goto-char (point-max))
    (widen)
    (forward-line 1)
    (unless (looking-at "$")
      (forward-line 2))))
  (sit-for 0))

(defcustom message-beginning-of-line t
  "Whether \\<message-mode-map>\\[message-beginning-of-line] goes to beginning of header values."
  :version "22.1"
  :group 'message-buffers
  :link '(custom-manual "(message)Movement")
  :type 'boolean)

(defvar visual-line-mode)
(declare-function beginning-of-visual-line "simple" (&optional n))

(defun message-beginning-of-header (handle-folded)
  "Move point to beginning of header's value.

When point is at the first header line, moves it after the colon
and spaces separating header name and header value.

When point is in a continuation line of a folded header (i.e. the
line starts with a space), the behavior depends on HANDLE-FOLDED
argument.  If it's nil, function moves the point to the start of
the header continuation; otherwise, function locates the
beginning of the header and moves point past the colon as is the
case of single-line headers.

No check whether point is inside of a header or body of the
message is performed.

Returns point or nil if beginning of header's value could not be
found.  In the latter case, the point is still moved to the
beginning of line (possibly after attempting to move it to the
beginning of a folded header)."
  ;; https://www.rfc-editor.org/rfc/rfc2822.txt, section 2.2.3. says that when
  ;; unfolding a single WSP should be consumed.  WSP is defined as a space
  ;; character or a horizontal tab.
  (beginning-of-line)
  (when handle-folded
    (while (and (> (point) (point-min))
                (or (eq (char-after) ?\s) (eq (char-after) ?\t)))
      (beginning-of-line 0)))
  (when (or (eq (char-after) ?\s) (eq (char-after) ?\t)
            (search-forward ":" (line-end-position) t))
    ;; We are a bit more lacks than the RFC and allow any positive number of WSP
    ;; characters.
    (skip-chars-forward " \t" (line-end-position))
    (point)))

(defun message-beginning-of-line (&optional n)
  "Move point to beginning of header value or to beginning of line.
The prefix argument N is passed directly to `beginning-of-line'.

This command is identical to `beginning-of-line' if point is
outside the message header or if the option
`message-beginning-of-line' is nil.

If point is in the message header and on a header line, move
point to the beginning of the header value or the beginning of
line, whichever is closer.  If point is already at beginning of
line, move point to beginning of header value.  Therefore,
repeated calls will toggle point between beginning of field and
beginning of line.

When called without a prefix argument, header value spanning
multiple lines is treated as a single line.  Otherwise, even if
N is 1, when point is on a continuation header line, it will be
moved to the beginning."
  (interactive "^p" message-mode)
  (cond
   ;; Go to beginning of header or beginning of line.
   ((and message-beginning-of-line (message-point-in-header-p))
    (let* ((point (point))
           (bol (progn (beginning-of-line n) (point)))
           (boh (message-beginning-of-header visual-line-mode)))
      (goto-char (if (and boh (or (< boh point) (= bol point))) boh bol))))
   ;; Go to beginning of visual line
   (visual-line-mode
    (beginning-of-visual-line n))
   ;; Go to beginning of line.
   ((beginning-of-line n))))

(defun message-buffer-name (type &optional to group)
  "Return a new (unique) buffer name based on TYPE and TO."
  (cond
   ;; Generate a new buffer name The Message Way.
   ((memq message-generate-new-buffers '(unique t))
    (generate-new-buffer-name
     (concat "*" type
	     (if to
		 (concat " to "
			 (or (car (mail-extract-address-components to))
			     to))
	       "")
	     (if (and group (not (string= group ""))) (concat " on " group) "")
	     "*")))
   ;; Check whether `message-generate-new-buffers' is a function,
   ;; and if so, call it.
   ((functionp message-generate-new-buffers)
    (funcall message-generate-new-buffers type to group))
   ((eq message-generate-new-buffers 'unsent)
    (generate-new-buffer-name
     (concat "*unsent " type
	     (if to
		 (concat " to "
			 (or (car (mail-extract-address-components to))
			     to))
	       "")
	     (if (and group (not (string= group ""))) (concat " on " group) "")
	     "*")))
   ;; Search for the existing message buffer with the specified name.
   (t
    (let* ((new (if (eq message-generate-new-buffers 'standard)
		    (generate-new-buffer-name (concat "*" type " message*"))
		  (let ((message-generate-new-buffers 'unique))
		    (message-buffer-name type to group))))
	   (regexp (concat "\\`"
			   (regexp-quote
			    (if (string-match "<[0-9]+>\\'" new)
				(substring new 0 (match-beginning 0))
			      new))
			   "\\(?:<\\([0-9]+\\)>\\)?\\'"))
	   (case-fold-search nil))
      (or (cdar
	   (last
	    (sort
	     (delq nil
		   (mapcar
		    (lambda (b)
		      (when (and (string-match regexp (setq b (buffer-name b)))
				 (eq (with-current-buffer b major-mode)
				     'message-mode))
			(cons (string-to-number (or (match-string 1 b) "1"))
			      b)))
		    (buffer-list)))
	     #'car-less-than-car)))
	  new)))))

(defun message-pop-to-buffer (name &optional switch-function)
  "Pop to buffer NAME, and warn if it already exists and is modified."
  (let ((buffer (get-buffer name)))
    (if (buffer-live-p buffer)
	(let ((window (get-buffer-window buffer 0)))
	  (if window
	      ;; Raise the frame already displaying the message buffer.
	      (progn
		(select-frame-set-input-focus (window-frame window))
		(select-window window))
	    (funcall (or switch-function #'pop-to-buffer) buffer)
	    (set-buffer buffer))
	  (when (and (buffer-modified-p)
		     (not (prog1
			      (y-or-n-p
			       "Message already being composed; erase? ")
			    (message nil))))
	    (error "Message being composed")))
      (funcall (or switch-function 'pop-to-buffer-same-window)
	       name)
      (set-buffer name))
    (erase-buffer)
    (message-mode)))

(defun message-do-send-housekeeping ()
  "Kill old message buffers."
  ;; We might have sent this buffer already.  Delete it from the
  ;; list of buffers.
  (setq message-buffer-list (delq (current-buffer) message-buffer-list))
  (while (and message-max-buffers
	      message-buffer-list
	      (>= (length message-buffer-list) message-max-buffers))
    ;; Kill the oldest buffer -- unless it has been changed.
    (let ((buffer (pop message-buffer-list)))
      (when (and (buffer-live-p buffer)
		 (not (buffer-modified-p buffer)))
	(kill-buffer buffer))))
  ;; Rename the buffer.
  (funcall (or message-send-rename-function
               #'message-default-send-rename-function))
  ;; Push the current buffer onto the list.
  (when message-max-buffers
    (setq message-buffer-list
	  (nconc message-buffer-list (list (current-buffer))))))

(defun message-default-send-rename-function ()
  ;; Note: mail-abbrevs of XEmacs renames buffer name behind Gnus.
  (when (string-match
	 "\\`\\*\\(sent \\|unsent \\)?\\(.+\\)\\*[^\\*]*\\|\\`mail to "
	 (buffer-name))
    (let ((name (match-string 2 (buffer-name)))
	  to group)
      (if (not (or (null name)
		   (string-equal name "mail")
		   (string-equal name "posting")))
	  (setq name (concat "*sent " name "*"))
	(message-narrow-to-headers)
	(setq to (message-fetch-field "to"))
	(setq group (message-fetch-field "newsgroups"))
	(widen)
	(setq name
	      (cond
	       (to (concat "*sent mail to "
			   (or (car (mail-extract-address-components to))
			       to) "*"))
	       ((and group (not (string= group "")))
		(concat "*sent posting on " group "*"))
	       (t "*sent mail*"))))
      (unless (string-equal name (buffer-name))
	(rename-buffer name t)))))

(defun message-mail-user-agent ()
  (let ((mua (cond
	      ((not message-mail-user-agent) nil)
	      ((eq message-mail-user-agent t) mail-user-agent)
	      (t message-mail-user-agent))))
    (if (memq mua '(message-user-agent gnus-user-agent))
	nil
      mua)))

;; YANK-ACTION, if non-nil, can be a buffer or a yank action of the
;; form (FUNCTION . ARGS).
(defun message-setup (headers &optional yank-action actions
			      continue switch-function return-action)
  (let ((mua (message-mail-user-agent))
	subject to field)
    (if (not (and message-this-is-mail mua))
	(message-setup-1 headers yank-action actions return-action)
      (setq headers (copy-sequence headers))
      (setq field (assq 'Subject headers))
      (when field
	(setq subject (cdr field))
	(setq headers (delq field headers)))
      (setq field (assq 'To headers))
      (when field
	(setq to (cdr field))
	(setq headers (delq field headers)))
      (let ((mail-user-agent mua))
	(compose-mail to subject
		      (mapcar (lambda (item)
				(cons
				 (format "%s" (car item))
				 (cdr item)))
			      headers)
		      continue switch-function
		      (if (bufferp yank-action)
			  (list 'insert-buffer yank-action)
			yank-action)
		      actions)))))

(defun message-headers-to-generate (headers included-headers excluded-headers)
  "Return a list that includes all headers from HEADERS.
If INCLUDED-HEADERS is a list, just include those headers.  If it is
t, include all headers.  In any case, headers from EXCLUDED-HEADERS
are not included."
  (let ((result nil)
	header-name)
    (dolist (header headers)
      (setq header-name (cond
			 ((and (consp header)
			       (eq (car header) 'optional))
			  ;; On the form (optional . Header)
			  (cdr header))
			 ((consp header)
			  ;; On the form (Header . function)
			  (car header))
			 (t
			  ;; Just a Header.
			  header)))
      (when (and (not (memq header-name excluded-headers))
		 (or (eq included-headers t)
		     (memq header-name included-headers)))
	(push header result)))
    (nreverse result)))

(defun message-setup-1 (headers &optional yank-action actions return-action)
  (dolist (action actions)
    ;; FIXME: Use functions rather than expressions!
    (add-to-list 'message-send-actions
		 `(apply #',(car action) ',(cdr action))))
  (setq message-return-action return-action)
  (setq message-reply-buffer
	(if (and (consp yank-action)
		 (eq (car yank-action) 'insert-buffer))
	    (nth 1 yank-action)
	  yank-action))
  (goto-char (point-min))
  ;; Insert all the headers.
  (mail-header-format
   (let ((h headers)
	 (alist message-header-format-alist))
     (while h
       (unless (assq (caar h) message-header-format-alist)
	 (push (list (caar h)) alist))
       (pop h))
     alist)
   headers)
  (delete-region (point) (progn (forward-line -1) (point)))
  (when message-default-headers
    (insert
     (if (functionp message-default-headers)
         (funcall message-default-headers)
       message-default-headers))
    (or (bolp) (insert ?\n)))
  (insert (concat mail-header-separator "\n"))
  (forward-line -1)
  ;; If a crash happens while replying, the auto-save file would *not*
  ;; have a `References:' header if `message-generate-headers-first'
  ;; was nil.  Therefore, always generate it first.  (And why not
  ;; include the `In-Reply-To' header as well.)
  (let ((message-generate-headers-first
         (if (eq message-generate-headers-first t)
             t
           (append message-generate-headers-first '(References In-Reply-To)))))
    (when (message-news-p)
      (when message-default-news-headers
        (insert message-default-news-headers)
        (or (bolp) (insert ?\n)))
      (message-generate-headers
       (message-headers-to-generate
        (append message-required-news-headers
                message-required-headers)
        message-generate-headers-first
        '(Lines Subject))))
    (when (message-mail-p)
      (when message-default-mail-headers
        (insert message-default-mail-headers)
        (or (bolp) (insert ?\n)))
      (message-generate-headers
       (message-headers-to-generate
        (append message-required-mail-headers
                message-required-headers)
        message-generate-headers-first
        '(Lines Subject)))))
  (run-hooks 'message-signature-setup-hook)
  (message-insert-signature)
  (save-restriction
    (message-narrow-to-headers)
    (run-hooks 'message-header-setup-hook))
  (setq buffer-undo-list nil)
  ;; Gnus posting styles are applied via buffer-local `message-setup-hook'
  ;; values.
  (run-hooks 'message-setup-hook)
  ;; Do this last to give it precedence over posting styles, etc.
  (when (message-mail-p)
    (save-restriction
      (message-narrow-to-headers)
      (if message-alternative-emails
	  (message-use-alternative-email-as-from))))
  (message-position-point)
  ;; Allow correct handling of `message-checksum' in `message-yank-original':
  (set-buffer-modified-p nil)
  (undo-boundary)
  ;; rmail-start-mail expects message-mail to return t (Bug#9392)
  t)

(defun message-set-auto-save-file-name ()
  "Associate the message buffer with a file in the drafts directory."
  (when message-auto-save-directory
    (unless (file-directory-p
	     (directory-file-name message-auto-save-directory))
      (make-directory message-auto-save-directory t))
    (if (gnus-alive-p)
	(setq message-draft-article
	      (nndraft-request-associate-buffer "drafts"))

      ;; If Gnus were alive, draft messages would be saved in the drafts folder.
      ;; But Gnus is not alive, so arrange to save the draft message in a
      ;; regular file in message-auto-save-directory.  Append a unique
      ;; time-based suffix to the filename to allow multiple drafts to be saved
      ;; simultaneously without overwriting each other (which mimics the
      ;; functionality of the Gnus drafts folder).
      (setq buffer-file-name (expand-file-name
			      (concat
			      (if (memq system-type
					'(ms-dos windows-nt cygwin))
				  "message"
				"*message*")
			       (format-time-string "-%Y%m%d-%H%M%S"))
			      message-auto-save-directory))
      (setq buffer-auto-save-file-name (make-auto-save-file-name)))
    (clear-visited-file-modtime)
    (setq buffer-file-coding-system message-draft-coding-system)))

(defun message-disassociate-draft ()
  "Disassociate the message buffer from the drafts directory."
  (when message-draft-article
    (nndraft-request-expire-articles
     (list message-draft-article) "drafts" nil t)))

(defun message-insert-headers ()
  "Generate the headers for the article."
  (interactive nil message-mode)
  (save-excursion
    (save-restriction
      (message-narrow-to-headers)
      (when (message-news-p)
	(message-generate-headers
	 (delq 'Lines
	       (delq 'Subject
		     (copy-sequence message-required-news-headers)))))
      (when (message-mail-p)
	(message-generate-headers
	 (delq 'Lines
	       (delq 'Subject
		     (copy-sequence message-required-mail-headers))))))))



;;;
;;; Commands for interfacing with message
;;;

;;;###autoload
(defun message-mail (&optional to subject other-headers continue
			       switch-function yank-action send-actions
			       return-action &rest _)
  "Start editing a mail message to be sent.
OTHER-HEADERS is an alist of header/value pairs.  CONTINUE says whether
to continue editing a message already being composed.  SWITCH-FUNCTION
is a function used to switch to and display the mail buffer."
  (interactive)
  (let ((message-this-is-mail t)
	message-buffers)
    ;; Search for the existing message buffer if `continue' is non-nil.
    (if (and continue
	     (setq message-buffers (message-buffers)))
	(pop-to-buffer (car message-buffers))
      ;; Start a new buffer.
      (unless (message-mail-user-agent)
	(message-pop-to-buffer (message-buffer-name "mail" to) switch-function))
      (message-setup
       (nconc
	`((To . ,(or to "")) (Subject . ,(or subject "")))
	;; C-h f compose-mail says that headers should be specified as
	;; (string . value); however all the rest of message expects
	;; headers to be symbols, not strings (eg message-header-format-alist).
	;; https://lists.gnu.org/r/emacs-devel/2011-01/msg00337.html
	;; We need to convert any string input, eg from rmail-start-mail.
	(dolist (h other-headers other-headers)
	  (when (stringp (car h))
            (setcar h (intern (capitalize (car h)))))
          ;; Firefox sends us In-Reply-To headers that are Message-IDs
          ;; without <> around them.  Fix that.
          (when (and (eq (car h) 'In-Reply-To)
                     (stringp (cdr h))
                     ;; Looks like a Message-ID.
                     (string-match-p "\\`[^ @]+@[^ @]+\\'" (cdr h))
                     (not (string-match-p "\\`<.*>\\'" (cdr h))))
            (setcdr h (concat "<" (cdr h) ">")))))
       yank-action send-actions continue switch-function
       return-action))))

;;;###autoload
(defun message-news (&optional newsgroups subject)
  "Start editing a news article to be sent."
  (interactive)
  (let ((message-this-is-news t))
    (message-pop-to-buffer (message-buffer-name "posting" nil newsgroups))
    (message-setup `((Newsgroups . ,(or newsgroups ""))
		     (Subject . ,(or subject ""))))))

(defun message-alter-recipients-discard-bogus-full-name (addrcell)
  "Discard mail address in full names.
When the full name in reply headers contains the mail
address (e.g. \"foo@bar <foo@bar>\"), discard full name.
ADDRCELL is a cons cell where the car is the mail address and the
cdr is the complete address (full name and mail address)."
  (if (string-match (concat (regexp-quote (car addrcell)) ".*"
			    (regexp-quote (car addrcell)))
		    (cdr addrcell))
      (cons (car addrcell) (car addrcell))
    addrcell))

(defcustom message-alter-recipients-function nil
  "Function called to allow alteration of reply header structures.
It is called in `message-get-reply-headers' for each recipient.
The function is called with one parameter, a cons cell ..."
  :type '(choice (const :tag "None" nil)
		 (const :tag "Discard bogus full name"
			message-alter-recipients-discard-bogus-full-name)
		 function)
  :version "23.1" ;; No Gnus
  :group 'message-headers)

(defun message-get-reply-headers (wide &optional to-address address-headers)
  (let (follow-to mct never-mct to cc author mft recipients extra)
    ;; Find all relevant headers we need.
    (save-restriction
      (message-narrow-to-headers-or-head)
      ;; Gmane renames "To".  Look at "Original-To", too, if it is present in
      ;; message-header-synonyms.
      (setq to (or (message-fetch-field "to")
		   (and (cl-loop for synonym in message-header-synonyms
			         when (memq 'Original-To synonym)
			         return t)
			(message-fetch-field "original-to")))
	    cc (message-fetch-field "cc")
	    extra (when message-extra-wide-headers
		    (mapconcat #'identity
			       (mapcar #'message-fetch-field
				       message-extra-wide-headers)
			       ", "))
	    mct (message-fetch-field "mail-copies-to")
	    author (or (message-fetch-field "mail-reply-to")
		       (message-fetch-field "reply-to"))
	    mft (and message-use-mail-followup-to
		     (message-fetch-field "mail-followup-to")))
      ;; Make sure this message goes to the author if this is a wide
      ;; reply, since Reply-To address may be a list address a mailing
      ;; list server added.
      (when (and wide author)
	(setq cc (concat author ", " cc)))
      (when (or wide (not author))
	(setq author (or (message-fetch-field "from") ""))))

    ;; Handle special values of Mail-Copies-To.
    (when mct
      (cond ((or (equal (downcase mct) "never")
		 (equal (downcase mct) "nobody"))
	     (setq never-mct t)
	     (setq mct nil))
	    ((or (equal (downcase mct) "always")
		 (equal (downcase mct) "poster"))
	     (setq mct author))))

    (save-match-data
      ;; Build (textual) list of new recipient addresses.
      (cond
       (to-address
	(setq recipients (concat ", " to-address))
	;; If the author explicitly asked for a copy, we don't deny it to them.
	(if mct (setq recipients (concat recipients ", " mct))))
       ((not wide)
	(setq recipients (concat ", " author)))
       (address-headers
	(dolist (header address-headers)
	  (let ((value (message-fetch-field header)))
	    (when value
	      (setq recipients (concat recipients ", " value))))))
       ((and mft
	     (string-match "[^ \t,]" mft)
	     (or (not (eq message-use-mail-followup-to 'ask))
		 (message-y-or-n-p "Obey Mail-Followup-To? " t "\
You should normally obey the Mail-Followup-To: header.  In this
article, it has the value of

" mft "

which directs your response to " (if (string-search "," mft)
				     "the specified addresses"
				   "that address only") ".

Most commonly, Mail-Followup-To is used by a mailing list poster to
express that responses should be sent to just the list, and not the
poster as well.

If a message is posted to several mailing lists, Mail-Followup-To may
also be used to direct the following discussion to one list only,
because discussions that are spread over several lists tend to be
fragmented and very difficult to follow.

Also, some source/announcement lists are not intended for discussion;
responses here are directed to other addresses.

You may customize the variable `message-use-mail-followup-to', if you
want to get rid of this query permanently.")))
	(setq recipients (concat ", " mft)))
       (t
	(setq recipients (if never-mct "" (concat ", " author)))
	(if to (setq recipients (concat recipients ", " to)))
	(if cc (setq recipients (concat recipients ", " cc)))
	(if extra (setq recipients (concat recipients ", " extra)))
	(if mct (setq recipients (concat recipients ", " mct)))))
      (if (>= (length recipients) 2)
	  ;; Strip the leading ", ".
	  (setq recipients (substring recipients 2)))
      ;; Squeeze whitespace.
      (while (string-match "[ \t][ \t]+" recipients)
	(setq recipients (replace-match " " t t recipients)))
      ;; Remove addresses that match `message-dont-reply-to-names'.
      (setq recipients
            (cond ((functionp message-dont-reply-to-names)
                   (mapconcat
                    #'identity
                    (delq nil
                          (mapcar (lambda (mail)
                                    (unless (funcall message-dont-reply-to-names
                                                     (mail-strip-quoted-names mail))
                                      mail))
                                  (message-tokenize-header recipients)))
                    ", "))
                  (t (let ((mail-dont-reply-to-names (message-dont-reply-to-names)))
                       (mail-dont-reply-to recipients)))))
      ;; Perhaps "Mail-Copies-To: never" removed the only address?
      (if (string-equal recipients "")
	  (setq recipients author))
      ;; Convert string to a list of (("foo@bar" . "Name <Foo@BAR>") ...).
      (setq recipients
	    (mapcar
	     (lambda (addr)
	       (if message-alter-recipients-function
		   (funcall message-alter-recipients-function
			    (cons (downcase (mail-strip-quoted-names addr))
				  addr))
		 (cons (downcase (mail-strip-quoted-names addr)) addr)))
	     (message-tokenize-header recipients)))
      ;; Remove all duplicates.
      (let ((s recipients))
	(while s
	  (let ((address (car (pop s))))
	    (while (assoc address s)
	      (setq recipients (delq (assoc address s) recipients)
		    s (delq (assoc address s) s))))))

      ;; Remove hierarchical lists that are contained within each other,
      ;; if message-hierarchical-addresses is defined.
      (when message-hierarchical-addresses
	(let ((plain-addrs (mapcar #'car recipients))
	      subaddrs recip)
	  (while plain-addrs
	    (setq subaddrs (assoc (car plain-addrs)
				  message-hierarchical-addresses)
		  plain-addrs (cdr plain-addrs))
	    (when subaddrs
	      (setq subaddrs (cdr subaddrs))
	      (while subaddrs
		(setq recip (assoc (car subaddrs) recipients)
		      subaddrs (cdr subaddrs))
		(if recip
		    (setq recipients (delq recip recipients))))))))

      (setq recipients (message-prune-recipients recipients))
      (setq recipients
	    (cl-loop for (id . address) in recipients
		     collect (cons id (message--alter-repeat-address address))))

      ;; Build the header alist.  Allow the user to be asked whether
      ;; or not to reply to all recipients in a wide reply.
      (when (or (< (length recipients) 2)
		(not message-wide-reply-confirm-recipients)
		(y-or-n-p "Reply to all recipients? "))
	(if never-mct
	    ;; The author has requested never to get a (wide)
	    ;; response, so put everybody else into the To header.
	    ;; This avoids looking as if we're To-in somebody else in
	    ;; specific, and just Cc-in the rest.
	    (setq follow-to (list
			     (cons 'To
				   (mapconcat #'cdr recipients ", "))))
	  ;; Put the first recipient in the To header.
	  (setq follow-to (list (cons 'To (cdr (pop recipients)))))
	  ;; Put the rest of the recipients in Cc.
	  (when recipients
	    (setq recipients (mapconcat #'cdr recipients ", "))
	    (if (string-match "^ +" recipients)
		(setq recipients (substring recipients (match-end 0))))
	    (push (cons 'Cc recipients) follow-to)))))
    follow-to))

(defun message-prune-recipients (recipients)
  (dolist (rule message-prune-recipient-rules)
    (let ((match (car rule))
	  dup-match
	  address)
      (dolist (recipient recipients)
	(setq address (car recipient))
	(when (string-match match address)
	  (setq dup-match (replace-match (cadr rule) nil nil address))
	  (dolist (recipient recipients)
	    ;; Don't delete the address that triggered this.
	    (when (and (not (eq address (car recipient)))
		       (string-match dup-match (car recipient)))
	      (setq recipients (delq recipient recipients))))))))
  recipients)

(defun message--alter-repeat-address (address)
  "Transform an address on the form \"\"foo@bar.com\"\" <foo@bar.com>\".
The first bit will be elided if a match is made."
  (let ((bits (gnus-extract-address-components address)))
    (if (equal (car bits) (cadr bits))
	(car bits)
      ;; Return the original address if we don't have repetition.
      address)))

(defcustom message-simplify-subject-functions
  '(message-strip-list-identifiers
    message-strip-subject-re
    message-strip-subject-trailing-was
    message-strip-subject-encoded-words)
  "List of functions taking a string argument that simplify subjects.
The functions are applied when replying to a message.

Useful functions to put in this list include:
`message-strip-list-identifiers', `message-strip-subject-re',
`message-strip-subject-trailing-was', and
`message-strip-subject-encoded-words'."
  :version "22.1" ;; Gnus 5.10.9
  :group 'message-various
  :type '(repeat function))

(defun message-simplify-subject (subject &optional functions)
  "Return simplified SUBJECT.
Do so by calling each one-argument function in the list of functions
specified by FUNCTIONS, if non-nil, or by the variable
`message-simplify-subject-functions' otherwise."
  (dolist (fun (or functions message-simplify-subject-functions) subject)
    (setq subject (funcall fun subject))))

;;;###autoload
(defun message-reply (&optional to-address wide switch-function)
  "Start editing a reply to the article in the current buffer."
  (interactive)
  (require 'gnus-sum)			; for gnus-list-identifiers
  (let ((cur (current-buffer))
	from subject date
	references message-id follow-to
	(message-this-is-mail t)
	gnus-warning)
    (save-restriction
      (message-narrow-to-head-1)
      ;; Allow customizations to have their say.
      (if (not wide)
	  ;; This is a regular reply.
	  (when (functionp message-reply-to-function)
	    (save-excursion
	      (setq follow-to (funcall message-reply-to-function))))
	;; This is a followup.
	(when (functionp message-wide-reply-to-function)
	  (save-excursion
	    (setq follow-to
		  (funcall message-wide-reply-to-function)))))
      (setq message-id (message-fetch-field "message-id" t)
	    references (message-fetch-field "references")
	    date (message-fetch-field "date")
	    from (or (message-fetch-field "from") "nobody")
	    subject (or (message-fetch-field "subject") "none"))

      ;; Strip list identifiers, "Re: ", and "was:"
      (setq subject (concat "Re: " (message-simplify-subject subject)))

      (when (and (setq gnus-warning (message-fetch-field "gnus-warning"))
		 (string-match "<[^>]+>" gnus-warning))
	(setq message-id (match-string 0 gnus-warning)))

      (unless follow-to
	(setq follow-to (message-get-reply-headers wide to-address))))

    (let ((headers
	   `((Subject . ,subject)
	     ,@follow-to)))
      (unless (message-mail-user-agent)
	(message-pop-to-buffer
	 (message-buffer-name
	  (if wide "wide reply" "reply") from
	  (if wide to-address nil))
	 switch-function))
      (setq message-reply-headers
	    (make-full-mail-header 0 (cdr (assq 'Subject headers))
		                   from date message-id references 0 0 ""))
      (message-setup headers cur))))

;;;###autoload
(defun message-wide-reply (&optional to-address)
  "Make a \"wide\" reply to the message in the current buffer."
  (interactive)
  (message-reply to-address t))

;;;###autoload
(defun message-followup (&optional to-newsgroups)
  "Follow up to the message in the current buffer.
If TO-NEWSGROUPS, use that as the new Newsgroups line."
  (interactive)
  (require 'gnus-sum)			; for gnus-list-identifiers
  (let ((cur (current-buffer))
	from subject date reply-to mrt mct
	references message-id follow-to
	(message-this-is-news t)
	followup-to distribution newsgroups gnus-warning posted-to)
    (save-restriction
      (narrow-to-region
       (goto-char (point-min))
       (if (search-forward "\n\n" nil t)
	   (1- (point))
	 (point-max)))
      (when (functionp message-followup-to-function)
	(setq follow-to
	      (funcall message-followup-to-function)))
      (setq from (message-fetch-field "from")
	    date (message-fetch-field "date")
	    subject (or (message-fetch-field "subject") "none")
	    references (message-fetch-field "references")
	    message-id (message-fetch-field "message-id" t)
	    followup-to (message-fetch-field "followup-to")
	    newsgroups (message-fetch-field "newsgroups")
	    posted-to (message-fetch-field "posted-to")
	    reply-to (message-fetch-field "reply-to")
	    mrt (message-fetch-field "mail-reply-to")
	    distribution (message-fetch-field "distribution")
	    mct (message-fetch-field "mail-copies-to"))
      (when (and (setq gnus-warning (message-fetch-field "gnus-warning"))
		 (string-match "<[^>]+>" gnus-warning))
	(setq message-id (match-string 0 gnus-warning)))
      ;; Remove bogus distribution.
      (when (and (stringp distribution)
		 (let ((case-fold-search t))
		   (string-match "world" distribution)))
	(setq distribution nil))
      ;; Strip list identifiers, "Re: ", and "was:"
      (setq subject (concat "Re: " (message-simplify-subject subject)))
      (widen))

    (message-pop-to-buffer (message-buffer-name "followup" from newsgroups))

    (setq message-reply-headers
	  (make-full-mail-header
           0 subject from date message-id references 0 0 ""))

    (message-setup
     `((Subject . ,subject)
       ,@(cond
	  (to-newsgroups
	   (list (cons 'Newsgroups to-newsgroups)))
	  (follow-to follow-to)
	  ((and followup-to message-use-followup-to)
	   (list
	    (cond
	     ((equal (downcase followup-to) "poster")
	      (if (or (eq message-use-followup-to 'use)
		      (message-y-or-n-p "Obey Followup-To: poster? " t "\
You should normally obey the Followup-To: header.

`Followup-To: poster' sends your response via e-mail instead of news.

A typical situation where `Followup-To: poster' is used is when the poster
does not read the newsgroup, so he wouldn't see any replies sent to it.

You may customize the variable `message-use-followup-to', if you
want to get rid of this query permanently."))
		  (progn
		    (setq message-this-is-news nil)
		    (cons 'To (or mrt reply-to from "")))
		(cons 'Newsgroups newsgroups)))
	     (t
	      (if (or (equal followup-to newsgroups)
		      (not (eq message-use-followup-to 'ask))
		      (message-y-or-n-p
		       (concat "Obey Followup-To: " followup-to "? ") t "\
You should normally obey the Followup-To: header.

	`Followup-To: " followup-to "'
directs your response to " (if (string-search "," followup-to)
			       "the specified newsgroups"
			     "that newsgroup only") ".

If a message is posted to several newsgroups, Followup-To is often
used to direct the following discussion to one newsgroup only,
because discussions that are spread over several newsgroup tend to
be fragmented and very difficult to follow.

Also, some source/announcement newsgroups are not intended for discussion;
responses here are directed to other newsgroups.

You may customize the variable `message-use-followup-to', if you
want to get rid of this query permanently."))
		  (cons 'Newsgroups followup-to)
		(cons 'Newsgroups newsgroups))))))
	  (posted-to
	   `((Newsgroups . ,posted-to)))
	  (t
	   `((Newsgroups . ,newsgroups))))
       ,@(and distribution (list (cons 'Distribution distribution)))
       ,@(when (and mct
		    (not (or (equal (downcase mct) "never")
			     (equal (downcase mct) "nobody"))))
	   (list (cons 'Cc (if (or (equal (downcase mct) "always")
				   (equal (downcase mct) "poster"))
			       (or mrt reply-to from "")
			     mct)))))

     cur)))

(defun message-is-yours-p ()
  "Non-nil means current article is yours.
If you have added `cancel-messages' to `message-shoot-gnksa-feet', all articles
are yours except those that have Cancel-Lock header not belonging to you.
Instead of shooting GNKSA feet, you should modify `message-alternative-emails'
to match all of yours addresses."
  ;; Canlock-logic as suggested by Per Abrahamsen
  ;; <abraham@dina.kvl.dk>
  ;;
  ;; IF article has cancel-lock THEN
  ;;   IF we can verify it THEN
  ;;     issue cancel
  ;;   ELSE
  ;;     error: cancellock: article is not yours
  ;; ELSE
  ;;   Use old rules, comparing sender...
  (save-excursion
    (save-restriction
      (message-narrow-to-head-1)
      (if (and (message-fetch-field "Cancel-Lock")
	       (message-gnksa-enable-p 'canlock-verify))
	  (if (null (canlock-verify))
	      t
	    (error "Failed to verify Cancel-lock: This article is not yours"))
	(let (sender from)
	  (or
	   (message-gnksa-enable-p 'cancel-messages)
	   (and (setq sender (message-fetch-field "sender"))
		(string-equal (downcase sender)
			      (downcase (message-make-sender))))
	   ;; Email address in From field equals to our address
	   (and (setq from (message-fetch-field "from"))
		(string-equal
		 (downcase (car (mail-header-parse-address from)))
		 (downcase (car (mail-header-parse-address
				 (message-make-from))))))
	   ;; Email address in From field matches
	   ;; 'message-alternative-emails' regexp or function.
	   (and from
		message-alternative-emails
                (cond ((functionp message-alternative-emails)
                       (funcall message-alternative-emails
                                (mail-header-parse-address from)))
                      (t (string-match message-alternative-emails
                                       (car (mail-header-parse-address from))))))))))))

;;;###autoload
(defun message-cancel-news (&optional arg)
  "Cancel an article you posted.
If ARG, allow editing of the cancellation message."
  (interactive "P")
  (unless (message-news-p)
    (error "This is not a news article; canceling is impossible"))
  (let (from newsgroups message-id distribution buf)
    (save-excursion
      ;; Get header info from original article.
      (save-restriction
	(message-narrow-to-head-1)
	(setq from (message-fetch-field "from")
	      newsgroups (message-fetch-field "newsgroups")
	      message-id (message-fetch-field "message-id" t)
	      distribution (message-fetch-field "distribution")))
      ;; Make sure that this article was written by the user.
      (unless (message-is-yours-p)
	(error "This article is not yours"))
      (when (yes-or-no-p "Do you really want to cancel this article? ")
	;; Make control message.
	(if arg
	    (message-news)
	  (setq buf (set-buffer (gnus-get-buffer-create " *message cancel*"))))
	(erase-buffer)
	(insert "Newsgroups: " newsgroups "\n"
		"From: " from "\n"
		"Subject: cancel " message-id "\n"
		"Control: cancel " message-id "\n"
		(if distribution
		    (concat "Distribution: " distribution "\n")
		  "")
		mail-header-separator "\n"
		message-cancel-message)
	(run-hooks 'message-cancel-hook)
	(unless arg
	  (message "Canceling your article...")
	  (if (let ((message-syntax-checks
		     'dont-check-for-anything-just-trust-me))
		(funcall message-send-news-function))
	      (message "Canceling your article...done"))
	  (kill-buffer buf))))))

;;;###autoload
(defun message-supersede ()
  "Start composing a message to supersede the current message.
This is done simply by taking the old article and adding a Supersedes
header line with the old Message-ID."
  (interactive)
  (let ((cur (current-buffer)))
    ;; Check whether the user owns the article that is to be superseded.
    (unless (message-is-yours-p)
      (error "This article is not yours"))
    ;; Get a normal message buffer.
    (message-pop-to-buffer (message-buffer-name "supersede"))
    (insert-buffer-substring cur)
    (mime-to-mml)
    (message-narrow-to-head-1)
    ;; Remove unwanted headers.
    (when message-ignored-supersedes-headers
      (message-remove-header message-ignored-supersedes-headers t))
    (goto-char (point-min))
    (if (not (re-search-forward "^Message-ID: " nil t))
	(error "No Message-ID in this article")
      (replace-match "Supersedes: " t t))
    (goto-char (point-max))
    (insert mail-header-separator)
    (widen)
    (forward-line 1)))

;;;###autoload
(defun message-recover ()
  "Reread contents of current buffer from its last auto-save file."
  (interactive)
  (let ((file-name (make-auto-save-file-name)))
    (cond ((save-window-excursion
	     (with-output-to-temp-buffer "*Directory*"
	       (with-current-buffer standard-output
		 (fundamental-mode))
	       (buffer-disable-undo standard-output)
	       (let ((default-directory "/"))
		 (call-process
		  "ls" nil standard-output nil "-l" file-name)))
	     (yes-or-no-p (format "Recover auto save file %s? " file-name)))
	   (let ((buffer-read-only nil))
	     (erase-buffer)
	     (insert-file-contents file-name nil)))
	  (t (error "message-recover canceled")))))

;;; Washing Subject:

(defun message-wash-subject (subject)
  "Remove junk like \"Re:\", \"(fwd)\", etc. added to subject string SUBJECT.
Previous forwarders, repliers, etc. may add it."
  (with-temp-buffer
    (insert subject)
    (goto-char (point-min))
    ;; strip Re/Fwd stuff off the beginning
    (while (re-search-forward
	    "\\([Rr][Ee]:\\|[Ff][Ww][Dd]\\(\\[[0-9]*\\]\\)?:\\|[Ff][Ww]:\\)" nil t)
      (replace-match ""))

    ;; and gnus-style forwards [foo@bar.com] subject
    (goto-char (point-min))
    (while (re-search-forward "\\[[^ \t]*\\(@\\|\\.\\)[^ \t]*\\]" nil t)
      (replace-match ""))

    ;; and off the end
    (goto-char (point-max))
    (while (re-search-backward "([Ff][Ww][Dd])" nil t)
      (replace-match ""))

    ;; and finally, any whitespace that was left-over
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]+" nil t)
      (replace-match ""))
    (goto-char (point-max))
    (while (re-search-backward "[ \t]+$" nil t)
      (replace-match ""))

    (buffer-string)))

;;; Forwarding messages.

(defvar message-forward-decoded-p nil
  "Non-nil means the original message is decoded.")

(defun message-forward-subject-name-subject (subject)
  "Generate a SUBJECT for a forwarded message.
The form is: [Source] Subject, where if the original message was mail,
Source is the name of the sender, and if the original message was
news, Source is the list of newsgroups is was posted to."
  (let* ((group (message-fetch-field "newsgroups"))
	 (from (message-fetch-field "from"))
	 (prefix
	  (or group
	      (or (and from (or
			     (car (gnus-extract-address-components from))
			     (cadr (gnus-extract-address-components from))))
		  "(nowhere)"))))
    (concat "["
	    (if message-forward-decoded-p
		prefix
	      (mail-decode-encoded-word-string prefix))
	    "] " subject)))

(defun message-forward-subject-author-subject (subject)
  "Generate a SUBJECT for a forwarded message.
The form is: [Source] Subject, where if the original message was mail,
Source is the sender, and if the original message was news, Source is
the list of newsgroups is was posted to."
  (let* ((group (message-fetch-field "newsgroups"))
	 (prefix
	  (or group
	      (or (message-fetch-field "from")
		  "(nowhere)"))))
    (concat "["
	    (if message-forward-decoded-p
		prefix
	      (mail-decode-encoded-word-string prefix))
	    "] " subject)))

(defun message-forward-subject-fwd (subject)
  "Generate a SUBJECT for a forwarded message.
The form is: Fwd: Subject, where Subject is the original subject of
the message."
  (if (string-match "^Fwd: " subject)
      subject
    (concat "Fwd: " subject)))

(defun message-make-forward-subject ()
  "Return a Subject header suitable for the message in the current buffer."
  (save-excursion
    (save-restriction
      (message-narrow-to-head-1)
      (let ((funcs message-make-forward-subject-function)
	    (subject (message-fetch-field "Subject")))
	(setq subject
	      (if subject
		  (if message-forward-decoded-p
		      subject
		    (mail-decode-encoded-word-string subject))
		""))
	(when message-wash-forwarded-subjects
	  (setq subject (message-wash-subject subject)))
        (setq funcs (ensure-list funcs))
	;; Apply funcs in order, passing subject generated by previous
	;; func to the next one.
	(dolist (func funcs)
	  (when (functionp func)
	    (setq subject (funcall func subject))))
	subject))))

(defvar gnus-article-decoded-p)


;;;###autoload
(defun message-forward (&optional news digest)
  "Forward the current message via mail.
Optional NEWS will use news to forward instead of mail.
Optional DIGEST will use digest to forward."
  (interactive "P")
  (let* ((cur (current-buffer))
	 (message-forward-decoded-p
	  (if (local-variable-p 'gnus-article-decoded-p (current-buffer))
	      gnus-article-decoded-p ;; In an article buffer.
	    message-forward-decoded-p))
	 (subject (message-make-forward-subject)))
    (if news
	(message-news nil subject)
      (message-mail nil subject))
    (message-forward-make-body cur digest)))

(defun message-forward-make-body-plain (forward-buffer)
  (insert
   "\n-------------------- Start of forwarded message --------------------\n")
  (let ((b (point))
	(contents (with-current-buffer forward-buffer (buffer-string)))
	e)
    (unless (multibyte-string-p contents)
      (error "Attempt to insert unibyte string from the buffer \"%s\"\
 to the multibyte buffer \"%s\""
             forward-buffer
	     (buffer-name)))
    (insert (mm-with-multibyte-buffer
	      (insert contents)
	      (mime-to-mml)
	      (goto-char (point-min))
	      (when (looking-at "From ")
		(replace-match "X-From-Line: "))
	      (buffer-string)))
    (unless (bolp) (insert "\n"))
    (setq e (point))
    (insert
     "-------------------- End of forwarded message --------------------\n")
    (message-remove-ignored-headers b e)))

(defun message-remove-ignored-headers (b e &optional preserve-mime)
  (when (or message-forward-ignored-headers
	    message-forward-included-headers)
    (let ((saved-headers nil))
    (save-restriction
      (narrow-to-region b e)
      (goto-char b)
      (narrow-to-region (point)
			(or (search-forward "\n\n" nil t) (point)))
      ;; When forwarding as MIME, preserve some MIME headers.
      (when preserve-mime
	(let ((headers (buffer-string)))
	  (with-temp-buffer
	    (insert headers)
	    (message-remove-header
	     (if (listp message-forward-included-mime-headers)
		 (mapconcat
		  #'identity (cons "^$" message-forward-included-mime-headers)
		  "\\|")
	       message-forward-included-mime-headers)
	     t nil t)
	    (setq saved-headers (string-lines (buffer-string) t)))))
      (when message-forward-ignored-headers
	(let ((ignored (if (stringp message-forward-ignored-headers)
			   (list message-forward-ignored-headers)
			 message-forward-ignored-headers)))
	  (dolist (elem ignored)
	    (message-remove-header elem t))))
      (when message-forward-included-headers
	(message-remove-header
	 (if (listp message-forward-included-headers)
	     (mapconcat #'identity (cons "^$" message-forward-included-headers)
			"\\|")
	   message-forward-included-headers)
	 t nil t))
      ;; Insert the MIME headers, if any.
      (goto-char (point-max))
      (forward-line -1)
      (dolist (header saved-headers)
	(insert header "\n"))))))

(defun message-forward-make-body-mime (forward-buffer &optional beg end)
  (let ((b (point)))
    (insert "\n\n<#part type=message/rfc822 disposition=inline raw=t>\n")
    (save-restriction
      (narrow-to-region (point) (point))
      (insert-buffer-substring forward-buffer beg end)
      (mml-quote-region (point-min) (point-max))
      (goto-char (point-min))
      (when (looking-at "From ")
	(replace-match "X-From-Line: "))
      (message-remove-ignored-headers (point-min) (point-max) t)
      (goto-char (point-max)))
    (insert "<#/part>\n")
    ;; Consider there is no illegible text.
    (add-text-properties
     b (point)
     '(no-illegible-text t rear-nonsticky t))))

(defun message-forward-make-body-mml (forward-buffer)
  (insert "\n\n<#mml type=message/rfc822 disposition=inline>\n")
  (let ((b (point)) e)
    (if (not message-forward-decoded-p)
	(let ((contents (with-current-buffer forward-buffer (buffer-string))))
	  (unless (multibyte-string-p contents)
	    (error "Attempt to insert unibyte string from the buffer \"%s\"\
 to the multibyte buffer \"%s\""
                   forward-buffer
		   (buffer-name)))
	  (insert (mm-with-multibyte-buffer
		    (insert contents)
		    (mime-to-mml)
		    (goto-char (point-min))
		    (when (looking-at "From ")
		      (replace-match "X-From-Line: "))
		    (buffer-string))))
      (save-restriction
	(narrow-to-region (point) (point))
	(mml-insert-buffer forward-buffer)
	(goto-char (point-min))
	(when (looking-at "From ")
	  (replace-match "X-From-Line: "))
	(goto-char (point-max))))
    (setq e (point))
    (insert "<#/mml>\n")
    (when (not message-forward-decoded-p)
      (message-remove-ignored-headers b e))))

(defun message-forward-make-body-digest-plain (forward-buffer)
  (insert
   "\n-------------------- Start of forwarded message --------------------\n")
  (mml-insert-buffer forward-buffer)
  (insert
   "\n-------------------- End of forwarded message --------------------\n"))

(defun message-forward-make-body-digest-mime (forward-buffer)
  (insert "\n<#multipart type=digest>\n")
  (let ((b (point)) e)
    (insert-buffer-substring forward-buffer)
    (setq e (point))
    (insert "<#/multipart>\n")
    (save-restriction
      (narrow-to-region b e)
      (goto-char b)
      (narrow-to-region (point)
			(or (search-forward "\n\n" nil t) (point)))
      (delete-region (point-min) (point-max)))))

(defun message-forward-make-body-digest (forward-buffer)
  (if message-forward-as-mime
      (message-forward-make-body-digest-mime forward-buffer)
    (message-forward-make-body-digest-plain forward-buffer)))

(autoload 'mm-uu-dissect-text-parts "mm-uu")
(autoload 'mm-uu-dissect "mm-uu")

(defun message-signed-or-encrypted-p (&optional dont-emulate-mime handles)
  "Say whether the current buffer contains signed or encrypted message.
If DONT-EMULATE-MIME is nil, this function does the MIME emulation on
messages that don't conform to PGP/MIME described in RFC2015.  HANDLES
is for the internal use."
  (unless handles
    (let ((mm-decrypt-option 'never)
	  (mm-verify-option 'never))
      (if (setq handles (mm-dissect-buffer nil t))
	  (unless dont-emulate-mime
	    (mm-uu-dissect-text-parts handles))
	(unless dont-emulate-mime
	  (setq handles (mm-uu-dissect))))))
  ;; Check text/plain message in which there is a signed or encrypted
  ;; body that has been encoded by B or Q.
  (unless (or handles dont-emulate-mime)
    (let ((cur (current-buffer))
	  (mm-decrypt-option 'never)
	  (mm-verify-option 'never))
      (with-temp-buffer
	(insert-buffer-substring cur)
	(when (setq handles (mm-dissect-buffer t t))
	  (if (and (bufferp (car handles))
		   (equal (mm-handle-media-type handles) "text/plain"))
	      (progn
		(erase-buffer)
		(insert-buffer-substring (car handles))
		(mm-decode-content-transfer-encoding
		 (mm-handle-encoding handles))
		(mm-destroy-parts handles)
		(setq handles (mm-uu-dissect)))
	    (mm-destroy-parts handles)
	    (setq handles nil))))))
  (when handles
    (prog1
	(catch 'found
	  (dolist (handle (if (stringp (car handles))
			      (if (member (car handles)
					  '("multipart/signed"
					    "multipart/encrypted"))
				  (throw 'found t)
				(cdr handles))
			    (list handles)))
	    (if (stringp (car handle))
		(when (message-signed-or-encrypted-p dont-emulate-mime handle)
		  (throw 'found t))
	      (when (and (bufferp (car handle))
			 (equal (mm-handle-media-type handle)
				"message/rfc822"))
		(with-current-buffer (mm-handle-buffer handle)
		  (when (message-signed-or-encrypted-p dont-emulate-mime)
		    (throw 'found t)))))))
      (mm-destroy-parts handles))))

;;;###autoload
(defun message-forward-make-body (forward-buffer &optional digest)
  ;; Put point where we want it before inserting the forwarded
  ;; message.
  (if message-forward-before-signature
      (message-goto-body)
    (goto-char (point-max)))
  (if digest
      (message-forward-make-body-digest forward-buffer)
    (if message-forward-as-mime
	(if (and message-forward-show-mml
		 (not (and (eq message-forward-show-mml 'best)
			   ;; Use the raw form in the body if it contains
			   ;; signed or encrypted message so as not to be
			   ;; destroyed by re-encoding.
			   (with-current-buffer forward-buffer
			     (condition-case nil
				 (message-signed-or-encrypted-p)
			       (error t))))))
	    (message-forward-make-body-mml forward-buffer)
	  (message-forward-make-body-mime forward-buffer))
      (message-forward-make-body-plain forward-buffer)))
  (message-position-point))

(declare-function rmail-toggle-header "rmail" (&optional arg))

;;;###autoload
(defun message-forward-rmail-make-body (forward-buffer)
  (save-window-excursion
    (set-buffer forward-buffer)
    (when (rmail-msg-is-pruned)
      (rmail-toggle-header 0)))
  (message-forward-make-body forward-buffer))

;; Fixme: Should have defcustom.
;;;###autoload
(defun message-insinuate-rmail ()
  "Let RMAIL use message to forward."
  (interactive)
  (setq rmail-enable-mime-composing t)
  (setq rmail-insert-mime-forwarded-message-function
	#'message-forward-rmail-make-body))

;;;###autoload
(defun message-resend (address)
  "Resend the current article to ADDRESS."
  (interactive
   (list (message-read-from-minibuffer "Resend message to: ")))
  (message "Resending message to %s..." address)
  (save-excursion
    (let ((cur (current-buffer))
	  gcc beg)
      ;; We first set up a normal mail buffer.
      (unless (message-mail-user-agent)
	(set-buffer (gnus-get-buffer-create " *message resend*"))
	(let ((inhibit-read-only t))
	  (erase-buffer)))
      (let ((message-this-is-mail t)
	    message-setup-hook)
	(message-setup `((To . ,address))))
      ;; Insert our usual headers.
      (message-generate-headers '(From Date To Message-ID))
      (message-narrow-to-headers)
      (when (setq gcc (mail-fetch-field "gcc" nil t))
	(message-remove-header "gcc"))
      ;; Remove X-Draft-From header etc.
      (message-remove-header message-ignored-mail-headers t)
      ;; Rename them all to "Resent-*".
      (goto-char (point-min))
      (while (re-search-forward "^[A-Za-z]" nil t)
	(forward-char -1)
	(insert "Resent-"))
      (widen)
      (forward-line)
      (let ((inhibit-read-only t))
	(delete-region (point) (point-max)))
      (setq beg (point))
      ;; Insert the message to be resent.
      (insert-buffer-substring cur)
      (goto-char (point-min))
      (search-forward "\n\n")
      (forward-char -1)
      (save-restriction
	(narrow-to-region beg (point))
	(message-remove-header message-ignored-resent-headers t)
	(goto-char (point-max)))
      (insert mail-header-separator)
      ;; Rename all old ("Also-")Resent headers.
      (while (re-search-backward "^\\(Also-\\)*Resent-" beg t)
	(beginning-of-line)
	(insert "Also-"))
      ;; Quote any "From " lines at the beginning.
      (goto-char beg)
      (when (looking-at "From ")
	(replace-match "X-From-Line: "))
      ;; Send it.
      (let ((message-inhibit-body-encoding
	     ;; Don't do any further encoding if it looks like the
	     ;; message has already been encoded.
	     (let ((case-fold-search t))
	       (re-search-forward "^mime-version:" nil t)))
	    (message-inhibit-ecomplete t)
	    ;; We don't want smtpmail.el to encode anything, either.
	    (sendmail-coding-system 'raw-text)
	    (select-safe-coding-system-function nil)
	    message-required-mail-headers
	    rfc2047-encode-encoded-words
            ;; If `message-sendmail-envelope-from' is `header' then
            ;; the envelope-from will be the original sender's
            ;; address, not the resender's.  But when resending, the
            ;; envelope-from should be the resender's address.  Defuse
            ;; that particular case.
            (message-sendmail-envelope-from
             (and (not (and (eq message-sendmail-envelope-from
                                'obey-mail-envelope-from)
                            (eq mail-envelope-from 'header)))
                  (not (eq message-sendmail-envelope-from 'header))
                  message-sendmail-envelope-from)))
	(message-send-mail))
      (when gcc
	(message-goto-eoh)
	(insert "Gcc: " gcc "\n"))
      (run-hooks 'message-sent-hook)
      (kill-buffer (current-buffer)))
    (message "Resending message to %s...done" address)))

;;;###autoload
(defun message-bounce ()
  "Re-mail the current message.
This only makes sense if the current message is a bounce message that
contains some mail you have written which has been bounced back to
you."
  (interactive)
  (let ((handles (mm-dissect-buffer t))
	boundary)
    (message-pop-to-buffer (message-buffer-name "bounce"))
    (if (stringp (car handles))
	;; This is a MIME bounce.
	(mm-insert-part (car (last handles)))
      ;; This is a non-MIME bounce, so we try to remove things
      ;; manually.
      (mm-insert-part handles)
      (undo-boundary)
      (goto-char (point-min))
      (re-search-forward "\n\n+" nil t)
      (setq boundary (point))
      ;; We remove everything before the bounced mail.
      (if (or (re-search-forward message-unsent-separator nil t)
	      (progn
		(search-forward "\n\n" nil 'move)
		(re-search-backward "^Return-Path:.*\n" boundary t)))
	  (progn
	    (forward-line 1)
	    (delete-region (point-min)
			   (if (re-search-forward "^[^ \n\t]+:" nil t)
			       (match-beginning 0)
			     (point))))
	(goto-char boundary)
	(when (re-search-backward "^.?From .*\n" nil t)
	  (delete-region (match-beginning 0) (match-end 0)))))
    (mime-to-mml)
    (save-restriction
      (message-narrow-to-head-1)
      (message-remove-header message-ignored-bounced-headers t)
      (goto-char (point-max))
      (insert mail-header-separator))
    (message-position-point)))

;;;
;;; Interactive entry points for new message buffers.
;;;

;;;###autoload
(defun message-mail-other-window (&optional to subject)
  "Like `message-mail' command, but display mail buffer in another window."
  (interactive)
  (unless (message-mail-user-agent)
    (message-pop-to-buffer (message-buffer-name "mail" to)
			   'switch-to-buffer-other-window))
  (let ((message-this-is-mail t))
    (message-setup `((To . ,(or to "")) (Subject . ,(or subject "")))
		   nil nil nil 'switch-to-buffer-other-window)))

;;;###autoload
(defun message-mail-other-frame (&optional to subject)
  "Like `message-mail' command, but display mail buffer in another frame."
  (interactive)
  (unless (message-mail-user-agent)
    (message-pop-to-buffer (message-buffer-name "mail" to)
			   'switch-to-buffer-other-frame))
  (let ((message-this-is-mail t))
    (message-setup `((To . ,(or to "")) (Subject . ,(or subject "")))
		   nil nil nil 'switch-to-buffer-other-frame)))

;;;###autoload
(defun message-news-other-window (&optional newsgroups subject)
  "Start editing a news article to be sent."
  (interactive)
  (message-pop-to-buffer (message-buffer-name "posting" nil newsgroups)
			 'switch-to-buffer-other-window)
  (let ((message-this-is-news t))
    (message-setup `((Newsgroups . ,(or newsgroups ""))
		     (Subject . ,(or subject ""))))))

;;;###autoload
(defun message-news-other-frame (&optional newsgroups subject)
  "Start editing a news article to be sent."
  (interactive)
  (message-pop-to-buffer (message-buffer-name "posting" nil newsgroups)
			 'switch-to-buffer-other-frame)
  (let ((message-this-is-news t))
    (message-setup `((Newsgroups . ,(or newsgroups ""))
		     (Subject . ,(or subject ""))))))

;;; underline.el

;; This code should be moved to underline.el (from which it is stolen).

;;;###autoload
(defun message-bold-region (start end)
  "Bold all nonblank characters in the region.
Works by overstriking characters.
Called from program, takes two arguments START and END
which specify the range to operate on."
  (interactive "r")
  (save-excursion
    (let ((end1 (make-marker)))
      (move-marker end1 (max start end))
      (goto-char (min start end))
      (while (< (point) end1)
	(or (looking-at "[_\^@- ]")
	    (insert (char-after) "\b"))
	(forward-char 1)))))

;;;###autoload
(defun message-unbold-region (start end)
  "Remove all boldness (overstruck characters) in the region.
Called from program, takes two arguments START and END
which specify the range to operate on."
  (interactive "r")
  (save-excursion
    (let ((end1 (make-marker)))
      (move-marker end1 (max start end))
      (goto-char (min start end))
      (while (search-forward "\b" end1 t)
	(if (eq (char-after) (char-after (- (point) 2)))
	    (delete-char -2))))))

(defun message-exchange-point-and-mark ()
  "Exchange point and mark, but don't activate region if it was inactive."
  (goto-char (prog1 (mark t)
	       (set-marker (mark-marker) (point)))))

;; Support for toolbar
(defvar tool-bar-mode)

(defcustom message-tool-bar
  '((ispell-message "spell" nil
		    :vert-only t
		    :visible (not flyspell-mode))
    (flyspell-buffer "spell" t
		     :vert-only t
		     :visible flyspell-mode
		     :help "Flyspell whole buffer")
    (message-send-and-exit "mail/send" t :label "Send")
    (message-dont-send "mail/save-draft")
    (mml-attach-file "attach" mml-mode-map :vert-only t)
    (mml-preview "mail/preview" mml-mode-map)
    (mml-secure-message-sign-encrypt "lock" mml-mode-map :visible nil)
    (message-insert-importance-high "important" nil :visible nil)
    (message-insert-importance-low "unimportant" nil :visible nil)
    (message-insert-disposition-notification-to "receipt" nil :visible nil))
  "Specifies the message mode tool bar.

It can be either a list or a symbol referring to a list.  See
`gmm-tool-bar-from-list' for the format of the list.  The
default key map is `message-mode-map'."
  :type '(choice (repeat :tag "User defined list" gmm-tool-bar-item)
		 (symbol))
  :version "29.1"
  :group 'message)

(defvar message-tool-bar-gnome nil)
(make-obsolete-variable 'message-tool-bar-gnome nil "29.1")
(defvar message-tool-bar-retro nil)
(make-obsolete-variable 'message-tool-bar-gnome nil "29.1")
(defvar message-tool-bar-zap-list t)
(make-obsolete-variable 'message-tool-bar-zap-list nil "29.1")

(defvar image-load-path)
(declare-function image-load-path-for-library "image"
		  (library image &optional path no-error))

(defun message-make-tool-bar (&optional force)
  "Make a message mode tool bar from `message-tool-bar'.
When FORCE, rebuild the tool bar."
  (when (and (boundp 'tool-bar-mode)
	     tool-bar-mode
	     (or (not message-tool-bar-map) force))
    (setq message-tool-bar-map
	  (let* ((load-path
		  (image-load-path-for-library
		   "message" "mail/save-draft.xpm" nil t))
		 (image-load-path (cons (car load-path) image-load-path)))
	    (gmm-tool-bar-from-list message-tool-bar
				    message-tool-bar-zap-list
				    'message-mode-map))))
  message-tool-bar-map)

;;; Group name and email address completion.

(defcustom message-newgroups-header-regexp
  "^\\(Newsgroups\\|Followup-To\\|Posted-To\\|Gcc\\):"
  "Regexp matching headers that list groups."
  :group 'message
  :type 'regexp)

(defcustom message-email-recipient-header-regexp
  "^\\([^ :]*-\\)?\\(To\\|B?Cc\\|From\\|Reply-to\\|Mail-Followup-To\\|Mail-Copies-To\\):"
  "Regexp matching headers that list email addresses."
  :version "29.1"
  :type 'regexp)

(defcustom message-completion-alist
  `((,message-newgroups-header-regexp . ,#'message-expand-group)
    (,message-email-recipient-header-regexp . ,#'message-expand-name))
  "Alist of (RE . FUN).  Use FUN for completion on header lines matching RE.
FUN should be a function that obeys the same rules as those
of `completion-at-point-functions'."
  :version "27.1"
  :group 'message
  :type '(alist :key-type regexp :value-type function))

(defcustom message-expand-name-databases
  '(bbdb eudc)
  "List of databases to try for name completion (`message-expand-name').
Each element is a symbol and can be `bbdb' or `eudc'."
  :group 'message
  :type '(set (const bbdb) (const eudc)))

(defcustom message-tab-body-function nil
  "Function to execute when `message-tab' (TAB) is executed in the body.
If nil, the function bound in `text-mode-map' or `global-map' is executed."
  :version "22.1"
  :group 'message
  :link '(custom-manual "(message)Various Commands")
  :type '(choice (const nil)
		 function))

(declare-function mail-abbrev-in-expansion-header-p "mailabbrev" ())

(defun message-tab ()
  "Complete names according to `message-completion-alist'.
Execute function specified by `message-tab-body-function' when
not in those headers.  If that variable is nil, indent with the
regular text mode tabbing command."
  (interactive nil message-mode)
  (cond
   ((let ((completion-fail-discreetly t))
      (completion-at-point))
    ;; Completion was performed; nothing else to do.
    nil)
   (message-tab-body-function (funcall message-tab-body-function))
   (t (funcall (or (lookup-key text-mode-map "\t")
                   (lookup-key global-map "\t")
                   'indent-relative)))))

(defvar mail-abbrev-mode-regexp)

(defvar message--old-style-completion-functions nil)

(defun message-completion-function ()
  (let ((alist message-completion-alist))
    (while (and alist
		(let ((mail-abbrev-mode-regexp (caar alist)))
		  (not (mail-abbrev-in-expansion-header-p))))
      (setq alist (cdr alist)))
    (when (cdar alist)
      (let ((fun (cdar alist)))
        (if (member fun message--old-style-completion-functions)
            (lambda ()
              (funcall fun)
              ;; Even if completion fails, return a non-nil value, so as to
              ;; avoid falling back to message-tab-body-function.
              'completion-attempted)
          (let ((ticks-before (buffer-chars-modified-tick))
                (data (funcall fun)))
            (if (and (eq ticks-before (buffer-chars-modified-tick))
                     (or (null data)
                         (integerp (car-safe data))))
                data
              (push fun message--old-style-completion-functions)
              ;; Completion was already performed, so just return a dummy
              ;; function that prevents trying any further.
              (lambda () 'completion-attempted))))))))

(defun message-expand-group ()
  "Expand the group name under point."
  (let ((b (save-excursion
	     (save-restriction
	       (narrow-to-region
		(save-excursion
		  (beginning-of-line)
		  (skip-chars-forward "^:")
		  (1+ (point)))
		(point))
	       (skip-chars-backward "^, \t\n") (point))))
	(completion-ignore-case t)
	(e (progn (skip-chars-forward "^,\t\n ") (point)))
	(collection (when (and (boundp 'gnus-active-hashtb)
			       gnus-active-hashtb)
		      (hash-table-keys gnus-active-hashtb))))
    (when collection
      ;; FIXME: Add `category' metadata to the collection, so we can use
      ;; substring matching on it.
      (list b e collection))))

(defcustom message-expand-name-standard-ui nil
  "If non-nil, use the standard completion UI in `message-expand-name'.
E.g. this means it will obey `completion-styles' and other such settings.

If this variable is non-nil and `message-mail-alias-type' is
`ecomplete', `message-self-insert-commands' should probably be
set to nil."
  :version "27.1"
  :type 'boolean)

(defun message-expand-name ()
  (cond (message-expand-name-standard-ui
	 (let ((beg (save-excursion
                      (skip-chars-backward "^\n:,") (skip-chars-forward " \t")
                      (point)))
               (end (save-excursion
                      (skip-chars-forward "^\n,") (skip-chars-backward " \t")
                      (point))))
           (when (< beg end)
             (list beg end (message--name-table (buffer-substring beg end))))))
	((and (memq 'eudc message-expand-name-databases)
		    (boundp 'eudc-protocol)
		    eudc-protocol)
	 (eudc-expand-inline))
	((and (memq 'bbdb message-expand-name-databases)
	      (fboundp 'bbdb-complete-name))
         (let ((starttick (buffer-modified-tick)))
           (or (bbdb-complete-name)
               ;; Apparently, bbdb-complete-name can return nil even when
               ;; completion took place.  So let's double check the buffer was
               ;; not modified.
               (/= starttick (buffer-modified-tick)))))
	(t
	 (expand-abbrev))))

(add-to-list 'completion-category-defaults '(email (styles substring
                                                           partial-completion)))

(defun message--bbdb-query-with-words (words)
  ;; FIXME: This (or something like this) should live on the BBDB side.
  (when (fboundp 'bbdb-records)
    (require 'bbdb)           ;FIXME: `bbdb-records' is incorrectly autoloaded!
    (bbdb-records)            ;Make sure BBDB and its database is initialized.
    (defvar bbdb-hashtable)
    (declare-function bbdb-record-mail "bbdb" (record))
    (declare-function bbdb-dwim-mail "bbdb-com" (record &optional mail))
    (declare-function bbdb-completion-predicate "bbdb-com" (key records))
    (let ((records '())
          (responses '()))
      (dolist (word words)
	(dolist (c (all-completions word bbdb-hashtable
	                            #'bbdb-completion-predicate))
	  (dolist (record (gethash c bbdb-hashtable))
	    (cl-pushnew record records))))
      (dolist (record records)
	(dolist (mail (bbdb-record-mail record))
	  (push (bbdb-dwim-mail record mail) responses)))
      responses)))

(defun message--name-table (orig-string)
  (let ((orig-words (split-string orig-string "[ \t]+"))
        eudc-responses
        bbdb-responses)
    (lambda (string pred action)
      (pcase action
        ('metadata '(metadata (category . email)))
        ('lambda t)
        ((or 'nil 't)
         (when orig-words
           (when (and (memq 'eudc message-expand-name-databases)
		      (boundp 'eudc-protocol)
		      eudc-protocol)
	     (setq eudc-responses (eudc-query-with-words orig-words)))
	   (when (memq 'bbdb message-expand-name-databases)
	     (setq bbdb-responses (message--bbdb-query-with-words orig-words)))
	   (ecomplete-setup)
	   (setq orig-words nil))
         (let ((candidates
	        ;; FIXME: Add `expand-abbrev'!
	        (append (all-completions string eudc-responses pred)
	                (all-completions string bbdb-responses pred)
	                (when (and (bound-and-true-p ecomplete-database)
	                           (fboundp 'ecomplete-completion-table))
                          (all-completions string
                                           (ecomplete-completion-table 'mail)
                                           pred)))))
	   (if action candidates (try-completion string candidates))))))))

;;; Help stuff.

(defun message-talkative-question (ask question show &rest text)
  "Call FUNCTION with argument QUESTION; optionally display TEXT... args.
If SHOW is non-nil, the arguments TEXT... are displayed in a temp buffer.
The following arguments may contain lists of values."
  (if (and show
	   (setq text (flatten-tree text)))
      (save-window-excursion
        (with-output-to-temp-buffer " *MESSAGE information message*"
          (with-current-buffer " *MESSAGE information message*"
	    (fundamental-mode)
	    (mapc #'princ text)
	    (goto-char (point-min))))
	(funcall ask question))
    (funcall ask question)))

(define-obsolete-function-alias 'message-flatten-list #'flatten-tree "27.1")

(defun message-generate-new-buffer-clone-locals (name &optional varstr)
  "Create and return a buffer with name based on NAME using `generate-new-buffer'.
Then clone the local variables and values from the old buffer to the
new one, cloning only the locals having a substring matching the
regexp VARSTR."
  (let ((oldbuf (current-buffer)))
    (with-current-buffer (generate-new-buffer name)
      (message-clone-locals oldbuf varstr)
      (current-buffer))))

(defun message-clone-locals (buffer &optional varstr)
  "Clone the local variables from BUFFER to the current buffer."
  (let ((locals (with-current-buffer buffer (buffer-local-variables)))
	(regexp "^gnus\\|^nn\\|^message\\|^sendmail\\|^smtp\\|^user-mail-address"))
    (mapcar
     (lambda (local)
       (when (and (consp local)
		  (car local)
		  (string-match regexp (symbol-name (car local)))
		  (or (null varstr)
		      (string-match varstr (symbol-name (car local)))))
	 (ignore-errors
	   ;; Cloning message-default-charset could cause an already
	   ;; encoded text to be encoded again, yielding raw bytes
	   ;; instead of characters in the message.
	   (unless (eq 'message-default-charset (car local))
	     (set (make-local-variable (car local))
		  (cdr local))))))
     locals)))

;;;
;;; MIME functions
;;;

(defun message-encode-message-body ()
  (unless message-inhibit-body-encoding
    (let ((case-fold-search t)
	  lines content-type-p)
      (message-goto-body)
      (save-restriction
	(narrow-to-region (point) (point-max))
	(let ((new (mml-generate-mime nil
				      (save-restriction
					(message-narrow-to-headers)
					(mail-fetch-field "content-type")))))
	  (when new
	    (delete-region (point-min) (point-max))
	    (insert new)
	    (goto-char (point-min))
	    (if (eq (aref new 0) ?\n)
		(delete-char 1)
	      (search-forward "\n\n")
	      (setq lines (buffer-substring (point-min) (1- (point))))
	      (delete-region (point-min) (point))))))
      (save-restriction
	(message-narrow-to-headers-or-head)
	(message-remove-header "Mime-Version")
	(goto-char (point-max))
	(insert "MIME-Version: 1.0\n")
	(when lines
	  (insert lines))
	(setq content-type-p
	      (or mml-boundary
		  (re-search-backward "^Content-Type:" nil t))))
      (save-restriction
	(message-narrow-to-headers-or-head)
	(message-remove-first-header "Content-Type")
	(message-remove-first-header "Content-Transfer-Encoding"))
      ;; We always make sure that the message has a Content-Type
      ;; header.  This is because some broken MTAs and MUAs get
      ;; awfully confused when confronted with a message with a
      ;; MIME-Version header and without a Content-Type header.  For
      ;; instance, Solaris' /usr/bin/mail.
      (unless content-type-p
	(goto-char (point-min))
	;; For unknown reason, MIME-Version doesn't exist.
	(when (re-search-forward "^MIME-Version:" nil t)
	  (forward-line 1)
	  (insert "Content-Type: text/plain; charset=us-ascii\n"))))))

(defun message-read-from-minibuffer (prompt &optional initial-contents)
  "Read from the minibuffer while providing abbrev expansion."
  (let ((minibuffer-setup-hook 'mail-abbrevs-setup)
	(minibuffer-local-map message-minibuffer-local-map))
    (read-from-minibuffer prompt initial-contents)))

(defun message-use-alternative-email-as-from ()
  "Set From field of the outgoing message to the first matching
address in `message-alternative-emails', looking at To, Cc and
From headers in the original article."
  (require 'mail-utils)
  (let* ((fields '("To" "Cc" "From"))
	 (emails
	  (message-tokenize-header
	   (mail-strip-quoted-names
	    (mapconcat
	     #'identity
	     (cl-loop for field in fields
		      for value = (message-fetch-reply-field field)
		      when value
		      collect value)
	     ","))))
	 (email
          (cond ((functionp message-alternative-emails)
                 (car (cl-remove-if-not message-alternative-emails emails)))
                (t (cl-loop for email in emails
                            if (string-match-p message-alternative-emails email)
                            return email)))))
    (unless (or (not email) (equal email user-mail-address))
      (message-remove-header "From")
      (goto-char (point-max))
      (insert "From: " (let ((user-mail-address email)) (message-make-from))
	      "\n"))))

(defun message-options-get (symbol)
  (cdr (assq symbol message-options)))

(defun message-options-set (symbol value)
  (let ((the-cons (assq symbol message-options)))
    (if the-cons
	(if value
	    (setcdr the-cons value)
	  (setq message-options (delq the-cons message-options)))
      (and value
	   (push (cons symbol value) message-options))))
  value)

(defun message-options-set-recipient ()
  (save-restriction
    (message-narrow-to-headers-or-head)
    (message-options-set 'message-sender
			 (mail-strip-quoted-names
			  (message-fetch-field "from")))
    (message-options-set 'message-recipients
			 (mail-strip-quoted-names
			  (let ((to (message-fetch-field "to"))
				(cc (message-fetch-field "cc"))
				(bcc (message-fetch-field "bcc")))
			    (concat
			     (or to "")
			     (if (and to cc) ", ")
			     (or cc "")
			     (if (and (or to cc) bcc) ", ")
			     (or bcc "")))))))

(defun message-hide-headers ()
  "Hide headers based on the `message-hidden-headers' variable."
  (let ((regexps (if (stringp message-hidden-headers)
		     (list message-hidden-headers)
		   message-hidden-headers))
	end-of-headers)
    (when regexps
      (save-excursion
	(save-restriction
	  (message-narrow-to-headers)
          (setq end-of-headers (point-min-marker))
	  (goto-char (point-min))
	  (while (not (eobp))
	    (if (not (message-hide-header-p regexps))
		(message-next-header)
	      (let ((begin (point)))
		(message-next-header)
                (let ((header (delete-and-extract-region begin (point))))
                  (save-excursion
                    (goto-char end-of-headers)
                    (insert-before-markers header))))))))
      (narrow-to-region end-of-headers (point-max)))))

(defun message-hide-header-p (regexps)
  (let ((result nil)
	(reverse nil))
    (when (eq (car regexps) 'not)
      (setq reverse t)
      (pop regexps))
    (dolist (regexp regexps)
      (setq result (or result (looking-at regexp))))
    (if reverse
	(not result)
      result)))

(declare-function ecomplete-add-item "ecomplete" (type key text))
(declare-function ecomplete-save "ecomplete" ())

(defun message-put-addresses-in-ecomplete ()
  (require 'ecomplete)
  (dolist (header '("to" "cc" "from" "reply-to"))
    (let ((value (message-field-value header)))
      (dolist (string (mail-header-parse-addresses value 'raw))
	(setq string
	      (string-replace
	       "\n" ""
	       (replace-regexp-in-string "^ +\\| +$" "" string)))
	(ecomplete-add-item 'mail (car (mail-header-parse-address string))
			    string))))
  (ecomplete-save))

(autoload 'ecomplete-display-matches "ecomplete")

(defun message--in-tocc-p ()
  (and (memq (char-after (line-beginning-position)) '(?C ?T ?\t ? ))
       (message-point-in-header-p)
       (save-excursion
	 (beginning-of-line)
	 (while (and (memq (char-after) '(?\t ? ))
		     (zerop (forward-line -1))))
	 (looking-at "To:\\|Cc:"))))

(defun message-display-abbrev (&optional choose)
  "Display the next possible abbrev for the text before point."
  (interactive (list t) message-mode)
  (when (message--in-tocc-p)
    (let* ((end (point))
	   (start (save-excursion
		    (and (re-search-backward "[\n\t ]" nil t)
			 (1+ (point)))))
	   (word (when start (buffer-substring start end)))
	   (match (when (and word
			     (not (zerop (length word))))
		    (ecomplete-display-matches 'mail word choose))))
      (when (and choose match)
	(delete-region start end)
	(insert match)))))

(defun message-ecomplete-capf ()
  "Return completion data for email addresses in Ecomplete.
Meant for use on `completion-at-point-functions'."
  (when (and (bound-and-true-p ecomplete-database)
             (fboundp 'ecomplete-completion-table)
             (message--in-tocc-p))
    (let ((end (save-excursion
                 (skip-chars-forward "^, \t\n")
                 (point)))
	  (start (save-excursion
                   (skip-chars-backward "^, \t\n")
                   (point))))
      `(,start ,end ,(ecomplete-completion-table 'mail)))))

;; To send pre-formatted letters like the example below, you can use
;; `message-send-form-letter':
;; --8<---------------cut here---------------start------------->8---
;; To: alice@invalid.invalid
;; Subject: Verification of your contact information
;; From: Contact verification <admin@foo.invalid>
;; --text follows this line--
;; Hi Alice,
;; please verify that your contact information is still valid:
;; Alice A, A avenue 11, 1111 A town, Austria
;; ----------next form letter message follows this line----------
;; To: bob@invalid.invalid
;; Subject: Verification of your contact information
;; From: Contact verification <admin@foo.invalid>
;; --text follows this line--
;; Hi Bob,
;; please verify that your contact information is still valid:
;; Bob, B street 22, 22222 Be town, Belgium
;; ----------next form letter message follows this line----------
;; To: charlie@invalid.invalid
;; Subject: Verification of your contact information
;; From: Contact verification <admin@foo.invalid>
;; --text follows this line--
;; Hi Charlie,
;; please verify that your contact information is still valid:
;; Charlie Chaplin, C plaza 33, 33333 C town, Chile
;; --8<---------------cut here---------------end--------------->8---

;; FIXME: What is the most common term (circular letter, form letter, serial
;; letter, standard letter) for such kind of letter?  See also
;; <https://en.wikipedia.org/wiki/Form_letter>

;; FIXME: Maybe extent message-mode's font-lock support to recognize
;; `message-form-letter-separator', i.e. highlight each message like a single
;; message.

(defcustom message-form-letter-separator
  "\n----------next form letter message follows this line----------\n"
  "Separator for `message-send-form-letter'."
  ;; :group 'message-form-letter
  :group 'message-various
  :version "23.1" ;; No Gnus
  :type 'string)

(defcustom message-send-form-letter-delay 1
  "Delay in seconds when sending a message with `message-send-form-letter'.
Only used when `message-send-form-letter' is called with non-nil
argument `force'."
  ;; :group 'message-form-letter
  :group 'message-various
  :version "23.1" ;; No Gnus
  :type 'integer)

(defun message-send-form-letter (&optional force)
  "Sent all form letter messages from current buffer.
Unless FORCE, prompt before sending.

The messages are separated by `message-form-letter-separator'.
Header and body are separated by `mail-header-separator'."
  (interactive "P" message-mode)
  (let ((sent 0) (skipped 0)
	start end text
	buff
	to done)
    (goto-char (point-min))
    (while (not done)
      (setq start (point)
	    end (if (search-forward message-form-letter-separator nil t)
		    (- (point) (length message-form-letter-separator) -1)
		  (setq done t)
		  (point-max)))
      (setq text
	    (buffer-substring-no-properties start end))
      (setq buff (generate-new-buffer "*mail - form letter*"))
      (with-current-buffer buff
	(insert text)
	(message-mode)
	(setq to (message-fetch-field "To"))
	(switch-to-buffer buff)
	(when force
	  (sit-for message-send-form-letter-delay))
	(if (or force
		  (y-or-n-p (format-message "Send message to `%s'? " to)))
	    (progn
	      (setq sent (1+ sent))
	      (message-send-and-exit))
	  (message "Message to `%s' skipped." to)
	  (setq skipped (1+ skipped)))
	(when (buffer-live-p buff)
	  (kill-buffer buff))))
    (message "%s message(s) sent, %s skipped." sent skipped)))

(defun message-replace-header (header new-value &optional after force)
  "Remove HEADER and insert the NEW-VALUE.
If AFTER, insert after this header.  AFTER may be a list of
headers.  If FORCE, insert new field even if NEW-VALUE is empty."
  ;; Similar to `nnheader-replace-header' but for message buffers.
  (save-excursion
    (save-restriction
      (message-narrow-to-headers)
      (message-remove-header header))
    (when (or force (> (length new-value) 0))
      (apply #'message-position-on-field header
             (if (listp after)
                 after
               (list after)))
      (insert new-value))))

(make-obsolete-variable
 'message-recipients-without-full-name
 "Recipients are simplified by default" "27.1")
(defcustom message-recipients-without-full-name
  (list "ding@gnus.org"
	"bugs@gnus.org"
	"emacs-devel@gnu.org"
	"emacs-pretest-bug@gnu.org"
	"bug-gnu-emacs@gnu.org")
  "Mail addresses that have no full name.
Used in `message-simplify-recipients'."
  :type '(choice (const :tag "None" nil)
		 (repeat string))
  :version "23.1" ;; No Gnus
  :group 'message-headers)

(make-obsolete 'message-simplify-recipients nil "27.1")
(defun message-simplify-recipients ()
  (interactive nil message-mode)
  (dolist (hdr '("Cc" "To"))
    (message-replace-header
     hdr
     (mapconcat
      (lambda (addrcomp)
	(if (and message-recipients-without-full-name
		 (string-match
		  (regexp-opt message-recipients-without-full-name)
		  (cadr addrcomp)))
	    (cadr addrcomp)
	  (if (car addrcomp)
	      (message-make-from (car addrcomp) (cadr addrcomp))
	    (cadr addrcomp))))
      (when (message-fetch-field hdr)
	(mail-extract-address-components
	 (message-fetch-field hdr) t))
      ", "))))

;;; multipart/related and HTML support.

(defun message-make-html-message-with-image-files (files)
  "Make a message containing the current dired-marked image files."
  (interactive (list (dired-get-marked-files nil current-prefix-arg))
	       dired-mode)
  (message-mail)
  (message-goto-body)
  (insert "<#part type=text/html>\n\n")
  (dolist (file files)
    (insert (format "<img src=%S>\n\n" file)))
  (message-toggle-image-thumbnails)
  (message-goto-to))

(defun message-toggle-image-thumbnails ()
  "For any included image files, insert a thumbnail of that image."
  (interactive nil message-mode)
  (let ((displayed nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
	(when-let* ((props (get-text-property (point) 'display)))
	  (when (and (consp props)
		     (eq (car props) 'image))
	    (put-text-property (point) (1+ (point)) 'display nil)
	    (setq displayed t)))
	(forward-char 1)))
    (unless displayed
      (save-excursion
	(goto-char (point-min))
	(while (re-search-forward "<img.*src=\"\\([^\"]+\\).*>" nil t)
	  (let ((string (match-string 0))
		(file (match-string 1))
		(edges (window-inside-pixel-edges
			(get-buffer-window (current-buffer)))))
	    (delete-region (match-beginning 0) (match-end 0))
	    (insert-image
	     (create-image
	      file 'imagemagick nil
	      :max-width (truncate
			  (* 0.7 (- (nth 2 edges) (nth 0 edges))))
	      :max-height (truncate
			   (* 0.5 (- (nth 3 edges) (nth 1 edges)))))
	     string)))))))

(defun message-insert-screenshot (delay)
  "Take a screenshot and insert in the current buffer.
DELAY (the numeric prefix) says how many seconds to wait before
starting the screenshotting process.

The `message-screenshot-command' variable says what command is
used to take the screenshot."
  (interactive "p" message-mode)
  (unless (executable-find (car message-screenshot-command))
    (error "Can't find %s to take the screenshot"
	   (car message-screenshot-command)))
  (decf delay)
  (unless (zerop delay)
    (dotimes (i delay)
      (message "Sleeping %d second%s..."
	       (- delay i)
	       (if (= (- delay i) 1)
		   ""
		 "s"))
      (sleep-for 1)))
  (message "Take screenshot")
  (let ((image
	 (with-temp-buffer
	   (set-buffer-multibyte nil)
	   (apply #'call-process
		  (car message-screenshot-command) nil (current-buffer) nil
		  (cdr message-screenshot-command))
	   (buffer-string))))
    (message--yank-media-image-handler 'image/png image)
    (message "")))

(defun message--yank-media-image-handler (type image)
  (set-mark (point))
  (insert-image
   (create-image image (mailcap-mime-type-to-extension type) t
		 :max-width (truncate (* (frame-pixel-width) 0.8))
		 :max-height (truncate (* (frame-pixel-height) 0.8))
		 :scale 1)
   (message--image-part-string type image)
   nil nil t)
  (insert "\n\n"))

(defun message--image-part-string (type image)
  (format "<#part type=\"%s\" disposition=inline data-encoding=base64 raw=t>\n%s\n<#/part>"
          type
	  ;; Get a base64 version of the image -- this avoids later
	  ;; complications if we're auto-saving the buffer and
	  ;; restoring from a file.
	  (with-temp-buffer
	    (set-buffer-multibyte nil)
	    (insert image)
	    (base64-encode-region (point-min) (point-max) t)
	    (buffer-string))))

(declare-function image-crop--content-type "image-crop")
(defun message--update-image-crop (_text image)
  (message--image-part-string (image-crop--content-type image) image))

(declare-function gnus-url-unhex-string "gnus-util")

(defun message-parse-mailto-url (url)
  "Parse a mailto: url."
  (setq url (string-replace "\n" " " url))
  (when (string-match "mailto:/*\\(.*\\)" url)
    (setq url (substring url (match-beginning 1) nil)))
  (setq url (if (string-match "^\\?" url)
		(substring url 1)
	      (if (string-match "^\\([^?]+\\)\\?\\(.*\\)" url)
		  (concat "to=" (match-string 1 url) "&"
			  (match-string 2 url))
		(concat "to=" url))))
  (let (retval pairs cur key val)
    (setq pairs (split-string url "&"))
    (while pairs
      (setq cur (car pairs)
	    pairs (cdr pairs))
      (if (not (string-match "=" cur))
	  nil                           ; Grace
	(setq key (downcase (gnus-url-unhex-string
			     (substring cur 0 (match-beginning 0))))
	      val (gnus-url-unhex-string (substring cur (match-end 0) nil) t))
	(setq cur (assoc key retval))
	(if cur
	    (setcdr cur (cons val (cdr cur)))
	  (setq retval (cons (list key val) retval)))))
    retval))

;;;###autoload
(defun message-mailto (&optional url subject body file-attachments)
  "Command to parse command line mailto: links.
This is meant to be used for MIME handlers: Setting the handler
for \"x-scheme-handler/mailto;\" to \"emacs -f message-mailto %u\"
will then start up Emacs ready to compose mail.  For emacsclient use
  emacsclient -e \\='(message-mailto \"%u\")'

To facilitate the use of this function within window systems that
provide message subject, body and attachments independent of URL
itself, the arguments SUBJECT, BODY and FILE-ATTACHMENTS may also
provide alternative message subject and body text, which is
inserted in lieu of nothing if URL does not incorporate such
information itself, and a list of files to insert as attachments
to the E-mail."
  (interactive)
  ;; <a href="mailto:someone@example.com?subject=This%20is%20the%20subject&cc=someone_else@example.com&body=This%20is%20the%20body">Send email</a>
  (message-mail)
  (message-mailto-1 (or url (pop command-line-args-left))
                    subject body file-attachments))

(defun message-mailto-1 (url &optional subject body file-attachments)
  (let ((args (message-parse-mailto-url url))
        (need-body nil) (need-subject nil))
    (dolist (arg args)
      (unless (equal (car arg) "body")
	(message-position-on-field (capitalize (car arg)))
	(insert (string-replace
		 "\r\n" "\n"
		 (mapconcat #'identity (reverse (cdr arg)) ", ")))))
    (if (assoc "body" args)
        (progn
          (message-goto-body)
          (dolist (body (cdr (assoc "body" args)))
	    (insert body "\n")))

      (setq need-body t))
    (if (assoc "subject" args)
	(message-goto-body)
      (setq need-subject t)
      (message-goto-subject))
    ;; If either one of need-subject and need-body is non-nil then
    ;; attempt to insert the absent information from an external
    ;; SUBJECT or BODY.
    (when (or need-body need-subject)
      (when (and need-body body)
        (message-goto-body)
        (insert body))
      (when (and need-subject subject)
        (message-goto-subject)
        (insert subject)
        (message-goto-body)))
    ;; Subsequently insert each attachment enumerated within
    ;; FILE-ATTACHMENTS.
    (dolist (file file-attachments)
      (mml-attach-file file nil 'attachment))))

(provide 'message)

(make-obsolete-variable 'message-load-hook
                        "use `with-eval-after-load' instead." "28.1")
(run-hooks 'message-load-hook)

;; Local Variables:
;; coding: utf-8
;; End:

;;; message.el ends here
