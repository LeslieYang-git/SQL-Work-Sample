-- Audit Stats Table
CREATE OR REPLACE TABLE DB.SCHEMA.COLUMN_NULL_AUDIT (
    Create_Date TIMESTAMP,
    Check_Type STRING,
    Table_Name STRING,
    Column_Name STRING,
    Total_Records NUMBER,
    Null_Count NUMBER,
    Check_Status STRING
);


-- Audit Procs
CREATE OR REPLACE PROCEDURE DB.SCHEMA.RUN_COLUMN_NULL_AUDIT(
    CHECK_TYPE_PARAMETER STRING  -- 'DAILY' or 'MONTHLY'
)
RETURNS STRING
LANGUAGE JAVASCRIPT
AS
$$
try {
    var emailRecipients = 'EMAIL_RECIPIENT';
    
    // Get parameter data for the specified check type
    var paramQuery = `
        SELECT TABLE_NAME, COLUMN_NAME, CHECK_TYPE 
        FROM DB.SCHEMA.COLUMN_AUDIT_CONFIG
        WHERE CHECK_TYPE = '${CHECK_TYPE_PARAMETER}'
    `;
    var paramStmt = snowflake.createStatement({sqlText: paramQuery});
    var paramResult = paramStmt.execute();
    
    var processedCount = 0;
    var failedChecks = [];
    var erroredChecks = [];
    
    // Loop through each parameter row
    while (paramResult.next()) {
        var tableName = paramResult.getColumnValue('TABLE_NAME');
        var columnName = paramResult.getColumnValue('COLUMN_NAME');
        var checkType = paramResult.getColumnValue('CHECK_TYPE');

        try {
            // Build dynamic SQL query
            var auditQuery = `
                SELECT 
                    COUNT(*) as total_records,
                    SUM(CASE WHEN ${columnName} IS NULL THEN 1 ELSE 0 END) as null_count
                FROM ${tableName}
            `;
            
            var auditStmt = snowflake.createStatement({sqlText: auditQuery});
            var auditResult = auditStmt.execute();
            
            if (auditResult.next()) {
                var totalRecords = auditResult.getColumnValue('TOTAL_RECORDS');
                var nullCount = auditResult.getColumnValue('NULL_COUNT');
                
                var checkStatus = 'PASS';
                
                // Check if all values are NULL
                if (totalRecords > 0 && nullCount === totalRecords) {
                    checkStatus = 'FAIL';
                    failedChecks.push(`${tableName}.${columnName}`);
                    
                    // Send email alert if all values are null
                    var emailSubject = `(DATA_QUALITY NULL COLUMN ALERT) ${tableName} - ${columnName} COLUMN ALL NULL`;
                    var emailBody = `CRITICAL: All values in ${columnName} column are NULL.\n\n` +
                                    `Table: ${tableName}\n` +
                                    `Column: ${columnName}\n` +
                                    `Total Records: ${totalRecords}\n` +
                                    `Null Count: ${nullCount}\n\n` +
                                    `Please investigate.`;
                    var emailQuery = `CALL SYSTEM$SEND_EMAIL('EMAIL_INTEGRATION', '${emailRecipients}', '${emailSubject}', '${emailBody}')`;
                    var emailStmt = snowflake.createStatement({sqlText: emailQuery});
                    emailStmt.execute();
                }
                
                // Insert results into audit table
                var insertQuery = `
                    INSERT INTO DB.SCHEMA.COLUMN_NULL_AUDIT(
                        Create_Date,
                        Check_Type,
                        Table_Name,
                        Column_Name,
                        Total_Records,
                        Null_Count,
                        Check_Status
                    )
                    VALUES (
                        CURRENT_TIMESTAMP(),
                        '${checkType}',
                        '${tableName}',
                        '${columnName}',
                        ${totalRecords},
                        ${nullCount},
                        '${checkStatus}'
                    )
                `;
                
                var insertStmt = snowflake.createStatement({sqlText: insertQuery});
                insertStmt.execute();
                
                processedCount++;
            }
            
        } catch (tableError) {
            // Log individual table errors
            var errorMsg = `${tableName}.${columnName}: ${tableError.message}`;
            erroredChecks.push(errorMsg);
            
            // Send email alert with specific table errors
            var errorEmailSubject = `(DATA_QUALITY NULL COLUMN CHECK ERROR) Error checking ${tableName}.${columnName}`;
            var errorEmailBody = `ERROR: Failed to check ${columnName} column in ${tableName} table.\n\n` +
                                `Table: ${tableName}\n` +
                                `Column: ${columnName}\n` +
                                `Error Message: ${tableError.message}\n\n` +
                                `Please investigate the table/column configuration or data structure.`;
            var errorEmailQuery = `CALL SYSTEM$SEND_EMAIL('EMAIL_INTEGRATION', '${emailRecipients}', '${errorEmailSubject}', '${errorEmailBody.replace(/'/g, "''")}')`;
            var errorEmailStmt = snowflake.createStatement({sqlText: errorEmailQuery});
            errorEmailStmt.execute();
            
            // Insert error record into audit table
            var errorInsertQuery = `
                INSERT INTO DB.SCHEMA.COLUMN_NULL_AUDIT(
                    Create_Date,
                    Check_Type,
                    Table_Name,
                    Column_Name,
                    Check_Status
                )
                VALUES (
                    CURRENT_TIMESTAMP(),
                    '${checkType}',
                    '${tableName}',
                    '${columnName}',
                    'ERROR: ${tableError.message.replace(/'/g, "''")}'
                )
            `;
            
            var errorInsertStmt = snowflake.createStatement({sqlText: errorInsertQuery});
            errorInsertStmt.execute();
        }
    }
    
    // Output Message
    var summaryMsg = `${CHECK_TYPE_PARAMETER} NULL column checks completed. Processed ${processedCount} checks successfully.`;
    if (failedChecks.length > 0) {
        summaryMsg += ` Failed checks (all NULL): ${failedChecks.join(', ')}.`;
    }
    if (erroredChecks.length > 0) {
        summaryMsg += ` Errored checks: ${erroredChecks.join('; ')}.`;
    }
    
    return summaryMsg;
    
} catch (error) {
    // Handle any unexpected errors when running the audit check
    var errorEmailQuery = `
        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_INTEGRATION', 
            '${emailRecipients}', 
            '(ERROR) ${CHECK_TYPE_PARAMETER} NULL Column Check Failed',
            'The ${CHECK_TYPE_PARAMETER} NULL column check procedure encountered an error. Error: ${error.message} Timestamp: ${new Date().toISOString()}'
        )
    `;
    
    var errorEmailStmt = snowflake.createStatement({sqlText: errorEmailQuery});
    errorEmailStmt.execute();
    
    return `ERROR: ${CHECK_TYPE_PARAMETER} NULL column check failed. Error: ${error.message}`;
}
$$;

-- Column List and Check Type Parameter Table
CREATE OR REPLACE TABLE DB.SCHEMA.COLUMN_AUDIT_CONFIG (
    TABLE_NAME STRING,
    COLUMN_NAME STRING,
    CHECK_TYPE STRING  -- DAILY/MONTHLY
);


