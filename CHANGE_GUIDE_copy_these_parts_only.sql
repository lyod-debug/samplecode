/* =====================================================================================
   CHANGE GUIDE - copy ONLY these parts into your proc.  Nothing else in the proc changed.
   Rules used everywhere:
     - Exposure is linked ONLY if the lookup column Link_to_Exposure = 'YES'; otherwise NULL.
     - Incident is linked ONLY if Link_to_Incident = 'YES'; otherwise NULL.
     - NO claim-level fallback (a contact gets the exposure / incident of its OWN case only).
     - 5 Motor roles (repairshop, hirecompany_adm, thirdparty_adm, tpinsurer_Adm, recoveryagent) and
       3 Household roles (thirdparty_adm, tpinsurer_Adm, recoveryagent) take the VEHICLE incident; vehicle exposure only if Link_to_Exposure = 'YES'.
   ===================================================================================== */

/* ---------- 0. TOP OF PROC, with the other DROP TABLE lines: add this one ---------- */
    IF OBJECT_ID('tempdb..#HH_EXPOSURE_BY_CASE_VEH') IS NOT NULL DROP TABLE #HH_EXPOSURE_BY_CASE_VEH;

/* ---------- 0b. STEP 6 CLEANUP, with the other DROP TABLE lines: add this one ---------- */
    DROP TABLE #HH_EXPOSURE_BY_CASE_VEH;

/* =====================================================================================
   HOUSEHOLD
   ===================================================================================== */

/* ---------- H1. STEP 2A (Household pickers): REPLACE your old #HH_INCIDENT_BY_CASE_VEH block (if any) with these two pickers.
                  Put them after the #HH_INCIDENT_BY_CLAIM index line. ---------- */

    /* CHANGE (Household): thirdparty_adm, tpinsurer_Adm, recoveryagent may only sit on a VehicleIncident (Guidewire load errors, same as Motor).
       The household exposure table has no incident type column, so for HOUSEHOLD ONLY we join IS_INCIDENT (filtered to household:
       the exposure side is IS_EXPOSURE_HOUSEHOLD and the incident ID must be a household one 'mig:HH%') to read the subtype.
       NOTHING is deleted: if the TP case has no vehicle incident, these roles keep their row and get NULL incident / NULL exposure
       (BA sees them through the HH checks). */
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        MIN(EXP.IncidentID) AS PickedIncidentID
    INTO #HH_INCIDENT_BY_CASE_VEH
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_HOUSEHOLD EXP
    INNER JOIN IntermediateStaging_DEV.dbo.IS_INCIDENT INC
        ON INC.PublicID = EXP.IncidentID
       AND INC.PublicID LIKE 'mig:HH%'               -- household incidents only
    WHERE EXP.VectusCaseID_Adm IS NOT NULL
      AND EXP.LossParty = 'third_party'              -- case IDs come from 3 tables (HHT/HHB/HHC); only the third-party case is meant here
      AND EXP.IncidentID IS NOT NULL
      AND INC.Subtype = 'VehicleIncident'            -- CONFIRM column name Subtype on IS_INCIDENT (run HH check V0 first)
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_HHIBC_VEH ON #HH_INCIDENT_BY_CASE_VEH (V2_SubCaseID);

    /* The vehicle EXPOSURE for the same 3 roles = the household exposure of the same TP case that sits on the picked vehicle incident. */
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        MIN(EXP.PublicID) AS PickedExposureID
    INTO #HH_EXPOSURE_BY_CASE_VEH
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_HOUSEHOLD EXP
    INNER JOIN #HH_INCIDENT_BY_CASE_VEH V
        ON V.V2_SubCaseID = EXP.VectusCaseID_Adm
       AND V.PickedIncidentID = EXP.IncidentID
    WHERE EXP.LossParty = 'third_party'
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_HEBC_VEH ON #HH_EXPOSURE_BY_CASE_VEH (V2_SubCaseID);


/* ---------- H2. STEP 3A  #LKP_ROLES_HH : REPLACE the two CASE expressions ExposureID and IncidentID
                  (they sit between  B.ClaimContactID AS ClaimContactID,  and  CASE WHEN LKP.Link_to_Policy ... AS PolicyID) ---------- */

        -- ExposureID: ONLY when the lookup says Link to Exposure = YES. The lookup's EXPOSURE text says which exposure. (same pattern as IncidentID below)
        CASE
            WHEN LKP.Link_to_Exposure = 'YES' THEN
                CASE
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%THIRDPARTY%' THEN
                        CASE
                            WHEN LKP.GWCC_Role_TYPECODE IN ('thirdparty_adm', 'tpinsurer_Adm', 'recoveryagent')
                                THEN EBC_VEH.PickedExposureID   -- vehicle roles: the VEHICLE exposure of their own TP case
                            ELSE EBC.PickedExposureID   -- other TP roles: the exposure of their OWN TP case. No claim-level fallback.
                        END
                    /* first-party Household: the lookup has no first-party row with Link to Exposure = YES (claimant is built separately).
                       If the mapping sheet gets one, add its branch here. */
                    ELSE NULL
                END
            ELSE NULL
        END AS ExposureID,
        -- IncidentID: ONLY when the lookup says Link to Incident = YES. Same pattern as ExposureID above.
        CASE
            WHEN LKP.Link_to_Incident = 'YES' THEN
                CASE
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%THIRDPARTY%' THEN
                        CASE
                            WHEN LKP.GWCC_Role_TYPECODE IN ('thirdparty_adm', 'tpinsurer_Adm', 'recoveryagent')
                                THEN IBC_VEH.PickedIncidentID   -- vehicle roles: the VEHICLE incident of their own TP case (Guidewire accepts only VehicleIncident). None = NULL, role kept.
                            ELSE IBC.PickedIncidentID   -- other TP roles: the incident of their OWN TP case. No claim-level fallback.
                        END
                    ELSE NULL   -- incidents exist only for TP cases; first-party roles have Link to Incident = NO in the lookup
                END
            ELSE NULL
        END AS IncidentID,


/* ---------- H3. STEP 3A  #LKP_ROLES_HH : at the END of the FROM / JOIN list, after the last LEFT JOIN (before the ';'), add these joins.
                  (IBC_VEH is new if you did not have it; EBC_VEH is new) ---------- */
    LEFT JOIN #HH_INCIDENT_BY_CASE_VEH IBC_VEH
        ON IBC_VEH.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
    LEFT JOIN #HH_EXPOSURE_BY_CASE_VEH EBC_VEH
        ON EBC_VEH.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)

/* =====================================================================================
   MOTOR
   ===================================================================================== */

/* ---------- M1. STEP 2B (Motor pickers): REPLACE your #MOTOR_INCIDENT_BY_CASE_VEH and #MOTOR_EXPOSURE_BY_CASE_VEH blocks with these
                  (vehicle incident comes from IS_EXPOSURE_MOTOR.IncidentType = 'VehicleDamage', no IS_INCIDENT join) ---------- */

    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        MIN(EXP.IncidentID) AS PickedIncidentID
    INTO #MOTOR_INCIDENT_BY_CASE_VEH
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
    WHERE EXP.VectusCaseID_Adm IS NOT NULL
      AND EXP.SourceOrigin_Adm IN ('TP_VEH', 'TP_INJ', 'TP_PRO', 'TP_HIRE')
      AND EXP.IncidentID IS NOT NULL
      AND EXP.IncidentType = 'VehicleDamage'       -- vehicle incident = IncidentType 'VehicleDamage' on IS_EXPOSURE_MOTOR (TP_VEH and TP_HIRE), no IS_INCIDENT
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_MIBC_VEH ON #MOTOR_INCIDENT_BY_CASE_VEH (V2_SubCaseID);

    /* BA: the 5 vehicle-incident roles also link to the CORRESPONDING vehicle exposure = the exposure
       that belongs to the picked VehicleIncident of the same TP case (prefer the TP_VEH exposure,
       else any TP_* exposure on that incident). */
    SELECT
        EXP.VectusCaseID_Adm AS V2_SubCaseID,
        COALESCE(
            MIN(CASE WHEN EXP.SourceOrigin_Adm = 'TP_VEH' THEN EXP.Exposure_Motor_PublicID END),
            MIN(EXP.Exposure_Motor_PublicID)
        ) AS PickedExposureID
    INTO #MOTOR_EXPOSURE_BY_CASE_VEH
    FROM IntermediateStaging_DEV.dbo.IS_EXPOSURE_MOTOR EXP
    INNER JOIN #MOTOR_INCIDENT_BY_CASE_VEH V
        ON V.V2_SubCaseID = EXP.VectusCaseID_Adm
       AND V.PickedIncidentID = EXP.IncidentID
    WHERE EXP.SourceOrigin_Adm IN ('TP_VEH', 'TP_INJ', 'TP_PRO', 'TP_HIRE')
    GROUP BY EXP.VectusCaseID_Adm;

    CREATE UNIQUE CLUSTERED INDEX CIX_MEBC_VEH ON #MOTOR_EXPOSURE_BY_CASE_VEH (V2_SubCaseID);


/* ---------- M2. STEP 3B  #LKP_ROLES_MOTOR : REPLACE the two CASE expressions ExposureID and IncidentID
                  (between  B.ClaimContactID AS ClaimContactID,  and  CASE WHEN LKP.Link_to_Policy ... AS PolicyID) ---------- */

        -- ExposureID: ONLY when the lookup says Link to Exposure = YES. The lookup's EXPOSURE text says which exposure. (same pattern as IncidentID below)
        CASE
            WHEN LKP.Link_to_Exposure = 'YES' THEN
                CASE
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%THIRDPARTY%' THEN
                        CASE
                            WHEN LKP.GWCC_Role_TYPECODE IN ('repairshop', 'hirecompany_adm', 'thirdparty_adm', 'tpinsurer_Adm', 'recoveryagent')
                                THEN EBC_VEH.PickedExposureID   -- vehicle roles: the VEHICLE exposure of their own TP case
                            ELSE EBC.PickedExposureID   -- other TP roles: the exposure of their OWN TP case. No claim-level fallback.
                        END
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%ANCILLARY%'    THEN EBCLM_PA.PickedExposureID   -- first party: the PA (1st party BI) exposure of the claim
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%MOTOR AD%'     THEN EBCLM.PickedExposureID      -- first party: the AD / F&T exposure of the claim
                    ELSE NULL
                END
            ELSE NULL
        END AS ExposureID,
        -- IncidentID: ONLY when the lookup says Link to Incident = YES. Same pattern as ExposureID above.
        CASE
            WHEN LKP.Link_to_Incident = 'YES' THEN
                CASE
                    WHEN UPPER(LKP.EXPOSURE) LIKE '%THIRDPARTY%' THEN
                        CASE
                            WHEN LKP.GWCC_Role_TYPECODE IN ('repairshop', 'hirecompany_adm', 'thirdparty_adm', 'tpinsurer_Adm', 'recoveryagent')
                                THEN IBC_VEH.PickedIncidentID   -- vehicle roles: the VEHICLE incident of their own TP case (Guidewire accepts only VehicleIncident). None = NULL, role kept.
                            ELSE IBC.PickedIncidentID   -- other TP roles: the incident of their OWN TP case. No claim-level fallback.
                        END
                    ELSE NULL   -- incidents exist only for TP cases; first-party roles have Link to Incident = NO in the lookup
                END
            ELSE NULL
        END AS IncidentID,


/* ---------- M3. STEP 3B  #LKP_ROLES_MOTOR : these two joins must exist at the end of its FROM list (they were already there before) ---------- */
    LEFT JOIN #MOTOR_EXPOSURE_BY_CASE_VEH EBC_VEH
        ON EBC_VEH.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
    LEFT JOIN #MOTOR_INCIDENT_BY_CASE_VEH IBC_VEH
        ON IBC_VEH.V2_SubCaseID = CONVERT(VARCHAR(64), B.V2_SubCaseID)
