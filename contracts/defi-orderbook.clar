;; orderbook.clar
;; DeFi Orderbook implementation for Stacks blockchain

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-order (err u103))
(define-constant err-unauthorized (err u104))
(define-constant err-order-filled (err u105))
(define-constant err-transfer-failed (err u106))
(define-constant err-lock-failed (err u107))

;; Trading fee (1% = 100 basis points)
(define-constant trading-fee u100)

;; Data structures for orders
(define-map buy-orders
    {order-id: uint}
    {
        trader: principal,
        token-in: principal,
        token-out: principal,
        amount-in: uint,
        amount-out: uint,
        price: uint,
        timestamp: uint,
        active: bool
    }
)

(define-map sell-orders
    {order-id: uint}
    {
        trader: principal,
        token-in: principal,
        token-out: principal,
        amount-in: uint,
        amount-out: uint,
        price: uint,
        timestamp: uint,
        active: bool
    }
)

;; Order counters
(define-data-var buy-order-counter uint u0)
(define-data-var sell-order-counter uint u0)

;; User balances tracking
(define-map user-token-balances
    {user: principal, token: principal}
    uint
)

;; Helper functions for token management
(define-private (has-sufficient-balance (user principal) (token principal) (amount uint))
    (>= (default-to u0 (map-get? user-token-balances {user: user, token: token})) amount)
)

(define-private (lock-tokens (user principal) (token principal) (amount uint))
    (let ((current-balance (default-to u0 (map-get? user-token-balances {user: user, token: token}))))
        (if (>= current-balance amount)
            (begin
                (map-set user-token-balances
                    {user: user, token: token}
                    (- current-balance amount)
                )
                (ok true))
            (err err-insufficient-balance)
        )
    )
)

(define-private (unlock-tokens (user principal) (token principal) (amount uint))
    (let ((current-balance (default-to u0 (map-get? user-token-balances {user: user, token: token}))))
        (map-set user-token-balances
            {user: user, token: token}
            (+ current-balance amount)
        )
        (ok true)
    )
)

(define-private (transfer-tokens (from principal) (token principal) (to principal) (amount uint))
    (let ((from-balance (default-to u0 (map-get? user-token-balances {user: from, token: token})))
          (to-balance (default-to u0 (map-get? user-token-balances {user: to, token: token}))))
        (if (>= from-balance amount)
            (begin
                (map-set user-token-balances
                    {user: from, token: token}
                    (- from-balance amount)
                )
                (map-set user-token-balances
                    {user: to, token: token}
                    (+ to-balance amount)
                )
                (ok true))
            (err err-insufficient-balance)
        )
    )
)

;; Public functions

;; Add new buy order 
(define-public (add-buy-order 
    (token-in principal)
    (token-out principal)
    (amount-in uint)
    (amount-out uint)
    (price uint))
    (let ((order-id (+ (var-get buy-order-counter) u1))
          (trader tx-sender))
        ;; Lock tokens in contract
        (try! (lock-tokens trader token-in amount-in))
        
        ;; Create order
        (map-set buy-orders
            {order-id: order-id}
            {
                trader: trader,
                token-in: token-in,
                token-out: token-out,
                amount-in: amount-in,
                amount-out: amount-out,
                price: price,
                timestamp: block-height,
                active: true
            }
        )
        
        ;; Update counter
        (var-set buy-order-counter order-id)
        
        ;; Emit event
        (print {event: "buy-order-placed", order-id: order-id, trader: trader, amount: amount-in})
        
        (ok order-id)
    )
)

;; Add new sell order 
(define-public (add-sell-order
    (token-in principal)
    (token-out principal)
    (amount-in uint)
    (amount-out uint)
    (price uint))
    (let ((order-id (+ (var-get sell-order-counter) u1))
          (trader tx-sender))
        ;; Lock tokens in contract
        (try! (lock-tokens trader token-in amount-in))
        
        ;; Create order
        (map-set sell-orders
            {order-id: order-id}
            {
                trader: trader,
                token-in: token-in,
                token-out: token-out,
                amount-in: amount-in,
                amount-out: amount-out,
                price: price,
                timestamp: block-height,
                active: true
            }
        )
        
        ;; Update counter
        (var-set sell-order-counter order-id)
        
        ;; Emit event
        (print {event: "sell-order-placed", order-id: order-id, trader: trader, amount: amount-in})
        
        (ok order-id)
    )
)

;; Fill buy order - FIXED VERSION
(define-public (fill-buy-order (order-id uint) (fill-amount uint))
    (let ((order (unwrap! (map-get? buy-orders {order-id: order-id}) err-not-found))
          (taker tx-sender))
        ;; Verify order is active
        (asserts! (get active order) err-order-filled)
        
        ;; Verify fill amount is valid
        (asserts! (<= fill-amount (get amount-out order)) err-invalid-order)
        
        ;; Calculate amounts with fee
        (let ((fill-ratio (/ (* fill-amount u1000000) (get amount-out order)))
              (tokens-to-pay (/ (* (get amount-in order) fill-ratio) u1000000))
              (fee-amount (/ (* tokens-to-pay trading-fee) u10000)))
        
            ;; Transfer tokens from taker to maker
            (match (transfer-tokens taker (get token-out order) (get trader order) tokens-to-pay)
                success (ok true)
                error (err err-transfer-failed)
            )
            
            ;; Transfer tokens from maker to taker (minus fee)
            (match (transfer-tokens (get trader order) (get token-in order) taker (- tokens-to-pay fee-amount))
                success (ok true)
                error (err err-transfer-failed)
            )
            
            ;; Emit fill event
            (print {event: "order-filled", order-id: order-id, taker: taker, amount: fill-amount})
            
            ;; Update order status if fully filled
            (if (>= fill-amount (get amount-out order))
                (begin
                    (map-set buy-orders {order-id: order-id} (merge order {active: false}))
                    (ok true))
                (begin
                    (map-set buy-orders {order-id: order-id} 
                        (merge order {
                            amount-out: (- (get amount-out order) fill-amount),
                            amount-in: (- (get amount-in order) tokens-to-pay)
                        }))
                    (ok true))
            )
        )
    )
)

;; Fill sell order - FIXED VERSION
(define-public (fill-sell-order (order-id uint) (fill-amount uint))
    (let ((order (unwrap! (map-get? sell-orders {order-id: order-id}) err-not-found))
          (taker tx-sender))
        ;; Verify order is active
        (asserts! (get active order) err-order-filled)
        
        ;; Verify fill amount is valid
        (asserts! (<= fill-amount (get amount-out order)) err-invalid-order)
        
        ;; Calculate amounts with fee
        (let ((fill-ratio (/ (* fill-amount u1000000) (get amount-out order)))
              (tokens-to-pay (/ (* (get amount-in order) fill-ratio) u1000000))
              (fee-amount (/ (* fill-amount trading-fee) u10000)))
        
            ;; Transfer tokens from taker to maker
            (match (transfer-tokens taker (get token-in order) (get trader order) tokens-to-pay)
                success (ok true)
                error (err err-transfer-failed)
            )
            
            ;; Transfer tokens from maker to taker (minus fee)
            (match (transfer-tokens (get trader order) (get token-out order) taker (- fill-amount fee-amount))
                success (ok true)
                error (err err-transfer-failed)
            )
            
            ;; Emit fill event
            (print {event: "order-filled", order-id: order-id, taker: taker, amount: fill-amount})
            
            ;; Update order status if fully filled
            (if (>= fill-amount (get amount-out order))
                (begin
                    (map-set sell-orders {order-id: order-id} (merge order {active: false}))
                    (ok true))
                (begin
                    (map-set sell-orders {order-id: order-id} 
                        (merge order {
                            amount-out: (- (get amount-out order) fill-amount),
                            amount-in: (- (get amount-in order) tokens-to-pay)
                        }))
                    (ok true))
            )
        )
    )
)

;; Cancel order 
(define-public (cancel-order (order-type (string-ascii 4)) (order-id uint))
    (let ((trader tx-sender))
        (if (is-eq order-type "buy")
            (cancel-buy-order order-id trader)
            (if (is-eq order-type "sell")
                (cancel-sell-order order-id trader)
                (err err-invalid-order)
            )
        )
    )
)

(define-private (cancel-buy-order (order-id uint) (trader principal))
    (let ((order (unwrap! (map-get? buy-orders {order-id: order-id}) err-not-found)))
        ;; Verify caller is order creator
        (asserts! (is-eq (get trader order) trader) err-unauthorized)
        
        ;; Return locked tokens
        (try! (unlock-tokens trader (get token-in order) (get amount-in order)))
        
        ;; Deactivate order
        (map-set buy-orders {order-id: order-id} (merge order {active: false}))
        
        ;; Emit event
        (print {event: "order-cancelled", order-id: order-id, trader: trader})
        
        (ok true)
    )
)

(define-private (cancel-sell-order (order-id uint) (trader principal))
    (let ((order (unwrap! (map-get? sell-orders {order-id: order-id}) err-not-found)))
        ;; Verify caller is order creator
        (asserts! (is-eq (get trader order) trader) err-unauthorized)
        
        ;; Return locked tokens
        (try! (unlock-tokens trader (get token-in order) (get amount-in order)))
        
        ;; Deactivate order
        (map-set sell-orders {order-id: order-id} (merge order {active: false}))
        
        ;; Emit event
        (print {event: "order-cancelled", order-id: order-id, trader: trader})
        
        (ok true)
    )
)

;; Read-only functions

;; Get buy order details 
(define-read-only (get-buy-order (order-id uint))
    (map-get? buy-orders {order-id: order-id})
)

;; Get sell order details 
(define-read-only (get-sell-order (order-id uint))
    (map-get? sell-orders {order-id: order-id})
)

;; Get user balance
(define-read-only (get-user-balance (user principal) (token principal))
    (default-to u0 (map-get? user-token-balances {user: user, token: token}))
)