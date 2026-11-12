-- A new migration, never an edit to V1: Flyway checksums applied migrations and refuses to start if one changes.
INSERT INTO products (name, price) VALUES ('4K webcam', 149.00);
