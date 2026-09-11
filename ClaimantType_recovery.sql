/* =====================================================================
   RECOVERY - the 5 ClaimantType crammed rows were accidentally deleted
   from both the main table AND the staging capture table (re-running
   Step 3a's capture after Step 3b's DELETE had already removed the
   source rows - the DROP TABLE at the top of Step 3a wiped out the
   first, good capture, then the recapture found nothing).
   CHECK FOR A REAL BACKUP FIRST - this reconstruction uses values
   confirmed from your own earlier TYPELIST_TABLE_MAPPING sample data
   in this conversation, but TypeList_CC_Table_Name and
   GW_TypeCode_Description/Name are inferred by pattern, not re-verified
   fresh - please spot-check a row or two against another already-
   correct ClaimantType row in your table before trusting this fully.
   ===================================================================== */

INSERT INTO SourceStaging.dbo.TYPELIST_TABLE_MAPPING
(Vectus_TypeCode, Vectus_Description, [Household/Motor/Both], TypeList_Name, TypeList_CC_Table_Name, GW_TypeCode, GW_TypeCode_Description, Name)
VALUES
-- CONFIRMED target: veh_other_owner
('TP Vehicle Owner',          NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'veh_other_owner',  'Owner of other vehicle',  'Owner of other vehicle'),
('Company (for V2 VEH case)', NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'veh_other_owner',  'Owner of other vehicle',  'Owner of other vehicle'),

-- CONFIRMED target: veh_other_driver ('TP Driver (Thief)' is INTERIM per BA)
('TP Driver & Owner', NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'veh_other_driver', 'Driver of other vehicle', 'Driver of other vehicle'),
('TP Driver',         NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'veh_other_driver', 'Driver of other vehicle', 'Driver of other vehicle'),
('TP Driver (DOC)',   NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'veh_other_driver', 'Driver of other vehicle', 'Driver of other vehicle'),
('TP Driver (Thief)', NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'veh_other_driver', 'Driver of other vehicle', 'Driver of other vehicle'), -- INTERIM per BA
('Alleged Vandal',    NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'veh_other_driver', 'Driver of other vehicle', 'Driver of other vehicle'),

-- CONFIRMED target: bystander
('Adult Pedestrian', NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'bystander', 'Pedestrian or bystander', 'Pedestrian or bystander'),
('Child Pedestrian',  NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'bystander', 'Pedestrian or bystander', 'Pedestrian or bystander'),

-- CONFIRMED target: propertyowner
('TP Property Owner',         NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'propertyowner', 'Owner of the lost/damaged property', 'Owner of the lost/damaged property'),
('Company (for V2 PRO case)', NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'propertyowner', 'Owner of the lost/damaged property', 'Owner of the lost/damaged property'),

-- CONFIRMED target: other
('Motorcyclist',      NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'other', 'Other third party', 'Other third party'),
('Adult Cyclist',     NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'other', 'Other third party', 'Other third party'),
('Child Cyclist',     NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'other', 'Other third party', 'Other third party'),
('Pillion Passenger', NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'other', 'Other third party', 'Other third party'),
('Registered Keeper', NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'other', 'Other third party', 'Other third party'),
('Secondary Victim',  NULL, 'Motor only', 'ClaimantType', 'cctl_claimanttype', 'other', 'Other third party', 'Other third party');

-- VERIFY after running: should show all 15 rows above with the correct
-- GW_TypeCode groupings, plus your existing PH Passenger/TP Passenger
-- rows (those were never touched by any of this)
SELECT Vectus_TypeCode, GW_TypeCode
FROM SourceStaging.dbo.TYPELIST_TABLE_MAPPING
WHERE TypeList_Name = 'ClaimantType'
ORDER BY Vectus_TypeCode;
