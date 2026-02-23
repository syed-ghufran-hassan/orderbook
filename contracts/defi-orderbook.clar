;; simple-orderbook.clar
;; Minimal working DeFi orderbook with enhancements

;; Constants
(define-constant err-not-found (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-order-filled (err u105))

;; Data structures
(define-map orders
    {order-id: uint}
    {
        trader: principal,
        amount: uint,
        active: bool
    }
)

(define-data-var order-counter uint u0)

(define-map balances
    {user: principal}
    uint
)

;; Public functions
(define-public (deposit (amount uint))
    (begin
        (map-set balances {user: tx-sender} 
            (+ (default-to u0 (map-get? balances {user: tx-sender})) amount))
        (ok true)
    )
)

(define-public (add-order (amount uint))
    (let ((order-id (+ (var-get order-counter) u1))
          (trader tx-sender)
          (current-balance (default-to u0 (map-get? balances {user: trader}))))
        ;; Check balance
        (asserts! (>= current-balance amount) err-insufficient-balance)
        
        ;; Lock tokens
        (map-set balances {user: trader} (- current-balance amount))
        
        ;; Create order
        (map-set orders {order-id: order-id} 
            {
                trader: trader,
                amount: amount,
                active: true
            })
        
        (var-set order-counter order-id)
        (ok order-id)
    )
)

(define-public (fill-order (order-id uint) (fill-amount uint))
    (let ((order (unwrap! (map-get? orders {order-id: order-id}) err-not-found))
          (taker tx-sender)
          (taker-balance (default-to u0 (map-get? balances {user: taker}))))
        ;; Verify order is active
        (asserts! (get active order) err-order-filled)
        (asserts! (<= fill-amount (get amount order)) err-order-filled)
        ;; Verify taker has sufficient balance
        (asserts! (>= taker-balance fill-amount) err-insufficient-balance)
        
        ;; Transfer tokens: taker -> maker
        (map-set balances {user: taker} (- taker-balance fill-amount))
        (map-set balances {user: (get trader order)} 
            (+ (default-to u0 (map-get? balances {user: (get trader order)})) fill-amount))
        
        ;; Update order
        (let ((new-amount (- (get amount order) fill-amount))
              (new-active (if (>= fill-amount (get amount order)) false true)))
            (map-set orders {order-id: order-id} 
                (merge order {amount: new-amount, active: new-active}))
            (ok true))
    )
)

(define-public (cancel-order (order-id uint))
    (let ((order (unwrap! (map-get? orders {order-id: order-id}) err-not-found)))
        (begin
            (asserts! (is-eq (get trader order) tx-sender) err-not-found)
            ;; Refund remaining amount
            (map-set balances {user: tx-sender} 
                (+ (default-to u0 (map-get? balances {user: tx-sender})) (get amount order)))
            ;; Mark order as inactive
            (map-set orders {order-id: order-id} 
                (merge order {amount: u0, active: false}))
            (ok true)
        )
    )
)

;; Read-only
(define-read-only (get-order (order-id uint))
    (map-get? orders {order-id: order-id})
)

(define-read-only (get-balance (user principal))
    (default-to u0 (map-get? balances {user: user}))
)

;; Read-only: list active orders with balances
(define-read-only (get-active-orders-with-balances)
    (let ((count (var-get order-counter))
          (result (list)))
        (define-private (loop id acc)
            (if (> id count)
                acc
                (let ((order (map-get? orders {order-id: id})))
                    (if (is-some order)
                        (let ((o (unwrap! order err-not-found))
                              (balance (default-to u0 (map-get? balances {user: (get trader o)}))))
                            (if (get active o)
                                (loop (+ id u1) (cons
                                    { order-id: id
                                      trader: (get trader o)
                                      amount: (get amount o)
                                      active: true
                                      trader-balance: balance }
                                    acc))
                                (loop (+ id u1) acc)
                            )
                        )
                        (loop (+ id u1) acc)
                    )
                )
            )
        )
        (ok (loop u1 (list)))
    )
)

;; Read-only: paginated active orders
(define-read-only (get-active-orders-with-balances-paged (start-id uint) (limit uint))
  (let ((count (var-get order-counter))
        (result (list)))
    ;; Iterate through order IDs from start-id to start-id + limit
    (begin
      (define-private (loop id acc remaining)
        (if (or (> id count) (<= remaining u0))
            acc
            (let ((order (map-get? orders {order-id: id})))
              (if (is-some order)
                  (let ((o (unwrap! order err-not-found))
                        (balance (default-to u0 (map-get? balances {user: (get trader o)}))))
                    (if (get active o)
                        (loop (+ id u1) (cons
                          { order-id: id
                            trader: (get trader o)
                            amount: (get amount o)
                            active: true
                            trader-balance: balance }
                          acc)
                          (- remaining u1))
                        (loop (+ id u1) acc remaining)
                    )
                  )
                  (loop (+ id u1) acc remaining)
              )
            )
        )
      )
      (ok (loop start-id (list) limit))
    )
  )
)
