/* =====================================================================
   BA EVIDENCE - MOTOR - INCIDENT-LINKED ROLES  (IS layer only, no ccst)
   Roles covered: repairshop, hirecompany_adm, thirdparty_adm,
                  tpinsurer_Adm, recoveryagent   (all have Link_to_Incident = YES for TP contacts)

   Works from the SOURCE of the proc (CONTACT_MASTER_MOTOR + lookup + IS_EXPOSURE_MOTOR + IS_INCIDENT),
   NOT from IS_CLAIMCONTACTROLE, because the proc deletes/changes rows before inserting.
   Run the SETUP block first (same session), then any of Q1..Q5.

   Allowed incident subtypes (comes from the LOAD ERRORS, not from BA / mapping):
       repairshop, hirecompany_adm, thirdparty_adm, tpinsurer_Adm : VehicleIncident only
       recoveryagent                                              : VehicleIncident or MobilePropertyIncident
   Unique per incident (load errors #8 / #9): recoveryagent, tpinsurer_Adm

   ASSUMED NAME: IS_INCIDENT.Subtype   (rename if different)
   ===================================================================== */

/* ============================ SETUP ============================ */
IF OBJECT_ID('tempdb..#EV_ROLE') IS NOT NULL DROP TABLE #EV_ROLE;
IF OBJECT_ID('tempdb..#EV_INC')  IS NOT NULL DROP TABLE #EV_INC;
IF OBJECT_ID('tempdb..#EV_PAIR') IS NOT NULL DROP TABLE #EV_PAIR;
IF OBJECT_ID('tempdb..#EV_OUT')  IS NOT NULL DROP TABLE #EV_OUT;

-- 1. every contact holding one of the 5 roles where the lookup says Link_to_Incident = YES
SELECT DISTINCT
       CLM.PublicID                       AS ClaimPublicID,
       C.CLAIM_REF,
       CC.PublicID                        AS ClaimContactID,
       C.PublicID                         AS ContactPublicID,
       C.HDR_ID, C.HDR_TYPE_ID, C.LINK_TYPE_ID,
       CONVERT(VARCHAR(64), HDR.CASEID)   AS TP_CaseID,          -- for TP contacts = TP.ID
       L.GWCC_Role_TYPECODE               AS Role
INTO #EV_ROLE
FROM IntermediateStaging_DEV.dbo.CONTACT_MASTER_MOTOR C
JOIN IntermediateStaging_DEV.dbo.IS_CLAIM_MASTER CLM
       ON C.GW_HDR_CASEID = CLM.GW_HDR_CASEID AND CLM.PRODUCT = 'MOTOR'
JOIN IntermediateStaging_DEV.dbo.IS_CLAIMCONTACT CC
       ON CC.ContactID = C.PublicID AND CC.ClaimID = CLM.PublicID
JOIN SourceStaging.VECCASRN.VEC_GW_CF_HDR HDR ON HDR.ID = C.HDR_ID
JOIN IntermediateStaging_DEV.dbo.CLAIM_CONTACT_ROLE_LOOKUP L
       ON  L.PRODUCT = 'Motor'
       AND L.HDR_TYPEID = C.HDR_TYPE_ID
       AND (L.LINK_TYPEID = C.LINK_TYPE_ID OR L.GWCF_LNKID = C.LINK_TYPE_ID)
WHERE L.Link_to_Incident = 'YES'
  AND L.GWCC_Role_TYPECODE IN ('repairshop','hirecompany_adm','thirdparty_adm','tpinsurer_Adm','recoveryagent');

-- 2. every incident that each TP case produced (via its exposures)
SELECT DISTINCT
       CONVERT(VARCHAR(64), E.VectusCaseID_Adm) AS TP_CaseID,
       E.IncidentID,
       I.Subtype                                AS IncidentSubtype
INTO #EV_INC
FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR E
JOIN IntermediateStaging_DEV.dbo.IS_INCIDENT I ON I.PublicID = E.IncidentID
WHERE E.SourceOrigin_Adm IN ('TP_VEH','TP_INJ','TP_PRO','TP_HIRE')
  AND E.IncidentID IS NOT NULL;

-- 3. role x every incident on its case, with the Guidewire verdict for that pair
SELECT R.*, X.IncidentID, X.IncidentSubtype,
       CASE WHEN X.IncidentID IS NULL THEN NULL
            WHEN R.Role = 'recoveryagent' AND X.IncidentSubtype IN ('VehicleIncident','MobilePropertyIncident') THEN 1
            WHEN R.Role <> 'recoveryagent' AND X.IncidentSubtype = 'VehicleIncident' THEN 1
            ELSE 0 END AS GW_Allows
INTO #EV_PAIR
FROM #EV_ROLE R
LEFT JOIN #EV_INC X ON X.TP_CaseID = R.TP_CaseID;

-- 4. one row per contact-role: what the proc can pick
SELECT  P.ClaimPublicID, P.CLAIM_REF, P.ClaimContactID, P.ContactPublicID, P.HDR_ID,
        P.HDR_TYPE_ID, P.LINK_TYPE_ID, P.TP_CaseID, P.Role,
        COUNT(P.IncidentID)                                        AS IncidentsOnCase,
        SUM(CASE WHEN P.GW_Allows = 1 THEN 1 ELSE 0 END)           AS AllowedIncidentsOnCase,
        SUM(CASE WHEN P.GW_Allows = 0 THEN 1 ELSE 0 END)           AS NotAllowedIncidentsOnCase,
        MIN(CASE WHEN P.GW_Allows = 1 THEN P.IncidentID END)       AS PickedIncidentID,   -- same MIN rule as the proc
        STRING_AGG(CONVERT(VARCHAR(40), P.IncidentSubtype), ', ')  AS SubtypesOnCase
INTO #EV_OUT
FROM #EV_PAIR P
GROUP BY P.ClaimPublicID, P.CLAIM_REF, P.ClaimContactID, P.ContactPublicID, P.HDR_ID,
         P.HDR_TYPE_ID, P.LINK_TYPE_ID, P.TP_CaseID, P.Role;
/* ========================== END SETUP ========================== */


/* ---------------------------------------------------------------------
   Q1 - THE BIG PICTURE FOR BA
   For every role: how many contact-role rows, and in how many the proc finds an allowed incident.
   NO_ALLOWED_INCIDENT = case has incidents but none of an allowed subtype (Guidewire would reject any link)
   NO_INCIDENT_AT_ALL  = the TP case produced no incident (or case not found in IS_EXPOSURE_MOTOR)
   --------------------------------------------------------------------- */
SELECT  Role,
        COUNT(*)                                                                 AS ContactRoleRows,
        COUNT(DISTINCT CLAIM_REF)                                                AS Claims,
        SUM(CASE WHEN AllowedIncidentsOnCase > 0 THEN 1 ELSE 0 END)              AS HasAllowedIncident_LinkOK,
        SUM(CASE WHEN AllowedIncidentsOnCase = 0 AND IncidentsOnCase > 0 THEN 1 ELSE 0 END) AS NO_ALLOWED_INCIDENT_only_wrong_subtypes,
        SUM(CASE WHEN IncidentsOnCase = 0 THEN 1 ELSE 0 END)                     AS NO_INCIDENT_AT_ALL,
        SUM(CASE WHEN AllowedIncidentsOnCase > 0 AND NotAllowedIncidentsOnCase > 0 THEN 1 ELSE 0 END)
                                                                                 AS AllowedAndNotAllowedBothExist
FROM #EV_OUT
GROUP BY Role
ORDER BY Role;


/* ---------------------------------------------------------------------
   Q2 - THE DANGLING ROLES (the "nothing to link to" scenario)
   Contacts whose lookup says "link to incident" but the TP case has no incident of an allowed subtype.
   WhatProcDoesToday  (with @DropDanglingRoles = 1):
      repairshop, hirecompany_adm, tpinsurer_Adm, recoveryagent -> row DELETED (all links NULL, role is in the drop list)
      thirdparty_adm                                            -> row INSERTED claim-only (not in the drop list)
   --------------------------------------------------------------------- */
SELECT  CLAIM_REF, TP_CaseID, HDR_ID, ContactPublicID, HDR_TYPE_ID, LINK_TYPE_ID, Role,
        IncidentsOnCase, SubtypesOnCase,
        CASE WHEN IncidentsOnCase = 0
             THEN 'TP case has NO incident'
             ELSE 'TP case has only non-allowed subtypes: ' + SubtypesOnCase END  AS Situation,
        CASE WHEN Role IN ('repairshop','hirecompany_adm','tpinsurer_Adm','recoveryagent')
             THEN 'DELETED by DEDUP_ROLE (all links NULL)'
             ELSE 'INSERTED claim-only (ExposureID/IncidentID/PolicyID NULL)' END AS WhatProcDoesToday
FROM #EV_OUT
WHERE AllowedIncidentsOnCase = 0
ORDER BY Role, CLAIM_REF, TP_CaseID;


/* ---------------------------------------------------------------------
   Q3 - THE "GUIDEWIRE REJECTS THIS LINK" EXAMPLES
   One row per contact-role x incident on its case. Rows with GW_Allows = 0 are the links
   Guidewire refuses (load errors #2-#5, #10). IsMinPick shows the incident a plain MIN(IncidentID)
   pick (no subtype filter) would have chosen - if that one is GW_Allows = 0, that is the load error.
   --------------------------------------------------------------------- */
;WITH X AS (
    SELECT P.*,
           MIN(P.IncidentID) OVER (PARTITION BY P.ContactPublicID, P.HDR_ID, P.Role, P.TP_CaseID) AS MinIncidentOnCase
    FROM #EV_PAIR P
    WHERE P.IncidentID IS NOT NULL
)
SELECT  CLAIM_REF, TP_CaseID, HDR_ID, Role,
        IncidentID, IncidentSubtype,
        CASE WHEN GW_Allows = 1 THEN 'allowed' ELSE 'GUIDEWIRE REJECTS' END              AS GuidewireVerdict,
        CASE WHEN IncidentID = MinIncidentOnCase THEN 'YES' ELSE '' END                  AS IsMinPick_whatSimplePickWouldChoose,
        CASE WHEN EXISTS (SELECT 1 FROM #EV_PAIR Z
                          WHERE Z.HDR_ID = X.HDR_ID AND Z.Role = X.Role AND Z.TP_CaseID = X.TP_CaseID AND Z.GW_Allows = 1)
             THEN 'case also has an allowed incident (proc picks that)'
             ELSE 'case has NO allowed incident (role dangling)' END                     AS Scenario
FROM X
WHERE EXISTS (SELECT 1 FROM #EV_PAIR Z
              WHERE Z.HDR_ID = X.HDR_ID AND Z.Role = X.Role AND Z.TP_CaseID = X.TP_CaseID AND Z.GW_Allows = 0)
ORDER BY Role, CLAIM_REF, TP_CaseID, HDR_ID, IncidentID;


/* Q3b - role x subtype table (the "which roles errored on which subtypes" slide) */
SELECT Role, IncidentSubtype,
       CASE WHEN MAX(GW_Allows) = 1 THEN 'allowed' ELSE 'GUIDEWIRE REJECTS' END AS GuidewireVerdict,
       COUNT(*) AS ContactRoleXIncidentRows, COUNT(DISTINCT CLAIM_REF) AS Claims
FROM #EV_PAIR
WHERE IncidentID IS NOT NULL
GROUP BY Role, IncidentSubtype
ORDER BY Role, GuidewireVerdict DESC, ContactRoleXIncidentRows DESC;


/* Q3c - 3 example claims per role for the rejected combinations */
SELECT * FROM (
    SELECT  CLAIM_REF, TP_CaseID, HDR_ID, Role, IncidentID, IncidentSubtype,
            ROW_NUMBER() OVER (PARTITION BY Role, IncidentSubtype ORDER BY CLAIM_REF, TP_CaseID) AS rn
    FROM #EV_PAIR
    WHERE GW_Allows = 0
) Z
WHERE rn <= 3
ORDER BY Role, IncidentSubtype, CLAIM_REF;


/* ---------------------------------------------------------------------
   Q4 - DUPLICATES  (recoveryagent / tpinsurer_Adm must be UNIQUE per incident)
   Several contacts with the same role would be linked to the SAME picked incident.
   ContactsSamePerson = 'same contact, several header rows' or 'different contacts'.
   --------------------------------------------------------------------- */
SELECT  CLAIM_REF, Role, PickedIncidentID, TP_CaseID,
        COUNT(*)                                             AS RowsOnSameIncident,
        COUNT(DISTINCT ContactPublicID)                      AS DistinctContacts,
        CASE WHEN COUNT(DISTINCT ContactPublicID) = 1
             THEN 'SAME contact on several header/link rows'
             ELSE 'DIFFERENT contacts, same role, same incident' END AS Kind,
        STRING_AGG(CONVERT(VARCHAR(20), HDR_ID), ', ')       AS HdrIds,
        STRING_AGG(CONVERT(VARCHAR(20), LINK_TYPE_ID), ', ') AS LinkTypeIds
FROM #EV_OUT
WHERE Role IN ('recoveryagent','tpinsurer_Adm')
  AND PickedIncidentID IS NOT NULL
GROUP BY CLAIM_REF, Role, PickedIncidentID, TP_CaseID
HAVING COUNT(*) > 1
ORDER BY RowsOnSameIncident DESC, CLAIM_REF;


/* Q4b - the detail rows behind each duplicate group (show BA the actual contacts) */
;WITH D AS (
    SELECT Role, PickedIncidentID
    FROM #EV_OUT
    WHERE Role IN ('recoveryagent','tpinsurer_Adm') AND PickedIncidentID IS NOT NULL
    GROUP BY Role, PickedIncidentID HAVING COUNT(*) > 1
)
SELECT O.CLAIM_REF, O.TP_CaseID, O.Role, O.PickedIncidentID,
       O.HDR_ID, O.ContactPublicID, O.HDR_TYPE_ID, O.LINK_TYPE_ID
FROM #EV_OUT O JOIN D ON D.Role = O.Role AND D.PickedIncidentID = O.PickedIncidentID
ORDER BY O.CLAIM_REF, O.Role, O.PickedIncidentID, O.HDR_ID;


/* ---------------------------------------------------------------------
   Q5 - ONE CLAIM END TO END (paste a CLAIM_REF from Q2/Q3/Q4 to walk BA through it)
   --------------------------------------------------------------------- */
DECLARE @ClaimRef VARCHAR(50) = '<CLAIM_REF>';
SELECT 'ROLE ROWS' AS Section, CLAIM_REF, TP_CaseID, HDR_ID, Role, PickedIncidentID, SubtypesOnCase
FROM #EV_OUT WHERE CLAIM_REF = @ClaimRef;
SELECT 'INCIDENTS ON EACH TP CASE' AS Section, R.CLAIM_REF, X.TP_CaseID, X.IncidentID, X.IncidentSubtype
FROM (SELECT DISTINCT CLAIM_REF, TP_CaseID FROM #EV_ROLE WHERE CLAIM_REF = @ClaimRef) R
JOIN #EV_INC X ON X.TP_CaseID = R.TP_CaseID;
