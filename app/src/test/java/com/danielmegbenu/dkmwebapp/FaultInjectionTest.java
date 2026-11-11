package com.danielmegbenu.dkmwebapp;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

// The fault switch Phase 10 uses to prove a bad canary is rolled back: at error-rate 1, every list request fails.
@SpringBootTest(properties = "app.fault.error-rate=1")
@ActiveProfiles("test")
@AutoConfigureMockMvc
class FaultInjectionTest {
    @Autowired MockMvc mvc;

    @Test
    void failsListRequestsWhenFaultIsOn() throws Exception {
        mvc.perform(get("/api/products")).andExpect(status().isInternalServerError());
    }

    @Test
    void leavesOtherEndpointsAlone() throws Exception {
        mvc.perform(get("/api/version")).andExpect(status().isOk());
    }
}
