-- Tie redemptions to user ids (and the staff member who scanned).
-- Legacy rows keep their email; user_id is backfilled where it matches.
ALTER TABLE redemptions
  ADD COLUMN user_id INT NULL,
  ADD COLUMN scanner_user_id INT NULL,
  ADD INDEX idx_redemptions_user_date (user_id, redeemed_at),
  ADD INDEX idx_redemptions_email (email);

UPDATE redemptions r
  JOIN users u ON u.email = r.email
  SET r.user_id = u.id
  WHERE r.user_id IS NULL;
