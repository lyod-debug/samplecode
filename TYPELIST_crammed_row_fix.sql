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
-- query in chat before running. 'TP Driver (Thief)' and 'Company' are
-- DELIBERATELY EXCLUDED here - splitting doesn't resolve them, they
-- each appear in two different crammed cells pointing to two different
-- target codes and need a real decision from whoever owns this table,
-- not a mechanical split. See the note below this block.
INSERT INTO dbo.TYPELIST_SPLIT_CONFIRMED VALUES
('ClaimantType', 'TP Vehicle Owner TP Driver (Thief) Company (for V2 VEH case)', 'TP Vehicle Owner'),
('ClaimantType', 'TP Driver & Owner TP Driver TP Driver (DOC) TP Driver (Thief) Alleged Vandal', 'TP Driver & Owner'),
('ClaimantType', 'TP Driver & Owner TP Driver TP Driver (DOC) TP Driver (Thief) Alleged Vandal', 'TP Driver'),
('ClaimantType', 'TP Driver & Owner TP Driver TP Driver (DOC) TP Driver (Thief) Alleged Vandal', 'TP Driver (DOC)'),
('ClaimantType', 'TP Driver & Owner TP Driver TP Driver (DOC) TP Driver (Thief) Alleged Vandal', 'Alleged Vandal'),
('ClaimantType', 'Adult Pedestrian Child Pedestrian', 'Adult Pedestrian'),
('ClaimantType', 'Adult Pedestrian Child Pedestrian', 'Child Pedestrian'),
('ClaimantType', 'TP Property Owner Company (for V2 PRO case)', 'TP Property Owner'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Motorcyclist'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Adult Cyclist'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Child Cyclist'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Pillion Passenger'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Registered Keeper'),
('ClaimantType', 'Motorcyclist Adult Cyclist Child Cyclist Pillion Passenger Registered Keeper Secondary Victim', 'Secondary Victim');

-- STILL AMBIGUOUS, NOT AUTO-RESOLVED - take this to whoever owns
-- TYPELIST_TABLE_MAPPING for a real decision before this can be fully clean:
-- 'TP Driver (Thief)' -> currently sits under BOTH 'veh_other_owner'
--   (the VEH-case cell) AND 'veh_other_driver' (the other cell)
-- 'Company' -> currently sits under BOTH 'veh_other_owner' (VEH case)
--   AND 'propertyowner' (PRO case) - and the original CMP-104 sheet
--   separately said 'other' - a THIRD candidate answer
-- Once a real single answer is decided for each, add it to
-- TYPELIST_SPLIT_CONFIRMED above manually with its correct target
-- GW_TypeCode - until then, these two specific values will still have
-- more than one row after the split runs.

/* --------------------------------------------------------------
   STEP 3: apply the confirmed splits. Expands each crammed row into
   N individual rows (carrying every other column forward unchanged),
   then removes the original crammed row. BACK UP the table before
   running this on anything but a small confirmed batch.
   -------------------------------------------------------------- */
INSERT INTO SourceStaging.dbo.TYPELIST_TABLE_MAPPING
(Vectus_TypeCode, Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name)
SELECT
    SC.IndividualVectusTypeCode,
    ORIG.Vectus_Description, ORIG.[Household/Motor/Both], ORIG.TypeList_Name,
    ORIG.TypeList_CC_Table_Name, ORIG.GW_TypeCode, ORIG.GW_TypeCode_Description, ORIG.Name
FROM dbo.TYPELIST_SPLIT_CONFIRMED SC
INNER JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING ORIG
    ON ORIG.TypeList_Name = SC.TypeList_Name AND ORIG.Vectus_TypeCode = SC.OriginalCrammedValue;

DELETE ORIG
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING ORIG
INNER JOIN (SELECT DISTINCT TypeList_Name, OriginalCrammedValue FROM dbo.TYPELIST_SPLIT_CONFIRMED) SC
    ON ORIG.TypeList_Name = SC.TypeList_Name AND ORIG.Vectus_TypeCode = SC.OriginalCrammedValue;

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

-- Confirms exact-match ClaimantType now works for everything EXCEPT the
-- two still-ambiguous values - those two are expected to still show up
-- here until a real decision is made and added above
SELECT DISTINCT T.DISPLAY_STRING
FROM SourceStaging.VECCASRN.VEC_GW_TPTYPE T
WHERE T.DISPLAY_STRING IS NOT NULL
  AND NOT EXISTS (
      SELECT 1 FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING TL
      WHERE TL.TypeList_Name = 'ClaimantType' AND TL.Vectus_TypeCode = T.DISPLAY_STRING
  );

-- Duplicate check - should return ONLY 'TP Driver (Thief)' and 'Company'
-- until those two are resolved; anything else here means a mistake in
-- the split above
SELECT Vectus_TypeCode, COUNT(*) AS dup_count
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name = 'ClaimantType'
GROUP BY Vectus_TypeCode
HAVING COUNT(*) > 1;
