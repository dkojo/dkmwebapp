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
