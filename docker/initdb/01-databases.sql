-- Runs once, on the first start of an empty data volume.
-- MARIADB_DATABASE can create only one database, so both are created here.
-- MariaDB 11.4 still defaults to latin1, so utf8mb4 is set explicitly.
CREATE DATABASE IF NOT EXISTS oc_dev CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS oc_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
