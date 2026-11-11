package com.danielmegbenu.dkmwebapp;

import jakarta.persistence.*;
import jakarta.validation.constraints.*;
import java.math.BigDecimal;

@Entity
@Table(name = "products")
public class Product {
    @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @NotBlank @Size(max = 120)
    private String name;

    @NotNull @DecimalMin("0.00")
    private BigDecimal price;

    protected Product() {}
    public Product(String name, BigDecimal price) { this.name = name; this.price = price; }

    public Long getId() { return id; }
    public String getName() { return name; }
    public BigDecimal getPrice() { return price; }
}
