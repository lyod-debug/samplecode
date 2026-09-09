/* =====================================================================
   IS_EXPOSURE_MOTOR — v21
   ARCHITECTURE CHANGE per your senior's review: every field that was
   previously populated via a post-INSERT UPDATE (CoverageID, IncidentID,
   ClaimantDenormID, ClaimantType-fallback, LiabilityPosition_Adm, BI
   fields, CIL fields, State, CloseDate, and the flat mandatory defaults)
   is now computed inline via LEFT JOINs within each block's own single
   INSERT...SELECT. No UPDATE statements remain anywhere in this proc.
   Same technique applied consistently: an UPDATE's INNER JOIN only
   touches matched rows and leaves the rest at their prior value; a
   LEFT JOIN in the SELECT reproduces that exactly (real value on match,
   NULL/default on no match) in a single pass instead of N passes.
   Every field's actual logic (source tables, join keys, fallback
   values) is unchanged from v20 - only WHERE it's computed moved.
   Re-verified line by line against the mapping-doc text and all prior
   discussion before finalizing - see chat message.
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
   BLOCK A: 1st Party AD Vehicle Exposures — single INSERT...SELECT
   ================================================================ */
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
COVERAGE_PRIORITY AS (
    SELECT ClaimPublicID, Type, PublicID,
        ROW_NUMBER() OVER (PARTITION BY ClaimPublicID, Type
            ORDER BY CASE WHEN VEC_GMP_COVERAGEID IS NOT NULL THEN 1 ELSE 2 END, PublicID ASC) AS RN
    FROM IntermediateStaging_DEV.dbo.IS_COVERAGE
    WHERE Subtype = 'VehicleCoverage'
),
CIL_TOTALS AS (
    SELECT PT.GW_HDR_CASEID, SUM(PD.AMOUNT) AS TotalCIL
    FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS PD ON PD.GW_PAY_TRAN_ID = PT.ID
    WHERE PD.CODE IN ('CIL','CIP')
    GROUP BY PT.GW_HDR_CASEID
),
AD_ENRICHED AS (
    SELECT
        AC.CLAIM_REF, AC.ClaimPublicID, AC.GW_HDR_CASEID, AC.AD_ID,
        R.ExposureType, R.PrimaryCoverage, R.CoverageSubType, R.LossParty,
        CP.PublicID AS CoverageID,
        INC.PublicID AS IncidentID,
        CC.ContactID AS ClaimantDenormID,
        ISNULL(STATE_TL.GW_TypeCode, 'draft') AS ResolvedState,
        CS.STATUS AS CaseStatusRaw,
        CS.RECORD_DATE AS CaseRecordDate,
        CIL.TotalCIL
    FROM AD_CANDIDATES AC
    INNER JOIN dbo.LKP_EXPOSURE_MOTOR_RULES R ON R.V2CaseFlow = 'GW MOTOR AD' AND R.RuleKey = AC.RuleKey
    LEFT JOIN COVERAGE_PRIORITY CP ON CP.ClaimPublicID = AC.ClaimPublicID AND CP.Type = R.PrimaryCoverage AND CP.RN = 1
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_INCIDENT INC ON INC.PublicID = 'mig:motor:veh:fp' + CONVERT(VARCHAR(64), AC.AD_ID)
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACTROLE CCR ON CCR.Role = 'insured'
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC ON CC.PublicID = CCR.ClaimContactID AND CC.ClaimID = AC.ClaimPublicID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS ON CS.CASEID = AC.AD_ID AND CS.GCURRENT = 'X'
    LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING STATE_TL ON STATE_TL.Vectus_TypeCode = CS.STATUS AND STATE_TL.TypeList_Name = 'ExposureState'
    LEFT JOIN CIL_TOTALS CIL ON CIL.GW_HDR_CASEID = AC.GW_HDR_CASEID
)
INSERT INTO IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
(PublicID, ClaimID, VectusCaseID_Adm, GW_HDR_CASEID, SourceOrigin_Adm, ExposureType, PrimaryCoverage,
 CoverageSubType, LossParty, ClaimOrder, CreateTime, CLAIM_REF, ClaimantType,
 CoverageID, IncidentID, ClaimantDenormID, AssignmentStatus, BIReservePercentage_Adm,
 RIGroupSetExternally, State, SupplementalWorkloadWeight, WorkloadWeight,
 CILFigure_Adm, CILNotes_Adm, CloseDate)
SELECT
    'mig:exp:ad:' + EN.ClaimPublicID + '_' + CONVERT(VARCHAR(64), EN.AD_ID),
    EN.ClaimPublicID, CONVERT(VARCHAR(64), EN.AD_ID), EN.GW_HDR_CASEID, 'AD',
    EN.ExposureType, EN.PrimaryCoverage, EN.CoverageSubType, EN.LossParty,
    0,
    (SELECT CONVERT(DATETIME2(7), CONCAT(VC.CREATE_DATE, ' ', VC.CREATE_TIME))
     FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = EN.AD_ID),
    EN.CLAIM_REF, 'insured',
    EN.CoverageID, EN.IncidentID, EN.ClaimantDenormID,
    'assigned', 100, 0,
    EN.ResolvedState,
    0, 0,
    EN.TotalCIL, CASE WHEN EN.TotalCIL IS NOT NULL THEN 'CIL' END,
    CASE WHEN EN.ResolvedState = 'closed' AND EN.CaseStatusRaw = 'Finalised' THEN EN.CaseRecordDate ELSE NULL END
FROM AD_ENRICHED EN;


/* ================================================================
   BLOCK B: 3rd Party Vehicle/Injury/Property — single INSERT...SELECT
   ================================================================ */
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
CLAIMANT_TYPE_LOOKUP AS (
    SELECT DD.DISPLAY_STRING, TL.GW_TypeCode,
        ROW_NUMBER() OVER (PARTITION BY DD.DISPLAY_STRING ORDER BY TL.GW_TypeCode) AS RN
    FROM (SELECT DISTINCT DISPLAY_STRING FROM SourceStaging.VECCASRN.VEC_GW_TPTYPE WHERE DISPLAY_STRING IS NOT NULL) DD
    INNER JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
        ON TL.TypeList_Name = 'ClaimantType' AND TL.Vectus_TypeCode LIKE '%' + DD.DISPLAY_STRING + '%'
),
COVERAGE_PRIORITY AS (
    SELECT ClaimPublicID, Type, PublicID,
        ROW_NUMBER() OVER (PARTITION BY ClaimPublicID, Type
            ORDER BY CASE WHEN VEC_GMP_COVERAGEID IS NOT NULL THEN 1 ELSE 2 END, PublicID ASC) AS RN
    FROM IntermediateStaging_DEV.dbo.IS_COVERAGE
    WHERE Subtype = 'VehicleCoverage'
),
CIL_TOTALS AS (
    SELECT PT.GW_HDR_CASEID, SUM(PD.AMOUNT) AS TotalCIL
    FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS PD ON PD.GW_PAY_TRAN_ID = PT.ID
    WHERE PD.CODE IN ('CIL','CIP')
    GROUP BY PT.GW_HDR_CASEID
),
LATEST_RES_TRANS AS (
    SELECT RT.ID, RT.CASEID,
        ROW_NUMBER() OVER (PARTITION BY RT.CASEID ORDER BY RT.GORDER DESC) AS RN
    FROM SourceStaging.VECCASRN.VEC_GW_RES_TRANS RT
    WHERE RT.ACCEPTED = 'Y'
),
BI_RESERVE AS (
    SELECT LRT.CASEID, RA.CLAIM_LIFE, RA.LIABILITY, RA.YRS_TO_ISSUE
    FROM LATEST_RES_TRANS LRT
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_RES_ADJUST RA ON RA.GW_RES_TRANSID = LRT.ID
    WHERE LRT.RN = 1
),
TP_ENRICHED AS (
    SELECT
        TE.CLAIM_REF, TE.ClaimPublicID, TE.GW_HDR_CASEID, TE.TP_ID, TE.RuleKey, TE.ElementTag,
        R.ExposureType, R.PrimaryCoverage, R.CoverageSubType, R.LossParty,
        CP.PublicID AS CoverageID,
        CASE WHEN TE.RuleKey = 'TP_VEH' THEN INC.PublicID ELSE NULL END AS IncidentID,
        CM.PublicID AS ClaimantDenormID,
        ISNULL(TL_EXACT.GW_TypeCode, ISNULL(CTL.GW_TypeCode, 'other')) AS ClaimantTypeResolved,
        LIAB_TL.GW_TypeCode AS LiabilityPositionResolved,
        CASE WHEN TE.RuleKey = 'TP_INJ' AND BR.CASEID IS NOT NULL THEN BR.LIABILITY ELSE 100 END AS BIReservePctResolved,
        CASE WHEN TE.RuleKey = 'TP_INJ' THEN BR.CLAIM_LIFE ELSE NULL END AS BIClaimLifeResolved,
        CASE WHEN TE.RuleKey = 'TP_INJ' THEN BR.YRS_TO_ISSUE ELSE NULL END AS BIYearsToIssueResolved,
        ISNULL(STATE_TL.GW_TypeCode, 'draft') AS ResolvedState,
        CS.STATUS AS CaseStatusRaw,
        CS.RECORD_DATE AS CaseRecordDate,
        CIL.TotalCIL
    FROM TP_ELEMENTS TE
    INNER JOIN dbo.LKP_EXPOSURE_MOTOR_RULES R ON R.RuleKey = TE.RuleKey AND R.V2CaseFlow = 'GW MOTOR TP'
    LEFT JOIN COVERAGE_PRIORITY CP ON CP.ClaimPublicID = TE.ClaimPublicID AND CP.Type = R.PrimaryCoverage AND CP.RN = 1
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_INCIDENT INC ON INC.PublicID = 'mig:motor:veh:tp' + CONVERT(VARCHAR(64), TE.TP_ID)
    LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM ON CM.GW_HDR_CASEID = TE.GW_HDR_CASEID AND CM.HDR_TYPE_ID = 55
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR_TYPE HT ON HT.ID = CM.HDR_TYPE_ID AND HT.PRIMCONT_TYPE = 'Y'
    LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL_EXACT
        ON TL_EXACT.TypeList_Name = 'ClaimantType' AND TL_EXACT.Vectus_TypeCode = TE.ClaimantRoleDesc
    LEFT JOIN CLAIMANT_TYPE_LOOKUP CTL ON CTL.DISPLAY_STRING = TE.ClaimantRoleDesc AND CTL.RN = 1
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_LIABILITY LIAB ON LIAB.CASEID = TE.TP_ID AND LIAB.CURRENT_REC = 'X'
    LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING LIAB_TL ON LIAB_TL.Vectus_TypeCode = LIAB.LIAB_STATUS AND LIAB_TL.TypeList_Name = 'LiabilityPosition_Adm'
    LEFT JOIN BI_RESERVE BR ON BR.CASEID = TE.TP_ID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS ON CS.CASEID = TE.TP_ID AND CS.GCURRENT = 'X'
    LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING STATE_TL ON STATE_TL.Vectus_TypeCode = CS.STATUS AND STATE_TL.TypeList_Name = 'ExposureState'
    LEFT JOIN CIL_TOTALS CIL ON CIL.GW_HDR_CASEID = TE.GW_HDR_CASEID
)
INSERT INTO IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
(PublicID, ClaimID, VectusCaseID_Adm, GW_HDR_CASEID, SourceOrigin_Adm, ExposureType, PrimaryCoverage,
 CoverageSubType, LossParty, ClaimOrder, CreateTime, CLAIM_REF, ClaimantType,
 CoverageID, IncidentID, ClaimantDenormID, AssignmentStatus, BIReservePercentage_Adm,
 RIGroupSetExternally, State, SupplementalWorkloadWeight, WorkloadWeight,
 CILFigure_Adm, CILNotes_Adm, CloseDate, LiabilityPosition_Adm, BIClaimLife_Adm, BIYearsToIssue_Adm)
SELECT
    'mig:exp:tp' + LOWER(EN.ElementTag) + ':' + EN.ClaimPublicID + '_' + CONVERT(VARCHAR(64), EN.TP_ID),
    EN.ClaimPublicID, CONVERT(VARCHAR(64), EN.TP_ID), EN.GW_HDR_CASEID, EN.RuleKey,
    EN.ExposureType, EN.PrimaryCoverage, EN.CoverageSubType, EN.LossParty,
    0,
    (SELECT CONVERT(DATETIME2(7), CONCAT(VC.CREATE_DATE, ' ', VC.CREATE_TIME))
     FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = EN.TP_ID),
    EN.CLAIM_REF, EN.ClaimantTypeResolved,
    EN.CoverageID, EN.IncidentID, EN.ClaimantDenormID,
    'assigned', EN.BIReservePctResolved, 0,
    EN.ResolvedState,
    0, 0,
    EN.TotalCIL, CASE WHEN EN.TotalCIL IS NOT NULL THEN 'CIL' END,
    CASE WHEN EN.ResolvedState = 'closed' AND EN.CaseStatusRaw = 'Finalised' THEN EN.CaseRecordDate ELSE NULL END,
    EN.LiabilityPositionResolved, EN.BIClaimLifeResolved, EN.BIYearsToIssueResolved
FROM TP_ENRICHED EN;


/* ================================================================
   BLOCK C: 3rd Party Hire & Mobility — single INSERT...SELECT
   PAYMENT CODE LIST CONFLICT still open - see prior chat message.
   ================================================================ */
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
CLAIMANT_TYPE_LOOKUP AS (
    SELECT DD.DISPLAY_STRING, TL.GW_TypeCode,
        ROW_NUMBER() OVER (PARTITION BY DD.DISPLAY_STRING ORDER BY TL.GW_TypeCode) AS RN
    FROM (SELECT DISTINCT DISPLAY_STRING FROM SourceStaging.VECCASRN.VEC_GW_TPTYPE WHERE DISPLAY_STRING IS NOT NULL) DD
    INNER JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
        ON TL.TypeList_Name = 'ClaimantType' AND TL.Vectus_TypeCode LIKE '%' + DD.DISPLAY_STRING + '%'
),
COVERAGE_PRIORITY AS (
    SELECT ClaimPublicID, Type, PublicID,
        ROW_NUMBER() OVER (PARTITION BY ClaimPublicID, Type
            ORDER BY CASE WHEN VEC_GMP_COVERAGEID IS NOT NULL THEN 1 ELSE 2 END, PublicID ASC) AS RN
    FROM IntermediateStaging_DEV.dbo.IS_COVERAGE
    WHERE Subtype = 'VehicleCoverage'
),
CIL_TOTALS AS (
    SELECT PT.GW_HDR_CASEID, SUM(PD.AMOUNT) AS TotalCIL
    FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS PD ON PD.GW_PAY_TRAN_ID = PT.ID
    WHERE PD.CODE IN ('CIL','CIP')
    GROUP BY PT.GW_HDR_CASEID
),
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
),
HIRE_ENRICHED AS (
    SELECT
        H.CLAIM_REF, H.ClaimPublicID, H.GW_HDR_CASEID, H.TP_ID,
        R.ExposureType, R.PrimaryCoverage, R.CoverageSubType, R.LossParty,
        CP.PublicID AS CoverageID,
        CM.PublicID AS ClaimantDenormID,
        ISNULL(TL_EXACT.GW_TypeCode, ISNULL(CTL.GW_TypeCode, 'other')) AS ClaimantTypeResolved,
        LIAB_TL.GW_TypeCode AS LiabilityPositionResolved,
        CASE WHEN HCS.STATUS = 'Finalised' THEN 'closed'
             WHEN HSD.CASEID IS NOT NULL THEN 'closed'
             ELSE 'open'
        END AS ResolvedState,
        CASE WHEN HSD.CASEID IS NOT NULL THEN CONVERT(DATETIME2(7), CONCAT(HSD.CREATEDATE, ' ', HSD.CREATETIME)) ELSE NULL END AS ResolvedCloseDate,
        CIL.TotalCIL
    FROM TP_HIRE_CANDIDATES H
    INNER JOIN dbo.LKP_EXPOSURE_MOTOR_RULES R ON R.RuleKey = 'TP_HIRE' AND R.V2CaseFlow = 'GW MOTOR TP'
    LEFT JOIN COVERAGE_PRIORITY CP ON CP.ClaimPublicID = H.ClaimPublicID AND CP.Type = R.PrimaryCoverage AND CP.RN = 1
    LEFT JOIN IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR CM ON CM.GW_HDR_CASEID = H.GW_HDR_CASEID AND CM.HDR_TYPE_ID = 55
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR_TYPE HT ON HT.ID = CM.HDR_TYPE_ID AND HT.PRIMCONT_TYPE = 'Y'
    LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL_EXACT
        ON TL_EXACT.TypeList_Name = 'ClaimantType' AND TL_EXACT.Vectus_TypeCode = H.ClaimantRoleDesc
    LEFT JOIN CLAIMANT_TYPE_LOOKUP CTL ON CTL.DISPLAY_STRING = H.ClaimantRoleDesc AND CTL.RN = 1
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_LIABILITY LIAB ON LIAB.CASEID = H.TP_ID AND LIAB.CURRENT_REC = 'X'
    LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING LIAB_TL ON LIAB_TL.Vectus_TypeCode = LIAB.LIAB_STATUS AND LIAB_TL.TypeList_Name = 'LiabilityPosition_Adm'
    LEFT JOIN HIRE_CASE_STATUS HCS ON HCS.CASEID = H.TP_ID
    LEFT JOIN HIRE_SETTLED_DETAIL HSD ON HSD.CASEID = H.TP_ID
    LEFT JOIN CIL_TOTALS CIL ON CIL.GW_HDR_CASEID = H.GW_HDR_CASEID
)
INSERT INTO IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
(PublicID, ClaimID, VectusCaseID_Adm, GW_HDR_CASEID, SourceOrigin_Adm, ExposureType, PrimaryCoverage,
 CoverageSubType, LossParty, ClaimOrder, CreateTime, CLAIM_REF, ClaimantType,
 CoverageID, IncidentID, ClaimantDenormID, AssignmentStatus, BIReservePercentage_Adm,
 RIGroupSetExternally, State, SupplementalWorkloadWeight, WorkloadWeight,
 CILFigure_Adm, CILNotes_Adm, CloseDate, LiabilityPosition_Adm)
SELECT
    'mig:exp:tphire:' + EN.ClaimPublicID + '_' + CONVERT(VARCHAR(64), EN.TP_ID),
    EN.ClaimPublicID, CONVERT(VARCHAR(64), EN.TP_ID), EN.GW_HDR_CASEID, 'TP_HIRE',
    EN.ExposureType, EN.PrimaryCoverage, EN.CoverageSubType, EN.LossParty,
    0,
    (SELECT CONVERT(DATETIME2(7), CONCAT(VC.CREATE_DATE, ' ', VC.CREATE_TIME))
     FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = EN.TP_ID),
    EN.CLAIM_REF, EN.ClaimantTypeResolved,
    EN.CoverageID, NULL, EN.ClaimantDenormID,
    'assigned', 100, 0,
    EN.ResolvedState,
    0, 0,
    EN.TotalCIL, CASE WHEN EN.TotalCIL IS NOT NULL THEN 'CIL' END,
    EN.ResolvedCloseDate,
    EN.LiabilityPositionResolved
FROM HIRE_ENRICHED EN;


/* ================================================================
   BLOCK D: 1st Party PA Ancillary — single INSERT...SELECT
   ================================================================ */
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
COVERAGE_PRIORITY AS (
    SELECT ClaimPublicID, Type, PublicID,
        ROW_NUMBER() OVER (PARTITION BY ClaimPublicID, Type
            ORDER BY CASE WHEN VEC_GMP_COVERAGEID IS NOT NULL THEN 1 ELSE 2 END, PublicID ASC) AS RN
    FROM IntermediateStaging_DEV.dbo.IS_COVERAGE
    WHERE Subtype = 'VehicleCoverage'
),
CIL_TOTALS AS (
    SELECT PT.GW_HDR_CASEID, SUM(PD.AMOUNT) AS TotalCIL
    FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
    INNER JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS PD ON PD.GW_PAY_TRAN_ID = PT.ID
    WHERE PD.CODE IN ('CIL','CIP')
    GROUP BY PT.GW_HDR_CASEID
),
PA_ENRICHED AS (
    SELECT
        PC.CLAIM_REF, PC.ClaimPublicID, PC.GW_HDR_CASEID, PC.PA_ID,
        R.ExposureType, R.PrimaryCoverage, R.CoverageSubType, R.LossParty,
        CP.PublicID AS CoverageID,
        CC.ContactID AS ClaimantDenormID,
        ISNULL(STATE_TL.GW_TypeCode, 'draft') AS ResolvedState,
        CS.STATUS AS CaseStatusRaw,
        CS.RECORD_DATE AS CaseRecordDate,
        CIL.TotalCIL
    FROM PA_COV_CHECK PC
    INNER JOIN dbo.LKP_EXPOSURE_MOTOR_RULES R ON R.V2CaseFlow = 'GW PI ANCILLARY' AND R.RuleKey = CASE WHEN PC.HasPlusCov = 1 THEN 'PA_PLUS' ELSE 'PA_STD' END
    LEFT JOIN COVERAGE_PRIORITY CP ON CP.ClaimPublicID = PC.ClaimPublicID AND CP.Type = R.PrimaryCoverage AND CP.RN = 1
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACTROLE CCR ON CCR.Role = 'insured'
    LEFT JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC ON CC.PublicID = CCR.ClaimContactID AND CC.ClaimID = PC.ClaimPublicID
    LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS ON CS.CASEID = PC.PA_ID AND CS.GCURRENT = 'X'
    LEFT JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING STATE_TL ON STATE_TL.Vectus_TypeCode = CS.STATUS AND STATE_TL.TypeList_Name = 'ExposureState'
    LEFT JOIN CIL_TOTALS CIL ON CIL.GW_HDR_CASEID = PC.GW_HDR_CASEID
)
INSERT INTO IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
(PublicID, ClaimID, VectusCaseID_Adm, GW_HDR_CASEID, SourceOrigin_Adm, ExposureType, PrimaryCoverage,
 CoverageSubType, LossParty, ClaimOrder, CreateTime, CLAIM_REF, ClaimantType,
 CoverageID, IncidentID, ClaimantDenormID, AssignmentStatus, BIReservePercentage_Adm,
 RIGroupSetExternally, State, SupplementalWorkloadWeight, WorkloadWeight,
 CILFigure_Adm, CILNotes_Adm, CloseDate)
SELECT
    'mig:exp:pa:' + EN.ClaimPublicID + '_' + CONVERT(VARCHAR(64), EN.PA_ID),
    EN.ClaimPublicID, CONVERT(VARCHAR(64), EN.PA_ID), EN.GW_HDR_CASEID, 'PA',
    EN.ExposureType, EN.PrimaryCoverage, EN.CoverageSubType, EN.LossParty,
    0,
    (SELECT CONVERT(DATETIME2(7), CONCAT(VC.CREATE_DATE, ' ', VC.CREATE_TIME))
     FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = EN.PA_ID),
    EN.CLAIM_REF, 'insured',
    EN.CoverageID, NULL, EN.ClaimantDenormID,
    'assigned', 100, 0,
    EN.ResolvedState,
    0, 0,
    EN.TotalCIL, CASE WHEN EN.TotalCIL IS NOT NULL THEN 'CIL' END,
    CASE WHEN EN.ResolvedState = 'closed' AND EN.CaseStatusRaw = 'Finalised' THEN EN.CaseRecordDate ELSE NULL END
FROM PA_ENRICHED EN;

END
GO


/* =====================================================================
   3. VALIDATION / FAN-OUT QUERIES (unchanged from v20 - all read the
   final table state, unaffected by the UPDATE-to-SELECT restructure)
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

SELECT E.PublicID, E.PrimaryCoverage,
    CASE WHEN COV.VEC_GMP_COVERAGEID IS NOT NULL THEN 'coverage' ELSE 'inclusion (fallback)' END AS resolved_via
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E
INNER JOIN IntermediateStaging_DEV.dbo.IS_COVERAGE COV ON COV.PublicID = E.CoverageID;

SELECT SourceOrigin_Adm, COUNT(*) AS total, SUM(CASE WHEN IncidentID IS NULL THEN 1 ELSE 0 END) AS null_incidents
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
GROUP BY SourceOrigin_Adm;

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
