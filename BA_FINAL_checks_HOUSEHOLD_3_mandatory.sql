/* =====================================================================================
   BA FINAL CHECKS - HOUSEHOLD - THE THREE MANDATORY CHECKS      (read-only, nothing is changed or deleted)

   CHECK 1  Two (or more) DIFFERENT claim contacts get the SAME role on the SAME case - ALL ROLES (any role can be exclusive in Guidewire)
   CHECK 2  The third-party case has NO VEHICLE INCIDENT, but the contact has one of the vehicle roles
            (the role is kept with a blank IncidentID; nothing is deleted)
   CHECK 3  The IncidentID is on the exposure (IS_EXPOSURE_HOUSEHOLD) but that incident does not exist in IS_INCIDENT
            (3a = exposures with such an IncidentID, 3b = claim contact roles that carry such an IncidentID)

   Every list shows: claim reference, GW_HDR_CASEID (claim header case ID), the case ID, the role, and the ids to look up.
   The last query ("ALL CLAIMS") gives one list of every claim that appears in any of the three checks.

   NOTE: the vehicle-role / lookup rules below belong to CHECK 2 only. CHECK 1 covers ALL roles and reads IS_CLAIMCONTACTROLE (so run the claim contact role proc first).
   THE VEHICLE ROLES (Guidewire accepts them only on a VehicleIncident):  thirdparty_adm, tpinsurer_Adm, recoveryagent
   WHICH CONTACTS ARE LOOKED AT (exactly the rule of the proc, STEP 3A):
        lookup row with  EXPOSURE text containing 'THIRDPARTY'  and  Link_to_Incident = 'YES'  and  one of the 3 roles.
   THE CASE: contact's HDR.CASEID = VEC_HH_THIRDPARTY.ID. Its exposures are the IS_EXPOSURE_HOUSEHOLD rows with PublicID 'mig:hhtp%'
        and VectusCaseID_Adm = that case ID (case IDs come from three tables, so the prefix is needed).
        A case with CLAIM_RECOVERY = 'REC' creates no exposure by design (BA decision pending) and shows as P1 with CaseType REC.
   VEHICLE INCIDENT = IS_INCIDENT.Subtype = 'VehicleIncident' and PublicID 'mig:HH%' (same rule as the proc). IS_EXPOSURE_HOUSEHOLD has no
        incident type column, so for Household ONLY the incident table is joined, always on the IncidentID that comes from the exposure.
   Run the exposure proc first, then this file. CHECK 1 and CHECK 3b read IS_CLAIMCONTACTROLE, so run the claim contact role proc first for them.
   If IS_INCIDENT has a Retired column add  AND ISNULL(I.Retired,0) = 0  to the incident joins.
   HH role PublicID = 'mig:hhccr' + HDR_ID + '_' + Role   (HDR_ID starts at character 10).

   ASSUMED NAMES (verify once): IS_EXPOSURE_HOUSEHOLD.(PublicID, ClaimID, VectusCaseID_Adm, LossParty, IncidentID), IS_INCIDENT.(PublicID, Subtype),
   IS_CLAIM_MASTER.(PublicID, CLAIM_REF, GW_HDR_CASEID, PRODUCT), VEC_HH_THIRDPARTY.(ID, HH_CLAIMID, CLAIM_RECOVERY).
   ===================================================================================== */
USE IntermediateStaging_DEV;
GO

/* ============================ SETUP ============================ */
IF OBJECT_ID('tempdb..#HB')     IS NOT NULL DROP TABLE #HB;
IF OBJECT_ID('tempdb..#HC')     IS NOT NULL DROP TABLE #HC;
IF OBJECT_ID('tempdb..#HR')     IS NOT NULL DROP TABLE #HR;
IF OBJECT_ID('tempdb..#HC1')    IS NOT NULL DROP TABLE #HC1;
IF OBJECT_ID('tempdb..#HC1G')   IS NOT NULL DROP TABLE #HC1G;
IF OBJECT_ID('tempdb..#HC2')    IS NOT NULL DROP TABLE #HC2;
IF OBJECT_ID('tempdb..#HC3A')   IS NOT NULL DROP TABLE #HC3A;
IF OBJECT_ID('tempdb..#HC3B')   IS NOT NULL DROP TABLE #HC3B;

/* contacts that must link to a vehicle incident of their OWN third-party case (same lookup join as the proc, STEP 3A) */
SELECT DISTINCT
       CLM.CLAIM_REF                       AS ClaimRef,
       CLM.PublicID                        AS ClaimPublicID,
       C.GW_HDR_CASEID                     AS GW_HDR_CASEID,
       CONVERT(VARCHAR(64), HDR.CASEID)    AS CaseID,
       HT.CLAIM_RECOVERY                   AS CaseType,
       C.HDR_ID,
       CC.PublicID                         AS ClaimContactID,
       C.PublicID                          AS ContactPublicID,
       LT.LINK_TYPE,
       LKP.GWCC_Role_TYPECODE              AS Role
INTO #HB
FROM dbo.CONTACT_MASTER_HOUSEHOLD C
JOIN dbo.IS_CLAIM_MASTER CLM   ON C.GW_HDR_CASEID = CLM.GW_HDR_CASEID AND CLM.PRODUCT = 'HOUSEHOLD'
JOIN dbo.IS_CLAIMCONTACT CC    ON CC.ContactID = C.PublicID AND CC.ClaimID = CLM.PublicID
LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR ON CLM.GW_HDR_CASEID = SR.GW_HDR_CASEID
LEFT JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RSK  ON RSK.GWP_POLICYID = SR.GWP_POLICYID AND RSK.PUBLICID = SR.PUBLICID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR HDR     ON HDR.ID = C.HDR_ID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CFLINK_TYPE LT ON LT.ID = C.LINK_TYPE_ID
LEFT JOIN SourceStaging.VECCASRN.VEC_HH_THIRDPARTY HT  ON HT.ID = HDR.CASEID
JOIN dbo.CLAIM_CONTACT_ROLE_LOOKUP LKP
       ON LKP.PRODUCT = 'Household'
      AND LKP.HDR_TYPEID  = C.HDR_TYPE_ID
      AND LKP.LINK_TYPEID = C.LINK_TYPE_ID
      AND (   LKP.RISKUNIT_COVERABLE_TYPE = RSK.COVERABLE_TYPE
           OR (LKP.RISKUNIT_COVERABLE_TYPE IS NULL
               AND NOT EXISTS (SELECT 1 FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP X
                               WHERE X.PRODUCT = LKP.PRODUCT AND X.HDR_TYPEID = LKP.HDR_TYPEID AND X.LINK_TYPEID = LKP.LINK_TYPEID
                                 AND X.RISKUNIT_COVERABLE_TYPE = RSK.COVERABLE_TYPE)))
WHERE LKP.GWCC_Role_TYPECODE IN ('thirdparty_adm','tpinsurer_Adm','recoveryagent')
  AND UPPER(LKP.EXPOSURE) LIKE '%THIRDPARTY%'
  AND LKP.Link_to_Incident = 'YES';
CREATE NONCLUSTERED INDEX IX_HB ON #HB (CaseID, Role);

/* the OWN exposures and incidents of every third-party case (third-party exposures only: PublicID prefix mig:hhtp), with the subtype from IS_INCIDENT */
SELECT CONVERT(VARCHAR(64), E.VectusCaseID_Adm) AS CaseID,
       COUNT(DISTINCT E.PublicID)                                                                                        AS Exposures,
       COUNT(DISTINCT E.IncidentID)                                                                                      AS Incidents,
       COUNT(DISTINCT CASE WHEN I.PublicID IS NOT NULL THEN E.IncidentID END)                                            AS IncidentsFoundInIS_INCIDENT,
       COUNT(DISTINCT CASE WHEN I.Subtype = 'VehicleIncident' AND I.PublicID LIKE 'mig:HH%' THEN E.IncidentID END)       AS VehicleIncidents,
       STRING_AGG(CONVERT(VARCHAR(MAX), E.PublicID + ' -> ' + ISNULL(E.IncidentID, '(no IncidentID)') +
            CASE WHEN E.IncidentID IS NULL THEN '' ELSE ' [' + ISNULL(I.Subtype, 'NOT FOUND in IS_INCIDENT') + ']' END), '  ||  ') AS OwnExposuresAndIncidents
INTO #HC
FROM dbo.IS_EXPOSURE_HOUSEHOLD E
LEFT JOIN dbo.IS_INCIDENT I ON I.PublicID = E.IncidentID
WHERE E.PublicID LIKE 'mig:hhtp%' AND E.VectusCaseID_Adm IS NOT NULL
GROUP BY CONVERT(VARCHAR(64), E.VectusCaseID_Adm);
CREATE UNIQUE CLUSTERED INDEX IX_HC ON #HC (CaseID);
GO


/* =====================================================================================
   CHECK 1 - SAME ROLE, SAME CASE, DIFFERENT CLAIM CONTACTS            (ALL ROLES, not only the vehicle roles)
   In Guidewire a role can be EXCLUSIVE: only one contact may hold it. Any role can have this constraint, so EVERY role that is loaded is checked here.
   Which roles are exclusive is decided in Guidewire / by the BA, not here: the summary lists every role that has the problem, the BA ticks the exclusive ones.
   (Known from the mapping notes: insured, reporter and claimant are exclusive.)
   Reads IS_CLAIMCONTACTROLE (run the claim contact role proc first) = exactly what will be loaded, mandatory roles included.
   CASE = for THIRD-PARTY roles the case ID of the role's HDR_ID (VEC_GW_CF_HDR.CASEID); for FIRST-PARTY roles the claim's header case (GW_HDR_CASEID) itself is the case.
   A role is third party when its header type has only 'THIRDPARTY' rows in CLAIM_CONTACT_ROLE_LOOKUP.EXPOSURE. The same claim and the same case are grouped together.
   Counts CLAIM CONTACTS (IS_CLAIMCONTACT.PublicID). Whether two claim contacts are the same real person is NOT checked.
   One contact that holds the role through two HDR_IDs / two exposures is ONE claim contact and is NOT reported.
   Role rows whose HDR_ID has no VEC_GW_CF_HDR row (no case ID) cannot be grouped and are left out (count shown in 1a-0).
   ===================================================================================== */
-- 1a-0. role rows left out because their header (HDR_ID) does not exist in VEC_GW_CF_HDR (should be 0)
SELECT COUNT(*) AS RoleRowsWithoutHeader_NotChecked
FROM dbo.IS_CLAIMCONTACTROLE R
CROSS APPLY (SELECT TRY_CONVERT(BIGINT, SUBSTRING(R.PublicID, 10, NULLIF(CHARINDEX('_', R.PublicID, 10), 0) - 10)) AS HDR_ID) HR
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR HDR ON HDR.ID = HR.HDR_ID
WHERE R.PublicID LIKE 'mig:hhccr%' AND HDR.ID IS NULL;

-- every loaded role row with its claim, case, HDR_ID, header type, exposure and incident (distinct)
SELECT DISTINCT CLM.CLAIM_REF AS ClaimRef, CLM.PublicID AS ClaimPublicID, CLM.GW_HDR_CASEID AS GW_HDR_CASEID,
       CASE WHEN TPT.IsThirdParty = 1 THEN CONVERT(VARCHAR(64), HDR.CASEID) ELSE CONVERT(VARCHAR(64), CLM.GW_HDR_CASEID) END AS CaseID,
       R.Role, R.ClaimContactID, HR.HDR_ID, HTY.HDR_TYPE,
       R.ExposureID, R.IncidentID
INTO #HR
FROM dbo.IS_CLAIMCONTACTROLE R
CROSS APPLY (SELECT TRY_CONVERT(BIGINT, SUBSTRING(R.PublicID, 10, NULLIF(CHARINDEX('_', R.PublicID, 10), 0) - 10)) AS HDR_ID) HR   -- 'mig:hhccr' = 9 characters
JOIN dbo.IS_CLAIMCONTACT CC     ON CC.PublicID = R.ClaimContactID
JOIN dbo.IS_CLAIM_MASTER CLM    ON CLM.PublicID = CC.ClaimID
JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR HDR ON HDR.ID = HR.HDR_ID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR_TYPE HTY ON HTY.ID = HDR.GWCONTH_TYPEID
OUTER APPLY (SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP L WHERE L.PRODUCT = 'Household' AND L.HDR_TYPEID = HDR.GWCONTH_TYPEID AND UPPER(L.EXPOSURE) LIKE '%THIRDPARTY%')
                    AND NOT EXISTS (SELECT 1 FROM dbo.CLAIM_CONTACT_ROLE_LOOKUP L WHERE L.PRODUCT = 'Household' AND L.HDR_TYPEID = HDR.GWCONTH_TYPEID AND L.EXPOSURE IS NOT NULL AND LTRIM(RTRIM(L.EXPOSURE)) <> '' AND UPPER(L.EXPOSURE) NOT LIKE '%THIRDPARTY%')
               THEN 1 ELSE 0 END AS IsThirdParty) TPT
WHERE R.PublicID LIKE 'mig:hhccr%' AND (TPT.IsThirdParty = 0 OR HDR.CASEID IS NOT NULL);
CREATE NONCLUSTERED INDEX IX_HR ON #HR (ClaimPublicID, CaseID, Role);

-- one row per claim / case / role / claim contact (what that contact holds, as text)
SELECT X.ClaimRef, X.ClaimPublicID, X.GW_HDR_CASEID, X.CaseID, X.Role, X.ClaimContactID,
       STRING_AGG(CONVERT(VARCHAR(MAX), 'HDR ' + CONVERT(VARCHAR(20), X.HDR_ID) + ' (' + ISNULL(X.HDR_TYPE, '?') + ')'
                          + ' exposure: ' + ISNULL(X.ExposureID, '-') + ' incident: ' + ISNULL(X.IncidentID, '-')), ' ; ') AS WhatThisContactHolds
INTO #HC1
FROM #HR X
GROUP BY X.ClaimRef, X.ClaimPublicID, X.GW_HDR_CASEID, X.CaseID, X.Role, X.ClaimContactID;

SELECT ClaimRef, ClaimPublicID, GW_HDR_CASEID, CaseID, Role,
       COUNT(*)                                                    AS NumberOfClaimContacts,
       STRING_AGG(CONVERT(VARCHAR(MAX), ClaimContactID), ', ')     AS ClaimContactIDs,
       STRING_AGG(CONVERT(VARCHAR(MAX), WhatThisContactHolds), ' | ') AS WhatEachContactHolds
INTO #HC1G
FROM #HC1
GROUP BY ClaimRef, ClaimPublicID, GW_HDR_CASEID, CaseID, Role
HAVING COUNT(*) > 1;

-- 1a. SUMMARY by role: every role that has the problem (the BA says which of these roles are exclusive)
SELECT Role, COUNT(*) AS CaseRoleGroups, COUNT(DISTINCT CaseID) AS Cases, COUNT(DISTINCT ClaimRef) AS Claims, COUNT(DISTINCT GW_HDR_CASEID) AS HeaderCases,
       SUM(NumberOfClaimContacts) AS ClaimContactsInvolved
FROM #HC1G GROUP BY Role ORDER BY CaseRoleGroups DESC;

-- 1b. THE LIST FOR BA: claim, header case ID, case ID, role, the claim contacts and what each holds.   (@C1Role: one role, or NULL for all roles)
DECLARE @C1Role VARCHAR(60) = NULL;
SELECT ClaimRef, GW_HDR_CASEID, CaseID AS CaseID, Role, NumberOfClaimContacts, ClaimContactIDs, WhatEachContactHolds
FROM #HC1G
WHERE @C1Role IS NULL OR Role = @C1Role
ORDER BY Role, ClaimRef;
GO


/* =====================================================================================
   CHECK 2 - THE CASE HAS NO VEHICLE INCIDENT (for contacts with a vehicle role)
   Only the contact's OWN case is looked at. Reason (first one that applies):
     P1   the third-party case has NO exposure at all (CaseType 'REC' creates none by design - BA decision pending)
     P2   the case has exposure(s) but none has an IncidentID
     P3a  the case has incident IDs but NONE of them exists in IS_INCIDENT (this is also CHECK 3)
     P3b  the case has incidents in IS_INCIDENT but none is a VehicleIncident
   The role is kept; its IncidentID will be blank.
   ===================================================================================== */
SELECT B.ClaimRef, B.GW_HDR_CASEID, B.CaseID, B.CaseType, B.Role, B.ClaimContactID, B.HDR_ID, B.LINK_TYPE,
       ISNULL(C.Exposures, 0) AS Exposures, ISNULL(C.Incidents, 0) AS Incidents, ISNULL(C.VehicleIncidents, 0) AS VehicleIncidents,
       C.OwnExposuresAndIncidents,
       CASE WHEN C.CaseID IS NULL                  THEN 'P1 - the case has NO exposure'
            WHEN C.Incidents = 0                   THEN 'P2 - the case has exposure(s) but none has an IncidentID'
            WHEN C.IncidentsFoundInIS_INCIDENT = 0 THEN 'P3a - the case has incident IDs but none exists in IS_INCIDENT'
            ELSE                                        'P3b - the case has incidents but none is a VehicleIncident' END AS Situation
INTO #HC2
FROM #HB B
LEFT JOIN #HC C ON C.CaseID = B.CaseID
WHERE C.CaseID IS NULL OR C.VehicleIncidents = 0;

-- 2a. SUMMARY by role and situation
SELECT Role, Situation, COUNT(*) AS ContactRoleRows, COUNT(DISTINCT CaseID) AS Cases, COUNT(DISTINCT ClaimRef) AS Claims, COUNT(DISTINCT GW_HDR_CASEID) AS HeaderCases
FROM #HC2 GROUP BY Role, Situation ORDER BY Situation, ContactRoleRows DESC;

-- 2b. THE LIST FOR BA: one row per claim / case / role with the case's OWN exposures and incidents.
--     (@C2Role: one role or NULL for all;  @C2Situation: 'P1', 'P2', 'P3a', 'P3b' or NULL for all)
DECLARE @C2Role VARCHAR(60) = NULL, @C2Situation VARCHAR(3) = NULL;
SELECT P.ClaimRef, P.GW_HDR_CASEID, P.CaseID AS HHT_CaseID, MIN(P.CaseType) AS CaseType, P.Role,
       COUNT(DISTINCT P.ClaimContactID)                  AS Contacts,
       STRING_AGG(CONVERT(VARCHAR(20), P.HDR_ID), ', ')  AS HDR_IDs,
       MIN(P.Situation)                                  AS Situation,
       ISNULL(MIN(P.OwnExposuresAndIncidents), '(no exposure on this case)') AS 'Own case: exposure -> incident [subtype in IS_INCIDENT]'
FROM #HC2 P
WHERE (@C2Role IS NULL OR P.Role = @C2Role)
  AND (@C2Situation IS NULL OR LEFT(P.Situation, LEN(@C2Situation)) = @C2Situation)
GROUP BY P.ClaimRef, P.GW_HDR_CASEID, P.CaseID, P.Role
ORDER BY P.Role, MIN(P.Situation), P.ClaimRef;

-- 2c. ONE CASE IN DETAIL (every exposure and incident of that case; put a case ID in @C2Case)
DECLARE @C2Case VARCHAR(64) = NULL;
SELECT CONVERT(VARCHAR(64), E.VectusCaseID_Adm) AS CaseID, E.PublicID AS ExposureID, ISNULL(E.IncidentID, '(no IncidentID)') AS IncidentID,
       CASE WHEN E.IncidentID IS NULL THEN '-' ELSE ISNULL(I.Subtype, 'NOT FOUND in IS_INCIDENT') END AS Subtype
FROM dbo.IS_EXPOSURE_HOUSEHOLD E
LEFT JOIN dbo.IS_INCIDENT I ON I.PublicID = E.IncidentID
WHERE @C2Case IS NOT NULL AND CONVERT(VARCHAR(64), E.VectusCaseID_Adm) = @C2Case AND E.PublicID LIKE 'mig:hhtp%'
ORDER BY E.PublicID;
GO


/* =====================================================================================
   CHECK 3 - INCIDENT ID IS ON THE EXPOSURE (OR ON THE ROLE) BUT THE INCIDENT DOES NOT EXIST IN IS_INCIDENT
   3a  exposures (third-party, buildings, contents)             -> load error: IS_EXPOSURE_HOUSEHOLD.IncidentID has no parent incident
   3b  claim contact roles (read from IS_CLAIMCONTACTROLE)      -> load error: IS_CLAIMCONTACTROLE.IncidentID has no parent incident
   ===================================================================================== */
-- 3a. exposures whose IncidentID is not in IS_INCIDENT, with how many role rows carry the same incident
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID,
       CONVERT(VARCHAR(64), E.VectusCaseID_Adm) AS CaseID,
       CASE WHEN E.PublicID LIKE 'mig:hhtp%' THEN 'THIRD PARTY' WHEN E.PublicID LIKE 'mig:hhb%' THEN 'BUILDINGS'
            WHEN E.PublicID LIKE 'mig:hhc%' THEN 'CONTENTS' ELSE 'OTHER' END AS ExposureKind,
       E.LossParty, E.PublicID AS ExposureID, E.IncidentID AS IncidentID_OnExposure,
       ISNULL(RR.RoleRowsCarryingThisIncident, 0) AS RoleRowsCarryingThisIncident,
       'IncidentID on the exposure is NOT FOUND in IS_INCIDENT' AS IncidentTableCheck
INTO #HC3A
FROM dbo.IS_EXPOSURE_HOUSEHOLD E
LEFT JOIN dbo.IS_CLAIM_MASTER CLM ON CLM.PublicID = E.ClaimID
LEFT JOIN (SELECT IncidentID, COUNT(*) AS RoleRowsCarryingThisIncident
           FROM dbo.IS_CLAIMCONTACTROLE WHERE PublicID LIKE 'mig:hhccr%' AND IncidentID IS NOT NULL GROUP BY IncidentID) RR
       ON RR.IncidentID = E.IncidentID
WHERE E.IncidentID IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_INCIDENT I WHERE I.PublicID = E.IncidentID);

-- 3a-1. SUMMARY by exposure kind
SELECT ExposureKind, LossParty, COUNT(*) AS Exposures, COUNT(DISTINCT IncidentID_OnExposure) AS DistinctIncidentIDs, COUNT(DISTINCT ClaimRef) AS Claims,
       COUNT(DISTINCT GW_HDR_CASEID) AS HeaderCases, SUM(RoleRowsCarryingThisIncident) AS RoleRowsAffected
FROM #HC3A GROUP BY ExposureKind, LossParty ORDER BY Exposures DESC;
-- how big is it compared with all exposures that have an IncidentID
SELECT COUNT(*) AS ExposuresWithIncidentID,
       SUM(CASE WHEN NOT EXISTS (SELECT 1 FROM dbo.IS_INCIDENT I WHERE I.PublicID = E.IncidentID) THEN 1 ELSE 0 END) AS IncidentIdNotFoundInIS_INCIDENT
FROM dbo.IS_EXPOSURE_HOUSEHOLD E WHERE E.IncidentID IS NOT NULL;

-- 3a-2. THE LIST FOR BA: claim, header case ID, case ID, exposure, incident ID from the exposure   (@C3Kind: 'THIRD PARTY' / 'BUILDINGS' / 'CONTENTS' or NULL for all)
DECLARE @C3Kind VARCHAR(20) = NULL;
SELECT ClaimRef, GW_HDR_CASEID, CaseID, ExposureKind, LossParty, ExposureID, IncidentID_OnExposure, RoleRowsCarryingThisIncident, IncidentTableCheck
FROM #HC3A WHERE @C3Kind IS NULL OR ExposureKind = @C3Kind
ORDER BY ExposureKind, ClaimRef;

-- 3b. claim contact roles that carry an IncidentID that is not in IS_INCIDENT
SELECT CLM.CLAIM_REF AS ClaimRef, CLM.GW_HDR_CASEID AS GW_HDR_CASEID, CONVERT(VARCHAR(64), HDR.CASEID) AS CaseID,
       R.Role, R.ClaimContactID, HR.HDR_ID, R.ExposureID, R.IncidentID AS IncidentID_OnRole,
       'IncidentID on the role is NOT FOUND in IS_INCIDENT' AS IncidentTableCheck
INTO #HC3B
FROM dbo.IS_CLAIMCONTACTROLE R
CROSS APPLY (SELECT TRY_CONVERT(BIGINT, SUBSTRING(R.PublicID, 10, NULLIF(CHARINDEX('_', R.PublicID, 10), 0) - 10)) AS HDR_ID) HR   -- 'mig:hhccr' = 9 characters
JOIN dbo.IS_CLAIMCONTACT CC     ON CC.PublicID = R.ClaimContactID
JOIN dbo.IS_CLAIM_MASTER CLM    ON CLM.PublicID = CC.ClaimID
LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR HDR ON HDR.ID = HR.HDR_ID
WHERE R.PublicID LIKE 'mig:hhccr%' AND R.IncidentID IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.IS_INCIDENT I WHERE I.PublicID = R.IncidentID);

-- 3b-1. by role
SELECT Role, COUNT(*) AS ContactRoleRows, COUNT(DISTINCT IncidentID_OnRole) AS DistinctIncidentIDs, COUNT(DISTINCT ClaimRef) AS Claims, COUNT(DISTINCT GW_HDR_CASEID) AS HeaderCases
FROM #HC3B GROUP BY Role ORDER BY ContactRoleRows DESC;
-- 3b-2. THE LIST FOR BA
SELECT ClaimRef, GW_HDR_CASEID, CaseID, Role, ClaimContactID, HDR_ID, ExposureID, IncidentID_OnRole, IncidentTableCheck
FROM #HC3B ORDER BY Role, ClaimRef;
-- 3b-3. proof that 3b comes from 3a: role rows whose missing incident is also on an exposure from 3a (the two numbers should be equal)
SELECT SUM(CASE WHEN A.IncidentID_OnExposure IS NOT NULL THEN 1 ELSE 0 END) AS RoleRowsWhoseIncidentIsAlsoMissingOnAnExposure, COUNT(*) AS AllRoleRowsWithMissingIncident
FROM #HC3B B LEFT JOIN (SELECT DISTINCT IncidentID_OnExposure FROM #HC3A) A ON A.IncidentID_OnExposure = B.IncidentID_OnRole;
GO


/* =====================================================================================
   ALL CLAIMS - one list of every claim / header case that appears in at least one of the three checks
   ===================================================================================== */
SELECT ClaimRef, GW_HDR_CASEID,
       MAX(CASE WHEN CheckNo = 1 THEN 'YES' ELSE '' END) AS [Check1_SameRoleSameCase_DifferentContacts],
       MAX(CASE WHEN CheckNo = 2 THEN 'YES' ELSE '' END) AS [Check2_NoVehicleIncidentOnCase],
       MAX(CASE WHEN CheckNo = 3 THEN 'YES' ELSE '' END) AS [Check3_IncidentNotInIS_INCIDENT]
FROM (
    SELECT ClaimRef, GW_HDR_CASEID, 1 AS CheckNo FROM #HC1G
    UNION ALL SELECT ClaimRef, GW_HDR_CASEID, 2 FROM #HC2
    UNION ALL SELECT ClaimRef, GW_HDR_CASEID, 3 FROM #HC3A
    UNION ALL SELECT ClaimRef, GW_HDR_CASEID, 3 FROM #HC3B
) X
GROUP BY ClaimRef, GW_HDR_CASEID
ORDER BY ClaimRef;
