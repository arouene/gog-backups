;;; gog-backups.el --- Manage GOG backups -*- lexical-binding: t; coding: utf-8; -*-

;; Author: Aurélien Rouëné
;; Maintainer: Aurélien Rouëné
;; Version: 1.1
;; Package-Requires: ((emacs "28.1") (acurl "0.1.0"))
;; Keywords: games, gog, backup

;; This file is not part of GNU Emacs

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; gog-backups is an Emacs mode to back up a GOG library: list of
;; owned games, OS and language selection per game, download of the
;; standalone installers and extras (goodies), incremental storage in
;; a directory tree, and state persisted in an ELD file.
;;
;; Usage:
;;
;;   M-x gog-backups       -- open the *GOG Backups* buffer
;;                            (logs in to GOG when needed)
;;
;; Login (same OAuth flow as the Galaxy client):
;;
;;   M-x gog-backups-login -- log in again and save the token
;;
;; The login fetches the auth page (Galaxy client_id), posts
;; login_check with the user and password (handles TOTP and two-step),
;; exchanges the code for a token, then refreshes the token (5 minute
;; margin) before API requests.  On a reCAPTCHA, Emacs asks to log in
;; with a browser and paste the final URL.
;;
;; All network requests go through acurl, asynchronously: Emacs is
;; never blocked, transient failures (such as 503) are retried with
;; backoff and Retry-After, and downloads resume where they stopped.
;;
;; Main options:
;;
;;   `gog-backups-backup-dir'         root directory of the backups
;;                                    (one subdirectory per game)
;;   `gog-backups-data-file'          ELD persistence file
;;                                    (token, games, versions, dirs)
;;   `gog-backups-os-list'            OS downloaded by default
;;   `gog-backups-lang-list'          default languages
;;   `gog-backups-user-function'      function returning the GOG login
;;                                    (nil = prompt)
;;   `gog-backups-password-function'  function returning the password
;;                                    (password-store, auth-source or
;;                                    `read-passwd')
;;   `gog-backups-verify-md5'         check the MD5 provided by GOG
;;   `gog-backups-verify-zip'         check the integrity of .zip files
;;   `gog-backups-retry-count'        attempts per request
;;   `gog-backups-request-timeout'    timeout of stalled requests
;;
;; The password is never stored in the ELD file; it is requested on
;; each login through `gog-backups-password-function'.
;;
;; List buffer (`gog-backups-mode', tabulated-list):
;;
;;   Columns: Mark | Title | State | Backup version |
;;            Online version | OS | Lang | Size
;;   State: NEW (not backed up), OK (up to date), UPDATE (update
;;   available, highlighted with `gog-backups-update-face').
;;
;;   g / u   refresh the library from GOG
;;   m       mark/unmark the game for backup
;;   o       choose the OS of the game at point
;;   l       choose the languages of the game at point
;;   B       back up the marked games
;;   RET     open the backup directory of the game in Dired
;;   / n     filter by name
;;   / s     filter by state (NEW/OK/UPDATE)
;;   / o     filter by OS
;;   / l     filter by language
;;   / /     clear the filter
;;   q       quit
;;
;; Backups:
;;
;;   Files go to `<gog-backups-backup-dir>/<Game title>/', named after
;;   the real GOG file name (Content-Disposition or final CDN URL).
;;   Downloads are atomic and checked with the MD5 when GOG provides
;;   one before they replace an existing file.  A file already present with the right size is never
;;   downloaded again (incremental backups).  Patches and hotfixes are
;;   skipped; only standalone installers (setup_*) and extras are
;;   downloaded.  Progress is logged to the *GOG Backups Log* buffer.
;;
;; Public commands:
;;
;;   `gog-backups'                open the list buffer
;;   `gog-backups-login'          log in again and save the token
;;   `gog-backups-refresh'        sync the library again
;;   `gog-backups-run'            back up the marked games
;;
;; Hooks:
;;
;;   `gog-backups-after-fetch-library-hook' after the library is fetched
;;   `gog-backups-before-backup-hook'       before each game backup
;;                                          (argument: the game)
;;   `gog-backups-after-backup-hook'        after each game backup
;;                                          (argument: the game)
;;   `gog-backups-all-backups-done-hook'    after all marked games are
;;                                          backed up
;;
;; Faces:
;;
;;   `gog-backups-update-face' (warning), `gog-backups-ok-face'
;;   (success), `gog-backups-new-face' (default).
;;
;; Tests: `make' runs the byte-compilation, checkdoc and the ERT tests
;; of test/gog-backups-test.el.

;;; Code:

(require 'acurl)
(require 'cl-lib)
(require 'dired)
(require 'tabulated-list)
(require 'url-util)

(defgroup gog-backups nil "GOG backups." :group 'games)

(defcustom gog-backups-backup-dir
  (expand-file-name "Gog backups" "~")
  "Root directory of the backups, with one subdirectory per game."
  :type 'directory
  :group 'gog-backups)

(defcustom gog-backups-data-file
  (expand-file-name "gog-backups.eld" user-emacs-directory)
  "ELD persistence file (user, token, games, versions)."
  :type 'file
  :group 'gog-backups)

(defcustom gog-backups-os-list '(windows)
  "OS downloaded by default."
  :type '(repeat (choice (const windows) (const linux) (const mac)))
  :group 'gog-backups)

(defcustom gog-backups-lang-list
  (list (if (string-prefix-p "French" (or current-language-environment "en"))
            "fr" "en"))
  "Languages downloaded by default (the system language by default)."
  :type '(repeat string)
  :group 'gog-backups)

(defcustom gog-backups-password-function #'read-passwd
  "Function called to get the GOG password.
It is called with a PROMPT string and returns the password, for
instance (lambda (p) (auth-source-pick-first-password ...)) or
\(lambda (p) (password-store-get \"gog.com\"))."
  :type 'function
  :group 'gog-backups)

(defcustom gog-backups-user-function nil
  "Function returning the GOG login, or nil to prompt for it."
  :type '(choice function (const nil))
  :group 'gog-backups)

(defcustom gog-backups-verify-zip nil
  "If non-nil, check the integrity of downloaded .zip files."
  :type 'boolean
  :group 'gog-backups)

(defcustom gog-backups-verify-md5 t
  "If non-nil, check the MD5 of files when GOG provides it."
  :type 'boolean
  :group 'gog-backups)

(make-obsolete-variable 'gog-backups-retry-delay 'acurl-retry-base-delay "1.1")

(defcustom gog-backups-retry-count 4
  "Maximum number of attempts of a request on transient errors.
Transient errors include HTTP 503 and network failures; downloads
resume where they stopped on each attempt."
  :type 'integer
  :group 'gog-backups)

(defcustom gog-backups-request-timeout 30
  "Delay in seconds after which a stalled request is abandoned.
API requests must complete within this delay.  Downloads are only
interrupted when no data arrives during this delay, then resume
with a range request on the next attempt."
  :type 'integer
  :group 'gog-backups)

;;;; Hooks

(defvar gog-backups-after-fetch-library-hook nil
  "Hook run after the list of owned games is fetched.")

(defvar gog-backups-before-backup-hook nil
  "Hook run before each game backup, with the game as argument.")

(defvar gog-backups-after-backup-hook nil
  "Hook run after each game backup, with the game as argument.")

(defvar gog-backups-all-backups-done-hook nil
  "Hook run when all the marked games are backed up.")

;;;; Faces

(defface gog-backups-update-face
  '((t :inherit warning))
  "Face for games with an available update."
  :group 'gog-backups)

(defface gog-backups-ok-face
  '((t :inherit success))
  "Face for games backed up and up to date."
  :group 'gog-backups)

(defface gog-backups-new-face
  '((t :inherit default))
  "Face for games not backed up yet."
  :group 'gog-backups)

;;;; Constants

(defvar gog-backups--client-id "46899977096215655"
  "Client ID used for OAuth2 authentication.")

(defvar gog-backups--client-secret "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
  "Client secret used for OAuth2 authentication.")

(defvar gog-backups--auth-url "https://auth.gog.com/auth")

(defvar gog-backups--token-url "https://auth.gog.com/token")

(defvar gog-backups--login-url "https://login.gog.com/login_check")

(defvar gog-backups--redirect-url
  "https://embed.gog.com/on_login_success?origin=client")

(defvar gog-backups--library-url
  "https://www.gog.com/account/getFilteredProducts")

(defvar gog-backups--game-details-url
  "https://www.gog.com/account/gameDetails/%s.json")

(defvar gog-backups--token-refresh-margin 300
  "Refresh the token when it expires in less than this many seconds.")

(defvar gog-backups--buffer-name
  "*GOG Backups*"
  "Name of the GOG Backups list buffer.")

(defvar gog-backups--os-choices '("windows" "linux" "mac"))

(defvar gog-backups--lang-choices '("en" "fr"))

;;;; State

(defvar gog-backups--data nil
  "Persisted plist: :version :user :token :os-list :games.")

(defvar gog-backups--filter nil
  "Filter of the list buffer, a plist (:name :state :os :lang).")

(defvar gog-backups--progress nil
  "Last progress message.")

(defvar gog-backups--saved-title-format nil
  "Value of `frame-title-format' saved during a GOG operation.")

(defvar gog-backups--busy nil
  "Non-nil when an operation is running (refresh, backup, login).")

(defmacro gog-backups--acquire-lock (label &rest body)
  "Run BODY holding the global lock, named LABEL.
Signal a `user-error' if an operation is already running.  BODY or the
callbacks it starts must call `gog-backups--release-lock'; an error or
a quit during BODY releases the lock."
  (declare (indent 1))
  `(progn
     (when gog-backups--busy
       (user-error "An operation is already running: %s"
                   gog-backups--busy))
     (setq gog-backups--busy ,label)
     (condition-case err
         (progn ,@body)
       ((error quit)
        (gog-backups--release-lock)
        (signal (car err) (cdr err))))))

(defun gog-backups--release-lock ()
  "Release the global lock and refresh the list buffer."
  (setq gog-backups--busy nil)
  (gog-backups--progress-done)
  (let ((buf (get-buffer gog-backups--buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'gog-backups-mode)
          (let ((id (tabulated-list-get-id)))
            (gog-backups--refresh-list)
            (when id
              (gog-backups--goto-id id))))))))

(defun gog-backups--update-title ()
  "Show the progress in the frame title and the list buffer header line."
  (let ((buf (get-buffer gog-backups--buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if gog-backups--progress
            (setq header-line-format
                  (concat " GOG — " gog-backups--progress))
          ;; Done: restore the tabulated-list header.
          (tabulated-list-init-header))
        (force-mode-line-update t))))
  (if gog-backups--progress
      (progn
        (unless gog-backups--saved-title-format
          (setq gog-backups--saved-title-format frame-title-format))
        (setq frame-title-format
              (concat "GOG " gog-backups--progress)))
    ;; End of the operation: restore the title.
    (when gog-backups--saved-title-format
      (setq frame-title-format gog-backups--saved-title-format
            gog-backups--saved-title-format nil))))

(defun gog-backups--progress-done ()
  "Clear the progress and restore the frame title."
  (setq gog-backups--progress nil)
  (gog-backups--update-title)
  (message "GOG Refresh: done"))

(defun gog-backups--log (format &rest args)
  "Log a progress message built from FORMAT and ARGS.
The message goes to *GOG Backups Log* and the frame title, not to the
echo area, to avoid spam."
  (setq gog-backups--progress (apply #'format format args))
  (gog-backups--update-title)
  (with-current-buffer (get-buffer-create "*GOG Backups Log*")
    (goto-char (point-max))
    (insert gog-backups--progress "\n")))

;;;; ELD persistence

(defun gog-backups--games ()
  "Return the list of games."
  (plist-get gog-backups--data :games))

(defun gog-backups--set-games (games)
  "Set the list of games to GAMES."
  (setq gog-backups--data (plist-put gog-backups--data :games games)))

(defun gog-backups--game-put (game key val)
  "Return GAME with KEY set to VAL."
  (plist-put game key val))

(defun gog-backups--game-by-id (id)
  "Return the game whose id is ID, or nil."
  (cl-find id (gog-backups--games) :key (lambda (g) (plist-get g :id))))

(defun gog-backups--token ()
  "Return the stored token plist."
  (plist-get gog-backups--data :token))

(defun gog-backups--set-token (token)
  "Store TOKEN."
  (setq gog-backups--data (plist-put gog-backups--data :token token)))

(defun gog-backups--save-data ()
  "Save `gog-backups--data' to `gog-backups-data-file' atomically."
  (let ((file gog-backups-data-file))
    (unless (file-directory-p (directory-file-name (file-name-directory file)))
      (error "Directory does not exist: %s"
             (file-name-directory file)))
    (let ((tmp (make-temp-file (concat file ".tmp"))))
      (with-temp-file tmp
        (pp (or gog-backups--data '(:version 1)) (current-buffer)))
      (copy-file tmp file t)
      (delete-file tmp))))

(defun gog-backups--load-data ()
  "Load `gog-backups--data' from `gog-backups-data-file'.
A corrupted file yields nil without error."
  (setq gog-backups--data nil)
  (when (file-exists-p gog-backups-data-file)
    (setq gog-backups--data
          (with-demoted-errors "gog-backups: corrupted ELD file: %S"
            (with-temp-buffer
              (insert-file-contents gog-backups-data-file)
              (goto-char (point-min))
              (condition-case nil
                  (read (current-buffer))
                (end-of-file nil))))))
  gog-backups--data)

(defun gog-backups--save-data-or-msg ()
  "Save the data, showing the error message on failure."
  (condition-case err
      (gog-backups--save-data)
    (error (message "%s" (error-message-string err)))))

;;;; HTTP layer

(defun gog-backups--query-string (params)
  "Encode PARAMS, a list of (NAME VALUE), as a query string."
  (url-build-query-string params nil t))

(defun gog-backups--json-parse (body)
  "Parse the JSON string BODY into an alist, or return nil."
  (condition-case nil
      (json-parse-string body
                         :object-type 'alist
                         :array-type 'list
                         :false-object nil
                         :null-object nil)
    (error nil)))

(defun gog-backups--guard (fn &rest args)
  "Apply FN to ARGS, aborting the current operation on error or quit.
Network callbacks run from process sentinels, where an error would
leave the global lock held: log the error, release the lock and show
the error."
  (condition-case err
      (apply fn args)
    ((error quit)
     (gog-backups--log "error: %s" (error-message-string err))
     (gog-backups--release-lock)
     (message "%s" (error-message-string err)))))

(defun gog-backups--log-error (url err)
  "Log the `acurl-error' ERR of the request to URL."
  (let ((url (car (split-string url "?")))
        (code (acurl-error-code err)))
    (cond
     ((not (eq (acurl-error-type err) 'http))
      (gog-backups--log "network error: %s (%s)" url (acurl-error-message err)))
     ((memq code '(401 403))
      (gog-backups--log "access denied (%s): log in again (M-x gog-backups-login), then g" code))
     (t (gog-backups--log "HTTP error %s: %s" code url)))))

(defun gog-backups--request (url callback &rest args)
  "Start an asynchronous request to URL and call CALLBACK with the result.
CALLBACK receives the `acurl-response', or nil after the failure is
logged.  ARGS are keyword arguments of `acurl-request' and take
precedence over the defaults set here."
  (apply #'acurl-request url
         (append args
                 (list :timeout gog-backups-request-timeout
                       :max-attempts gog-backups-retry-count
                       :on-success (lambda (resp)
                                     (gog-backups--guard callback resp))
                       :on-error (lambda (err)
                                   (gog-backups--log-error url err)
                                   (gog-backups--guard callback nil))))))

(defun gog-backups--auth-headers ()
  "Return the Authorization header of the access token."
  (list (cons "Authorization"
              (concat "Bearer "
                      (plist-get (gog-backups--token) :access_token)))))

(defun gog-backups--api-get (url callback)
  "GET the GOG API URL with the access token.
Call CALLBACK with the parsed JSON body, or nil on failure."
  (gog-backups--ensure-token
   (lambda ()
     (gog-backups--request
      url
      (lambda (resp)
        (funcall callback
                 (and resp (gog-backups--json-parse (acurl-response-body resp)))))
      :headers (gog-backups--auth-headers)))))

;;;; Login

(defun gog-backups--extract-code (url body)
  "Extract the OAuth code from URL, or from the JavaScript BODY.
The login_check response can be a JavaScript page embedding the code
as JSON (gogData Auth.AuthCode) instead of a redirection with ?code=."
  (or (and (string-match "[?&]code=\\([^&]+\\)" url)
           (match-string 1 url))
      (and body
           (string-match "\\\"code\\\":\\\"\\([^\\\"]+\\)\\\"" body)
           (match-string 1 body))))

(defun gog-backups--extract-input-token (html id)
  "Extract the value of the hidden input whose id is ID from HTML."
  (cond ((string-match (format "<input[^>]*id=\"%s\"[^>]*value=\"\\([^\"]*\\)\"" id) html)
         (match-string 1 html))
        ((string-match (format "<input[^>]*value=\"\\([^\"]*\\)\"[^>]*id=\"%s\"" id) html)
         (match-string 1 html))))

(defun gog-backups--extract-login-token (html)
  "Extract the hidden login__token field from the auth page HTML."
  (gog-backups--extract-input-token html "login__token"))

(defun gog-backups--login-response-kind (url)
  "Classify the login response URL: `totp', `two-step', `success' or `unknown'."
  (cond ((string-match-p "totp" url) 'totp)
        ((string-match-p "two_step" url) 'two-step)
        ((string-match-p "on_login_success" url) 'success)
        (t 'unknown)))

(defun gog-backups--parse-token-json (body)
  "Parse the token endpoint response BODY.
Return a plist (:access_token :refresh_token :expiry), or nil."
  (let* ((json (gog-backups--json-parse body))
         (at (cdr (assoc 'access_token json)))
         (rt (cdr (assoc 'refresh_token json)))
         (exp (cdr (assoc 'expires_in json))))
    (when at
      (list :access_token at
            :refresh_token rt
            :expiry (+ (float-time) (or exp 3600))))))

(defun gog-backups--token-expired-p ()
  "Return non-nil if the access token is missing or expires soon."
  (let ((token (gog-backups--token)))
    (or (null token)
        (null (plist-get token :access_token))
        (< (or (plist-get token :expiry) 0)
           (+ (float-time) gog-backups--token-refresh-margin)))))

(defun gog-backups--fetch-token (grant callback)
  "Get a token from the token endpoint with the GRANT parameters.
GRANT is a list of (NAME VALUE).  Store and save the token, then call
CALLBACK with it, or with nil on failure."
  (gog-backups--request
   (concat gog-backups--token-url "?"
           (gog-backups--query-string
            `(("client_id" ,gog-backups--client-id)
              ("client_secret" ,gog-backups--client-secret)
              ,@grant
              ("redirect_uri" ,gog-backups--redirect-url))))
   (lambda (resp)
     (let ((token (and resp (gog-backups--parse-token-json
                             (acurl-response-body resp)))))
       (when token
         (gog-backups--set-token token)
         (gog-backups--save-data-or-msg))
       (funcall callback token)))))

(defun gog-backups--ensure-token (callback)
  "Call CALLBACK without argument once the access token is valid.
Refresh an expiring token, or log in when there is no refresh token."
  (let ((refresh (plist-get (gog-backups--token) :refresh_token)))
    (cond
     ((not (gog-backups--token-expired-p)) (funcall callback))
     (refresh
      (gog-backups--fetch-token
       `(("grant_type" "refresh_token") ("refresh_token" ,refresh))
       (lambda (token)
         (unless token
           (error "Token refresh failed, log in again"))
         (funcall callback))))
     (t (gog-backups--login (lambda (_token) (funcall callback)))))))

(defun gog-backups--login (callback)
  "Log in to GOG, store the token and call CALLBACK with it.
The session cookies live in a temporary curl cookie jar, deleted when
the code is obtained or the login fails.

Reference: https://gogapidocs.readthedocs.io/en/latest/auth.html"
  (let* ((user (or (and gog-backups-user-function
                        (funcall gog-backups-user-function))
                   (read-string "GOG user: ")))
         (pass (funcall gog-backups-password-function "GOG password: "))
         (cookies (make-temp-file "gog-backups-cookies-")))
    (cl-labels
        ((protect (fn &rest args)
           ;; Delete the session cookies when the login fails.
           (condition-case err
               (apply fn args)
             ((error quit)
              (delete-file cookies)
              (signal (car err) (cdr err)))))
         (send (url fn &rest args)
           (apply #'protect #'gog-backups--request url
                  (lambda (resp)
                    (protect (lambda ()
                               (unless resp
                                 (error "Request failed: %s" url))
                               (funcall fn resp))))
                  :extra-args (list "--cookie" cookies "--cookie-jar" cookies)
                  args))
         (post (url params fn)
           (send url fn
                 :method "POST"
                 :headers '(("Content-Type" . "application/x-www-form-urlencoded"))
                 :body (gog-backups--query-string params)))
         (exchange (code)
           (delete-file cookies)
           (unless code (error "No authorization code obtained"))
           (gog-backups--fetch-token
            `(("grant_type" "authorization_code") ("code" ,code))
            (lambda (token)
              (unless token
                (error "Exchange of the code for a token failed"))
              (funcall callback token))))
         (finish (resp)
           (let ((url (acurl-response-url resp)))
             (exchange (and (eq (gog-backups--login-response-kind url) 'success)
                            (gog-backups--extract-code
                             url (acurl-response-body resp))))))
         (second-step (resp form digits prompt)
           ;; FORM is the name of the TOTP or two-step form, whose code
           ;; is sent one digit per field.
           (let ((code (read-string prompt))
                 (token (gog-backups--extract-input-token
                         (acurl-response-body resp) (concat form "__token"))))
             (post (acurl-response-url resp)
                   (append
                    (cl-loop for i from 0 below (min digits (length code))
                             collect (list (format "%s[token][letter_%d]" form (1+ i))
                                           (substring code i (1+ i))))
                    (list (list (concat form "[send]") ""))
                    (and token (list (list (concat form "[_token]") token))))
                   #'finish))))
      (send
       (concat gog-backups--auth-url "?"
               (gog-backups--query-string
                `(("client_id" ,gog-backups--client-id)
                  ("redirect_uri" ,gog-backups--redirect-url)
                  ("response_type" "code")
                  ("layout" "client2"))))
       (lambda (resp)
         (let ((login-token (gog-backups--extract-login-token
                             (acurl-response-body resp))))
           (if (not login-token)
               ;; reCAPTCHA or unexpected page: fall back to a browser.
               (progn
                 (gog-backups--log
                  "reCAPTCHA detected: log in with a browser, then paste the final URL containing code=")
                 (exchange (gog-backups--extract-code
                            (read-string "Login URL (containing code=): ")
                            nil)))
             (post gog-backups--login-url
                   `(("login[username]" ,user)
                     ("login[password]" ,pass)
                     ("login[login]" "")
                     ("login[login_flow]" "default")
                     ("login[_token]" ,login-token))
                   (lambda (resp)
                     (pcase (gog-backups--login-response-kind
                             (acurl-response-url resp))
                       ('success (finish resp))
                       ('totp (second-step resp "two_factor_totp_authentication"
                                           6 "Code Authenticator (TOTP): "))
                       ('two-step (second-step resp "second_step_authentication"
                                               4 "Code two-step: "))
                       (_ (error "Login failed, check the credentials"))))))))))))

;;;; Library

(defun gog-backups--fetch-library (done)
  "Fetch the whole library and the details of each game.
Call DONE with the list of games, or with nil when aborted."
  (let (products details)
    (cl-labels
        ((finish ()
           (let ((games (gog-backups--build-games products details)))
             (gog-backups--set-games games)
             (gog-backups--save-data-or-msg)
             (run-hooks 'gog-backups-after-fetch-library-hook)
             (funcall done games)))
         (get-details (ids)
           (if (null ids)
               (finish)
             (let ((id (car ids)))
               (gog-backups--log "Details %d/%d"
                                 (- (length products) (length ids) -1)
                                 (length products))
               (gog-backups--api-get
                (format gog-backups--game-details-url id)
                (lambda (json)
                  (when json
                    (push (cons id json) details))
                  (get-details (cdr ids)))))))
         (get-page (page)
           (gog-backups--api-get
            (concat gog-backups--library-url "?"
                    (gog-backups--query-string
                     `(("mediaType" "1")
                       ("sortBy" "title")
                       ("page" ,(number-to-string page)))))
            (lambda (json)
              (if (not json)
                  (funcall done nil)
                (setq products (append products (cdr (assoc 'products json))))
                (if (< page (or (cdr (assoc 'totalPages json)) 1))
                    (get-page (1+ page))
                  (gog-backups--log
                   "Library: %d games, fetching the details..."
                   (length products))
                  (get-details (mapcar (lambda (p) (cdr (assoc 'id p)))
                                       products))))))))
      (get-page 1))))

(defun gog-backups--build-games (products details)
  "Build the list of games from PRODUCTS and DETAILS.
DETAILS is an alist (ID . GAME-DETAILS).  The existing preferences of
each game (os-list, lang-list, selected...) are preserved."
  (let (games)
    (dolist (p products)
      (let* ((id (cdr (assoc 'id p)))
             (title (cdr (assoc 'title p)))
             (slug (cdr (assoc 'slug p)))
             (old (gog-backups--game-by-id id))
             (details (cdr (assoc id details)))
             (os-list (or (plist-get old :os-list) gog-backups-os-list))
             (lang-list (or (plist-get old :lang-list) gog-backups-lang-list))
             (installers (gog-backups--extract-installers
                          details os-list lang-list slug))
             (os-avail (or (plist-get old :os-available)
                           (gog-backups--available-os details)))
             (lang-avail (or (plist-get old :lang-available)
                             (gog-backups--available-lang details)))
             (extras (gog-backups--collect-extras details))
             (online-version (or (plist-get (car installers) :version)
                                 (plist-get old :online-version))))
        (push (list :id id
                    :slug slug
                    :title title
                    :updates (cdr (assoc 'updates p))
                    :online-version online-version
                    :os-list os-list
                    :lang-list lang-list
                    :os-available os-avail
                    :lang-available lang-avail
                    :selected (plist-get old :selected)
                    :backed-up (plist-get old :backed-up)
                    :backup-version (plist-get old :backup-version)
                    :last-backup (plist-get old :last-backup)
                    :files (plist-get old :files)
                    :installers installers
                    :extras extras)
              games)))
    (nreverse games)))

(defun gog-backups--installer-keep-p (manual-url)
  "Return non-nil if MANUAL-URL is a main standalone installer.
GOG download paths contain \"installer\" for full installers and
\"patch\" for patches."
  (and (string-match-p "installer" manual-url)
       (not (string-match-p "patch\\|hotfix" manual-url))))

(defun gog-backups--os-pairs (lang-rest)
  "Return the list of (OS ENTRIES...) pairs of LANG-REST.
LANG-REST is what follows the language key.  In the GOG format, it is
a list holding an osmap such as ((windows ENTRIES...))."
  (let ((pairs nil))
    (dolist (x lang-rest)
      (cond
       ((atom x) (push x pairs))           ; Unlikely key atom.
       ((atom (car x)) (push x pairs))     ; X is (os . entries).
       (t (setq pairs (append pairs x))))) ; X is an osmap ((os . e) ...).
    (nreverse pairs)))

(defun gog-backups--installer-filename (slug version name)
  "Build a stable file name for a GOG installer.
The real name, with its extension, is only known when downloading,
from the CDN response; this name is a stable key for the logs and the
download check.  NAME is the GOG title such as \"Loop Hero (Part 1 of
2)\", SLUG the slug of the game (can be nil) and VERSION the GOG version
string."
  (let ((base (concat "setup_"
                      (if slug
                          (replace-regexp-in-string "[^a-z0-9]" "_" slug)
                        "game")
                      (when version
                        (concat "_"
                                (replace-regexp-in-string
                                 "[ /]" "_" version)))))
        (part (and name
                   (string-match "(Part \\([0-9]+\\) of" name)
                   (string-to-number (match-string 1 name)))))
    (if (and part (> part 1))
        (format "%s-%d" base (1- part))
      base)))

(defun gog-backups--available-os (details)
  "Return the OS symbols available in DETAILS (keys of the osmaps)."
  (let ((oses))
    (dolist (dl (cdr (assoc 'downloads details)))
      (dolist (os (gog-backups--os-pairs (cdr dl)))
        (let ((o (car os)))
          (when (symbolp o)
            (cl-pushnew o oses)))))
    (nreverse oses)))

(defun gog-backups--available-lang (details)
  "Return the languages available in DETAILS (keys of downloads)."
  (let ((langs))
    (dolist (dl (cdr (assoc 'downloads details)))
      (let ((l (car dl)))
        (when (stringp l) (cl-pushnew l langs :test #'string=))))
    (nreverse langs)))

(defun gog-backups--extract-installers (details os-list lang-list &optional slug)
  "Extract the standalone installers of DETAILS for OS-LIST and LANG-LIST.
In the GOG format, downloads is a list of (\"English\" . OSMAP) pairs
whose entries have a manualUrl, a name, a version and a size string
\(\"1 MB\").  Patches are skipped; the download URL is
https://www.gog.com<manualUrl>.  SLUG is the slug of the game."
  (let ((result))
    (dolist (dl (cdr (assoc 'downloads details)))
      (let ((lang (car dl)))
        (when (and lang (or (string= lang "*")
                            (gog-backups--lang-match-p lang lang-list)))
          (dolist (os (gog-backups--os-pairs (cdr dl)))
            (when (member (car os) os-list)
              (dolist (entry (cdr os))
                (let ((name (cdr (assoc 'name entry)))
                      (murl (cdr (assoc 'manualUrl entry))))
                  (when (and (stringp name)
                             (stringp murl)
                             (gog-backups--installer-keep-p murl))
                    (push
                     (list :name (gog-backups--installer-filename
                                  slug
                                  (cdr (assoc 'version entry))
                                  name)
                           :version (cdr (assoc 'version entry))
                           :size (gog-backups--parse-size
                                  (cdr (assoc 'size entry)))
                           :downlink (concat "https://www.gog.com" murl)
                           :manualUrl murl)
                     result)))))))))
    (nreverse result)))

(defun gog-backups--lang-match-p (lang lang-list)
  "Return non-nil if LANG matches one of the languages of LANG-LIST.
LANG is a GOG language such as \"English\" or \"fr-FR\"; LANG-LIST holds
short codes (\"en\", \"fr\") or full names."
  (or (member lang lang-list)
      (cl-some (lambda (l)
                 (or (string-prefix-p l lang)
                     (and (>= (length lang) 2)
                          (member (downcase (substring lang 0 2)) lang-list))))
               lang-list)))

(defun gog-backups--parse-size (size)
  "Convert a GOG SIZE (\"1 MB\", \"4 GB\", a number) to bytes, or nil."
  (cond ((numberp size) size)
        ((stringp size)
         (when (string-match "\\`\\([0-9.]+\\)\\s-*\\(GB?\\|MB?\\|KB?\\|B\\)\\'" size)
           (let ((v (string-to-number (match-string 1 size)))
                 (u (upcase (match-string 2 size))))
             (round
              (* v
                 (cond ((member u '("GB" "G")) (* 1024 1024 1024))
                       ((member u '("MB" "M")) (* 1024 1024))
                       ((member u '("KB" "K")) 1024)
                       (t 1)))))))
        (t nil)))

(defun gog-backups--collect-extras (details)
  "Collect all the extras of DETAILS, recursively including the DLCs.
In the GOG format, extras have a manualUrl (no downlink) and a size
string."
  (cl-labels ((walk (node)
                (let ((extras
                       (cl-loop for e in (cdr (assoc 'extras node))
                                for murl = (cdr (assoc 'manualUrl e))
                                when (and (stringp murl)
                                          (string-match-p "extra\\|download\\|/downloads/" murl))
                                collect
                                (list :name (cdr (assoc 'name e))
                                      :size (gog-backups--parse-size
                                             (cdr (assoc 'size e)))
                                      :downlink (concat "https://www.gog.com" murl)
                                      :manualUrl murl))))
                  (append extras
                          (cl-loop for d in (cdr (assoc 'dlcs node))
                                   append (walk d))))))
    (walk details)))

;;;; Backup state

(defun gog-backups--status (game)
  "Return the backup state of GAME: `new', `ok' or `update'."
  (let ((bv (plist-get game :backup-version))
        (ov (plist-get game :online-version)))
    (cond ((or (not bv) (not ov)) 'new)
          ((string= bv ov) 'ok)
          (t 'update))))

(defun gog-backups--status-string (game)
  "Return the backup state of GAME as a string."
  (cl-case (gog-backups--status game)
    (new "NEW") (ok "OK") (update "UPDATE") (t "?")))

(defun gog-backups--game-dir (game)
  "Return the backup directory of GAME: <backup-dir>/<Game title>."
  (expand-file-name
   (plist-get game :title)
   (file-name-as-directory
    (expand-file-name
     (or (plist-get gog-backups--data :backup-dir)
         (directory-file-name gog-backups-backup-dir))))))

(defun gog-backups--ensure-game-dir (game)
  "Create the backup directory of GAME if needed and return it."
  (let ((dir (gog-backups--game-dir game)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun gog-backups--human-size (bytes)
  "Return BYTES as a human readable size."
  (cond ((< bytes 1024) (format "%d B" bytes))
        ((< bytes (* 1024 1024)) (format "%.1f KiB" (/ bytes 1024.0)))
        ((< bytes (* 1024 1024 1024)) (format "%.1f MiB" (/ bytes 1024.0 1024)))
        (t (format "%.1f GiB" (/ bytes 1024.0 1024 1024)))))

(defun gog-backups--files-size (game)
  "Return the total size of the files of GAME as a human readable string.
The value in bytes is in the `gog-backups-bytes' text property, for
numeric sorting."
  (let ((total 0) known)
    (dolist (f (append (plist-get game :installers) (plist-get game :extras)))
      (let ((s (plist-get f :size)))
        (when (numberp s)
          (setq known t total (+ total s)))))
    (if known
        (propertize (gog-backups--human-size total)
                    'gog-backups-bytes total)
      "-")))

(defun gog-backups--sort-size-cell (entry)
  "Return the Size cell of the tabulated-list ENTRY.
Accept a bare vector, (id . [cols]) or (id . ([cols])).  Look for the
cell with the `gog-backups-bytes' property, else return column 7."
  (let ((vec (cond ((vectorp entry) entry)
                   ((and (consp entry) (vectorp (cdr entry))) (cdr entry))
                   ((and (consp entry) (consp (cdr entry))
                         (vectorp (car (cdr entry))))
                    (car (cdr entry)))
                   (t nil))))
    (when (vectorp vec)
      (or (cl-find-if (lambda (c)
                        (and (stringp c)
                             (get-text-property 0 'gog-backups-bytes c)))
                      vec)
          (and (> (length vec) 7) (aref vec 7))))))

(defun gog-backups--sort-by-size (a b)
  "Return non-nil if the Size of entry A is smaller than the one of B.
Cells carry the `gog-backups-bytes' property; without it, compare
them as strings."
  (let* ((ca (gog-backups--sort-size-cell a))
         (cb (gog-backups--sort-size-cell b))
         (av (and (stringp ca) (get-text-property 0 'gog-backups-bytes ca)))
         (bv (and (stringp cb) (get-text-property 0 'gog-backups-bytes cb))))
    (cond ((and (numberp av) (numberp bv)) (< av bv))
          ((numberp av) t)
          ((numberp bv) nil)
          (t (string< (format "%s" ca) (format "%s" cb))))))

;;;; Download

(defun gog-backups--verify-md5 (file md5)
  "Return non-nil if the MD5 of FILE is MD5."
  (and md5
       (string=
        (with-temp-buffer
          (insert-file-contents-literally file)
          (secure-hash 'md5 (current-buffer)))
        (downcase md5))))

(defun gog-backups--zip-ok-p (file)
  "Return nil if FILE is a .zip without the PK signature.
Only check when `gog-backups-verify-zip' is non-nil."
  (or (not gog-backups-verify-zip)
      (not (string-match-p "\\.zip\\'" file))
      (string-prefix-p "PK" (with-temp-buffer
                              (insert-file-contents-literally file nil 0 4)
                              (buffer-string)))))

(defun gog-backups--check-download (resp md5 dir)
  "Check the file downloaded by the `acurl-response' RESP and move it to DIR.
The file replaces a file of the same name in DIR.  Return its new
name, or delete it and return nil when it does not match MD5 or is a
corrupted zip."
  (let* ((file (acurl-response-file resp))
         (target (expand-file-name (file-name-nondirectory file) dir))
         (err (cond ((and md5 gog-backups-verify-md5
                          (not (gog-backups--verify-md5 file md5)))
                     "invalid MD5")
                    ((not (gog-backups--zip-ok-p file))
                     "invalid zip"))))
    (if err
        (progn
          (delete-file file)
          (gog-backups--log "error: %s: %s" target err)
          nil)
      (rename-file file target t)
      (gog-backups--log "ok: %s (%s)"
                        (file-name-nondirectory target)
                        (gog-backups--human-size (acurl-response-size resp)))
      target)))

(defun gog-backups--download-file (url dir md5 callback)
  "Download URL into DIR without blocking Emacs.
The file is named after the Content-Disposition header or the final
URL, which hold the real GOG file name.  It is downloaded into a
staging subdirectory of DIR and replaces a file of the same name in
DIR only once checked, so a failed download keeps the previous backup.
MD5, when non-nil, is the expected checksum.  Call CALLBACK with the
file name, or nil on failure."
  (let ((staging (expand-file-name ".gog-staging" dir)))
    (gog-backups--ensure-token
     (lambda ()
       (make-directory staging t)
       (gog-backups--request
        url
        (lambda (resp)
          (let ((file (and resp (gog-backups--check-download resp md5 dir))))
            (ignore-errors (delete-directory staging))
            (funcall callback file)))
        :output (file-name-as-directory staging)
        :overwrite t
        :headers (gog-backups--auth-headers)
        ;; Only abort stalled transfers: a large download takes longer
        ;; than any total timeout, and the next attempt resumes it.
        :timeout nil
        :extra-args (list "--speed-limit" "1" "--speed-time"
                          (number-to-string gog-backups-request-timeout)))))))

(defun gog-backups--download-need-p (dir file)
  "Return non-nil if FILE must be downloaded into DIR.
The real name of installers is only known from the CDN response: when
no file has the predicted name, look in DIR for a file of the expected
size, since GOG names include a build number that changes between
versions."
  (let* ((path (expand-file-name (plist-get file :name) dir))
         (size (plist-get file :size))
         (actual (and (file-exists-p path)
                      (file-attribute-size (file-attributes path))))
         ;; The GOG size is a rounded string ("185 MB"): never compare
         ;; strictly, allow 2% or 1 MiB.
         (tolerance (and size (max (floor (* 0.02 size)) 1048576))))
    (cond
     ((not actual) t)
     ((not size) nil)
     ((<= (abs (- actual size)) tolerance) nil)
     ;; Wrong size: look for a file of the right size, backed up under
     ;; another build name.
     (t (not (cl-find-if
              (lambda (n)
                (and (not (string-suffix-p ".tmp" n))
                     (<= (abs (- (file-attribute-size
                                  (file-attributes
                                   (expand-file-name n dir)))
                                 size))
                         tolerance)))
              (directory-files dir)))))))

;;;; Backup

(defun gog-backups--replace-game (game)
  "Replace the stored game with the id of GAME by GAME."
  (gog-backups--set-games
   (mapcar (lambda (g)
             (if (equal (plist-get g :id) (plist-get game :id))
                 game g))
           (gog-backups--games))))

(defun gog-backups--backup-finish (game installers extras actual-names
                                        ok done)
  "Record the backup of GAME, run the hooks and call DONE with OK.
ACTUAL-NAMES are the real names of the downloaded files; without them,
the predicted names of INSTALLERS and EXTRAS are recorded."
  (if (not ok)
      (progn
        (gog-backups--log "Incomplete backup: %s" (plist-get game :title))
        (funcall done nil))
    (let ((names (or (nreverse actual-names)
                     (mapcar (lambda (f) (plist-get f :name))
                             (append installers extras)))))
      (setq game (gog-backups--game-put game :backed-up t))
      (setq game (gog-backups--game-put game :backup-version
                                        (plist-get game :online-version)))
      (setq game (gog-backups--game-put
                  game :last-backup (format-time-string "%Y-%m-%d")))
      (setq game (gog-backups--game-put game :files names))
      (gog-backups--replace-game game)
      (gog-backups--save-data-or-msg)
      (run-hook-with-args 'gog-backups-after-backup-hook game)
      (funcall done t))))

(defun gog-backups--backup-game (game done)
  "Back up GAME, then call DONE with t on success or nil."
  (run-hook-with-args 'gog-backups-before-backup-hook game)
  (let* ((dir (gog-backups--ensure-game-dir game))
         (installers (plist-get game :installers))
         (extras (plist-get game :extras))
         (all (append installers extras))
         ;; Already backed up with the same version: nothing to do.
         (uptodate (and (plist-get game :backed-up)
                        (plist-get game :online-version)
                        (string= (or (plist-get game :backup-version) "")
                                 (plist-get game :online-version))))
         (files (unless uptodate
                  (cl-remove-if-not
                   (lambda (f) (gog-backups--download-need-p dir f))
                   all)))
         (ok t)
         (actual-names nil))
    (gog-backups--log "Backup: %s (%d/%d files)"
                      (plist-get game :title) (length files) (length all))
    (cl-labels ((next (rest)
                  (let ((url (plist-get (car rest) :downlink)))
                    (cond
                     ((null rest)
                      (gog-backups--backup-finish game installers extras
                                                  actual-names ok done))
                     ((null url)
                      (gog-backups--log "No URL for %s, skipped"
                                        (plist-get (car rest) :name))
                      (setq ok nil)
                      (next (cdr rest)))
                     (t
                      (gog-backups--log "Downloading: %s"
                                        (plist-get (car rest) :name))
                      (gog-backups--download-file
                       url dir (plist-get (car rest) :md5)
                       (lambda (file)
                         (if file
                             (push (file-name-nondirectory file) actual-names)
                           (setq ok nil))
                         (next (cdr rest)))))))))
      (next files))))

(defun gog-backups--run-backups (games done)
  "Back up GAMES one after the other, then call DONE.
DONE receives t when all the backups succeeded."
  (let ((all-ok t))
    (cl-labels ((next (rest)
                  (if (null rest)
                      (progn
                        (run-hooks 'gog-backups-all-backups-done-hook)
                        (funcall done all-ok))
                    (gog-backups--backup-game
                     (car rest)
                     (lambda (ok)
                       (unless ok (setq all-ok nil))
                       (next (cdr rest)))))))
      (next games))))

;;;; Mode

(defun gog-backups--refresh-list ()
  "Compute the tabulated-list entries for the current filter."
  (setq tabulated-list-entries
        (cl-loop for game in (gog-backups--games)
                 when (gog-backups--match-filter-p game)
                 collect (list (plist-get game :id)
                               (gog-backups--row game))))
  (tabulated-list-print))

(defun gog-backups--row (game)
  "Return the tabulated-list row of GAME."
  (let* ((status (gog-backups--status-string game))
         (title (plist-get game :title))
         (status-face (cl-case (gog-backups--status game)
                        (new 'gog-backups-new-face)
                        (ok 'gog-backups-ok-face)
                        (update 'gog-backups-update-face)))
         (mark (if (plist-get game :selected) "*" ""))
         (os (mapconcat #'symbol-name (plist-get game :os-list) ","))
         (langs (mapconcat #'identity (plist-get game :lang-list) ",")))
    (vector mark
            (propertize (or title "-") 'face status-face)
            (propertize status 'face status-face)
            (propertize (or (plist-get game :backup-version) "-")
                        'face status-face)
            (or (plist-get game :online-version) "-")
            os
            langs
            (gog-backups--files-size game))))

(defvar gog-backups-filter-map
  (let ((map (make-sparse-keymap)))
    (define-key map "n" #'gog-backups-filter-name)
    (define-key map "s" #'gog-backups-filter-state)
    (define-key map "o" #'gog-backups-filter-os)
    (define-key map "l" #'gog-backups-filter-lang)
    (define-key map "/" #'gog-backups-filter-clear)
    map)
  "Keymap of the filters (prefix /).")

(defvar gog-backups-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "g" #'gog-backups-refresh)
    (define-key map "u" #'gog-backups-refresh)
    (define-key map "m" #'gog-backups-toggle-mark)
    (define-key map "o" #'gog-backups-set-os)
    (define-key map "l" #'gog-backups-set-lang)
    (define-key map "B" #'gog-backups-run)
    (define-key map (kbd "RET") #'gog-backups-open-dired)
    (define-key map "q" #'quit-window)
    (define-key map "/" gog-backups-filter-map)
    map)
  "Keymap of `gog-backups-mode'.")

(define-derived-mode gog-backups-mode tabulated-list-mode "GOG-Backups"
  "Major mode for the list of GOG backups."
  (setq tabulated-list-format
        [("Mark" 5 t)
         ("Title" 40 t)
         ("State" 8 t)
         ("Backup version" 20 t)
         ("Online version" 20 t)
         ("OS" 12 t)
         ("Lang" 10 t)
         ("Size" 10 gog-backups--sort-by-size)])
  (setq tabulated-list-sort-key '("Title" . nil))
  (tabulated-list-init-header))

(defun gog-backups--match-filter-p (game)
  "Return non-nil if GAME matches the current filter, if any."
  (let ((f gog-backups--filter))
    (and (or (not (plist-get f :name))
             (string-match-p
              (regexp-quote (plist-get f :name))
              (or (plist-get game :title) "")))
         (or (not (plist-get f :state))
             (string= (plist-get f :state)
                      (gog-backups--status-string game)))
         (or (not (plist-get f :os))
             (member (intern (plist-get f :os))
                     (plist-get game :os-list)))
         (or (not (plist-get f :lang))
             (member (plist-get f :lang)
                     (plist-get game :lang-list))))))

(defun gog-backups--current-game ()
  "Return the game at point, or signal an error."
  (or (gog-backups--game-by-id (tabulated-list-get-id))
      (error "No game at point")))

(defun gog-backups--goto-id (id)
  "Move point to the line whose tabulated-list id is ID."
  (let ((pos (cl-position id tabulated-list-entries :key #'car)))
    (when pos
      (goto-char (point-min))
      (forward-line pos))))

(defun gog-backups--refresh-game-details (game done)
  "Fetch the details of GAME again and update its files.
Extract the installers and extras for its :os-list and :lang-list and
update :os-available and :lang-available.  Call DONE with the updated
game, or with nil on failure."
  (gog-backups--api-get
   (format gog-backups--game-details-url (plist-get game :id))
   (lambda (details)
     (if (not details)
         (funcall done nil)
       (let* ((installers (gog-backups--extract-installers
                           details
                           (plist-get game :os-list)
                           (plist-get game :lang-list)
                           (plist-get game :slug)))
              (online-version (or (plist-get (car installers) :version)
                                  (plist-get game :online-version))))
         (setq game (gog-backups--game-put
                     game :os-available (gog-backups--available-os details)))
         (setq game (gog-backups--game-put
                     game :lang-available (gog-backups--available-lang details)))
         (setq game (gog-backups--game-put game :installers installers))
         (setq game (gog-backups--game-put
                     game :extras (gog-backups--collect-extras details)))
         (setq game (gog-backups--game-put game :online-version online-version))
         (gog-backups--replace-game game)
         (funcall done game))))))

;;;; Filters

(defun gog-backups-filter-name (name)
  "Show only the games with NAME in their title."
  (interactive "sFilter by name: ")
  (setq gog-backups--filter (plist-put gog-backups--filter :name name))
  (gog-backups--refresh-list))

(defun gog-backups-filter-state (state)
  "Show only the games in STATE: NEW, OK or UPDATE."
  (interactive (list (completing-read "State (NEW/OK/UPDATE): "
                                      '("NEW" "OK" "UPDATE"))))
  (setq gog-backups--filter (plist-put gog-backups--filter :state state))
  (gog-backups--refresh-list))

(defun gog-backups-filter-os (os)
  "Show only the games backed up for OS."
  (interactive (list (completing-read "OS: " gog-backups--os-choices)))
  (setq gog-backups--filter (plist-put gog-backups--filter :os os))
  (gog-backups--refresh-list))

(defun gog-backups-filter-lang (lang)
  "Show only the games backed up in LANG."
  (interactive (list (completing-read "Lang: " gog-backups--lang-choices)))
  (setq gog-backups--filter (plist-put gog-backups--filter :lang lang))
  (gog-backups--refresh-list))

(defun gog-backups-filter-clear ()
  "Clear the filter."
  (interactive)
  (setq gog-backups--filter nil)
  (gog-backups--refresh-list))

;;;; Interactive commands

(defun gog-backups-refresh ()
  "Re-sync the game list and details."
  (interactive)
  (gog-backups--acquire-lock "Refreshing"
    (gog-backups--log "updating game library...")
    (gog-backups--fetch-library
     (lambda (games)
       (if games
           (gog-backups--log "game library updated (%d games)" (length games))
         (gog-backups--log "update was interrupted by an error (see *GOG Backups Log*)"))
       (gog-backups--release-lock)))))

(defun gog-backups-run ()
  "Back up the marked games."
  (interactive)
  (let ((marked (cl-remove-if-not (lambda (g) (plist-get g :selected))
                                  (gog-backups--games))))
    (unless marked
      (user-error "No games marked for backup"))
    (gog-backups--acquire-lock "Backing up"
      (gog-backups--run-backups
       marked (lambda (_) (gog-backups--release-lock))))))

(defun gog-backups-login ()
  "Log in and save the token."
  (interactive)
  (gog-backups--acquire-lock "Logging in"
    (gog-backups--login (lambda (_) (gog-backups--release-lock)))))

(defun gog-backups-toggle-mark ()
  "Mark or unmark the game at point for backup."
  (interactive)
  (gog-backups--acquire-lock "Toggling mark"
    (let ((game (gog-backups--current-game)))
      (gog-backups--replace-game
       (gog-backups--game-put game :selected (not (plist-get game :selected)))))
    (gog-backups--release-lock)))

(defun gog-backups-open-dired ()
  "Open the backup directory of the game at point in Dired."
  (interactive)
  (let ((dir (gog-backups--game-dir (gog-backups--current-game))))
    (if (file-directory-p dir)
        (dired dir)
      (message "This directory doesn't exist: %s" dir))))

(defun gog-backups-set-os ()
  "Choose the OS of the game at point to back up.
Each available OS is proposed in turn, then the files of the game are
updated for the new selection."
  (interactive)
  (gog-backups--acquire-lock "Changing OS settings"
    (let* ((game (gog-backups--current-game))
           (avail (or (plist-get game :os-available)
                      (mapcar #'intern gog-backups--os-choices)))
           (current (plist-get game :os-list))
           selected)
      (dolist (os avail)
        (when (y-or-n-p (format (if (member os current)
                                    "Include OS %s? (yes by default) "
                                  "Include OS %s? (no by default) ")
                                os))
          (push os selected)))
      (setq game (gog-backups--game-put game :os-list (nreverse selected)))
      (gog-backups--replace-game game)
      (gog-backups--save-data-or-msg)
      ;; Extract the installers again for the new OS selection.
      (gog-backups--log "Updating the files of %s..."
                        (plist-get game :title))
      (gog-backups--refresh-game-details
       game (lambda (updated)
              (when updated
                (gog-backups--log "Files updated: %s"
                                  (plist-get updated :title)))
              (gog-backups--release-lock))))))

(defun gog-backups-set-lang ()
  "Choose the languages of the game at point."
  (interactive)
  (gog-backups--acquire-lock "Changing Lang settings"
    (let* ((game (gog-backups--current-game))
           (choices (completing-read-multiple
                     "Languages: " gog-backups--lang-choices
                     nil nil (mapconcat #'identity
                                        (plist-get game :lang-list) ","))))
      (setq game (gog-backups--game-put
                  game :lang-list
                  (cl-remove-duplicates choices :test #'string=)))
      (gog-backups--replace-game game)
      (gog-backups--save-data-or-msg)
      (gog-backups--release-lock))))

;;;; Entry point

;;;###autoload
(defun gog-backups ()
  "Open the GOG Backups buffer, syncing the library the first time."
  (interactive)
  (gog-backups--load-data)
  (let ((buf (get-buffer-create gog-backups--buffer-name)))
    (with-current-buffer buf
      (gog-backups-mode)
      (setq gog-backups--filter nil)
      (gog-backups--refresh-list)
      (pop-to-buffer buf))
    (unless (plist-get gog-backups--data :games)
      (gog-backups-refresh))))

(provide 'gog-backups)
;;; gog-backups.el ends here
