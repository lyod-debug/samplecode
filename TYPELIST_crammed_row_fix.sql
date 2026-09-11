/* =====================================================================
   TYPELIST_TABLE_MAPPING — crammed-row fix, using direct capture-first
   delete/reinsert for every field (not text-matching against the
   crammed string, which repeatedly failed due to inconsistent internal
   spacing, tabs, and non-breaking spaces in the real data). Each
   section below: identify the crammed row via a short, distinctive,
   wildcard-separated word pattern (immune to whatever invisible
   character sits between words), capture its real column values first,
   delete it, then insert clean replacement rows reusing those real
   values - never guessing or typing a GW_TypeCode from memory.
   ===================================================================== */

/* --------------------------------------------------------------
   STEP 1: find every crammed row across the WHOLE table, not just
   the three TypeList_Names already checked below. High space_count
   relative to typical phrase length is a signal to review, not a verdict.
   -------------------------------------------------------------- */
SELECT TypeList_Name, Vectus_TypeCode,
    LEN(Vectus_TypeCode) - LEN(REPLACE(Vectus_TypeCode, ' ', '')) AS space_count
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE Vectus_TypeCode IS NOT NULL
ORDER BY space_count DESC;

-- CLAIMANTTYPE fix already applied and confirmed working (the capture/
-- delete/insert steps you already ran) - see ClaimantType_recovery.sql
-- for the actual final values now in the table.

/* --------------------------------------------------------------
   STEP 2b: diagnose the invisible-character issue before trusting the
   normalization below. Run this first - if it shows HAS TAB or HAS
   NON-BREAKING SPACE, that confirms what NormalizeSpaces() needs to
   handle (already updated below to cover both).
   -------------------------------------------------------------- */
SELECT Vectus_TypeCode,
    CASE WHEN Vectus_TypeCode LIKE '%' + CHAR(9) + '%' THEN 'HAS TAB' ELSE 'no tab' END AS tab_check,
    CASE WHEN Vectus_TypeCode LIKE '%' + CHAR(160) + '%' THEN 'HAS NON-BREAKING SPACE' ELSE 'no nbsp' END AS nbsp_check
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name = 'ClaimantType';

/* --------------------------------------------------------------
   STEP 3 (REPLACED): delete-and-reinsert instead of matching the whole
   crammed string. This sidesteps the whitespace/tab/invisible-character
   problem entirely - each crammed row is found by a short, distinctive
   multi-word fragment with WILDCARDS BETWEEN EACH WORD (not just at the
   start/end), so it doesn't matter what invisible character sits
   between "TP" and "Vehicle" and "Owner" - only that those three words
   appear in that order somewhere in the row.
   STEP 3a: capture each crammed row's OTHER columns (GW_TypeCode,
   TypeList_CC_Table_Name, etc.) into a staging table BEFORE deleting -
   this way we never have to know or type those values ourselves, we
   just carry the real ones forward.
   -------------------------------------------------------------- */
IF OBJECT_ID('dbo.TYPELIST_CLAIMANTTYPE_CAPTURED', 'U') IS NOT NULL DROP TABLE dbo.TYPELIST_CLAIMANTTYPE_CAPTURED;
SELECT *,
    CASE
        WHEN Vectus_TypeCode LIKE '%TP%Vehicle%Owner%' THEN 'VEH_ROW'
        WHEN Vectus_TypeCode LIKE '%Alleged%Vandal%' THEN 'DRIVER_ROW'
        WHEN Vectus_TypeCode LIKE '%Adult%Pedestrian%' THEN 'PEDESTRIAN_ROW'
        WHEN Vectus_TypeCode LIKE '%TP%Property%Owner%' THEN 'PRO_ROW'
        WHEN Vectus_TypeCode LIKE '%Secondary%Victim%' THEN 'OTHER_ROW'
    END AS RowTag
INTO dbo.TYPELIST_CLAIMANTTYPE_CAPTURED
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name = 'ClaimantType'
  AND (
        Vectus_TypeCode LIKE '%TP%Vehicle%Owner%'
     OR Vectus_TypeCode LIKE '%Alleged%Vandal%'
     OR Vectus_TypeCode LIKE '%Adult%Pedestrian%'
     OR Vectus_TypeCode LIKE '%TP%Property%Owner%'
     OR Vectus_TypeCode LIKE '%Secondary%Victim%'
      );

-- CHECK before proceeding: this must return exactly 5 rows, one per
-- RowTag, with no NULLs in RowTag. If it doesn't, STOP and look at why -
-- do not continue to the DELETE below until this looks right.
SELECT * FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED;

/* --------------------------------------------------------------
   STEP 3b: delete the original crammed rows, same identifying condition.
   -------------------------------------------------------------- */
DELETE FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name = 'ClaimantType'
  AND (
        Vectus_TypeCode LIKE '%TP%Vehicle%Owner%'
     OR Vectus_TypeCode LIKE '%Alleged%Vandal%'
     OR Vectus_TypeCode LIKE '%Adult%Pedestrian%'
     OR Vectus_TypeCode LIKE '%TP%Property%Owner%'
     OR Vectus_TypeCode LIKE '%Secondary%Victim%'
      );

/* --------------------------------------------------------------
   STEP 3c: insert clean rows, reusing each captured row's other real
   column values via RowTag - only the new individual Vectus_TypeCode
   is hardcoded, everything else comes from the real captured data.
   'TP Driver (Thief)' is INTERIM per BA - maps to whatever GW_TypeCode
   the DRIVER_ROW carries (veh_other_driver), pending her real decision.
   -------------------------------------------------------------- */
INSERT INTO SourceStaging.dbo.TYPELIST_TABLE_MAPPING
(Vectus_TypeCode, Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name)
SELECT 'TP Vehicle Owner', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'VEH_ROW'
UNION ALL
SELECT 'Company (for V2 VEH case)', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'VEH_ROW'
UNION ALL
SELECT 'TP Driver & Owner', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'DRIVER_ROW'
UNION ALL
SELECT 'TP Driver', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'DRIVER_ROW'
UNION ALL
SELECT 'TP Driver (DOC)', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'DRIVER_ROW'
UNION ALL
SELECT 'TP Driver (Thief)', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'DRIVER_ROW'
UNION ALL
SELECT 'Alleged Vandal', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'DRIVER_ROW'
UNION ALL
SELECT 'Adult Pedestrian', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'PEDESTRIAN_ROW'
UNION ALL
SELECT 'Child Pedestrian', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'PEDESTRIAN_ROW'
UNION ALL
SELECT 'TP Property Owner', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'PRO_ROW'
UNION ALL
SELECT 'Company (for V2 PRO case)', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'PRO_ROW'
UNION ALL
SELECT 'Motorcyclist', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'OTHER_ROW'
UNION ALL
SELECT 'Adult Cyclist', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'OTHER_ROW'
UNION ALL
SELECT 'Child Cyclist', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'OTHER_ROW'
UNION ALL
SELECT 'Pillion Passenger', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'OTHER_ROW'
UNION ALL
SELECT 'Registered Keeper', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'OTHER_ROW'
UNION ALL
SELECT 'Secondary Victim', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_CLAIMANTTYPE_CAPTURED WHERE RowTag = 'OTHER_ROW';

/* --------------------------------------------------------------
   STEP 4: confirm the fix worked - exact-match joins should now find
   everything they need
   -------------------------------------------------------------- */
SELECT DISTINCT CS.STATUS
FROM SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS
WHERE CS.GCURRENT = 'X'
  AND NOT EXISTS (
      SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
      WHERE TL.TypeList_Name = 'ExposureState' AND TL.Vectus_TypeCode = CS.STATUS
  );

SELECT DISTINCT LIAB.LIAB_STATUS
FROM SourceStaging.VECCASRN.VEC_GW_LIABILITY LIAB
WHERE LIAB.CURRENT_REC = 'X'
  AND NOT EXISTS (
      SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
      WHERE TL.TypeList_Name = 'LiabilityPosition_Adm' AND TL.Vectus_TypeCode = LIAB.LIAB_STATUS
  );

-- Confirms exact-match ClaimantType now works for everything. 'Company'
-- is EXPECTED to still show up here - it's never meant to be found by a
-- plain DISPLAY_STRING match, since it's resolved in the exposure proc's
-- own code (context-aware, based on RuleKey), not by this table alone.
-- 'TP Driver (Thief)' should NOT show up here anymore (interim fix applied).
SELECT DISTINCT T.DISPLAY_STRING
FROM SourceStaging.VECCASRN.VEC_GW_TPTYPE T
WHERE T.DISPLAY_STRING IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
      WHERE TL.TypeList_Name = 'ClaimantType' AND TL.Vectus_TypeCode = T.DISPLAY_STRING
  );

-- Duplicate check - should return ZERO rows now. The two Company
-- variants are stored as two DIFFERENT literal strings (with their VEH/
-- PRO tags), so they're not duplicates at the data level at all - any
-- row returned here means a real mistake in the split above.
SELECT Vectus_TypeCode, COUNT(*) AS dup_count
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name = 'ClaimantType'
GROUP BY Vectus_TypeCode
HAVING COUNT(*) > 1;


/* =====================================================================
   EXPOSURESTATE - same safe capture-first pattern, avoiding the same
   whitespace-matching problem. IMPORTANT DIFFERENCE from ClaimantType:
   the crammed cell "Open Re-opened Re-Opened" has only ONE original
   GW_TypeCode - it is NOT yet confirmed whether 'Open' and 'Re-Opened'
   are meant to share that same code, or need two different ones. DO
   NOT run the final INSERT until you've looked at the captured code
   and confirmed which applies.
   ===================================================================== */

-- STEP A: capture the crammed row's real data. Wildcards between words
-- again, same reasoning as before - sidesteps whatever invisible
-- character is actually sitting between "Open" and "Re-opened".
IF OBJECT_ID('dbo.TYPELIST_EXPOSURESTATE_CAPTURED', 'U') IS NOT NULL DROP TABLE dbo.TYPELIST_EXPOSURESTATE_CAPTURED;
SELECT *
INTO dbo.TYPELIST_EXPOSURESTATE_CAPTURED
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name = 'ExposureState'
  AND Vectus_TypeCode LIKE '%Open%'
  AND Vectus_TypeCode LIKE '%Re%Opened%';

-- CHECK: must show exactly 1 row. Look at the GW_TypeCode value here -
-- this tells you what 'Open' should map to for certain. It does NOT
-- yet tell you what 'Re-Opened' should map to - that needs a separate
-- check (e.g. does a distinct 'reopened'-style code already exist
-- elsewhere in the typelist for this same TypeList_Name?).
SELECT * FROM dbo.TYPELIST_EXPOSURESTATE_CAPTURED;

-- STEP B: delete the crammed row (only once you've seen the capture above)
DELETE FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name = 'ExposureState'
  AND Vectus_TypeCode LIKE '%Open%'
  AND Vectus_TypeCode LIKE '%Re%Opened%';

-- STEP C: insert 'Open' using the real captured code - this part is safe
INSERT INTO SourceStaging.dbo.TYPELIST_TABLE_MAPPING
(Vectus_TypeCode, Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name)
SELECT 'Open', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_EXPOSURESTATE_CAPTURED;

-- STEP D: insert 'Re-Opened' - REVIEW THIS BEFORE RUNNING. As written,
-- this reuses the SAME code as 'Open' (copy-paste of Step C), which may
-- be wrong. If 'Re-Opened' needs a DIFFERENT code, replace GW_TypeCode/
-- GW_TypeCode_Description/Name below with the correct real values
-- instead of the captured ones.
INSERT INTO SourceStaging.dbo.TYPELIST_TABLE_MAPPING
(Vectus_TypeCode, Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name)
SELECT 'Re-Opened', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_EXPOSURESTATE_CAPTURED;


/* =====================================================================
   LIABILITYPOSITION_ADM - same pattern, same caution. Crammed cell:
   "Admitted Split Agreed" splits into 'Admitted' and 'Split Agreed'.
   SAME WARNING: only ONE original code exists for this crammed row -
   not confirmed whether both split values should share it.
   ===================================================================== */

IF OBJECT_ID('dbo.TYPELIST_LIABILITY_CAPTURED', 'U') IS NOT NULL DROP TABLE dbo.TYPELIST_LIABILITY_CAPTURED;
SELECT *
INTO dbo.TYPELIST_LIABILITY_CAPTURED
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name = 'LiabilityPosition_Adm'
  AND Vectus_TypeCode LIKE '%Admitted%'
  AND Vectus_TypeCode LIKE '%Split%Agreed%';

-- CHECK: must show exactly 1 row - review GW_TypeCode before proceeding
SELECT * FROM dbo.TYPELIST_LIABILITY_CAPTURED;

DELETE FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name = 'LiabilityPosition_Adm'
  AND Vectus_TypeCode LIKE '%Admitted%'
  AND Vectus_TypeCode LIKE '%Split%Agreed%';

-- 'Admitted' - using the real captured code, safe
INSERT INTO SourceStaging.dbo.TYPELIST_TABLE_MAPPING
(Vectus_TypeCode, Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name)
SELECT 'Admitted', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_LIABILITY_CAPTURED;

-- 'Split Agreed' - REVIEW BEFORE RUNNING, same reasoning as 'Re-Opened'
-- above. 'Admitted' (full liability) and 'Split Agreed' (partial/50-50
-- liability) are different legal positions - check whether they
-- genuinely need different codes before trusting this reuse.
INSERT INTO SourceStaging.dbo.TYPELIST_TABLE_MAPPING
(Vectus_TypeCode, Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name)
SELECT 'Split Agreed', Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name
FROM dbo.TYPELIST_LIABILITY_CAPTURED;

-- After both are done, confirm against the real source values (same
-- queries as before)
SELECT DISTINCT CS.STATUS
FROM SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS
WHERE CS.GCURRENT = 'X'
  AND NOT EXISTS (
      SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
      WHERE TL.TypeList_Name = 'ExposureState' AND TL.Vectus_TypeCode = CS.STATUS
  );

SELECT DISTINCT LIAB.LIAB_STATUS
FROM SourceStaging.VECCASRN.VEC_GW_LIABILITY LIAB
WHERE LIAB.CURRENT_REC = 'X'
  AND NOT EXISTS (
      SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
      WHERE TL.TypeList_Name = 'LiabilityPosition_Adm' AND TL.Vectus_TypeCode = LIAB.LIAB_STATUS
  );
