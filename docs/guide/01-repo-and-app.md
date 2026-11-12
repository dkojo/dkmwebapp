# Phase 1: Repository and sample app

**Goal:** `dkmwebapp`, a small Spring Boot service with a MySQL database, metrics endpoint, health probes and a
built-in "fault switch" for testing canary rollbacks, running locally in Docker.

**Time:** 2–3 hours · **Cost:** $0

---

## 1.1 The repository layout you're building toward

```
dkmwebapp/
├── app/                         dkmwebapp source, Dockerfile           (this phase)
├── infra/
│   ├── foundation/              ECR, CI role, ACM certificate — kept    (Phase 2)
│   └── platform/                VPC, EKS, RDS — created per session     (Phases 3, 5)
├── gitops/
│   ├── bootstrap/               the one Application you apply by hand   (Phase 4)
│   ├── platform/                add-ons as Argo CD Applications         (Phases 4, 5, 8, 9, 10)
│   ├── apps/                    the dkmwebapp Application               (Phase 7)
│   └── charts/dkmwebapp/        Helm chart: Rollout, Service, Ingress…  (Phase 7)
├── .github/workflows/ci.yml     the pipeline                            (Phase 6)
├── docs/                        this guide, architecture, screenshots
└── legacy-2024/                 the 2024 Jenkins version, kept for comparison (Phase 0.4)
```

---

## 1.2 Generate the Spring Boot project

Spring's generator always gives you the current Spring Boot release, so there's no version to guess:

```bash
cd /c/Users/User/dkmwebapp
curl -s https://start.spring.io/starter.zip \
  -d type=maven-project -d language=java -d javaVersion=21 \
  -d groupId=com.danielmegbenu -d artifactId=dkmwebapp -d name=dkmwebapp \
  -d packageName=com.danielmegbenu.dkmwebapp \
  -d dependencies=web,actuator,data-jpa,mysql,flyway,validation,prometheus,h2 \
  -o app.zip
mkdir app && cd app && unzip -q ../app.zip && rm ../app.zip && cd ..
ls app   # HELP.md  mvnw  mvnw.cmd  pom.xml  src
```

`h2` is an in-memory database used only by the tests, so they don't need MySQL. The generator adds it with
`runtime` scope plus a `spring-boot-h2console` dependency, which would ship H2 and its web console in the
production image. In `app/pom.xml`, **delete the `spring-boot-h2console` dependency** and change H2's scope to
`test`:

```xml
<dependency>
  <groupId>com.h2database</groupId>
  <artifactId>h2</artifactId>
  <scope>test</scope>
</dependency>
```

Also delete `app/HELP.md`.

### Add test coverage (SonarQube reads it in Phase 6)

In `app/pom.xml`, inside `<build><plugins>`, add JaCoCo. Look up the latest version from Maven Central's
metadata (the search.maven.org index can lag several releases behind):
`curl -s https://repo1.maven.org/maven2/org/jacoco/jacoco-maven-plugin/maven-metadata.xml | grep '<release>'`

```xml
<plugin>
  <groupId>org.jacoco</groupId>
  <artifactId>jacoco-maven-plugin</artifactId>
  <version>‹latest, e.g. 0.8.16›</version>
  <executions>
    <execution><goals><goal>prepare-agent</goal></goals></execution>
    <execution><id>report</id><phase>verify</phase><goals><goal>report</goal></goals></execution>
  </executions>
</plugin>
```

---

## 1.3 The application code

All paths are under `app/src/main/java/com/danielmegbenu/dkmwebapp/`.

**`Product.java`**, the entity:

```java
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
```

**`ProductRepository.java`**:

```java
package com.danielmegbenu.dkmwebapp;

import org.springframework.data.jpa.repository.JpaRepository;

public interface ProductRepository extends JpaRepository<Product, Long> {}
```

**`NewProduct.java`**: what a client may send. It has no `id` on purpose: binding a request straight to the
entity let a client send `{"id": 1, …}` and overwrite an existing row (mass assignment, flagged by SonarQube as
S4684 on the first CI run):

```java
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
```

**`ProductController.java`**: the API, plus the fault switch used in Phase 10:

```java
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
```

### Database schema: `app/src/main/resources/db/migration/V1__products.sql`

```sql
CREATE TABLE products (
  id    BIGINT AUTO_INCREMENT PRIMARY KEY,
  name  VARCHAR(120)   NOT NULL,
  price DECIMAL(10, 2) NOT NULL
);

INSERT INTO products (name, price) VALUES
  ('Mechanical keyboard', 89.00),
  ('USB-C dock', 129.00),
  ('Noise-cancelling headphones', 199.00);
```

### Configuration: replace `app/src/main/resources/application.properties` with `application.yml`

```yaml
spring:
  application:
    name: dkmwebapp
  datasource:
    url: jdbc:mysql://${DB_HOST:localhost}:${DB_PORT:3306}/${DB_NAME:dkm}?useSSL=true&requireSSL=false
    username: ${DB_USERNAME:dkm}
    password: ${DB_PASSWORD:dkm}
  jpa:
    hibernate:
      ddl-auto: validate          # Flyway owns the schema
    open-in-view: false
  lifecycle:
    timeout-per-shutdown-phase: 20s

server:
  shutdown: graceful              # finish in-flight requests when Kubernetes stops a pod

app:
  version: ${APP_VERSION:dev}
  fault:
    error-rate: ${FAULT_ERROR_RATE:0}

management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  endpoint:
    health:
      probes:
        enabled: true             # /actuator/health/liveness and /readiness for Kubernetes
  metrics:
    tags:
      application: dkmwebapp
    distribution:
      percentiles-histogram:
        http.server.requests: true   # latency histograms for p95 in Grafana and canary analysis
```

```bash
rm app/src/main/resources/application.properties
```

### Test configuration: `app/src/test/resources/application-test.yml`

```yaml
# Loaded on top of src/main/resources/application.yml when the "test" profile is active (see @ActiveProfiles).
# Keep the name: a test application.yml would replace the main file entirely instead of overriding it.
spring:
  datasource:
    url: jdbc:h2:mem:dkm;MODE=MySQL;DATABASE_TO_LOWER=TRUE
    username: sa
    password: ""
```

⚠️ Don't name this file `application.yml`. A test `application.yml` **replaces** the main one instead of
adding to it, so the tests would silently lose every main setting, including the actuator exposure, and
`/actuator/prometheus` would return 404. As a profile file it only overrides the datasource. Each test class
turns it on with `@ActiveProfiles("test")`; add that to the generated `DkmwebappApplicationTests.java` too:

```java
@SpringBootTest
@ActiveProfiles("test")          // H2 instead of MySQL, from application-test.yml
class DkmwebappApplicationTests {
```

(import `org.springframework.test.context.ActiveProfiles`).

### A real test: `app/src/test/java/com/danielmegbenu/dkmwebapp/ProductControllerTest.java`

```java
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
    void createIgnoresClientSuppliedIdSoItCannotOverwriteARow() throws Exception {
        String before = mvc.perform(get("/api/products/1")).andReturn().getResponse().getContentAsString();
        String body = mvc.perform(post("/api/products").contentType(MediaType.APPLICATION_JSON)
                                 .content("{\"id\":1,\"name\":\"Overwritten\",\"price\":0}"))
           .andExpect(status().isCreated())
           .andReturn().getResponse().getContentAsString();
        Number newId = JsonPath.read(body, "$.id");
        org.junit.jupiter.api.Assertions.assertNotEquals(1, newId.intValue(), "a new product must get a new id");
        mvc.perform(get("/api/products/1"))
           .andExpect(status().isOk())
           .andExpect(content().json(before));        // product 1 is unchanged
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
```

Two Spring Boot 4 details: `AutoConfigureMockMvc` lives in `org.springframework.boot.webmvc.test.autoconfigure`,
and `@AutoConfigureMetrics` is needed because Spring Boot switches off metrics export in tests, which would
remove the Prometheus endpoint.

### The fault switch test: `app/src/test/java/com/danielmegbenu/dkmwebapp/FaultInjectionTest.java`

```java
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
```

These extra tests matter in Phase 6: SonarQube Cloud's default quality gate needs **80% coverage**, and the
first four tests alone reach only about 58%.

```bash
cd app && ./mvnw -B clean verify && cd ..
# Tests run: 10, Failures: 0 ... BUILD SUCCESS
# Coverage report: app/target/site/jacoco/index.html (about 95%)
```

Use `clean` whenever you rename or delete a resource file: otherwise the old copy stays in `target/` and is
still loaded.

---

## 1.4 The Dockerfile: `app/Dockerfile`

Multi-stage: Maven builds in a full JDK image, and only the JAR goes into a minimal, non-root runtime image with
no shell or package manager.

```dockerfile
# syntax=docker/dockerfile:1

# $BUILDPLATFORM: Maven always runs natively, even when CI builds the arm64 image. The JAR is the same on
# every architecture, so only the small runtime stage below is built per architecture. Without this, the
# arm64 build runs Maven under emulation and takes about 10 minutes instead of 1.
FROM --platform=$BUILDPLATFORM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml mvnw ./
COPY .mvn .mvn
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q dependency:go-offline
COPY src src
RUN --mount=type=cache,target=/root/.m2 ./mvnw -B -q package -DskipTests \
 && cp target/dkmwebapp-*.jar /app.jar

# Distroless on Debian 13: no shell, no package manager, runs as UID 65532. The Debian 12 image lags on
# security fixes (Trivy found 10 fixable HIGH/CRITICAL there), so use the newer base.
FROM gcr.io/distroless/java21-debian13:nonroot
COPY --from=build /app.jar /app/app.jar
# The :nonroot base already runs as 65532; stating it makes it visible to scanners, and a numeric UID lets
# Kubernetes verify runAsNonRoot (Phase 9) without trusting the image metadata.
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75", "-jar", "/app/app.jar"]
```

`app/.dockerignore`:

```
target/
*.iml
.idea/
```

---

## 1.5 Run it locally with MySQL: `docker-compose.yml` (repo root)

```yaml
services:
  db:
    image: mysql:8.4
    environment:
      MYSQL_DATABASE: dkm
      MYSQL_USER: dkm
      MYSQL_PASSWORD: dkm
      MYSQL_ROOT_PASSWORD: root-local-only
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      retries: 20

  api:
    build: ./app
    environment:
      DB_HOST: db
      APP_VERSION: local
    ports: ["8080:8080"]
    depends_on:
      db:
        condition: service_healthy
```

```bash
docker compose up --build -d
docker compose logs -f api      # wait for "Started DkmwebappApplication", then Ctrl+C
```

---

## ✅ Phase 1 checkpoint

```bash
curl -s localhost:8080/api/products | jq length          # 3
curl -s localhost:8080/api/version                        # {"version":"local"}
curl -s localhost:8080/actuator/health/readiness          # {"status":"UP"}
curl -s localhost:8080/actuator/prometheus | grep -c http_server_requests_seconds_bucket   # a number > 0
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/api/products/999   # 404
docker image ls --format '{{.Repository}} {{.Size}}' | grep api   # about 375 MB in Docker Desktop (about 250 MB of layers; it counts compressed + unpacked)
trivy image --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 dkmwebapp-api && echo "no fixable critical/high CVEs"
```

Then stop it: `docker compose down -v`.

### If something goes wrong

| Symptom | Fix |
|---|---|
| `Communications link failure` at startup | MySQL wasn't ready. `docker compose up` again; the health check should prevent it. |
| `Schema-validation: missing table [products]` | The migration file name must be exactly `V1__products.sql` (two underscores) in `db/migration`. |
| Trivy reports a fixable CRITICAL/HIGH in the base image | Pull the newest base (`docker compose build --pull`). Distroless images are rebuilt often. Findings with no fix yet are skipped by `--ignore-unfixed`, the same rule the CI scan uses in Phase 6. |
| `/actuator/prometheus` returns 404 in tests | The test config is named `application.yml` (it must be `application-test.yml`), or `@AutoConfigureMetrics` is missing. Then `./mvnw clean verify`. |

## Commit

```bash
git add -A
git commit -m "Add dkmwebapp service, Dockerfile and local compose stack"
git push
```

**Next:** [Phase 2: Terraform foundation](02-terraform-foundation.md)
