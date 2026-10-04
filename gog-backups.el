;;; gog-backups.el --- Manage GOG backups -*- lexical-binding: t; coding: utf-8; -*-

;; Author: Aurélien Rouëné
;; Maintainer: Aurélien Rouëné
;; Version: 1.0
;; Package-Requires: ((emacs "28.1"))
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

;; gog-backups est un mode Emacs pour sauvegarder sa bibliothèque GOG :
;; liste des jeux possédés, sélection des OS et langues par jeu,
;; téléchargement des installers standalone et des extras (goodies),
;; stockage incrémental dans une arborescence de répertoires, et
;; persistance de l'état dans un fichier ELD.
;;
;; Usage :
;;
;;   M-x gog-backups       -- ouvre le buffer *GOG Backups*
;;                            (login GOG implicite si nécessaire)
;;
;; Connexion (même mécanisme OAuth que le client Galaxy) :
;;
;;   M-x gog-backups-login -- (re)faire le login et sauver le token
;;
;; Le login fait : GET de la page d'auth (client_id Galaxy), POST de
;; login_check avec user/mot de passe (gère TOTP et two-step), échange
;; du code contre un token, puis refresh automatique du token (marge de
;; 5 minutes) avant chaque requête API.  En cas de reCAPTCHA, Emacs
;; demande de se connecter dans un navigateur et de coller l'URL finale.
;;
;; Configuration principale :
;;
;;   `gog-backups-backup-dir'         répertoire racine des backups
;;                                    (un sous-répertoire par jeu)
;;   `gog-backups-data-file'          fichier ELD de persistance
;;                                    (token, jeux, versions, dirs)
;;   `gog-backups-os-list'            OS téléchargés par défaut
;;   `gog-backups-lang-list'          langues par défaut
;;   `gog-backups-user-function'      fonction retournant le login GOG
;;                                    (nil = saisie interactive)
;;   `gog-backups-password-function'  fonction retournant le mot de
;;                                    passe (ex. password-store,
;;                                    auth-source, ou `read-passwd')
;;   `gog-backups-verify-md5'         vérifier les MD5 fournis par GOG
;;   `gog-backups-verify-zip'         vérifier l'intégrité des .zip
;;   `gog-backups-retry-delay' / `gog-backups-retry-count'
;;                                    retry sur erreur 503
;;
;; Le mot de passe n'est jamais stocké dans le fichier ELD ; il est
;; obtenu à chaque login via `gog-backups-password-function'.
;;
;; Buffer de liste (`gog-backups-mode', tabulated-list) :
;;
;;   Colonnes : Marque | Titre | État | Version backup |
;;              Version en ligne | OS | Lang | Taille
;;   État : NEW (non backupé), OK (à jour), UPDATE (mise à jour
;;   disponible, ligne surlignée avec `gog-backups-update-face').
;;
;;   g / u   rafraîchir la bibliothèque depuis GOG
;;   m       marquer/démarquer le jeu pour backup
;;   o       choisir les OS du jeu pointé
;;   l       choisir les langues du jeu pointé
;;   B       lancer le backup des jeux marqués
;;   d       changer le répertoire de destination (persisté)
;;   RET     ouvrir le répertoire de backup du jeu dans dired
;;   / n     filtrer par nom
;;   / s     filtrer par état (NEW/OK/UPDATE)
;;   / o     filtrer par OS
;;   / l     filtrer par langue
;;   / /     supprimer le filtre
;;   q       quitter
;;
;; Backups :
;;
;;   Les fichiers vont dans `<gog-backups-backup-dir>/<Titre du jeu>/'.
;;   Téléchargement atomique (fichier .tmp puis rename), reprise par
;;   requête Range si un .tmp partiel existe, vérification par taille
;;   et MD5 quand GOG le fournit.  Un fichier déjà présent avec la
;;   bonne taille n'est jamais retéléchargé (comportement incrémental).
;;   Les patchs/hotfixes sont exclus ; seuls les installers standalone
;;   (setup_*) et les extras sont téléchargés.  La progression est
;;   loggée dans le buffer *GOG Backups Log*.
;;
;; Commandes publiques :
;;
;;   `gog-backups'                ouvrir le buffer de liste
;;   `gog-backups-login'          (re)login, sauver le token
;;   `gog-backups-refresh'        re-synchroniser la bibliothèque
;;   `gog-backups-run'            backup des jeux marqués
;;
;; Hooks :
;;
;;   `gog-backups-after-fetch-library-hook' après récupération de la
;;                                          bibliothèque
;;   `gog-backups-before-backup-hook'       avant chaque backup de jeu
;;                                          (argument : le jeu)
;;   `gog-backups-after-backup-hook'        après chaque backup de jeu
;;                                          (argument : le jeu)
;;   `gog-backups-all-backups-done-hook'    après le backup de tous les
;;                                          jeux marqués
;;
;; Faces :
;;
;;   `gog-backups-update-face' (warning), `gog-backups-ok-face'
;;   (success), `gog-backups-new-face' (highlight).
;;
;; Tests (ERT, sans réseau) : voir gog-backups-test.el.
;;   emacs -batch -l gog-backups.el -l gog-backups-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'tabulated-list)
(require 'url)
(require 'url-util)
(require 'url-http)
(require 'dired)

(defgroup gog-backups nil "Backups GOG." :group 'games)

(defcustom gog-backups-backup-dir
  (expand-file-name "Gog backups" "~")
  "Répertoire racine des backups.  Un sous-répertoire par jeu."
  :type 'directory
  :group 'gog-backups)

(defcustom gog-backups-data-file
  (expand-file-name "gog-backups.eld" user-emacs-directory)
  "Fichier ELD de persistance (user, token, jeux, versions)."
  :type 'file
  :group 'gog-backups)

(defcustom gog-backups-os-list '(windows)
  "OS à télécharger par défaut."
  :type '(repeat (choice (const windows) (const linux) (const mac)))
  :group 'gog-backups)

(defcustom gog-backups-lang-list
  (list (if (string-prefix-p "French" (or current-language-environment "en"))
            "fr" "en"))
  "Langues à télécharger par défaut (langue système par défaut)."
  :type '(repeat string)
  :group 'gog-backups)

(defcustom gog-backups-password-function #'read-passwd
  "Fonction appelée pour récupérer le mot de passe GOG.
Contract : (funcall gog-backups-password-function PROMPT) -> string.
Alternative idiomatique : (lambda (p) (auth-source-pick-first-password ...))
ou (lambda (p) (password-store-get \"gog.com\"))."
  :type 'function
  :group 'gog-backups)

(defcustom gog-backups-user-function nil
  "Fonction retournant le login GOG,
ou nil pour saisie interactive."
  :type '(choice function (const nil))
  :group 'gog-backups)

(defcustom gog-backups-verify-zip nil
  "Si non-nil, vérifier l'intégrité des fichiers .zip téléchargés."
  :type 'boolean
  :group 'gog-backups)

(defcustom gog-backups-verify-md5 t
  "Si non-nil, vérifier le MD5 des fichiers quand GOG le fournit."
  :type 'boolean
  :group 'gog-backups)

(defcustom gog-backups-retry-delay 5
  "Attente en secondes avant retry d'une requête 503."
  :type 'integer
  :group 'gog-backups)

(defcustom gog-backups-retry-count 4
  "Nombre d'essais maximum sur une erreur 503."
  :type 'integer
  :group 'gog-backups)

(defcustom gog-backups-request-timeout 30
  "Délai en secondes au-delà duquel une requête asynchrone sans
réponse est abandonnée (les gros téléchargements reprennent ensuite
automatiquement par Range)."
  :type 'integer
  :group 'gog-backups)

;;;; Hooks

(defvar gog-backups-after-fetch-library-hook nil
  "Hooks lancés après récupération de la liste des jeux possédés.")

(defvar gog-backups-before-backup-hook nil
  "Hooks lancés avant chaque backup de jeu (argument : le jeu).")

(defvar gog-backups-after-backup-hook nil
  "Hooks lancés après chaque backup de jeu (argument : le jeu).")

(defvar gog-backups-all-backups-done-hook nil
  "Hooks lancés quand tous les jeux marqués ont été backuper.")

;;;; Faces

(defface gog-backups-update-face
  '((t :inherit warning))
  "Face pour les jeux ayant une mise à jour disponible."
  :group 'gog-backups)

(defface gog-backups-ok-face
  '((t :inherit success))
  "Face pour les jeux backupés à jour."
  :group 'gog-backups)

(defface gog-backups-new-face
    '((t :inherit default))
  "Face pour les jeux non encore backupés."
  :group 'gog-backups)

;;;; Constants

(defvar gog-backups--client-id "46899977096215655"
  "Client ID used for OAUTH2 authentication")

(defvar gog-backups--client-secret "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
  "Client Secret used for OAUTH2 authentication")

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
  "Rafraîchir le token s'il expire dans moins de N secondes.")

(defvar gog-backups--buffer-name
  "*GOG Backups*"
  "Buffer name for GOG Backups")

(defvar gog-backups--os-choices '("windows" "linux" "mac"))

(defvar gog-backups--lang-choices '("en" "fr"))

;;;; State

(defvar gog-backups--data nil
  "Pliste persistée : :version :user :token :os-list :games.")

(defvar gog-backups--filter nil
  "Filtre local au buffer : pliste (:name :state :os :lang).")

(defvar gog-backups--progress nil
  "Dernier message de progression.")

(defvar gog-backups--saved-title-format nil
  "frame-title-format sauvegardé pendant une opération GOG.")

(defvar gog-backups--busy nil
  "Non-nil when an operation is running (refresh, backup, login).")

(defun gog-backups--busy-p ()
  "Get the busy state, nil or the operation running"
  (and gog-backups--busy
       (not (user-error "gog-backups: an operation is already running: %s" gog-backups--busy))))

(defmacro gog-backups--acquire-lock (label &rest body)
  "Execute BODY with a global lock; raise an error if already busy"
  (declare (indent 1))
  `(unless (gog-backups--busy-p)
     (setq gog-backups--busy ,label)
     (progn ,@body)))

(defun gog-backups--release-lock ()
  "Release the global lock"
  (setq gog-backups--busy nil)
  (gog-backups--progress-done)
  ;; Refresh buffer
  (let ((buf (get-buffer gog-backups--buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (derived-mode-p 'gog-backups-mode)
          (let ((game (gog-backups--current-game)))
            (gog-backups--refresh-list)
            (when game
              (gog-backups--goto-id (plist-get game :id)))))))))

(defun gog-backups--update-title ()
  "Afficher la progression dans la barre de titre de la frame et
dans le header-line du buffer *GOG Backups* (comme elfeed)."
  (let ((buf (get-buffer "*GOG Backups*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if gog-backups--progress
            (setq header-line-format
                  (concat " GOG — " gog-backups--progress))
          ;; fin : restaurer l'en-tête tabulated-list
          (tabulated-list-init-header))
        (force-mode-line-update t))))
  (if gog-backups--progress
      (progn
        (unless gog-backups--saved-title-format
          (setq gog-backups--saved-title-format frame-title-format))
        (setq frame-title-format
              (concat "GOG " gog-backups--progress)))
    ;; fin d'opération : restaurer le titre
    (when gog-backups--saved-title-format
      (setq frame-title-format gog-backups--saved-title-format
            gog-backups--saved-title-format nil))))

(defun gog-backups--progress-done ()
  "Effacer la progression et restaurer la barre de titre."
  (setq gog-backups--progress nil)
  (gog-backups--update-title)
  (message "GOG Refresh: done"))

(defun gog-backups--log (format &rest args)
  "Logger un message de progression dans *GOG Backups Log* et la
barre de titre (pas dans le minibuffer, pour éviter le spam)."
  (setq gog-backups--progress (apply #'format format args))
  (gog-backups--update-title)
  (with-current-buffer (get-buffer-create "*GOG Backups Log*")
    (goto-char (point-max))
    (insert gog-backups--progress "\n")))

(defun gog-backups--message-filter (orig fmt &rest args)
  "Filtrer le message de connexion de url.el (spam \"Contacting host:\")."
  (unless (and (stringp fmt)
               (string-prefix-p "Contacting host:" fmt))
    (apply orig fmt args)))

(advice-add 'message :around #'gog-backups--message-filter)

;;;; ELD persistence

(defun gog-backups--games ()
  (plist-get gog-backups--data :games))

(defun gog-backups--set-games (games)
  (setq gog-backups--data (plist-put gog-backups--data :games games)))

(defun gog-backups--game-get (game key)
  "Retourner la valeur de KEY dans la pliste GAME."
  (plist-get game key))

(defun gog-backups--game-put (game key val)
  "Retourner GAME avec KEY mis à VAL."
  (plist-put game key val))

(defun gog-backups--game-by-id (id)
  (cl-find id (gog-backups--games) :key (lambda (g) (plist-get g :id))))

(defun gog-backups--token ()
  (plist-get gog-backups--data :token))

(defun gog-backups--set-token (token)
  (setq gog-backups--data (plist-put gog-backups--data :token token)))

(defun gog-backups--save-data ()
  "Sauver gog-backups--data dans `gog-backups-data-file' (écriture atomique)."
  (let ((file gog-backups-data-file))
    (unless (file-directory-p (directory-file-name (file-name-directory file)))
      (error "gog-backups: répertoire inexistant: %s"
             (file-name-directory file)))
    (let ((tmp (make-temp-file (concat file ".tmp"))))
      (with-temp-file tmp
        (pp (or gog-backups--data '(:version 1)) (current-buffer)))
      (copy-file tmp file t)
      (delete-file tmp))))

(defun gog-backups--load-data ()
  "Charger gog-backups--data depuis `gog-backups-data-file'.
Tolérant : fichier corrompu → retourne nil sans erreur."
  (setq gog-backups--data nil)
  (when (file-exists-p gog-backups-data-file)
    (setq gog-backups--data
          (with-demoted-errors "gog-backups: fichier ELD corrompu: %S"
            (with-temp-buffer
              (insert-file-contents gog-backups-data-file)
              (goto-char (point-min))
              (condition-case nil
                  (read (current-buffer))
                (end-of-file nil))))))
  gog-backups--data)

(defun gog-backups--save-data-or-msg ()
  (condition-case err
      (gog-backups--save-data)
    (error (message "%s" (error-message-string err)))))

;;;; HTTP layer

(defun gog-backups--resolve-url (location base)
  "Résoudre LOCATION relativement à BASE."
  (cond ((or (string-prefix-p "http://" location)
             (string-prefix-p "https://" location))
         location)
        ((string-prefix-p "/" location)
         (concat (progn (string-match "\\`\\(https?://[^/]+\\)" base)
                        (match-string 1 base))
                 location))
        (t (concat (file-name-as-directory
                    (directory-file-name
                     (or (and (string-match "\\`\\(https?://.*/\\)" base)
                              (match-string 1 base))
                         base)))
                   location))))


(defvar url-http-response-status)  ; défini dans url-http.el
(defvar url-http-end-of-headers)  ; défini dans url-http.el

(defun gog-backups--parse-headers ()
  "Extraire les headers HTTP du buffer courant (avant la ligne vide)."
  (save-excursion
    (goto-char (point-min))
    (forward-line 1) ; sauter la ligne de statut "HTTP/1.1 200 OK"
    (let ((case-fold-search t) hdrs)
      (while (and (not (eobp))
                  (looking-at "^\\([-A-Za-z]+\\):[ \\t]*\\(.*\\)$"))
        (push (cons (match-string 1) (match-string 2)) hdrs)
        (forward-line 1))
      (nreverse hdrs))))

(defun gog-backups--http-request (method url &optional headers data)
  "Requête HTTP (réception sans bloquer Emacs : boucle d'events).
Retourne (:status :headers :body :url)."
  (let ((url-request-method method)
        (url-request-extra-headers headers)
        (url-request-data data)
        buf)
    (setq buf
          (ignore-errors
            (url-retrieve url (lambda (&rest _) nil) nil t t)))
    (unless (buffer-live-p buf)
      (error "gog-backups: requête échouée: %s" url))
    (unwind-protect
         (progn
           ;; attendre headers + contenu complet, sans bloquer
           (gog-backups--http-request-async-wait buf)
           (if (not (buffer-live-p buf))
               (error "gog-backups: connexion perdue: %s" url)
             (with-current-buffer buf
               (let* ((status url-http-response-status)
                      (final-url
                       (ignore-errors (url-recreate-url url-current-object)))
                      (hdrs (gog-backups--parse-headers)))
                 (if url-http-end-of-headers
                     (progn
                       (set-buffer-multibyte nil)
                       (list :status status
                             :headers hdrs
                             :body (buffer-substring-no-properties
                                    url-http-end-of-headers (point-max))
                             :url (or final-url url)))
                   (list :status status :headers hdrs :body "" :url url))))))
      (when (buffer-live-p buf)
        (let ((proc (get-buffer-process buf)))
          (when proc (delete-process proc)))
        (kill-buffer buf)))))

(defun gog-backups--http-get (url &optional headers)
  (gog-backups--http-request "GET" url headers))

(defun gog-backups--http-post (url data &optional headers)
  (gog-backups--http-request "POST" url headers data))

(defun gog-backups--json-parse (body)
  "Parse a JSON body into an alist."
  (condition-case nil
      (with-temp-buffer
        (insert body)
        (goto-char (point-min))
        (json-parse-buffer :object-type 'alist
                           :array-type 'list
                           :false-object nil
                           :null-object nil))
    (error nil)))

(defun gog-backups--urlencode-params (params)
  "Encoder PARAMS (alist) en corps form-urlencoded."
  (mapconcat
   (lambda (p)
     (concat (url-hexify-string (car p)) "=" (url-hexify-string (cdr p))))
   params "&"))

(defun gog-backups--query-string (params)
  (mapconcat
   (lambda (p)
     (concat (url-hexify-string (car p)) "=" (url-hexify-string (cdr p))))
   params "&"))

(defun gog-backups--header (headers name)
  "Extraire la valeur du header NAME (insensible à la casse)."
  (cdr (assoc name headers)))

(defun gog-backups--content-disposition-filename (headers)
  (let ((cd (gog-backups--header headers "Content-Disposition")))
    (when (and cd (string-match "filename\\*?=\"?\\([^\";]+\\)\"?" cd))
      (let ((fn (match-string 1 cd)))
        (if (and fn (string-match-p "utf-8''" fn))
            (url-unhex-string (substring fn (match-end 0)))
          fn)))))

;;;; Login
(defun gog-backups--extract-code (url body)
  "Extraire le code OAuth depuis URL, ou depuis le body JS (gogData Auth.AuthCode).
La réponse de login_check peut être une page JS embarquant le code
JSON plutôt qu'une redirection avec ?code=."
  (or (and (string-match "[?&]code=\\([^&]+\\)" url)
           (match-string 1 url))
      (and body
           (string-match "\\\"code\\\":\\\"\\([^\\\"]+\\)\\\"" body)
           (match-string 1 body))))


(defun gog-backups--extract-login-token (html)
  "Extraire le champ caché login__token de la page HTML d'auth."
  (cond ((string-match "<input[^>]*id=\"login__token\"[^>]*value=\"\\([^\"]*\\)\"" html)
         (match-string 1 html))
        ((string-match "<input[^>]*value=\"\\([^\"]*\\)\"[^>]*id=\"login__token\"" html)
         (match-string 1 html))))

(defun gog-backups--login-response-kind (url)
  "Classifier l'URL de réponse du login : totp / two-step / success / nil."
  (cond ((string-match-p "totp" url) 'totp)
        ((string-match-p "two_step" url) 'two-step)
        ((string-match-p "on_login_success" url) 'success)
        (t 'unknown)))

(defun gog-backups--parse-token-json (body)
  "Parser la réponse du token endpoint.
Retourne une pliste (:access_token :refresh_token :expiry)."
  (let* ((json (gog-backups--json-parse body))
         (at (cdr (assoc 'access_token json)))
         (rt (cdr (assoc 'refresh_token json)))
         (exp (cdr (assoc 'expires_in json))))
    (when at
      (list :access_token at
            :refresh_token rt
            :expiry (+ (float-time) (or exp 3600))))))

(defun gog-backups--token-expired-p ()
  (let ((token (gog-backups--token)))
    (or (null token)
        (null (plist-get token :access_token))
        (< (or (plist-get token :expiry) 0)
           (+ (float-time) gog-backups--token-refresh-margin)))))

(defun gog-backups--refresh-token ()
  "Rafraîchir le token via grant_type=refresh_token."
  (let ((rt (plist-get (gog-backups--token) :refresh_token)))
    (unless rt (error "gog-backups: pas de refresh token, il faut se reconnecter"))
    (let* ((url (concat gog-backups--token-url "?"
                        (gog-backups--query-string
                         `(("client_id" . ,gog-backups--client-id)
                           ("client_secret" . ,gog-backups--client-secret)
                           ("grant_type" . "refresh_token")
                           ("refresh_token" . ,rt)
                           ("redirect_uri" . ,gog-backups--redirect-url)))))
           (resp (gog-backups--http-get url))
           (token (gog-backups--parse-token-json (plist-get resp :body))))
      (if token
          (gog-backups--set-token token)
        (error "gog-backups: refresh du token échoué (relogin nécessaire)"))
      token)))

(defun gog-backups--ensure-token ()
  "S'assurer que le token est valide, sinon login ou refresh."
  (when (gog-backups--token-expired-p)
    (if (plist-get (gog-backups--token) :refresh_token)
        (gog-backups--refresh-token)
      (gog-backups--login))))

(defun gog-backups--extract-input-token (html id)
  "Extraire la valeur du champ caché d'id ID (formulaires 2FA)."
  (cond ((string-match (format "<input[^>]*id=\"%s\"[^>]*value=\"\\([^\"]*\\)\"" id) html)
         (match-string 1 html))
        ((string-match (format "<input[^>]*value=\"\\([^\"]*\\)\"[^>]*id=\"%s\"" id) html)
         (match-string 1 html))))

(defun gog-backups--login ()
  "Complete GOG loging, returns a token.

Reference: https://gogapidocs.readthedocs.io/en/latest/auth.html"
  (let* ((user (or (and gog-backups-user-function
                        (funcall gog-backups-user-function))
                   (read-string "GOG user: ")))
         (pass (funcall gog-backups-password-function "GOG password: "))
         code)
    ;; 1. GET auth page + login__token
    (let* ((auth-url (concat gog-backups--auth-url "?"
                             (gog-backups--query-string
                              `(("client_id" . ,gog-backups--client-id)
                                ("redirect_uri" . ,gog-backups--redirect-url)
                                ("response_type" . "code")
                                ("layout" . "client2")))))
           (resp (gog-backups--http-get auth-url))
           (html (plist-get resp :body))
           (login-token (gog-backups--extract-login-token html)))
      (if (not login-token)
          ;; reCAPTCHA ou page inattendue : fallback navigateur
          (progn
            (gog-backups--log
             "reCAPTCHA détecté : connectez-vous dans un navigateur puis collez l'URL finale contenant code=")
            (let ((input-url (read-string "URL de connexion (contenant code=): ")))
              (setq code (and (string-match "[?&]code=\\([^&]+\\)" input-url)
                              (match-string 1 input-url)))))
        ;; 2. POST login_check
        (let* ((post-resp (gog-backups--http-post
                           gog-backups--login-url
                           (gog-backups--urlencode-params
                            `(("login[username]" . ,user)
                              ("login[password]" . ,pass)
                              ("login[login]" . "")
                              ("login[login_flow]" . "default")
                              ("login[_token]" . ,login-token)))
                           '(("Content-Type" . "application/x-www-form-urlencoded"))))
               (kind (gog-backups--login-response-kind
                      (or (plist-get post-resp :url) ""))))
          (cl-case kind
            (success
             (setq code (gog-backups--extract-code
                         (or (plist-get post-resp :url) "")
                         (plist-get post-resp :body))))
            (totp
             (let* ((sec (read-string "Code Authenticator (TOTP): "))
                    (tok (gog-backups--extract-input-token
                          (plist-get post-resp :body)
                          "two_factor_totp_authentication__token"))

                    (params
                     (append
                      (cl-loop for i from 0 below (min 6 (length sec))
                            collect
                            (cons (format "two_factor_totp_authentication[token][letter_%d]" (1+ i))
                                  (substring sec i (1+ i))))
                      '(("two_factor_totp_authentication[send]" . ""))
                      (and tok
                           (list (cons "two_factor_totp_authentication[_token]" tok)))))
                    (resp2 (gog-backups--http-post
                            (plist-get post-resp :url)
                            (gog-backups--urlencode-params params)
                            '(("Content-Type" . "application/x-www-form-urlencoded")))))
               (when (eq 'success (gog-backups--login-response-kind
                                   (or (plist-get resp2 :url) "")))
                 (setq code (gog-backups--extract-code
                             (or (plist-get resp2 :url) "")
                             (plist-get resp2 :body))))))
            (two-step
             (let* ((sec (read-string "Code two-step: "))
                    (tok (gog-backups--extract-input-token
                          (plist-get post-resp :body)
                          "second_step_authentication__token"))

                    (params
                     (append
                      (cl-loop for i from 0 below (min 4 (length sec))
                            collect
                            (cons (format "second_step_authentication[token][letter_%d]" (1+ i))
                                  (substring sec i (1+ i))))
                      '(("second_step_authentication[send]" . ""))
                      (and tok
                           (list (cons "second_step_authentication[_token]" tok)))))
                    (resp2 (gog-backups--http-post
                            (plist-get post-resp :url)
                            (gog-backups--urlencode-params params)
                            '(("Content-Type" . "application/x-www-form-urlencoded")))))
               (when (eq 'success (gog-backups--login-response-kind
                                   (or (plist-get resp2 :url) "")))
                 (setq code (gog-backups--extract-code
                             (or (plist-get resp2 :url) "")
                             (plist-get resp2 :body))))))
            (t
             (error "gog-backups: login échoué, vérifiez identifiants"))))))
    ;; 3. Exchange code → token
    (unless code (error "gog-backups: pas de code d'autorisation obtenu"))
    (let* ((tok-url (concat gog-backups--token-url "?"
                            (gog-backups--query-string
                             `(("client_id" . ,gog-backups--client-id)
                               ("client_secret" . ,gog-backups--client-secret)
                               ("grant_type" . "authorization_code")
                               ("code" . ,code)
                               ("redirect_uri" . ,gog-backups--redirect-url)))))
           (resp (gog-backups--http-get tok-url))
           (token (gog-backups--parse-token-json (plist-get resp :body))))
      (unless token (error "gog-backups: échange du code contre token échoué"))
      (gog-backups--set-token token)
      (gog-backups--save-data-or-msg)
      token)))

;;;; API calls

(defun gog-backups--api-request (url &optional headers)
  "Requête API authentifiée : token, retry 503, relogin sur 401/403."
  (gog-backups--ensure-token)
  (let ((attempt 0) resp)
    (while (progn
             (setq resp
                   (gog-backups--http-get
                    url
                    (append (list (cons "Authorization"
                                        (concat "Bearer "
                                                (plist-get (gog-backups--token)
                                                           :access_token))))
                            headers)))
             (let ((st (plist-get resp :status)))
               (cond
                ((memq st '(401 403))
                 (when (>= attempt 1)
                   (error "gog-backups: accès refusé (%d) après relogin: %s" st url))
                 (cl-incf attempt)
                 (gog-backups--login)
                 t)
                ((= st 503)
                 (when (>= attempt gog-backups-retry-count)
                   (error "gog-backups: 503 persistant: %s" url))
                 (cl-incf attempt)
                 (gog-backups--log "503, retry dans %ds (%d/%d)"
                                   gog-backups-retry-delay attempt
                                   gog-backups-retry-count)
                 (sit-for gog-backups-retry-delay)
                 t)
                ((>= st 400)
                 (error "gog-backups: erreur HTTP %d: %s" st url))
                (t nil)))))
    resp))

;;;; Library

(defun gog-backups--fetch-library-page (page)
  (let* ((url (concat gog-backups--library-url "?"
                      (gog-backups--query-string
                       `(("mediaType" . "1")
                         ("sortBy" . "title")
                         ("page" . ,(number-to-string page))))))
         (resp (gog-backups--api-request url)))
    (gog-backups--json-parse (plist-get resp :body))))

(defun gog-backups--fetch-library ()
  "Récupérer toute la bibliothèque et les détails par jeu."
  (let ((page 1) products total-pages)
    (catch 'done
      (while t
        (let ((json (gog-backups--fetch-library-page page)))
          (setq products (append products (cdr (assoc 'products json))))
          (setq total-pages (or (cdr (assoc 'totalPages json)) 1))
          (unless (< page total-pages) (throw 'done nil))
          (setq page (1+ page)))))
    (let ((games (gog-backups--build-games products)))
      (gog-backups--set-games games)
      (gog-backups--save-data-or-msg)
      (run-hooks 'gog-backups-after-fetch-library-hook)
      games)))

(defun gog-backups--build-games (products &optional details)
  "Construire la liste de jeux depuis PRODUCTS, en préservant
les préférences existantes (os-list, lang-list, selected...).

DETAILS est un alist optionnel (ID . details) évitant de recharger les
gameDetails (utilisé par la version asynchrone)."
  (let (games)
    (dolist (p products)
      (let* ((id (cdr (assoc 'id p)))
             (title (cdr (assoc 'title p)))
             (slug (cdr (assoc 'slug p)))
             (old (gog-backups--game-by-id id))
             (details (if details
                          (cdr (assoc id details))
                        (gog-backups--fetch-game-details id)))
             (os-list (or (plist-get old :os-list) gog-backups-os-list))
             (lang-list (or (plist-get old :lang-list) gog-backups-lang-list))
             (installers (gog-backups--extract-installers
                          details os-list lang-list slug))
             (os-avail (or (plist-get old :os-available)
                           (and (listp details)
                                (gog-backups--available-os details))))
             (lang-avail (or (plist-get old :lang-available)
                             (and (listp details)
                                  (gog-backups--available-lang details))))
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
                    :selected (if old (plist-get old :selected) nil)
                    :backed-up (plist-get old :backed-up)
                    :backup-version (plist-get old :backup-version)
                    :last-backup (plist-get old :last-backup)
                    :files (plist-get old :files)
                    :installers installers
                    :extras extras)
              games)))
    (nreverse games)))

(defun gog-backups--fetch-game-details (id)
  (let ((resp (gog-backups--api-request
               (format gog-backups--game-details-url id))))
    (or (gog-backups--json-parse (plist-get resp :body)) 'nil)))

(defun gog-backups--patch-p (name)
  "Vrai si NAME ressemble à un patch/update/hotfix.
Le format réel GOG nomme les patchs \"Patch (1.1 to 1.2)\"."
  (and (stringp name)
       (string-match-p "\\`[[:space:]]*\\([Pp]atch\\|[Uu]pdate\\|[Hh]otfix\\)" name)))

(defun gog-backups--installer-keep-p (manual-url)
  "Vrai si MANUAL-URL (chemin GOG du download) est un installer
standalone principal.  Les URLs GOG contiennent \"installer\" pour
les installers complets, \"patch\" pour les patchs."
  (and (string-match-p "installer" manual-url)
       (not (string-match-p "patch\\|hotfix" manual-url))))

(defun gog-backups--os-pairs (lang-rest)
  "Extraire la liste des paires (OS ENTRÉES...) du contenu après la
clé de langue.  Format réel GOG : (cdr dl) est une liste contenant un
osmap du type ((windows ENTRÉES...))."
  (let ((pairs nil))
    (dolist (x lang-rest)
      (cond
       ((atom x) (push x pairs))          ; (windows . e) "atome-clé" improbable
       ((atom (car x)) (push x pairs))    ; x = (os . entries)
       (t (setq pairs (append pairs x))))) ; x = osmap = ((os . e) ...)
    (nreverse pairs)))

(defun gog-backups--installer-filename (slug version name)
  "Construire un nom de fichier stable pour un installer GOG.
Le nom réel (avec extension) n\'est connu qu\'au moment du
téléchargement via le header Content-Disposition du CDN ; ce nom
sert uniquement de clé stable pour la reprise (.tmp) et les logs.
GOG fournit dans NAME le titre du jeu, ex. « Loop Hero (Part 1 of
2) » ; SLUG est le slug du jeu (peut être nil), VERSION la chaîne
de version GOG."
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
  "Liste des symboles OS disponibles dans DETAILS (clés des osmaps)."
  (let ((oses))
    (dolist (dl (cdr (assoc 'downloads details)))
      (dolist (os (gog-backups--os-pairs (cdr dl)))
        (let ((o (car os)))
          (when (symbolp o)
            (cl-pushnew o oses)))))
    (nreverse oses)))

(defun gog-backups--available-lang (details)
  "Liste des langues disponibles dans DETAILS (clés de downloads)."
  (let ((langs))
    (dolist (dl (cdr (assoc 'downloads details)))
      (let ((l (car dl)))
        (when (stringp l) (cl-pushnew l langs :test (function string=)))))
    (nreverse langs)))

(defun gog-backups--extract-installers (details os-list lang-list &optional slug)
  "Extraire les installers standalone de DETAILS pour OS-LIST et LANG-LIST.
Format réel GOG : downloads est une liste de paires (\"English\" . {os
-> entrées}) ; entrées avec manualUrl/name/version, taille en chaîne
(\"1 MB\").  Les patchs sont exclus ; l'URL finale est
https://www.gog.com<manualUrl>."
  (let ((result))
    (when (listp details)
      (dolist (dl (cdr (assoc 'downloads details)))
        (let* ((lang (car dl)))
          (when (and lang (or (string= lang "*")
                              (gog-backups--lang-match-p lang lang-list)))
            (dolist (os (gog-backups--os-pairs (cdr dl)))
              (let* ((osname (car os)))
                (when (member osname os-list)
                  (dolist (entry (cdr os))
                    (let* ((name (cdr (assoc 'name entry)))
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
                         result)))))))))))
    (nreverse result)))

(defun gog-backups--lang-match-p (lang lang-list)
  "Vrai si LANG (ex. \"English\", \"fr-FR\") match une des langues LANG-LIST
(code court \"en\"/\"fr\" ou nom complet)."
  (or (member lang lang-list)
      (cl-some (lambda (l)
                 (or (string-prefix-p l lang)
                     (and (>= (length lang) 2)
                          (member (downcase (substring lang 0 2)) lang-list))))
               lang-list)))

(defun gog-backups--parse-size (size)
  "Convertir une taille GOG (\"1 MB\", \"4 GB\", nombre) en octets, ou nil."
  (cond ((numberp size) size)
        ((stringp size)
         (when (string-match "\\`\\([0-9.]+\\)\\s-*\\(GB?\\|MB?\\|KB?\\|B\\)\\'" size)
           (let ((v (string-to-number (match-string 1 size)))
                 (u (upcase (match-string 2 size))))
             (round
              (* v
                 (cond ((equal u "GB") (* 1024 1024 1024))
                       ((equal u "G") (* 1024 1024 1024))
                       ((equal u "MB") (* 1024 1024))
                       ((equal u "M") (* 1024 1024))
                       ((equal u "KB") 1024)
                       ((equal u "K") 1024)
                       (t 1)))))))
        (t nil)))

(defun gog-backups--collect-extras (details)
  "Collecter tous les extras (récursivement, y compris dans les dlcs).
Format réel GOG : extras avec manualUrl (pas downlink) et taille
en chaîne."
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
    (when (listp details)
      (walk details))))

;;;; Backup state

(defun gog-backups--status (game)
  "État du backup : `new', `ok' ou `update'."
  (let ((bv (plist-get game :backup-version))
        (ov (plist-get game :online-version)))
    (cond ((or (not bv) (not ov)) 'new)
          ((string= bv ov) 'ok)
          (t 'update))))

(defun gog-backups--status-string (game)
  (cl-case (gog-backups--status game)
    (new "NEW") (ok "OK") (update "UPDATE") (t "?")))

(defun gog-backups--game-dir (game)
  "Répertoire de backup du jeu : <backup-dir>/<Titre du jeu>."
  (expand-file-name
   (plist-get game :title)
   (file-name-as-directory
    (expand-file-name
     (or (plist-get gog-backups--data :backup-dir)
         (directory-file-name gog-backups-backup-dir))))))

(defun gog-backups--ensure-game-dir (game)
  (let ((dir (gog-backups--game-dir game)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(defun gog-backups--human-size (bytes)
  (cond ((< bytes 1024) (format "%d B" bytes))
        ((< bytes (* 1024 1024)) (format "%.1f KiB" (/ bytes 1024.0)))
        ((< bytes (* 1024 1024 1024)) (format "%.1f MiB" (/ bytes 1024.0 1024)))
        (t (format "%.1f GiB" (/ bytes 1024.0 1024 1024)))))

(defun gog-backups--files-size (game)
  "Taille totale (chaîne human) avec la valeur en octets en
propriété texte gog-backups-bytes, pour le tri numérique."
  (let ((total 0) known)
    (dolist (f (append (plist-get game :installers) (plist-get game :extras)))
      (let ((s (plist-get f :size)))
        (if (numberp s)
            (setq known t total (+ total s)))))
    (if known
        (propertize (gog-backups--human-size total)
                    'gog-backups-bytes total)
      "-")))

(defun gog-backups--sort-size-cell (entry)
  "Extraire la cellule Taille d'une entrée tabulated-list ENTRY.
Tolérant aux formats : vecteur nu, (id . [cols]), (id . ([cols])).
Cherche la cellule portant la propriété gog-backups-bytes, sinon
renvoie la colonne 7."
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
  "Comparateur de tri tabulated-list : colonne Taille (numérique).
Les cellules portent la propriété gog-backups-bytes ; sans elle,
comparaison lexicographique."
  (let* ((ca (gog-backups--sort-size-cell a))
         (cb (gog-backups--sort-size-cell b))
         (av (and (stringp ca) (get-text-property 0 'gog-backups-bytes ca)))
         (bv (and (stringp cb) (get-text-property 0 'gog-backups-bytes cb))))
    (cond ((and (numberp av) (numberp bv)) (< av bv))
          ((numberp av) t)
          ((numberp bv) nil)
          (t (string< (format "%s" ca) (format "%s" cb))))))

;;;; Download

(defvar gog-backups--http-head-fallback t
  "Si non-nil, faire un HEAD pour obtenir la taille quand inconnue.")

(defun gog-backups--http-head (url)
  (gog-backups--http-request "HEAD" url))

(defun gog-backups--expected-size (url)
  "Taille attendue via Content-Length d'un HEAD."
  (let ((resp (gog-backups--http-head url)))
    (when (and (numberp (plist-get resp :status))
               (< (plist-get resp :status) 400))
      (let ((cl (gog-backups--header (plist-get resp :headers)
                                     "Content-Length")))
        (and cl (string-to-number cl))))))

(defun gog-backups--verify-md5 (file md5)
  (and md5
       (string=
        (with-temp-buffer
          (insert-file-contents-literally file)
          (secure-hash 'md5 (current-buffer)))
        (downcase md5))))

(defun gog-backups--md5-for-url (url)
  "MD5 fourni par GOG (fichier .xml à côté du download), ou nil."
  (condition-case nil
      (let ((resp (gog-backups--http-get (concat url ".xml"))))
        (when (and (numberp (plist-get resp :status))
                   (< (plist-get resp :status) 400))
          (let ((body (plist-get resp :body)))
            (and (string-match "md5=\"\\([0-9a-fA-F]\\{32\\}\\)\"" body)
                 (downcase (match-string 1 body))))))
    (error nil)))

(defun gog-backups--verify-zip (file)
  "Vérification d'intégrité minimale d'un .zip (signature PK)."
  (and gog-backups-verify-zip
       (string-match-p "\\.zip$" file)
       (let ((beg (with-temp-buffer
                    (insert-file-contents-literally file nil 0 4)
                    (buffer-string))))
         (string-prefix-p "PK" beg))))

(defvar gog-backups--download-error nil
  "Erreur du dernier téléchargement, ou nil.")

(defun gog-backups--http-request-async-wait (buf &optional timeout)
  "Attendre la fin de la réception du buffer URL BUF sans bloquer Emacs.
Boucle sur accept-process-output tant que le processus réseau est
vivant (url.el ferme le processus à la fin de la réception, après
les éventuelles redirections), ou TIMEOUT secondes."
  (let ((deadline (+ (float-time) (or timeout 3600)))
        proc)
    (while (and (buffer-live-p buf)
                (< (float-time) deadline)
                (progn
                  (accept-process-output nil 0.2)
                  (setq proc (and (buffer-live-p buf)
                                  (get-buffer-process buf)))
                  (and proc (process-live-p proc)))))
    (buffer-live-p buf)))

(defun gog-backups--download-file (url file &optional expected-size md5)
  "Télécharger URL vers FILE (atomique, reprise par Range).
Retourne FILE si succès, nil si le téléchargement est incomplet
(le .tmp est alors conservé pour reprise)."
  (let* ((tmp (concat file ".tmp"))
         (existing (and (file-exists-p tmp)
                        (file-attribute-size (file-attributes tmp))))
         (offset (if (and existing expected-size (< existing expected-size))
                     existing
                   0))
         (headers
          (append
           (when (> offset 0)
             (list (cons "Range" (format "bytes=%d-" offset))))
           (list (cons "Authorization"
                       (concat "Bearer "
                               (plist-get (gog-backups--token)
                                          :access_token))))))
         (resp (gog-backups--http-request "GET" url headers))
         (status (plist-get resp :status)))
    ;; suivre les redirections (30x) manuellement : url-retrieve
    ;; async retourne la première réponse sans les suivre
    (while (and (numberp status) (memq status '(301 302 303 307 308)))
      (let ((loc (gog-backups--header (plist-get resp :headers) "Location")))
        (unless loc
          (error "gog-backups: redirection sans Location: %s" url))
        (setq url (gog-backups--resolve-url loc url)
              resp (gog-backups--http-request "GET" url headers)
              status (plist-get resp :status))))
    (unless (and (numberp status) (memq status '(200 206)))
      (error "gog-backups: téléchargement HTTP %s: %s" status url))
    (let* ((body (plist-get resp :body))
           (cl (gog-backups--header (plist-get resp :headers)
                                    "Content-Length"))
           (expected (or expected-size
                         (and cl (stringp cl) (string-to-number cl)))))
      (let ((coding-system-for-write 'no-conversion))
        (if (> offset 0)
            (with-temp-buffer
              (insert body)
              (append-to-file (point-min) (point-max) tmp))
          (with-temp-buffer
            (insert body)
            (write-region (point-min) (point-max) tmp nil 'quiet))))
      (let ((total (+ offset (length body))))
        (if (and expected (> expected total))
            (progn
              (gog-backups--log "partiel: %s (%s/%s)" file
                                (gog-backups--human-size total)
                                (gog-backups--human-size expected))
              nil)
          (when (and md5 gog-backups-verify-md5)
            (unless (gog-backups--verify-md5 tmp md5)
              (delete-file tmp)
              (error "gog-backups: MD5 invalide: %s" file)))
          (gog-backups--verify-zip tmp)
          (when (file-exists-p file) (delete-file file))
          (rename-file tmp file)
          (gog-backups--log "ok: %s (%s)"
                            (file-name-nondirectory file)
                            (gog-backups--human-size total))
          file)))))

(defun gog-backups--file-url (file)
  "URL de téléchargement d'un FILE."
  (plist-get file :downlink))

(defun gog-backups--download-need-p (dir file)
  "Vrai si le fichier doit être (re)téléchargé.
Le nom réel des installers ne peut être connu qu'à partir du header
Content-Disposition du CDN : si le fichier portant le nom prédit
n\'existe pas, on cherche dans DIR un fichier de la même taille
(size attendue) — les noms GOG incluant un numéro de build varient
selon les versions."
  (let* ((path (expand-file-name (plist-get file :name) dir))
         (size (plist-get file :size))
         (actual (and (file-exists-p path)
                      (file-attribute-size (file-attributes path)))))
    ;; NB : la taille GOG est une chaîne arrondie ("185 MB"), ne jamais
    ;; comparer strictement ; tolérance de 2 %.
    (cond
     ((not actual) t)                     ; absent → à télécharger
     ((not size) nil)                     ; pas de taille → présent suffit
     ;; présent et taille dans la tolérance → à jour
     ((<= (abs (- actual size)) (max (floor (* 0.02 size)) 1048576)) nil)
     ;; présent mais mauvaise taille : chercher un autre fichier de la
     ;; bonne taille dans DIR (backupé sous un autre nom de build)
     (t (not (cl-find-if
              (lambda (n)
                (and (not (string-suffix-p ".tmp" n))
                     (<= (abs (- (file-attribute-size
                                  (file-attributes
                                   (expand-file-name n dir)))
                                size))
                         (max (floor (* 0.02 size)) 1048576))))
              (directory-files dir)))))))

(defun gog-backups--download-files (dir files)
  "Télécharger la liste FILES dans DIR.  Retourne t si tout est ok."
  (let ((ok t))
    (dolist (file files)
      (let* ((name (plist-get file :name))
             (path (expand-file-name name dir))
             (size (plist-get file :size))
             (url (gog-backups--file-url file)))
        (cond
         ((null url)
          (gog-backups--log "Pas d'URL pour %s, ignoré" name))
         ((gog-backups--download-need-p dir file)
          (gog-backups--log "Téléchargement: %s" name)
          (unless (gog-backups--download-file url path size
                                              (plist-get file :md5))
            (setq ok nil)))
         (t (gog-backups--log "Déjà présent, ignoré: %s" name)))))
    ok))

(defun gog-backups--backup-game (game)
  "Backuper un jeu : répertoire, installers, extras, maj ELD."
  (run-hook-with-args 'gog-backups-before-backup-hook game)
  (let* ((dir (gog-backups--ensure-game-dir game))
         (installers (plist-get game :installers))
         (extras (plist-get game :extras)))
    (gog-backups--log "Backup: %s (%d fichiers)"
                      (plist-get game :title)
                      (+ (length installers) (length extras)))
    (let ((ok (and (gog-backups--download-files dir installers)
                   (gog-backups--download-files dir extras))))
      (if ok
          (let ((version (plist-get game :online-version)))
            (setq game (gog-backups--game-put game :backed-up t))
            (setq game (gog-backups--game-put game :backup-version version))
            (setq game (gog-backups--game-put
                        game :last-backup
                        (format-time-string "%Y-%m-%d")))
            (setq game (gog-backups--game-put game :files
                                              (append
                                               (mapcar (lambda (f) (plist-get f :name)) installers)
                                               (mapcar (lambda (f) (plist-get f :name)) extras))))
            (gog-backups--replace-game game)
            (gog-backups--save-data-or-msg)
            (run-hook-with-args 'gog-backups-after-backup-hook game)
            t)
        (gog-backups--log "Backup incomplet: %s" (plist-get game :title))
        nil))))

(defun gog-backups--replace-game (game)
  (let ((games (gog-backups--games)))
    (setq games
          (mapcar (lambda (g)
                    (if (equal (plist-get g :id) (plist-get game :id))
                        game g))
                  games))
    (gog-backups--set-games games)))

(defun gog-backups--run-backups ()
  "Backuper tous les jeux marqués."
  (gog-backups--ensure-token)
  (let ((marked (cl-remove-if-not
                 (lambda (g) (plist-get g :selected))
                 (gog-backups--games)))
        (all-ok t))
    (if (not marked)
        (message "No marked games")
      (dolist (game marked)
        (unless (gog-backups--backup-game game)
          (setq all-ok nil)))
      (run-hooks 'gog-backups-all-backups-done-hook)
      (when (derived-mode-p 'gog-backups-mode)
        (gog-backups--refresh-list))
      all-ok)))

;;;; Couche HTTP asynchrone

(defun gog-backups--http-async (method url headers data callback)
  "Requête HTTP asynchrone : CALLBACK reçoit un plist
(:status :headers :body :url), ou (:status error ...).  Les
redirections 30x sont suivies manuellement.  Aucun blocage."
  "Effectuer METHOD sur URL, livrer le résultat à CALLBACK.
STATE = [buffer callback délivré? timer dernière-taille stalls]."
  (cl-labels (http-async-1 (method url headers data callback nredirect)
                           (let ((state (vector nil callback nil nil -1 0)))
                             (condition-case err
                                 (let ((buf (url-retrieve
                                             url
                                             (apply-partially
                                              #'gog-backups--http-async-callback
                                              method url headers data callback nredirect state))))
                                   (aset state 0 buf)
                                   (aset state 4 (buffer-size buf))
                                   ;; url.el n'appelle pas toujours le callback quand la
                                   ;; connexion échoue (DNS, refus) : le timer livre une erreur.
                                   (aset state 3
                                         (run-with-timer 5 5 #'gog-backups--http-async-watch
                                                         state url)))
                               (error
                                (gog-backups--log "requête échouée: %s (%s)" url
                                                  (error-message-string err))
                                (gog-backups--http-async-deliver
                                 state (list :status 'error :url url)))))))

  (gog-backups--http-async-1 method url headers data callback 0))

(defun gog-backups--http-async-deliver (state resp)
  "Livrer RESP une seule fois (état STATE)."
  (unless (aref state 2)
    (aset state 2 t)
    (when (timerp (aref state 3))
      (cancel-timer (aref state 3)))
    (funcall (aref state 1) resp)))

(defun gog-backups--http-async-watch (state url)
  "Timer de surveillance : livrer une erreur si le processus
réseau est mort ou bloqué (aucun octet reçu pendant
gog-backups-request-timeout).  Un téléchargement actif (des octets
arrivent) n'est jamais interrompu."
  (unless (aref state 2)
    (let ((buf (aref state 0)))
      (cond
       ((or (not (buffer-live-p buf))
            (not (get-buffer-process buf)))
        (gog-backups--http-async-deliver
         state (list :status 'error :url url)))
       ((= (buffer-size buf) (aref state 4))
        (aset state 5 (1+ (aref state 5)))
        (when (> (aref state 5) (/ gog-backups-request-timeout 5))
          (let ((proc (get-buffer-process buf)))
            (when proc (delete-process proc))
            (gog-backups--http-async-deliver
             state (list :status 'error :url url)))))
       (t (aset state 4 (buffer-size buf)))))))

(defun gog-backups--http-async-callback (method url headers data callback
                                         nredirect state status)
  "Callback de url-retrieve (voir gog-backups--http-async-1)."
  ;; NB : url.el suit les redirections lui-même ; le callback est
  ;; appelé une seule fois, avec le buffer FINAL (status contient
  ;; :redirect à titre d'information).  Ne pas relancer la requête ni
  ;; toucher au buffer avant lecture.
  (let (resp)
    (unwind-protect
         (cond
           ;; erreur réseau/DNS/TLS : livrer l'erreur
           ((plist-get status :error)
            (setq resp (list :status 'error
                             :error (plist-get status :error)
                             :url url)))
           ((buffer-live-p (current-buffer))
            (let* ((st (or url-http-response-status 'error))
                   (hdrs (ignore-errors (gog-backups--parse-headers))))
              (cond
                ;; redirection NON suivie par url.el (30x restant dans le
                ;; buffer) : la suivre manuellement
                ((and (numberp st)
                      (memq st '(301 302 303 307 308))
                      (cdr (assoc "Location" hdrs))
                      (< nredirect 10))
                 (gog-backups--http-async-1
                  method (gog-backups--resolve-url
                          (cdr (assoc "Location" hdrs)) url)
                  headers data callback (1+ nredirect)))
                (url-http-end-of-headers
                 (set-buffer-multibyte nil)
                 ;; URL finale (après redirections du CDN) : utile pour
                 ;; retrouver le vrai nom de fichier dans le chemin signé
                 (let ((final-url (ignore-errors
                                    (url-recreate-url url-current-object))))
                   (setq resp (list :status st
                                    :headers hdrs
                                    :body (buffer-substring-no-properties
                                           url-http-end-of-headers (point-max))
                                    :url (or final-url url)))))
                (t (setq resp (list :status st :headers hdrs
                                    :body "" :url url)))))))
      (when (buffer-live-p (current-buffer))
        (let ((proc (get-buffer-process (current-buffer))))
          (when proc (delete-process proc)))
        (kill-buffer (current-buffer))))
    ;; livrer une seule fois
    (when resp
      (aset state 4 (length (plist-get resp :body)))
      (gog-backups--http-async-deliver state resp))))

(defun gog-backups--api-async (url callback &optional attempt)
  "Requête API authentifiée asynchrone.  CALLBACK reçoit la réponse
ou nil (abandon).  Retry 503, abandon sur 401/403."
  (gog-backups--ensure-token)
  (let ((headers (list (cons "Authorization"
                             (concat "Bearer "
                                     (plist-get (gog-backups--token)
                                                :access_token))))))
    (gog-backups--http-async "GET" url headers nil
                             (lambda (resp)
                               (let ((st (plist-get resp :status)))
                                 (cond
                                   ((not resp) (funcall callback nil))
                                   ((eq st 'error)
                                    (gog-backups--log "erreur réseau: %s" url)
                                    (funcall callback nil))
                                   ((memq st '(401 403))
                                    (gog-backups--log "accès refusé (%s) : refaites le login (M-x gog-backups-login) puis g" st)
                                    (funcall callback nil))
                                   ((= st 503)
                                    (if (>= (or attempt 0) gog-backups-retry-count)
                                        (progn (gog-backups--log "503 persistant: %s" url)
                                               (funcall callback nil))
                                      (gog-backups--log "503, retry dans %ds" gog-backups-retry-delay)
                                      (run-at-time gog-backups-retry-delay nil
                                                   #'gog-backups--api-async url callback
                                                   (1+ (or attempt 0)))))
                                   ((>= st 400)
                                    (gog-backups--log "erreur HTTP %s: %s" st url)
                                    (funcall callback nil))
                                   (t (funcall callback resp))))))))

;;;; Bibliothèque asynchrone

(defun gog-backups--fetch-library-async (&optional done)
  "Récupérer la bibliothèque + détails par jeu, sans bloquer Emacs.
Appelle DONE avec la liste des jeux, ou nil si abandon."
  (gog-backups--ensure-token)
  (let ((products nil)
        (details nil)
        (total-products 0))
    (cl-labels
        ((finish ()
           (let ((games (gog-backups--build-games products details)))
             (gog-backups--set-games games)
             (gog-backups--save-data-or-msg)
             (run-hooks 'gog-backups-after-fetch-library-hook)
             (when done (funcall done games))))
         (get-details (ids)
           (if (null ids)
               (finish)
             (let ((id (car ids)))
               (gog-backups--log "Détails %d/%d"
                                 (- total-products (length ids) -1)
                                 total-products)
               (gog-backups--api-async
                (format gog-backups--game-details-url id)
                (lambda (resp)
                  (when resp
                    (setq details
                          (cons (cons id
                                      (gog-backups--json-parse
                                       (plist-get resp :body)))
                                details)))
                  (get-details (cdr ids)))))))
         (get-page (page)
           (gog-backups--api-async
            (concat gog-backups--library-url "?"
                    (gog-backups--query-string
                     `(("mediaType" . "1")
                       ("sortBy" . "title")
                       ("page" . ,(number-to-string page)))))
            (lambda (resp)
              (cond
               ((not resp) (when done (funcall done nil)))
               (t
                (let ((json (gog-backups--json-parse
                             (plist-get resp :body))))
                  (setq products (append products
                                         (cdr (assoc 'products json))))
                  (let ((tp (or (cdr (assoc 'totalPages json)) 1)))
                    (if (< page tp)
                        (get-page (1+ page))
                      (setq total-products (length products))
                      (gog-backups--log
                       "Bibliothèque: %d jeux, récupération des détails..."
                       total-products)
                      (get-details
                               (mapcar (lambda (p) (cdr (assoc 'id p)))
                                       products)))))))))))
      (get-page 1))))

;;;; Téléchargements asynchrones

(defun gog-backups--download-headers (offset)
  "Headers HTTP pour un téléchargement avec reprise à OFFSET."
  (append
   (when (> offset 0)
     (list (cons "Range" (format "bytes=%d-" offset))))
   (list (cons "Authorization"
               (concat "Bearer "
                       (plist-get (gog-backups--token) :access_token))))))

(defun gog-backups--download-write (body offset tmp)
  "Écrire BODY dans TMP (append si OFFSET > 0)."
  (let ((coding-system-for-write 'no-conversion))
    (if (> offset 0)
        (with-temp-buffer
          (insert body)
          (append-to-file (point-min) (point-max) tmp))
      (with-temp-buffer
        (insert body)
        (write-region (point-min) (point-max) tmp nil 'quiet)))))

(defun gog-backups--download-file-async (url file expected-size md5 done)
  "Télécharger URL vers FILE, sans bloquer Emacs.
Le nom final du fichier est celui du header Content-Disposition de la
réponse (vrai nom GOG). Appelle DONE avec FILE (ou le chemin
réel) si succès, nil sinon (le .tmp est conservé ou la reprise Range
continue automatiquement)."
  (let* ((tmp (concat file ".tmp"))
         (existing (and (file-exists-p tmp)
                        (file-attribute-size (file-attributes tmp))))
         (offset (if (and existing
                          expected-size
                          (< existing expected-size))
                     existing
                   0))
         (attempt 0)
         (not-finished t))
    (while not-finished
      (gog-backups--log "Téléchargement: %s%s"
                        (file-name-nondirectory file)
                        (if (> offset 0)
                            (format " (reprise à %s)" (gog-backups--human-size offset))
                          ""))
      (gog-backups--http-async "GET" url (gog-backups--download-headers offset) nil))


    (if (> attempt 20)
        (progn
          (gog-backups--log "trop de reprises, abandon: %s" file)
          (funcall done nil))

      (gog-backups--log "Téléchargement: %s%s"
                        (file-name-nondirectory file)
                        (if (> offset 0)
                            (format " (reprise à %s)"
                                    (gog-backups--human-size offset))
                          ""))
      (gog-backups--http-async "GET" url
                               (gog-backups--download-headers offset) nil
                               (lambda (resp)
                                 (let ((status (plist-get resp :status)))
                                   (cond
                                     ((or (not resp) (eq status 'error))
                                      (gog-backups--log "échec réseau: %s" file)
                                      (funcall done nil))
                                     ((not (and (numberp status) (memq status '(200 206))))
                                      (gog-backups--log "téléchargement HTTP %s: %s" status file)
                                      (funcall done nil))
                                     (t
                                      (let* ((body (plist-get resp :body))
                                             (cl (gog-backups--header (plist-get resp :headers)
                                                                      "Content-Length"))
                                             (expected (or expected-size
                                                           (and cl (stringp cl)
                                                                (string-to-number cl))))
                                             (total (+ offset (length body))))
                                        (gog-backups--download-write body offset tmp)
                                        (if (and expected (> expected total))
                                            ;; réponse partielle → reprise Range immédiate
                                            (funcall #'gog-backups--download-file-async
                                                     url file expected-size md5 done)
                                          (condition-case err
                                              (let ((final
                                                     ;; le vrai nom est dans le chemin de
                                                     ;; l'URL finale signée du CDN (ex.
                                                     ;; .../setup_game_1.0_(20270).exe) ;
                                                     ;; fallback : Content-Disposition
                                                     (or (and (plist-get resp :url)
                                                              (file-name-nondirectory
                                                               (url-unhex-string
                                                                (plist-get resp :url))))
                                                         (gog-backups--content-disposition-filename
                                                          (plist-get resp :headers))
                                                         (file-name-nondirectory file)))
                                                    tmp0)
                                                ;; si le vrai nom diffère du prédit, déplacer
                                                ;; le .tmp avant le rename final
                                                (setq file (expand-file-name final (file-name-directory file)))
                                                (setq tmp0 (concat file ".tmp"))
                                                (unless (string= tmp0 tmp)
                                                  (when (file-exists-p tmp0) (delete-file tmp0))
                                                  (rename-file tmp tmp0)
                                                  (setq tmp tmp0))
                                                (when (and md5 gog-backups-verify-md5)
                                                  (unless (gog-backups--verify-md5 tmp md5)
                                                    (delete-file tmp)
                                                    (error "MD5 invalide")))
                                                (gog-backups--verify-zip tmp)
                                                (when (file-exists-p file) (delete-file file))
                                                (rename-file tmp file)
                                                (gog-backups--log "ok: %s (%s)"
                                                                  (file-name-nondirectory file)
                                                                  (gog-backups--human-size total))
                                                (funcall done file))
                                            (error
                                             (gog-backups--log "erreur: %s: %S" file
                                                               (error-message-string err))
                                             (funcall done nil)))))))))))))

(defun gog-backups--download-file-async-disabled (url file expected-size md5 done
                                                  &optional offset attempt)
  "Télécharger URL vers FILE, sans bloquer Emacs.
Le nom final du fichier est celui du header Content-Disposition de la
réponse (vrai nom GOG). Appelle DONE avec FILE (ou le chemin
réel) si succès, nil sinon (le .tmp est conservé ou la reprise Range
continue automatiquement)."
  (let* ((tmp (concat file ".tmp"))
         (existing (and (file-exists-p tmp)
                        (file-attribute-size (file-attributes tmp))))
         (offset (or offset
                     (if (and existing expected-size
                              (< existing expected-size))
                         existing 0)))
         (attempt (or attempt 0)))
    (if (> attempt 20)
        (progn
          (gog-backups--log "trop de reprises, abandon: %s" file)
          (funcall done nil))
      (gog-backups--log "Téléchargement: %s%s"
                        (file-name-nondirectory file)
                        (if (> offset 0)
                            (format " (reprise à %s)"
                                    (gog-backups--human-size offset))
                          ""))
      (gog-backups--http-async "GET" url
                               (gog-backups--download-headers offset) nil
                               (lambda (resp)
                                 (let ((status (plist-get resp :status)))
                                   (cond
                                     ((or (not resp) (eq status 'error))
                                      (gog-backups--log "échec réseau: %s" file)
                                      (funcall done nil))
                                     ((not (and (numberp status) (memq status '(200 206))))
                                      (gog-backups--log "téléchargement HTTP %s: %s" status file)
                                      (funcall done nil))
                                     (t
                                      (let* ((body (plist-get resp :body))
                                             (cl (gog-backups--header (plist-get resp :headers)
                                                                      "Content-Length"))
                                             (expected (or expected-size
                                                           (and cl (stringp cl)
                                                                (string-to-number cl))))
                                             (total (+ offset (length body))))
                                        (gog-backups--download-write body offset tmp)
                                        (if (and expected (> expected total))
                                            ;; réponse partielle → reprise Range immédiate
                                            (funcall #'gog-backups--download-file-async
                                                     url file expected-size md5 done
                                                     total (1+ attempt))
                                          (condition-case err
                                              (let ((final
                                                     ;; le vrai nom est dans le chemin de
                                                     ;; l'URL finale signée du CDN (ex.
                                                     ;; .../setup_game_1.0_(20270).exe) ;
                                                     ;; fallback : Content-Disposition
                                                     (or (and (plist-get resp :url)
                                                              (file-name-nondirectory
                                                               (url-unhex-string
                                                                (plist-get resp :url))))
                                                         (gog-backups--content-disposition-filename
                                                          (plist-get resp :headers))
                                                         (file-name-nondirectory file)))
                                                    tmp0)
                                                ;; si le vrai nom diffère du prédit, déplacer
                                                ;; le .tmp avant le rename final
                                                (setq file (expand-file-name final (file-name-directory file)))
                                                (setq tmp0 (concat file ".tmp"))
                                                (unless (string= tmp0 tmp)
                                                  (when (file-exists-p tmp0) (delete-file tmp0))
                                                  (rename-file tmp tmp0)
                                                  (setq tmp tmp0))
                                                (when (and md5 gog-backups-verify-md5)
                                                  (unless (gog-backups--verify-md5 tmp md5)
                                                    (delete-file tmp)
                                                    (error "MD5 invalide")))
                                                (gog-backups--verify-zip tmp)
                                                (when (file-exists-p file) (delete-file file))
                                                (rename-file tmp file)
                                                (gog-backups--log "ok: %s (%s)"
                                                                  (file-name-nondirectory file)
                                                                  (gog-backups--human-size total))
                                                (funcall done file))
                                            (error
                                             (gog-backups--log "erreur: %s: %S" file
                                                               (error-message-string err))
                                             (funcall done nil)))))))))))))

;;;; Backup asynchrone

(defun gog-backups--backup-finish (game installers extras actual-names
                                   ok done)
  "Finaliser le backup (maj ELD, hooks), appeler DONE.
ACTUAL-NAMES sont les vrais noms des fichiers téléchargés
(Content-Disposition) ; sans eux, on retombe sur les :name prédits."
  (if (not ok)
      (progn
        (gog-backups--log "Backup incomplet: %s" (plist-get game :title))
        (funcall done nil))
    (let* ((version (plist-get game :online-version))
           (names (or (nreverse actual-names)
                      (append (mapcar (lambda (f) (plist-get f :name))
                                      installers)
                              (mapcar (lambda (f) (plist-get f :name))
                                      extras)))))
      (setq game (gog-backups--game-put game :backed-up t))
      (setq game (gog-backups--game-put game :backup-version version))
      (setq game (gog-backups--game-put
                  game :last-backup (format-time-string "%Y-%m-%d")))
      (setq game (gog-backups--game-put game :files names))
      (gog-backups--replace-game game)
      (gog-backups--save-data-or-msg)
      (run-hook-with-args 'gog-backups-after-backup-hook game)
      (funcall done t))))

(defun gog-backups--backup-game-async (game done)
  "Backup GAME.  Call DONE with t if it's a success or nil."
  (run-hook-with-args 'gog-backups-before-backup-hook game)
  (let* ((dir (gog-backups--ensure-game-dir game))
         (installers (plist-get game :installers))
         (extras (plist-get game :extras))
         (all (append installers extras))
         ;; déjà backupé avec la même version → rien à faire
         (uptodate (and (plist-get game :backed-up)
                        (plist-get game :online-version)
                        (string= (or (plist-get game :backup-version) "")
                                 (plist-get game :online-version))))
         (files (if uptodate
                    nil
                  (cl-remove-if-not
                   (lambda (f) (gog-backups--download-need-p dir f))
                   all)))
         (ok t)
         (actual-names nil))
    (gog-backups--log "Backup: %s (%d/%d fichiers)"
                      (plist-get game :title) (length files) (length all))
    (cl-labels ((next (rest)
                  (cond
                    ((null rest)
                     (gog-backups--backup-finish game installers extras
                                                 actual-names ok done))
                    ((null (gog-backups--file-url (car rest)))
                     (gog-backups--log "Pas d'URL pour %s, ignoré"
                                       (plist-get (car rest) :name))
                     (setq ok nil)
                     (next (cdr rest)))
                    (t
                     ;; les installers ont un nom prédit : le vrai nom
                     ;; vient du Content-Disposition du CDN
                     (gog-backups--download-file-async
                      (gog-backups--file-url (car rest))
                      (expand-file-name (plist-get (car rest) :name) dir)
                      (plist-get (car rest) :size)
                      (plist-get (car rest) :md5)
                      (lambda (res)
                        (if res
                            (push (file-name-nondirectory res) actual-names)
                          (setq ok nil))
                        (next (cdr rest))))))))
      (next files))))

(defun gog-backups--run-backups-async (&optional done)
  "Backup the games asynchronously."
  (gog-backups--ensure-token)
  (let ((marked (cl-remove-if-not
                 (lambda (g) (plist-get g :selected))
                 (gog-backups--games))))
    (if (not marked)
        (message "No games marked for backup")
      (let ((all-ok t))
        (cl-labels ((next (rest)
                      (if (null rest)
                          (progn
                            (run-hooks 'gog-backups-all-backups-done-hook)
                            (with-current-buffer gog-backups--buffer-name
                              (when (derived-mode-p 'gog-backups-mode)
                                (gog-backups--refresh-list)))
                            (when done (funcall done all-ok)))
                        (gog-backups--backup-game-async
                         (car rest)
                         (lambda (ok)
                           (unless ok (setq all-ok nil))
                           (next (cdr rest)))))))
          (next marked))))))

;;;; Mode

(defun gog-backups--refresh-list ()
  "Recalculer les entrées du tabulated-list selon le filtre courant."
  (setq tabulated-list-entries
        (cl-loop for game in (gog-backups--games)
              when (gog-backups--match-filter-p game)
              collect (list (plist-get game :id)
                            (gog-backups--row game))))
  (tabulated-list-print))

(defun gog-backups--row (game)
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
  "Sous-keymap des filtres (préfixe /).")

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
  "Keymap du mode `gog-backups-mode'.")

(define-derived-mode gog-backups-mode tabulated-list-mode "GOG-Backups"
  "Major mode pour la liste des backups GOG."
  (setq tabulated-list-format
        [("Mark" 5 t)
         ("Titre" 40 t)
         ("État" 8 t)
         ("Version backup" 20 t)
         ("Version en ligne" 20 t)
         ("OS" 12 t)
         ("Lang" 10 t)
         ("Taille" 10 gog-backups--sort-by-size)])
  (setq tabulated-list-sort-key '("Titre" . nil))
  (tabulated-list-init-header))

(defun gog-backups--match-filter-p (game)
  "If a filter is set, return t if the game match the filter or nil else."
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
  (or (gog-backups--game-by-id (tabulated-list-get-id))
      (error "gog-backups: pas de jeu sous le curseur")))

(defun gog-backups--goto-id (id)
  "Placer le point sur la ligne dont l'identité tabulated est ID."
  (let ((pos (cl-position id tabulated-list-entries :key #'car)))
    (when pos
      (goto-char (point-min))
      (forward-line pos))))

(defun gog-backups--refresh-game-details (game &optional done)
  "Re-télécharger les gameDetails de GAME (async), réextraire
installers/extras selon ses :os-list/:lang-list, mettre à jour
:os-available/:lang-available, puis rafraîchir la liste."
  (gog-backups--api-async
   (format gog-backups--game-details-url (plist-get game :id))
   (lambda (resp)
     (when resp
       (let* ((details (gog-backups--json-parse (plist-get resp :body)))
              (slug (plist-get game :slug))
              (os-list (plist-get game :os-list))
              (lang-list (plist-get game :lang-list))
              (installers (gog-backups--extract-installers
                           details os-list lang-list slug))
              (extras (gog-backups--collect-extras details))
              (online-version (or (plist-get (car installers) :version)
                                  (plist-get game :online-version))))
         (when (listp details)
           (setq game (gog-backups--game-put
                       game :os-available
                       (gog-backups--available-os details))
                 game (gog-backups--game-put
                       game :lang-available
                       (gog-backups--available-lang details))))
         (setq game (gog-backups--game-put game :installers installers))
         (setq game (gog-backups--game-put game :extras extras))
         (setq game (gog-backups--game-put game :online-version online-version))
         (gog-backups--replace-game game)
         (gog-backups--refresh-list)
         (when done (funcall done game)))))))

;;;; Filters

(defun gog-backups-filter-name (name)
  (interactive "sFilter by name: ")
  (setq gog-backups--filter (plist-put gog-backups--filter :name name))
  (gog-backups--refresh-list))

(defun gog-backups-filter-state (state)
  (interactive (list (completing-read "State (NEW/OK/UPDATE): "
                                      '("NEW" "OK" "UPDATE"))))
  (setq gog-backups--filter (plist-put gog-backups--filter :state state))
  (gog-backups--refresh-list))

(defun gog-backups-filter-os (os)
  (interactive (list (completing-read "OS: " gog-backups--os-choices)))
  (setq gog-backups--filter (plist-put gog-backups--filter :os os))
  (gog-backups--refresh-list))

(defun gog-backups-filter-lang (lang)
  (interactive (list (completing-read "Lang: " gog-backups--lang-choices)))
  (setq gog-backups--filter (plist-put gog-backups--filter :lang lang))
  (gog-backups--refresh-list))

(defun gog-backups-filter-clear ()
  (interactive)
  (setq gog-backups--filter nil)
  (gog-backups--refresh-list))

;;;; Interactive commands

(defun gog-backups-refresh ()
  "Re-sync the game list and details."
  (interactive)
  (gog-backups--acquire-lock "Refreshing"
    (gog-backups--log "updating game library...")
    (gog-backups--fetch-library-async
     (lambda (games)
       (if games
           (gog-backups--log "game library updated (%d games)" (length games))
         (gog-backups--log "updates was interrupted by an error (see *GOG Backups Log*)"))
       (gog-backups--release-lock)))))

(defun gog-backups-run ()
  "Backups the selected games."
  (interactive)
  (gog-backups--acquire-lock "Backing up"
    (gog-backups--run-backups-async
     (lambda (_) (gog-backups--release-lock)))))

(defun gog-backups-login ()
  "Log in and save the token."
  (interactive)
  (gog-backups--acquire-lock "Logging in"
    (unwind-protect
         (gog-backups--login)
      (gog-backups--release-lock))))

(defun gog-backups-toggle-mark ()
  "Mark/Unmark games for backup."
  (interactive)
  (gog-backups--acquire-lock "Toggling mark"
    (unwind-protect
         (let* ((game (gog-backups--current-game))
                (game (gog-backups--game-put game :selected
                                             (not (plist-get game :selected)))))
           (gog-backups--replace-game game))
      (gog-backups--release-lock))))

(defun gog-backups-open-dired ()
  "Open the backup directory of the current game in dired."
  (interactive)
  (let ((dir (gog-backups--game-dir (gog-backups--current-game))))
    (if (file-directory-p dir)
        (dired dir)
      (message "This directory doesn't exists: %s" dir))))

(defun gog-backups-set-os ()
  "Set the OS version of the game that will be backup-ed, more than one can
be selected, and at least one must be selected."
  (interactive)
  (gog-backups--acquire-lock "Changing OS settings"
    (let* ((game (gog-backups--current-game))
           (avail (or (plist-get game :os-available)
                      (mapcar #'intern gog-backups--os-choices)))
           (current (plist-get game :os-list))
           selected)
      (dolist (os avail)
        (let ((def (if (member os current)
                       (if (y-or-n-p (format "OS %s : inclure ? (oui par défaut) " os))
                           t
                         nil)
                     (y-or-n-p (format "OS %s : inclure ? (non par défaut) " os)))))
          (when def (push os selected))))
      (setq game (gog-backups--game-put game :os-list (nreverse selected)))
      (gog-backups--replace-game game)
      (gog-backups--save-data-or-msg)
      ;; réextraire les installers avec la nouvelle sélection d'OS
      (gog-backups--log "Mise à jour des fichiers de %s..."
                        (plist-get game :title))
      (gog-backups--refresh-game-details
       game (lambda (updated)
              (gog-backups--log "Fichiers mis à jour: %s"
                                (plist-get updated :title))
              (gog-backups--release-lock))))))

(defun gog-backups-set-lang ()
  "Choisir les langues du jeu pointé."
  (interactive)
  (gog-backups--acquire-lock "Changing Lang settings"
    (let* ((game (gog-backups--current-game))
           (choices (completing-read-multiple
                     "Langues: " gog-backups--lang-choices
                     nil nil (mapconcat #'identity
                                        (plist-get game :lang-list) ","))))
      (setq game (gog-backups--game-put
                  game :lang-list
                  (cl-remove-duplicates choices :test #'string=)))
      (gog-backups--replace-game game)
      (gog-backups--save-data-or-msg)
      (gog-backups--release-lock))))

;;;; Major mode

;;;###autoload
(defun gog-backups ()
  "Open a gog-backups buffer and set major mode."
  (interactive)
  (gog-backups--load-data)
  (let ((buf (get-buffer-create gog-backups--buffer-name)))
    (with-current-buffer buf
      (gog-backups-mode)
      (setq gog-backups--filter nil)
      (gog-backups--refresh-list)
      (pop-to-buffer buf))
    ;; First synchronisation
    (unless (plist-get gog-backups--data :games)
      (gog-backups-refresh))))


(provide 'gog-backups)
;;; gog-backups.el ends here
