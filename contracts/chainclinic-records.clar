;; chainclinic-records.clar
;; This smart contract manages medical records access control and authorization for ChainClinic,
;; a decentralized application for patient-controlled electronic medical records.
;; It handles patient and provider registration, record creation, access management, and audit logging
;; while enforcing strict privacy controls.

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u1))
(define-constant ERR-USER-ALREADY-REGISTERED (err u2))
(define-constant ERR-USER-NOT-REGISTERED (err u3))
(define-constant ERR-PROVIDER-NOT-REGISTERED (err u4))
(define-constant ERR-PATIENT-NOT-REGISTERED (err u5))
(define-constant ERR-RECORD-NOT-FOUND (err u6))
(define-constant ERR-ACCESS-ALREADY-GRANTED (err u7))
(define-constant ERR-ACCESS-NOT-GRANTED (err u8))
(define-constant ERR-INVALID-RECORD-DATA (err u9))
(define-constant ERR-UNAUTHORIZED-ACCESS (err u10))
(define-constant ERR-INVALID-USER-TYPE (err u11))

;; Data space definitions

;; User types 
(define-constant USER-TYPE-PATIENT u1)
(define-constant USER-TYPE-PROVIDER u2)

;; User profile structure mapping: address -> user details
(define-map users
  { user: principal }
  {
    user-type: uint,  ;; 1 for patient, 2 for provider
    name: (string-ascii 100),
    verified: bool,
    registration-date: uint
  }
)

;; Medical records mapping: record-id -> record details
(define-map medical-records
  { record-id: (string-ascii 32) }
  {
    patient: principal,
    provider: principal,
    record-hash: (string-ascii 64),  ;; IPFS hash or other reference to encrypted data
    description: (string-ascii 100),
    timestamp: uint,
    metadata: (string-ascii 200)
  }
)

;; Access control mapping: patient + provider -> access status
(define-map access-permissions
  { patient: principal, provider: principal }
  {
    granted: bool,
    last-updated: uint
  }
)

;; Patient records index: patient -> list of their record IDs
(define-map patient-records
  { patient: principal }
  { record-ids: (list 100 (string-ascii 32)) }
)

;; Access log for audit trail
(define-map access-logs
  { record-id: (string-ascii 32), timestamp: uint }
  {
    provider: principal,
    access-type: (string-ascii 10),  ;; "read", "write", etc.
    notes: (string-ascii 100)
  }
)

;; Contract owner for administrative functions
(define-data-var contract-owner principal tx-sender)

;; Private functions

;; Check if user is registered
(define-private (is-user-registered (user principal))
  (is-some (map-get? users { user: user }))
)

;; Check if user is a patient
(define-private (is-patient (user principal))
  (let ((user-data (map-get? users { user: user })))
    (and
      (is-some user-data)
      (is-eq (get user-type (unwrap-panic user-data)) USER-TYPE-PATIENT)
    )
  )
)

;; Check if user is a provider
(define-private (is-provider (user principal))
  (let ((user-data (map-get? users { user: user })))
    (and
      (is-some user-data)
      (is-eq (get user-type (unwrap-panic user-data)) USER-TYPE-PROVIDER)
    )
  )
)

;; Check if provider has access to patient's records
(define-private (has-access (patient principal) (provider principal))
  (let ((access-data (map-get? access-permissions { patient: patient, provider: provider })))
    (and
      (is-some access-data)
      (get granted (unwrap-panic access-data))
    )
  )
)

;; Get patient record list or empty list if none exists
(define-private (get-patient-record-list (patient principal))
  (default-to 
    { record-ids: (list) }
    (map-get? patient-records { patient: patient })
  )
)

;; Add record to patient's record list
(define-private (add-to-patient-records (patient principal) (record-id (string-ascii 32)))
  (let ((current-records (get-patient-record-list patient)))
    (map-set patient-records
      { patient: patient }
      { record-ids: (unwrap-panic (as-max-len? 
                      (append (get record-ids current-records) record-id)
                      u100)) }
    )
  )
)

;; Log access to a record
(define-private (log-record-access (record-id (string-ascii 32)) (provider principal) (access-type (string-ascii 10)) (notes (string-ascii 100)))
  (let ((timestamp (unwrap-panic (get-block-info? time (- block-height u1)))))
    (map-set access-logs
      { record-id: record-id, timestamp: timestamp }
      { 
        provider: provider,
        access-type: access-type,
        notes: notes
      }
    )
    true
  )
)

;; Public functions

;; Register a new patient
;; @param name: The name of the patient
;; @returns: Success response with true or error if already registered
(define-public (register-patient (name (string-ascii 100)))
  (let ((user tx-sender)
        (timestamp (unwrap-panic (get-block-info? time (- block-height u1)))))
    (if (is-user-registered user)
      ERR-USER-ALREADY-REGISTERED
      (begin
        (map-set users
          { user: user }
          {
            user-type: USER-TYPE-PATIENT,
            name: name,
            verified: false,
            registration-date: timestamp
          }
        )
        (ok true)
      )
    )
  )
)

;; Register a new healthcare provider
;; @param name: The name of the healthcare provider
;; @returns: Success response with true or error if already registered
(define-public (register-provider (name (string-ascii 100)))
  (let ((user tx-sender)
        (timestamp (unwrap-panic (get-block-info? time (- block-height u1)))))
    (if (is-user-registered user)
      ERR-USER-ALREADY-REGISTERED
      (begin
        (map-set users
          { user: user }
          {
            user-type: USER-TYPE-PROVIDER,
            name: name,
            verified: false,
            registration-date: timestamp
          }
        )
        (ok true)
      )
    )
  )
)

;; Verify a healthcare provider (admin function)
;; @param provider: The principal address of the provider to verify
;; @returns: Success response with true or error if unauthorized or provider not found
(define-public (verify-provider (provider principal))
  (let ((caller tx-sender))
    (if (is-eq caller (var-get contract-owner))
      (match (map-get? users { user: provider })
        user-data (begin
          (if (is-eq (get user-type user-data) USER-TYPE-PROVIDER)
            (begin
              (map-set users
                { user: provider }
                (merge user-data { verified: true })
              )
              (ok true)
            )
            ERR-INVALID-USER-TYPE
          )
        )
        ERR-PROVIDER-NOT-REGISTERED
      )
      ERR-NOT-AUTHORIZED
    )
  )
)

;; Grant access to a healthcare provider
;; @param provider: The principal address of the provider to grant access to
;; @returns: Success response with true or error if not authorized or already granted
(define-public (grant-access (provider principal))
  (let ((patient tx-sender)
        (timestamp (unwrap-panic (get-block-info? time (- block-height u1)))))
    (if (is-patient patient)
      (if (is-provider provider)
        (if (has-access patient provider)
          ERR-ACCESS-ALREADY-GRANTED
          (begin
            (map-set access-permissions
              { patient: patient, provider: provider }
              { granted: true, last-updated: timestamp }
            )
            (ok true)
          )
        )
        ERR-PROVIDER-NOT-REGISTERED
      )
      ERR-PATIENT-NOT-REGISTERED
    )
  )
)

;; Revoke access from a healthcare provider
;; @param provider: The principal address of the provider to revoke access from
;; @returns: Success response with true or error if not authorized or access wasn't granted
(define-public (revoke-access (provider principal))
  (let ((patient tx-sender)
        (timestamp (unwrap-panic (get-block-info? time (- block-height u1)))))
    (if (is-patient patient)
      (if (is-provider provider)
        (if (has-access patient provider)
          (begin
            (map-set access-permissions
              { patient: patient, provider: provider }
              { granted: false, last-updated: timestamp }
            )
            (ok true)
          )
          ERR-ACCESS-NOT-GRANTED
        )
        ERR-PROVIDER-NOT-REGISTERED
      )
      ERR-PATIENT-NOT-REGISTERED
    )
  )
)

;; Add a new medical record
;; @param record-id: Unique identifier for the record
;; @param patient: The principal address of the patient
;; @param record-hash: Hash reference to the encrypted data
;; @param description: Brief description of the record
;; @param metadata: Additional metadata about the record
;; @returns: Success response with true or error if unauthorized
(define-public (add-medical-record
  (record-id (string-ascii 32))
  (patient principal)
  (record-hash (string-ascii 64))
  (description (string-ascii 100))
  (metadata (string-ascii 200))
)
  (let ((provider tx-sender)
        (timestamp (unwrap-panic (get-block-info? time (- block-height u1)))))
    (if (is-provider provider)
      (if (is-patient patient)
        (if (has-access patient provider)
          (begin
            (map-set medical-records
              { record-id: record-id }
              {
                patient: patient,
                provider: provider,
                record-hash: record-hash,
                description: description,
                timestamp: timestamp,
                metadata: metadata
              }
            )
            (add-to-patient-records patient record-id)
            (log-record-access record-id provider "write" "Created new medical record")
            (ok true)
          )
          ERR-UNAUTHORIZED-ACCESS
        )
        ERR-PATIENT-NOT-REGISTERED
      )
      ERR-PROVIDER-NOT-REGISTERED
    )
  )
)

;; Get a medical record (if authorized)
;; @param record-id: ID of the record to retrieve
;; @returns: Record data if authorized, error otherwise
(define-public (get-medical-record (record-id (string-ascii 32)))
  (let ((user tx-sender))
    (match (map-get? medical-records { record-id: record-id })
      record-data (begin
        (if (or 
              (is-eq user (get patient record-data))  ;; patient can access own records
              (and 
                (is-provider user)
                (has-access (get patient record-data) user)  ;; provider with access can view
              )
            )
          (begin
            (if (is-provider user)
              (log-record-access record-id user "read" "Accessed medical record")
              true
            )
            (ok record-data)
          )
          ERR-UNAUTHORIZED-ACCESS
        )
      )
      ERR-RECORD-NOT-FOUND
    )
  )
)

;; Get all record IDs for a patient
;; @returns: List of record IDs belonging to the calling patient
(define-public (get-my-record-ids)
  (let ((patient tx-sender))
    (if (is-patient patient)
      (ok (get record-ids (get-patient-record-list patient)))
      ERR-PATIENT-NOT-REGISTERED
    )
  )
)

;; Get all record IDs for a given patient (provider function)
;; @param patient: The principal address of the patient
;; @returns: List of record IDs for the patient if provider has access
(define-public (get-patient-record-ids (patient principal))
  (let ((provider tx-sender))
    (if (is-provider provider)
      (if (is-patient patient)
        (if (has-access patient provider)
          (ok (get record-ids (get-patient-record-list patient)))
          ERR-UNAUTHORIZED-ACCESS
        )
        ERR-PATIENT-NOT-REGISTERED
      )
      ERR-PROVIDER-NOT-REGISTERED
    )
  )
)

;; Check if a provider has access to a patient's records
;; @param patient: The patient's principal address
;; @param provider: The provider's principal address
;; @returns: Boolean indicating if access is granted
(define-read-only (check-access-status (patient principal) (provider principal))
  (ok (has-access patient provider))
)

;; Get user profile information
;; @param user: Principal address of the user
;; @returns: User profile data or error if not registered
(define-read-only (get-user-info (user principal))
  (match (map-get? users { user: user })
    user-data (ok user-data)
    ERR-USER-NOT-REGISTERED
  )
)

;; Transfer contract ownership (admin function)
;; @param new-owner: Principal address of the new contract owner
;; @returns: Success response with true or error if unauthorized
(define-public (transfer-ownership (new-owner principal))
  (if (is-eq tx-sender (var-get contract-owner))
    (begin
      (var-set contract-owner new-owner)
      (ok true)
    )
    ERR-NOT-AUTHORIZED
  )
)