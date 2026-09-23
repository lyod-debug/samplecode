USE [IntermediateStaging_DEV]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[usp_Load_IS_CLAIMCONTACTROLE]
AS
BEGIN
/* FIXED: was truncating TS_CLAIMCONTACTROLE, a different table than the
   one the final INSERT writes to (IS_CLAIMCONTACTROLE) - every run would
   have accumulated on top of the last one instead of replacing it. */
TRUNCATE TABLE [IntermediateStaging_DEV].dbo.IS_CLAIMCONTACTROLE;

IF OBJECT_ID('tempdb..#BASE_CONTACT_ROLE') IS NOT NULL DROP TABLE #BASE_CONTACT_ROLE;
IF OBJECT_ID('tempdb..#BASE_CONTACT_ROLE_MOTOR') IS NOT NULL DROP TABLE #BASE_CONTACT_ROLE_MOTOR;
IF OBJECT_ID('tempdb..#LKP_ROLES') IS NOT NULL DROP TABLE #LKP_ROLES;
IF OBJECT_ID('tempdb..#LKP_ROLES_MOTOR') IS NOT NULL DROP TABLE #LKP_ROLES_MOTOR;
IF OBJECT_ID('tempdb..#MOTOR_EXPOSURE_BY_CASE') IS NOT NULL DROP TABLE #MOTOR_EXPOSURE_BY_CASE;
IF OBJECT_ID('tempdb..#MOTOR_INCIDENT_BY_CASE') IS NOT NULL DROP TABLE #MOTOR_INCIDENT_BY_CASE;
IF OBJECT_ID('tempdb..#MOTOR_TP_CLAIMANT_CONTACT') IS NOT NULL DROP TABLE #MOTOR_TP_CLAIMANT_CONTACT;

/* =========================================================================
   HOUSEHOLD - syntax corrected only. New ExposureID/IncidentID/claimant
   logic NOT built here yet - per your instruction, Household waits for
   the VEC_GW_CFLINK_TYPE (HH)-Role sheet. ExposureID/IncidentID stay
   NULL here for now, exactly as in the original half-built version.
   ========================================================================= */
SELECT
    CLM.PublicID AS ClaimPublicID, CC.PublicID AS ClaimContactID, C.PublicID AS ContactPublicID, C.HDR_ID, C.GW_HDR_CASEID,
    C.CLAIM_REF, C.HDR_TYPE_ID, HDR_TYPE.HDR_TYPE, C.LINK_TYPE_ID, CFLINK_TYPE.LINK_TYPE, RSK.COVERABLE_TYPE AS RISKUNIT_COVERABLE_TYPE,
    'Household' AS PRODUCT
INTO #BASE_CONTACT_ROLE
FROM [IntermediateStaging_DEV].dbo.CONTACT_MASTER_HOUSEHOLD C
INNER JOIN [IntermediateStaging_DEV].dbo.IS_CLAIM_MASTER CLM ON C.GW_HDR_CASEID = CLM.GW_HDR_CASEID
INNER JOIN [IntermediateStaging_DEV].dbo.IS_CLAIMCONTACT CC ON CC.ContactID = C.PublicID AND CC.ClaimID = CLM.PublicID
LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR ON CLM.GW_HDR_CASEID = SR.GW_HDR_CASEID
LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR HDR ON HDR.ID = C.HDR_ID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR_TYPE HDR_TYPE ON HDR_TYPE.ID = HDR.GWCONTH_TYPEID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK CF_LINK ON CF_LINK.ID = C.LINK_ID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CFLINK_TYPE CFLINK_TYPE ON C.LINK_TYPE_ID = CFLINK_TYPE.ID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'HOUSEHOLD';

CREATE NONCLUSTERED INDEX IX_BCR ON #BASE_CONTACT_ROLE (HDR_TYPE_ID, LINK_TYPE_ID);

SELECT
    B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE, B.RISKUNIT_COVERABLE_TYPE, LKP.Link_to_Policy, B.ClaimPublicID, B.ContactPublicID,
    B.HDR_ID, B.CLAIM_REF, 1 AS Active, B.ClaimContactID AS ClaimContactID, NULL AS ExposureID, NULL AS IncidentID,
    CASE WHEN LKP.Link_to_Policy = 'YES' THEN B.ClaimPublicID ELSE NULL END AS PolicyID, LKP.GWCC_Role_TYPECODE AS Role, 'Household' AS PRODUCT
INTO #LKP_ROLES
FROM #BASE_CONTACT_ROLE B
LEFT JOIN dbo.CLAIM_CONTACT_ROLE_LOOKUP LKP
    ON LKP.PRODUCT = 'Household'
    AND LKP.HDR_TYPEID = B.HDR_TYPE_ID
    AND LKP.LINK_TYPEID = B.LINK_TYPE_ID
    AND (
        LKP.RISKUNIT_COVERABLE_TYPE = B.RISKUNIT_COVERABLE_TYPE
        OR (
            LKP.RISKUNIT_COVERABLE_TYPE IS NULL
            AND NOT EXISTS (
                SELECT 1
                FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP X
                WHERE X.PRODUCT = LKP.PRODUCT
                AND X.HDR_TYPEID = LKP.HDR_TYPEID
                AND X.LINK_TYPEID = LKP.LINK_TYPEID
                AND X.RISKUNIT_COVERABLE_TYPE = B.RISKUNIT_COVERABLE_TYPE
            )
        )
    );

CREATE NONCLUSTERED INDEX IX_LKP ON #LKP_ROLES (HDR_TYPE_ID);


/* =========================================================================
   MOTOR - syntax corrected, and CASEID added to the base select (needed
   below to tie a contact to its SPECIFIC V2 sub-case - AD_ID/TP_ID/PA_ID -
   not just the whole claim; the original select never captured this).
   ========================================================================= */
SELECT
    CLM.PublicID AS ClaimPublicID, CC.PublicID AS ClaimContactID, C.PublicID AS ContactPublicID, C.HDR_ID, C.GW_HDR_CASEID, C.CLAIM_REF,
    C.HDR_TYPE_ID, HDR_TYPE.HDR_TYPE, C.LINK_TYPE_ID, CFLINK_TYPE.LINK_TYPE,
    RSK.COVERABLE_TYPE AS RISKUNIT_COVERABLE_TYPE,
    HDR.CASEID AS V2_SubCaseID,   -- ADDED: the specific AD/TP/PA case this contact's folder belongs to
    'Motor' AS PRODUCT
INTO #BASE_CONTACT_ROLE_MOTOR
FROM [IntermediateStaging_DEV].dbo.CONTACT_MASTER_MOTOR C
INNER JOIN [IntermediateStaging_DEV].dbo.IS_CLAIM_MASTER CLM ON C.GW_HDR_CASEID = CLM.GW_HDR_CASEID AND UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
INNER JOIN [IntermediateStaging_DEV].dbo.IS_CLAIMCONTACT CC ON CC.ContactID = C.PublicID AND CC.ClaimID = CLM.PublicID
LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR ON CLM.GW_HDR_CASEID = SR.GW_HDR_CASEID
LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR HDR ON HDR.ID = C.HDR_ID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR_TYPE HDR_TYPE ON HDR_TYPE.ID = HDR.GWCONTH_TYPEID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_LINK CF_LINK ON CF_LINK.ID = C.LINK_ID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CFLINK_TYPE CFLINK_TYPE ON C.LINK_TYPE_ID = CFLINK_TYPE.ID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR';

CREATE NONCLUSTERED INDEX IX_BCRM ON #BASE_CONTACT_ROLE_MOTOR (HDR_TYPE_ID, LINK_TYPE_ID);
CREATE NONCLUSTERED INDEX IX_BCRM_CASE ON #BASE_CONTACT_ROLE_MOTOR (V2_SubCaseID);


/* -------------------------------------------------------------------------
   #MOTOR_EXPOSURE_BY_CASE / #MOTOR_INCIDENT_BY_CASE: one deterministically
   picked exposure and incident per V2 sub-case, for ordinary (non-claimant)
   roles. Per BA: "if more than one exposure/incident exists for the case,
   it is sufficient to link to only one" - MIN() makes this the SAME one
   every time the proc re-runs, not an arbitrary pick that changes.
   ------------------------------------------------------------------------- */
SELECT
    VectusCaseID_Adm AS V2_SubCaseID,
    MIN(Exposure_Motor_PublicID) AS PickedExposureID
INTO #MOTOR_EXPOSURE_BY_CASE
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
GROUP BY VectusCaseID_Adm;

CREATE UNIQUE CLUSTERED INDEX CIX_MEBC ON #MOTOR_EXPOSURE_BY_CASE (V2_SubCaseID);

-- Picked separately from ExposureID, since a case's picked exposure might
-- itself have a NULL IncidentID (e.g. a real incident-proc gap) while a
-- different exposure from the same case does have one.
SELECT
    VectusCaseID_Adm AS V2_SubCaseID,
    MIN(IncidentID) AS PickedIncidentID
INTO #MOTOR_INCIDENT_BY_CASE
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR
WHERE IncidentID IS NOT NULL
GROUP BY VectusCaseID_Adm;

CREATE UNIQUE CLUSTERED INDEX CIX_MIBC ON #MOTOR_INCIDENT_BY_CASE (V2_SubCaseID);


SELECT
    B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE, B.RISKUNIT_COVERABLE_TYPE, LKP.Link_to_Policy, B.ClaimPublicID,
    B.ContactPublicID, B.HDR_ID, B.CLAIM_REF, 1 AS Active, B.ClaimContactID AS ClaimContactID,
    /* FIXED: real ExposureID/IncidentID, driven by the lookup's own flags -
       was hardcoded NULL in the half-built version */
    CASE WHEN LKP.Link_to_Exposure = 'YES' THEN EBC.PickedExposureID ELSE NULL END AS ExposureID,
    CASE WHEN LKP.Link_to_Incident = 'YES' THEN IBC.PickedIncidentID ELSE NULL END AS IncidentID,
    CASE WHEN LKP.Link_to_Policy = 'YES' THEN B.ClaimPublicID ELSE NULL END AS PolicyID,
    LKP.GWCC_Role_TYPECODE AS Role, 'Motor' AS PRODUCT
INTO #LKP_ROLES_MOTOR
FROM #BASE_CONTACT_ROLE_MOTOR B
LEFT JOIN dbo.CLAIM_CONTACT_ROLE_LOOKUP LKP
    ON LKP.PRODUCT = 'Motor'
    AND LKP.HDR_TYPEID = B.HDR_TYPE_ID
    AND LKP.LINK_TYPEID = B.LINK_TYPE_ID
    AND (
        LKP.RISKUNIT_COVERABLE_TYPE = B.RISKUNIT_COVERABLE_TYPE
        OR (
            LKP.RISKUNIT_COVERABLE_TYPE IS NULL
            AND NOT EXISTS (
                SELECT 1
                FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP X
                WHERE X.PRODUCT = LKP.PRODUCT
                AND X.HDR_TYPEID = LKP.HDR_TYPEID
                AND X.LINK_TYPEID = LKP.LINK_TYPEID
                AND X.RISKUNIT_COVERABLE_TYPE = B.RISKUNIT_COVERABLE_TYPE
            )
        )
    )
LEFT JOIN #MOTOR_EXPOSURE_BY_CASE EBC ON EBC.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
LEFT JOIN #MOTOR_INCIDENT_BY_CASE IBC ON IBC.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID);

CREATE NONCLUSTERED INDEX IX_LKPM ON #LKP_ROLES_MOTOR (HDR_TYPE_ID);


/* -------------------------------------------------------------------------
   #MOTOR_TP_CLAIMANT_CONTACT: for each real TP case, the ONE contact who
   is its claimant - reusing the exact Link_to_Exposure='YES' approach
   already verified in the exposure proc's own contact logic. Confirmed
   earlier in this project: every real TP case has exactly one real
   person tied to it, so there is no ambiguity to resolve here.
   ------------------------------------------------------------------------- */
SELECT
    B.V2_SubCaseID,
    B.ClaimContactID
INTO #MOTOR_TP_CLAIMANT_CONTACT
FROM #BASE_CONTACT_ROLE_MOTOR B
INNER JOIN dbo.CLAIM_CONTACT_ROLE_LOOKUP LKP
    ON LKP.PRODUCT = 'Motor'
    AND LKP.HDR_TYPEID = B.HDR_TYPE_ID
    AND LKP.LINK_TYPEID = B.LINK_TYPE_ID
    AND LKP.Link_to_Exposure = 'YES'
WHERE B.HDR_TYPE_ID = 55;   -- Third Party only

CREATE UNIQUE CLUSTERED INDEX CIX_MTPCC ON #MOTOR_TP_CLAIMANT_CONTACT (V2_SubCaseID);


;WITH
MANDATORY_INSURED_ROLE AS (
    SELECT B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE, B.RISKUNIT_COVERABLE_TYPE,
    'YES' AS Link_to_Policy, B.ClaimPublicID, B.ContactPublicID, B.HDR_ID, B.CLAIM_REF, 1 AS Active, B.ClaimContactID,
    NULL AS ExposureID, NULL AS IncidentID, B.ClaimPublicID AS PolicyID, 'insured' AS Role, 'Household' AS PRODUCT
    FROM #LKP_ROLES B
    WHERE B.HDR_TYPE_ID = 113
),
MANDATORY_REPORTER_ROLE AS (
    SELECT B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE, B.RISKUNIT_COVERABLE_TYPE,
    'NO' AS Link_to_Policy, B.ClaimPublicID, B.ContactPublicID, B.HDR_ID, B.CLAIM_REF, 1 AS Active, B.ClaimContactID,
    NULL AS ExposureID, NULL AS IncidentID, NULL AS PolicyID, 'reporter' AS Role, 'Household' AS PRODUCT
    FROM #LKP_ROLES B
    WHERE B.HDR_TYPE_ID = 113
),
MANDATORY_INSURED_ROLE_MOTOR AS (
    SELECT B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE, B.RISKUNIT_COVERABLE_TYPE, 'YES' AS Link_to_Policy,
    B.ClaimPublicID, B.ContactPublicID, B.HDR_ID, B.CLAIM_REF, 1 AS Active, B.ClaimContactID, NULL AS ExposureID,
    NULL AS IncidentID, B.ClaimPublicID AS PolicyID, 'insured' AS Role, 'Motor' AS PRODUCT
    FROM #LKP_ROLES_MOTOR B
    WHERE B.HDR_TYPE_ID = 44
),
MANDATORY_REPORTER_ROLE_MOTOR AS (
    SELECT B.HDR_TYPE_ID, B.HDR_TYPE, B.LINK_TYPE_ID, B.LINK_TYPE, B.RISKUNIT_COVERABLE_TYPE,
    'NO' AS Link_to_Policy, B.ClaimPublicID, B.ContactPublicID, B.HDR_ID, B.CLAIM_REF, 1 AS Active, B.ClaimContactID, NULL AS ExposureID,
    NULL AS IncidentID, NULL AS PolicyID, 'reporter' AS Role, 'Motor' AS PRODUCT
    FROM #LKP_ROLES_MOTOR B
    WHERE B.HDR_TYPE_ID = 44
),
/* -------------------------------------------------------------------------
   MANDATORY_CLAIMANT_ROLE_MOTOR: NEW. One row PER REAL EXPOSURE, not per
   contact - per BA's own words, a contact who is claimant on more than
   one exposure gets a separate record for each. 1st-party exposures
   (AD/PA/PA_PLUS) always claim the HDR_TYPE_ID=44 contact. 3rd-party
   exposures (TP_VEH/TP_INJ/TP_PRO/TP_HIRE) claim the one real contact
   tied to that specific TP case (#MOTOR_TP_CLAIMANT_CONTACT above).
   PolicyID and IncidentID are NEVER populated for claimant - BA is
   explicit: "I expect the exposure to be populated, not the incident,
   not the policy."
   ------------------------------------------------------------------------- */
MANDATORY_CLAIMANT_ROLE_MOTOR AS (
    SELECT
        44 AS HDR_TYPE_ID, 'Policy Holder' AS HDR_TYPE, NULL AS LINK_TYPE_ID, NULL AS LINK_TYPE, NULL AS RISKUNIT_COVERABLE_TYPE,
        'NO' AS Link_to_Policy, EXP.ClaimID AS ClaimPublicID, B.ContactPublicID, B.HDR_ID, EXP.CLAIM_REF, 1 AS Active,
        B.ClaimContactID, EXP.Exposure_Motor_PublicID AS ExposureID, NULL AS IncidentID, NULL AS PolicyID,
        'claimant' AS Role, 'Motor' AS PRODUCT
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
    INNER JOIN #BASE_CONTACT_ROLE_MOTOR B
        ON B.ClaimPublicID = EXP.ClaimID AND B.HDR_TYPE_ID = 44
    WHERE EXP.SourceOrigin_Adm IN ('AD', 'PA', 'PA_PLUS')

    UNION ALL

    SELECT
        55 AS HDR_TYPE_ID, 'Third Party' AS HDR_TYPE, NULL AS LINK_TYPE_ID, NULL AS LINK_TYPE, NULL AS RISKUNIT_COVERABLE_TYPE,
        'NO' AS Link_to_Policy, EXP.ClaimID AS ClaimPublicID, B.ContactPublicID, B.HDR_ID, EXP.CLAIM_REF, 1 AS Active,
        TPC.ClaimContactID, EXP.Exposure_Motor_PublicID AS ExposureID, NULL AS IncidentID, NULL AS PolicyID,
        'claimant' AS Role, 'Motor' AS PRODUCT
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
    INNER JOIN #MOTOR_TP_CLAIMANT_CONTACT TPC
        ON TPC.V2_SubCaseID = CONVERT(VARCHAR(64), EXP.VectusCaseID_Adm)
    INNER JOIN #BASE_CONTACT_ROLE_MOTOR B
        ON B.ClaimContactID = TPC.ClaimContactID
    WHERE EXP.SourceOrigin_Adm IN ('TP_VEH', 'TP_INJ', 'TP_PRO', 'TP_HIRE')
),
FINAL_ROLE AS (
    SELECT * FROM #LKP_ROLES
    UNION ALL SELECT * FROM MANDATORY_INSURED_ROLE
    UNION ALL SELECT * FROM MANDATORY_REPORTER_ROLE
    UNION ALL SELECT * FROM #LKP_ROLES_MOTOR
    UNION ALL SELECT * FROM MANDATORY_INSURED_ROLE_MOTOR
    UNION ALL SELECT * FROM MANDATORY_REPORTER_ROLE_MOTOR
    UNION ALL SELECT * FROM MANDATORY_CLAIMANT_ROLE_MOTOR
),
DEDUP_ROLE AS (
    /* Unaffected by the claimant addition: since ExposureID differs
       across a contact's multiple exposures, each claimant row lands in
       its own partition here and none get collapsed - exactly the
       "separate record for each exposure" behavior BA described. */
    SELECT
        ROW_NUMBER() OVER (
            PARTITION BY ClaimContactID, Role, ISNULL(PolicyID,''), ISNULL(ExposureID,''), ISNULL(IncidentID,'')
            ORDER BY ClaimContactID
        ) AS RN,
        /* NEW: disambiguates PublicID for the ONE case where a single
           contact legitimately gets more than one row for the same Role -
           claimant, across several exposures. For every other role this
           is always 1 (harmless), since dedup above already guarantees
           at most one row per (ClaimContactID, Role, Policy/Exposure/
           IncidentID) combination. */
        ROW_NUMBER() OVER (
            PARTITION BY ClaimContactID, Role
            ORDER BY ISNULL(ExposureID,''), ISNULL(PolicyID,''), ISNULL(IncidentID,'')
        ) AS RoleSeq,
        *
    FROM FINAL_ROLE
)
INSERT INTO [IntermediateStaging_DEV].[dbo].[IS_CLAIMCONTACTROLE] (
    [PublicID], [LUWID], [Active], [ClaimContactID], [ExposureID], [IncidentID], [PolicyID], [Role]
)
SELECT
    /* FIXED: appends RoleSeq only when it's needed (RoleSeq > 1) - the
       very first / only row for a given (ClaimContactID, Role) keeps the
       original, unchanged PublicID format, so every existing role's
       PublicID is byte-for-byte identical to before. Only a SECOND (or
       further) claimant row for the same contact gets a distinguishing
       suffix, avoiding the collision. */
    CASE WHEN PRODUCT = 'Household' THEN 'mig:hhccr' WHEN PRODUCT = 'Motor' THEN 'mig:motorccr' END
        + CONVERT(varchar(64), HDR_ID) + '_' + Role
        + CASE WHEN RoleSeq > 1 THEN '_' + CONVERT(varchar(10), RoleSeq) ELSE '' END AS PublicID,
    CLAIM_REF AS LUWID,
    Active,
    ClaimContactID,
    ExposureID,
    IncidentID,
    PolicyID,
    Role
FROM DEDUP_ROLE
WHERE RN = 1;

DROP TABLE #BASE_CONTACT_ROLE;
DROP TABLE #BASE_CONTACT_ROLE_MOTOR;
DROP TABLE #LKP_ROLES;
DROP TABLE #LKP_ROLES_MOTOR;
DROP TABLE #MOTOR_EXPOSURE_BY_CASE;
DROP TABLE #MOTOR_INCIDENT_BY_CASE;
DROP TABLE #MOTOR_TP_CLAIMANT_CONTACT;
END;
GO
