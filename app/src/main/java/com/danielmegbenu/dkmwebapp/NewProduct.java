package com.danielmegbenu.dkmwebapp;

import jakarta.validation.constraints.*;
import java.math.BigDecimal;

/**
 * What a client may send to create a product. It deliberately has no id: binding the request straight to the
 * JPA entity let a client send {"id": 1, ...} and overwrite an existing row (mass assignment, Sonar S4684).
 */
public record NewProduct(
        @NotBlank @Size(max = 120) String name,
        @NotNull @DecimalMin("0.00") BigDecimal price) {

    Product toEntity() {
        return new Product(name, price);
    }
}
