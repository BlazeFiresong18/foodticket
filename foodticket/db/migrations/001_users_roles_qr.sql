-- Roles, per-customer QR identity, and account activation flag.
ALTER TABLE users
  ADD COLUMN role ENUM('customer','scanner','admin') NOT NULL DEFAULT 'customer',
  ADD COLUMN qr_token CHAR(43) NULL,
  ADD COLUMN qr_issued_at DATETIME NULL,
  ADD COLUMN is_active TINYINT(1) NOT NULL DEFAULT 1,
  ADD UNIQUE KEY uq_users_qr_token (qr_token);
