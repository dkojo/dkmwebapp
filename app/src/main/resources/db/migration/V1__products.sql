CREATE TABLE products (
  id    BIGINT AUTO_INCREMENT PRIMARY KEY,
  name  VARCHAR(120)   NOT NULL,
  price DECIMAL(10, 2) NOT NULL
);

INSERT INTO products (name, price) VALUES
  ('Mechanical keyboard', 89.00),
  ('USB-C dock', 129.00),
  ('Noise-cancelling headphones', 199.00);
