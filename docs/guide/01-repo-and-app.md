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

`h2` is an in-memory database used only by the tests, so they don't need MySQL.

### Add test coverage (SonarQube reads it in Phase 6)

In `app/pom.xml`, inside `<build><plugins>`, add JaCoCo. Look up the latest version with
`curl -s https://search.maven.org/solrsearch/select?q=g:org.jacoco+AND+a:jacoco-maven-plugin | jq -r '.response.docs[0].latestVersion'`:

```xml
<plugin>
  <groupId>org.jacoco</groupId>
  <artifactId>jacoco-maven-plugin</artifactId>
  <version>‹latest, e.g. 0.8.14›</version>
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
    public Product create(@Valid @RequestBody Product product) {
        return products.save(product);
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

### Test configuration: `app/src/test/resources/application.yml`

```yaml
spring:
  datasource:
    url: jdbc:h2:mem:dkm;MODE=MySQL;DATABASE_TO_LOWER=TRUE
    username: sa
    password: ""
```

### A real test: `app/src/test/java/com/danielmegbenu/dkmwebapp/ProductControllerTest.java`

```java
package com.danielmegbenu.dkmwebapp;

import static org.hamcrest.Matchers.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest
@AutoConfigureMockMvc
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
    void exposesHealthAndMetrics() throws Exception {
        mvc.perform(get("/actuator/health/readiness")).andExpect(status().isOk());
        mvc.perform(get("/actuator/prometheus")).andExpect(status().isOk());
    }
}
```

> If your Spring Boot version moved `AutoConfigureMockMvc` to a different package, your IDE's quick-fix shows the
> new import. Spring Boot 4 split some test auto-configuration into separate modules.

```bash
cd app && ./mvnw -B verify && cd ..
# Tests run: 5, Failures: 0 ... BUILD SUCCESS   (4 tests + the generated context test)
```

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

# Distroless: no shell, no package manager, runs as UID 65532
FROM gcr.io/distroless/java21-debian12:nonroot
COPY --from=build /app.jar /app/app.jar
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
docker image ls --format '{{.Repository}} {{.Size}}' | grep api   # roughly 200–250 MB
trivy image --severity CRITICAL,HIGH --exit-code 1 dkmwebapp-api && echo "no critical/high CVEs"
```

Then stop it: `docker compose down -v`.

### If something goes wrong

| Symptom | Fix |
|---|---|
| `Communications link failure` at startup | MySQL wasn't ready. `docker compose up` again; the health check should prevent it. |
| `Schema-validation: missing table [products]` | The migration file name must be exactly `V1__products.sql` (two underscores) in `db/migration`. |
| Trivy reports a CRITICAL in the base image | Pull the newest base (`docker compose build --pull`). Distroless images are rebuilt often. |

## Commit

```bash
git add -A
git commit -m "Add dkmwebapp service, Dockerfile and local compose stack"
git push
```

**Next:** [Phase 2: Terraform foundation](02-terraform-foundation.md)
