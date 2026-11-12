package com.danielmegbenu.dkmwebapp;

import static org.hamcrest.Matchers.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import com.jayway.jsonpath.JsonPath;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.micrometer.metrics.test.autoconfigure.AutoConfigureMetrics;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest
@ActiveProfiles("test")          // H2 instead of MySQL, from application-test.yml
@AutoConfigureMockMvc
@AutoConfigureMetrics            // Spring Boot turns off metrics export in tests; this brings /actuator/prometheus back
class ProductControllerTest {
    @Autowired MockMvc mvc;

    @Test
    void listsSeededProducts() throws Exception {
        mvc.perform(get("/api/products"))
           .andExpect(status().isOk())
           .andExpect(jsonPath("$", hasSize(greaterThanOrEqualTo(3))));
    }

    @Test
    void rejectsInvalidProduct() throws Exception {
        mvc.perform(post("/api/products").contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"\",\"price\":-1}"))
           .andExpect(status().isBadRequest());
    }

    @Test
    void returns404ForMissingProduct() throws Exception {
        mvc.perform(get("/api/products/999999")).andExpect(status().isNotFound());
    }

    @Test
    void createsAndFetchesProduct() throws Exception {
        String body = mvc.perform(post("/api/products").contentType(MediaType.APPLICATION_JSON)
                                 .content("{\"name\":\"Webcam\",\"price\":49.99}"))
           .andExpect(status().isCreated())
           .andExpect(jsonPath("$.id", notNullValue()))
           .andExpect(jsonPath("$.name").value("Webcam"))
           .andReturn().getResponse().getContentAsString();
        Number id = JsonPath.read(body, "$.id");
        mvc.perform(get("/api/products/" + id))
           .andExpect(status().isOk())
           .andExpect(jsonPath("$.price").value(49.99));
    }

    @Test
    void reportsVersion() throws Exception {
        mvc.perform(get("/api/version"))
           .andExpect(status().isOk())
           .andExpect(jsonPath("$.version").value("dev"));
    }

    @Test
    void exposesHealthAndMetrics() throws Exception {
        mvc.perform(get("/actuator/health/readiness")).andExpect(status().isOk());
        mvc.perform(get("/actuator/prometheus")).andExpect(status().isOk());
    }
}
