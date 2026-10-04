/* =====================================================================================
   HOUSEHOLD - CLAIM CONTACT ROLE CHECKS   (IS layer only; the incident table is NOT used)
   Run the proc first (IS_CLAIMCONTACTROLE must be loaded). Nothing here changes any data.

   H0  What the loaded lookup really contains (text of the link columns, landlord rows)       <- run first
   H1  What the household exposure table contains (kinds, LossParty, incident ID shapes)
   H2  Landlord / policyholder (113 + link 157 / 158, risk unit coverable type)
   H3  Claimant: one per exposure, and every exposure has one
   H4  Contacts on third-party cases: exposure links, recovery (REC) cases, cases without exposure
   H5  Incident links of the roles that are conditional in the lookup
   H6  Same role, same incident / exposure, different contacts; duplicate role PublicIDs

   HH role PublicID = 'mig:hhccr' + HDR_ID + '_' + Role  (claimant adds '_claimant_' + exposure) -> HDR_ID starts at character 10.
   ASSUMED NAMES: IS_EXPOSURE_HOUSEHOLD.(PublicID, ClaimID, VectusCaseID_Adm, LossParty, IncidentID),
   CONTACT_MASTER_HOUSEHOLD.(PublicID, HDR_ID, HDR_TYPE_ID, LINK_TYPE_ID, GW_HDR_CASEID), IS_CLAIM_MASTER.(PublicID, CLAIM_REF, GW_HDR_CASEID, PRODUCT),
   VEC_HH_THIRDPARTY.(ID, HH_CLAIMID, CLAIM_RECOVERY)
   ===================================================================================== */
USE IntermediateStaging_DEV;
GO

/* ============================ H0 - THE LOADED LOOKUP ============================ */
-- H0a. exact text in the three link columns. The proc tests  Link_to_Incident = 'YES'  and  Link_to_Exposure = 'YES'.
--      The mapping sheet has 'YES - If the incident type we are creating aligns with the CC constraint ...' for some roles:
--      if that long text is in this table, the exact test 'YES' never matches those rows.
SELECT Link_to_Policy, Link_to_Exposure, Link_to_Incident, COUNT(*) AS LookupRows
FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP WHERE PRODUCT = 'Household'
GROUP BY Link_to_Policy, Link_to_Exposure, Link_to_Incident
ORDER BY LookupRows DESC;

-- H0b. which household roles have an incident link that is not a plain NO / blank
SELECT HDR_TYPEID, LINK_TYPEID, GWCC_Role_TYPECODE AS Role, EXPOSURE, Link_to_Exposure, Link_to_Incident
FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP
WHERE PRODUCT = 'Household' AND ISNULL(Link_to_Incident, '') NOT IN ('NO', '-', '')
ORDER BY GWCC_Role_TYPECODE, LINK_TYPEID;

-- H0c. landlord / policyholder rows: the proc chooses between them with RISKUNIT_COVERABLE_TYPE
--      expected: landlord_adm rows = 'PHLandlord'; policyholder rows = 'PHHome' (or blank)
SELECT HDR_TYPEID, LINK_TYPEID, GWCC_Role_TYPECODE AS Role, RISKUNIT_COVERABLE_TYPE, Link_to_Policy
FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP
WHERE PRODUCT = 'Household' AND HDR_TYPEID = 113
ORDER BY LINK_TYPEID, GWCC_Role_TYPECODE;

-- H0d. lookup rows with no link type (insured, reporter, claimant, checkpayee): they can never match a contact in the proc's join (NULL = NULL is false)
SELECT HDR_TYPEID, LINK_TYPEID, GWCC_Role_TYPECODE AS Role, Link_to_Exposure FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP WHERE PRODUCT = 'Household' AND LINK_TYPEID IS NULL;


/* ============================ H1 - HOUSEHOLD EXPOSURES ============================ */
-- H1a. kind (from the PublicID prefix), LossParty and the shape of the incident ID.  The proc uses LossParty = 'insured' (first party)
--      and 'third_party' (TP) for the claimant role, so any other value here means no claimant.
SELECT CASE WHEN E.PublicID LIKE 'mig:hhtp%' THEN 'TP (mig:hhtp)'
            WHEN E.PublicID LIKE 'mig:hhb%'  THEN 'BUILDINGS (mig:hhb)'
            WHEN E.PublicID LIKE 'mig:hhc%'  THEN 'CONTENTS (mig:hhc)'
            ELSE 'OTHER' END AS ExposureKind,
       E.LossParty,
       CASE WHEN E.IncidentID IS NULL THEN '(no IncidentID)'
            WHEN PATINDEX('%[0-9]%', E.IncidentID) > 0 THEN LEFT(E.IncidentID, PATINDEX('%[0-9]%', E.IncidentID) - 1)
            ELSE E.IncidentID END AS IncidentIdShape,
       COUNT(*) AS Exposures
FROM dbo.IS_EXPOSURE_HOUSEHOLD E
GROUP BY CASE WHEN E.PublicID LIKE 'mig:hhtp%' THEN 'TP (mig:hhtp)' WHEN E.PublicID LIKE 'mig:hhb%' THEN 'BUILDINGS (mig:hhb)' WHEN E.PublicID LIKE 'mig:hhc%' THEN 'CONTENTS (mig:hhc)' ELSE 'OTHER' END,
         E.LossParty,
         CASE WHEN E.IncidentID IS NULL THEN '(no IncidentID)' WHEN PATINDEX('%[0-9]%', E.IncidentID) > 0 THEN LEFT(E.IncidentID, PATINDEX('%[0-9]%', E.IncidentID) - 1) ELSE E.IncidentID END
ORDER BY ExposureKind, Exposures DESC;

-- H1b. the same exposure PublicID appearing more than once (the exposure proc joins INCD, which can repeat a case when the claim has several incident detail rows)
SELECT COUNT(*) AS PublicIDsUsedMoreThanOnce FROM (SELECT PublicID FROM dbo.IS_EXPOSURE_HOUSEHOLD GROUP BY PublicID HAVING COUNT(*) > 1) X;
SELECT TOP 50 E.PublicID, COUNT(*) AS Rows, COUNT(DISTINCT E.IncidentID) AS DifferentIncidentIDs
FROM dbo.IS_EXPOSURE_HOUSEHOLD E GROUP BY E.PublicID HAVING COUNT(*) > 1 ORDER BY COUNT(*) DESC;

-- H1c. the claimant PublicID turns the exposure ID into a short suffix with REPLACE('mig:hhb'->'b', 'mig:hhc'->'c', 'mig:hhtp'->'tp').
--      Your data: third-party exposure IDs are 'mig:hhtp' + ID, so the 'mig:hhtp' -> 'tp' replace in the proc works. (The pasted exposure code showed 'mig:hhbp'; the data is what counts.)
SELECT TOP 5 PublicID FROM dbo.IS_EXPOSURE_HOUSEHOLD WHERE PublicID LIKE 'mig:hhtp%';


/* ============================ H2 - LANDLORD / POLICYHOLDER ============================
   BA: contact header type 113 is always policyholder, EXCEPT when the selected risk unit coverable type is PHLandlord: then landlord_adm.  */
IF OBJECT_ID('tempdb..#L_BASE')  IS NOT NULL DROP TABLE #L_BASE;
IF OBJECT_ID('tempdb..#L_CONT')  IS NOT NULL DROP TABLE #L_CONT;

-- one row per claim contact and selected risk unit (same joins as the proc uses)
SELECT DISTINCT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID, CC.PublicID AS ClaimContactID, C.HDR_ID,
       RSK.COVERABLE_TYPE AS CoverableType
INTO #L_BASE
FROM dbo.CONTACT_MASTER_HOUSEHOLD C
JOIN dbo.IS_CLAIM_MASTER CLM ON C.GW_HDR_CASEID = CLM.GW_HDR_CASEID AND CLM.PRODUCT = 'HOUSEHOLD'
JOIN dbo.IS_CLAIMCONTACT CC  ON CC.ContactID = C.PublicID AND CC.ClaimID = CLM.PublicID
LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR ON CLM.GW_HDR_CASEID = SR.GW_HDR_CASEID
LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK  ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
WHERE C.HDR_TYPE_ID = 113;

-- H2a. coverable types found on household claims, and claims with more than one selected risk unit
SELECT ISNULL(CoverableType, '(no risk unit found)') AS CoverableType, COUNT(DISTINCT ClaimRef) AS Claims FROM #L_BASE GROUP BY CoverableType ORDER BY Claims DESC;
SELECT COUNT(*) AS ClaimsWithMoreThanOneCoverableTypeRow
FROM (SELECT ClaimRef FROM #L_BASE GROUP BY ClaimRef, ClaimContactID HAVING COUNT(*) > 1) X;

-- one row per claim contact: coverable types and the landlord / policyholder roles actually loaded
SELECT B.ClaimRef, B.GW_HDR_CASEID, B.ClaimContactID, MIN(B.HDR_ID) AS HDR_ID,
       STRING_AGG(ISNULL(B.CoverableType, '(none)'), ', ') AS CoverableTypes,
       MAX(CASE WHEN B.CoverableType = 'PHLandlord' THEN 1 ELSE 0 END) AS HasLandlordRiskUnit,
       MAX(CASE WHEN R.Role = 'landlord_adm' THEN 1 ELSE 0 END)  AS GotLandlord,
       MAX(CASE WHEN R.Role = 'policyholder' THEN 1 ELSE 0 END)  AS GotPolicyholder
INTO #L_CONT
FROM #L_BASE B
LEFT JOIN dbo.IS_CLAIMCONTACTROLE R ON R.ClaimContactID = B.ClaimContactID AND R.Role IN ('landlord_adm','policyholder') AND R.PublicID LIKE 'mig:hhccr%'
GROUP BY B.ClaimRef, B.GW_HDR_CASEID, B.ClaimContactID;

-- H2b. SUMMARY: what the proc gave versus what BA's rule says
SELECT CASE WHEN GotLandlord = 1 AND GotPolicyholder = 1 THEN '3 BOTH landlord_adm and policyholder'
            WHEN GotLandlord = 0 AND GotPolicyholder = 0 THEN '4 NEITHER role'
            WHEN HasLandlordRiskUnit = 1 AND GotLandlord = 1 THEN '1 landlord_adm, risk unit is PHLandlord  (correct)'
            WHEN HasLandlordRiskUnit = 0 AND GotPolicyholder = 1 THEN '1 policyholder, risk unit is not PHLandlord  (correct)'
            ELSE '5 does NOT follow the rule' END AS Situation,
       COUNT(*) AS ClaimContacts, COUNT(DISTINCT ClaimRef) AS Claims
FROM #L_CONT GROUP BY CASE WHEN GotLandlord = 1 AND GotPolicyholder = 1 THEN '3 BOTH landlord_adm and policyholder'
            WHEN GotLandlord = 0 AND GotPolicyholder = 0 THEN '4 NEITHER role'
            WHEN HasLandlordRiskUnit = 1 AND GotLandlord = 1 THEN '1 landlord_adm, risk unit is PHLandlord  (correct)'
            WHEN HasLandlordRiskUnit = 0 AND GotPolicyholder = 1 THEN '1 policyholder, risk unit is not PHLandlord  (correct)'
            ELSE '5 does NOT follow the rule' END
ORDER BY 1;

-- H2c. LIST for BA / you: every case that is not "correct" (claim, GW header case ID, contact, coverable types, roles)
SELECT ClaimRef, GW_HDR_CASEID, ClaimContactID, HDR_ID, CoverableTypes,
       CASE WHEN GotLandlord = 1 THEN 'landlord_adm ' ELSE '' END + CASE WHEN GotPolicyholder = 1 THEN 'policyholder' ELSE '' END AS RolesLoaded
FROM #L_CONT
WHERE (GotLandlord = 1 AND GotPolicyholder = 1)
   OR (GotLandlord = 0 AND GotPolicyholder = 0)
   OR (HasLandlordRiskUnit = 1 AND GotLandlord = 0)
   OR (HasLandlordRiskUnit = 0 AND GotPolicyholder = 0)
ORDER BY ClaimRef;


/* ============================ H3 - CLAIMANT ============================
   BA: claimant is mandatory for every exposure, and exclusive: one person per exposure.
   First party exposure (LossParty = insured): the policyholder (header 113).  TP exposure (LossParty = third_party): the third party contact (header 127) of that TP case. */
IF OBJECT_ID('tempdb..#C_CLAIMANT') IS NOT NULL DROP TABLE #C_CLAIMANT;
SELECT R.ExposureID, COUNT(DISTINCT R.ClaimContactID) AS Claimants, STRING_AGG(CONVERT(VARCHAR(100), R.ClaimContactID), ', ') AS ClaimContactIDs
INTO #C_CLAIMANT
FROM dbo.IS_CLAIMCONTACTROLE R
WHERE R.Role = 'claimant' AND R.PublicID LIKE 'mig:hhccr%'
GROUP BY R.ExposureID;
CREATE CLUSTERED INDEX IX_C_CLAIMANT ON #C_CLAIMANT (ExposureID);

-- H3a. exposures WITHOUT a claimant, by kind and LossParty
SELECT CASE WHEN E.PublicID LIKE 'mig:hhtp%' THEN 'TP' WHEN E.PublicID LIKE 'mig:hhb%' THEN 'BUILDINGS' WHEN E.PublicID LIKE 'mig:hhc%' THEN 'CONTENTS' ELSE 'OTHER' END AS ExposureKind,
       E.LossParty, COUNT(DISTINCT E.PublicID) AS ExposuresWithoutClaimant
FROM dbo.IS_EXPOSURE_HOUSEHOLD E
LEFT JOIN #C_CLAIMANT C ON C.ExposureID = E.PublicID
WHERE C.ExposureID IS NULL
GROUP BY CASE WHEN E.PublicID LIKE 'mig:hhtp%' THEN 'TP' WHEN E.PublicID LIKE 'mig:hhb%' THEN 'BUILDINGS' WHEN E.PublicID LIKE 'mig:hhc%' THEN 'CONTENTS' ELSE 'OTHER' END, E.LossParty
ORDER BY ExposuresWithoutClaimant DESC;

-- H3b. LIST: claim, GW header case ID, case ID, exposure, why there is no claimant
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID, E.VectusCaseID_Adm AS CaseID, E.PublicID AS ExposureID, E.LossParty,
       CASE WHEN E.LossParty = 'insured' THEN 'no header 113 (policyholder) contact on the claim'
            WHEN E.LossParty = 'third_party' THEN 'no header 127 (third party) contact on this TP case'
            ELSE 'LossParty is not insured / third_party - the proc creates no claimant' END AS Reason
FROM dbo.IS_EXPOSURE_HOUSEHOLD E
JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.PublicID = E.ClaimID
LEFT JOIN #C_CLAIMANT C ON C.ExposureID = E.PublicID
WHERE C.ExposureID IS NULL
ORDER BY E.LossParty, CLM.CLAIM_REF;

-- H3c. exposures with MORE THAN ONE claimant (breaks 'exclusive per exposure')
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID, E.VectusCaseID_Adm AS CaseID, E.PublicID AS ExposureID, E.LossParty,
       C.Claimants AS NumberOfClaimants, C.ClaimContactIDs
FROM #C_CLAIMANT C
JOIN dbo.IS_EXPOSURE_HOUSEHOLD E ON E.PublicID = C.ExposureID
JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.PublicID = E.ClaimID
WHERE C.Claimants > 1
ORDER BY E.LossParty, CLM.CLAIM_REF;


/* ============================ H4 - TP-SIDE CONTACTS, RECOVERY CASES, CASES WITHOUT EXPOSURE ============================
   Colleague's logic: only HH_THIRDPARTY cases with CLAIM_RECOVERY = 'TP' create an exposure.  A 'REC' (recovery) case creates NO exposure:
   it is "grouped with one of the main exposures (buildings or contents)".  So contacts on a REC case have no exposure of their own.
   The proc falls back to the claim's first-party exposure (lowest ID, buildings before contents) for roles whose lookup says Link to Exposure = YES. */
IF OBJECT_ID('tempdb..#T_ROLE') IS NOT NULL DROP TABLE #T_ROLE;
SELECT R.Role, R.ClaimContactID, R.ExposureID, R.IncidentID,
       TRY_CONVERT(BIGINT, SUBSTRING(R.PublicID, 10, NULLIF(CHARINDEX('_', R.PublicID, 10), 0) - 10)) AS HDR_ID
INTO #T_ROLE
FROM dbo.IS_CLAIMCONTACTROLE R
WHERE R.PublicID LIKE 'mig:hhccr%' AND R.Role <> 'claimant';

-- the case each contact sits on, and what kind of case that is
IF OBJECT_ID('tempdb..#T_CASE2') IS NOT NULL DROP TABLE #T_CASE2;
SELECT T.Role, T.ClaimContactID, T.HDR_ID, T.ExposureID, T.IncidentID, HDR.CASEID AS CaseID, HT.CLAIM_RECOVERY, HT.HH_CLAIMID,
       CASE WHEN EXISTS (SELECT 1 FROM dbo.IS_EXPOSURE_HOUSEHOLD E WHERE E.LossParty = 'third_party' AND CONVERT(VARCHAR(64), E.VectusCaseID_Adm) = CONVERT(VARCHAR(64), HDR.CASEID)) THEN 1 ELSE 0 END AS CaseHasOwnExposure
INTO #T_CASE2
FROM #T_ROLE T
JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR HDR ON HDR.ID = T.HDR_ID
JOIN SourceStaging.VECCASRN.VEC_HH_THIRDPARTY HT ON HT.ID = HDR.CASEID;      -- only contacts that sit on a household third-party case
CREATE CLUSTERED INDEX IX_T_CASE2 ON #T_CASE2 (CaseID);

-- H4a. REGRESSION CHECK (must be 0 rows after the latest proc: the claim-level fallback was REMOVED): roles that got an exposure although their TP case has NO exposure of its own, by case type
SELECT ISNULL(CLAIM_RECOVERY, '(blank)') AS CaseType_CLAIM_RECOVERY, Role,
       COUNT(*) AS RolesLinkedToAnotherCasesExposure, COUNT(DISTINCT CaseID) AS TP_Cases
FROM #T_CASE2
WHERE CaseHasOwnExposure = 0 AND ExposureID IS NOT NULL
GROUP BY CLAIM_RECOVERY, Role ORDER BY CaseType_CLAIM_RECOVERY, RolesLinkedToAnotherCasesExposure DESC;

-- H4b. LIST: claim, GW header case ID, case ID, case type, role, exposure it got
DECLARE @H4Type VARCHAR(10) = NULL;          -- 'REC' or 'TP' or NULL = all
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID, T.CaseID AS CaseID, T.CLAIM_RECOVERY AS CaseType, T.Role, T.ClaimContactID, T.ExposureID AS ExposureLinkedTo
FROM #T_CASE2 T
JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.GW_HDR_CASEID = T.HH_CLAIMID AND CLM.PRODUCT = 'HOUSEHOLD'
WHERE T.CaseHasOwnExposure = 0 AND T.ExposureID IS NOT NULL AND (@H4Type IS NULL OR T.CLAIM_RECOVERY = @H4Type)
ORDER BY T.CLAIM_RECOVERY, CLM.CLAIM_REF;

-- H4c. TP cases (CLAIM_RECOVERY = 'TP') that should have created an exposure but have none
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID, HT.ID AS CaseID, HT.CLAIM_RECOVERY AS CaseType
FROM SourceStaging.VECCASRN.VEC_HH_THIRDPARTY HT
JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.GW_HDR_CASEID = HT.HH_CLAIMID AND CLM.PRODUCT = 'HOUSEHOLD'
WHERE HT.CLAIM_RECOVERY = 'TP'
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_EXPOSURE_HOUSEHOLD E WHERE E.LossParty = 'third_party' AND CONVERT(VARCHAR(64), E.VectusCaseID_Adm) = CONVERT(VARCHAR(64), HT.ID))
ORDER BY CLM.CLAIM_REF;
-- the colleague's TP exposure build has these INNER JOINs: VEC_HH_INC_DETS, VEC_GW_CASE_STATUS, VEC_CASE, IS_COVERAGE (coverage of the lookup's CT_Code on the claim).
-- A missing coverage row, or no incident detail row on the claim, removes the TP exposure.  Ask him which one loses these cases.

-- H4d. REC cases: the exposures of their claim that they could be grouped with (this is what BA has to choose from)
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID, HT.ID AS RecCaseID,
       STRING_AGG(E.PublicID + ' [' + CASE WHEN E.PublicID LIKE 'mig:hhb%' THEN 'buildings' WHEN E.PublicID LIKE 'mig:hhc%' THEN 'contents' ELSE 'other' END + ']', ', ') AS MainExposuresOnClaim
FROM SourceStaging.VECCASRN.VEC_HH_THIRDPARTY HT
JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.GW_HDR_CASEID = HT.HH_CLAIMID AND CLM.PRODUCT = 'HOUSEHOLD'
LEFT JOIN dbo.IS_EXPOSURE_HOUSEHOLD E ON E.ClaimID = CLM.PublicID AND E.LossParty = 'insured'
WHERE HT.CLAIM_RECOVERY = 'REC'
GROUP BY CLM.CLAIM_REF, CLM.GW_HDR_CASEID, HT.ID
ORDER BY CLM.CLAIM_REF;


/* ============================ H5 - INCIDENT LINKS ============================ */
-- H5a. which incident kinds do household roles point at (by shape of the incident ID)?  Roles with no incident are not shown.
SELECT R.Role,
       CASE WHEN PATINDEX('%[0-9]%', R.IncidentID) > 0 THEN LEFT(R.IncidentID, PATINDEX('%[0-9]%', R.IncidentID) - 1) ELSE R.IncidentID END AS IncidentIdShape,
       COUNT(*) AS RoleRows
FROM dbo.IS_CLAIMCONTACTROLE R
WHERE R.PublicID LIKE 'mig:hhccr%' AND R.IncidentID IS NOT NULL
GROUP BY R.Role, CASE WHEN PATINDEX('%[0-9]%', R.IncidentID) > 0 THEN LEFT(R.IncidentID, PATINDEX('%[0-9]%', R.IncidentID) - 1) ELSE R.IncidentID END
ORDER BY R.Role, RoleRows DESC;
-- 0 rows here means NO household role carries an incident (the exact-'YES' test did not match the long lookup text - see H0a).

-- H5b. thirdparty_adm / tpinsurer_Adm / recoveryagent: Guidewire accepts them only on a VehicleIncident. These rows sit on another kind = future load errors
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID, T.CaseID, T.Role, T.ClaimContactID, T.IncidentID
FROM #T_CASE2 T
JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.GW_HDR_CASEID = T.HH_CLAIMID AND CLM.PRODUCT = 'HOUSEHOLD'
LEFT JOIN dbo.IS_INCIDENT INCX ON INCX.PublicID = T.IncidentID
WHERE T.IncidentID IS NOT NULL AND ISNULL(INCX.Subtype,'(not found in IS_INCIDENT)') <> 'VehicleIncident'    -- subtype from IS_INCIDENT (same rule as the proc)
  AND T.Role IN ('thirdparty_adm','tpinsurer_Adm','recoveryagent')
ORDER BY T.Role, CLM.CLAIM_REF;

-- H5c. roles linked to an incident that does not belong to their own TP case (claim-level fallback)
SELECT T.Role, COUNT(*) AS RoleRows
FROM #T_CASE2 T
LEFT JOIN (SELECT DISTINCT CONVERT(VARCHAR(64), VectusCaseID_Adm) AS CaseID, IncidentID FROM dbo.IS_EXPOSURE_HOUSEHOLD WHERE IncidentID IS NOT NULL) OWN
       ON OWN.CaseID = CONVERT(VARCHAR(64), T.CaseID) AND OWN.IncidentID = T.IncidentID
WHERE T.IncidentID IS NOT NULL AND OWN.IncidentID IS NULL
GROUP BY T.Role ORDER BY RoleRows DESC;


/* ============================ H6 - DUPLICATES ============================ */
-- H6a. same exclusive role (recoveryagent, tpinsurer_Adm = load errors 8 / 9) on the same incident, different claim contacts
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID, X.IncidentID, X.Role, X.ClaimContacts AS NumberOfClaimContacts, X.ClaimContactIDs
FROM (SELECT R.IncidentID, R.Role, MIN(CC.ClaimID) AS ClaimID, COUNT(DISTINCT R.ClaimContactID) AS ClaimContacts,
             STRING_AGG(CONVERT(VARCHAR(100), R.ClaimContactID), ', ') AS ClaimContactIDs
      FROM (SELECT DISTINCT IncidentID, Role, ClaimContactID FROM dbo.IS_CLAIMCONTACTROLE
            WHERE PublicID LIKE 'mig:hhccr%' AND IncidentID IS NOT NULL AND Role IN ('recoveryagent','tpinsurer_Adm')) R
      JOIN dbo.IS_CLAIMCONTACT CC ON CC.PublicID = R.ClaimContactID
      GROUP BY R.IncidentID, R.Role HAVING COUNT(DISTINCT R.ClaimContactID) > 1) X
JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.PublicID = X.ClaimID
ORDER BY X.Role, CLM.CLAIM_REF;
-- the vehicle incident ID of the household exposure proc ('mig:HH_veh_tp' + INC_DETS ID) is built from the CLAIM-level incident detail ID,
-- so every TP case of a claim can end up on the SAME incident ID.

-- H6b. same role, same exposure, different claim contacts (any role)
SELECT R.Role, COUNT(*) AS ExposureRoleGroups
FROM (SELECT ExposureID, Role FROM dbo.IS_CLAIMCONTACTROLE WHERE PublicID LIKE 'mig:hhccr%' AND ExposureID IS NOT NULL
      GROUP BY ExposureID, Role HAVING COUNT(DISTINCT ClaimContactID) > 1) R
GROUP BY R.Role ORDER BY ExposureRoleGroups DESC;

-- H6c. two role rows with the same PublicID (the PublicID has no exposure or incident in it, except for claimant): would be a unique-key error
SELECT COUNT(*) AS PublicIDsUsedMoreThanOnce FROM (SELECT PublicID FROM dbo.IS_CLAIMCONTACTROLE WHERE PublicID LIKE 'mig:hhccr%' GROUP BY PublicID HAVING COUNT(*) > 1) X;
SELECT TOP 50 R.PublicID, COUNT(*) AS Rows, COUNT(DISTINCT ISNULL(R.ExposureID,'')) AS Exposures, COUNT(DISTINCT ISNULL(R.IncidentID,'')) AS Incidents, COUNT(DISTINCT ISNULL(R.PolicyID,'')) AS Policies
FROM dbo.IS_CLAIMCONTACTROLE R WHERE R.PublicID LIKE 'mig:hhccr%' GROUP BY R.PublicID HAVING COUNT(*) > 1 ORDER BY COUNT(*) DESC;
