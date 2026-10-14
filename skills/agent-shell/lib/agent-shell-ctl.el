;;; agent-shell-ctl.el --- emacsclient control surface for agent-shell -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Support library for the `agent-shell' skill.  Loaded into a running
;; Emacs via emacsclient by bin/agent-shell-ctl, which is the only
;; intended caller.
;;
;; Every entry point writes its result to a file and returns an exit
;; code, so the wrapper never has to unescape `emacsclient --eval'
;; output.

;;; Code:

(require 'agent-shell)
(require 'agent-shell-prompt-queue)
(require 'agent-shell-worktree)
(require 'map)
(require 'seq)

(defvar-local agent-shell-ctl--turns nil
  "Count of completed turns observed in this shell buffer.")

(defvar-local agent-shell-ctl--message nil
  "Chunks of the agent message streaming in this turn, newest first.")

(defvar-local agent-shell-ctl--message-stale nil
  "Non-nil when a tool call ran after `agent-shell-ctl--message' streamed.")

(defvar-local agent-shell-ctl--last-message nil
  "Final agent message of the last completed turn, or nil if none observed.")

(defvar-local agent-shell-ctl--tracking nil
  "Non-nil once the event subscription is installed here.")

(defvar-local agent-shell-ctl--requested nil
  "Alist of (OPTION . VALUE) config options `new' was asked for.")

(defvar-local agent-shell-ctl--model-resolution nil
  "Outcome of sending an unlisted model id straight to the agent.

nil when not tried, `pending' while in flight, `failed' when the
agent refused it, or (REQUESTED . VALUE) once the agent accepted
REQUESTED and switched to its own VALUE.")

(defconst agent-shell-ctl--options
  '(("model" . agent-shell--current-model-id)
    ("mode" . agent-shell--current-mode-id)
    ("thought_level" . agent-shell--current-thought-level-id))
  "Config option categories `config' reports, with their readers.")


;;; Resolution

(defun agent-shell-ctl--sessions ()
  "Return live agent shell buffers."
  (seq-filter #'buffer-live-p (agent-shell-buffers)))

(defun agent-shell-ctl--find (name &optional session-id)
  "Return the shell buffer designated by NAME.

Matches an exact buffer name first, then falls back to a
case-insensitive substring match, which must be unique.

With SESSION-ID, only a buffer whose ACP session id is SESSION-ID
matches, and when NAME is non-empty it must also be named exactly
NAME.  Buffer names are reused, so this is what keeps a caller that
pinned a session's id from reaching a different session started under
the same name.  A resumed session can be open in two buffers with one
id; that is ambiguous unless NAME picks one."
  (if session-id
      (let ((matches (and (not (member session-id '("" "-")))
                          (seq-filter
                           (lambda (buffer)
                             (and (or (string-empty-p name)
                                      (equal (buffer-name buffer) name))
                                  (equal (agent-shell-ctl--session-id buffer)
                                         session-id)))
                           (agent-shell-ctl--sessions)))))
        (pcase (length matches)
          (1 (car matches))
          (0 (if (string-empty-p name)
                 (user-error "No agent session with ACP session id %s" session-id)
               (user-error "No agent session %s with ACP session id %s"
                           name session-id)))
          (_ (user-error "Ambiguous ACP session id %s, matches: %s" session-id
                         (string-join (mapcar #'buffer-name matches) ", ")))))
    (or (seq-find (lambda (buffer) (equal (buffer-name buffer) name))
                  (agent-shell-ctl--sessions))
        (let ((matches (seq-filter
                        (lambda (buffer)
                          (string-match-p (regexp-quote (downcase name))
                                          (downcase (buffer-name buffer))))
                        (agent-shell-ctl--sessions))))
          (pcase (length matches)
            (1 (car matches))
            (0 (user-error "No agent session matching %S.  Known: %s" name
                           (or (string-join (mapcar #'buffer-name
                                                    (agent-shell-ctl--sessions))
                                            ", ")
                               "none")))
            (_ (user-error "Ambiguous session %S, matches: %s" name
                           (string-join (mapcar #'buffer-name matches) ", "))))))))

(defun agent-shell-ctl--agent (buffer)
  "Return the agent identifier of BUFFER as a string."
  (format "%s" (or (map-elt (agent-shell-get-config buffer) :identifier) "unknown")))

(defun agent-shell-ctl--session-id (buffer)
  "Return the ACP session id of BUFFER, or \"-\" when not yet established."
  (or (map-nested-elt (buffer-local-value 'agent-shell--state buffer)
                      '(:session :id))
      "-"))

(defun agent-shell-ctl--describe (buffer)
  "Return a tab-separated description of BUFFER."
  (string-join (list (buffer-name buffer)
                     (format "%s" (agent-shell-status :shell-buffer buffer))
                     (agent-shell-ctl--agent buffer)
                     (format "%s" (agent-shell-ctl--turns buffer))
                     (directory-file-name
                      (buffer-local-value 'default-directory buffer))
                     (agent-shell-ctl--session-id buffer))
               "\t"))


;;; Turn tracking
;;
;; `agent-shell-status' flips to `busy' only once the prompt request is
;; actually sent, so polling it right after a send can observe a stale
;; `ready'.  Count `turn-complete' events instead: the wrapper reads the
;; counter before sending and waits for it to advance.
;;
;; The same subscription keeps the agent's last message as it streamed
;; it, before rendering.  `agent-message-chunk' carries no message id, so
;; a tool call is the boundary: text streamed before one is preamble, and
;; the next chunk after it starts the message again.

(defun agent-shell-ctl--ensure-tracking (buffer)
  "Install the turn counter and message capture in BUFFER, once."
  (with-current-buffer buffer
    (unless agent-shell-ctl--tracking
      (setq-local agent-shell-ctl--tracking t)
      (setq-local agent-shell-ctl--turns 0)
      (agent-shell-subscribe-to
       :shell-buffer buffer
       :on-event (lambda (event)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (agent-shell-ctl--track event))))))))

(defun agent-shell-ctl--track (event)
  "Update the current buffer's turn count and messages from EVENT."
  (pcase (map-elt event :event)
    ('input-submitted
     (setq-local agent-shell-ctl--message nil)
     (setq-local agent-shell-ctl--message-stale nil))
    ('tool-call-update
     (setq-local agent-shell-ctl--message-stale t))
    ('agent-message-chunk
     (when-let* ((chunk (map-nested-elt event '(:data :text-chunk))))
       (when agent-shell-ctl--message-stale
         (setq-local agent-shell-ctl--message nil)
         (setq-local agent-shell-ctl--message-stale nil))
       (push chunk agent-shell-ctl--message)))
    ('turn-complete
     (setq-local agent-shell-ctl--last-message
                 (apply #'concat (reverse agent-shell-ctl--message)))
     (setq-local agent-shell-ctl--turns
                 (1+ (or agent-shell-ctl--turns 0))))))

(defun agent-shell-ctl--turns (buffer)
  "Return the completed turn count observed in BUFFER."
  (agent-shell-ctl--ensure-tracking buffer)
  (or (buffer-local-value 'agent-shell-ctl--turns buffer) 0))


;;; Config
;;
;; agent-shell applies startup config options best effort: a value the
;; agent does not list is skipped with a warning in the buffer, and the
;; session runs on the agent's default.  `check' turns that into a hard
;; failure, so a mistyped --model or --effort never goes unnoticed.
;;
;; Agents may accept model ids they do not list, though: claude-code
;; lists aliases (opus, haiku, ...) and resolves full ids such as
;; claude-opus-5-5 onto them.  So an unlisted model is sent to the agent
;; once more, straight through the public setter, and the agent decides.

(defun agent-shell-ctl--value (option)
  "Return the current value of config OPTION in this shell, or nil.

A model id the agent resolved onto one of its own values reads back
as the id requested, for as long as the agent stays on that value."
  (let ((value (funcall (alist-get option agent-shell-ctl--options nil nil #'equal)
                        agent-shell--state)))
    (if (and value
             (equal option "model")
             (consp agent-shell-ctl--model-resolution)
             (equal value (cdr agent-shell-ctl--model-resolution)))
        (car agent-shell-ctl--model-resolution)
      value)))

(defun agent-shell-ctl--mismatch (option value)
  "Describe how config OPTION differs from the requested VALUE, or nil."
  (let ((current (agent-shell-ctl--value option))
        (offered (agent-shell--default-config-option-values agent-shell--state option)))
    (unless (equal value current)
      (format "--%s %s (has %s; offers %s)"
              (if (equal option "thought_level") "effort" option)
              value (or current "none")
              (if offered (string-join offered ", ") "nothing")))))

(defun agent-shell-ctl--resolve-model (buffer model effort)
  "Ask BUFFER's agent to switch to MODEL, an id it does not list.

On success EFFORT, when non-nil, is set again, since agents scope
thought levels to the model.  The outcome lands in
`agent-shell-ctl--model-resolution'."
  (let ((finish (lambda (outcome)
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (setq-local agent-shell-ctl--model-resolution outcome))))))
    (funcall finish 'pending)
    (agent-shell-set-config-option-value
     :shell-buffer buffer
     :category "model"
     :value model
     :on-success
     (lambda (result)
       (let ((outcome (cons model (map-nested-elt result '(:config-option :current-value)))))
         (if (not effort)
             (funcall finish outcome)
           (condition-case nil
               (agent-shell-set-config-option-value
                :shell-buffer buffer
                :category "thought_level"
                :value effort
                :on-success (lambda (_result) (funcall finish outcome))
                :on-failure (lambda (_result) (funcall finish outcome)))
             ;; No thought level for the new model; `check' reports it.
             (error (funcall finish outcome))))))
     :on-failure (lambda (_result) (funcall finish 'failed)))))


;;; Commands

(defun agent-shell-ctl-agents ()
  "Return one line per known agent identifier and its display name."
  (string-join
   (seq-keep (lambda (config)
               (when-let* ((identifier (map-elt config :identifier)))
                 (format "%s\t%s" identifier
                         (or (map-elt config :mode-line-name) ""))))
             (agent-shell--resolved-agent-configs))
   "\n"))

(defun agent-shell-ctl-list ()
  "Return one tab-separated line per live session."
  (string-join (mapcar #'agent-shell-ctl--describe (agent-shell-ctl--sessions))
               "\n"))

(defun agent-shell-ctl-worktrees-dir (repo)
  "Return the worktrees directory agent-shell would use for REPO."
  (let ((default-directory (file-name-as-directory (expand-file-name repo))))
    (directory-file-name (agent-shell--dot-subdir "worktrees"))))

(defun agent-shell-ctl-worktree-name ()
  "Return a fresh agent-shell style worktree name."
  (agent-shell-worktree--generate-name))

(defun agent-shell-ctl-new (agent dir mode model effort display)
  "Start a shell for AGENT in DIR and return its buffer name.

MODE, MODEL and EFFORT, when non-empty, are applied as ACP session
config options during initialization, EFFORT as the thought level.
`agent-shell-ctl-check' later verifies they took.  DISPLAY non-nil
shows the buffer."
  (let* ((identifier (intern agent))
         (config (or (agent-shell--resolve-config-designator identifier)
                     (user-error "Unknown agent %S.  Known: %s" agent
                                 (string-join
                                  (mapcar (lambda (c)
                                            (format "%s" (map-elt c :identifier)))
                                          (agent-shell--resolved-agent-configs))
                                  ", "))))
         (dir (file-name-as-directory (expand-file-name dir)))
         ;; The thought level goes last: agents scope its values to the
         ;; active model.
         (options (seq-keep #'identity
                            (list (unless (string-empty-p mode) (cons "mode" mode))
                                  (unless (string-empty-p model) (cons "model" model))
                                  (unless (string-empty-p effort)
                                    (cons "thought_level" effort))))))
    (unless (file-directory-p dir)
      (user-error "No such directory: %s" dir))
    (when options
      ;; Copy before mutating: configs come from shared maker functions.
      (setq config (copy-alist config))
      (setf (alist-get :default-config-options config) (lambda () options)))
    (let* ((default-directory dir)
           (agent-shell-cwd-function (lambda () dir))
           (buffer (agent-shell--start :config config
                                       :no-focus t
                                       :new-session t
                                       :session-strategy 'new)))
      (agent-shell-ctl--ensure-tracking buffer)
      (with-current-buffer buffer
        (setq-local agent-shell-ctl--requested options))
      (when display
        (agent-shell--display-buffer buffer))
      (buffer-name buffer))))

(defun agent-shell-ctl-send (name prompt-file steer &optional session-id)
  "Send the contents of PROMPT-FILE to session NAME.

Returns the turn count observed before sending, so the caller can wait
for it to advance.  STEER non-nil injects the prompt into the running
turn instead of queueing it.  SESSION-ID pins NAME as in
`agent-shell-ctl--find'."
  (let* ((buffer (agent-shell-ctl--find name session-id))
         (prompt (with-temp-buffer
                   (insert-file-contents prompt-file)
                   (string-trim-right (buffer-string))))
         (turns (agent-shell-ctl--turns buffer)))
    (when (string-empty-p prompt)
      (user-error "Empty prompt"))
    (with-current-buffer buffer
      (unless (or (map-nested-elt agent-shell--state '(:session :id))
                  (eq agent-shell-session-strategy 'new-deferred))
        (user-error "Session not ready yet"))
      (cond
       ((and steer (shell-maker-busy))
        (unless (agent-shell-steering-supported-p)
          (user-error "Agent %s does not support steering"
                      (agent-shell-ctl--agent buffer)))
        (agent-shell-experimental--send-steering
         :state (agent-shell--state) :prompt prompt)
        (format "steered\t%s" turns))
       ((shell-maker-busy)
        (agent-shell--prompt-queue-enqueue :prompt prompt)
        (format "queued\t%s" turns))
       (t
        (agent-shell--insert-to-shell-buffer
         :text prompt :submit t :no-focus t)
        (format "sent\t%s" turns))))))

(defun agent-shell-ctl-output (name mode lines &optional session-id)
  "Return output from session NAME.

MODE is \"last\" for the agent's final message of the last completed
turn, \"tail\" for the last LINES lines, or \"all\" for the whole
transcript.  \"last\" falls back to the rendered latest response until
a turn completes under `agent-shell-ctl--ensure-tracking'.  SESSION-ID
pins NAME as in `agent-shell-ctl--find'."
  (let ((buffer (agent-shell-ctl--find name session-id))
        (lines (if (stringp lines) (string-to-number lines) lines)))
    (agent-shell-ctl--ensure-tracking buffer)
    (with-current-buffer buffer
      (pcase mode
        ("all" (buffer-substring-no-properties (point-min) (point-max)))
        ("tail"
         (save-excursion
           (goto-char (point-max))
           (forward-line (- (max 1 lines)))
           (buffer-substring-no-properties (point) (point-max))))
        ((guard agent-shell-ctl--last-message) agent-shell-ctl--last-message)
        (_
         (if-let* ((process (get-buffer-process buffer)))
             (save-mark-and-excursion
               ;; `shell-maker-mark-output' marks the output at point and
               ;; only falls back to the latest one from the live prompt.
               (goto-char (process-mark process))
               (shell-maker-mark-output)
               (buffer-substring-no-properties (region-beginning) (region-end)))
           (user-error "Session %s has no running agent" (buffer-name buffer))))))))

(defun agent-shell-ctl-status (name &optional session-id)
  "Return the description line for session NAME, pinned to SESSION-ID."
  (agent-shell-ctl--describe (agent-shell-ctl--find name session-id)))

(defun agent-shell-ctl-config (name &optional session-id)
  "Return session NAME's model, mode and thought level, tab-separated.

SESSION-ID pins NAME as in `agent-shell-ctl--find'."
  (with-current-buffer (agent-shell-ctl--find name session-id)
    (string-join (mapcar (lambda (option)
                           (or (agent-shell-ctl--value (car option)) "-"))
                         agent-shell-ctl--options)
                 "\t")))

(defun agent-shell-ctl-check (name &optional session-id)
  "Return \"pending\" until session NAME has initialized, then \"ready\".

Signal an error naming every config option `new' requested that the
agent did not apply, and the values it offers instead.  SESSION-ID
pins NAME as in `agent-shell-ctl--find'."
  (let ((buffer (agent-shell-ctl--find name session-id)))
    (with-current-buffer buffer
      (let ((model (alist-get "model" agent-shell-ctl--requested nil nil #'equal)))
        (cond
         ((or (not (agent-shell-initialized-p))
              (eq agent-shell-ctl--model-resolution 'pending))
          "pending")
         ((and model
               (not agent-shell-ctl--model-resolution)
               (not (equal model (agent-shell-ctl--value "model")))
               (agent-shell--config-option-by-category agent-shell--state "model"))
          (agent-shell-ctl--resolve-model
           buffer model
           (alist-get "thought_level" agent-shell-ctl--requested nil nil #'equal))
          "pending")
         (t
          (when-let* ((mismatches (seq-keep (lambda (option)
                                              (agent-shell-ctl--mismatch
                                               (car option) (cdr option)))
                                            agent-shell-ctl--requested)))
            (user-error "Agent did not apply %s" (string-join mismatches "; ")))
          "ready"))))))

(defun agent-shell-ctl-kill (name &optional session-id)
  "Kill session NAME, shutting down its ACP client.

SESSION-ID pins NAME as in `agent-shell-ctl--find'."
  (let* ((buffer (agent-shell-ctl--find name session-id))
         (killed (buffer-name buffer)))
    ;; `agent-shell--clean-up' runs from `kill-buffer-hook' and shuts the
    ;; ACP client down; `kill-buffer-query-functions' would otherwise ask.
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))
    (format "killed\t%s" killed)))

(defun agent-shell-ctl-kill-under (dir)
  "Kill every session whose working directory is inside DIR."
  (let ((dir (file-name-as-directory (expand-file-name dir)))
        (killed '()))
    (dolist (buffer (agent-shell-ctl--sessions))
      (when (file-in-directory-p (buffer-local-value 'default-directory buffer) dir)
        (push (buffer-name buffer) killed)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer buffer))))
    (string-join (nreverse killed) "\n")))


;;; Entry point

(defun agent-shell-ctl-run (outfile command &rest args)
  "Run COMMAND with ARGS, writing its output to OUTFILE.

Returns 0 on success and 1 on failure, with the error message written to
OUTFILE instead of the result."
  (condition-case err
      (let ((result (pcase command
                      ("agents" (agent-shell-ctl-agents))
                      ("list" (agent-shell-ctl-list))
                      ("worktrees-dir" (apply #'agent-shell-ctl-worktrees-dir args))
                      ("worktree-name" (agent-shell-ctl-worktree-name))
                      ("new" (apply #'agent-shell-ctl-new args))
                      ("send" (apply #'agent-shell-ctl-send args))
                      ("output" (apply #'agent-shell-ctl-output args))
                      ("status" (apply #'agent-shell-ctl-status args))
                      ("config" (apply #'agent-shell-ctl-config args))
                      ("check" (apply #'agent-shell-ctl-check args))
                      ("kill" (apply #'agent-shell-ctl-kill args))
                      ("kill-under" (apply #'agent-shell-ctl-kill-under args))
                      (_ (user-error "Unknown command: %s" command)))))
        (with-temp-file outfile
          (insert (if (stringp result) result (format "%s" result))))
        0)
    (error
     (with-temp-file outfile
       (insert (error-message-string err)))
     1)))

(provide 'agent-shell-ctl)

;;; agent-shell-ctl.el ends here
