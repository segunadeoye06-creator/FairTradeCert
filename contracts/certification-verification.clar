;; CertificationVerification.clar
;; Core contract for managing verification of sustainable farming practices submissions
;; in the FairTradeCert system. Handles auditor verifications, multi-auditor voting,
;; appeals, comments, and status tracking with immutable records.

;; Constants
(define-constant ERR_NOT_AUTHORIZED u100)
(define-constant ERR_INVALID_SUBMISSION u101)
(define-constant ERR_ALREADY_VERIFIED u102)
(define-constant ERR_VOTE_THRESHOLD_NOT_MET u103)
(define-constant ERR_APPEAL_WINDOW_CLOSED u104)
(define-constant ERR_INVALID_STATUS u105)
(define-constant ERR_INVALID_AUDITOR u106)
(define-constant ERR_COMMENT_TOO_LONG u107)
(define-constant ERR_NO_ACTIVE_VOTE u108)
(define-constant ERR_APPEAL_ALREADY_RESOLVED u109)
(define-constant ERR_INVALID_APPEAL u110)
(define-constant ERR_METADATA_TOO_LONG u111)
(define-constant ERR_INVALID_TIMESTAMP u112)
(define-constant ERR_PAUSED u113)

(define-constant STATUS_PENDING u0)
(define-constant STATUS_APPROVED u1)
(define-constant STATUS_REJECTED u2)
(define-constant STATUS_APPEALED u3)
(define-constant STATUS_RESOLVED u4)

(define-constant MAX_COMMENT_LEN u500)
(define-constant MAX_METADATA_LEN u1000)
(define-constant DEFAULT_VOTE_THRESHOLD u3) ;; Minimum votes needed for approval/rejection
(define-constant APPEAL_WINDOW_BLOCKS u144) ;; ~1 day in Stacks blocks

;; Data Maps
(define-map submissions
  { submission-id: uint }
  {
    farmer: principal,
    evidence-hash: (buff 32),
    metadata: (string-utf8 1000),
    timestamp: uint,
    status: uint,
    vote-count-approve: uint,
    vote-count-reject: uint,
    required-threshold: uint,
    appeal-timestamp: (optional uint),
    appeal-resolved: bool
  }
)

(define-map auditor-votes
  { submission-id: uint, auditor: principal }
  {
    vote: bool, ;; true for approve, false for reject
    comment: (string-utf8 500),
    timestamp: uint
  }
)

(define-map auditors
  { auditor: principal }
  {
    reputation: uint,
    active: bool,
    total-verifications: uint,
    successful-verifications: uint
  }
)

(define-map appeals
  { submission-id: uint }
  {
    reason: (string-utf8 500),
    additional-evidence: (optional (buff 32)),
    resolver: (optional principal),
    resolution-status: uint,
    resolution-timestamp: (optional uint)
  }
)

;; Variables
(define-data-var contract-owner principal tx-sender)
(define-data-var paused bool false)
(define-data-var global-vote-threshold uint DEFAULT_VOTE_THRESHOLD)

;; Private Functions
(define-private (is-owner (caller principal))
  (is-eq caller (var-get contract-owner))
)

(define-private (is-auditor (caller principal))
  (match (map-get? auditors {auditor: caller})
    entry (get active entry)
    false
  )
)

(define-private (update-reputation (auditor principal) (success bool))
  (match (map-get? auditors {auditor: auditor})
    entry
    (let
      ((new-rep (if success (+ (get reputation entry) u1) (- (get reputation entry) u1)))
       (new-total (+ (get total-verifications entry) u1))
       (new-success (if success (+ (get successful-verifications entry) u1) (get successful-verifications entry))))
      (map-set auditors {auditor: auditor}
        {
          reputation: (if (> new-rep u0) new-rep u0), ;; Prevent underflow
          active: (get active entry),
          total-verifications: new-total,
          successful-verifications: new-success
        }
      )
    )
    false ;; Should not happen
  )
)

(define-private (check-vote-threshold (submission-id uint))
  (match (map-get? submissions {submission-id: submission-id})
    sub
    (let
      ((approve-count (get vote-count-approve sub))
       (reject-count (get vote-count-reject sub))
       (threshold (get required-threshold sub)))
      (if (>= approve-count threshold)
        (begin
          (map-set submissions {submission-id: submission-id}
            (merge sub {status: STATUS_APPROVED})
          )
          (print {event: "submission-approved", submission-id: submission-id})
          true
        )
        (if (>= reject-count threshold)
          (begin
            (map-set submissions {submission-id: submission-id}
              (merge sub {status: STATUS_REJECTED})
            )
            (print {event: "submission-rejected", submission-id: submission-id})
            true
          )
          false
        )
      )
    )
    false
  )
)

;; Public Functions
(define-public (submit-evidence (submission-id uint) (evidence-hash (buff 32)) (metadata (string-utf8 1000)) (threshold uint))
  (let
    ((caller tx-sender))
    (if (var-get paused) (err ERR_PAUSED)
      (if (> (len metadata) MAX_METADATA_LEN) (err ERR_METADATA_TOO_LONG)
        (begin
          (map-set submissions {submission-id: submission-id}
            {
              farmer: caller,
              evidence-hash: evidence-hash,
              metadata: metadata,
              timestamp: block-height,
              status: STATUS_PENDING,
              vote-count-approve: u0,
              vote-count-reject: u0,
              required-threshold: (if (is-eq threshold u0) (var-get global-vote-threshold) threshold),
              appeal-timestamp: none,
              appeal-resolved: false
            }
          )
          (print {event: "evidence-submitted", submission-id: submission-id, farmer: caller})
          (ok true)
        )
      )
    )
  )
)

(define-public (verify-submission (submission-id uint) (vote bool) (comment (string-utf8 500)))
  (let
    ((caller tx-sender))
    (if (var-get paused) (err ERR_PAUSED)
      (if (not (is-auditor caller)) (err ERR_INVALID_AUDITOR)
        (if (> (len comment) MAX_COMMENT_LEN) (err ERR_COMMENT_TOO_LONG)
          (match (map-get? submissions {submission-id: submission-id})
            sub
            (if (not (is-eq (get status sub) STATUS_PENDING)) (err ERR_ALREADY_VERIFIED)
              (match (map-get? auditor-votes {submission-id: submission-id, auditor: caller})
                existing-vote (err ERR_ALREADY_VERIFIED)
                (begin
                  (map-set auditor-votes {submission-id: submission-id, auditor: caller}
                    {
                      vote: vote,
                      comment: comment,
                      timestamp: block-height
                    }
                  )
                  (let
                    ((new-approve (if vote (+ (get vote-count-approve sub) u1) (get vote-count-approve sub)))
                     (new-reject (if vote (get vote-count-reject sub) (+ (get vote-count-reject sub) u1))))
                    (map-set submissions {submission-id: submission-id}
                      (merge sub {vote-count-approve: new-approve, vote-count-reject: new-reject})
                    )
                    (update-reputation caller true) ;; Assume success for voting
                    (print {event: "vote-cast", submission-id: submission-id, auditor: caller, vote: vote})
                    (if (check-vote-threshold submission-id)
                      (ok true)
                      (ok false) ;; Voting continues
                    )
                  )
                )
              )
            )
            (err ERR_INVALID_SUBMISSION)
          )
        )
      )
    )
  )
)

(define-public (appeal-submission (submission-id uint) (reason (string-utf8 500)) (additional-evidence (optional (buff 32))))
  (let
    ((caller tx-sender))
    (if (var-get paused) (err ERR_PAUSED)
      (if (> (len reason) MAX_COMMENT_LEN) (err ERR_COMMENT_TOO_LONG)
        (match (map-get? submissions {submission-id: submission-id})
          sub
          (if (not (is-eq (get farmer sub) caller)) (err ERR_NOT_AUTHORIZED)
            (if (not (or (is-eq (get status sub) STATUS_REJECTED) (is-eq (get status sub) STATUS_APPROVED))) (err ERR_INVALID_STATUS)
              (let
                ((current-block block-height)
                 (verification-time (get timestamp sub)))
                (if (> (- current-block verification-time) APPEAL_WINDOW_BLOCKS) (err ERR_APPEAL_WINDOW_CLOSED)
                  (if (get appeal-resolved sub) (err ERR_APPEAL_ALREADY_RESOLVED)
                    (begin
                      (map-set submissions {submission-id: submission-id}
                        (merge sub {
                          status: STATUS_APPEALED,
                          appeal-timestamp: (some current-block),
                          appeal-resolved: false
                        })
                      )
                      (map-set appeals {submission-id: submission-id}
                        {
                          reason: reason,
                          additional-evidence: additional-evidence,
                          resolver: none,
                          resolution-status: STATUS_PENDING,
                          resolution-timestamp: none
                        }
                      )
                      (print {event: "appeal-filed", submission-id: submission-id, farmer: caller})
                      (ok true)
                    )
                  )
                )
              )
            )
          )
          (err ERR_INVALID_SUBMISSION)
        )
      )
    )
  )
)

(define-public (resolve-appeal (submission-id uint) (resolution bool) (comment (string-utf8 500)))
  (let
    ((caller tx-sender))
    (if (var-get paused) (err ERR_PAUSED)
      (if (not (is-auditor caller)) (err ERR_INVALID_AUDITOR)
        (if (> (len comment) MAX_COMMENT_LEN) (err ERR_COMMENT_TOO_LONG)
          (match (map-get? submissions {submission-id: submission-id})
            sub
            (if (not (is-eq (get status sub) STATUS_APPEALED)) (err ERR_INVALID_APPEAL)
              (match (map-get? appeals {submission-id: submission-id})
                appeal
                (if (is-some (get resolver appeal)) (err ERR_APPEAL_ALREADY_RESOLVED)
                  (begin
                    (let
                      ((new-status (if resolution STATUS_APPROVED STATUS_REJECTED)))
                      (map-set submissions {submission-id: submission-id}
                        (merge sub {
                          status: new-status,
                          appeal-resolved: true
                        })
                      )
                      (map-set appeals {submission-id: submission-id}
                        (merge appeal {
                          resolver: (some caller),
                          resolution-status: (if resolution STATUS_APPROVED STATUS_REJECTED),
                          resolution-timestamp: (some block-height)
                        })
                      )
                      (update-reputation caller true)
                      (print {event: "appeal-resolved", submission-id: submission-id, resolver: caller, resolution: resolution})
                      (ok true)
                    )
                  )
                )
                (err ERR_INVALID_APPEAL)
              )
            )
            (err ERR_INVALID_SUBMISSION)
          )
        )
      )
    )
  )
)

(define-public (add-auditor (new-auditor principal))
  (if (is-owner tx-sender)
    (begin
      (map-set auditors {auditor: new-auditor}
        {
          reputation: u100, ;; Starting reputation
          active: true,
          total-verifications: u0,
          successful-verifications: u0
        }
      )
      (print {event: "auditor-added", auditor: new-auditor})
      (ok true)
    )
    (err ERR_NOT_AUTHORIZED)
  )
)

(define-public (remove-auditor (auditor principal))
  (if (is-owner tx-sender)
    (match (map-get? auditors {auditor: auditor})
      entry
      (begin
        (map-set auditors {auditor: auditor}
          (merge entry {active: false})
        )
        (print {event: "auditor-removed", auditor: auditor})
        (ok true)
      )
      (err ERR_INVALID_AUDITOR)
    )
    (err ERR_NOT_AUTHORIZED)
  )
)

(define-public (pause-contract)
  (if (is-owner tx-sender)
    (begin
      (var-set paused true)
      (print {event: "contract-paused"})
      (ok true)
    )
    (err ERR_NOT_AUTHORIZED)
  )
)

(define-public (unpause-contract)
  (if (is-owner tx-sender)
    (begin
      (var-set paused false)
      (print {event: "contract-unpaused"})
      (ok true)
    )
    (err ERR_NOT_AUTHORIZED)
  )
)

(define-public (set-global-threshold (new-threshold uint))
  (if (is-owner tx-sender)
    (begin
      (var-set global-vote-threshold new-threshold)
      (print {event: "threshold-updated", new-threshold: new-threshold})
      (ok true)
    )
    (err ERR_NOT_AUTHORIZED)
  )
)

;; Read-Only Functions
(define-read-only (get-submission-details (submission-id uint))
  (map-get? submissions {submission-id: submission-id})
)

(define-read-only (get-verification-status (submission-id uint))
  (match (map-get? submissions {submission-id: submission-id})
    sub (ok (get status sub))
    (err ERR_INVALID_SUBMISSION)
  )
)

(define-read-only (get-auditor-vote (submission-id uint) (auditor principal))
  (map-get? auditor-votes {submission-id: submission-id, auditor: auditor})
)

(define-read-only (get-auditor-details (auditor principal))
  (map-get? auditors {auditor: auditor})
)

(define-read-only (get-appeal-details (submission-id uint))
  (map-get? appeals {submission-id: submission-id})
)

(define-read-only (is-contract-paused)
  (var-get paused)
)

(define-read-only (get-global-threshold)
  (var-get global-vote-threshold)
)