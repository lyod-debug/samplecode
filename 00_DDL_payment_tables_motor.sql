/* =====================================================================================
   00_DDL_payment_tables_motor.sql
   Database : IntermediateStaging_DEV
   Purpose  : Working tables + target IS tables for the MOTOR payments / recoveries load.
              The senior's reserve procs TRUNCATE IS_TRANSACTION_MOTOR, IS_TRANSACTIONSET_MOTOR,
              IS_TRANSACTIONLINEITEM_MOTOR on every run, so payments get their OWN tables (*_PAY_*).
   Safe to re-run: every table is created only if it does not exist yet.
   Types for GW_HDR_CASEID / ClaimID / PublicID follow the exposure and reserve line procs.
   ===================================================================================== */
USE [IntermediateStaging_DEV]
GO

/* ------------------------------------------------------------------------------------
   W1. One row per ClaimCenter transaction (= one V2 transaction, or one part of it when
       the V2 transaction has to be split by exposure / cost type).
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_PAYMENT_UNIT_MOTOR') IS NULL
CREATE TABLE dbo.IS_PAYMENT_UNIT_MOTOR
(
    TranID                   BIGINT          NOT NULL,   /* VEC_GW_PAY_TRANS.ID                      */
    UnitSuffix               VARCHAR(10)     NOT NULL,   /* '' when the V2 transaction is not split  */
    GW_HDR_CASEID            BIGINT          NULL,
    CLAIM_REF                VARCHAR(50)     NULL,
    ClaimPublicID            VARCHAR(64)     NULL,
    CaseID                   BIGINT          NULL,       /* VEC_GW_PAY_TRANS.CASEID                  */
    CaseType                 VARCHAR(10)     NULL,       /* HDR / AD / TP / PA / UNKNOWN             */
    CASE_STATUS              VARCHAR(50)     NULL,       /* live status of CaseID (information only) */
    VectusCaseID_Adm         VARCHAR(64)     NULL,       /* case the reserve line sits on            */
    SourceOrigin_Adm         VARCHAR(50)     NULL,       /* HDR / AD / PA / TP_VEH / TP_PRO / TP_INJ / TP_HIRE */
    DebitCredit              CHAR(1)         NULL,
    Subtype                  VARCHAR(20)     NULL,       /* Payment / Recovery                       */
    CostType                 VARCHAR(20)     NULL,       /* claimcost / aoexpense                    */
    CostCategory             VARCHAR(100)    NULL,       /* AS IS from the chosen reserve line       */
    IsHire                   BIT             NULL,
    ExposureID               VARCHAR(64)     NULL,       /* NULL on claim-level (HDR) lines          */
    ReserveLineID            VARCHAR(128)    NULL,
    RecoveryCodingID         VARCHAR(128)    NULL,
    PayType                  VARCHAR(10)     NULL,
    IsTransfer               BIT             NULL,
    CurrentStatusType        VARCHAR(30)     NULL,       /* VEC_GW_PAY_STATUS.STATUS_TYPE, GCURRENT='X' */
    Status                   VARCHAR(50)     NULL,       /* cc_transaction.Status (typelist)         */
    LifeCycleState           VARCHAR(50)     NULL,
    ApprovalStatus           VARCHAR(50)     NULL,
    CreateTime               DATETIME2(7)    NULL,
    ApprovalDate             DATETIME2(7)    NULL,
    PresentedDate            DATETIME2(7)    NULL,
    PaidDate                 DATETIME2(7)    NULL,
    CanxDate                 DATETIME2(7)    NULL,
    ChequeStopReason         VARCHAR(100)    NULL,
    CashMoveNo               BIGINT          NULL,       /* CASH_MOVE_NO converted; CC field is a long integer */
    ChequeNumber             VARCHAR(50)     NULL,
    PayeeName                VARCHAR(200)    NULL,
    AccountNumber            VARCHAR(50)     NULL,
    SortCode                 VARCHAR(20)     NULL,
    Grouped                  VARCHAR(5)      NULL,
    PostCode                 VARCHAR(30)     NULL,
    AddressLine1             VARCHAR(200)    NULL,
    AddressLine2             VARCHAR(200)    NULL,
    AddressLine3             VARCHAR(200)    NULL,
    PayeeLinkID              BIGINT          NULL,
    AddLinkID                BIGINT          NULL,
    PayeeContactID           VARCHAR(64)     NULL,       /* contact PublicID                         */
    PayeeClaimContactID      VARCHAR(128)    NULL,       /* claim contact PublicID (real or dummy)   */
    InCareOfContactID        VARCHAR(64)     NULL,
    IsDummyPayee             BIT             NULL,
    GatewayRef               VARCHAR(50)     NULL,
    PaymentMethod            VARCHAR(50)     NULL,
    HdrAmount                DECIMAL(18,2)   NULL,       /* VEC_GW_PAY_TRANS.AMOUNT                  */
    DissSum                  DECIMAL(18,2)   NULL,       /* sum of all dissections of the V2 tran    */
    UnitAmount               DECIMAL(18,2)   NULL,       /* sum of the dissections in this unit      */
    UnitCountInTran          INT             NULL,
    ExceptionCode            VARCHAR(40)     NULL,       /* NULL = loadable                          */
    WarnList                 VARCHAR(500)    NULL,       /* ';' separated, never blocks the load     */
    Loadable                 BIT             NOT NULL DEFAULT (0),
    CONSTRAINT PK_IS_PAYMENT_UNIT_MOTOR PRIMARY KEY CLUSTERED (TranID, UnitSuffix)
);
GO

/* ------------------------------------------------------------------------------------
   W2. One row per dissection (= one transaction line item)
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_PAYMENT_LINE_MOTOR') IS NULL
CREATE TABLE dbo.IS_PAYMENT_LINE_MOTOR
(
    TranID        BIGINT         NOT NULL,
    UnitSuffix    VARCHAR(10)    NOT NULL,
    LineSeq       INT            NOT NULL,
    DissCode      VARCHAR(20)    NULL,        /* NULL when the transaction has no dissection row */
    Amount        DECIMAL(18,2)  NULL,
    LineItem      VARCHAR(50)    NULL,        /* Migrated Payment / Migrated Recovery            */
    CONSTRAINT PK_IS_PAYMENT_LINE_MOTOR PRIMARY KEY CLUSTERED (TranID, UnitSuffix, LineSeq)
);
GO

/* ------------------------------------------------------------------------------------
   T1. Target : transaction (Payment / Recovery)
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_TRANSACTION_PAY_MOTOR') IS NULL
CREATE TABLE dbo.IS_TRANSACTION_PAY_MOTOR
(
    GW_HDR_CASEID                   BIGINT         NULL,
    CLAIM_REF                       VARCHAR(50)    NULL,
    VectusCaseID_Adm                VARCHAR(64)    NULL,
    SourceOrigin_Adm                VARCHAR(50)    NULL,
    CASE_STATUS                     VARCHAR(50)    NULL,
    PublicID                        VARCHAR(128)   NOT NULL,
    LUWID                           VARCHAR(50)    NULL,
    BookingDate                     DATETIME2(7)   NULL,
    CreateTime                      DATETIME2(7)   NULL,
    ClaimID                         VARCHAR(64)    NULL,
    CostCategory                    VARCHAR(100)   NULL,
    CostType                        VARCHAR(20)    NULL,
    Currency                        VARCHAR(10)    NULL,
    ExposureID                      VARCHAR(64)    NULL,
    LifeCycleState                  VARCHAR(50)    NULL,
    RecoveryCategory                VARCHAR(50)    NULL,
    RecoveryCodingID                VARCHAR(128)   NULL,
    ReserveLineID                   VARCHAR(128)   NULL,
    ReservingCurrency               VARCHAR(10)    NULL,
    Status                          VARCHAR(50)    NULL,
    Subtype                         VARCHAR(20)    NULL,
    TransactionSetID                VARCHAR(128)   NULL,
    PaymentType                     VARCHAR(20)    NULL,
    DoesNotErodeReserves            BIT            NULL,
    CloseExposure                   BIT            NULL,
    CloseClaim                      BIT            NULL,
    CheckID                         VARCHAR(128)   NULL,
    DenormCashMoveNo_Adm            BIGINT         NULL,       /* CC longint */
    ChequeNumber_Adm                VARCHAR(50)    NULL,
    InternalCCPayRecoCurrency_Adm   VARCHAR(10)    NULL,
    InternalCCPayRecoCat_Adm        VARCHAR(50)    NULL
);
GO

/* ------------------------------------------------------------------------------------
   T2. Target : transaction line item
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR') IS NULL
CREATE TABLE dbo.IS_TRANSACTIONLINEITEM_PAY_MOTOR
(
    GW_HDR_CASEID           BIGINT         NULL,
    CLAIM_REF               VARCHAR(50)    NULL,
    VectusCaseID_Adm        VARCHAR(64)    NULL,
    SourceOrigin_Adm        VARCHAR(50)    NULL,
    CASE_STATUS             VARCHAR(50)    NULL,
    PublicID                VARCHAR(128)   NOT NULL,
    LUWID                   VARCHAR(50)    NULL,
    CreateTime              DATETIME2(7)   NULL,
    TransactionAmount       DECIMAL(18,2)  NULL,
    ReservingForExAmount    DECIMAL(18,2)  NULL,
    ReportingForExAmount    DECIMAL(18,2)  NULL,
    ReportingAmount         DECIMAL(18,2)  NULL,
    ClaimForExAmount        DECIMAL(18,2)  NULL,
    ClaimAmount             DECIMAL(18,2)  NULL,
    ReservingAmount         DECIMAL(18,2)  NULL,
    LineCategory            VARCHAR(50)    NULL,
    TransactionID           VARCHAR(128)   NULL
);
GO

/* ------------------------------------------------------------------------------------
   T3. Target : transaction set (one per ClaimCenter transaction; CheckSet or RecoverySet)
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_TRANSACTIONSET_PAY_MOTOR') IS NULL
CREATE TABLE dbo.IS_TRANSACTIONSET_PAY_MOTOR
(
    GW_HDR_CASEID      BIGINT         NULL,
    CLAIM_REF          VARCHAR(50)    NULL,
    VectusCaseID_Adm   VARCHAR(64)    NULL,
    SourceOrigin_Adm   VARCHAR(50)    NULL,
    CASE_STATUS        VARCHAR(50)    NULL,
    PublicID           VARCHAR(128)   NOT NULL,
    LUWID              VARCHAR(50)    NULL,
    ApprovalDate       DATETIME2(7)   NULL,
    ApprovalStatus     VARCHAR(50)    NULL,
    ClaimID            VARCHAR(64)    NULL,
    CreatedVia         VARCHAR(20)    NULL,
    CreateTime         DATETIME2(7)   NULL,
    RequestingUserID   VARCHAR(64)    NULL,
    Subtype            VARCHAR(30)    NULL,
    CashMoveNo_Adm     BIGINT         NULL        /* CC longint */
);
GO

/* ------------------------------------------------------------------------------------
   T4. Target : check (payments only)
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_CHECK_MOTOR') IS NULL
CREATE TABLE dbo.IS_CHECK_MOTOR
(
    GW_HDR_CASEID                   BIGINT         NULL,
    CLAIM_REF                       VARCHAR(50)    NULL,
    VectusCaseID_Adm                VARCHAR(64)    NULL,
    SourceOrigin_Adm                VARCHAR(50)    NULL,
    CASE_STATUS                     VARCHAR(50)    NULL,
    PublicID                        VARCHAR(128)   NOT NULL,
    LUWID                           VARCHAR(50)    NULL,
    AccountName                     VARCHAR(200)   NULL,
    BankAccountNumber               VARCHAR(50)    NULL,
    BankSortCodeStr_Adm             VARCHAR(20)    NULL,
    CheckBatching                   VARCHAR(30)    NULL,
    CheckNumber                     VARCHAR(50)    NULL,
    CheckSetID                      VARCHAR(128)   NULL,
    CheckType                       VARCHAR(20)    NULL,
    ChequeNumber_Adm                VARCHAR(50)    NULL,
    ChequePresentedDate_Adm         DATETIME2(7)   NULL,
    ChequeStopReason_Adm            VARCHAR(100)   NULL,
    ClaimContactID                  VARCHAR(128)   NULL,
    ClaimID                         VARCHAR(64)    NULL,
    CreateTime                      DATETIME2(7)   NULL,
    DenormCashMoveNo_Adm            BIGINT         NULL,       /* CC longint */
    DenormPostalCode_Adm            VARCHAR(30)    NULL,
    EnteredTime                     DATETIME2(7)   NULL,
    InCareOf_Adm                    VARCHAR(64)    NULL,
    InternalCCPayClaimNumber_Adm    VARCHAR(50)    NULL,
    IssueDate                       DATETIME2(7)   NULL,
    MailingAddressID                VARCHAR(128)   NULL,
    MailTo                          VARCHAR(500)   NULL,
    PaymentMethod                   VARCHAR(50)    NULL,
    PayTo                           VARCHAR(200)   NULL,
    PayToDenorm                     VARCHAR(200)   NULL,
    Status                          VARCHAR(50)    NULL
);
GO

/* ------------------------------------------------------------------------------------
   T5. Target : check payee (exactly one per check)
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_CHECKPAYEE_MOTOR') IS NULL
CREATE TABLE dbo.IS_CHECKPAYEE_MOTOR
(
    GW_HDR_CASEID      BIGINT         NULL,
    CLAIM_REF          VARCHAR(50)    NULL,
    VectusCaseID_Adm   VARCHAR(64)    NULL,
    SourceOrigin_Adm   VARCHAR(50)    NULL,
    CASE_STATUS        VARCHAR(50)    NULL,
    PublicID           VARCHAR(128)   NOT NULL,
    LUWID              VARCHAR(50)    NULL,
    CheckID            VARCHAR(128)   NULL,
    ClaimContactID     VARCHAR(128)   NULL,
    PayeeType          VARCHAR(50)    NULL,     /* type key of ContactRole = 'checkpayee' (mapping DB type: Type Key of type ContactRole, not nullable) */
    IsDummyPayee       BIT            NULL
);
GO

/* ------------------------------------------------------------------------------------
   R1. Exception / warning report (rebuilt by usp_Load_SS_to_IS_PAYMENT_EXCEPTION_MOTOR)
   ------------------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.IS_PAYMENT_EXCEPTION_MOTOR') IS NULL
CREATE TABLE dbo.IS_PAYMENT_EXCEPTION_MOTOR
(
    TranID           BIGINT         NOT NULL,
    UnitSuffix       VARCHAR(10)    NOT NULL,
    GW_HDR_CASEID    BIGINT         NULL,
    CLAIM_REF        VARCHAR(50)    NULL,
    CaseID           BIGINT         NULL,
    CaseType         VARCHAR(10)    NULL,
    DebitCredit      CHAR(1)        NULL,
    CostType         VARCHAR(20)    NULL,
    UnitAmount       DECIMAL(18,2)  NULL,
    Severity         VARCHAR(10)    NOT NULL,    /* ERROR = not loaded, WARN = loaded but check */
    ExceptionCode    VARCHAR(40)    NOT NULL
);
GO
