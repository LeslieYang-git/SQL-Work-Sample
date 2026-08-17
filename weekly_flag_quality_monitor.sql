-- Result table for weekly flag audit
CREATE OR REPLACE TABLE DB.SCHEMA.WEEKLY_FLAG_AUDIT (
    Create_Date TIMESTAMP,
    Table_Name STRING,
    Flag_Name STRING,
    Date_Column STRING,
    Current_Week_Sunday DATE,  
    Total_Records NUMBER,
    Null_Count NUMBER,
    Zero_Count NUMBER,
    Non_Null_Non_Zero_Count NUMBER,
    All_Null_Check STRING,
    All_Zero_Check STRING
);


-- Parameter Table
CREATE OR REPLACE TABLE DB.SCHEMA.WEEKLY_FLAG_CONFIG (
    TABLE_NAME STRING,
    FLAG_NAME STRING,
    DATE_COLUMN STRING
);


-- Weekly flag auditing procedure 
-- This procedure checks flags for the current week by comparing with week_begin_dt (Sunday dates)
CREATE OR REPLACE PROCEDURE DB.SCHEMA.RUN_WEEKLY_FLAG_AUDIT(
    PARAMETER_TABLE_NAME STRING
)
RETURNS STRING
LANGUAGE JAVASCRIPT
AS
$$
try {
    // Calculate current week's Sunday (beginning of week)
    // If today is Fri 2025-09-12, current week Sunday = 2025-09-07
    // If today is Sun 2025-09-07, current week Sunday = 2025-09-07
    var currentDate = new Date();
    var dayOfWeek = currentDate.getDay(); // 0=Sunday, 1=Monday, 6=Saturday
    
    // Calculate current week's Sunday
    var currentWeekSunday = new Date(currentDate);
    currentWeekSunday.setDate(currentDate.getDate() - dayOfWeek);
    
    // Format Sunday date for SQL and display
    var currentWeekSundaySql = currentWeekSunday.getFullYear() + '-' + 
                               String(currentWeekSunday.getMonth() + 1).padStart(2, '0') + '-' +
                               String(currentWeekSunday.getDate()).padStart(2, '0');
    
    var weekDisplayStr = currentWeekSundaySql;
    
    // Get parameter data
    var paramQuery = `SELECT table_name, flag_name, date_column FROM ${PARAMETER_TABLE_NAME}`;
    var paramStmt = snowflake.createStatement({sqlText: paramQuery});
    var paramResult = paramStmt.execute();
    
    var processedCount = 0;
    var failedChecks = [];
    
    // Loop through each parameter row
    while (paramResult.next()) {
        var tableName = paramResult.getColumnValue('TABLE_NAME');
        var flagName = paramResult.getColumnValue('FLAG_NAME');
        var dateColumn = paramResult.getColumnValue('DATE_COLUMN');

        try {
            // Build dynamic SQL query with direct date comparison
            // This assumes the date column is properly typed as DATE (not VARCHAR)
            // Example: WHERE week_begin_dt = '2025-09-07' (current week's Sunday)
            var auditQuery = `
                SELECT 
                    COUNT(*) as total_records,
                    SUM(CASE WHEN ${flagName} IS NULL THEN 1 ELSE 0 END) as null_count,
                    SUM(CASE WHEN ${flagName} = 0 THEN 1 ELSE 0 END) as zero_count,
                    SUM(CASE WHEN ${flagName} IS NOT NULL AND ${flagName} != 0 THEN 1 ELSE 0 END) as non_null_non_zero_count
                FROM ${tableName} 
                WHERE ${dateColumn} = '${currentWeekSundaySql}'
            `;
            
            // Execute audit query
            var auditStmt = snowflake.createStatement({sqlText: auditQuery});
            var auditResult = auditStmt.execute();
            
            if (auditResult.next()) {
                var totalRecords = auditResult.getColumnValue('TOTAL_RECORDS');
                var nullCount = auditResult.getColumnValue('NULL_COUNT');
                var zeroCount = auditResult.getColumnValue('ZERO_COUNT');
                var nonNullNonZeroCount = auditResult.getColumnValue('NON_NULL_NON_ZERO_COUNT');
                
                // Perform checks
                var allNullCheck = 'Y';
                var allZeroCheck = 'Y';
                
                // Check 1: All NULL check
                if (totalRecords > 0 && nullCount === totalRecords) {
                    allNullCheck = 'N';
                    failedChecks.push(`${tableName}.${flagName}: All values are NULL for current week`);
                    
                    // Send email alert
                    var emailSubject = `(WEEKLY FLAG ALERT) ALL ${flagName} VALUES ARE NULL in ${tableName} FOR WEEK ${weekDisplayStr}`;
                    var emailBody = `All ${flagName} values are NULL in ${tableName} table for week beginning ${weekDisplayStr}. Total records: ${totalRecords}. Please investigate.`;
                    
                    var emailQuery = `CALL SYSTEM$SEND_EMAIL('EMAIL_INTEGRATION', 'EMAIL_RECIPIENT', '${emailSubject}', '${emailBody}')`;
                    var emailStmt = snowflake.createStatement({sqlText: emailQuery});
                    emailStmt.execute();
                }
                
                // Check 2: All ZERO check (only for non-null values)
                var nonNullRecords = totalRecords - nullCount;
                if (totalRecords > 0 && nonNullRecords > 0 && zeroCount === nonNullRecords) {
                    allZeroCheck = 'N';
                    failedChecks.push(`${tableName}.${flagName}: All non-null values are ZERO for current week`);
                    
                    // Send email alert
                    var emailSubject = `(WEEKLY FLAG ALERT) ALL NON-NULL ${flagName} VALUES ARE ZERO in ${tableName} FOR WEEK ${weekDisplayStr}`;
                    var emailBody = `All non-null ${flagName} values are 0 in ${tableName} table for week beginning ${weekDisplayStr}. Total non-null records: ${nonNullRecords}, Zero count: ${zeroCount}. Please investigate.`;
                    
                    var emailQuery = `CALL SYSTEM$SEND_EMAIL('EMAIL_INTEGRATION', 'EMAIL_RECIPIENT', '${emailSubject}', '${emailBody}')`;
                    var emailStmt = snowflake.createStatement({sqlText: emailQuery});
                    emailStmt.execute();
                }
                
                // Insert results into weekly audit table
                var insertQuery = `
                    INSERT INTO DB.SCHEMA.WEEKLY_FLAG_AUDIT(
                        Create_Date,
                        Table_Name,
                        Flag_Name,
                        Date_Column,
                        Current_Week_Sunday,
                        Total_Records,
                        Null_Count,
                        Zero_Count,
                        Non_Null_Non_Zero_Count,
                        All_Null_Check,
                        All_Zero_Check
                    )
                    VALUES (
                        CURRENT_TIMESTAMP(),
                        '${tableName}',
                        '${flagName}',
                        '${dateColumn}',
                        '${currentWeekSundaySql}',
                        ${totalRecords},
                        ${nullCount},
                        ${zeroCount},
                        ${nonNullNonZeroCount},
                        '${allNullCheck}',
                        '${allZeroCheck}'
                    )
                `;
                
                var insertStmt = snowflake.createStatement({sqlText: insertQuery});
                insertStmt.execute();
                
                processedCount++;
            }
            
        } catch (tableError) {
            // Log individual table errors but continue processing
            var errorMsg = `Error processing ${tableName}.${flagName}: ${tableError.message}`;
            
            // Insert error record
            var errorInsertQuery = `
                INSERT INTO DB.SCHEMA.WEEKLY_FLAG_AUDIT(
                    Create_Date,
                    Table_Name,
                    Flag_Name,
                    Date_Column,
                    Current_Week_Sunday,
                    All_Null_Check,
                    All_Zero_Check
                )
                VALUES (
                    CURRENT_TIMESTAMP(),
                    '${tableName}',
                    '${flagName}',
                    '${dateColumn}',
                    '${currentWeekSundaySql}',
                    'ERROR: ${tableError.message.replace(/'/g, "''")}',
                    'ERROR'
                )
            `;
            
            var errorInsertStmt = snowflake.createStatement({sqlText: errorInsertQuery});
            errorInsertStmt.execute();
        }
    }
    
    // Summary
    var summaryMsg = `Weekly flag audit completed for week beginning ${weekDisplayStr}. Processed ${processedCount} table/flag combinations.`;
    if (failedChecks.length > 0) {
        summaryMsg += ` Failed checks: ${failedChecks.join('; ')}`;
    }
    
    return summaryMsg;
    
} catch (error) {
    // Handle any unexpected errors
    var errorEmailQuery = `
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_INTEGRATION', 
            'EMAIL_RECIPIENT', 
            '(ERROR) Weekly Flag Audit Check Failed',
            'The weekly flag audit check procedure encountered an error. Error: ${error.message} Timestamp: ${new Date().toISOString()}'
        )
    `;
    
    var errorEmailStmt = snowflake.createStatement({sqlText: errorEmailQuery});
    errorEmailStmt.execute();
    
    return `ERROR: Weekly flag audit check failed. Error: ${error.message}`;
}
$$;


