# Build stage
FROM maven:3.9.9-eclipse-temurin-17 AS build

WORKDIR /build

# Dependencies first — the pom is stable in git, so this layer stays cached
COPY myapp/pom.xml .
RUN mvn -B -e -ntp dependency:go-offline


COPY myapp/src ./src

# Changing the pom.xml value and building the jar
ARG APP_VER=0.0.0
RUN mvn -B -ntp versions:set -DnewVersion="$APP_VER" -DgenerateBackupPoms=false package


# Runtime stage
FROM eclipse-temurin:17.0.13_11-jre-alpine

# Non-root user with a fixed UID, so runAsNonRoot can verify it
RUN addgroup -S -g 10001 app && adduser -S -u 10001 -G app app

WORKDIR /app

COPY --from=build --chown=10001:10001 /build/target/myapp-*.jar /app/app.jar

USER 10001:10001

ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-jar", "/app/app.jar"]