package com.danielmegbenu.dkmwebapp;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;

@SpringBootTest
@ActiveProfiles("test")          // H2 instead of MySQL, from application-test.yml
class DkmwebappApplicationTests {

	@Test
	void contextLoads() {
	}

}
