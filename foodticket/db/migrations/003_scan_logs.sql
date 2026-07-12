-- Every scan attempt, valid or not; feeds the admin oversight view.
CREATE TABLE scan_logs (
  id INT AUTO_INCREMENT PRIMARY KEY,
  scanner_user_id INT NULL,
  raw_payload VARCHAR(512) NOT NULL,
  matched_user_id INT NULL,
  result ENUM('redeemed','otp_sent','invalid_token','inactive_user',
              'cooldown','otp_failed') NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_scan_logs_created (created_at),
  INDEX idx_scan_logs_result (result)
);
