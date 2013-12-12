#lang racket/gui

(require data/gvector
         data/queue
         framework
         racket/control)

(define on-local-char/c
  (->m (is-a?/c key-event%) void?))

(define on-paint/c
  (->m any/c (is-a?/c dc<%>) real? real? real? real? real? real?
       (or/c (one-of/c 'no-caret 'show-inactive-caret 'show-caret)
             (cons/c natural-number/c natural-number/c))
       void?))

(provide/contract
  [vim-emulation<%> interface?]
  [vim-emulation-mixin
    (-> (class/c
          (inherit invalidate-bitmap-cache
                   get-position
                   set-position
                   move-position
                   insert
                   copy paste kill undo redo delete
                   line-start-position line-end-position position-line
                   get-view-size local-to-global
                   find-wordbreak get-admin
                   get-style-list get-padding)
          (super on-local-char on-paint))
      (class/c
        [on-paint on-paint/c]
        [on-local-char on-local-char/c]
        (override [on-paint on-paint/c]
                  [on-local-char on-local-char/c])
        [vim? (->m boolean?)]
        [toggle-vim! (->m void?)]))])

(define/contract vim-prompt-tag
  (prompt-tag/c (-> (is-a?/c key-event%) any))
  (make-continuation-prompt-tag))

(define vim-emulation<%>
  (interface () vim?  toggle-vim!))

(define vim-emulation-mixin
  (λ (cls)
    (class* cls (vim-emulation<%>)

      ;; ==== public state & accessors ====
      (inherit get-tab invalidate-bitmap-cache)

      (define/public-final (vim?) vim-emulation?)

      (define/public-final (toggle-vim!)
        (preferences:set 'drracket:vim-emulation? (not vim-emulation?))
        (set! vim-emulation? (not vim-emulation?)))

      ;;; Private state

      ;; vim-style mode
      ;; Editing modes: 'command 'insert 'visual
      ;; Bookkeeping: 'search
      (define mode 'command)

      ;; used to build up a search string
      (define search-queue (make-queue))
      ;; current search string (#f means none set)
      (define search-string #f)

      ;; for ex commands
      (define ex-queue (gvector))

      ;; helpers for searching
      ;; char? -> void?
      (define/private (enqueue-char! char)
        (enqueue-front! search-queue char)
        (update-mode!))

      ;; -> void?
      (define/private (dequeue-char!)
        (dequeue! search-queue)
        (update-mode!))

      ;; -> string?
      (define/private (search-queue->string)
        (list->string (reverse (queue->list search-queue))))

      (define/private (set-mode! new-mode)
        (set! mode new-mode)
        (when (eq? new-mode 'visual-line)
          (move-position 'left #f 'line)
          (move-position 'right #t 'line))
        (when (eq? new-mode 'search)
          (set! search-queue (make-queue)))
        (update-mode!))

      ;; handle the GUI portion of setting the mode line
      (define/private (update-mode!)
        (define frame (send (get-tab) get-frame))
        (send frame set-vim-status-message (mode-string)))

      (define vim-emulation? (preferences:get 'drracket:vim-emulation?))

      (define mode-padding 3)

      ;; continuation into key handling routine
      (define key-cont #f)

      ;; ==== overrides ====
      ;; override character handling and dispatch based on mode
      ;; is-a?/c key-event% -> void?
      (define/override (on-local-char event)
        (if vim-emulation?
            (if key-cont
                (key-cont event)
                (call/prompt
                 (λ ()
                   (match mode
                     ['command (do-command event)]
                     ['insert  (do-insert event)]
                     ['visual  (do-visual event)]
                     ['visual-line (do-visual-line event)]
                     ['search (do-search event)]
                     ['ex (do-ex event)]
                     [_ (error "Unimplemented mode")])
                   (clear-cont!))
                 vim-prompt-tag
                 (λ (k) (set! key-cont k))))
            (super on-local-char event)))

      ;; ==== private functionality ====
      (inherit get-position set-position
               move-position
               insert
               copy paste kill undo redo delete
               line-start-position line-end-position position-line
               local-to-global find-wordbreak)

      ;; mode string for mode line
      ;; -> string?
      (define/private (mode-string)
        (match mode
          ['command ""]
          ['search (string-append "/" (search-queue->string))]
          ['ex (string-append ":" (list->string (gvector->list ex-queue)))]
          [_ (string-upcase (format "-- ~a --" (symbol->string mode)))]))

      ;; provide the next key later
      (define/private (get-next-key)
        (call/comp (λ (k) (abort/cc vim-prompt-tag k))))

      ;; handles a multi-character command
      ;; (is-a?/c key-event%) -> void?
      (define/private (do-command event)
        (define key (send event get-key-code))
        (match key
          ['escape (clear-cont!)]
          [#\d (do-delete (get-next-key))]
          [#\y (do-yank (get-next-key))]
          [_   (do-simple-command event)]))

      ;; handle deletes
      (define/private (do-delete event)
        (let ([deleter (lambda (s e) (send this kill 0 s e))])
          (match (send event get-key-code)
            [#\w (do-word deleter)]
            [#\d (do-line deleter)]
            [_ (clear-cont!)])))

      ;; handle yanking
      (define/private (do-yank event)
        (let ([copier (lambda (s e) (send this copy #f 0 s e))])
          (match (send event get-key-code)
            [#\w (do-word copier)]
            [#\y (do-line copier)]
            [_ (clear-cont!)])))

      (define-syntax-rule (do-line f)
        (let ([b (box 0)])
          (get-position b)
          (define line (position-line (unbox b)))
          (define start (line-start-position line))
          (f (if (zero? start) start (sub1 start))
             (line-end-position line))))

      (define-syntax-rule (do-word f)
        (let ([start (box 0)]
              [end (box 0)])
          (get-position start)
          (get-position end)
          (find-wordbreak start end 'selection)
          (f (unbox start) (unbox end))))

      ;; clear the command continuation
      (define/private (clear-cont!)
        (set! key-cont #f))

      ;; (is-a?/c key-event%) -> void?
      (define/private (do-insert event)
        (if (eq? (send event get-key-code) 'escape)
            (set-mode! 'command)
            (super on-local-char event)))

      ;; (is-a?/c key-event%) -> void?
      (define/private (do-simple-command event)
        (match (send event get-key-code)
          ;; insertion
          [#\a (set-mode! 'insert)]
          [#\A (begin (move-position 'right #f 'line)
                      (set-mode! 'insert))]
          [#\i (set-mode! 'insert)]
          [#\I (begin (move-position 'left #f 'line)
                      (set-mode! 'insert))]
          [#\O (begin (insert-line-before)
                      (move-position 'up)
                      (set-mode! 'insert))]
          [#\o (begin (insert-line-after)
                      (move-position 'down)
                      (set-mode! 'insert))]
          ;; modes
          [#\v (set-mode! 'visual)]
          [#\V (set-mode! 'visual-line)]
          [#\: (set-mode! 'ex)]
          ;; movement
          [#\f (and (send event get-control-down)
                    (move-position 'down #f 'page))]
          [#\b (and (send event get-control-down)
                    (move-position 'up #f 'page))]
          [#\h (move-position 'left)]
          [#\j (move-position 'down)]
          [#\k (move-position 'up)]
          [#\l (move-position 'right)]
          [#\w (move-position 'right #f 'word)]
          [#\b (move-position 'right #f 'word)]
          [#\G (set-position 0)]
          ;; editing
          [#\J (delete-next-newline-and-whitespace)]
          [#\x (delete)]
          ;; copy & paste & editing
          [#\D (delete-until-end)]
          [#\p (paste)]
          [#\u (undo)]
          [#\r (and (send event get-control-down)
                    (redo))]
          ;; search
          [#\/ (set-mode! 'search)]
          [#\n (do-next-search)]
          [_   (void)]))

      ;; (is-a?/c key-event%) -> void?
      (define/private (do-visual event)
        (match (send event get-key-code)
          [#\h (move-position 'left #t)]
          [#\j (move-position 'down #t)]
          [#\k (move-position 'up #t)]
          [#\l (move-position 'right #t)]
          [_ (do-visual-line event)]))

      ;; (is-a?/c key-event%) -> void?
      (define/private (do-visual-line event)
        (match (send event get-key-code)
          ;; modes
          ['escape (set-mode! 'command)]
          ;; copy & paste
          [#\d (visual-kill)]
          [#\x (visual-kill)]
          [#\y (visual-copy)]
          [#\p (begin (paste)
                      (set-mode! 'command))]
          ;; visual movement
          [#\j (visual-line-move 'down)]
          [#\k (visual-line-move 'up)]
          ;; re-indent on tab
          [#\tab (super on-local-char event)]
          [_   (void)]))


      ;; searching
      ;; TODO: - backwards search
      ;;       - fix weird behavior when no more hits remain
      (inherit set-searching-state
               get-search-hit-count
               get-replace-search-hit
               search-updates-pending?)

      ;; (is-a?/c key-event%) -> void?
      ;; handle search mode key events
      (define/private (do-search event)
        (define key (send event get-key-code))
        (match key
          ['escape (set-mode! 'command)]
          [#\return
           (define the-string (search-queue->string))
           (set! search-string the-string)
           (do-next-search)
           (set-mode! 'command)]
          [#\backspace
           (unless (queue-empty? search-queue)
             (dequeue-char!))]
          [(? char?) (enqueue-char! key)]
          [_ (void)]))

      ;; (is-a?/c key-event%) -> void
      ;; handle ex commands
      (define/private (do-ex event)
        (define key (send event get-key-code))
        (match key
          [#\return (run-ex-command)]
          ['escape (set-mode! 'command)]
          [#\backspace
           (unless (= (gvector-count ex-queue) 1)
             (gvector-remove-last! ex-queue))]
          [(? char?) (gvector-add! ex-queue key)]
          [_ (void)])
        (update-mode!))

      ;; run the current ex command
      (define/private (run-ex-command)
        (match (list->string (gvector->list ex-queue))
          ["w" (send this save-file)]
          ["tabnext" (send (send (get-tab) get-frame) next-tab)]
          ["tabprev" (send (send (get-tab) get-frame) prev-tab)]
          [_ (void)])
        (set-mode! 'command)
        (set! ex-queue (gvector)))

      (define/private (do-next-search [start-at-next-word #t])
        (when search-string
          (define old-pos (box 0))
          (get-position old-pos)
          (when start-at-next-word
            (move-position 'right #f 'word))
          ;; set the search state to get the next hit
          (set-searching-state search-string #f #t #f)
          (let loop ()
            (when (search-updates-pending?)
              (yield)
              (loop)))
          (if (get-replace-search-hit)
              (set-position (get-replace-search-hit))
              (set-position (unbox old-pos)))
          ;; immediately clear the state to remove bubbles
          (set-searching-state #f #t #f #f)))

      ;; deletes starting from the next newline and to the first
      ;; non-whitespace character after that position
      (define/private (delete-next-newline-and-whitespace)
        (define newline-pos (send this find-newline))
        (when newline-pos
          (send this begin-edit-sequence)
          (delete newline-pos)
          (let loop ([char (send this get-character newline-pos)])
            (when (and (char-whitespace? char)
                       (not (eq? #\newline char)))
              (delete newline-pos)
              (loop (send this get-character newline-pos))))
          (send this end-edit-sequence)))

      ;; -> void?
      (define/private (delete-until-end)
        (let* ([b (box 0)]
               [_ (get-position b)]
               [line (position-line (unbox b))]
               [eol (line-end-position line)])
          (kill 0 (unbox b) eol)))

      ;; move selection by line
      ;; : (one-of/c 'down 'up) -> void?
      (define/private (visual-line-move dir)
        (move-position dir #t)
        (move-position 'right #t 'line))

      ;; copy selection
      (define/private (visual-copy)
        (let ([bs (box 0)]
              [be (box 0)])
          (get-position bs be)
          (copy #f 0 (unbox bs) (unbox be))
          (visual-cleanup)))

      ;; kill selection
      (define/private (visual-kill)
        (let ([bs (box 0)]
              [be (box 0)])
          (get-position bs be)
          (kill 0 (unbox bs) (unbox be))
          (visual-cleanup)))

      ;; clear selection and end visual mode
      (define/private (visual-cleanup)
        (let ([b (box 0)])
          (get-position b)
          (set-position (unbox b) 'same)
          (set-mode! 'command)))
      
      ;; insert line after the line the cursor is currently on
      (define/private (insert-line-after)
        (define-values (_start end) (get-current-line-start-end))
        (insert "\n" end))
      
      ;; insert line before the line the cursor is currently on
      (define/private (insert-line-before)
        (define-values (start _end) (get-current-line-start-end))
        (insert "\n" (if (zero? start) start (sub1 start))))
      
      ;; -> (values int int)
      ;; gets the start and end position of the line at the start of current selection
      (define/private (get-current-line-start-end)
        (define b (box 0))
        (get-position b)
        (define line (position-line (unbox b)))
        (values (line-start-position line)
                (line-end-position line)))
      
      (define/private (get-selection event)
        (define k (send event get-key-code))
        (define pb (box #f))
        (get-position pb)
        (match k
          #;[#\G ]
          [#\g (values 0 (unbox pb))]
          #;[#\w]
          #;[#\b]
          #;[#\%]
          #;[#\e]))

      (super-new))))

