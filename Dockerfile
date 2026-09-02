# Build stage
FROM maven:3.9.9-eclipse-temurin-17 AS build

WORKDIR /build

# Dependencies first, so this layer is cached unless the pom changes
COPY myapp/pom.xml .
RUN mvn -B -e dependency:go-offline

# Sources change often; keep them in a later layer
COPY myapp/src ./src
RUN mvn -B package

# Runtime stage
FROM eclipse-temurin:17.0.13_11-jre-alpine

# Non-root user, created explicitly
RUN addgroup -S app && adduser -S -G app app

WORKDIR /app

COPY --from=build --chown=app:app /build/target/myapp-*.jar /app/app.jar

USER app

ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-jar", "/app/app.jar"]

# why did i choose each version