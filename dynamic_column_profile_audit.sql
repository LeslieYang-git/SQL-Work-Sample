-- Audit Stats Table
CREATE OR REPLACE TABLE DB.SCHEMA.COLUMN_PROFILE_AUDIT(
ColumnName TEXT,
SEGMENT VARCHAR,
SUBSEGMENT VARCHAR,
Column_RecordCount INT,
DistinctValueCount INT,
CATEGORY_FLAG_COUNT INT,
Create_Date TIMESTAMP
);



-- Column name table
CREATE OR REPLACE TABLE DB.SCHEMA.PROFILE_COLUMN_CONFIG(
ColumnName VARCHAR
);


-- Stored procedure for all columns that need to do auditing for 
CREATE OR REPLACE PROCEDURE DB.SCHEMA.PROFILE_CONFIGURED_COLUMNS()
RETURNS STRING
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
var resultTable = 'DB.SCHEMA.COLUMN_PROFILE_AUDIT';

try {
    // Create a temporary table to hold the results for colName, SEGMENT, SUBSEGMENT, column_recordCount, distinctValueCount
    // Generate a unique temporary table name by appending a random number in the end
    var tempTable = 'TEMP_RESULTS_' + Math.floor(Math.random() * 1000000); 
    var createTempTableSQL = `
        CREATE TEMP TABLE ${tempTable} (
            ColumnName STRING,
            SEGMENT STRING,
            SUBSEGMENT STRING,
            Column_RecordCount NUMBER,
            DistinctValueCount NUMBER,
            CATEGORY_FLAG_COUNT NUMBER
        )
    `;
    snowflake.createStatement({sqlText: createTempTableSQL}).execute();

    // Get the Column Names from DB.SCHEMA.PROFILE_COLUMN_CONFIG table
    var getColumnNamesSQL = "SELECT ColumnName FROM DB.SCHEMA.PROFILE_COLUMN_CONFIG";
    var stmt1 = snowflake.createStatement({sqlText: getColumnNamesSQL});
    var resultSet1 = stmt1.execute();

    // Loop through all columns that we want to do auditing for
    while (resultSet1.next()) {
        var colName = resultSet1.getColumnValue(1);

        // Construct the dynamic SQL to get record counts for each column and group by SEGMENT and SUBSEGMENT
        var sql_command = `
            INSERT INTO ${tempTable} (ColumnName, SEGMENT, SUBSEGMENT, Column_RecordCount, DistinctValueCount)
            SELECT 
                '${colName}' AS ColName, 
                A.SEGMENT, 
                A.SUBSEGMENT,
                COUNT(A.${colName}) AS Column_RecordCount, 
                COUNT(DISTINCT A.${colName}) AS DistinctValueCount
            FROM 
                ANALYTICS_SANDBOX.ENTITY_SNAPSHOT A
            GROUP BY ALL
        `;

        // Execute the dynamic SQL
        snowflake.createStatement({sqlText: sql_command}).execute();
    }

    // Create a temporary table to hold the results for CATEGORY_FLAG_COUNT
    var tempTableCategory = 'TEMP_RESULTS_CATEGORY_' + Math.floor(Math.random() * 1000000); 
    var createTempTableSQLCategory = `
        CREATE TEMP TABLE ${tempTableCategory} (
            ColumnName STRING,
            SEGMENT STRING,
            SUBSEGMENT STRING,
            Column_RecordCount NUMBER,
            DistinctValueCount NUMBER,
            CATEGORY_FLAG NUMBER
        )
    `;
    snowflake.createStatement({sqlText: createTempTableSQLCategory}).execute();

    // Populate the temporary table for CATEGORY_FLAG
    var populateCategorySQL = `
        INSERT INTO ${tempTableCategory} (ColumnName, SEGMENT, SUBSEGMENT, Column_RecordCount, DistinctValueCount, CATEGORY_FLAG)
        SELECT 
            '${colName}' AS ColName, 
            A.SEGMENT, 
            A.SUBSEGMENT,
            COUNT(A.${colName}) AS Column_RecordCount, 
            COUNT(DISTINCT A.${colName}) AS DistinctValueCount,
            SUM(B.CURRENT_CATEGORY_FLAG) AS CATEGORY_FLAG
        FROM 
            ANALYTICS_SANDBOX.ENTITY_SNAPSHOT A
        LEFT JOIN ANALYTICS_SANDBOX.ENTITY_ATTRIBUTE B
        ON A.ENTITY_ID = B.ENTITY_ID
        AND A.RECORD_ID = B.RECORD_ID
        GROUP BY ALL
    `;
    snowflake.createStatement({sqlText: populateCategorySQL}).execute();

    // Calculate CATEGORY_FLAG_COUNT separately from the temporary table
    var updatetempTableCategory = `
        UPDATE ${tempTable} t
        SET CATEGORY_FLAG_COUNT = t1.CATEGORY_FLAG
        FROM ${tempTableCategory} t1
        WHERE t1.ColumnName = t.ColumnName AND t1.SEGMENT = t.SEGMENT AND t1.SUBSEGMENT = t.SUBSEGMENT
    `;

    snowflake.createStatement({sqlText: updatetempTableCategory}).execute();


    // Insert the results from the temporary table into the final result table
    var insertSQL = `
        INSERT INTO ${resultTable} (ColumnName, SEGMENT, SUBSEGMENT, Column_RecordCount, DistinctValueCount, CATEGORY_FLAG_COUNT, Create_Date)
        SELECT 
            ColumnName, 
            SEGMENT, 
            SUBSEGMENT, 
            Column_RecordCount, 
            DistinctValueCount,
            CATEGORY_FLAG_COUNT,
            CURRENT_TIMESTAMP()
        FROM 
            ${tempTable}
    `;
    snowflake.createStatement({sqlText: insertSQL}).execute();

    // Drop the temporary tables
    var dropTempTableSQL = `DROP TABLE ${tempTable}`;
    snowflake.createStatement({sqlText: dropTempTableSQL}).execute();
    var dropTempTableSQLCATEGORY = `DROP TABLE ${tempTableCategory}`;
    snowflake.createStatement({sqlText: dropTempTableSQLCATEGORY}).execute();

    return 'Stored Procedure completed successfully';
} catch (err) {
    return 'Error: ' + err;
}
$$;
