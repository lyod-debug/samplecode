/* =====================================================================================
   INTERNAL CHECK (do NOT send to BA yet) - MOTOR FIRST PARTY - A CLAIM WITH MORE THAN ONE AD / PA EXPOSURE
   Read-only. Nothing is changed or deleted.

   WHY IT CAN HAPPEN (from the exposure proc, usp_Load_IS_EXPOSURE_MOTOR):
     AD : IS_CLAIM_MASTER.GW_HDR_CASEID = VEC_GW_MOTOR_AD.GW_HDR_CASEID  (via #AD_ELIGIBLE). The exposure ID is 'mig:motor_ad' + AD_ID, and the AD_ID
          is also used in the joins VEC_CASE (VC.ID = AD_ID), VEC_GW_CASE_STATUS (CASEID = AD_ID) and #CIL_TOTALS (TRANS_CASEID = AD_ID).
          So ONE header case with TWO eligible AD rows (two different AD_IDs) gives TWO exposures.
          The duplicate table MOTOR_AD_DUPLICATE_LOOKUP is matched on  DUPE.GW_MOTOR_AD_ID = AD.ID  (the AD_ID, not the header case ID).
     PA : IS_CLAIM_MASTER.GW_HDR_CASEID = VEC_PA_ANCILLARY.GW_HDR_CASEID. The exposure ID is 'mig:motor_pa' + PA_ID and PA_ID is used in
          VEC_GW_CASE_STATUS / VEC_CASE / #CIL_TOTALS. There is NO duplicate table for PA, so every PA row of the header case gives its own exposure.

   PART AD-1  claims with more than one AD exposure             (list)
   PART AD-2  every AD row of those header cases, with the duplicate-table status and the proc's eligibility result
   PART AD-3  in the SOURCE: header cases with more than one ELIGIBLE AD row (the root, even before other joins)
   PART PA-1  how many PA exposures per claim (distribution)
   PART PA-2  claims with more than one PA exposure (list: claim, header case ID, PA IDs, exposures, rule, status, create date)
   PART PA-3  in the SOURCE: header cases with more than one VEC_PA_ANCILLARY row
   PART ONE   one header case in full (put its GW_HDR_CASEID in @Hdr): every source row and every exposure, side by side
   ===================================================================================== */
USE IntermediateStaging_DEV;
GO

/* ============================ AD ============================ */
-- AD-1. claims with more than one AD exposure
IF OBJECT_ID('tempdb..#AD_MULTI') IS NOT NULL DROP TABLE #AD_MULTI;
SELECT E.ClaimID AS ClaimPublicID, CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID,
       COUNT(DISTINCT E.Exposure_Motor_PublicID) AS AD_Exposures,
       STRING_AGG(CONVERT(VARCHAR(MAX), E.Exposure_Motor_PublicID + ' (AD_ID ' + CONVERT(VARCHAR(64), E.VectusCaseID_Adm) + ')'), ' ; ') AS ExposuresAndAD_IDs
INTO #AD_MULTI
FROM dbo.IS_EXPOSURE_MOTOR E
JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.PublicID = E.ClaimID
WHERE E.SourceOrigin_Adm = 'AD'
GROUP BY E.ClaimID, CLM.CLAIM_REF, CLM.GW_HDR_CASEID
HAVING COUNT(DISTINCT E.Exposure_Motor_PublicID) > 1;
SELECT * FROM #AD_MULTI ORDER BY ClaimRef;

-- AD-2. every AD row of those header cases (source), whether it is on the duplicate table, and the proc's eligibility rule
--       IsEligible = 1 means the exposure proc lets this AD row through the duplicate rule (NOT on the table, or on it with a MIGRATE solution)
SELECT M.ClaimRef, M.GW_HDR_CASEID, AD.ID AS AD_ID,
       CASE WHEN NOT EXISTS (SELECT 1 FROM SourceStaging.dbo.MOTOR_AD_DUPLICATE_LOOKUP D WHERE D.GW_MOTOR_AD_ID = AD.ID)
              OR EXISTS (SELECT 1 FROM SourceStaging.dbo.MOTOR_AD_DUPLICATE_LOOKUP D
                         WHERE D.GW_MOTOR_AD_ID = AD.ID AND D.CLAIM_REF IS NOT NULL AND LTRIM(RTRIM(D.CLAIM_REF)) <> ''
                           AND UPPER(D.Solution) LIKE '%MIGRATE%' AND UPPER(D.Solution) NOT LIKE '%MIGRATE-GROUP%' AND UPPER(D.Solution) NOT LIKE '%DESCOPE%')
            THEN 1 ELSE 0 END AS IsEligible,
       (SELECT STRING_AGG(CONVERT(VARCHAR(MAX), ISNULL(D.CLAIM_REF,'(no claim ref)') + ' / ' + ISNULL(D.Solution,'(no solution)')), ' ; ')
        FROM SourceStaging.dbo.MOTOR_AD_DUPLICATE_LOOKUP D WHERE D.GW_MOTOR_AD_ID = AD.ID) AS DuplicateTable_ClaimRef_Solution,
       (SELECT STRING_AGG(CONVERT(VARCHAR(MAX), E.Exposure_Motor_PublicID), ', ')
        FROM dbo.IS_EXPOSURE_MOTOR E WHERE E.SourceOrigin_Adm = 'AD' AND CONVERT(VARCHAR(64), E.VectusCaseID_Adm) = CONVERT(VARCHAR(64), AD.ID)) AS ExposureCreated
FROM #AD_MULTI M
JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD ON AD.GW_HDR_CASEID = M.GW_HDR_CASEID
ORDER BY M.ClaimRef, AD.ID;

-- AD-3. SOURCE view: header cases (of MOTOR claims) with more than one AD row that passes the duplicate rule. These are the header cases that CAN give two exposures.
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID, COUNT(*) AS EligibleAD_Rows, STRING_AGG(CONVERT(VARCHAR(64), AD.ID), ', ') AS AD_IDs
FROM dbo.IS_CLAIM_MASTER CLM
JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD ON AD.GW_HDR_CASEID = CLM.GW_HDR_CASEID
WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
  AND (   NOT EXISTS (SELECT 1 FROM SourceStaging.dbo.MOTOR_AD_DUPLICATE_LOOKUP D WHERE D.GW_MOTOR_AD_ID = AD.ID)
       OR EXISTS (SELECT 1 FROM SourceStaging.dbo.MOTOR_AD_DUPLICATE_LOOKUP D
                  WHERE D.GW_MOTOR_AD_ID = AD.ID AND D.CLAIM_REF IS NOT NULL AND LTRIM(RTRIM(D.CLAIM_REF)) <> ''
                    AND UPPER(D.Solution) LIKE '%MIGRATE%' AND UPPER(D.Solution) NOT LIKE '%MIGRATE-GROUP%' AND UPPER(D.Solution) NOT LIKE '%DESCOPE%'))
GROUP BY CLM.CLAIM_REF, CLM.GW_HDR_CASEID
HAVING COUNT(*) > 1
ORDER BY CLM.CLAIM_REF;
GO


/* ============================ PA ============================ */
-- PA-1. distribution: how many PA exposures a claim has
SELECT PA_Exposures, COUNT(*) AS Claims
FROM (SELECT E.ClaimID, COUNT(DISTINCT E.Exposure_Motor_PublicID) AS PA_Exposures
      FROM dbo.IS_EXPOSURE_MOTOR E WHERE E.SourceOrigin_Adm IN ('PA','PA_PLUS') GROUP BY E.ClaimID) X
GROUP BY PA_Exposures ORDER BY PA_Exposures;

-- PA-2. THE LIST: claims with more than one PA exposure. One row per PA exposure, with its source case (PA_ID), rule, current status and create date.
IF OBJECT_ID('tempdb..#PA_MULTI') IS NOT NULL DROP TABLE #PA_MULTI;
SELECT E.ClaimID
INTO #PA_MULTI
FROM dbo.IS_EXPOSURE_MOTOR E WHERE E.SourceOrigin_Adm IN ('PA','PA_PLUS')
GROUP BY E.ClaimID HAVING COUNT(DISTINCT E.Exposure_Motor_PublicID) > 1;

SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID,
       CONVERT(VARCHAR(64), E.VectusCaseID_Adm) AS PA_ID, E.Exposure_Motor_PublicID AS ExposureID, E.SourceOrigin_Adm AS RuleKeyStored,
       CS.STATUS AS CaseStatus, VC.CREATEDATE AS PA_CaseCreateDate,
       COUNT(*) OVER (PARTITION BY E.ClaimID) AS PA_ExposuresOnThisClaim
FROM #PA_MULTI M
JOIN dbo.IS_EXPOSURE_MOTOR E ON E.ClaimID = M.ClaimID AND E.SourceOrigin_Adm IN ('PA','PA_PLUS')
JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.PublicID = E.ClaimID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS ON CS.CASEID = E.VectusCaseID_Adm AND CS.GCURRENT = 'X'
LEFT JOIN SourceStaging.VECCASRN.VEC_CASE VC ON VC.ID = E.VectusCaseID_Adm
ORDER BY CLM.CLAIM_REF, E.VectusCaseID_Adm;

-- PA-3. SOURCE view: header cases (of MOTOR claims) with more than one VEC_PA_ANCILLARY row (these are the header cases that CAN give several PA exposures)
SELECT PA_Rows, COUNT(*) AS HeaderCases
FROM (SELECT CLM.GW_HDR_CASEID, COUNT(*) AS PA_Rows
      FROM dbo.IS_CLAIM_MASTER CLM
      JOIN SourceStaging.VECCASRN.VEC_PA_ANCILLARY PA ON PA.GW_HDR_CASEID = CLM.GW_HDR_CASEID
      WHERE UPPER(LTRIM(RTRIM(CLM.PRODUCT))) = 'MOTOR'
      GROUP BY CLM.GW_HDR_CASEID) X
GROUP BY PA_Rows ORDER BY PA_Rows;
GO


/* ============================ ONE HEADER CASE IN FULL ============================
   Put the GW_HDR_CASEID of an AD claim from AD-1, or a PA claim from PA-2, in @Hdr.  Shows every source row and every exposure of that header case. */
DECLARE @Hdr BIGINT = NULL;

-- all AD source rows of the header case (every column of the source table)
SELECT 'AD source row' AS Source, AD.* FROM SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD WHERE @Hdr IS NOT NULL AND AD.GW_HDR_CASEID = @Hdr;
-- all PA source rows of the header case (every column of the source table)
SELECT 'PA source row' AS Source, PA.* FROM SourceStaging.VECCASRN.VEC_PA_ANCILLARY PA WHERE @Hdr IS NOT NULL AND PA.GW_HDR_CASEID = @Hdr;
-- the first-party exposures created for that header case
SELECT E.Exposure_Motor_PublicID AS ExposureID, E.SourceOrigin_Adm, E.VectusCaseID_Adm AS CaseID_FromSource, E.IncidentID, E.IncidentType, E.ExposureType
FROM dbo.IS_EXPOSURE_MOTOR E
JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.PublicID = E.ClaimID
WHERE @Hdr IS NOT NULL AND CLM.GW_HDR_CASEID = @Hdr AND E.SourceOrigin_Adm IN ('AD','PA','PA_PLUS')
ORDER BY E.SourceOrigin_Adm, E.Exposure_Motor_PublicID;
