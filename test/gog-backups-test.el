;;; gog-backups-test.el --- Tests for gog-backups  -*- lexical-binding: t; -*-

;;; Commentary:

;; Integration tests run the network functions through acurl against
;; test/server.py, a local stand-in for the GOG endpoints started on an
;; ephemeral port.  Unit tests stub `acurl-request'.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'gog-backups)

(defconst gog-backups-test--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst gog-backups-test--installer-size (+ 2 (* 256 64))
  "Size of the installer served by test/server.py.")

(defvar gog-backups-test--server nil)

(defvar gog-backups-test--port nil)

(defun gog-backups-test--wait (pred &optional timeout)
  "Process events until PRED returns non-nil, or fail after TIMEOUT seconds."
  (let ((deadline (+ (float-time) (or timeout 30))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall pred))))

(defun gog-backups-test--url (path)
  "Return the URL of PATH on the test server, starting it if needed."
  (unless (process-live-p gog-backups-test--server)
    (let ((buf (generate-new-buffer " *gog-backups-server*")))
      (setq gog-backups-test--server
            (make-process :name "gog-backups-server" :buffer buf :noquery t
                          :command (list "python3" (expand-file-name
                                                    "server.py"
                                                    gog-backups-test--dir))))
      (gog-backups-test--wait
       (lambda () (with-current-buffer buf (string-search "\n" (buffer-string)))))
      (setq gog-backups-test--port
            (string-to-number (with-current-buffer buf (buffer-string))))))
  (format "http://127.0.0.1:%d%s" gog-backups-test--port path))

(defmacro gog-backups-test--with-env (&rest body)
  "Run BODY against the test server, with fresh state in a temporary directory."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "gog-backups-test-" t))
          (temporary-file-directory (file-name-as-directory
                                     (expand-file-name "tmp" dir)))
          (gog-backups-data-file (expand-file-name "data.eld" dir))
          (gog-backups-backup-dir (expand-file-name "backups" dir))
          (gog-backups--token-url (gog-backups-test--url "/token"))
          (gog-backups--library-url
           (gog-backups-test--url "/account/getFilteredProducts"))
          (gog-backups--game-details-url
           (gog-backups-test--url "/account/gameDetails/%s.json"))
          (gog-backups--data nil)
          (gog-backups--busy nil)
          (acurl-retry-base-delay 0))
     (make-directory temporary-file-directory)
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(defun gog-backups-test--set-valid-token ()
  "Store a valid access token."
  (gog-backups--set-token (list :access_token "AT1" :refresh_token "RT1"
                                :expiry (+ (float-time) 3600))))

(defun gog-backups-test--temp-files ()
  "Return the files left in `temporary-file-directory'."
  (directory-files temporary-file-directory nil
                   directory-files-no-dot-files-regexp))

(defun gog-backups-test--log ()
  "Return the contents of the log buffer."
  (with-current-buffer (get-buffer-create "*GOG Backups Log*")
    (buffer-string)))

(defvar gog-backups-test--opened nil
  "URL opened by the stubbed `browse-url'.")

(defvar gog-backups-test--prompt nil
  "Prompt passed to the stubbed `read-string'.")

(defvar gog-backups-test--prompt-progress nil
  "Value of `gog-backups--progress' when `read-string' is called.")

(defmacro gog-backups-test--with-browser (input &rest body)
  "Run BODY with the browser stubbed and INPUT pasted at the login prompt."
  (declare (indent 1))
  `(let ((gog-backups-test--opened nil)
         (gog-backups-test--prompt nil)
         (gog-backups-test--prompt-progress nil))
     (cl-letf (((symbol-function 'browse-url)
                (lambda (url &rest _) (setq gog-backups-test--opened url)))
               ((symbol-function 'read-string)
                (lambda (prompt &rest _)
                  (setq gog-backups-test--prompt prompt
                        gog-backups-test--prompt-progress gog-backups--progress)
                  ,input)))
       ,@body)))

(defun gog-backups-test--login ()
  "Log in and return the token passed to the callback."
  (let (token)
    (gog-backups--login (lambda (tok) (setq token tok)))
    (gog-backups-test--wait (lambda () token))
    token))

;;;; Helpers

(ert-deftest gog-backups-test-query-string ()
  (should (equal (gog-backups--query-string '(("a[b]" "") ("c" "d e")))
                 "a%5Bb%5D=&c=d%20e")))

;;;; Login and token

(ert-deftest gog-backups-test-parse-code ()
  (dolist (case '(("https://embed.gog.com/on_login_success?origin=client&code=ab-C_1" . "ab-C_1")
                  ("https://embed.gog.com/on_login_success?code=a%2Bb&origin=client" . "a+b")
                  ("  ab-C_1\n" . "ab-C_1")
                  ("https://embed.gog.com/on_login_success?origin=client")
                  ("https://login.gog.com/login")
                  ("")))
    (should (equal (gog-backups--parse-code (car case)) (cdr case)))))

(ert-deftest gog-backups-test-auth-page-url ()
  (let ((url (split-string (gog-backups--auth-page-url) "?")))
    (should (equal (car url) "https://auth.gog.com/auth"))
    (should (equal (sort (url-parse-query-string (string-join (cdr url) "?"))
                         (lambda (a b) (string< (car a) (car b))))
                   '(("client_id" "46899977096215655")
                     ("layout" "client2")
                     ("redirect_uri" "https://embed.gog.com/on_login_success?origin=client")
                     ("response_type" "code"))))))

(ert-deftest gog-backups-test-login ()
  (gog-backups-test--with-env
    (gog-backups-test--with-browser
        "https://embed.gog.com/on_login_success?origin=client&code=CODE1"
      (let ((token (gog-backups-test--login)))
        (should (equal gog-backups-test--opened (gog-backups--auth-page-url)))
        (should (equal (plist-get token :access_token) "AT1"))
        (should (equal (plist-get token :refresh_token) "RT1"))
        (should (equal (plist-get (gog-backups--load-data) :token) token))
        (should-not (gog-backups-test--temp-files))))))

(ert-deftest gog-backups-test-login-bare-code ()
  (gog-backups-test--with-env
    (gog-backups-test--with-browser "CODE2"
      (should (equal (plist-get (gog-backups-test--login) :access_token)
                     "AT2")))))

(ert-deftest gog-backups-test-login-without-browser ()
  (gog-backups-test--with-env
    (gog-backups-test--with-browser "CODE1"
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (&rest _) (error "No usable browser found"))))
        (let ((kill-ring nil))
          (should (equal (plist-get (gog-backups-test--login) :access_token)
                         "AT1"))
          (should (equal (car kill-ring) (gog-backups--auth-page-url))))
        (should (string-search "kill ring" gog-backups-test--prompt))
        (should (string-search (gog-backups--auth-page-url)
                               (gog-backups-test--log)))
        (should (equal gog-backups-test--prompt-progress
                       "Waiting for the GOG login"))
        (should (string-search "Cannot open a browser (No usable browser found)"
                               (gog-backups-test--log)))))))

(ert-deftest gog-backups-test-login-no-code-releases-lock ()
  (gog-backups-test--with-env
    (gog-backups-test--with-browser "https://login.gog.com/login"
      (should-error (gog-backups-login) :type 'user-error)
      (should-not gog-backups--busy)
      (should-not (gog-backups--token)))))

(ert-deftest gog-backups-test-login-failure-releases-lock ()
  (gog-backups-test--with-env
    (gog-backups-test--with-browser "BADCODE"
      (let (called)
        (gog-backups--acquire-lock "Logging in"
          (gog-backups--login (lambda (_) (setq called t))))
        (gog-backups-test--wait (lambda () (not gog-backups--busy)))
        (should-not called)
        (should-not (gog-backups--token))
        (should (string-search "Exchange of the code for a token failed"
                               (gog-backups-test--log)))))))

(ert-deftest gog-backups-test-refresh-token ()
  (gog-backups-test--with-env
    (gog-backups--set-token (list :access_token "AT1" :refresh_token "RT1"
                                  :expiry 0))
    (let (done)
      (gog-backups--ensure-token (lambda () (setq done t)))
      (gog-backups-test--wait (lambda () done))
      (should (equal (plist-get (gog-backups--token) :access_token) "AT3")))))

;;;; Library

(ert-deftest gog-backups-test-refresh-library ()
  (gog-backups-test--with-env
    (gog-backups-test--set-valid-token)
    (gog-backups-refresh)
    (gog-backups-test--wait (lambda () (not gog-backups--busy)))
    (let ((games (plist-get (gog-backups--load-data) :games)))
      (should (equal (mapcar (lambda (g) (plist-get g :title)) games)
                     '("Game A" "Game B")))
      (should (equal (plist-get (car games) :installers)
                     '((:name "setup_game_a_1.0" :version "1.0" :size 1048576
                              :downlink "https://www.gog.com/downloads/game_a/en1installer0"
                              :manualUrl "/downloads/game_a/en1installer0"))))
      (should (equal (plist-get (car games) :os-available) '(windows)))
      ;; Game B details were retried after a 503; its only installer
      ;; is for Linux, not selected by default.
      (should (equal (plist-get (cadr games) :os-available) '(linux)))
      (should-not (plist-get (cadr games) :installers)))
    (should (string-search "game library updated (2 games)"
                           (gog-backups-test--log)))))

(defun gog-backups-test--fetch-many (count max-concurrent)
  "Fetch the /many/ library of COUNT games with MAX-CONCURRENT requests.
Return (GAMES . PEAK), PEAK being the most simultaneous details
requests seen by the server."
  (let ((gog-backups--library-url
         (gog-backups-test--url (format "/many/%d/getFilteredProducts" count)))
        (gog-backups--game-details-url
         (gog-backups-test--url "/many/gameDetails/%s.json"))
        (acurl-max-concurrent max-concurrent)
        (gog-backups--data nil)
        (result 'pending)
        peak)
    (gog-backups-test--set-valid-token)
    (gog-backups--api-get (gog-backups-test--url "/many/peak")
                          (lambda (_) (setq peak 'reset)))
    (gog-backups-test--wait (lambda () peak))
    (setq peak nil)
    (gog-backups--fetch-library (lambda (games) (setq result games)))
    (gog-backups-test--wait (lambda () (not (eq result 'pending))))
    (gog-backups--api-get (gog-backups-test--url "/many/peak")
                          (lambda (json) (setq peak (alist-get 'peak json))))
    (gog-backups-test--wait (lambda () peak))
    (cons result peak)))

(ert-deftest gog-backups-test-fetch-details-parallel ()
  (gog-backups-test--with-env
    (let ((sequential (gog-backups-test--fetch-many 8 1))
          (parallel (gog-backups-test--fetch-many 8 3)))
      (should (= (cdr sequential) 1))
      (should (= (cdr parallel) 3))
      (should (equal (car parallel) (car sequential)))
      (should (equal (mapcar (lambda (g) (plist-get g :id)) (car parallel))
                     (number-sequence 1 8)))
      ;; Game 3 details failed: the game is listed without installers.
      (should-not (plist-get (nth 2 (car parallel)) :installers))
      (should (plist-get (nth 3 (car parallel)) :installers))
      (should (string-search "Details 8/8" (gog-backups-test--log))))))

(ert-deftest gog-backups-test-fetch-library-empty ()
  (gog-backups-test--with-env
    (should (equal (gog-backups-test--fetch-many 0 3) '(nil . 0)))))

(ert-deftest gog-backups-test-fetch-details-refreshes-token ()
  ;; The token, valid for 1000 more seconds, is refreshed before the
  ;; details requests are queued with the token of the time.
  (gog-backups-test--with-env
    (gog-backups--set-token (list :access_token "AT1" :refresh_token "RT1"
                                  :expiry (+ (float-time) 1000)))
    (let ((gog-backups--library-url
           (gog-backups-test--url "/many/2/getFilteredProducts"))
          (gog-backups--game-details-url
           (gog-backups-test--url "/many/gameDetails/%s.json"))
          (orig (symbol-function 'acurl-request))
          (result 'pending)
          auth)
      (cl-letf (((symbol-function 'acurl-request)
                 (lambda (url &rest args)
                   (when (string-search "/gameDetails/" url)
                     (push (cdr (assoc "Authorization"
                                       (plist-get args :headers)))
                           auth))
                   (apply orig url args))))
        (gog-backups--fetch-library (lambda (games) (setq result games)))
        (gog-backups-test--wait (lambda () (not (eq result 'pending)))))
      (should (equal auth '("Bearer AT3" "Bearer AT3")))
      (should (= (length result) 2)))))

;;;; Backup

(defun gog-backups-test--game (&rest file-props)
  "Return a game with one installer of FILE-PROPS on the test server."
  (list :id 1 :title "Game A" :online-version "1.0" :selected t
        :installers (list (append
                           file-props
                           (list :name "setup_game_a_1.0"
                                 :downlink (gog-backups-test--url
                                            "/downloads/game_a/en1installer0"))))))

(defun gog-backups-test--backup (game)
  "Back up GAME and return the result passed to the callback."
  (gog-backups--set-games (list game))
  (let ((result 'pending))
    (gog-backups--backup-game game (lambda (ok) (setq result ok)))
    (gog-backups-test--wait (lambda () (not (eq result 'pending))))
    result))

(ert-deftest gog-backups-test-backup-game ()
  (gog-backups-test--with-env
    (gog-backups-test--set-valid-token)
    (let* ((file (expand-file-name "Game A/setup_game_a_1.0_(123).exe"
                                   gog-backups-backup-dir)))
      (should (eq (gog-backups-test--backup (gog-backups-test--game)) t))
      (should (= (file-attribute-size (file-attributes file))
                 gog-backups-test--installer-size))
      (let ((game (gog-backups--game-by-id 1)))
        (should (equal (plist-get game :files) '("setup_game_a_1.0_(123).exe")))
        (should (equal (plist-get game :backup-version) "1.0")))
      ;; A new download replaces the file of the same name.
      (with-temp-file file (insert "stale"))
      (should (eq (gog-backups-test--backup (gog-backups-test--game)) t))
      (should (= (file-attribute-size (file-attributes file))
                 gog-backups-test--installer-size))
      (should (equal (directory-files (file-name-directory file) nil
                                      directory-files-no-dot-files-regexp)
                     '("setup_game_a_1.0_(123).exe")))
      (should-not (gog-backups-test--temp-files)))))

(ert-deftest gog-backups-test-backup-md5-mismatch ()
  (gog-backups-test--with-env
    (gog-backups-test--set-valid-token)
    (should-not (gog-backups-test--backup
                 (gog-backups-test--game :md5 (make-string 32 ?0))))
    (should-not (directory-files (expand-file-name "Game A" gog-backups-backup-dir)
                                 nil directory-files-no-dot-files-regexp))
    (should (string-search "invalid MD5" (gog-backups-test--log)))))

(ert-deftest gog-backups-test-backup-failed-check-keeps-file ()
  (gog-backups-test--with-env
    (gog-backups-test--set-valid-token)
    (let ((file (expand-file-name "Game A/setup_game_a_1.0_(123).exe"
                                  gog-backups-backup-dir)))
      (make-directory (file-name-directory file) t)
      (with-temp-file file (insert "good"))
      (should-not (gog-backups-test--backup
                   (gog-backups-test--game :md5 (make-string 32 ?0))))
      (should (equal (with-temp-buffer
                       (insert-file-contents-literally file)
                       (buffer-string))
                     "good"))
      (should (equal (directory-files (file-name-directory file) nil
                                      directory-files-no-dot-files-regexp)
                     '("setup_game_a_1.0_(123).exe"))))))

;;;; Stubbed acurl

(defmacro gog-backups-test--with-acurl (fn &rest body)
  "Run BODY with `acurl-request' replaced by FN."
  (declare (indent 1))
  `(let ((gog-backups--data nil)
         (gog-backups--busy nil))
     (gog-backups-test--set-valid-token)
     (cl-letf (((symbol-function 'acurl-request) ,fn))
       ,@body)))

(ert-deftest gog-backups-test-download-args ()
  (let ((dir (make-temp-file "gog-backups-test-" t))
        args)
    (unwind-protect
        (gog-backups-test--with-acurl (lambda (_url &rest rest) (setq args rest))
          (let ((gog-backups-request-timeout 42))
            (gog-backups--download-file "https://x/y" dir nil #'ignore)))
      (delete-directory dir t))
    ;; The first occurrence of a keyword wins, as in `cl-defun'.
    (should (equal (plist-get args :output)
                   (file-name-as-directory (expand-file-name ".gog-staging" dir))))
    (should (eq (plist-get args :overwrite) t))
    (should-not (plist-get args :timeout))
    (should (equal (plist-get args :extra-args)
                   '("--speed-limit" "1" "--speed-time" "42")))
    (should (equal (plist-get args :headers)
                   '(("Authorization" . "Bearer AT1"))))))

(ert-deftest gog-backups-test-api-access-denied ()
  (let ((result 'pending))
    (gog-backups-test--with-acurl
        (lambda (_url &rest args)
          (funcall (plist-get args :on-error)
                   (acurl--make-error :type 'http :code 401
                                      :message "HTTP status 401")))
      (gog-backups--api-get "https://x/y" (lambda (json) (setq result json))))
    (should-not result)
    (should (string-search "access denied (401)" gog-backups--progress))))

(ert-deftest gog-backups-test-callback-error-releases-lock ()
  (gog-backups-test--with-acurl
      (lambda (_url &rest args)
        (funcall (plist-get args :on-success)
                 (acurl--make-response :status 200 :body "")))
    (setq gog-backups--busy "Refreshing")
    (gog-backups--request "https://x/y" (lambda (_) (error "Boom")))
    (should-not gog-backups--busy)
    (should (string-search "error: Boom" (gog-backups-test--log)))))

(provide 'gog-backups-test)
;;; gog-backups-test.el ends here
