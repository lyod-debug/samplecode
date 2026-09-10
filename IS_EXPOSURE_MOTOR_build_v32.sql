/* =====================================================================
   IS_EXPOSURE_MOTOR — v32
   Checked the top of the file per your request: ran a full comment-
   balance scan (every /* matched with a */) - confirmed nothing was
   accidentally swallowed into a comment block. Trimmed the version
   history below to a short summary instead of the full v29-v31 text,
   since it had grown to 55 lines of pure changelog.

   ClaimantType: the fuzzy fallback (CLAIMANT_TYPE_LOOKUP CTE, its
   ORDER BY tiebreak, and the ISNULL(...,ISNULL(CTL...)) wrapper) is
   REMOVED ENTIRELY per your instruction, in both Block B and Block C.
   ClaimantType now does a plain exact match against
   TYPELIST_TABLE_MAPPING, same pattern as ExposureState/
   LiabilityPosition_Adm. This ONLY works correctly once the crammed
   source rows are actually split - see the new ClaimantType section in
   TYPELIST_crammed_row_fix.sql. Until that split is run in your real
   database, ClaimantType will resolve to 'other' for most 3rd-party
   exposures, since the crammed cells won't exact-match anything. Run
   the split FIRST, then this proc.

   Prior version history (v20-v31): AD dedup positive-selection logic;
   removed Vandal/Thief suppression (deferred) and the exception table;
   no UPDATE statements except ClaimOrder (structurally required, sees
   across all 4 blocks); BI/CIL fixes confirmed against your real
   mapping queries (LEFT JOIN RES_ADJUST, case-level CIL grouping);
   IncidentID rebuilt from source tables for TP_INJ/TP_PRO/PA (AD/TP_VEH/
   Hire still on IS_INCIDENT, pending fresh text); Coverage still on
   IS_COVERAGE per your instruction; ClaimOrder is genuinely random
   (NEWID(), per mapping: "no specific priority order to be applied").
   ===================================================================== */

USE [IntermediateStaging_DEV]
GO

/* =====================================================================
   0. LOOKUP TABLES
   ===================================================================== */
IF OBJECT_ID('dbo.LKP_EXPOSURE_MOTOR_RULES', 'U') IS NOT NULL DROP TABLE dbo.LKP_EXPOSURE_MOTOR_RULES;
CREATE TABLE dbo.LKP_EXPOSURE_MOTOR_RULES (
    V2CaseFlow          VARCHAR(50)  NOT NULL,
    RuleKey             VARCHAR(50)  NOT NULL PRIMARY KEY,
    LossType            VARCHAR(20),
    PolicyType          VARCHAR(50),
    PrimaryCoverage     VARCHAR(100),
    CoverageSubType     VARCHAR(100),
    IncidentType        VARCHAR(50),
    IncidentCode        VARCHAR(50),
    LossParty           VARCHAR(20),
    ExposureType        VARCHAR(50)
);
INSERT INTO dbo.LKP_EXPOSURE_MOTOR_RULES VALUES
('GW MOTOR AD','AD_STD',   'Motor','Personal Motor','PMAccidentalDamage_Inc','PMAccidentalDamage_VehicleDamageInc','VehicleIncident','VehicleDamage','insured','VehicleDamage'),
('GW MOTOR AD','AD_VAN',   'Motor','Personal Motor','PMAccidentalDamage_Inc','PMAccidentalDamage_VehicleDamageInc','VehicleIncident','VehicleDamage','insured','VehicleDamage'),
('GW MOTOR AD','AD_THEFT', 'Motor','Personal Motor','PMFireAndTheft_Inc','PMFireAndTheft_VehicleDamageInc','VehicleIncident','VehicleDamage','insured','VehicleDamage'),
('GW MOTOR AD','AD_VAN_THEFT','Motor','Personal Motor','PMFireAndTheft_Inc','PMFireAndTheft_VehicleDamageInc','VehicleIncident','VehicleDamage','insured','VehicleDamage'),
('GW MOTOR TP','TP_VEH',   'Motor','Personal Motor','PMLiability_Inc','PMLiability_TPVehicleDamageInc','VehicleIncident','VehicleDamage','third-party','VehicleDamage'),
('GW MOTOR TP','TP_INJ',   'Motor','Personal Motor','PMLiability_Inc','PMLiabilityInjuredParty_BIInc','InjuryIncident','BodilyInjuryDamage','third-party','BodilyInjuryDamage'),
('GW MOTOR TP','TP_PRO',   'Motor','Personal Motor','PMLiability_Inc','PMLiability_TPPropertyDamageInc','FixedPropertyIncident','PropertyDamage','third-party','PropertyDamage'),
('GW MOTOR TP','TP_HIRE',  'Motor','Personal Motor','PMLiability_Inc','PMLiability_TPHireMobilityVehicleDmgInc','VehicleIncident','VehicleDamage','third-party','VehicleDamage'),
('GW PI ANCILLARY','PA_STD',   'Motor','Personal Motor','PMPersonalInjuryAncCov','PMPersonalInjury_AncBIInc','InjuryIncident','BodilyInjuryDamage','insured','BodilyInjuryDamage'),
('GW PI ANCILLARY','PA_PLUS',  'Motor','Personal Motor','PMPersonalInjuryPlusAncCov','PMPersonalInjuryPlus_AncBIInc','InjuryIncident','BodilyInjuryDamage','insured','BodilyInjuryDamage');


/* =====================================================================
   1. CREATE TABLE
   ===================================================================== */
IF OBJECT_ID('dbo.IS_EXPOSURE_MOTOR', 'U') IS NOT NULL DROP TABLE dbo.IS_EXPOSURE_MOTOR;
CREATE TABLE dbo.IS_EXPOSURE_MOTOR (
    PublicID                    VARCHAR(100) NOT NULL PRIMARY KEY,
    ClaimID                     VARCHAR(64)  NOT NULL,
    VectusCaseID_Adm            VARCHAR(64)  NULL,
    GW_HDR_CASEID                BIGINT       NULL,
    SourceOrigin_Adm            VARCHAR(20)  NULL,

    ExposureType                VARCHAR(100) NOT NULL,
    PrimaryCoverage             VARCHAR(100) NOT NULL,
    CoverageSubType             VARCHAR(100) NULL,
    LossParty                   VARCHAR(20)  NULL,
    ClaimOrder                  INT          NOT NULL,

    CoverageID                  VARCHAR(100) NULL,
    IncidentID                  VARCHAR(100) NULL,
    ClaimantDenormID            VARCHAR(100) NULL,
    ClaimantType                VARCHAR(100) NULL,

    AssignmentStatus            VARCHAR(50)  NOT NULL DEFAULT 'unassigned',
    BIReservePercentage_Adm     DECIMAL(5,2) NOT NULL DEFAULT 100,
    RIGroupSetExternally        BIT          NOT NULL DEFAULT 0,
    State                       VARCHAR(50)  NOT NULL DEFAULT 'draft',
    SupplementalWorkloadWeight  INT          NOT NULL DEFAULT 0,
    WorkloadWeight              INT          NOT NULL DEFAULT 0,
    CreatedVia                  VARCHAR(50)  NULL DEFAULT 'manual',
    Strategy                    VARCHAR(50)  NULL DEFAULT 'unknown',
    ValidationLevel             VARCHAR(50)  NULL DEFAULT 'newloss',

    BIClaimLife_Adm              INT          NULL,
    BIYearsToIssue_Adm           INT          NULL,
    LiabilityPosition_Adm        VARCHAR(100) NULL,

    CILFigure_Adm                DECIMAL(18,2) NULL,
    CILNotes_Adm                 VARCHAR(50)   NULL,

    CreateTime                   DATETIME2(7)  NOT NULL,
    CloseDate                    DATETIME2(7)  NULL,

    AssignedUserID               VARCHAR(100) NULL,
    AssignedGroupID              VARCHAR(100) NULL,

    CLAIM_REF                    VARCHAR(50)  NULL
);
GO


/* =====================================================================
   2. STORED PROC
   ===================================================================== */
CREATE OR ALTER PROCEDURE [dbo].[usp_Load_IS_EXPOSURE_MOTOR]
AS
BEGIN

TRUNCATE TABLE IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR;

/* ================================================================
   BLOCK A: 1st Party AD Vehicle Exposures
   ================================================================ */

-- EDGE CASE: duplicate AD cases (CMP-2777). Positive selection, not
-- negative exclusion: an AD ID with no dupe-table entry at all proceeds
-- normally; a flagged AD ID only proceeds if a CLEAN, real-claim
-- "Migrate" decision exists for it - this wins over any conflicting
-- Descope/junk label also attached to the same ID. IDs where only
-- "Migrate-group" exists are still excluded - BA per-claim decision
-- pending. See chat for the exact rule walked through step by step.
;WITH AD_ELIGIBLE AS (
    SELECT AD.ID, AD.GW_HDR_CASEID
    FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD
    WHERE NOT EXISTS (
        SELECT 1 FROM SourceStaging.dbo.LKP_Dupe_MotorAD DUPE
        WHERE DUPE.GW_MOTOR_AD_ID = AD.ID
    )
    OR EXISTS (
        SELECT 1 FROM SourceStaging.dbo.LKP_Dupe_MotorAD DUPE
        WHERE DUPE.GW_MOTOR_AD_ID = AD.ID
          AND DUPE.CLAIM_REF IS NOT NULL
          AND DUPE.Solution LIKE 'Migrate%'
          AND DUPE.Solution NOT LIKE 'Migrate-group%'
    )
),
-- TRANSFORMATION: classify each AD case into one of 4 RuleKeys based on
-- van flag and fire/theft circumstance (GW_CIRCS_TYPID=5, confirmed =
-- TYPCODE 'FIRETHEFT'). Van vs non-van is cosmetic - both resolve to
-- identical output columns via LKP_EXPOSURE_MOTOR_RULES.
-- EDGE CASE: TPO/TPFT cover-type exclusion. No filter on CLM.INCIDENT_CODE
-- anywhere here - this is what correctly lets a real AD record on a
-- claim labeled 'PA ANCILLARY' still get its exposure, with no special
-- code needed for that specific interaction.
AD_CANDIDATES AS (
    SELECT
        CLM.CLAIM_REF, CLM.PUBLICID AS ClaimPublicID, CLM.GW_HDR_CASEID, AD.ID AS AD_ID,
        CASE
            WHEN RSK.COVERABLE_TYPE = 'PMVan' AND CIRC.GW_CIRCS_TYPID = 5 THEN 'AD_VAN_THEFT'
            WHEN RSK.COVERABLE_TYPE = 'PMVan' THEN 'AD_VAN'
            WHEN CIRC.GW_CIRCS_TYPID = 5 THEN 'AD_THEFT'
            ELSE 'AD_STD'
        END AS RuleKey
    FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
    INNER JOIN AD_ELIGIBLE AD ON AD.GW_HDR_CASEID = CLM.GW_HDR_CASEID
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_VEHICLE VEH ON VEH.CASEID = AD.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CIRCS_INC CIRC
        ON CIRC.GW_HDR_CASEID = CLM.GW_HDR_CASEID AND CIRC.GCURRENT = 'X'
    INNER JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR ON SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID
    INNER JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
    WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
      AND NOT (RSK.COVER_TYPE = 'tpo')
      AND NOT (RSK.COVER_TYPE = 'tpft' AND COALESCE(CIRC.GW_CIRCS_TYPID, 0) <> 5)
),
-- FIXED per your instruction: no priority between coverage and inclusion
-- origins - both equally valid, whichever has the value for this claim+type.
COVERAGE_LOOKUP AS (
    SELECT ClaimPublicID, Type, PublicID
    FROM IntermediateStaging_DEV.dbo.IS_COVERAGE
    WHERE Subtype = 'VehicleCoverage'
),
-- CONFIRMED against your real mapping query. Grouped by the SPECIFIC
-- CASE (VEC_GW_PAY_TRANS.CASEID), not the whole claim - a claim's AD
-- case and TP case must never have their CIL totals mixed together.
-- Routes through IS_CLAIM_MASTER first for MOTOR-only performance.
CIL_TOTALS AS (
    SELECT PT.CASEID AS VectusCaseID, SUM(PD.AMOUNT) AS TotalCIL
    FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM_CIL
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM_CIL.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS PD ON PD.GW_PAY_TRAN_ID = PT.ID
    WHERE UPPER(LTRIM(RTRIM(CLM_CIL.PRODUCT))) = 'MOTOR' AND PD.CODE IN ('CIL','CIP')
    GROUP BY PT.CASEID
)
INSERT INTO IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
(PublicID, ClaimID, VectusCaseID_Adm, GW_HDR_CASEID, SourceOrigin_Adm, ExposureType, PrimaryCoverage,
 CoverageSubType, LossParty, ClaimOrder, CreateTime, CLAIM_REF, ClaimantType,
 CoverageID, IncidentID, ClaimantDenormID, AssignmentStatus, BIReservePercentage_Adm,
 RIGroupSetExternally, State, SupplementalWorkloadWeight, WorkloadWeight,
 CILFigure_Adm, CILNotes_Adm, CloseDate)
SELECT
    /* PublicID */
    'mig:exp:ad:' + AC.ClaimPublicID + '_' + CONVERT(VARCHAR(64), AC.AD_ID),

    /* ClaimID */
    AC.ClaimPublicID,

    /* VectusCaseID_Adm */
    CONVERT(VARCHAR(64), AC.AD_ID),

    /* GW_HDR_CASEID */
    AC.GW_HDR_CASEID,

    /* SourceOrigin_Adm */
    'AD',

    /* ExposureType */
    R.ExposureType,

    /* PrimaryCoverage */
    R.PrimaryCoverage,

    /* CoverageSubType */
    R.CoverageSubType,

    /* LossParty */
    R.LossParty,

    /* ClaimOrder -- placeholder 0 here, corrected by Block E below (needs full cross-block visibility) */
    0,

    /* CreateTime */
    (SELECT CONVERT(DATETIME2(7), CONCAT(VC.CREATE_DATE, ' ', VC.CREATE_TIME))
     FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = AC.AD_ID),

    /* CLAIM_REF */
    AC.CLAIM_REF,

    /* ClaimantType -- 1st party is always the insured, per mapping */
    'insured',

    /* CoverageID */
    CP.PublicID,

    /* IncidentID -- still via IS_INCIDENT join, pending fresh "First
       Party Vehicle Incident" text before rebuilding from source tables */
    INC.PublicID,

    /* ClaimantDenormID -- 1st party claimant is always the insured */
    CC.ContactID,

    /* AssignmentStatus */
    'assigned',

    /* BIReservePercentage_Adm -- not applicable to AD, table default */
    100,

    /* RIGroupSetExternally */
    0,

    /* State */
    ISNULL(STATE_TL.GW_TypeCode, 'draft'),

    /* SupplementalWorkloadWeight */
    0,

    /* WorkloadWeight */
    0,

    /* CILFigure_Adm */
    CIL.TotalCIL,

    /* CILNotes_Adm */
    CASE WHEN CIL.TotalCIL IS NOT NULL THEN 'CIL' END,

    /* CloseDate -- only when State resolves to 'closed' AND the raw
       Vectus status is specifically 'Finalised' */
    CASE WHEN ISNULL(STATE_TL.GW_TypeCode, 'draft') = 'closed' AND CS.STATUS = 'Finalised'
         THEN CS.RECORD_DATE ELSE NULL END

FROM AD_CANDIDATES AC
INNER JOIN dbo.LKP_EXPOSURE_MOTOR_RULES R ON R.V2CaseFlow = 'GW MOTOR AD' AND R.RuleKey = AC.RuleKey
LEFT JOIN COVERAGE_LOOKUP CP ON CP.ClaimPublicID = AC.ClaimPublicID AND CP.Type = R.PrimaryCoverage
LEFT JOIN IntermediateStaging_DEV.dbo.IS_INCIDENT INC ON INC.PublicID = 'mig:motor:veh:fp' + CONVERT(VARCHAR(64), AC.AD_ID)
LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACTROLE CCR ON CCR.Role = 'insured'
LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC ON CC.PublicID = CCR.ClaimContactID AND CC.ClaimID = AC.ClaimPublicID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS ON CS.CASEID = AC.AD_ID AND CS.GCURRENT = 'X'
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING STATE_TL ON STATE_TL.Vectus_TypeCode = CS.STATUS AND STATE_TL.TypeList_Name = 'ExposureState'
LEFT JOIN CIL_TOTALS CIL ON CIL.VectusCaseID = AC.AD_ID;


/* ================================================================
   BLOCK B: 3rd Party Vehicle/Injury/Property Exposures
   ================================================================ */

-- Vandal/TP Driver (Thief) suppression logic REMOVED per your earlier
-- instruction (deferred, not resolved) - only PRODUCT='MOTOR' remains.
;WITH TP_BASE AS (
    SELECT
        CLM.CLAIM_REF, CLM.PUBLICID AS ClaimPublicID, CLM.GW_HDR_CASEID, TP.ID AS TP_ID,
        TPS.VEHICLE, TPS.INJURY, TPS.PROPERTY, TPTYPE.DISPLAY_STRING AS ClaimantRoleDesc
    FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_TP TP ON TP.GW_HDR_CASEID = CLM.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY TPS ON TPS.CASEID = TP.ID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_TPTYPE TPTYPE ON TPTYPE.ID = TPS.GW_TP_TYPEID
    WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
),
-- REBUILT per your senior's instruction: recomputes TP_INJ/TP_PRO
-- incident eligibility directly from source tables (confirmed formulas
-- from the "Third Party Injury/Property Incident" blocks). TP_VEH
-- intentionally not rebuilt here yet - pending fresh text.
TP_INCIDENT_ELIGIBLE AS (
    SELECT TB.TP_ID,
        CASE WHEN COALESCE(TB.VEHICLE,'') <> 'X' AND TB.INJURY = 'X' AND COALESCE(TB.PROPERTY,'') <> 'X'
             THEN 1 ELSE 0 END AS InjEligible,
        CASE WHEN COALESCE(TB.VEHICLE,'') <> 'X' AND COALESCE(TB.INJURY,'') <> 'X' AND TB.PROPERTY = 'X'
                  AND EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_TPPROP_HDR HDR WHERE HDR.CASEID = TB.TP_ID)
             THEN 1 ELSE 0 END AS ProEligible
    FROM TP_BASE TB
),
-- TRANSFORMATION (the "normal rule", not an edge case): one exposure per
-- flag switched on, completely independent of each other.
-- EDGE CASE (per the sheet's own "Data issue" label): NO TP ELEMENT -
-- the TP_VEH branch's second OR condition forces one vehicle exposure
-- as a fallback when nothing was recorded at all.
TP_ELEMENTS AS (
    SELECT CLAIM_REF, ClaimPublicID, GW_HDR_CASEID, TP_ID, ClaimantRoleDesc, 'TP_VEH' AS RuleKey, 'VEH' AS ElementTag
    FROM TP_BASE
    WHERE VEHICLE = 'X'
       OR (COALESCE(VEHICLE,'') <> 'X' AND COALESCE(INJURY,'') <> 'X' AND COALESCE(PROPERTY,'') <> 'X')
    UNION ALL
    SELECT CLAIM_REF, ClaimPublicID, GW_HDR_CASEID, TP_ID, ClaimantRoleDesc, 'TP_INJ', 'INJ'
    FROM TP_BASE WHERE INJURY = 'X'
    UNION ALL
    SELECT CLAIM_REF, ClaimPublicID, GW_HDR_CASEID, TP_ID, ClaimantRoleDesc, 'TP_PRO', 'PRO'
    FROM TP_BASE WHERE PROPERTY = 'X'
),
-- REMOVED per your instruction: once ClaimantType's crammed source
-- rows are split (see TYPELIST_crammed_row_fix.sql), the exact match
-- below is sufficient on its own - no fuzzy fallback or tiebreak needed.
COVERAGE_LOOKUP AS (
    SELECT ClaimPublicID, Type, PublicID
    FROM IntermediateStaging_DEV.dbo.IS_COVERAGE
    WHERE Subtype = 'VehicleCoverage'
),
CIL_TOTALS AS (
    SELECT PT.CASEID AS VectusCaseID, SUM(PD.AMOUNT) AS TotalCIL
    FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM_CIL
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM_CIL.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS PD ON PD.GW_PAY_TRAN_ID = PT.ID
    WHERE UPPER(LTRIM(RTRIM(CLM_CIL.PRODUCT))) = 'MOTOR' AND PD.CODE IN ('CIL','CIP')
    GROUP BY PT.CASEID
),
-- CONSOLIDATED per your instruction: was 3 separate CTEs
-- (BI_RESERVE_BASE/LATEST_RES_TRANS/BI_RESERVE), now one. Still routes
-- through IS_CLAIM_MASTER+TP_SUMMARY first (performance - only ranks
-- reserve transactions for real motor TP_INJ cases), still LEFT JOINs
-- VEC_GW_RES_ADJUST (the earlier real bug fix - a case with a latest
-- accepted transaction but no adjustment row must still appear here
-- with genuine NULLs, not be dropped and wrongly default to 100 later).
BI_RESERVE AS (
    SELECT RANKED.CASEID, RA.CLAIM_LIFE, RA.LIABILITY, RA.YRS_TO_ISSUE
    FROM (
        SELECT RT.ID, RT.CASEID,
            ROW_NUMBER() OVER (PARTITION BY RT.CASEID ORDER BY RT.GORDER DESC) AS RN
        FROM SourceStaging.VECCASRN.VEC_GW_RES_TRANS RT
        WHERE RT.ACCEPTED = 'Y'
          AND RT.CASEID IN (
              SELECT TPS.CASEID
              FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM_BI
              INNER JOIN SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY TPS ON TPS.GW_HDR_CASEID = CLM_BI.GW_HDR_CASEID
              WHERE UPPER(LTRIM(RTRIM(CLM_BI.PRODUCT))) = 'MOTOR' AND TPS.INJURY = 'X'
          )
    ) RANKED
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_RES_ADJUST RA ON RA.GW_RES_TRANSID = RANKED.ID
    WHERE RANKED.RN = 1
)
INSERT INTO IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
(PublicID, ClaimID, VectusCaseID_Adm, GW_HDR_CASEID, SourceOrigin_Adm, ExposureType, PrimaryCoverage,
 CoverageSubType, LossParty, ClaimOrder, CreateTime, CLAIM_REF, ClaimantType,
 CoverageID, IncidentID, ClaimantDenormID, AssignmentStatus, BIReservePercentage_Adm,
 RIGroupSetExternally, State, SupplementalWorkloadWeight, WorkloadWeight,
 CILFigure_Adm, CILNotes_Adm, CloseDate, LiabilityPosition_Adm, BIClaimLife_Adm, BIYearsToIssue_Adm)
SELECT
    /* PublicID */
    'mig:exp:tp' + LOWER(TE.ElementTag) + ':' + TE.ClaimPublicID + '_' + CONVERT(VARCHAR(64), TE.TP_ID),

    /* ClaimID */
    TE.ClaimPublicID,

    /* VectusCaseID_Adm */
    CONVERT(VARCHAR(64), TE.TP_ID),

    /* GW_HDR_CASEID */
    TE.GW_HDR_CASEID,

    /* SourceOrigin_Adm */
    TE.RuleKey,

    /* ExposureType */
    R.ExposureType,

    /* PrimaryCoverage */
    R.PrimaryCoverage,

    /* CoverageSubType */
    R.CoverageSubType,

    /* LossParty */
    R.LossParty,

    /* ClaimOrder -- placeholder 0 here, corrected by Block E below (needs full cross-block visibility) */
    0,

    /* CreateTime */
    (SELECT CONVERT(DATETIME2(7), CONCAT(VC.CREATE_DATE, ' ', VC.CREATE_TIME))
     FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = TE.TP_ID),

    /* CLAIM_REF */
    TE.CLAIM_REF,

    /* ClaimantType -- plain exact match against TYPELIST_TABLE_MAPPING,
       'other' if no match. Only works correctly once the crammed source
       rows are split - see TYPELIST_crammed_row_fix.sql */
    ISNULL(TL_EXACT.GW_TypeCode, 'other'),

    /* CoverageID */
    CP.PublicID,

    /* IncidentID -- TP_VEH still via IS_INCIDENT (pending fresh text);
       TP_INJ/TP_PRO now via TP_INCIDENT_ELIGIBLE (source tables directly).
       All 3 use an EXCLUSIVE filter (only their own element flagged) -
       on a combo TP case, none of the 3 get a matching incident. */
    CASE
        WHEN TE.RuleKey = 'TP_VEH' THEN INC.PublicID
        WHEN TE.RuleKey = 'TP_INJ' AND TIE.InjEligible = 1 THEN 'mig:motor:inj:tp' + CONVERT(VARCHAR(64), TE.TP_ID)
        WHEN TE.RuleKey = 'TP_PRO' AND TIE.ProEligible = 1 THEN 'mig:motor:fpi:tp' + CONVERT(VARCHAR(64), TE.TP_ID)
        ELSE NULL
    END,

    /* ClaimantDenormID -- 3rd party, STILL PROVISIONAL: matches at
       claim level, cannot distinguish two different third parties on
       the same claim (Bob/Alice example) - blocked on CONTACT_MASTER_MOTOR
       getting a per-TP-case column added */
    CM.PublicID,

    /* AssignmentStatus */
    'assigned',

    /* BIReservePercentage_Adm -- 3-way logic: not TP_INJ -> 100;
       TP_INJ + a real matched reserve row -> that row's value even if
       it's itself NULL; TP_INJ + no matched row -> 100 (table default) */
    CASE WHEN TE.RuleKey = 'TP_INJ' AND BR.CASEID IS NOT NULL THEN BR.LIABILITY ELSE 100 END,

    /* RIGroupSetExternally */
    0,

    /* State */
    ISNULL(STATE_TL.GW_TypeCode, 'draft'),

    /* SupplementalWorkloadWeight */
    0,

    /* WorkloadWeight */
    0,

    /* CILFigure_Adm */
    CIL.TotalCIL,

    /* CILNotes_Adm */
    CASE WHEN CIL.TotalCIL IS NOT NULL THEN 'CIL' END,

    /* CloseDate -- only when State resolves to 'closed' AND the raw
       Vectus status is specifically 'Finalised' */
    CASE WHEN ISNULL(STATE_TL.GW_TypeCode, 'draft') = 'closed' AND CS.STATUS = 'Finalised'
         THEN CS.RECORD_DATE ELSE NULL END,

    /* LiabilityPosition_Adm -- applies to ALL TP types unconditionally,
       no RuleKey filter needed, per mapping */
    LIAB_TL.GW_TypeCode,

    /* BIClaimLife_Adm -- TP_INJ only, NULL otherwise */
    CASE WHEN TE.RuleKey = 'TP_INJ' THEN BR.CLAIM_LIFE ELSE NULL END,

    /* BIYearsToIssue_Adm -- TP_INJ only, NULL otherwise */
    CASE WHEN TE.RuleKey = 'TP_INJ' THEN BR.YRS_TO_ISSUE ELSE NULL END

FROM TP_ELEMENTS TE
INNER JOIN dbo.LKP_EXPOSURE_MOTOR_RULES R ON R.RuleKey = TE.RuleKey AND R.V2CaseFlow = 'GW MOTOR TP'
LEFT JOIN COVERAGE_LOOKUP CP ON CP.ClaimPublicID = TE.ClaimPublicID AND CP.Type = R.PrimaryCoverage
LEFT JOIN IntermediateStaging_DEV.dbo.IS_INCIDENT INC
    ON TE.RuleKey = 'TP_VEH' AND INC.PublicID = 'mig:motor:veh:tp' + CONVERT(VARCHAR(64), TE.TP_ID)
LEFT JOIN TP_INCIDENT_ELIGIBLE TIE ON TIE.TP_ID = TE.TP_ID
LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM ON CM.GW_HDR_CASEID = TE.GW_HDR_CASEID AND CM.HDR_TYPE_ID = 55
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR_TYPE HT ON HT.ID = CM.HDR_TYPE_ID AND HT.PRIMCONT_TYPE = 'Y'
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL_EXACT
    ON TL_EXACT.TypeList_Name = 'ClaimantType' AND TL_EXACT.Vectus_TypeCode = TE.ClaimantRoleDesc
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_LIABILITY LIAB ON LIAB.CASEID = TE.TP_ID AND LIAB.CURRENT_REC = 'X'
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING LIAB_TL ON LIAB_TL.Vectus_TypeCode = LIAB.LIAB_STATUS AND LIAB_TL.TypeList_Name = 'LiabilityPosition_Adm'
LEFT JOIN BI_RESERVE BR ON BR.CASEID = TE.TP_ID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS ON CS.CASEID = TE.TP_ID AND CS.GCURRENT = 'X'
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING STATE_TL ON STATE_TL.Vectus_TypeCode = CS.STATUS AND STATE_TL.TypeList_Name = 'ExposureState'
LEFT JOIN CIL_TOTALS CIL ON CIL.VectusCaseID = TE.TP_ID;


/* ================================================================
   BLOCK C: 3rd Party Hire & Mobility Exposures
   PAYMENT CODE LIST CONFLICT still open - see earlier chat message.
   ================================================================ */

-- EDGE CASE: needs one of TWO different conditions, not a single flag -
-- either a hire-related payment transaction exists on its own, OR the
-- vehicle flag is on AND a hire record exists. A hire record ALONE
-- (no vehicle flag, no payment transaction) does not qualify.
;WITH TP_HIRE_CANDIDATES AS (
    SELECT CLM.CLAIM_REF, CLM.PUBLICID AS ClaimPublicID, CLM.GW_HDR_CASEID, TP.ID AS TP_ID,
           TPTYPE.DISPLAY_STRING AS ClaimantRoleDesc
    FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_TP TP ON TP.GW_HDR_CASEID = CLM.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY TPS ON TPS.CASEID = TP.ID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_TPTYPE TPTYPE ON TPTYPE.ID = TPS.GW_TP_TYPEID
    WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
      AND (
            EXISTS (
                SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
                INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS PD ON PD.GW_PAY_TRAN_ID = PT.ID
                WHERE PT.GW_HDR_CASEID = TP.GW_HDR_CASEID
                  AND PD.CODE IN ('ABH','COW','OUH','PLH','PLP','RVM','SUB','TEM','TPH','FSC','ABA','ABP')
            )
            OR (TPS.VEHICLE = 'X' AND EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_HIREREC HR WHERE HR.CASEID = TP.ID))
      )
),
-- REMOVED - same as Block B, plain exact match now sufficient.
COVERAGE_LOOKUP AS (
    SELECT ClaimPublicID, Type, PublicID
    FROM IntermediateStaging_DEV.dbo.IS_COVERAGE
    WHERE Subtype = 'VehicleCoverage'
),
CIL_TOTALS AS (
    SELECT PT.CASEID AS VectusCaseID, SUM(PD.AMOUNT) AS TotalCIL
    FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM_CIL
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM_CIL.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS PD ON PD.GW_PAY_TRAN_ID = PT.ID
    WHERE UPPER(LTRIM(RTRIM(CLM_CIL.PRODUCT))) = 'MOTOR' AND PD.CODE IN ('CIL','CIP')
    GROUP BY PT.CASEID
),
-- EDGE CASE: two-step State check, not the standard case-status lookup.
-- Step 1: is the underlying TP case itself finalized? If yes, closed -
-- don't even check history notes. Step 2: only if not finalized, check
-- for a note titled exactly 'Hire claim settled' (latest by ORDERING).
HIRE_SETTLED AS (
    SELECT CASEID, MAX(ORDERING) AS MaxOrdering
    FROM SourceStaging.VECCASRN.VEC_HISTORY
    WHERE HISTORYTEXT = 'Hire claim settled'
    GROUP BY CASEID
),
HIRE_SETTLED_DETAIL AS (
    SELECT H.CASEID, H.CREATEDATE, H.CREATETIME
    FROM SourceStaging.VECCASRN.VEC_HISTORY H
    INNER JOIN HIRE_SETTLED HS ON HS.CASEID = H.CASEID AND HS.MaxOrdering = H.ORDERING
),
HIRE_CASE_STATUS AS (
    SELECT CS.CASEID, CS.STATUS
    FROM SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS
    WHERE CS.GCURRENT = 'X'
)
INSERT INTO IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
(PublicID, ClaimID, VectusCaseID_Adm, GW_HDR_CASEID, SourceOrigin_Adm, ExposureType, PrimaryCoverage,
 CoverageSubType, LossParty, ClaimOrder, CreateTime, CLAIM_REF, ClaimantType,
 CoverageID, IncidentID, ClaimantDenormID, AssignmentStatus, BIReservePercentage_Adm,
 RIGroupSetExternally, State, SupplementalWorkloadWeight, WorkloadWeight,
 CILFigure_Adm, CILNotes_Adm, CloseDate, LiabilityPosition_Adm)
SELECT
    /* PublicID */
    'mig:exp:tphire:' + H.ClaimPublicID + '_' + CONVERT(VARCHAR(64), H.TP_ID),

    /* ClaimID */
    H.ClaimPublicID,

    /* VectusCaseID_Adm */
    CONVERT(VARCHAR(64), H.TP_ID),

    /* GW_HDR_CASEID */
    H.GW_HDR_CASEID,

    /* SourceOrigin_Adm */
    'TP_HIRE',

    /* ExposureType */
    R.ExposureType,

    /* PrimaryCoverage */
    R.PrimaryCoverage,

    /* CoverageSubType */
    R.CoverageSubType,

    /* LossParty */
    R.LossParty,

    /* ClaimOrder -- placeholder 0 here, corrected by Block E below (needs full cross-block visibility) */
    0,

    /* CreateTime */
    (SELECT CONVERT(DATETIME2(7), CONCAT(VC.CREATE_DATE, ' ', VC.CREATE_TIME))
     FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = H.TP_ID),

    /* CLAIM_REF */
    H.CLAIM_REF,

    /* ClaimantType -- per the mapping doc's own instruction, the same
       DISPLAY_STRING lookup applies to Hire & Mobility, not just the
       other TP types */
    ISNULL(TL_EXACT.GW_TypeCode, 'other'),

    /* CoverageID */
    CP.PublicID,

    /* IncidentID -- HYPOTHESIS, not confirmed by any document: reuses
       TP_VEH's own incident (same TP case, same IncidentType), still
       via IS_INCIDENT pending fresh TP_VEH text */
    INC.PublicID,

    /* ClaimantDenormID -- 3rd party, same provisional limitation as Block B */
    CM.PublicID,

    /* AssignmentStatus */
    'assigned',

    /* BIReservePercentage_Adm -- not applicable to Hire & Mobility, table default */
    100,

    /* RIGroupSetExternally */
    0,

    /* State -- special Hire & Mobility two-step logic, not the standard lookup */
    CASE WHEN HCS.STATUS = 'Finalised' THEN 'closed'
         WHEN HSD.CASEID IS NOT NULL THEN 'closed'
         ELSE 'open'
    END,

    /* SupplementalWorkloadWeight */
    0,

    /* WorkloadWeight */
    0,

    /* CILFigure_Adm */
    CIL.TotalCIL,

    /* CILNotes_Adm */
    CASE WHEN CIL.TotalCIL IS NOT NULL THEN 'CIL' END,

    /* CloseDate -- only from the settled-note's create date, never from
       case-status RECORD_DATE (Hire & Mobility is explicitly excluded
       from that general rule per the mapping) */
    CASE WHEN HSD.CASEID IS NOT NULL THEN CONVERT(DATETIME2(7), CONCAT(HSD.CREATEDATE, ' ', HSD.CREATETIME)) ELSE NULL END,

    /* LiabilityPosition_Adm -- applies to Hire & Mobility too, per mapping */
    LIAB_TL.GW_TypeCode

FROM TP_HIRE_CANDIDATES H
INNER JOIN dbo.LKP_EXPOSURE_MOTOR_RULES R ON R.RuleKey = 'TP_HIRE' AND R.V2CaseFlow = 'GW MOTOR TP'
LEFT JOIN COVERAGE_LOOKUP CP ON CP.ClaimPublicID = H.ClaimPublicID AND CP.Type = R.PrimaryCoverage
LEFT JOIN IntermediateStaging_DEV.dbo.IS_INCIDENT INC ON INC.PublicID = 'mig:motor:veh:tp' + CONVERT(VARCHAR(64), H.TP_ID)
LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM ON CM.GW_HDR_CASEID = H.GW_HDR_CASEID AND CM.HDR_TYPE_ID = 55
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR_TYPE HT ON HT.ID = CM.HDR_TYPE_ID AND HT.PRIMCONT_TYPE = 'Y'
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL_EXACT
    ON TL_EXACT.TypeList_Name = 'ClaimantType' AND TL_EXACT.Vectus_TypeCode = H.ClaimantRoleDesc
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_LIABILITY LIAB ON LIAB.CASEID = H.TP_ID AND LIAB.CURRENT_REC = 'X'
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING LIAB_TL ON LIAB_TL.Vectus_TypeCode = LIAB.LIAB_STATUS AND LIAB_TL.TypeList_Name = 'LiabilityPosition_Adm'
LEFT JOIN HIRE_CASE_STATUS HCS ON HCS.CASEID = H.TP_ID
LEFT JOIN HIRE_SETTLED_DETAIL HSD ON HSD.CASEID = H.TP_ID
LEFT JOIN CIL_TOTALS CIL ON CIL.VectusCaseID = H.TP_ID;


/* ================================================================
   BLOCK D: 1st Party PA Ancillary Exposures
   ================================================================ */

-- EDGE CASE: if a policy unusually has BOTH PI coverage variants active
-- at once, always use the richer "Plus" version. MAX(CASE...) picks up
-- the Plus flag if it exists anywhere for this risk unit, regardless of
-- what the standard row also contributes.
;WITH PA_COV_CHECK AS (
    SELECT
        CLM.CLAIM_REF, CLM.PUBLICID AS ClaimPublicID, CLM.GW_HDR_CASEID, PA.ID AS PA_ID,
        MAX(CASE WHEN COV.PATTERN_CODE = 'PMPersonalInjuryPlusAncCov' THEN 1 ELSE 0 END) AS HasPlusCov
    FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
    INNER JOIN SourceStaging.VECCASRN.VEC_PA_ANCILLARY PA ON PA.GW_HDR_CASEID = CLM.GW_HDR_CASEID
    INNER JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR ON SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID
    INNER JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_COVERAGE COV
        ON COV.GWP_RISKUNITID = RSK.ID AND COV.PATTERN_CODE IN ('PMPersonalInjuryAncCov','PMPersonalInjuryPlusAncCov')
    WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
    GROUP BY CLM.CLAIM_REF, CLM.PUBLICID, CLM.GW_HDR_CASEID, PA.ID
),
COVERAGE_LOOKUP AS (
    SELECT ClaimPublicID, Type, PublicID
    FROM IntermediateStaging_DEV.dbo.IS_COVERAGE
    WHERE Subtype = 'VehicleCoverage'
),
CIL_TOTALS AS (
    SELECT PT.CASEID AS VectusCaseID, SUM(PD.AMOUNT) AS TotalCIL
    FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM_CIL
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT ON PT.GW_HDR_CASEID = CLM_CIL.GW_HDR_CASEID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS PD ON PD.GW_PAY_TRAN_ID = PT.ID
    WHERE UPPER(LTRIM(RTRIM(CLM_CIL.PRODUCT))) = 'MOTOR' AND PD.CODE IN ('CIL','CIP')
    GROUP BY PT.CASEID
),
-- REBUILT per your senior's instruction: recomputes eligibility directly
-- from source tables, mirroring the exact FROM/WHERE of the "First
-- Party Injury Incident" block (claim validity + selected risk + risk
-- unit + a coverage row with pattern PMPersonalInjuryAncCov/PlusAncCov).
-- That source block is itself flagged "Join condition not available in
-- mapping doc" - a documentation gap on the incident side.
PA_INCIDENT_ELIGIBLE AS (
    SELECT DISTINCT MTP.ID AS PA_ID
    FROM SourceStaging.VECCASRN.VEC_GW_CLAIM_SUM CLM_INC
    INNER JOIN SourceStaging.VECCASRN.VEC_PA_ANCILLARY MTP ON CLM_INC.GW_HDR_CASEID = MTP.GW_HDR_CASEID
    INNER JOIN (SELECT GW_HDR_CASEID, ID, ROW_NUMBER() OVER (PARTITION BY GW_HDR_CASEID ORDER BY ID DESC) AS RN
                FROM SourceStaging.VECCASRN.VEC_GWP_POLICY) POL ON POL.GW_HDR_CASEID = CLM_INC.GW_HDR_CASEID AND POL.RN = 1
    INNER JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CM_INC ON CM_INC.GW_HDR_CASEID = CLM_INC.GW_HDR_CASEID
    INNER JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SRSK ON CLM_INC.GW_HDR_CASEID = SRSK.GW_HDR_CASEID
    INNER JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RISK ON SRSK.GWP_POLICYID = RISK.GWP_POLICYID AND SRSK.PUBLICID = RISK.PUBLICID
    INNER JOIN SourceStaging.VECCASRN.VEC_GWP_COVERAGE COV ON RISK.ID = COV.GWP_RISKUNITID
        AND COV.PATTERN_CODE IN ('PMPersonalInjuryAncCov','PMPersonalInjuryPlusAncCov')
    WHERE CLM_INC.GCURRENT = 'X'
      AND CLM_INC.INCIDENT_CODE <> 'WINDSCREEN'
      AND CLM_INC.CLAIM_REF IS NOT NULL AND CLM_INC.CLAIM_REF <> ''
)
INSERT INTO IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
(PublicID, ClaimID, VectusCaseID_Adm, GW_HDR_CASEID, SourceOrigin_Adm, ExposureType, PrimaryCoverage,
 CoverageSubType, LossParty, ClaimOrder, CreateTime, CLAIM_REF, ClaimantType,
 CoverageID, IncidentID, ClaimantDenormID, AssignmentStatus, BIReservePercentage_Adm,
 RIGroupSetExternally, State, SupplementalWorkloadWeight, WorkloadWeight,
 CILFigure_Adm, CILNotes_Adm, CloseDate)
SELECT
    /* PublicID */
    'mig:exp:pa:' + PC.ClaimPublicID + '_' + CONVERT(VARCHAR(64), PC.PA_ID),

    /* ClaimID */
    PC.ClaimPublicID,

    /* VectusCaseID_Adm */
    CONVERT(VARCHAR(64), PC.PA_ID),

    /* GW_HDR_CASEID */
    PC.GW_HDR_CASEID,

    /* SourceOrigin_Adm */
    'PA',

    /* ExposureType */
    R.ExposureType,

    /* PrimaryCoverage */
    R.PrimaryCoverage,

    /* CoverageSubType */
    R.CoverageSubType,

    /* LossParty */
    R.LossParty,

    /* ClaimOrder -- placeholder 0 here, corrected by Block E below (needs full cross-block visibility) */
    0,

    /* CreateTime */
    (SELECT CONVERT(DATETIME2(7), CONCAT(VC.CREATE_DATE, ' ', VC.CREATE_TIME))
     FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = PC.PA_ID),

    /* CLAIM_REF */
    PC.CLAIM_REF,

    /* ClaimantType -- 1st party is always the insured, per mapping */
    'insured',

    /* CoverageID */
    CP.PublicID,

    /* IncidentID -- confirmed formula from source tables, see
       PA_INCIDENT_ELIGIBLE above */
    CASE WHEN PIE.PA_ID IS NOT NULL THEN 'mig:motor:inj:FP' + CONVERT(VARCHAR(20), PC.PA_ID) ELSE NULL END,

    /* ClaimantDenormID -- 1st party claimant is always the insured */
    CC.ContactID,

    /* AssignmentStatus */
    'assigned',

    /* BIReservePercentage_Adm -- not applicable to PA, table default */
    100,

    /* RIGroupSetExternally */
    0,

    /* State */
    ISNULL(STATE_TL.GW_TypeCode, 'draft'),

    /* SupplementalWorkloadWeight */
    0,

    /* WorkloadWeight */
    0,

    /* CILFigure_Adm */
    CIL.TotalCIL,

    /* CILNotes_Adm */
    CASE WHEN CIL.TotalCIL IS NOT NULL THEN 'CIL' END,

    /* CloseDate -- only when State resolves to 'closed' AND the raw
       Vectus status is specifically 'Finalised' */
    CASE WHEN ISNULL(STATE_TL.GW_TypeCode, 'draft') = 'closed' AND CS.STATUS = 'Finalised'
         THEN CS.RECORD_DATE ELSE NULL END

FROM PA_COV_CHECK PC
INNER JOIN dbo.LKP_EXPOSURE_MOTOR_RULES R ON R.V2CaseFlow = 'GW PI ANCILLARY' AND R.RuleKey = CASE WHEN PC.HasPlusCov = 1 THEN 'PA_PLUS' ELSE 'PA_STD' END
LEFT JOIN COVERAGE_LOOKUP CP ON CP.ClaimPublicID = PC.ClaimPublicID AND CP.Type = R.PrimaryCoverage
LEFT JOIN PA_INCIDENT_ELIGIBLE PIE ON PIE.PA_ID = PC.PA_ID
LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACTROLE CCR ON CCR.Role = 'insured'
LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC ON CC.PublicID = CCR.ClaimContactID AND CC.ClaimID = PC.ClaimPublicID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS ON CS.CASEID = PC.PA_ID AND CS.GCURRENT = 'X'
LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING STATE_TL ON STATE_TL.Vectus_TypeCode = CS.STATUS AND STATE_TL.TypeList_Name = 'ExposureState'
LEFT JOIN CIL_TOTALS CIL ON CIL.VectusCaseID = PC.PA_ID;


/* ================================================================
   BLOCK E: ClaimOrder — the one legitimate exception to "no UPDATE
   statements". Per the mapping: "Do random ordering of migrated
   exposures - no specific priority order to be applied." This can only
   be computed AFTER all 4 blocks above have finished inserting, since
   it needs to see every exposure a claim ended up with (spread across
   Blocks A-D) to number them - no single block has that full picture
   on its own. NEWID() here is correct and intentional (unlike
   ClaimantType, which stays deterministic) - the mapping explicitly
   asks for no priority order, so a genuinely random shuffle per claim
   is exactly what's being asked for.
   ================================================================ */
;WITH ORDERED AS (
    SELECT PublicID, ROW_NUMBER() OVER (PARTITION BY ClaimID ORDER BY NEWID()) AS RN
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
)
UPDATE E
SET E.ClaimOrder = O.RN
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E
INNER JOIN ORDERED O ON O.PublicID = E.PublicID;

END
GO


/* =====================================================================
   3. VALIDATION / FAN-OUT QUERIES
   ===================================================================== */

SELECT PublicID, COUNT(*) FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
GROUP BY PublicID HAVING COUNT(*) > 1;

SELECT PublicID FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
WHERE ClaimID IS NULL OR ExposureType IS NULL OR PrimaryCoverage IS NULL
   OR ClaimOrder IS NULL OR AssignmentStatus IS NULL OR BIReservePercentage_Adm IS NULL
   OR RIGroupSetExternally IS NULL OR State IS NULL OR SupplementalWorkloadWeight IS NULL
   OR WorkloadWeight IS NULL OR CreateTime IS NULL;

SELECT * FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR WHERE CoverageID IS NULL;

SELECT GW_HDR_CASEID, COUNT(DISTINCT ID) AS ad_case_count
FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_AD
GROUP BY GW_HDR_CASEID
HAVING COUNT(DISTINCT ID) > 1;

SELECT DISTINCT CLAIM_REF FROM SourceStaging.dbo.LKP_Dupe_MotorAD
WHERE CLAIM_REF IS NOT NULL AND Solution LIKE 'Migrate-group%'
AND CLAIM_REF NOT IN (SELECT CLAIM_REF FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR WHERE SourceOrigin_Adm = 'AD');

SELECT ClaimID, CLAIM_REF, COUNT(*) AS ad_exposure_count
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
WHERE SourceOrigin_Adm = 'AD'
GROUP BY ClaimID, CLAIM_REF
HAVING COUNT(*) > 1;

SELECT ClaimPublicID, Type, COUNT(*) AS dup_count
FROM IntermediateStaging_DEV.dbo.IS_COVERAGE
WHERE Subtype = 'VehicleCoverage'
GROUP BY ClaimPublicID, Type
HAVING COUNT(*) > 1;

SELECT SourceOrigin_Adm, COUNT(*) AS total, SUM(CASE WHEN IncidentID IS NULL THEN 1 ELSE 0 END) AS null_incidents
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
GROUP BY SourceOrigin_Adm;

SELECT E.CLAIM_REF, E.PublicID, E.SourceOrigin_Adm, TPS.VEHICLE, TPS.INJURY, TPS.PROPERTY
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E
INNER JOIN SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY TPS ON TPS.CASEID = CONVERT(BIGINT, E.VectusCaseID_Adm)
WHERE (E.SourceOrigin_Adm = 'TP_VEH' AND (TPS.INJURY = 'X' OR TPS.PROPERTY = 'X'))
   OR (E.SourceOrigin_Adm = 'TP_INJ' AND (TPS.VEHICLE = 'X' OR TPS.PROPERTY = 'X'))
   OR (E.SourceOrigin_Adm = 'TP_PRO' AND (TPS.VEHICLE = 'X' OR TPS.INJURY = 'X'));

SELECT CLM.CLAIM_REF, COUNT(*) AS tp_case_count
FROM IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
INNER JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_TP TP ON TP.GW_HDR_CASEID = CLM.GW_HDR_CASEID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
GROUP BY CLM.CLAIM_REF
HAVING COUNT(*) > 1;

SELECT DISTINCT T.DISPLAY_STRING
FROM SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY S
INNER JOIN SourceStaging.VECCASRN.VEC_GW_TPTYPE T ON T.ID = S.GW_TP_TYPEID
WHERE T.DISPLAY_STRING IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
      WHERE TL.TypeList_Name = 'ClaimantType' AND TL.Vectus_TypeCode LIKE '%' + T.DISPLAY_STRING + '%'
  );

SELECT DD.DISPLAY_STRING, TL.GW_TypeCode, TL.Vectus_TypeCode
FROM (SELECT DISTINCT DISPLAY_STRING FROM SourceStaging.VECCASRN.VEC_GW_TPTYPE WHERE DISPLAY_STRING IS NOT NULL) DD
INNER JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
    ON TL.TypeList_Name = 'ClaimantType' AND TL.Vectus_TypeCode LIKE '%' + DD.DISPLAY_STRING + '%'
WHERE DD.DISPLAY_STRING IN (
    SELECT DD2.DISPLAY_STRING
    FROM (SELECT DISTINCT DISPLAY_STRING FROM SourceStaging.VECCASRN.VEC_GW_TPTYPE WHERE DISPLAY_STRING IS NOT NULL) DD2
    INNER JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL2
        ON TL2.TypeList_Name = 'ClaimantType' AND TL2.Vectus_TypeCode LIKE '%' + DD2.DISPLAY_STRING + '%'
    GROUP BY DD2.DISPLAY_STRING
    HAVING COUNT(*) > 1
)
ORDER BY DD.DISPLAY_STRING;

SELECT ClaimID, SourceOrigin_Adm, COUNT(*) AS cnt
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
GROUP BY ClaimID, SourceOrigin_Adm
ORDER BY cnt DESC;
