-- OTP lookups are always by email.
ALTER TABLE otps ADD INDEX idx_otps_email (email);
