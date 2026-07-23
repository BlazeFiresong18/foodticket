-- Baseline schema predating the versioned migrations in db/migrations/.
-- migrate.sh runs this first (idempotently, via CREATE TABLE IF NOT EXISTS)
-- so a brand-new database can be provisioned from this repo alone; on an
-- existing database every statement here is a no-op since the tables
-- already exist. Migrations 001+ then layer roles/QR/audit/etc. on top.

CREATE TABLE IF NOT EXISTS users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(255) NOT NULL UNIQUE,
  name VARCHAR(255) NOT NULL,
  password VARCHAR(255) NOT NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS otps (
  id INT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(255) NOT NULL,
  code VARCHAR(6) NOT NULL,
  expires_at DATETIME NOT NULL,
  used TINYINT(1) DEFAULT 0
);

CREATE TABLE IF NOT EXISTS redemptions (
  id INT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(255) NOT NULL,
  redeemed_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
