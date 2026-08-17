--------------------------------------------------------------
-- QA AUDIT TABLE
CREATE OR REPLACE TABLE DB.SCHEMA.MONTHLY_SNAPSHOT_RECONCILIATION_AUDIT (
    Create_Date TIMESTAMP,
    Month_Begin_Dt DATE,
    CATEGORY_FLAG STRING,
    Source_Count NUMBER,
    Target_Count NUMBER,
    Delta_Count_Target_Minus_Source NUMBER,
    Delta_Pct_Target_to_Source FLOAT,
    Threshold_Pct NUMBER,
    Check_Status STRING
);



--------------------------------------------------------------
-- QA PROC
CREATE OR REPLACE PROCEDURE DB.SCHEMA.RECONCILE_MONTHLY_SNAPSHOTS()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    threshold_pct NUMBER := 10;
    processed_count INT := 0;
    -- Missing count tracking
    missing_count INT := 0;
    missing_details VARCHAR;
    missing_email_subject VARCHAR;
    missing_email_body VARCHAR;
    -- Delta count tracking
    delta_failed_count INT := 0;
    delta_failed_details VARCHAR;
    delta_email_subject VARCHAR;
    delta_email_body VARCHAR;

BEGIN
    -- Build comparison temp table: full outer join on month + CATEGORY_FLAG
    CREATE OR REPLACE TEMPORARY TABLE TEMP_CATEGORY_COMPARISON AS
    WITH TT AS (
        SELECT
            DATE_TRUNC('MONTH', MONTH_BEGIN_DT)::DATE AS MONTH_BEGIN_DT,
            CATEGORY_FLAG::STRING AS CATEGORY_FLAG,
            COUNT(*) AS Source_Count
        FROM DB.SCHEMA.SOURCE_MONTHLY_SNAPSHOT
        GROUP BY 1, 2
    ),
    MM AS (
        SELECT
            DATE_TRUNC('MONTH', MONTH_BEGIN_DT)::DATE AS MONTH_BEGIN_DT,
            CATEGORY_FLAG::STRING AS CATEGORY_FLAG,
            COUNT(*) AS Target_Count
        FROM DB.SCHEMA.TARGET_MONTHLY_SNAPSHOT
        GROUP BY 1, 2
    )
    SELECT
        COALESCE(TT.MONTH_BEGIN_DT, MM.MONTH_BEGIN_DT) AS MONTH_BEGIN_DT,
        COALESCE(TT.CATEGORY_FLAG, MM.CATEGORY_FLAG) AS CATEGORY_FLAG,
        COALESCE(TT.Source_Count, 0) AS Source_Count,
        COALESCE(MM.Target_Count, 0) AS Target_Count,
        COALESCE(MM.Target_Count, 0) - COALESCE(TT.Source_Count, 0) AS Delta_Count_Target_Minus_Source,
        CASE
            WHEN COALESCE(TT.Source_Count, 0) = 0 THEN NULL
            ELSE ((COALESCE(MM.Target_Count, 0) - COALESCE(TT.Source_Count, 0)) * 100.0) / TT.Source_Count
        END AS Delta_Pct_Target_to_Source,
        CASE
            WHEN COALESCE(TT.Source_Count, 0) = 0
              OR COALESCE(MM.Target_Count, 0) = 0 THEN 'FAIL - MISSING'
            WHEN ABS(((COALESCE(MM.Target_Count, 0) - COALESCE(TT.Source_Count, 0)) * 100.0) / TT.Source_Count) > 10 THEN 'FAIL - DELTA'
            ELSE 'PASS'
        END AS CHECK_STATUS
    FROM TT
    FULL OUTER JOIN MM
        ON TT.MONTH_BEGIN_DT = MM.MONTH_BEGIN_DT
        AND TT.CATEGORY_FLAG = MM.CATEGORY_FLAG
    ORDER BY MONTH_BEGIN_DT DESC, CATEGORY_FLAG;

    -- Insert all rows into audit table
    INSERT INTO DB.SCHEMA.MONTHLY_SNAPSHOT_RECONCILIATION_AUDIT (
        Create_Date, Month_Begin_Dt, CATEGORY_FLAG,
        Source_Count, Target_Count, Delta_Count_Target_Minus_Source, Delta_Pct_Target_to_Source,
        Threshold_Pct, Check_Status
    )
    SELECT
        CURRENT_TIMESTAMP(),
        MONTH_BEGIN_DT,
        CATEGORY_FLAG,
        Source_Count,
        Target_Count,
        Delta_Count_Target_Minus_Source,
        Delta_Pct_Target_to_Source,
        :threshold_pct,
        CHECK_STATUS
    FROM TEMP_CATEGORY_COMPARISON;

    -- Get counts for summary
    SELECT COUNT(*) INTO :processed_count
    FROM TEMP_CATEGORY_COMPARISON;

    SELECT COUNT(*) INTO :missing_count
    FROM TEMP_CATEGORY_COMPARISON
    WHERE CHECK_STATUS = 'FAIL - MISSING';

    SELECT COUNT(*) INTO :delta_failed_count
    FROM TEMP_CATEGORY_COMPARISON
    WHERE CHECK_STATUS = 'FAIL - DELTA';

    -- Email 1: Missing CATEGORY_FLAG count for certain months in any of the two tables
    SELECT
        LISTAGG(
            'Month: ' || MONTH_BEGIN_DT::STRING
            || ' | CATEGORY_FLAG: ' || CATEGORY_FLAG
            || ' | TT Count: ' || Source_Count
            || ' | MM Count: ' || Target_Count
            || ' | Missing In: ' ||
            CASE
                WHEN Source_Count = 0 AND Target_Count = 0 THEN 'Both Tables'
                WHEN Source_Count = 0 THEN 'SOURCE_MONTHLY_SNAPSHOT'
                ELSE 'TARGET_MONTHLY_SNAPSHOT'
            END,
            '\n'
        )
    INTO :missing_details
    FROM TEMP_CATEGORY_COMPARISON
    WHERE CHECK_STATUS = 'FAIL - MISSING'
    ORDER BY MONTH_BEGIN_DT DESC, CATEGORY_FLAG;

    IF (:missing_count > 0) THEN
        missing_email_subject := '(Monthly Snapshot CATEGORY FLAG ALERT) Missing CATEGORY_FLAG Count for '
            || :missing_count || ' Month/Flag Combination(s)';

        missing_email_body :=
            'WARNING: The following month/CATEGORY_FLAG combinations have a zero count in one or both tables.'
            || ' This may indicate the table did not load correctly for that month.\n\n'
            || :missing_details
            || '\n\nSource Table (TT): ANALYTICS_STAGE.SOURCE_MONTHLY_SNAPSHOT'
            || '\nCompare Table (MM): ANALYTICS_PROD.TARGET_MONTHLY_SNAPSHOT\n\n'
            || 'Please investigate whether the target monthly snapshot loaded correctly.';

        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_INTEGRATION',
            'EMAIL_RECIPIENT',
            :missing_email_subject,
            :missing_email_body
        );
    END IF;

    -- Email 2: Delta exceeds threshold
    SELECT
        LISTAGG(
            'Month: ' || MONTH_BEGIN_DT::STRING
            || ' | CATEGORY_FLAG: ' || CATEGORY_FLAG
            || ' | TT Count: ' || Source_Count
            || ' | MM Count: ' || Target_Count
            || ' | Delta (MM - TT): ' || Delta_Count_Target_Minus_Source
            || ' (' || IFF(Delta_Pct_Target_to_Source > 0, '+', '') || ROUND(Delta_Pct_Target_to_Source, 2)::STRING || '%)'
            || ' | Threshold: ' || :threshold_pct || '%',
            '\n'
        )
    INTO :delta_failed_details
    FROM TEMP_CATEGORY_COMPARISON
    WHERE CHECK_STATUS = 'FAIL - DELTA'
    ORDER BY MONTH_BEGIN_DT DESC, CATEGORY_FLAG;

    IF (:delta_failed_count > 0) THEN
        delta_email_subject := '(Monthly Snapshot CATEGORY FLAG ALERT) Count Delta Exceeds '
            || :threshold_pct || '% for '
            || :delta_failed_count || ' Month/Flag Combination(s)';

        delta_email_body :=
            'WARNING: The CATEGORY_FLAG count comparison between SOURCE_MONTHLY_SNAPSHOT'
            || ' and TARGET_MONTHLY_SNAPSHOT has exceeded the ' || :threshold_pct || '% threshold'
            || ' for the following month/flag combinations:\n\n'
            || :delta_failed_details
            || '\n\nSource Table (TT): ANALYTICS_STAGE.SOURCE_MONTHLY_SNAPSHOT'
            || '\nCompare Table (MM): ANALYTICS_PROD.TARGET_MONTHLY_SNAPSHOT\n\n'
            || 'Please investigate whether the source monthly snapshot loaded correctly.';

        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_INTEGRATION',
            'EMAIL_RECIPIENT',
            :delta_email_subject,
            :delta_email_body
        );
    END IF;

    DROP TABLE IF EXISTS TEMP_CATEGORY_COMPARISON;

    RETURN 'CATEGORY flag comparison completed. Processed: ' || :processed_count
        || ' month/flag combinations. Failed (missing): ' || :missing_count
        || '. Failed (delta > ' || :threshold_pct || '%): ' || :delta_failed_count || '.';

EXCEPTION
    WHEN OTHER THEN
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_INTEGRATION',
            'EMAIL_RECIPIENT',
            '(ERROR) monthly snapshot CATEGORY Flag Comparison Failed',
            'The CATEGORY flag comparison procedure encountered an unexpected error. Error: ' || SQLERRM
        );
        RETURN 'ERROR: CATEGORY flag comparison failed. Error: ' || SQLERRM;
END;
$$;
