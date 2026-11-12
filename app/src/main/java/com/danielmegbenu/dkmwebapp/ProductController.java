package com.danielmegbenu.dkmwebapp;

import jakarta.validation.Valid;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ThreadLocalRandom;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.server.ResponseStatusException;

@RestController
@RequestMapping("/api")
public class ProductController {
    private final ProductRepository products;
    private final String version;
    private final double errorRate;

    public ProductController(ProductRepository products,
                             @Value("${app.version:dev}") String version,
                             // Fraction of /api/products requests that fail with 500. Used to prove canary rollback works.
                             @Value("${app.fault.error-rate:0}") double errorRate) {
        this.products = products;
        this.version = version;
        this.errorRate = errorRate;
    }

    @GetMapping("/products")
    public List<Product> list() {
        if (errorRate > 0 && ThreadLocalRandom.current().nextDouble() < errorRate) {
            throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "injected fault");
        }
        return products.findAll();
    }

    @GetMapping("/products/{id}")
    public Product get(@PathVariable Long id) {
        return products.findById(id).orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND));
    }

    @PostMapping("/products")
    @ResponseStatus(HttpStatus.CREATED)
    public Product create(@Valid @RequestBody NewProduct request) {
        return products.save(request.toEntity());
    }

    @GetMapping("/version")
    public Map<String, String> version() {
        return Map.of("version", version);
    }
}
