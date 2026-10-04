/* =====================================================================================
   INTERNAL CHECK (do NOT send to BA) - MOTOR - A CASE EXISTS BUT NO EXPOSURE WAS CREATED
   Read-only. Nothing is changed or deleted.

   PART A  Third-party cases     (VEC_GW_MOTOR_TP.ID)       -> exposures TP_VEH / TP_INJ / TP_PRO / TP_HIRE
   PART B  First-party AD cases  (VEC_GW_MOTOR_AD.ID)       -> exposure  AD
   PART C  First-party PA cases  (VEC_PA_ANCILLARY.ID)      -> exposure  PA
   PART D  Summary of all three

   How it works: the same joins as the exposure proc (usp_Load_IS_EXPOSURE_MOTOR, blocks A-D) are tested ONE BY ONE.
   Every case that has a claim in IS_CLAIM_MASTER (PRODUCT = MOTOR) but NO row in IS_EXPOSURE_MOTOR gets the FIRST join / rule that removes it
   (the INNER JOINs of the exposure proc remove a case silently). "By design" reasons are marked so you can tell them from real gaps.

   Created exposure of a case = IS_EXPOSURE_MOTOR.VectusCaseID_Adm = case ID and SourceOrigin_Adm of that kind
   (TP_*: TP.ID, AD: AD_ID, PA: PA_ID). The exposure proc writes these hard-coded origin values.
   Tables read (all exist in the exposure proc): VEC_GW_MOTOR_TP, VEC_GW_TP_SUMMARY, VEC_GW_TPTYPE, VEC_GW_HIREREC, VEC_GW_PAY_TRANS, VEC_GW_PAY_DISS,
   VEC_GW_MOTOR_AD, MOTOR_AD_DUPLICATE_LOOKUP, VEC_GW_VEHICLE, VEC_GW_CIRCS_INC, VEC_PA_ANCILLARY, VEC_GWP_SLCTD_RISK, VEC_GWP_RISKUNIT, VEC_GWP_COVERAGE,
   VEC_CASE, VEC_GW_CASE_STATUS, LKP_EXPOSURE_MOTOR_RULES.
   If the exposure proc is changed later, change the matching test here (each test says which join of the proc it copies).
   ===================================================================================== */
USE IntermediateStaging_DEV;
GO

/* ============================ PART A - THIRD-PARTY CASES ============================ */
IF OBJECT_ID('tempdb..#TP_FLAGS') IS NOT NULL DROP TABLE #TP_FLAGS;
IF OBJECT_ID('tempdb..#TP_RES')   IS NOT NULL DROP TABLE #TP_RES;

/* one row per TP case that belongs to a MOTOR claim (exposure proc block B/C: IS_CLAIM_MASTER join VEC_GW_MOTOR_TP on GW_HDR_CASEID) */
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.PublicID AS ClaimPublicID, CLM.GW_HDR_CASEID, TP.ID AS TP_ID,
       /* block B: VEC_GW_TP_SUMMARY (INNER) and VEC_GW_TPTYPE (INNER) */
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY S WHERE S.CASEID = TP.ID) THEN 1 ELSE 0 END AS HasSummary,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY S
                         JOIN SourceStaging.VECCASRN.VEC_GW_TPTYPE T ON T.ID = S.GW_TP_TYPEID WHERE S.CASEID = TP.ID) THEN 1 ELSE 0 END AS HasSummaryAndType,
       /* the elements of block B (same tests as TP_ELEMENTS) - only summary rows that also have a TPTYPE count, like the proc */
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY S
                         JOIN SourceStaging.VECCASRN.VEC_GW_TPTYPE T ON T.ID = S.GW_TP_TYPEID
                         WHERE S.CASEID = TP.ID
                           AND (COALESCE(NULLIF(LTRIM(RTRIM(S.VEHICLE)),''),'') = 'X'
                                OR (COALESCE(NULLIF(LTRIM(RTRIM(S.VEHICLE)),''),'')  <> 'X'
                                AND COALESCE(NULLIF(LTRIM(RTRIM(S.INJURY)),''),'')   <> 'X'
                                AND COALESCE(NULLIF(LTRIM(RTRIM(S.PROPERTY)),''),'') <> 'X'))) THEN 1 ELSE 0 END AS ExpectsVEH,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY S
                         JOIN SourceStaging.VECCASRN.VEC_GW_TPTYPE T ON T.ID = S.GW_TP_TYPEID
                         WHERE S.CASEID = TP.ID AND COALESCE(NULLIF(LTRIM(RTRIM(S.INJURY)),''),'') = 'X') THEN 1 ELSE 0 END AS ExpectsINJ,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY S
                         JOIN SourceStaging.VECCASRN.VEC_GW_TPTYPE T ON T.ID = S.GW_TP_TYPEID
                         WHERE S.CASEID = TP.ID AND COALESCE(NULLIF(LTRIM(RTRIM(S.PROPERTY)),''),'') = 'X') THEN 1 ELSE 0 END AS ExpectsPRO,
       /* block C: hire = a hire payment transaction (#HIRE_TRANSACTIONS) OR (a hire record (#HIRE_RECORDS) AND a summary row with VEHICLE = 'X') */
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_PAY_TRANS PT
                         JOIN SourceStaging.VECCASRN.VEC_GW_PAY_DISS PD ON PT.ID = PD.GW_PAY_TRAN_ID
                         WHERE PT.GW_HDR_CASEID = CLM.GW_HDR_CASEID AND PT.CASEID = TP.ID
                           AND PD.CODE IN ('ABH','CDW','DUH','PLH','PLP','RVM','SUB','TEM','TPH','FSC','ABA','ABP'))
                  OR (EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_HIREREC HR WHERE HR.CASEID = TP.ID)
                      AND EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_TP_SUMMARY S WHERE S.CASEID = TP.ID AND S.VEHICLE = 'X'))
            THEN 1 ELSE 0 END AS ExpectsHIRE,
       /* joins every block needs */
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = TP.ID) THEN 1 ELSE 0 END AS HasVecCase,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS WHERE CS.CASEID = TP.ID AND CS.GCURRENT = 'X') THEN 1 ELSE 0 END AS HasCurrentStatus,
       /* rule rows (INNER JOIN to LKP_EXPOSURE_MOTOR_RULES, V2CaseFlow 'GW MOTOR TP') */
       CASE WHEN EXISTS (SELECT 1 FROM dbo.LKP_EXPOSURE_MOTOR_RULES R WHERE R.V2CaseFlow = 'GW MOTOR TP' AND R.RuleKey = 'TP_VEH')  THEN 1 ELSE 0 END AS RuleVEH,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.LKP_EXPOSURE_MOTOR_RULES R WHERE R.V2CaseFlow = 'GW MOTOR TP' AND R.RuleKey = 'TP_INJ')  THEN 1 ELSE 0 END AS RuleINJ,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.LKP_EXPOSURE_MOTOR_RULES R WHERE R.V2CaseFlow = 'GW MOTOR TP' AND R.RuleKey = 'TP_PRO')  THEN 1 ELSE 0 END AS RulePRO,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.LKP_EXPOSURE_MOTOR_RULES R WHERE R.V2CaseFlow = 'GW MOTOR TP' AND R.RuleKey = 'TP_HIRE') THEN 1 ELSE 0 END AS RuleHIRE
INTO #TP_FLAGS
FROM dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_TP TP ON TP.GW_HDR_CASEID = CLM.GW_HDR_CASEID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR';
CREATE UNIQUE CLUSTERED INDEX IX_TPF ON #TP_FLAGS (TP_ID);   -- if this fails, one TP.ID appears for two claims: tell me, that is a finding itself

/* what was actually created per TP case */
IF OBJECT_ID('tempdb..#TP_CREATED') IS NOT NULL DROP TABLE #TP_CREATED;
SELECT CONVERT(VARCHAR(64), E.VectusCaseID_Adm) AS TP_ID,
       MAX(CASE WHEN E.SourceOrigin_Adm = 'TP_VEH'  THEN 1 ELSE 0 END) AS HasVEH,
       MAX(CASE WHEN E.SourceOrigin_Adm = 'TP_INJ'  THEN 1 ELSE 0 END) AS HasINJ,
       MAX(CASE WHEN E.SourceOrigin_Adm = 'TP_PRO'  THEN 1 ELSE 0 END) AS HasPRO,
       MAX(CASE WHEN E.SourceOrigin_Adm = 'TP_HIRE' THEN 1 ELSE 0 END) AS HasHIRE,
       STRING_AGG(CONVERT(VARCHAR(MAX), E.SourceOrigin_Adm), ', ') AS CreatedKinds
INTO #TP_CREATED
FROM dbo.IS_EXPOSURE_MOTOR E
WHERE E.SourceOrigin_Adm IN ('TP_VEH','TP_INJ','TP_PRO','TP_HIRE') AND E.VectusCaseID_Adm IS NOT NULL
GROUP BY CONVERT(VARCHAR(64), E.VectusCaseID_Adm);
CREATE UNIQUE CLUSTERED INDEX IX_TPC ON #TP_CREATED (TP_ID);

/* result per case: expected kinds, created kinds, and the first reason */
SELECT F.ClaimRef, F.ClaimPublicID, F.GW_HDR_CASEID, F.TP_ID,
       CONCAT(CASE WHEN F.ExpectsVEH  = 1 THEN 'TP_VEH '  ELSE '' END, CASE WHEN F.ExpectsINJ = 1 THEN 'TP_INJ ' ELSE '' END,
              CASE WHEN F.ExpectsPRO  = 1 THEN 'TP_PRO '  ELSE '' END, CASE WHEN F.ExpectsHIRE = 1 THEN 'TP_HIRE' ELSE '' END) AS ExpectedKinds,
       ISNULL(C.CreatedKinds, '(none)') AS CreatedKinds,
       CASE WHEN C.TP_ID IS NULL THEN 1 ELSE 0 END AS NoExposureAtAll,
       CASE WHEN (F.ExpectsVEH = 1 AND ISNULL(C.HasVEH,0) = 0) OR (F.ExpectsINJ = 1 AND ISNULL(C.HasINJ,0) = 0)
              OR (F.ExpectsPRO = 1 AND ISNULL(C.HasPRO,0) = 0) OR (F.ExpectsHIRE = 1 AND ISNULL(C.HasHIRE,0) = 0) THEN 1 ELSE 0 END AS SomeExpectedKindMissing,
       CASE
            WHEN F.ExpectsVEH + F.ExpectsINJ + F.ExpectsPRO + F.ExpectsHIRE = 0 AND F.HasSummary = 0
                 THEN 'A1 - no VEC_GW_TP_SUMMARY row for this case, and no hire (TP_VEH / TP_INJ / TP_PRO need the summary row: INNER JOIN)'
            WHEN F.ExpectsVEH + F.ExpectsINJ + F.ExpectsPRO + F.ExpectsHIRE = 0 AND F.HasSummary = 1 AND F.HasSummaryAndType = 0
                 THEN 'A2 - VEC_GW_TP_SUMMARY.GW_TP_TYPEID has no match in VEC_GW_TPTYPE, and no hire (INNER JOIN)'
            WHEN F.ExpectsVEH + F.ExpectsINJ + F.ExpectsPRO + F.ExpectsHIRE = 0
                 THEN 'A3 - the case has no vehicle / injury / property element and no hire: nothing is expected (check the summary row)'
            WHEN F.HasVecCase = 0        THEN 'A4 - no VEC_CASE row for this case (INNER JOIN VC.ID = case ID)'
            WHEN F.HasCurrentStatus = 0  THEN 'A5 - no VEC_GW_CASE_STATUS row with GCURRENT = X for this case (INNER JOIN)'
            WHEN (F.ExpectsVEH = 1 AND F.RuleVEH = 0) OR (F.ExpectsINJ = 1 AND F.RuleINJ = 0) OR (F.ExpectsPRO = 1 AND F.RulePRO = 0) OR (F.ExpectsHIRE = 1 AND F.RuleHIRE = 0)
                 THEN 'A6 - no rule row in LKP_EXPOSURE_MOTOR_RULES (GW MOTOR TP) for an expected kind (INNER JOIN)'
            ELSE 'A7 - every join tested here passes, yet nothing was created: not explained by this file, investigate (is the exposure proc up to date / re-run?)'
       END AS FirstReason
INTO #TP_RES
FROM #TP_FLAGS F
LEFT JOIN #TP_CREATED C ON C.TP_ID = CONVERT(VARCHAR(64), F.TP_ID);

-- A-1. SUMMARY
SELECT COUNT(*) AS TP_CasesOnMotorClaims,
       SUM(CASE WHEN NoExposureAtAll = 0 THEN 1 ELSE 0 END) AS WithAtLeastOneExposure,
       SUM(NoExposureAtAll) AS WithNoExposureAtAll,
       SUM(SomeExpectedKindMissing) AS WithAnExpectedKindMissing
FROM #TP_RES;

-- A-2. cases with NO exposure at all, by reason
SELECT FirstReason, COUNT(*) AS Cases, COUNT(DISTINCT ClaimRef) AS Claims
FROM #TP_RES WHERE NoExposureAtAll = 1 GROUP BY FirstReason ORDER BY Cases DESC;

-- A-3. THE LIST: every TP case with no exposure at all (claim, header case ID, TP case ID, what was expected, reason)
SELECT ClaimRef, GW_HDR_CASEID, TP_ID AS TP_ID_CaseID, ExpectedKinds, CreatedKinds, FirstReason
FROM #TP_RES WHERE NoExposureAtAll = 1 ORDER BY FirstReason, ClaimRef;

-- A-4. cases that DO have an exposure, but an expected kind is missing (for example hire expected, hire not created)
SELECT ClaimRef, GW_HDR_CASEID, TP_ID AS TP_ID_CaseID, ExpectedKinds, CreatedKinds, FirstReason AS ReasonIfAnyJoinFails
FROM #TP_RES WHERE NoExposureAtAll = 0 AND SomeExpectedKindMissing = 1 ORDER BY ClaimRef;
GO


/* ============================ PART B - FIRST-PARTY AD CASES ============================
   Exposure proc block A: AD_ELIGIBLE (duplicate rule) -> IS_CLAIM_MASTER on GW_HDR_CASEID -> VEC_GW_VEHICLE -> VEC_GW_CIRCS_INC (current) ->
   VEC_GWP_SLCTD_RISK -> VEC_GWP_RISKUNIT -> cover-type rule -> LKP_EXPOSURE_MOTOR_RULES ('GW MOTOR AD', RuleKey) -> VEC_CASE -> VEC_GW_CASE_STATUS (current). */
IF OBJECT_ID('tempdb..#AD_FLAGS') IS NOT NULL DROP TABLE #AD_FLAGS;
IF OBJECT_ID('tempdb..#AD_RES')   IS NOT NULL DROP TABLE #AD_RES;

SELECT CLM.CLAIM_REF AS ClaimRef, CLM.PublicID AS ClaimPublicID, CLM.GW_HDR_CASEID, AD.ID AS AD_ID,
       /* AD_ELIGIBLE: not on the duplicate list, or on it with a MIGRATE solution (same text as the exposure proc) */
       CASE WHEN NOT EXISTS (SELECT 1 FROM SourceStaging.dbo.MOTOR_AD_DUPLICATE_LOOKUP DUPE WHERE DUPE.GW_MOTOR_AD_ID = AD.ID)
              OR EXISTS (SELECT 1 FROM SourceStaging.dbo.MOTOR_AD_DUPLICATE_LOOKUP DUPE
                         WHERE DUPE.GW_MOTOR_AD_ID = AD.ID AND DUPE.CLAIM_REF IS NOT NULL AND LTRIM(RTRIM(DUPE.CLAIM_REF)) <> ''
                           AND UPPER(DUPE.Solution) LIKE '%MIGRATE%' AND UPPER(DUPE.Solution) NOT LIKE '%MIGRATE-GROUP%' AND UPPER(DUPE.Solution) NOT LIKE '%DESCOPE%')
            THEN 1 ELSE 0 END AS IsEligible,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_VEHICLE V WHERE V.CASEID = AD.GW_HDR_CASEID) THEN 1 ELSE 0 END AS HasVehicle,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_CIRCS_INC CI WHERE CI.GW_HDR_CASEID = AD.GW_HDR_CASEID AND CI.GCURRENT = 'X') THEN 1 ELSE 0 END AS HasCircs,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR WHERE SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID) THEN 1 ELSE 0 END AS HasSelectedRisk,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR
                         JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
                         WHERE SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID) THEN 1 ELSE 0 END AS HasRiskUnit,
       /* the cover-type rule of AD_CANDIDATES: not 'tpo', and not ('tpft' with a circumstance type other than 5) - at least one combination must survive */
       CASE WHEN EXISTS (SELECT 1
                         FROM SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR
                         JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
                         JOIN SourceStaging.VECCASRN.VEC_GW_CIRCS_INC CI ON CI.GW_HDR_CASEID = AD.GW_HDR_CASEID AND CI.GCURRENT = 'X'
                         WHERE SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID
                           AND LOWER(LTRIM(RTRIM(ISNULL(RSK.COVER_TYPE, '')))) <> 'tpo'
                           AND NOT (LOWER(LTRIM(RTRIM(ISNULL(RSK.COVER_TYPE, '')))) = 'tpft' AND CI.GW_CIRCS_TYPID <> 5)) THEN 1 ELSE 0 END AS PassesCoverTypeRule,
       /* rule row for the RuleKey that the surviving combination gives (AD / AD_VAN / AD_THEFT / AD_VAN_THEFT) */
       CASE WHEN EXISTS (SELECT 1
                         FROM SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR
                         JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
                         JOIN SourceStaging.VECCASRN.VEC_GW_CIRCS_INC CI ON CI.GW_HDR_CASEID = AD.GW_HDR_CASEID AND CI.GCURRENT = 'X'
                         JOIN dbo.LKP_EXPOSURE_MOTOR_RULES R ON R.V2CaseFlow = 'GW MOTOR AD'
                              AND R.RuleKey = CASE WHEN LTRIM(RTRIM(RSK.COVERABLE_TYPE)) = 'PMVan' AND CI.GW_CIRCS_TYPID = 5 THEN 'AD_VAN_THEFT'
                                                   WHEN LTRIM(RTRIM(RSK.COVERABLE_TYPE)) = 'PMVan' THEN 'AD_VAN'
                                                   WHEN CI.GW_CIRCS_TYPID = 5 THEN 'AD_THEFT'
                                                   ELSE 'AD' END
                         WHERE SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID
                           AND LOWER(LTRIM(RTRIM(ISNULL(RSK.COVER_TYPE, '')))) <> 'tpo'
                           AND NOT (LOWER(LTRIM(RTRIM(ISNULL(RSK.COVER_TYPE, '')))) = 'tpft' AND CI.GW_CIRCS_TYPID <> 5)) THEN 1 ELSE 0 END AS HasRuleRow,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = AD.ID) THEN 1 ELSE 0 END AS HasVecCase,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS WHERE CS.CASEID = AD.ID AND CS.GCURRENT = 'X') THEN 1 ELSE 0 END AS HasCurrentStatus
INTO #AD_FLAGS
FROM dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD ON AD.GW_HDR_CASEID = CLM.GW_HDR_CASEID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR';
CREATE UNIQUE CLUSTERED INDEX IX_ADF ON #AD_FLAGS (AD_ID);

SELECT F.ClaimRef, F.ClaimPublicID, F.GW_HDR_CASEID, F.AD_ID,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.IS_EXPOSURE_MOTOR E WHERE E.SourceOrigin_Adm = 'AD' AND CONVERT(VARCHAR(64), E.VectusCaseID_Adm) = CONVERT(VARCHAR(64), F.AD_ID))
            THEN 1 ELSE 0 END AS HasExposure,
       CASE WHEN F.IsEligible = 0         THEN 'B1 (BY DESIGN) - on MOTOR_AD_DUPLICATE_LOOKUP without a MIGRATE solution (duplicate / descoped)'
            WHEN F.HasVehicle = 0         THEN 'B2 - no VEC_GW_VEHICLE row for the claim header case (INNER JOIN VEH.CASEID = GW_HDR_CASEID)'
            WHEN F.HasCircs = 0           THEN 'B3 - no current (GCURRENT = X) VEC_GW_CIRCS_INC row for the claim header case (INNER JOIN)'
            WHEN F.HasSelectedRisk = 0    THEN 'B4 - no VEC_GWP_SLCTD_RISK row for the claim header case (INNER JOIN)'
            WHEN F.HasRiskUnit = 0        THEN 'B5 - selected risk has no matching VEC_GWP_RISKUNIT row (INNER JOIN)'
            WHEN F.PassesCoverTypeRule = 0 THEN 'B6 (BY DESIGN) - cover type rule: cover type is tpo, or tpft without theft circumstance'
            WHEN F.HasRuleRow = 0         THEN 'B7 - no rule row in LKP_EXPOSURE_MOTOR_RULES (GW MOTOR AD) for the RuleKey of this case (INNER JOIN)'
            WHEN F.HasVecCase = 0         THEN 'B8 - no VEC_CASE row for this AD case (INNER JOIN)'
            WHEN F.HasCurrentStatus = 0   THEN 'B9 - no VEC_GW_CASE_STATUS row with GCURRENT = X for this AD case (INNER JOIN)'
            ELSE 'B10 - every join tested here passes, yet nothing was created: not explained by this file, investigate (is the exposure proc up to date / re-run?)'
       END AS FirstReason
INTO #AD_RES
FROM #AD_FLAGS F;

-- B-1. SUMMARY
SELECT COUNT(*) AS AD_CasesOnMotorClaims, SUM(HasExposure) AS WithExposure, SUM(1 - HasExposure) AS WithoutExposure FROM #AD_RES;
-- B-2. cases WITHOUT an exposure, by reason
SELECT FirstReason, COUNT(*) AS Cases, COUNT(DISTINCT ClaimRef) AS Claims FROM #AD_RES WHERE HasExposure = 0 GROUP BY FirstReason ORDER BY Cases DESC;
-- B-3. THE LIST: claim, header case ID, AD case ID, reason
SELECT ClaimRef, GW_HDR_CASEID, AD_ID AS AD_CaseID, FirstReason FROM #AD_RES WHERE HasExposure = 0 ORDER BY FirstReason, ClaimRef;
GO


/* ============================ PART C - FIRST-PARTY PA ANCILLARY CASES ============================
   Exposure proc block D: IS_CLAIM_MASTER -> VEC_PA_ANCILLARY on GW_HDR_CASEID -> VEC_GWP_SLCTD_RISK -> VEC_GWP_RISKUNIT -> VEC_GWP_COVERAGE
   (PATTERN_CODE PMPersonalInjuryAncCov / PMPersonalInjuryPlusAncCov) -> LKP_EXPOSURE_MOTOR_RULES ('GW PI ANCILLARY', PA / PA_PLUS) ->
   VEC_GW_CASE_STATUS (current) -> VEC_CASE. */
IF OBJECT_ID('tempdb..#PA_FLAGS') IS NOT NULL DROP TABLE #PA_FLAGS;
IF OBJECT_ID('tempdb..#PA_RES')   IS NOT NULL DROP TABLE #PA_RES;

SELECT CLM.CLAIM_REF AS ClaimRef, CLM.PublicID AS ClaimPublicID, CLM.GW_HDR_CASEID, PA.ID AS PA_ID,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR WHERE SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID) THEN 1 ELSE 0 END AS HasSelectedRisk,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR
                         JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
                         WHERE SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID) THEN 1 ELSE 0 END AS HasRiskUnit,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR
                         JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
                         JOIN SourceStaging.VECCASRN.VEC_GWP_COVERAGE COV ON COV.GWP_RISKUNITID = RSK.ID
                              AND COV.PATTERN_CODE IN ('PMPersonalInjuryAncCov','PMPersonalInjuryPlusAncCov')
                         WHERE SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID) THEN 1 ELSE 0 END AS HasPACoverage,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.LKP_EXPOSURE_MOTOR_RULES R WHERE R.V2CaseFlow = 'GW PI ANCILLARY' AND R.RuleKey = 'PA')      THEN 1 ELSE 0 END AS RulePA,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.LKP_EXPOSURE_MOTOR_RULES R WHERE R.V2CaseFlow = 'GW PI ANCILLARY' AND R.RuleKey = 'PA_PLUS') THEN 1 ELSE 0 END AS RulePAPLUS,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR
                         JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
                         JOIN SourceStaging.VECCASRN.VEC_GWP_COVERAGE COV ON COV.GWP_RISKUNITID = RSK.ID AND COV.PATTERN_CODE = 'PMPersonalInjuryPlusAncCov'
                         WHERE SR.GW_HDR_CASEID = CLM.GW_HDR_CASEID) THEN 1 ELSE 0 END AS IsPlus,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS WHERE CS.CASEID = PA.ID AND CS.GCURRENT = 'X') THEN 1 ELSE 0 END AS HasCurrentStatus,
       CASE WHEN EXISTS (SELECT 1 FROM SourceStaging.VECCASRN.VEC_CASE VC WHERE VC.ID = PA.ID) THEN 1 ELSE 0 END AS HasVecCase
INTO #PA_FLAGS
FROM dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_PA_ANCILLARY PA ON PA.GW_HDR_CASEID = CLM.GW_HDR_CASEID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR';
CREATE UNIQUE CLUSTERED INDEX IX_PAF ON #PA_FLAGS (PA_ID);

SELECT F.ClaimRef, F.ClaimPublicID, F.GW_HDR_CASEID, F.PA_ID,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.IS_EXPOSURE_MOTOR E WHERE E.SourceOrigin_Adm = 'PA' AND CONVERT(VARCHAR(64), E.VectusCaseID_Adm) = CONVERT(VARCHAR(64), F.PA_ID))
            THEN 1 ELSE 0 END AS HasExposure,
       CASE WHEN F.HasSelectedRisk = 0 THEN 'C1 - no VEC_GWP_SLCTD_RISK row for the claim header case (INNER JOIN)'
            WHEN F.HasRiskUnit = 0     THEN 'C2 - selected risk has no matching VEC_GWP_RISKUNIT row (INNER JOIN)'
            WHEN F.HasPACoverage = 0   THEN 'C3 - risk unit has no PMPersonalInjuryAncCov / PMPersonalInjuryPlusAncCov coverage (INNER JOIN)'
            WHEN (F.IsPlus = 1 AND F.RulePAPLUS = 0) OR (F.IsPlus = 0 AND F.RulePA = 0)
                 THEN 'C4 - no rule row in LKP_EXPOSURE_MOTOR_RULES (GW PI ANCILLARY) for PA / PA_PLUS (INNER JOIN)'
            WHEN F.HasCurrentStatus = 0 THEN 'C5 - no VEC_GW_CASE_STATUS row with GCURRENT = X for this PA case (INNER JOIN)'
            WHEN F.HasVecCase = 0      THEN 'C6 - no VEC_CASE row for this PA case (INNER JOIN)'
            ELSE 'C7 - every join tested here passes, yet nothing was created: not explained by this file, investigate (is the exposure proc up to date / re-run?)'
       END AS FirstReason
INTO #PA_RES
FROM #PA_FLAGS F;

-- C-1. SUMMARY
SELECT COUNT(*) AS PA_CasesOnMotorClaims, SUM(HasExposure) AS WithExposure, SUM(1 - HasExposure) AS WithoutExposure FROM #PA_RES;
-- C-2. cases WITHOUT an exposure, by reason
SELECT FirstReason, COUNT(*) AS Cases, COUNT(DISTINCT ClaimRef) AS Claims FROM #PA_RES WHERE HasExposure = 0 GROUP BY FirstReason ORDER BY Cases DESC;
-- C-3. THE LIST
SELECT ClaimRef, GW_HDR_CASEID, PA_ID AS PA_CaseID, FirstReason FROM #PA_RES WHERE HasExposure = 0 ORDER BY FirstReason, ClaimRef;
GO


/* ============================ PART D - ALL THREE KINDS TOGETHER ============================ */
SELECT CaseKind, COUNT(*) AS CasesOnMotorClaims, SUM(CASE WHEN HasExposure = 1 THEN 1 ELSE 0 END) AS WithExposure, SUM(CASE WHEN HasExposure = 0 THEN 1 ELSE 0 END) AS WithoutExposure
FROM (
    SELECT 'Third party (TP)' AS CaseKind, CASE WHEN NoExposureAtAll = 1 THEN 0 ELSE 1 END AS HasExposure FROM #TP_RES
    UNION ALL SELECT 'First party AD', HasExposure FROM #AD_RES
    UNION ALL SELECT 'First party PA', HasExposure FROM #PA_RES
) X GROUP BY CaseKind;

-- every case without an exposure, one list (claim, header case ID, kind, case ID, reason)
SELECT ClaimRef, GW_HDR_CASEID, 'Third party (TP)' AS CaseKind, TP_ID AS CaseID, FirstReason FROM #TP_RES WHERE NoExposureAtAll = 1
UNION ALL SELECT ClaimRef, GW_HDR_CASEID, 'First party AD', AD_ID, FirstReason FROM #AD_RES WHERE HasExposure = 0
UNION ALL SELECT ClaimRef, GW_HDR_CASEID, 'First party PA', PA_ID, FirstReason FROM #PA_RES WHERE HasExposure = 0
ORDER BY CaseKind, FirstReason, ClaimRef;
