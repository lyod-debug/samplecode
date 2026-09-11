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
   STEP 3: apply the confirmed splits. Expands each crammed row into
   N individual rows (carrying every other column forward unchanged),
   then removes the original crammed row. BACK UP the table before
   running this on anything but a small confirmed batch.
   FIXED: the real crammed cells have inconsistent internal spacing
   (extra/uneven spaces between the different values someone typed by
   hand) - an exact string match against what was typed here would
   silently find nothing. NormalizeSpaces() collapses any run of 2+
   spaces down to 1 (and trims the ends) on BOTH sides of the
   comparison, so matching works regardless of the real spacing.
   -------------------------------------------------------------- */
IF OBJECT_ID('dbo.NormalizeSpaces', 'FN') IS NOT NULL DROP FUNCTION dbo.NormalizeSpaces;
GO
CREATE FUNCTION dbo.NormalizeSpaces(@Input VARCHAR(500))
RETURNS VARCHAR(500)
AS
BEGIN
    RETURN LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(@Input, ' ', '<>'), '><', ''), '<>', ' ')));
END
GO

INSERT INTO SourceStaging.dbo.TYPELIST_TABLE_MAPPING
(Vectus_TypeCode, Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name)
SELECT
    SC.IndividualVectusTypeCode,
    ORIG.Vectus_Description, ORIG.[Household/Motor/Both], ORIG.TypeList_Name,
    ORIG.TypeList_CC_Table_Name, ORIG.GW_TypeCode, ORIG.GW_TypeCode_Description, ORIG.Name
FROM dbo.TYPELIST_SPLIT_CONFIRMED SC
INNER JOIN SourceStaging.dbo.TYPELIST_TABLE_MAPPING ORIG
    ON ORIG.TypeList_Name = SC.TypeList_Name
   AND dbo.NormalizeSpaces(ORIG.Vectus_TypeCode) = dbo.NormalizeSpaces(SC.OriginalCrammedValue);

DELETE ORIG
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING ORIG
INNER JOIN (SELECT DISTINCT TypeList_Name, OriginalCrammedValue FROM dbo.TYPELIST_SPLIT_CONFIRMED) SC
    ON ORIG.TypeList_Name = SC.TypeList_Name
   AND dbo.NormalizeSpaces(ORIG.Vectus_TypeCode) = dbo.NormalizeSpaces(SC.OriginalCrammedValue);

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
