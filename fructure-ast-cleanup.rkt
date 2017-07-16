#lang racket

(require lens/common)
(require lens/data/list)
(require racket/gui/base)
(require fancy-app)
(require "fructure-style.rkt")

; ----------------------------------------------------------------------------

(define atom? (compose not pair?))

(define proper-list? (conjoin list? (compose not empty?)))

(require (rename-in racket (#%app call)))
(define-syntax #%app
  (syntax-rules (⋱↦ ↓ ⇐ ∘ ≡)
    [[#%app pattern ≡]
     (match-lambda
       [`pattern #true]
       [_ #false])]
    [[#%app pattern ⋱↦ result]
     (#%app [pattern ⋱↦ result])]
    [(#%app [pattern ⋱↦ result] ...)
     (letrec ([transform (match-lambda
                           [`pattern `result] ...
                           [a #:when (not (pair? a)) a]
                           [ls (map transform ls)])])
       transform)]
    [(#%app f-expr arg-expr ...) (call f-expr arg-expr ...)]))


(define-syntax-rule (↓ [pattern ⋱↦ result] ...)
  ([pattern ⋱↦ result] ...)) ; explicit fallthrough annotation


(define-syntax-rule (map-into source [<pattern> <payload> ...] ...)
  (letrec ([recursor (match-lambda
                       [<pattern> <payload> ...] ...
                       [(? list? x) (map recursor x)]
                       [(? atom? x) x])])
    (recursor source)))

(define-syntax-rule (map-into-fruct source [<pattern> <payload> ...] ...)
  (letrec ([recursor (match-lambda
                       [<pattern> <payload> ...] ...
                       [`(,x . ,xs) (map recursor xs)]
                       [(? atom? x) x])])
    (recursor source)))


; ----------------------------------------------------------------------------

(require (for-syntax racket/match racket/list racket/syntax racket/function fancy-app))
(begin-for-syntax
  
  (define L1-form-names '(if begin define let send new env kit meta)) ; copy with stuff added
  (define L1-sort-names '(expr name)) ; copy
  (define L1-affo-names '(▹ selector)) ;copy

  (define atom? (compose not pair?)) ; copy

  (define transpose (curry apply map list))

  (define (map-rec fn source)
    (match (fn source)
      [(? list? ls) (map (curry map-rec fn) ls)]
      [(? atom? a) a]))

  
  ; desugars _ ... into (ooo _)
  (define/match (undotdotdot source)
    [((list a ... b '... c ...)) `(,@(undotdotdot a) (ooo ,b) ,@c)]
    [(_) source])

  
  ; resugars (ooo _) into _ ...
  (define/match (redotdotdot source)
    [(`(,a ... (ooo ,b) ,c ...)) `(,@(redotdotdot a) ,b ... ,@c)]
    [(_) source])

  
  (define-values  (†quote
                   †quasiquote
                   †unquote
                   †unquote-splice) (values ((curry list) 'quote)
                                            ((curry list) 'quasiquote)
                                            ((curry list) 'unquote)
                                            ((curry list) 'unquote-splicing)))

  ; rewrites a form signature into a pattern-template pair for the parser
  (define (make-parse-pair pattern)
    (match pattern
      [(? (λ (x) (member x L1-form-names)))
       `(,pattern ,pattern)]
      [(? (λ (x) (member x L1-sort-names)))
       `(,(†unquote (gensym)) ,pattern)]
      [`(ooo ,(app make-parse-pair `(,new-pat ,new-temp)))
       `((ooo ,new-pat) ,(†unquote-splice `(make-list (length ,(†quasiquote (if (equal? 'unquote (first new-pat)) new-pat (first new-pat)))) ,(†quote new-temp))))]
      ; the above is sort of a hack. the test for first not equalling unquote detects when new-pat is actually a list of pats
      ; but maybe not robustly? to clarify, when the first is unquote we're assuming it's just a quoted, unquoted variable name
      [(? list? ls)
       (transpose (map make-parse-pair ls))]))

  
  ; maps in the ignore-affo pattern to stop in-line afforfances from interferring with parsing
  (define (add-ignores source)
    (match source
      ['... '...]
      [(list 'unquote x) source]
      [(? symbol?) (†unquote `(ignore-affo ,source))]
      [(? list?) (†unquote `(ignore-affo ,(map add-ignores source)))]))

  
  ; rewrites a list of form signatures into pattern-template pairs for the parser
  (define form-list->parse-pairs
    (compose (λ (x) (map (match-lambda [`(,(app add-ignores pat) ,tem) `(,pat ,tem)]) x))
             (λ (x) (map (map-rec redotdotdot _) x))
             (λ (x) (map make-parse-pair x))
             (λ (x) (map (map-rec undotdotdot _) x)))))



; changes a pattern into one that ignores over-wrapped affordances
(define-match-expander ignore-affo
  (syntax-rules ()
    [(ignore-affo <pat>)
     (app (λ (source) (match source
                        [`(,(? (λ (x) (member x L1-affo-names))) ,a) a]
                        [_ source])) `<pat>)]))


; matches source to a form from the provided list 
(define-syntax (source+grammar->form stx)
  (syntax-case stx ()
    [(_ <source> <forms>)
     (let ([parse-pairs (form-list->parse-pairs (eval (syntax->datum #'<forms>)))])
       (with-syntax* ([((<new-pat> <new-tem>) ...) (datum->syntax #'<source> parse-pairs)])
         #'(match <source>
             [`<new-pat> `<new-tem>] ...
             [(? atom? a) a])))])) ; atom case (temporary hack)




; parsing --------------------------------------------------------------------

(define L1 '((atom (|| (name
                        literal))) ; attach predicates
             (expr (|| (if expr expr expr)
                       (begin expr ...)
                       (define (name name ...) expr ...)
                       (let ([name expr] ...) expr ...)
                       atom))))

(define L1-sort-names '(atom hole expr))
(define L1-form-names '(if begin define let))
(define L1-terminal-names '(name name-ref literal))
(define L1-affo-names '(▹ selector)) ;copy

(define (source->form source)
  (source+grammar->form source '((if expr expr expr)
                                 (begin expr ...)
                                 (define (name name ...) expr ...)
                                 (define name expr)
                                 (let ([name expr] ...) expr ...)
                                 (send expr expr expr ...)
                                 (new expr [name expr] ...)
                                 (env expr ...)
                                 (kit expr ...)
                                 (meta expr ...)
                                 (expr expr ...))))


(define (sel◇ source) `(◇ ,source))

(define/match (◇-project source)
  [(`(◇ ,a)) a]
  [((? atom? a)) #f]
  [(_) (let ([result (filter-map ◇-project source)])
         (if (empty? result) #f (first result)))])

(define (lens-ith-child i fn source)
  (lens-transform (list-ref-lens i) source fn))

(define (◇-ith-child i)
  [(◇ (,ls ...)) ⋱↦ ,(lens-ith-child i sel◇ ls)])

(define (->child-contexts parent-context src)
  (map (λ (i) ((◇-ith-child i) parent-context)) (range (length src))))

(define-values (terminal-name?
                form-name?
                affo-name?) (values (λ (x) (member x L1-terminal-names))
                                    (λ (x) (member x L1-form-names))
                                    (λ (x) (member x L1-affo-names))))


(define (sexp->fruct source [ctx `(top (◇ expr))])
  (match source
    [`(,(? affo-name? name) ,selectee) 
     `(,(hash 'self `(name hole)
              'context ctx) ,(hash 'self name
                                   'context `((◇ name) hole)) ,(sexp->fruct selectee ctx))]
    ; the above is a hack. it skips (single) selections
    ; and just passes the context along to the selectee
    [_
     (match (◇-project ctx)
       [(? (disjoin terminal-name? form-name?))
        (hash 'self source
              'context ctx)]
       ['expr
        (let* ([form (source->form source)]
               [hash (hash 'self form
                           'context ctx)])
          (if (list? form)
              `(,hash ,@(map sexp->fruct source (->child-contexts `(◇ ,form) source)))
              hash))]
       [(? list?)
        `(,(hash 'self '()
                 'context ctx) ,@(map sexp->fruct source (->child-contexts ctx source)))])]))


(define/match (get-symbol fruct)
  [(`(,(hash-table ('self s)) ,ls ...)) s])


(define/match (project-symbol fruct)
  [(`(,x ,xs ...)) (map project-symbol xs)]
  [((hash-table ('self s))) s])


(define (fruct->fruct+gui source [parent-ed "fuck"])
  ((let* ([ed (new fruct-ed%)]
          [sn (new fruct-sn% [editor ed] [parent-editor parent-ed])])
     (if (list? source)
         (map (λ (x) (fruct->fruct+gui x ed)) source)
         (hash-set source 'gui (gui sn ed parent-ed))))))





; YOU ARE HERE!












; gui objs & structs ------------------------------------

(struct gui (sn ed parent-ed))

(define fruct-board%
  (class pasteboard% 
    (define/override (on-default-char event)
      (char-input event))
    (super-new)))


(define fruct-ed%
  (class text% (super-new [line-spacing 0])
    
    (define/public (set-text-color color)
      ;must be after super so style field is intialized
      (define my-style-delta (make-object style-delta%))
      
      #; (send my-style-delta set-delta-background color) ; text bkg
      #; (send my-style-delta set-alignment-on 'top) ; ???
      #; (send my-style-delta set-transparent-text-backing-on #f) ; ineffective
      
      (match color
        [`(color ,r ,g ,b)
         (send my-style-delta set-delta-foreground (make-color r g b))])
      
      (send this change-style my-style-delta))
    
    (define/public (set-format format)
      (match format
        ['horizontal (format-horizontal)]
        ['vertical (format-vertical)]
        ['indent (format-indent-after 2)]))

    (define/public (set-string-form string)
      (remove-text-snips)
      (send this insert string))
         
    (define (remove-text-snips)
      (for ([pos (range 0 (send this last-position))])
        (when (is-a? (send this find-snip pos 'before) string-snip%)
          (send this release-snip (send this find-snip pos 'before))
          (remove-text-snips))))

    (define (format-horizontal)
      (remove-text-snips))
                    
    (define (format-vertical)
      (remove-text-snips)
      (let ([num-items (send this last-position)])
        (for ([pos (range 1 (- (* 2 num-items) 2) 2)])
          (send this insert "\n" pos))))

    
    ; todo: update this to take variable number of spaces
    (define (format-indent-after start-at)
      (remove-text-snips)
      (let ([num-items (send this last-position)])
        (for ([pos (range start-at (* 2 (sub1 num-items)) 2)])
          (send this insert "\n" pos))
        (for ([line-num (range 1 (sub1 num-items))])
          (send this insert "    " (send this line-start-position line-num)))))

    (define/override (on-default-char event)
      (char-input event))))


(define fruct-sn%
  (class editor-snip% (super-new [with-border? #f])
                    
    (init-field parent-editor)
    
    (field [background-color (make-color 28 28 28)]) ; current default
    (field [border-color (make-color 0 255 0)])
    (field [border-style 'none])
    
    (define/public (set-background-color color)
      (match color
        [`(color ,r ,g ,b)
         (set! background-color (make-color r g b))]))
    
    (define/public (set-border-color color)
      (match color
        [`(color ,r ,g ,b)
         (set! border-color (make-color r g b))]))
    
    (define/public (set-border-style style)
      (set! border-style style))

    (define/public (set-margins l t r b)
      #; (send this set-inset 0 0 0 0)
      #; (send this set-align-top-line #t) ; ???
      (send this set-margin l t r b))

    
    (define/override (draw dc x y left top right bottom dx dy draw-caret)
 
      #; (send dc set-text-mode 'transparent) ; ineffective
      #; (send dc set-background "blue") ; ineffective
      #; (send editor get-extent width height) ; try this instead?

      #; (define bottom-x (box 2))
      #; (define bottom-y (box 2))
      #; (send parent-editor get-snip-location this bottom-x bottom-y #t)
      #; (send dc draw-rectangle (+ x 0) (+ y 0) (+ (unbox bottom-x) 0) (+ (unbox bottom-y) 0))

      
      (define-values (a-w a-h a-descent a-space a-lspace a-rspace)
        (values (box 0) (box 0) (box 0) (box 0) (box 0) (box 0) ))
 
      (send this get-extent dc x y a-w a-h a-descent a-space a-lspace a-rspace)
      
      (define-values (left-x top-y right-x bot-y width height)
        (values x y (+ x (unbox a-w)) (+ y (unbox a-h)) (unbox a-w) (unbox a-h)))

      
      (define (draw-background color)
        (send this use-style-background #t) ; otherwise whiteness ensues
        (send dc set-brush color 'solid)
        (send dc set-pen color 1 'solid)
        (send dc draw-rectangle (+ x 0) (+ y 0) (+ width 0) (+ height 0)))

      (define (draw-left-square-bracket color)
        (send dc set-pen color 1 'solid)
        (send dc draw-line left-x top-y left-x (+ bot-y -1))
        (send dc draw-line left-x top-y (+ 2 left-x) top-y)
        (send dc draw-line left-x (+ bot-y -1) (+ 2 left-x) (+ bot-y -1)))

      (define (draw-right-square-bracket color)
        (set! color (make-color 120 145 222)) ; temp
        (send dc set-pen color 1 'solid)
        (send dc draw-line (+ -1 right-x) top-y (+ -1 right-x) (+ bot-y -1))
        (send dc draw-line right-x top-y (+ -2 right-x) top-y)
        (send dc draw-line right-x (+ bot-y -1) (+ -2 right-x) (+ bot-y -1)))

      (define (draw-square-brackets color)
        (draw-left-square-bracket color)
        #;(draw-right-square-bracket color))

      
      ; actual draw calls (order sensitive!) -------------------------
      
      (draw-background background-color)
      
      (case border-style
        ['none void]
        ['square-brackets (draw-square-brackets border-color)])

      (send dc set-pen (make-color 255 255 255) 1 'solid)
      (super draw dc x y left top right bottom dx dy draw-caret))))


(define (update-gui)
  (let* ([new-main-board (new fruct-board%)]
         [new-kit-board (new fruct-ed%)]
         [new-stage-board (new fruct-ed%)]
         [stage-board-snip (new fruct-sn% [editor new-stage-board] [parent-editor new-main-board])]
         [kit-snip (new fruct-sn% [editor new-kit-board] [parent-editor new-main-board])])

    (set! stage-gui (new-gui stage new-stage-board))
    (send new-main-board insert stage-board-snip)
    
    (set! kit-gui (new-gui kit new-kit-board))
    (send new-main-board insert kit-snip)
    
    (send new-main-board move-to stage-board-snip 200 0)
    
    (send my-canvas set-editor new-main-board)
    (send new-main-board set-caret-owner #f 'global)))


(define (new-gui source parent-ed)
  (let ([obj-source 0 #;(gui-pass:object source parent-ed)])   
    #; (set! obj-source (gui-pass:forms source obj-source))    
    #; (set! obj-source ((gui-pass [(fruct sort type name text style mt)
                                    (fruct sort type name text (lookup-style name type) mt)]) obj-source))
    #; (set! obj-source (gui-pass:cascade-style obj-source)) 
    #; ((gui-pass [(fruct _ _ _ text _ (meta sn _ parent-ed)) ; changes behavior is done after forms pass??
                   (unless #f #;(equal? text "▹")
                     (send parent-ed insert sn))]) obj-source) 
    #; ((gui-pass [(fruct _ _ _ _ style (meta sn ed _))
                   (apply-style! style sn ed)]) obj-source)    
    #; ((gui-pass [(fruct _ type _ text _ (meta sn ed _)) ; must be after style cause style deletes text
                   (when (not (equal? text "?"))
                     (send ed insert text))]) obj-source) 
    obj-source))


; transformation ---------------------------------------

(define simple-select
  [,a ⋱↦ (▹ ,a)])

(define simple-deselect
  [(▹ ,a) ⋱↦ ,a]) ; note: doesn't work if a is list. needs new rule with context

(define forms+ #hash(("define" . (define (▹ /name/) /expr/)) ; how about this notation?
                     ("λ" . (λ ((▹ variable) ⋯) expr))
                     ("define ()" . (define ((▹ name) variable ⋯) expr))
                     ("let" . (let ([(▹ name) expr] ⋯) expr))
                     ("letrec" . (letrec ([(▹ name) expr] ⋯) expr))
                     ("begin" . (begin (▹ expr) expr ⋯))
                     ("if" . (if (▹ expr) expr expr))
                     ("cond" . (cond [(▹ expr) expr] ⋯ [expr expr]))
                     ("match" . (match (▹ expr) [pattern expr] ⋯))
                     ("quote" . (quote (▹ expr)))
                     ("unquote" . (unquote (▹ expr)))
                     ("map" . (map (▹ fn) ls ⋯))))

(define (insert-form name)
  [(▹ ,a) ⋱↦ ,(hash-ref forms+ name)])


; simple nav 

(define first-child
  [(▹ (,a ,b ...)) ⋱↦ ((▹ ,a) ,@b)])

(define last-child
  [(▹ (,a ... ,b)) ⋱↦ (,@a (▹ ,b))])

(define parent
  [(,a ... (▹ ,b ...) ,c ...) ⋱↦ (▹ (,@a ,@b ,@c))])


; atomic nav

(define/match (first-contained-atom source)
  [(`(▹ ,(? atom? a))) `(▹ ,a)]
  [(`(▹ ,ls)) (first-contained-atom-inner ls)]
  [((? atom? a)) a] 
  [(ls) (map first-contained-atom ls)])

(define/match (first-contained-atom-inner source)
  [((? atom? a)) `(▹ ,a)]
  [(`(,a ,b ...)) `(,(first-contained-atom-inner a) ,@b)])

(define/match (last-contained-atom source)
  [(`(▹ ,(? atom? a))) `(▹ ,a)]
  [(`(▹ ,ls)) (last-contained-atom-inner ls)]
  [((? atom? a)) a] 
  [(ls) (map last-contained-atom ls)])

(define/match (last-contained-atom-inner source)
  [((? atom? a)) `(▹ ,a)]
  [(`(,a ... ,b )) `(,@a ,(last-contained-atom-inner b))])

(define/match (selector-at-start? source)
  [((? atom? a)) #false]
  [(`(▹ ,a)) #true]
  [(`(,a ,b ...)) (selector-at-start? a)])

(define/match (selector-at-end? source)
  [((? atom? a)) #false]
  [(`(▹ ,a)) #true]
  [(`(,a ... ,b)) (selector-at-end? b)])

(define next-atom
  (↓ [(▹ ,a) ⋱↦ (▹ ,a)]
     [(,a ... ,(? selector-at-end? b) ,c ,d ...) ⋱↦ (,@a ,(simple-deselect b) ,(first-contained-atom `(▹ ,c)) ,@d)]))

(define prev-atom
  (↓ [(▹ ,a) ⋱↦ (▹ ,a)]
     [(,a ... ,b ,(? selector-at-start? c) ,d ...) ⋱↦ (,@a ,(last-contained-atom `(▹ ,b)) ,(simple-deselect c) ,@d)]))


; simple transforms

(define delete
  [(,a ... (▹ ,b ...) ,c ...) ⋱↦ (▹ (,@a ,@c ))])

(define insert-child-r
  [(▹ (,a ...)) ⋱↦ (,@a (▹ (☺)))])

(define insert-child-l
  [(▹ (,a ...)) ⋱↦ ((▹ (☺)) ,@a)])

(define new-sibling-r
  [(,a ... (▹ (,b ...)) ,c ...) ⋱↦ (,@a ,@b (▹ (☺)) ,@c)])

(define new-sibling-l
  [(,a ... (▹ (,b ...)) ,c ...) ⋱↦ (,@a (▹ (☺)) ,@b ,@c)])

(define wrap
  [(▹ (,a ...)) ⋱↦ (▹ ((,@a)))])




; helpers for main loop ------------------------------

(define (toggle-mode!)
  (if (equal? mode 'navigation) (set! mode 'text-entry) (set! mode 'navigation)))

; changes direction of nav keystrokes depending on visual layout
(define (relativize-direction key-code sn parent-ed)
  key-code
  #;(define (before-linebreak?)
      (let* ([snip-pos (send parent-ed get-snip-position sn)]
             [next-snip (send parent-ed find-snip (add1 snip-pos) 'after-or-none)])
        (if (equal? next-snip #f)
            #f
            (equal? (send next-snip get-text 0 1) "\n"))))
  #;(define (after-linebreak?)
      (let* ([snip-pos (send parent-ed get-snip-position sn)]
             [prev-snip (send parent-ed find-snip snip-pos 'before-or-none)])
        (if (equal? prev-snip #f)
            #f
            (or (equal? (send prev-snip get-text 0 1) "\n")
                (equal? (send prev-snip get-text 0 1) " ")
                #|this hacky second case deals with indents|#))))
  #;(cond
      [(and (before-linebreak?) (equal? key-code #\s)) #\d]
      [(and (after-linebreak?) (equal? key-code #\w)) #\a]
      [else key-code]))


(define/match (sel-to-pos sel-tree [pos '()])
  [(_ _) #:when (not (list? sel-tree)) #f]
  [(`(▹ ,a) _) '()]
  [(_ _) (let ([result (filter identity
                               (map (λ (sub num)
                                      (let ([a (sel-to-pos sub pos)])
                                        (if a `(,num ,@a) #f)))
                                    sel-tree
                                    (range 0 (length sel-tree))))])
           (if (empty? result) #f (first result)))])


(define/match (obj-at-pos obj-tree pos)
  [(_ `()) (first obj-tree) #;(third obj-tree)] ; use third if you don't want the selector itself
  [(_ `(,a . ,as)) (obj-at-pos (list-ref (rest obj-tree) a) as)])




; main loop ---------------------------------------------

(define (update source input)
  (let ([transform (match input
                     [#\space identity]
                     [#\e first-child]
                     [#\z last-child]
                     [#\q parent]
                     [#\d next-atom]
                     [#\a prev-atom]
                     [#\i delete]
                     [#\o insert-child-r]
                     [#\u insert-child-l]
                     [#\l new-sibling-r]
                     [#\j new-sibling-l]
                     [#\k wrap])])
    (transform source)))


(define (char-input event)
  (match-let* ([key-code (send event get-key-code)]
               [pos (sel-to-pos stage)]
               [obj (obj-at-pos stage-gui pos)]
               [`(fruct,sort type name text style (meta ,sn ,ed ,parent-ed)) obj])
    (when (not (equal? key-code 'release))
      (case mode
        ['navigation (match key-code
                       [#\space (toggle-mode!)
                                (send parent-ed set-caret-owner sn 'global)
                                (send ed set-position 0)]                                     
                       [_ (set! key-code (relativize-direction key-code sn parent-ed))
                          (set! stage (update stage key-code))
                          (set! stage-gui (new-gui stage (new fruct-ed%)))
                          ; above is hack so stage-gui is current for next line
                          #; (set! kit (update-kit kit kit-gui stage stage-gui key-code))
                          (update-gui)])]
        ['text-entry (match key-code
                       [#\space (toggle-mode!)      
                                (let ([input-chars (send ed get-text 0 num-chars)])
                                  (set! stage ((insert-form input-chars) stage))
                                  (set! num-chars 0))
                                (update-gui)]
                       [(app string (regexp #rx"[A-Za-z0-9_]")) (set! num-chars (add1 num-chars))
                                                                (send ed insert key-code)])]))))




; gui setup ---------------------------------------------

(define my-frame
  (new frame%
       [label "fructure"]
       [width 1300]
       [height 900]))

(define my-canvas
  (new editor-canvas%
       [parent my-frame]))

#; (send my-frame show #t) ; MUST UNCOMMENT TO DISPLAY!!!
#; (update-gui)




; testing ------------------------------------------------

; init stage and kit
(define stage '(▹ (define (fn a) a (define (g q r) 2))))
(define kit '(kit (env) (meta)))

; init gui refs
(define stage-gui '())
(define kit-gui '())

; init globals
(define mode 'navigation)
(define num-chars 0)

(define test-src2 '(define (fn a) a (define (g q r) 2)))
(define test-src '(define (selector (fn a)) 7))



(source+grammar->form  '((selector let) (▹ ([f a][f a][k a][g a])) 4 4 4) '((if expr expr expr)
                                                                            (begin expr ...)
                                                                            (define (name name ...) expr ...)
                                                                            (let ([name expr] ...) expr ...)))

(pretty-print (sexp->fruct test-src))
test-src
(project-symbol (sexp->fruct test-src))
(map-into-fruct (sexp->fruct test-src) [(hash-table ('self s)) s])

#;(map-into test-src ['a 'b])
