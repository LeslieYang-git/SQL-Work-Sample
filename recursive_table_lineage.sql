------------------------------------------------
-- Forward (tables that TARGET_TABLE_NAME table uses)
WITH RECURSIVE dependency_hierarchy AS (
    -- Base case: First level (direct dependencies for target table)
    SELECT 
        mtd.RECORD_ID,
        mtd.TABLE_ID AS TARGET_TABLE_ID,
        mt1.TABLE_NAME AS TARGET_TABLE,
        mt1.SCHEMA_NAME AS TARGET_TABLE_SCHEMA,
        mt1.DB_NAME AS TARGET_TABLE_DB,
        mtd.DEPENDENT_TABLE_ID,
        mt2.TABLE_NAME AS DEPENDENT_TABLE,
        mt2.SCHEMA_NAME AS DEPENDENT_SCHEMA,
        mt2.DB_NAME AS DEPENDENT_DB,
        1 AS LEVEL,
        ARRAY_CONSTRUCT(CONCAT(mt1.SCHEMA_NAME, '.', mt1.TABLE_NAME), 
                        CONCAT(mt2.SCHEMA_NAME, '.', mt2.TABLE_NAME)) AS PATH -- address self-reference/view
    FROM 
        DB.SCHEMA.TABLE_DEPENDENCY mtd
    JOIN 
        DB.SCHEMA.TABLE_CATALOG mt1
        ON mtd.TABLE_ID = mt1.TABLE_ID
    JOIN 
        DB.SCHEMA.TABLE_CATALOG mt2 
        ON mtd.DEPENDENT_TABLE_ID = mt2.TABLE_ID
    WHERE mt1.TABLE_NAME ILIKE 'TARGET_TABLE_NAME'

    
    UNION ALL
    
    -- Recursive case - refers to itself - captures all dependent tables
    SELECT 
        mtd.RECORD_ID,
        dh.DEPENDENT_TABLE_ID AS TARGET_TABLE_ID, -- Use previous dependent as new target
        dh.DEPENDENT_TABLE AS TARGET_TABLE,
        dh.DEPENDENT_SCHEMA AS TARGET_TABLE_SCHEMA,
        dh.DEPENDENT_DB AS TARGET_TABLE_DB,
        mtd.DEPENDENT_TABLE_ID,
        mt2.TABLE_NAME AS DEPENDENT_TABLE,
        mt2.SCHEMA_NAME AS DEPENDENT_SCHEMA,
        mt2.DB_NAME AS DEPENDENT_DB,
        dh.LEVEL + 1,
        ARRAY_APPEND(dh.PATH, CONCAT(mt2.SCHEMA_NAME, '.', mt2.TABLE_NAME))
    FROM 
        dependency_hierarchy dh
    JOIN 
        DB.SCHEMA.TABLE_DEPENDENCY mtd
        ON dh.DEPENDENT_TABLE_ID = mtd.TABLE_ID
    JOIN 
        DB.SCHEMA.TABLE_CATALOG mt2
        ON mtd.DEPENDENT_TABLE_ID = mt2.TABLE_ID
    WHERE 
        -- using schema+table name
        NOT ARRAY_CONTAINS(CONCAT(mt2.SCHEMA_NAME, '.', mt2.TABLE_NAME)::VARIANT, dh.PATH) -- Checks if the current table is already in the path to stop the recursive query from going into an infinite loop
        AND dh.LEVEL < 50
)
SELECT 
    RECORD_ID,
    TARGET_TABLE_ID,
    TARGET_TABLE,
    TARGET_TABLE_SCHEMA,
    TARGET_TABLE_DB,
    DEPENDENT_TABLE_ID,
    DEPENDENT_TABLE,
    DEPENDENT_SCHEMA,
    DEPENDENT_DB,
    LEVEL,
    ARRAY_TO_STRING(PATH, ' -> ') AS DEPENDENCY_PATH
FROM 
    dependency_hierarchy
ORDER BY 
    LEVEL, TARGET_TABLE, DEPENDENT_TABLE;


------------------------------------------------
-- Backward (first layer): direct dependents (tables that use TARGET_TABLE_NAME)
with a as(
SELECT 
    mtd.RECORD_ID,
    mtd.TABLE_ID AS SOURCE_TABLE_ID,
    mt1.TABLE_NAME AS SOURCE_TABLE,
    mt1.SCHEMA_NAME AS SOURCE_TABLE_SCHEMA,
    mt1.DB_NAME AS SOURCE_TABLE_DB,
    mtd.DEPENDENT_TABLE_ID AS TARGET_TABLE_ID,
    mt2.TABLE_NAME AS TARGET_TABLE,
    mt2.SCHEMA_NAME AS TARGET_TABLE_SCHEMA,
    mt2.DB_NAME AS TARGET_TABLE_DB
FROM 
    DB.SCHEMA.TABLE_DEPENDENCY mtd
JOIN 
    DB.SCHEMA.TABLE_CATALOG mt1
    ON mtd.TABLE_ID = mt1.TABLE_ID
JOIN 
    DB.SCHEMA.TABLE_CATALOG mt2 
    ON mtd.DEPENDENT_TABLE_ID = mt2.TABLE_ID
WHERE 
    mt2.TABLE_NAME ILIKE '%TARGET_TABLE_NAME%'
    AND mt2.SCHEMA_NAME ILIKE '%ANALYTICS_PROD%'
ORDER BY 
    mt1.SCHEMA_NAME,
    mt1.TABLE_NAME)
select distinct source_table from a;


--Backward (Multiple Layer):
WITH a as(
WITH RECURSIVE dependency_hierarchy AS (
    -- Base case: Find all tables that directly depend on TARGET_TABLE_NAME table
    SELECT 
        mtd.RECORD_ID,
        mtd.TABLE_ID AS SOURCE_TABLE_ID,
        mt1.TABLE_NAME AS SOURCE_TABLE,
        mt1.SCHEMA_NAME AS SOURCE_TABLE_SCHEMA,
        mt1.DB_NAME AS SOURCE_TABLE_DB,
        mtd.DEPENDENT_TABLE_ID AS TARGET_TABLE_ID,
        mt2.TABLE_NAME AS TARGET_TABLE,
        mt2.SCHEMA_NAME AS TARGET_TABLE_SCHEMA,
        mt2.DB_NAME AS TARGET_TABLE_DB,
        1 AS LEVEL,
        ARRAY_CONSTRUCT(CONCAT(mt1.SCHEMA_NAME, '.', mt1.TABLE_NAME), 
                        CONCAT(mt2.SCHEMA_NAME, '.', mt2.TABLE_NAME)) AS PATH
    FROM 
        DB.SCHEMA.TABLE_DEPENDENCY mtd
    JOIN 
        DB.SCHEMA.TABLE_CATALOG mt1
        ON mtd.TABLE_ID = mt1.TABLE_ID
    JOIN 
        DB.SCHEMA.TABLE_CATALOG mt2 
        ON mtd.DEPENDENT_TABLE_ID = mt2.TABLE_ID
    WHERE mt2.TABLE_NAME ILIKE '%TARGET_TABLE_NAME%'  -- tables that depend on TARGET_TABLE_NAME
    
    UNION ALL
    
    -- Recursive case: Find tables that depend on our source tables
    SELECT 
        mtd.RECORD_ID,
        mtd.TABLE_ID AS SOURCE_TABLE_ID,
        mt1.TABLE_NAME AS SOURCE_TABLE,
        mt1.SCHEMA_NAME AS SOURCE_TABLE_SCHEMA,
        mt1.DB_NAME AS SOURCE_TABLE_DB,
        dh.SOURCE_TABLE_ID AS TARGET_TABLE_ID,  
        dh.SOURCE_TABLE AS TARGET_TABLE,
        dh.SOURCE_TABLE_SCHEMA AS TARGET_TABLE_SCHEMA,
        dh.SOURCE_TABLE_DB AS TARGET_TABLE_DB,
        dh.LEVEL + 1,
        ARRAY_APPEND(dh.PATH, CONCAT(mt1.SCHEMA_NAME, '.', mt1.TABLE_NAME))
    FROM 
        dependency_hierarchy dh
    JOIN 
        DB.SCHEMA.TABLE_DEPENDENCY mtd
        ON dh.SOURCE_TABLE_ID = mtd.DEPENDENT_TABLE_ID  
    JOIN 
        DB.SCHEMA.TABLE_CATALOG mt1
        ON mtd.TABLE_ID = mt1.TABLE_ID
    WHERE 
        NOT ARRAY_CONTAINS(CONCAT(mt1.SCHEMA_NAME, '.', mt1.TABLE_NAME)::VARIANT, dh.PATH)
        AND dh.LEVEL < 50
)
SELECT 
    RECORD_ID,
    SOURCE_TABLE_ID,
    SOURCE_TABLE,
    SOURCE_TABLE_SCHEMA,
    SOURCE_TABLE_DB,
    TARGET_TABLE_ID,
    TARGET_TABLE,
    TARGET_TABLE_SCHEMA,
    TARGET_TABLE_DB,
    LEVEL,
    ARRAY_TO_STRING(PATH, ' -> ') AS DEPENDENCY_PATH
FROM 
    dependency_hierarchy
ORDER BY 
    LEVEL, SOURCE_TABLE, TARGET_TABLE)
    
SELECT distinct SOURCE_TABLE from a;
