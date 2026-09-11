/* =====================================================================
   TYPELIST_TABLE_MAPPING — crammed-row diagnostic and fix template
   Run the diagnostic first. NEVER auto-split based on space-counting
   alone - "Under Investigation" is a legitimate single value with a
   space in it. Only populate TYPELIST_SPLIT_CONFIRMED once you've
   verified the correct split against the real source column (see the
   two queries in the chat message for ExposureState/LiabilityPosition_Adm
   specifically - do the same for any other flagged TypeList_Name).
   ===================================================================== */

/* --------------------------------------------------------------
   STEP 1: find every crammed row across the WHOLE table, not just
   the four TypeList_Names already checked. High space_count relative
   to typical phrase length is a signal to review, not a verdict.
   -------------------------------------------------------------- */
SELECT TypeList_Name, Vectus_TypeCode,
    LEN(Vectus_TypeCode) - LEN(REPLACE(Vectus_TypeCode, ' ', '')) AS space_count
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE Vectus_TypeCode IS NOT NULL
ORDER BY space_count DESC;

/* --------------------------------------------------------------
   STEP 2: once a specific crammed value's correct split is confirmed
   against the real source column, record it here. One row per
   individual value that should exist after the split.
   -------------------------------------------------------------- */
IF OBJECT_ID('dbo.TYPELIST_SPLIT_CONFIRMED', 'U') IS NOT NULL DROP TABLE dbo.TYPELIST_SPLIT_CONFIRMED;
CREATE TABLE dbo.TYPELIST_SPLIT_CONFIRMED (
    TypeList_Name           VARCHAR(100) NOT NULL,
    OriginalCrammedValue    VARCHAR(500) NOT NULL,
    IndividualVectusTypeCode VARCHAR(200) NOT NULL
);

-- CONFIRMED against real source data (VEC_GW_CASE_STATUS.STATUS /
-- VEC_GW_LIABILITY.LIAB_STATUS) - these are the only two crammed cells
-- that actually need splitting for exposure's purposes. 'Under
-- Investigation' and 'No Admission - Agree to deal' were confirmed to
-- already be single real values, not crammed - deliberately left alone.
INSERT INTO dbo.TYPELIST_SPLIT_CONFIRMED VALUES
('ExposureState', 'Open Re-opened Re-Opened', 'Open'),
('ExposureState', 'Open Re-opened Re-Opened', 'Re-Opened'),
('LiabilityPosition_Adm', 'Admitted Split Agreed', 'Admitted'),
('LiabilityPosition_Adm', 'Admitted Split Agreed', 'Split Agreed');

-- CLAIMANTTYPE: verify each against the real DISTINCT DISPLAY_STRING
-- query already run in chat.
-- 'TP Driver (Thief)' — INTERIM, per BA: temporarily maps to
-- veh_other_driver (the same target as the OTHER crammed cell it also
-- appears in) until her real decision comes back. Deliberately NOT
-- included in the veh_other_owner cell's split below - only this one.
-- MARK: search for "INTERIM" to find this when BA's real answer arrives.
-- 'Company' — genuinely needs a code change, not just a split. V2 never
-- differentiates vehicle-context vs property-context Company at the
-- source (both are just "Company"), so both context-tagged variants are
-- kept as their OWN distinct values here (reusing the exact tags already
-- in the source data), and the exposure proc itself now picks the right
-- one based on which case type (RuleKey) is being built - see the
-- updated join in IS_EXPOSURE_MOTOR_build.
INSERT INTO dbo.TYPELIST_SPLIT_CONFIRMED VALUES
('ClaimantType', 'TP Vehicle Owner TP Driver (Thief) Company (for V2 VEH case)', 'TP Vehicle Owner'),
('ClaimantType', 'TP Vehicle Owner TP Driver (Thief) Company (for V2 VEH case)', 'Company (for V2 VEH case)'),
('ClaimantType', 'TP Driver & Owner TP Driver TP Driver (DOC) TP Driver (Thief) Alleged Vandal', 'TP Driver & Owner'),
('ClaimantType', 'TP Driver & Owner TP Driver TP Driver (DOC) TP Driver (Thief) Alleged Vandal', 'TP Driver'),
('ClaimantType', 'TP Driver & Owner TP Driver TP Driver (DOC) TP Driver (Thief) Alleged Vandal', 'TP Driver (DOC)'),
('ClaimantType', 'TP Driver & Owner TP Driver TP Driver (DOC) TP Driver (Thief) Alleged Vandal', 'TP Driver (Thief)'), -- INTERIM per BA
('ClaimantType', 'TP Driver & Owner TP Driver TP Driver (DOC) TP Driver (Thief) Alleged Vandal', 'Alleged Vandal'),
('ClaimantType', 'Adult Pedestrian Child Pedestrian', 'Adult Pedestrian'),
('ClaimantType', 'Adult Pedestrian Child Pedestrian', 'Child Pedestrian'),
('ClaimantType', 'TP Property Owner Company (for V2 PRO case)', 'TP Property Owner'),
('ClaimantType', 'TP Property Owner Company (for V2 PRO case)', 'Company (for V2 PRO case)'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Motorcyclist'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Adult Cyclist'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Child Cyclist'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Pillion Passenger'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Registered Keeper'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Secondary Victim');

-- After this split runs, TYPELIST_TABLE_MAPPING will have TWO rows where
-- Vectus_TypeCode contains "Company" (the VEH-tagged one and the PRO-
-- tagged one) - that's expected and correct, NOT a duplicate to fix.
-- The exposure proc's join is what picks the right one per case type.

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
