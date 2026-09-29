/* =====================================================================================================
   V2 -> SS NON-FINANCIAL ATTRIBUTE RECON  (optimised, no UNPIVOT)
   -----------------------------------------------------------------------------------------------------
   >> RENAME the proc / adjust @Execution_id type to match your existing proc before deploying. <<

   DESIGN (why it is fast)
   1. Highest policy per case is resolved ONCE into #PolicyHighest.
   2. SS side is built ONCE per entity in WIDE form (1 row per claim / vehicle / exposure, 1 column per
      attribute) instead of one giant UNION ALL branch per attribute.
   3. V2 landing rows for this Execution_id are copied to temp tables (single scan of the landing table).
   4. Both sides get a CLUSTERED index on (Source_id, ClaimNumber) -> the FULL OUTER JOIN is a streaming
      MERGE join (no hash build, no sort, no memory grant => no tempdb spill).
   5. Each entity is joined ONE row per claim, all 10 attributes compared side by side (no 23M-row unpivot).
   6. Summary = ONE pass with conditional aggregates (result: 1-3 rows), then that tiny result is
      turned into one row per Recon_id. Failures = rows with >=1 mismatch only, then expanded per attribute.

   COMPARISON RULE (identical to your V1):
        both NULL -> PASS | one NULL -> FAIL | UPPER(LTRIM(RTRIM(v2))) = UPPER(LTRIM(RTRIM(ss))) -> PASS | else FAIL
   JOIN KEY (identical to V1): Source_id + Claim_Number (Recon_id / Parameter_Name are constants per attribute)
   GROUP KEY for summary (identical to V1): Recon_id, Parameter_Name, COALESCE(V2 LOB, SS LOB)
   ===================================================================================================== */
CREATE OR ALTER PROCEDURE [audit].[usp_V2_SS_NonFin_Attribute_Recon]      -- << RENAME
    @Execution_id INT                                                     -- << match your type
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ts VARCHAR(23);

    BEGIN TRY

        SET @ts = CONVERT(VARCHAR(23), SYSDATETIME(), 121); RAISERROR('%s | START', 0, 1, @ts) WITH NOWAIT;

        TRUNCATE TABLE IntermediateStaging_DEV.[audit].NonFinReconciliationresult;
        TRUNCATE TABLE IntermediateStaging_DEV.[audit].ClaimNonFinReconciliationData;

        DROP TABLE IF EXISTS #PolicyHighest, #V2_Claim, #SS_Claim, #ClaimAgg, #ClaimFail,
                             #V2_Vehicle, #SS_Vehicle, #V2_Exp, #SS_ExpBase, #SS_ExpClose, #SS_ExpCreate;

        /* =================================================================================================
           STEP 1: HIGHEST POLICY ID PER CASE (once).  SELECT INTO keeps the source data types, so the later
           joins on GW_HDR_CASEID need no implicit conversion. Non-unique clustered index (no PK: a PK would
           fail on NULL / duplicate keys, V1 never failed on those).
           ================================================================================================= */
        SELECT X.GW_HDR_CASEID, X.POLICY_REF, X.POL_INCEP_DATE, X.PRODUCT, X.POLICY_BRAND, X.CUR_INCEP_DATE
        INTO   #PolicyHighest
        FROM ( SELECT P.GW_HDR_CASEID, P.POLICY_REF, P.POL_INCEP_DATE, P.PRODUCT, P.POLICY_BRAND, P.CUR_INCEP_DATE,
                      ROW_NUMBER() OVER (PARTITION BY P.GW_HDR_CASEID ORDER BY P.ID DESC) AS RN
               FROM   SourceStaging.VECCASRN.VEC_GWP_POLICY P ) X
        WHERE X.RN = 1;

        CREATE CLUSTERED INDEX CIX ON #PolicyHighest (GW_HDR_CASEID);

        SET @ts = CONVERT(VARCHAR(23), SYSDATETIME(), 121); RAISERROR('%s | #PolicyHighest done', 0, 1, @ts) WITH NOWAIT;

        /* =================================================================================================
           SECTION A : CLAIMS  (Recon 201-210)
           ================================================================================================= */

        /* ---- A1. V2 side: copy this execution's rows once. Keys cast to fixed varchar so both sides have
                   identical types/collation (required for a clean merge join). Value columns keep landing types
                   (no truncation risk). v2row = "this V2 row exists" marker. ---- */
        SELECT CAST(L.Source_id   AS VARCHAR(64)) COLLATE DATABASE_DEFAULT AS Source_id,
               CAST(L.ClaimNumber AS VARCHAR(50)) COLLATE DATABASE_DEFAULT AS ClaimNumber,
               L.LOBCode,
               L.LossDate, L.ReportedDate, L.NCBValue_Adm, L.CloseDate, L.InsuredLiabilityView_Adm,
               L.LossCause, L.FaultRating, L.PolicyNumber, L.PolicyTermInceptionDate,
               CAST(1 AS TINYINT) AS v2row
        INTO   #V2_Claim
        FROM   IntermediateStaging_DEV.[audit].V2_ClaimAttribute_Landing L
        WHERE  L.Execution_id = @Execution_id;

        CREATE CLUSTERED INDEX CIX ON #V2_Claim (Source_id, ClaimNumber);

        /* ---- A2. SS side: ONE wide row per claim (all joins done once). Expressions are the same as your
                   SS_RAW attribute expressions (taken from version 2 - see note in reply: diff vs your real V1
                   claim CTE once). ---- */
        CREATE TABLE #SS_Claim
        (
            Source_id                 VARCHAR(64)  COLLATE DATABASE_DEFAULT NULL,
            ClaimNumber               VARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            LOBCode                   VARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            LossDate                  VARCHAR(10)  COLLATE DATABASE_DEFAULT NULL,
            ReportedDate              VARCHAR(10)  COLLATE DATABASE_DEFAULT NULL,
            NCBValue_Adm              VARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            CloseDate                 VARCHAR(19)  COLLATE DATABASE_DEFAULT NULL,
            InsuredLiabilityView_Adm  VARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            LossCause                 VARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            FaultRating               VARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            PolicyNumber              VARCHAR(255) COLLATE DATABASE_DEFAULT NULL,
            PolicyTermInceptionDate   VARCHAR(10)  COLLATE DATABASE_DEFAULT NULL
        );

        INSERT INTO #SS_Claim WITH (TABLOCK)
               (Source_id, ClaimNumber, LOBCode, LossDate, ReportedDate, NCBValue_Adm, CloseDate,
                InsuredLiabilityView_Adm, LossCause, FaultRating, PolicyNumber, PolicyTermInceptionDate)
        SELECT
            NULLIF(LTRIM(RTRIM(C.ID)), ''),
            CAST(NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') AS VARCHAR(50)),
            UPPER(NULLIF(LTRIM(RTRIM(C.PRODUCT)), '')),

            /* 201 Date of Loss */
            CAST(CASE WHEN NULLIF(LTRIM(RTRIM(C.ACTUAL_DOL)), '') IS NULL THEN NULL
                      ELSE CONVERT(VARCHAR(10), TRY_CONVERT(DATE, C.ACTUAL_DOL), 23) END AS VARCHAR(255)),

            /* 202 Reported Date */
            CAST(CASE WHEN NULLIF(LTRIM(RTRIM(C.REPORTED_DATE)), '') IS NULL THEN NULL
                      ELSE CONVERT(VARCHAR(10), TRY_CONVERT(DATE, C.REPORTED_DATE), 23) END AS VARCHAR(255)),

            /* 204 NCB Status */
            CAST(NULLIF(LTRIM(RTRIM(C.NCB_STATUS)), '') AS VARCHAR(255)),

            /* 205 Claim finalised date */
            CAST(CASE WHEN UPPER(LTRIM(RTRIM(C.CLAIM_STATUS))) = 'F' THEN
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(S.RECORD_DATE)), '') IS NULL AND NULLIF(LTRIM(RTRIM(S.RECORD_TIME)), '') IS NULL THEN NULL
                    WHEN NULLIF(LTRIM(RTRIM(S.RECORD_DATE)), '') IS NOT NULL AND NULLIF(LTRIM(RTRIM(S.RECORD_TIME)), '') IS NULL
                         THEN CONVERT(VARCHAR(10), TRY_CONVERT(DATE, S.RECORD_DATE), 23)
                    WHEN NULLIF(LTRIM(RTRIM(S.RECORD_DATE)), '') IS NULL AND NULLIF(LTRIM(RTRIM(S.RECORD_TIME)), '') IS NOT NULL
                         THEN CONVERT(VARCHAR(8), TRY_CONVERT(TIME, S.RECORD_TIME), 108)
                    ELSE CONVERT(VARCHAR(19), CAST(TRY_CONVERT(DATE, S.RECORD_DATE) AS DATETIME) + CAST(TRY_CONVERT(TIME, S.RECORD_TIME) AS DATETIME), 120)
                END
            END AS VARCHAR(255)),

            /* 206 PM Admit Liability Flag (MOTOR only) */
            CAST(CASE WHEN UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'MOTOR' THEN
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(INC.INSDADMITLIAB)), '') IS NULL AND NULLIF(LTRIM(RTRIM(REF.LIABILITY)), '') IS NULL THEN NULL
                    WHEN NULLIF(LTRIM(RTRIM(INC.INSDADMITLIAB)), '') IS NOT NULL AND NULLIF(LTRIM(RTRIM(REF.LIABILITY)), '') IS NULL THEN LTRIM(RTRIM(INC.INSDADMITLIAB))
                    WHEN NULLIF(LTRIM(RTRIM(INC.INSDADMITLIAB)), '') IS NULL AND NULLIF(LTRIM(RTRIM(REF.LIABILITY)), '') IS NOT NULL THEN LTRIM(RTRIM(REF.LIABILITY))
                    ELSE LTRIM(RTRIM(INC.INSDADMITLIAB)) + ' - ' + LTRIM(RTRIM(REF.LIABILITY))
                END
            END AS VARCHAR(255)),

            /* 207 Loss Cause (HH vs MOTOR) */
            CAST(CASE
                WHEN UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'HOUSEHOLD' THEN
                    CASE
                        WHEN NULLIF(LTRIM(RTRIM(CAUSE_LKP.CAUSE)), '') IS NULL AND NULLIF(LTRIM(RTRIM(CIRC_LKP.CIRC)), '') IS NULL THEN NULL
                        WHEN NULLIF(LTRIM(RTRIM(CAUSE_LKP.CAUSE)), '') IS NOT NULL AND NULLIF(LTRIM(RTRIM(CIRC_LKP.CIRC)), '') IS NULL THEN LTRIM(RTRIM(CAUSE_LKP.CAUSE))
                        WHEN NULLIF(LTRIM(RTRIM(CAUSE_LKP.CAUSE)), '') IS NULL AND NULLIF(LTRIM(RTRIM(CIRC_LKP.CIRC)), '') IS NOT NULL THEN LTRIM(RTRIM(CIRC_LKP.CIRC))
                        ELSE LTRIM(RTRIM(CAUSE_LKP.CAUSE)) + ' - ' + LTRIM(RTRIM(CIRC_LKP.CIRC))
                    END
                WHEN UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'MOTOR' THEN
                    CASE
                        WHEN NULLIF(LTRIM(RTRIM(TYP.TYPCODE)), '') IS NULL AND NULLIF(LTRIM(RTRIM(C.INCIDENT_CODE)), '') IS NULL THEN NULL
                        WHEN NULLIF(LTRIM(RTRIM(TYP.TYPCODE)), '') IS NOT NULL AND NULLIF(LTRIM(RTRIM(C.INCIDENT_CODE)), '') IS NULL THEN LTRIM(RTRIM(TYP.TYPCODE))
                        WHEN NULLIF(LTRIM(RTRIM(TYP.TYPCODE)), '') IS NULL AND NULLIF(LTRIM(RTRIM(C.INCIDENT_CODE)), '') IS NOT NULL THEN LTRIM(RTRIM(C.INCIDENT_CODE))
                        ELSE LTRIM(RTRIM(TYP.TYPCODE)) + ' - ' + LTRIM(RTRIM(C.INCIDENT_CODE))
                    END
            END AS VARCHAR(255)),

            /* 208 Fault Rating (MOTOR only) */
            CAST(CASE WHEN UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'MOTOR' THEN
                CASE
                    WHEN NULLIF(LTRIM(RTRIM(INC.INSDADMITLIAB)), '') IS NULL AND NULLIF(LTRIM(RTRIM(REF.LIABILITY)), '') IS NULL THEN NULL
                    WHEN NULLIF(LTRIM(RTRIM(INC.INSDADMITLIAB)), '') IS NOT NULL AND NULLIF(LTRIM(RTRIM(REF.LIABILITY)), '') IS NULL THEN LTRIM(RTRIM(INC.INSDADMITLIAB))
                    WHEN NULLIF(LTRIM(RTRIM(INC.INSDADMITLIAB)), '') IS NULL AND NULLIF(LTRIM(RTRIM(REF.LIABILITY)), '') IS NOT NULL THEN LTRIM(RTRIM(REF.LIABILITY))
                    ELSE LTRIM(RTRIM(INC.INSDADMITLIAB)) + ' - ' + LTRIM(RTRIM(REF.LIABILITY))
                END
            END AS VARCHAR(255)),

            /* 209 Policy Number */
            CAST(NULLIF(LTRIM(RTRIM(P.POLICY_REF)), '') AS VARCHAR(255)),

            /* 210 Policy Term Inception Date */
            CAST(CASE WHEN NULLIF(LTRIM(RTRIM(P.POL_INCEP_DATE)), '') IS NULL THEN NULL
                      ELSE CONVERT(VARCHAR(10), TRY_CONVERT(DATE, P.POL_INCEP_DATE), 23) END AS VARCHAR(255))

        FROM SourceStaging.VECCASRN.VEC_GW_CLAIM_SUM C
        INNER JOIN #PolicyHighest P
                ON P.GW_HDR_CASEID = C.GW_HDR_CASEID
        LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS S
               ON S.CASEID = C.GW_HDR_CASEID
              AND UPPER(LTRIM(RTRIM(S.STATUS))) = 'FINALISED'
              AND LTRIM(RTRIM(S.GCURRENT)) = 'X'
        LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CIRCS_INC INC
               ON C.GW_HDR_CASEID = INC.GW_HDR_CASEID
              AND UPPER(LTRIM(RTRIM(INC.GCURRENT))) = 'X'
        LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CIRCS_REF REF
               ON REF.ID = INC.GW_CIRCS_REFID
        LEFT JOIN SourceStaging.VECCASRN.VEC_GW_CIRCS_TYP TYP
               ON INC.GW_CIRCS_TYPID = TYP.ID
        LEFT JOIN SourceStaging.VECCASRN.VEC_HH_INC_DETS D
               ON D.HH_CLAIMID = C.GW_HDR_CASEID
        LEFT JOIN SourceStaging.VECCASRN.VEC_HH_AXX_CIRCS CIRC_LKP
               ON D.CIRC = CIRC_LKP.ID
        LEFT JOIN SourceStaging.VECCASRN.VEC_HH_AXX_CIRCS CAUSE_LKP
               ON D.CAUSE = CAUSE_LKP.ID
        WHERE UPPER(LTRIM(RTRIM(C.GCURRENT))) = 'X'
          AND COALESCE(NULLIF(UPPER(LTRIM(RTRIM(C.INCIDENT_CODE))), ''), '#NULL#') <> 'WINDSCREEN'
          AND NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') IS NOT NULL;

        CREATE CLUSTERED INDEX CIX ON #SS_Claim (Source_id, ClaimNumber);

        SET @ts = CONVERT(VARCHAR(23), SYSDATETIME(), 121); RAISERROR('%s | claim V2 + SS temp tables ready', 0, 1, @ts) WITH NOWAIT;

        /* ---- A3. PASS 1 (summary): one streaming merge join, all 10 attributes aggregated at once.
                   Output = 1 row per LOB (2-3 rows). n = rows in the LOB group; n_sc = rows in scope for the
                   MOTOR-only attributes 206/208 (V2 rows of any LOB + SS MOTOR rows, as V1 did).
                   f<recon> = number of mismatching rows. ---- */
        SELECT COALESCE(V.LOBCode, S.LOBCode) AS LOBCode,
               COUNT(*)      AS n,
               SUM(SC.sc)    AS n_sc,
        COUNT(V.LossDate) AS v201, COUNT(S.LossDate) AS s201, SUM(F.f201) AS f201,
        COUNT(V.ReportedDate) AS v202, COUNT(S.ReportedDate) AS s202, SUM(F.f202) AS f202,
        COUNT(V.ClaimNumber) AS v203, COUNT(S.ClaimNumber) AS s203, SUM(F.f203) AS f203,
        COUNT(V.NCBValue_Adm) AS v204, COUNT(S.NCBValue_Adm) AS s204, SUM(F.f204) AS f204,
        COUNT(V.CloseDate) AS v205, COUNT(S.CloseDate) AS s205, SUM(F.f205) AS f205,
        COUNT(V.InsuredLiabilityView_Adm) AS v206, COUNT(S.InsuredLiabilityView_Adm) AS s206, SUM(F.f206) AS f206,
        COUNT(V.LossCause) AS v207, COUNT(S.LossCause) AS s207, SUM(F.f207) AS f207,
        COUNT(V.FaultRating) AS v208, COUNT(S.FaultRating) AS s208, SUM(F.f208) AS f208,
        COUNT(V.PolicyNumber) AS v209, COUNT(S.PolicyNumber) AS s209, SUM(F.f209) AS f209,
        COUNT(V.PolicyTermInceptionDate) AS v210, COUNT(S.PolicyTermInceptionDate) AS s210, SUM(F.f210) AS f210
        INTO   #ClaimAgg
        FROM #V2_Claim V
    FULL OUTER MERGE JOIN #SS_Claim S            -- both sides clustered on the same key => streaming merge join, no hash/sort memory
         ON V.Source_id = S.Source_id AND V.ClaimNumber = S.ClaimNumber
    CROSS APPLY (SELECT CASE WHEN V.v2row = 1 OR S.LOBCode = 'MOTOR' THEN 1 ELSE 0 END AS sc) SC   -- scope flag for 206/208 (MOTOR only)
    CROSS APPLY (SELECT
            CASE WHEN V.LossDate IS NULL AND S.LossDate IS NULL THEN 0
                 WHEN V.LossDate IS NULL OR  S.LossDate IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.LossDate))) = UPPER(LTRIM(RTRIM(S.LossDate))) THEN 0
                 ELSE 1 END AS f201,
            CASE WHEN V.ReportedDate IS NULL AND S.ReportedDate IS NULL THEN 0
                 WHEN V.ReportedDate IS NULL OR  S.ReportedDate IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.ReportedDate))) = UPPER(LTRIM(RTRIM(S.ReportedDate))) THEN 0
                 ELSE 1 END AS f202,
            CASE WHEN V.ClaimNumber IS NULL AND S.ClaimNumber IS NULL THEN 0
                 WHEN V.ClaimNumber IS NULL OR  S.ClaimNumber IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.ClaimNumber))) = UPPER(LTRIM(RTRIM(S.ClaimNumber))) THEN 0
                 ELSE 1 END AS f203,
            CASE WHEN V.NCBValue_Adm IS NULL AND S.NCBValue_Adm IS NULL THEN 0
                 WHEN V.NCBValue_Adm IS NULL OR  S.NCBValue_Adm IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.NCBValue_Adm))) = UPPER(LTRIM(RTRIM(S.NCBValue_Adm))) THEN 0
                 ELSE 1 END AS f204,
            CASE WHEN V.CloseDate IS NULL AND S.CloseDate IS NULL THEN 0
                 WHEN V.CloseDate IS NULL OR  S.CloseDate IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.CloseDate))) = UPPER(LTRIM(RTRIM(S.CloseDate))) THEN 0
                 ELSE 1 END AS f205,
            CASE WHEN SC.sc = 0 THEN 0 WHEN V.InsuredLiabilityView_Adm IS NULL AND S.InsuredLiabilityView_Adm IS NULL THEN 0
                 WHEN V.InsuredLiabilityView_Adm IS NULL OR  S.InsuredLiabilityView_Adm IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.InsuredLiabilityView_Adm))) = UPPER(LTRIM(RTRIM(S.InsuredLiabilityView_Adm))) THEN 0
                 ELSE 1 END AS f206,
            CASE WHEN V.LossCause IS NULL AND S.LossCause IS NULL THEN 0
                 WHEN V.LossCause IS NULL OR  S.LossCause IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.LossCause))) = UPPER(LTRIM(RTRIM(S.LossCause))) THEN 0
                 ELSE 1 END AS f207,
            CASE WHEN SC.sc = 0 THEN 0 WHEN V.FaultRating IS NULL AND S.FaultRating IS NULL THEN 0
                 WHEN V.FaultRating IS NULL OR  S.FaultRating IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.FaultRating))) = UPPER(LTRIM(RTRIM(S.FaultRating))) THEN 0
                 ELSE 1 END AS f208,
            CASE WHEN V.PolicyNumber IS NULL AND S.PolicyNumber IS NULL THEN 0
                 WHEN V.PolicyNumber IS NULL OR  S.PolicyNumber IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.PolicyNumber))) = UPPER(LTRIM(RTRIM(S.PolicyNumber))) THEN 0
                 ELSE 1 END AS f209,
            CASE WHEN V.PolicyTermInceptionDate IS NULL AND S.PolicyTermInceptionDate IS NULL THEN 0
                 WHEN V.PolicyTermInceptionDate IS NULL OR  S.PolicyTermInceptionDate IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.PolicyTermInceptionDate))) = UPPER(LTRIM(RTRIM(S.PolicyTermInceptionDate))) THEN 0
                 ELSE 1 END AS f210
    ) F
        GROUP BY COALESCE(V.LOBCode, S.LOBCode)
        OPTION (MAXDOP 1);

        /* Tiny aggregate -> one NonFinReconciliationresult row per Recon_id / LOB (same columns as V1) */
        INSERT INTO IntermediateStaging_DEV.[audit].NonFinReconciliationresult
               (Execution_id, Recon_id, Parameter_Name, LOBCode, V2_Count, SS_Count,
                V2_SS_Match, V2_SS_Mismatch, V2_SS_result, Created_at)
        SELECT @Execution_id, u.Recon_id, u.Parameter_Name, a.LOBCode,
               u.V2_Count, u.SS_Count,
               u.N - u.Mism,                                   -- Match
               u.Mism,                                         -- Mismatch
               CASE WHEN u.Mism = 0 THEN 'PASS' ELSE 'FAIL' END,
               GETDATE()
        FROM #ClaimAgg a
        CROSS APPLY (VALUES
            (201, 'Date of Loss', a.v201, a.s201, a.n, a.f201),
            (202, 'Reported Date', a.v202, a.s202, a.n, a.f202),
            (203, 'Claim Number', a.v203, a.s203, a.n, a.f203),
            (204, 'No Claim Bonus Status', a.v204, a.s204, a.n, a.f204),
            (205, 'Claim finalised date', a.v205, a.s205, a.n, a.f205),
            (206, 'PM Admit Liability Flag', a.v206, a.s206, a.n_sc, a.f206),
            (207, 'Loss Cause', a.v207, a.s207, a.n, a.f207),
            (208, 'Fault Rating', a.v208, a.s208, a.n_sc, a.f208),
            (209, 'Policy Number', a.v209, a.s209, a.n, a.f209),
            (210, 'Policy Term Inception Date', a.v210, a.s210, a.n, a.f210)
        ) u (Recon_id, Parameter_Name, V2_Count, SS_Count, N, Mism)
        WHERE u.N > 0;

        /* ---- A4. PASS 2 (failures): keep ONLY rows with >=1 mismatch, then expand to one row per failed
                   attribute. The expansion runs on the failing rows only, never on 2.3M x 10. ---- */
        SELECT COALESCE(V.Source_id,   S.Source_id)   AS Source_id,
               COALESCE(V.ClaimNumber, S.ClaimNumber) AS ClaimNumber,
               COALESCE(V.LOBCode,     S.LOBCode)     AS LOBCode,
        V.LossDate AS v201, S.LossDate AS s201, F.f201 AS f201,
        V.ReportedDate AS v202, S.ReportedDate AS s202, F.f202 AS f202,
        V.ClaimNumber AS v203, S.ClaimNumber AS s203, F.f203 AS f203,
        V.NCBValue_Adm AS v204, S.NCBValue_Adm AS s204, F.f204 AS f204,
        V.CloseDate AS v205, S.CloseDate AS s205, F.f205 AS f205,
        V.InsuredLiabilityView_Adm AS v206, S.InsuredLiabilityView_Adm AS s206, F.f206 AS f206,
        V.LossCause AS v207, S.LossCause AS s207, F.f207 AS f207,
        V.FaultRating AS v208, S.FaultRating AS s208, F.f208 AS f208,
        V.PolicyNumber AS v209, S.PolicyNumber AS s209, F.f209 AS f209,
        V.PolicyTermInceptionDate AS v210, S.PolicyTermInceptionDate AS s210, F.f210 AS f210
        INTO   #ClaimFail
        FROM #V2_Claim V
    FULL OUTER MERGE JOIN #SS_Claim S            -- both sides clustered on the same key => streaming merge join, no hash/sort memory
         ON V.Source_id = S.Source_id AND V.ClaimNumber = S.ClaimNumber
    CROSS APPLY (SELECT CASE WHEN V.v2row = 1 OR S.LOBCode = 'MOTOR' THEN 1 ELSE 0 END AS sc) SC   -- scope flag for 206/208 (MOTOR only)
    CROSS APPLY (SELECT
            CASE WHEN V.LossDate IS NULL AND S.LossDate IS NULL THEN 0
                 WHEN V.LossDate IS NULL OR  S.LossDate IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.LossDate))) = UPPER(LTRIM(RTRIM(S.LossDate))) THEN 0
                 ELSE 1 END AS f201,
            CASE WHEN V.ReportedDate IS NULL AND S.ReportedDate IS NULL THEN 0
                 WHEN V.ReportedDate IS NULL OR  S.ReportedDate IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.ReportedDate))) = UPPER(LTRIM(RTRIM(S.ReportedDate))) THEN 0
                 ELSE 1 END AS f202,
            CASE WHEN V.ClaimNumber IS NULL AND S.ClaimNumber IS NULL THEN 0
                 WHEN V.ClaimNumber IS NULL OR  S.ClaimNumber IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.ClaimNumber))) = UPPER(LTRIM(RTRIM(S.ClaimNumber))) THEN 0
                 ELSE 1 END AS f203,
            CASE WHEN V.NCBValue_Adm IS NULL AND S.NCBValue_Adm IS NULL THEN 0
                 WHEN V.NCBValue_Adm IS NULL OR  S.NCBValue_Adm IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.NCBValue_Adm))) = UPPER(LTRIM(RTRIM(S.NCBValue_Adm))) THEN 0
                 ELSE 1 END AS f204,
            CASE WHEN V.CloseDate IS NULL AND S.CloseDate IS NULL THEN 0
                 WHEN V.CloseDate IS NULL OR  S.CloseDate IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.CloseDate))) = UPPER(LTRIM(RTRIM(S.CloseDate))) THEN 0
                 ELSE 1 END AS f205,
            CASE WHEN SC.sc = 0 THEN 0 WHEN V.InsuredLiabilityView_Adm IS NULL AND S.InsuredLiabilityView_Adm IS NULL THEN 0
                 WHEN V.InsuredLiabilityView_Adm IS NULL OR  S.InsuredLiabilityView_Adm IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.InsuredLiabilityView_Adm))) = UPPER(LTRIM(RTRIM(S.InsuredLiabilityView_Adm))) THEN 0
                 ELSE 1 END AS f206,
            CASE WHEN V.LossCause IS NULL AND S.LossCause IS NULL THEN 0
                 WHEN V.LossCause IS NULL OR  S.LossCause IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.LossCause))) = UPPER(LTRIM(RTRIM(S.LossCause))) THEN 0
                 ELSE 1 END AS f207,
            CASE WHEN SC.sc = 0 THEN 0 WHEN V.FaultRating IS NULL AND S.FaultRating IS NULL THEN 0
                 WHEN V.FaultRating IS NULL OR  S.FaultRating IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.FaultRating))) = UPPER(LTRIM(RTRIM(S.FaultRating))) THEN 0
                 ELSE 1 END AS f208,
            CASE WHEN V.PolicyNumber IS NULL AND S.PolicyNumber IS NULL THEN 0
                 WHEN V.PolicyNumber IS NULL OR  S.PolicyNumber IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.PolicyNumber))) = UPPER(LTRIM(RTRIM(S.PolicyNumber))) THEN 0
                 ELSE 1 END AS f209,
            CASE WHEN V.PolicyTermInceptionDate IS NULL AND S.PolicyTermInceptionDate IS NULL THEN 0
                 WHEN V.PolicyTermInceptionDate IS NULL OR  S.PolicyTermInceptionDate IS NULL THEN 1
                 WHEN UPPER(LTRIM(RTRIM(V.PolicyTermInceptionDate))) = UPPER(LTRIM(RTRIM(S.PolicyTermInceptionDate))) THEN 0
                 ELSE 1 END AS f210
    ) F
        WHERE  F.f201 = 1
       OR F.f202 = 1
       OR F.f203 = 1
       OR F.f204 = 1
       OR F.f205 = 1
       OR F.f206 = 1
       OR F.f207 = 1
       OR F.f208 = 1
       OR F.f209 = 1
       OR F.f210 = 1
        OPTION (MAXDOP 1);

        INSERT INTO IntermediateStaging_DEV.[audit].ClaimNonFinReconciliationData
               (Execution_id, Recon_id, Source_id, Claim_Number, LOBCode, Parameter_Name,
                V2_value, SS_value, V2_SS_result, Created_at)
        SELECT @Execution_id, u.Recon_id, c.Source_id, c.ClaimNumber, c.LOBCode, u.Parameter_Name,
               u.V2_Value, u.SS_Value, 'FAIL', GETDATE()
        FROM #ClaimFail c
        CROSS APPLY (VALUES
            (201, 'Date of Loss', c.v201, c.s201, c.f201),
            (202, 'Reported Date', c.v202, c.s202, c.f202),
            (203, 'Claim Number', c.v203, c.s203, c.f203),
            (204, 'No Claim Bonus Status', c.v204, c.s204, c.f204),
            (205, 'Claim finalised date', c.v205, c.s205, c.f205),
            (206, 'PM Admit Liability Flag', c.v206, c.s206, c.f206),
            (207, 'Loss Cause', c.v207, c.s207, c.f207),
            (208, 'Fault Rating', c.v208, c.s208, c.f208),
            (209, 'Policy Number', c.v209, c.s209, c.f209),
            (210, 'Policy Term Inception Date', c.v210, c.s210, c.f210)
        ) u (Recon_id, Parameter_Name, V2_Value, SS_Value, f)
        WHERE u.f = 1;

        DROP TABLE #V2_Claim, #SS_Claim, #ClaimAgg, #ClaimFail;   -- free tempdb before next section

        SET @ts = CONVERT(VARCHAR(23), SYSDATETIME(), 121); RAISERROR('%s | claims 201-210 done', 0, 1, @ts) WITH NOWAIT;

        /* =================================================================================================
           SECTION B : VEHICLES (Recon 211)   V2 landing has 1 row per vehicle, key = Source_id + ClaimNumber
           (NOT Source_id alone: in your screenshot Source_id 100000402 belongs to two different claims).
           ================================================================================================= */
        SELECT CAST(L.Source_id   AS VARCHAR(64)) COLLATE DATABASE_DEFAULT AS Source_id,
               CAST(L.ClaimNumber AS VARCHAR(50)) COLLATE DATABASE_DEFAULT AS ClaimNumber,
               CAST('MOTOR' AS VARCHAR(50))       COLLATE DATABASE_DEFAULT AS LOBCode,
               L.LicensePlate
        INTO   #V2_Vehicle
        FROM   IntermediateStaging_DEV.[audit].V2_VehicleAttribute_Landing L
        WHERE  L.Execution_id = @Execution_id;

        CREATE CLUSTERED INDEX CIX ON #V2_Vehicle (Source_id, ClaimNumber);

        CREATE TABLE #SS_Vehicle
        (
            Source_id    VARCHAR(64)  COLLATE DATABASE_DEFAULT NULL,
            ClaimNumber  VARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            LOBCode      VARCHAR(50)  COLLATE DATABASE_DEFAULT NULL,
            LicensePlate VARCHAR(255) COLLATE DATABASE_DEFAULT NULL
        );

        INSERT INTO #SS_Vehicle WITH (TABLOCK) (Source_id, ClaimNumber, LOBCode, LicensePlate)
        /* Vehicle - third party */
        SELECT NULLIF(LTRIM(RTRIM(VEH.ID)), ''),
               CAST(NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') AS VARCHAR(50)),
               'MOTOR',
               CAST(CASE WHEN NULLIF(LTRIM(RTRIM(VEH.REG)), '') IS NULL THEN NULL ELSE LTRIM(RTRIM(VEH.REG)) END AS VARCHAR(255))
        FROM SourceStaging.VECCASRN.VEC_GW_CLAIM_SUM C
        INNER JOIN #PolicyHighest P ON P.GW_HDR_CASEID = C.GW_HDR_CASEID
        INNER JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_TP TP ON TP.GW_HDR_CASEID = C.GW_HDR_CASEID
        INNER JOIN SourceStaging.VECCASRN.VEC_GW_VEHICLE VEH ON VEH.CASEID = TP.ID
        WHERE UPPER(TRIM(RTRIM(C.GCURRENT))) = 'X'
          AND COALESCE(NULLIF(UPPER(LTRIM(RTRIM(C.INCIDENT_CODE))), ''), '#NULL#') <> 'WINDSCREEN'
          AND NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') IS NOT NULL
          AND UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'MOTOR'

        UNION ALL

        /* Vehicle - own damage (policy risk unit) */
        SELECT NULLIF(LTRIM(RTRIM(VEH.ID)), ''),
               CAST(NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') AS VARCHAR(50)),
               'MOTOR',
               CAST(CASE WHEN NULLIF(LTRIM(RTRIM(VEH.REG_NUMBER)), '') IS NULL THEN NULL ELSE LTRIM(RTRIM(VEH.REG_NUMBER)) END AS VARCHAR(255))
        FROM SourceStaging.VECCASRN.VEC_GW_CLAIM_SUM C
        INNER JOIN #PolicyHighest P ON P.GW_HDR_CASEID = C.GW_HDR_CASEID
        INNER JOIN SourceStaging.VECCASRN.VEC_GW_MOTOR_AD AD ON AD.GW_HDR_CASEID = C.GW_HDR_CASEID
        INNER JOIN SourceStaging.VECCASRN.VEC_GWP_SLCTD_RISK SR ON SR.GW_HDR_CASEID = C.GW_HDR_CASEID
        INNER JOIN SourceStaging.VECCASRN.VEC_GWP_RISKUNIT RU ON RU.GWP_POLICYID = SR.GWP_POLICYID AND RU.PUBLICID = SR.PUBLICID
        INNER JOIN SourceStaging.VECCASRN.VEC_GWP_VEHICLE VEH ON VEH.GWP_RISKUNITID = RU.ID
        WHERE UPPER(TRIM(RTRIM(C.GCURRENT))) = 'X'
          AND COALESCE(NULLIF(UPPER(LTRIM(RTRIM(C.INCIDENT_CODE))), ''), '#NULL#') <> 'WINDSCREEN'
          AND NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') IS NOT NULL
          AND UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'MOTOR';

        CREATE CLUSTERED INDEX CIX ON #SS_Vehicle (Source_id, ClaimNumber);

        /* Summary 211 */
        INSERT INTO IntermediateStaging_DEV.[audit].NonFinReconciliationresult
               (Execution_id, Recon_id, Parameter_Name, LOBCode, V2_Count, SS_Count,
                V2_SS_Match, V2_SS_Mismatch, V2_SS_result, Created_at)
        SELECT @Execution_id, 211, 'RiskUnit/Vehicle Registration', COALESCE(V.LOBCode, S.LOBCode),
               COUNT(V.LicensePlate), COUNT(S.LicensePlate),
               COUNT(*) - SUM(F.f), SUM(F.f),
               CASE WHEN SUM(F.f) = 0 THEN 'PASS' ELSE 'FAIL' END, GETDATE()
        FROM #V2_Vehicle V
        FULL OUTER MERGE JOIN #SS_Vehicle S ON V.Source_id = S.Source_id AND V.ClaimNumber = S.ClaimNumber
        CROSS APPLY (SELECT CASE WHEN V.LicensePlate IS NULL AND S.LicensePlate IS NULL THEN 0
                                 WHEN V.LicensePlate IS NULL OR  S.LicensePlate IS NULL THEN 1
                                 WHEN UPPER(LTRIM(RTRIM(V.LicensePlate))) = UPPER(LTRIM(RTRIM(S.LicensePlate))) THEN 0
                                 ELSE 1 END AS f) F
        GROUP BY COALESCE(V.LOBCode, S.LOBCode)
        OPTION (MAXDOP 1);

        /* Failures 211  (uses the F flag, so rows where only ONE side is NULL are NOT lost) */
        INSERT INTO IntermediateStaging_DEV.[audit].ClaimNonFinReconciliationData
               (Execution_id, Recon_id, Source_id, Claim_Number, LOBCode, Parameter_Name,
                V2_value, SS_value, V2_SS_result, Created_at)
        SELECT @Execution_id, 211, COALESCE(V.Source_id, S.Source_id), COALESCE(V.ClaimNumber, S.ClaimNumber),
               COALESCE(V.LOBCode, S.LOBCode), 'RiskUnit/Vehicle Registration',
               V.LicensePlate, S.LicensePlate, 'FAIL', GETDATE()
        FROM #V2_Vehicle V
        FULL OUTER MERGE JOIN #SS_Vehicle S ON V.Source_id = S.Source_id AND V.ClaimNumber = S.ClaimNumber
        CROSS APPLY (SELECT CASE WHEN V.LicensePlate IS NULL AND S.LicensePlate IS NULL THEN 0
                                 WHEN V.LicensePlate IS NULL OR  S.LicensePlate IS NULL THEN 1
                                 WHEN UPPER(LTRIM(RTRIM(V.LicensePlate))) = UPPER(LTRIM(RTRIM(S.LicensePlate))) THEN 0
                                 ELSE 1 END AS f) F
        WHERE F.f = 1
        OPTION (MAXDOP 1);

        DROP TABLE #V2_Vehicle, #SS_Vehicle;

        SET @ts = CONVERT(VARCHAR(23), SYSDATETIME(), 121); RAISERROR('%s | vehicle 211 done', 0, 1, @ts) WITH NOWAIT;

        /* =================================================================================================
           SECTION C : EXPOSURES (Recon 213 CloseDate, 214 CreateTime)  - HOUSEHOLD now, MOTOR later
           V2 table = the unified landing table from your screenshot (has LOBCode + ExposureType).
           >> If your HH-only table V2_Exposure_HH_Attribute_Landing is the one to use, swap the name. <<
           213 and 214 keep the SAME SS row sets as your V1:
             213 : only exposures that have a current 'Finalised' status row  (INNER JOIN VEC_GW_CASE_STATUS)
             214 : all exposures that have a VEC_CASE row                      (INNER JOIN VEC_CASE)
           (Version 2 merged them with a LEFT JOIN, which inflated the 213 match count - fixed here.)
           ================================================================================================= */
        SELECT CAST(L.Source_id   AS VARCHAR(64)) COLLATE DATABASE_DEFAULT AS Source_id,
               CAST(L.ClaimNumber AS VARCHAR(50)) COLLATE DATABASE_DEFAULT AS ClaimNumber,
               UPPER(LTRIM(RTRIM(L.LOBCode)))     COLLATE DATABASE_DEFAULT AS LOBCode,
               L.CloseDate, L.CreateTime
        INTO   #V2_Exp
        FROM   IntermediateStaging_DEV.[audit].V2_ExposureAttribute_Landing L
        WHERE  L.Execution_id = @Execution_id
          AND  UPPER(LTRIM(RTRIM(L.LOBCode))) IN ('HOUSEHOLD');      -- << add 'MOTOR' when motor exposure SS is added

        CREATE CLUSTERED INDEX CIX ON #V2_Exp (Source_id, ClaimNumber);

        /* Base: every SS exposure (Source_id, claim, raw ID for the status / case joins). One scan of the
           claim + exposure tables instead of six. */
        SELECT CAST(NULLIF(LTRIM(RTRIM(HHC.ID)), '') AS VARCHAR(64)) AS Source_id,
               CAST(NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') AS VARCHAR(50)) AS ClaimNumber,
               CAST('HOUSEHOLD' AS VARCHAR(50)) AS LOBCode,
               HHC.ID AS Exp_ID
        INTO   #SS_ExpBase
        FROM SourceStaging.VECCASRN.VEC_GW_CLAIM_SUM C
        INNER JOIN #PolicyHighest P ON P.GW_HDR_CASEID = C.GW_HDR_CASEID
        INNER JOIN SourceStaging.VECCASRN.VEC_HH_CONTENTS HHC ON HHC.HH_CLAIMID = C.GW_HDR_CASEID
        WHERE UPPER(TRIM(RTRIM(C.GCURRENT))) = 'X'
          AND UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'HOUSEHOLD'
          AND COALESCE(NULLIF(UPPER(LTRIM(RTRIM(C.INCIDENT_CODE))), ''), '#NULL#') <> 'WINDSCREEN'
          AND NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') IS NOT NULL

        UNION ALL
        SELECT CAST(NULLIF(LTRIM(RTRIM(HHB.ID)), '') AS VARCHAR(64)),
               CAST(NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') AS VARCHAR(50)), 'HOUSEHOLD', HHB.ID
        FROM SourceStaging.VECCASRN.VEC_GW_CLAIM_SUM C
        INNER JOIN #PolicyHighest P ON P.GW_HDR_CASEID = C.GW_HDR_CASEID
        INNER JOIN SourceStaging.VECCASRN.VEC_HH_BUILDINGS HHB ON HHB.HH_CLAIMID = C.GW_HDR_CASEID
        WHERE UPPER(TRIM(RTRIM(C.GCURRENT))) = 'X'
          AND UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'HOUSEHOLD'
          AND COALESCE(NULLIF(UPPER(LTRIM(RTRIM(C.INCIDENT_CODE))), ''), '#NULL#') <> 'WINDSCREEN'
          AND NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') IS NOT NULL

        UNION ALL
        SELECT CAST(NULLIF(LTRIM(RTRIM(HHT.ID)), '') AS VARCHAR(64)),
               CAST(NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') AS VARCHAR(50)), 'HOUSEHOLD', HHT.ID
        FROM SourceStaging.VECCASRN.VEC_GW_CLAIM_SUM C
        INNER JOIN #PolicyHighest P ON P.GW_HDR_CASEID = C.GW_HDR_CASEID
        INNER JOIN SourceStaging.VECCASRN.VEC_HH_THIRDPARTY HHT ON HHT.HH_CLAIMID = C.GW_HDR_CASEID
        WHERE UPPER(TRIM(RTRIM(C.GCURRENT))) = 'X'
          AND UPPER(LTRIM(RTRIM(C.PRODUCT))) = 'HOUSEHOLD'
          AND HHT.CLAIM_RECOVERY = 'TP'
          AND COALESCE(NULLIF(UPPER(LTRIM(RTRIM(C.INCIDENT_CODE))), ''), '#NULL#') <> 'WINDSCREEN'
          AND NULLIF(LTRIM(RTRIM(C.CLAIM_REF)), '') IS NOT NULL;

        /* 213 SS rows: exposure must have a current Finalised status */
        SELECT B.Source_id COLLATE DATABASE_DEFAULT AS Source_id, B.ClaimNumber COLLATE DATABASE_DEFAULT AS ClaimNumber,
               B.LOBCode COLLATE DATABASE_DEFAULT AS LOBCode,
               CAST(CASE WHEN NULLIF(LTRIM(RTRIM(CS.Record_date)), '') IS NULL THEN NULL
                         ELSE CONVERT(VARCHAR(10), TRY_CONVERT(DATE, CS.Record_date), 23) END AS VARCHAR(255)) AS CloseDate
        INTO   #SS_ExpClose
        FROM   #SS_ExpBase B
        INNER JOIN SourceStaging.VECCASRN.VEC_GW_CASE_STATUS CS ON CS.CASEID = B.Exp_ID
        WHERE  CS.GCURRENT = 'X' AND CS.STATUS = 'Finalised';

        /* 214 SS rows: exposure must exist in VEC_CASE */
        SELECT B.Source_id COLLATE DATABASE_DEFAULT AS Source_id, B.ClaimNumber COLLATE DATABASE_DEFAULT AS ClaimNumber,
               B.LOBCode COLLATE DATABASE_DEFAULT AS LOBCode,
               CAST(CONVERT(VARCHAR(23),
                    DATEADD(MILLISECOND, DATEDIFF(MILLISECOND, CAST('00:00:00' AS TIME), VC.CREATETIME),
                            CAST(VC.CREATEDATE AS DATETIME2(3))), 121) AS VARCHAR(255)) AS CreateTime
        INTO   #SS_ExpCreate
        FROM   #SS_ExpBase B
        INNER JOIN SourceStaging.VECCASRN.VEC_CASE VC ON VC.ID = B.Exp_ID;

        CREATE CLUSTERED INDEX CIX ON #SS_ExpClose  (Source_id, ClaimNumber);
        CREATE CLUSTERED INDEX CIX ON #SS_ExpCreate (Source_id, ClaimNumber);

        SET @ts = CONVERT(VARCHAR(23), SYSDATETIME(), 121); RAISERROR('%s | exposure temp tables ready', 0, 1, @ts) WITH NOWAIT;

        /* ---- 213 summary ---- */
        INSERT INTO IntermediateStaging_DEV.[audit].NonFinReconciliationresult
               (Execution_id, Recon_id, Parameter_Name, LOBCode, V2_Count, SS_Count,
                V2_SS_Match, V2_SS_Mismatch, V2_SS_result, Created_at)
        SELECT @Execution_id, 213, 'Exposure/CloseDate', COALESCE(V.LOBCode, S.LOBCode),
               COUNT(V.CloseDate), COUNT(S.CloseDate), COUNT(*) - SUM(F.f), SUM(F.f),
               CASE WHEN SUM(F.f) = 0 THEN 'PASS' ELSE 'FAIL' END, GETDATE()
        FROM #V2_Exp V
        FULL OUTER MERGE JOIN #SS_ExpClose S ON V.Source_id = S.Source_id AND V.ClaimNumber = S.ClaimNumber
        CROSS APPLY (SELECT CASE WHEN V.CloseDate IS NULL AND S.CloseDate IS NULL THEN 0
                                 WHEN V.CloseDate IS NULL OR  S.CloseDate IS NULL THEN 1
                                 WHEN UPPER(LTRIM(RTRIM(V.CloseDate))) = UPPER(LTRIM(RTRIM(S.CloseDate))) THEN 0
                                 ELSE 1 END AS f) F
        GROUP BY COALESCE(V.LOBCode, S.LOBCode)
        OPTION (MAXDOP 1);

        /* ---- 213 failures ---- */
        INSERT INTO IntermediateStaging_DEV.[audit].ClaimNonFinReconciliationData
               (Execution_id, Recon_id, Source_id, Claim_Number, LOBCode, Parameter_Name,
                V2_value, SS_value, V2_SS_result, Created_at)
        SELECT @Execution_id, 213, COALESCE(V.Source_id, S.Source_id), COALESCE(V.ClaimNumber, S.ClaimNumber),
               COALESCE(V.LOBCode, S.LOBCode), 'Exposure/CloseDate', V.CloseDate, S.CloseDate, 'FAIL', GETDATE()
        FROM #V2_Exp V
        FULL OUTER MERGE JOIN #SS_ExpClose S ON V.Source_id = S.Source_id AND V.ClaimNumber = S.ClaimNumber
        CROSS APPLY (SELECT CASE WHEN V.CloseDate IS NULL AND S.CloseDate IS NULL THEN 0
                                 WHEN V.CloseDate IS NULL OR  S.CloseDate IS NULL THEN 1
                                 WHEN UPPER(LTRIM(RTRIM(V.CloseDate))) = UPPER(LTRIM(RTRIM(S.CloseDate))) THEN 0
                                 ELSE 1 END AS f) F
        WHERE F.f = 1
        OPTION (MAXDOP 1);

        /* ---- 214 summary ---- */
        INSERT INTO IntermediateStaging_DEV.[audit].NonFinReconciliationresult
               (Execution_id, Recon_id, Parameter_Name, LOBCode, V2_Count, SS_Count,
                V2_SS_Match, V2_SS_Mismatch, V2_SS_result, Created_at)
        SELECT @Execution_id, 214, 'Exposure/CreateTime', COALESCE(V.LOBCode, S.LOBCode),
               COUNT(V.CreateTime), COUNT(S.CreateTime), COUNT(*) - SUM(F.f), SUM(F.f),
               CASE WHEN SUM(F.f) = 0 THEN 'PASS' ELSE 'FAIL' END, GETDATE()
        FROM #V2_Exp V
        FULL OUTER MERGE JOIN #SS_ExpCreate S ON V.Source_id = S.Source_id AND V.ClaimNumber = S.ClaimNumber
        CROSS APPLY (SELECT CASE WHEN V.CreateTime IS NULL AND S.CreateTime IS NULL THEN 0
                                 WHEN V.CreateTime IS NULL OR  S.CreateTime IS NULL THEN 1
                                 WHEN UPPER(LTRIM(RTRIM(V.CreateTime))) = UPPER(LTRIM(RTRIM(S.CreateTime))) THEN 0
                                 ELSE 1 END AS f) F
        GROUP BY COALESCE(V.LOBCode, S.LOBCode)
        OPTION (MAXDOP 1);

        /* ---- 214 failures ---- */
        INSERT INTO IntermediateStaging_DEV.[audit].ClaimNonFinReconciliationData
               (Execution_id, Recon_id, Source_id, Claim_Number, LOBCode, Parameter_Name,
                V2_value, SS_value, V2_SS_result, Created_at)
        SELECT @Execution_id, 214, COALESCE(V.Source_id, S.Source_id), COALESCE(V.ClaimNumber, S.ClaimNumber),
               COALESCE(V.LOBCode, S.LOBCode), 'Exposure/CreateTime', V.CreateTime, S.CreateTime, 'FAIL', GETDATE()
        FROM #V2_Exp V
        FULL OUTER MERGE JOIN #SS_ExpCreate S ON V.Source_id = S.Source_id AND V.ClaimNumber = S.ClaimNumber
        CROSS APPLY (SELECT CASE WHEN V.CreateTime IS NULL AND S.CreateTime IS NULL THEN 0
                                 WHEN V.CreateTime IS NULL OR  S.CreateTime IS NULL THEN 1
                                 WHEN UPPER(LTRIM(RTRIM(V.CreateTime))) = UPPER(LTRIM(RTRIM(S.CreateTime))) THEN 0
                                 ELSE 1 END AS f) F
        WHERE F.f = 1
        OPTION (MAXDOP 1);

        /* >>> EXPOSURE MOTOR (later): add a MOTOR branch to #SS_ExpBase (LOBCode 'MOTOR'), add 'MOTOR' to the
               IN (...) list of #V2_Exp above. The 213/214 blocks group by LOB, so they need no other change. <<< */

        DROP TABLE #V2_Exp, #SS_ExpBase, #SS_ExpClose, #SS_ExpCreate, #PolicyHighest;

        SET @ts = CONVERT(VARCHAR(23), SYSDATETIME(), 121); RAISERROR('%s | exposures 213-214 done. END', 0, 1, @ts) WITH NOWAIT;

    END TRY
    BEGIN CATCH
        THROW;
    END CATCH;
END;
GO

/* =====================================================================================================
   PARITY CHECK vs V1 (run BEFORE deploying, on the same Execution_id):
     1) Run V1, then:  SELECT * INTO IntermediateStaging_DEV.[audit].zz_V1_result FROM IntermediateStaging_DEV.[audit].NonFinReconciliationresult;
                       SELECT * INTO IntermediateStaging_DEV.[audit].zz_V1_fail   FROM IntermediateStaging_DEV.[audit].ClaimNonFinReconciliationData;
     2) Run the new proc, then both must return ZERO rows:
        SELECT Recon_id, Parameter_Name, LOBCode, V2_Count, SS_Count, V2_SS_Match, V2_SS_Mismatch FROM IntermediateStaging_DEV.[audit].zz_V1_result
        EXCEPT
        SELECT Recon_id, Parameter_Name, LOBCode, V2_Count, SS_Count, V2_SS_Match, V2_SS_Mismatch FROM IntermediateStaging_DEV.[audit].NonFinReconciliationresult;
        (and the same query with the two tables swapped)

        SELECT Recon_id, Source_id, Claim_Number, Parameter_Name, V2_value, SS_value FROM IntermediateStaging_DEV.[audit].zz_V1_fail
        EXCEPT
        SELECT Recon_id, Source_id, Claim_Number, Parameter_Name, V2_value, SS_value FROM IntermediateStaging_DEV.[audit].ClaimNonFinReconciliationData;
        (and swapped)
   ===================================================================================================== */
