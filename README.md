# maven-hello-world — CI/CD Pipeline

A Java/Maven "Hello World" application with fully automated GitHub Actions
pipelines: automatic patch version bumping using git tags, multistage Docker build, non-root
runtime, Docker Hub publishing, and Kubernetes deployment via Helm to a kind cluster.

Forked from ido83/maven-hello-world - https://github.com/ido83/maven-hello-world

---

## 1. Overview


 **Language** - Java 17       
 **Build tool** - Apache Maven        
 **CI/CD** - GitHub Actions        
 **Registry** - Docker Hub — `noamkux/maven-hello-world`        
 **Orchestration** - Kubernetes via Helm        

### Pipeline flow

```
push to main
      |
      v
  read MAJOR.MINOR from pom.xml  ->  find highest matching git tag  ->  bump patch
      |
      v
  multistage docker build  (version injected as --build-arg APP_VER)
      |
      v
  smoke test  (entrypoint + non-root)
      |
      +--> extract jar from image  ->  upload as build artifact
      |
      v
  push image to Docker Hub  (version tag only)
      |
      v
  pull the pushed image and run it
      |
      v
  deploy to a kind cluster with Helm
      |
      v
  promote :latest
      |
      v
  tag the release  (v1.0.1)
```

**Three writes leave the runner**, in ascending order of what a failure costs. `:VERSION` goes first, because the kind deployment pulls it from Docker Hub - that pull is what proves the published image is the one that runs.       
A version tag of a build that later fails deployment is harmless: nothing points at it and
nothing resolves to it by accident. `:latest` moves only after the deploy succeeds, since it is the tag people pull without thinking.        
The `git tag` is created last, so the release record exists only for an artifact that was proven
end to end.


### Versioning Strategy

The assignment requires a jar at `1.0.0` whose patch component then increments automatically on every build.       
That is one number that has to live somewhere and move.      
There are three places it can live.

**A — the pom is the source of truth.** The pipeline reads the version, bump it, writes it back with `versions:set`, and commits the modified pom.

**B — git tags are the source of truth.** The pom holds a placeholder such as `0.0.0-SNAPSHOT`, and the pipeline derives the version from the latest tag.

**C — split by who decides.** The pom declares `MAJOR.MINOR` and never changes in CI.       
Tags carry `PATCH`. The pipeline reads the series from the pom, finds the highest tag in it, and adds one.

**Chosen: C.**

**Why not A.** It requires the pipeline to write to a protected branch, which means a bypass entry on the ruleset for an automated identity — a permission no human contributor to this repository has.      It also creates a trigger loop needing `[skip ci]`, a race between overlapping runs reading the same pom, and automated commits in the history.     
All three were hit in practice before the approach was
dropped.

**Why not B.** The pom stops stating anything true. A developer who clones the repository sees a placeholder, builds a placeholder jar, and has no way to know from the working tree what the current release is.      
The pom is the file every tool in the Java ecosystem treats as the project's identity.

**Why C works.** The pom is not pretending to be the version — it declares the series, which is exactly what it is authoritative about.       
`MAJOR` and `MINOR` are human decisions, edited by hand in the file that records decisions.      
`PATCH` is a mechanical count of releases, kept where releases are already recorded.      
Nothing writes to `main`, so no bypass, no loop, no race.

**The version still reaches the artifact.** It is passed to the build as `--build-arg APP_VER` and applied by `versions:set` *inside* the Dockerfile, after the dependency layer. The jar is therefore built from the real pom and `META-INF/maven/com.myapp/myapp/pom.properties` carries the released version.
Section 6 covers why the `ARG` sits where it does.

**Measured.** A build with a new version took **83.1s** under A and **20.1s**
under C. The difference is the `dependency:go-offline` layer, 61.8s, which stays
cached because the pom no longer changes between runs.

---

## 2. Understanding the Repository

This section answers task #2 of the exercise.

### 2.1 Which programming language is this?

Java. The project is built with Apache Maven and produces an executable `.jar`.


### 2.2 What is Java?

Java is an object-oriented, statically typed language that compiles to
**bytecode**. Bytecode is the abstraction layer between the source code and the
machine: it is not native machine code, but an instruction set for a virtual
machine. This is what makes the same compiled output run on any platform that
has a JVM.

**The compilation path**

Stage 1 — compilation. `javac App.java` turns Java source into bytecode,
producing one `.class` file per class under `target/classes`. No `.jar` exists
yet. the jar is created later, at Maven's `package` phase, by
`maven-jar-plugin`, which archives the `.class` files together with a
`META-INF/` directory.

Stage 2 — runtime. The JVM loads the bytecode, verifies it, and begins
interpreting it. When a method is executed repeatedly, the **JIT compiler** — a
component inside the JVM — compiles that "hot" method from bytecode into native
code and stores it in the code cache. The JVM's execution engine then runs
either through the interpreter or directly from the compiled native code.

This is why Java starts slow and speeds up, the first executions are
interpreted, and only after "warm-up" does performance approach C.

**The three components**

- **JVM** — the engine. Loads, verifies and executes bytecode, and manages
  garbage collection.
- **JRE** — the runtime environment. Contains the JVM plus the standard
  libraries.
- **JDK** — the development kit. Contains the JRE plus the tools needed to
  produce bytecode: `javac`, `jar`, `javadoc`, `jdb`.

The relationship is nested: JDK contains JRE, which contains JVM.

**Garbage collection and memory**

A Java application manages its own memory through the garbage collector, which
identifies objects that are no longer referenced and frees them. The heap size
is controlled by two flags:

- `-Xms` — the initial heap size
- `-Xmx` — the maximum heap size

When neither is set, the JVM sizes the heap from the memory it believes the
machine has — historically a quarter of physical RAM.

**Why this breaks in containers.** Before Java 10, the JVM read
`/proc/meminfo`, which reports the host's memory: cgroups limit what a process
may use, but there is no memory namespace hiding the host's real numbers. A
container limited to 512 MB could run a JVM that had sized its heap for a 64 GB
host, grow past the cgroup limit, and be killed by the kernel — `OOMKilled`, with no Java exception and no stack trace, because the process was
terminated from outside.

The fix is `-XX:+UseContainerSupport`, added in Java 10,
which makes the JVM read the cgroup limit instead. It is on by default in modern
JVMs, but the heap fraction still deserves to be explicit.




### 2.3 What is Maven?

Maven is an Apache tool that does two things: **dependency management** and
**build automation**. It targets JVM projects, primarily Java.

Its central idea is that it is **declarative**. You describe the project — what
it is, what version it is, what it depends on — and Maven derives the build
process from that description. It replaced Ant, which was imperative and
required you to script every build step yourself.

**Dependency management.** You declare which libraries you need and Maven
locates and downloads them, by default from a public repository (most commonly
Maven Central). While doing so it resolves **transitive dependencies**: if
library A needs B and C, Maven fetches B and C as well, without you declaring
them.

**Local caching.** Everything downloaded is cached under `~/.m2/repository`, so
the next build reuses it instead of downloading again.

**Convention over configuration.** All of this works because Maven relies on a
fixed directory layout:

- `src/main/java` — production code
- `src/main/resources` — configuration and resources
- `src/test/java` — test code
- `target/` — build output

`target/` never belongs in version control. It is regenerated on every build,
and that is the point: the source is the truth, the output is a derivative that
can always be rebuilt.

The flip side is that Maven is **opinionated**. A project that does not follow
the convention can still be built, but you will be fighting the tool.

**The three kinds of repository**

- **Local** — the `~/.m2` directory on your machine. A cache, Maven looks here
  first.
- **Central** — Apache's public repository. Anything not found locally comes
  from here.
- **Private / remote** — an organization's own repository, typically Nexus or
  JFrog Artifactory.

Organizations run a private repository for three reasons. First, **air-gapped
environments**: with no internet access there is no Maven Central, so the
internal repository acts as a mirror fed with approved libraries. Second,
**control and security**: only scanned and approved libraries get in, rather
than developers pulling arbitrary packages straight into production. Third,
**internal publishing**: libraries the organization builds itself are published
there for other projects to consume.

Crucially, this is configured in `~/.m2/settings.xml` — not in `pom.xml`. The
separation is deliberate: the pom lives in git and describes the *project*,
while settings describe the *environment*. Internal repository URLs and
credentials have no business sitting in a repository.

**Maven is a plugin framework**

Maven itself does almost nothing. It does not compile, does not run tests, does
not build jars. Every action is performed by a **plugin** that binds to a stage
of the process. What Maven does is orchestrate: decide which plugin runs when,
and feed it the configuration from the pom.

This explains what looks like magic — running a build in a fresh project with no
plugins declared still works, because Maven applies default plugin bindings from
a base POM built into the tool itself.



**What matters when running Maven in CI**

- **Caching.** The first build downloads a great deal, because `~/.m2` is empty.
  A CI runner starts clean on every run, so without caching this happens every
  build and adds minutes. In GitHub Actions this is one configuration line in
  the Java setup action.
- **Batch mode.** The default output prints progress bars that pollute logs and
  may wait for interactive input. The `-B` flag disables this and belongs in
  every CI invocation.
- **Determinism.** Every dependency and every plugin needs an explicit version.
  Otherwise the same build can produce different results at different times.

### 2.4 How does Maven work?

Maven's execution model is a **lifecycle**: a fixed, ordered sequence of stages
that every build passes through.

**Three lifecycles**

- `default` — the build itself
- `clean` — deletes the output directory
- `site` — generates project documentation (rarely used today)

They do not mix. Cleaning is a separate sequence and does not run automatically
before a build. If you want you ask for both in one command — which is why
`mvn clean package` is the combination you see in nearly every pipeline.

**Three concepts**

- **Phase** — a station in the sequence, such as `compile` or `package`. A phase
  does nothing by itself, it is a point in time.
- **Goal** — a concrete action performed by a plugin, such as "compile the
  sources" or "create the jar".
- **Binding** — the attachment between them: when you reach this phase, run this
  goal from this plugin.

The key principle: requesting a phase runs that phase and every phase before
it, in order. This is what makes Maven declarative rather than imperative —
asking for `package` also compiles and tests, without saying so.



**The phases that matter**

The `default` lifecycle has 23 phases, but only a handful are used day to day.
Most are empty anchor points that exist so plugins can attach at precise moments
— there are phases specifically before and after packaging for exactly that
purpose.

- **validate** — checks the project structure and that required information is
  present. Fast, and designed to fail early on anything fundamentally broken.
- **compile** — compiles production code from `src/main/java` into bytecode in
  `target/classes`. Test code is *not* compiled here, it has its own phase.
- **test** — runs unit tests, after compiling test sources separately into
  `target/test-classes`. This is the critical failure point: if a test fails the
  build stops, no jar is produced, and the pipeline fails. That is intentional —
  broken code should never become an artifact.
- **package** — takes the bytecode and packages it into the distribution format,
  here a jar, named from the artifactId and version.
- **verify** — runs integration tests and quality checks against the packaged
  artifact. Unit tests check an isolated component, this checks the finished
  product. Empty in a simple project, but this is where security scans and
  coverage gates belong in a serious pipeline.
- **install** — copies the jar into the local repository at `~/.m2`, so another
  project on the same machine can depend on it. That is its only purpose, it
  does not install anything into a real environment.
- **deploy** — uploads the jar to a remote repository, making it available
  across the organization.

**package vs install vs deploy.** All three produce the jar, the difference is
where it ends up. `package` leaves it in `target/`, usable by this project only.
`install` also copies it to the local `~/.m2`, usable by other projects on that
machine. `deploy` also uploads it to a remote repository, usable by everyone.

The practical rule: **if your artifact is a Docker image, stop at `package`.**
There is no reason to run `install` — you do not need the jar sitting in the
`.m2` of a temporary CI runner that will be destroyed a minute later. Running
`install` out of habit is a common pipeline mistake that lengthens builds for
nothing.

**Which plugin performs which phase**

- compilation — `maven-compiler-plugin`
- unit tests — `maven-surefire-plugin`
- packaging into a jar — `maven-jar-plugin`
- integration tests — `maven-failsafe-plugin`
- cleaning — `maven-clean-plugin`

These names are worth knowing: when a build fails, the failing plugin's name
appears in the log, which tells you immediately which phase you fell over in.

**Surefire vs Failsafe.** Surefire runs at the `test` phase, before packaging,
and executes unit tests, a failure stops everything immediately. Failsafe runs
after packaging and executes integration tests, and is deliberately designed
*not* to fail immediately — it records the failure and continues, so that a
cleanup step (shutting down a test server, deleting test data) can run before
the build is failed. Hence the name: fail *safe*, without leaving a mess behind.

### 2.5 What is pom.xml?

The Project Object Model — an XML file that describes the project: what it is,
what version it is, how it is built, and what it needs. It is generated when a
Java project is created, but from then on it is maintained by hand.

The central idea is that the project is described as an **object**, not as a
script. You state the desired state — version, dependencies, packaging — and the
build process is derived from it.

In this repository the pom is at `myapp/pom.xml` rather than the repository
root.

**GAV and packaging**

At the top of the file the project identifies itself:

- `groupId` — the organization, here `com.myapp`
- `artifactId` — the project name, here `myapp`
- `version` — the artifact version, following semantic versioning

Together these form a unique identifier for the artifact. `packaging` declares
what the build produces: `jar` for an application or library, `war` for a web
archive.

**dependencies and scope**

Each dependency is declared with its own GAV plus a `scope`. Scope controls two
things: in which phases the dependency is available, and whether it is packaged
into the final jar.

- `compile` (the default) — available everywhere, and packaged. Libraries the
  code calls directly.
- `test` — available only when compiling and running tests, not packaged. JUnit,
  for example.
- `provided` — available at compile and test time, not packaged, because the
  runtime environment supplies it. The Servlet API provided by Tomcat is the
  classic case.
- `runtime` — not available at compile time, available for tests and at runtime,
  and packaged. A JDBC driver, for example: the code compiles against the
  interface, and the implementation is only loaded when the program runs.

**build and plugins**

This section declares the plugins the build uses. Maven compiles nothing on its
own — `maven-compiler-plugin` compiles, `maven-surefire-plugin` runs tests,
`maven-jar-plugin` packages.

This is also where `mainClass` is configured, under the jar plugin's manifest
settings. It must be the fully-qualified class name — `com.myapp.App`, with
dots, not a file path — and it is what allows the jar to be launched with
`java -jar`.

**The jar itself**

A `.jar` is a ZIP archive containing the compiled `.class` files and a
`META-INF/` directory. The important file inside is `META-INF/MANIFEST.MF`,
whose `Main-Class` entry names the entry point. A jar without it is still a
valid archive — it simply cannot be run directly, which is a failure that only
surfaces at `docker run` time if you do not check for it.

The jar is the boundary between build time and runtime: everything before it is
the JDK's concern, everything after it belongs to the JRE.


## 3. Setup

### Prerequisites

JDK  17 
Maven  3.9+  
Docker  29.x  
kubectl  1.29+   
Helm  3.x  
minikube for Local cluster for the deployment step 

Helm 3.5 is the floor because of `--wait-for-jobs`, added in that release. A local cluster is optional: the pipeline creates its own kind cluster on the runner, so nothing here is needed to run CI.


### Fork & clone

```bash
git clone https://github.com/noamkux/maven-hello-world.git
cd maven-hello-world
```
### Docker Hub

Two public repositories: `noamkux/maven-hello-world` for releases, and `noamkux/maven-hello-world-ci` for dry runs (section 7).

Public was a deliberate choice, for two reasons: the pipeline's final step pulls and runs the image, which needs no authentication when the repository is public, and the Helm deployment needs no `imagePullSecret`. 
A private repository would have added an authentication step in both places for no benefit here.

### Credentials — secrets vs. variables

A docker personal access token was created to allow git hub to push a image
to the repo, after the token is issued save it in git hub as a secret.

The username is deliberately **not** a secret. GitHub masks secret values in
logs, so storing the username as one would render every image reference in the
build output as `***/maven-hello-world`, making the logs far harder to read.
Secrets are for values whose disclosure causes harm — not for everything that
happens to be involved in authentication.

A **personal access token** is used rather than an account password: its
permissions can be narrowed (Read & Write, not Delete) and it can be revoked
individually without touching the account.


### Workflow permissions

```yaml
permissions:
  contents: read
```

`GITHUB_TOKEN` is created for every run whether or not it is used, so the only question is what it may do. The block is declared rather than omitted: an absent block inherits the repository default from **Settings → Actions → General**, a setting that is not in git, is not reviewed, and does not travel with a fork.

`contents: read` is what `actions/checkout` needs and nothing more. The `tag` job re-declares `contents: write`, and a job-level block **replaces** the workflow-level one rather than adding to it, so that job has write on contents and nothing elsewhere, while everything in `build` (including every third-party action) stays read-only. Permissions exist at workflow and job level only, never per step, so splitting the tag into its own job is what makes this granularity possible.

### Branch protection

`main` is protected by a repository ruleset: pull requests required, force pushes and deletions blocked, and `pr-check` required as a status check. Required approvals is 0, because a single-contributor repository cannot satisfy a review requirement, and a rule that cannot be met is a rule that gets bypassed.

**The bypass list is empty, including for Actions.** Nothing in the pipeline writes to `main`. The only write is `git push origin "v$VERSION"`, which creates a ref outside the protected branch, so the automation is subject to the same rule as a human contributor.

## 4. Code Changes

### Update the pom.xml

1. Set the version to `1.0.0`

The fork ships as `<version>1.0-SNAPSHOT</version>`. In Maven, the `-SNAPSHOT`
suffix marks a version as still in development: Maven re-checks remote
repositories for a newer copy, when a release version is fetched once and
cached permanently. An automatic patch bump has no meaning on top of a SNAPSHOT,
which is why the exercise requires moving to `1.0.0` first.

```bash
cd myapp
mvn versions:set -DnewVersion=1.0.0 -DgenerateBackupPoms=false
```

`versions:set` rather than a hand edit — this is the same command the pipeline
runs, so running it locally first confirms it behaves correctly on this project
before it costs a CI cycle. `-DgenerateBackupPoms=false` suppresses the
`pom.xml.versionsBackup` file the plugin writes by default.

2. Change the compiler configuration in `pom.xml`:

```xml
<!-- from -->
<maven.compiler.source>1.7</maven.compiler.source>
<maven.compiler.target>1.7</maven.compiler.target>

<!-- to -->
<maven.compiler.release>17</maven.compiler.release>
```

**The mechanism.** `source` controls allowed syntax and `target` stamps the
bytecode version, but neither constrains the API — `javac` resolves method calls
against whichever JDK it runs inside. `release` resolves against the declared
version's real API.

**The level.** Raising 7 to 17 is a language-version decision that belongs to
developers, not the pipeline. It was raised here because `1.7` was never chosen —
it's the `maven-archetype-quickstart` default — and the code uses nothing past
Java 1.0. It also couldn't stay: `source`/`target` `1.7` were removed in JDK 20,
and `release 7` is rejected by JDK 17. Keeping Java 7 would mean pinning both base
images to JDK 11 — the right call with real Java 7 code, not with one `println`.

Pinning to JDK 11 would have cost more than its age suggests. Container
awareness gained cgroups v2 support only in 11.0.16 — and modern hosts and
clusters run v2, so an earlier build would fall back to reading host memory
inside a container. That is exactly the OOMKilled failure described in section
2.2, and it would make the `-XX:MaxRAMPercentage` setting in the Dockerfile
meaningless.

That is the general cost of pinning to an older runtime: not that the version is
old, but that using it correctly requires knowing which fixes landed in which
patch release, for every behaviour you depend on. None of those questions arise
on 17.

### .gitignore

Create a git ignore file and add the follwing :

 - target/ - the .jar output, shouldnt be in the repo
 - *.versionsBackup - the pom backup created by the versions plugins (safty net)
 - .vscode/ - vs code settings

### Change the App.java

Add my name to the App.java file as requested in the assigment

## 5 Local Build

Built the `.jar` file locally to check the app is built and runs correctliy
Use the follwing command to built, the -B flag runs the comand in batch mode 
which dosent ask for input from the user

```bash
mvn -B clean package
```
Check the name of the `.jar` file is as follow : `myapp-1.0.0.jar`
Use the follwing command to run the .jar file
```bash
java -jar myapp-1.0.0.jar
```
Check you get back the string `Hello World from Noam!`

## 6 Dockerfile

### Wrting the Dockerfile

Create a Dockerfile in the root of the maven-hello-world folder.

[Docker file](./Dockerfile)

`FROM maven:3.9.9-eclipse-temurin-17 AS build`     
Use an explicit maven version and name it as build for future multistage use

`WORKDIR /build`      
Create a workdir for the build named "build"

`COPY myapp/pom.xml .`
Copy the pom on its own. The pom never changes in CI (section 1), so this layer is a permanent cache hit and everything under it survives.

`RUN mvn -B -e -ntp dependency:go-offline`
Resolves and downloads the dependencies into the image. `-B` is batch mode (no progress bars, no interactive prompts), `-e` prints full stack traces on failure, `-ntp` hides the transfer log. This is the expensive layer, 61.8s cold, and keeping it cached is the reason the pom is copied separately.

The goal is not a guarantee of an offline build. It resolves declared dependencies and the plugins the lifecycle binds, but misses plugins invoked by hand. Verified: adding `-o` to the build fails on `versions-maven-plugin`, which this layer never fetched. It is a warm cache, not an offline guarantee.

`COPY myapp/src ./src`
The source, copied after the dependencies. This is the layer that actually changes between builds.

`ARG APP_VER=0.0.0`
The version, injected by the pipeline as `--build-arg APP_VER=1.0.18`.

**Its position is the point.** BuildKit treats an `ARG` declaration as a layer, so changing the value invalidates only what is below it. Declared at the top of the file, every version bump would invalidate the dependency download. Declared here, a new version rebuilds two cheap layers: 83.1s before, 20.1s after.

`RUN mvn -B -ntp versions:set -DnewVersion="$APP_VER" -DgenerateBackupPoms=false package`
Writes the version into the pom inside the image, then builds. Because the jar is packaged from the real pom, `pom.properties` carries the released version and the artifact does not misreport itself. `-DgenerateBackupPoms=false` suppresses the `pom.xml.versionsBackup` file the plugin writes by default.

No `clean`: the layer is created fresh on every run, so there is nothing to clean. `clean` is still correct locally, where `target/` persists between

`FROM eclipse-temurin:17.0.13_11-jre-alpine`      
The start of a new stage using the JRE Alpine image. This image will be the
runtime image for the app


`RUN addgroup -S -g 10001 app && adduser -S -u 10001 -G app app`
`-S` creates a system account — password locked, shell `/sbin/nologin`. `-u` and
`-g` set the IDs explicitly; without them `adduser` takes the first free ID from
100 upward, which depends on what the base image already contains and can move
on an update. `-G` puts the user in the group created on its left, which is why
the two commands are chained.


`WORKDIR /app`      
Create a new workdir for the runtime

`COPY --from=build --chown=10001:10001 /build/target/myapp-*.jar /app/app.jar`
Copy only the jar out of the build stage, leaving the JDK, Maven and `~/.m2` behind. The ownership is set numerically for the same reason `USER` is, below.

`USER 10001:10001`      
Use the user to the user we created in the previous command.
Also takes the numeric ID, not the name. Kubernetes reads the `User` field
from the image config before the container starts and cannot resolve a name -
that would mean running the image it is trying to check.With
`runAsNonRoot: true` set, a name-based `USER` fails the pod:

`ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-jar", "/app/app.jar"]`      
- java - use the JVM launcher to run this app.
- -XX:MaxRAMPercentage=75.0 - by default the JVM allows the program to use 25% of the container RAM for the heap.
In a situation of a single program that runs in a container this is a waste of memory, I have set the limit to
75% to use as much RAM as I can and still leave RAM for the other parts of the JVM
- -jar - tells the JVM to read the manifest and find there the Main-Class
- /app/app.jar - the path of the jar file



### Writing the .dockerignore file

Create a `.dockerignore` in the repository root:

```
.git
.github
**/target
README.md
.gitignore
.vscode
```

The build context is everything Docker sends to the daemon before the build
starts. Excluding `.git` matters most — usually the largest directory in the
repository, and nothing in the build reads from it. `**/target` keeps local build
output out of the context.

### Testing the Dockerfile

**cache test**

```bash
docker build -t maven-hello-world:1.0.0 .
```

The first build takes a few minutes. Run the same command again and it should
finish in seconds, with every step reported as `CACHED`.
***
**Change only to the source code**

Change the string the program prints and rebuild. Only the source and package
layers rerun, the pom and dependency layers stay cached.

```
=> CACHED [build 3/6] COPY myapp/pom.xml .
=> CACHED [build 4/6] RUN mvn -B -e dependency:go-offline
=> [build 5/6] COPY myapp/src ./src
=> [build 6/6] RUN mvn -B package
```
***
**Change the version**

```bash
docker build --build-arg APP_VER=1.0.1 -t maven-hello-world:1.0.1 .
```

```
=> CACHED [build 3/7] COPY myapp/pom.xml .
=> CACHED [build 4/7] RUN mvn -B -e -ntp dependency:go-offline
=> CACHED [build 5/7] COPY myapp/src ./src
=> [build 6/7] RUN mvn -B -ntp versions:set -DnewVersion="1.0.1" ... package
```

Only the build layer reruns. The dependency download stays cached because nothing above the `ARG` changed, which is the whole argument for where it sits.

```bash
docker run --rm --entrypoint id maven-hello-world:1.0.0
```
```bash
uid=10001(app) gid=10001(app) groups=10001(app)
```
***
**Check the image size**

```
docker images maven-hello-world:1.0.0
```

should return a size of 250 MB

## 7 Workflow

Two workflows, with different questions and different privileges.

| | `pr.yml` | `ci.yml` |
|---|---|---|
| Asks | is this fit to merge? | is this fit to publish? |
| Triggers on | `pull_request` to `main` | `push` to `main`, or manual dispatch |
| Computes a version | no | yes |
| Publishes | no | yes |

Section 8 covers `pr.yml`. This section is `ci.yml`.

[ci.yml](.github/workflows/ci.yml)

### Trigger

```yaml
on:
  push:
    branches: [main]
    paths-ignore:
      - "**.md"
      - ".gitignore"
  workflow_dispatch:
    inputs:
      dry_run:
        description: "Publish to the scratch repo and skip tagging"
        type: boolean
        default: true
```

Since `main` only accepts merges, `push` to `main` means "a pull request was merged". `paths-ignore` keeps a documentation edit from producing a release: a new version number should mean the artifact changed.

`workflow_dispatch` adds the dry run, covered at the end of this section.

**timeout-minutes: 20.** The default is 360, six hours of runner time before a hung `docker pull` or a stalled Maven download is cut off. A normal run finishes in 3 to 5 minutes.

### Concurrency

```yaml
concurrency:
  group: release-${{ github.ref }}
  cancel-in-progress: false
```

Two merges landing close together would otherwise run in parallel, read the same highest tag, and compute the same version. `cancel-in-progress: false` is the important half: the second run waits instead of replacing the first, because a run that is midway through publishing an image should finish and record its tag rather than be killed halfway.

### Job-level variables

```yaml
env:
  REPO: ${{ vars.DOCKERHUB_USERNAME }}/maven-hello-world${{ inputs.dry_run && '-ci' || '' }}
```

Declared once and used by every step that names the image.
The suffix is what routes a dry run to the scratch repository. On a `push` trigger `inputs.dry_run` does not exist, evaluates as falsy, and the expression yields the release repository.


### Checkout

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
    filter: tree:0
```

`runs-on: ubuntu-22.04` rather than `ubuntu-latest`, so a runner image update cannot change the build under you.

`fetch-depth: 0` fetches the full history, because the default shallow clone brings no tags and the version is computed from them.     
`filter: tree:0` makes it a blobless clone: all commits and all refs, none of the file contents, fetched lazily only if something asks for them. Nothing here does, since the version comes from ref names alone.

### Determine next version

Reads the series from the pom, finds the highest tag in it, and adds one. This step only calculates.

```bash
CURRENT=$(mvn -B -q -ntp help:evaluate -Dexpression=project.version -DforceStdout)

[[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "::error::unexpected version format: '$CURRENT' (expected X.Y.Z)"
  exit 1; }
```

`help:evaluate` rather than grepping the XML: this pom holds ten `<version>` elements and only one is the project's. It asks Maven for the effective version after inheritance and property resolution. `-q` silences the logs, `-DforceStdout` puts a clean value on stdout.

The guard exists because bash arithmetic does not fail on malformed input, it produces a wrong answer. An empty or non-numeric field evaluates as `0`, so `1.0` would yield a patch component that never existed and `1.0.0-SNAPSHOT` would silently become a release.

```bash
MAJOR=$(echo "$CURRENT" | cut -d. -f1)
MINOR=$(echo "$CURRENT" | cut -d. -f2)
LAST=$(git tag -l "v$MAJOR.$MINOR.*" --sort=-v:refname | head -n1)

if [ -z "$LAST" ]; then
  PATCH=0
  OLD="none"
else
  PATCH=$(( $(echo "$LAST" | cut -d. -f3) + 1 ))
  OLD="${LAST#v}"
fi

NEW="$MAJOR.$MINOR.$PATCH"
```

The glob restricts the search to the series the pom declares, so raising the pom to `2.0.0` starts a fresh count without touching the `v1.0.*` tags. `--sort=-v:refname` is a version sort, not a lexicographic one: the default ordering puts `v1.0.9` above `v1.0.17`. `${LAST#v}` strips the leading `v`.

`PATCH=0` when the series is empty, so `2.0.0` in the pom releases as `2.0.0`. Changing `MAJOR` or `MINOR` is a statement about which version this is, not a starting point for the next one.

```bash
git rev-parse "v$NEW" >/dev/null 2>&1 && {
  echo "::error::v$NEW already exists in git — version computation is broken"
  exit 1; }

for _ in $(seq 1 20); do
  docker manifest inspect "$REPO:$NEW" >/dev/null 2>&1 || break
  echo "::warning::$REPO:$NEW is already published but has no git tag — skipping"
  PATCH=$((PATCH + 1))
  NEW="$MAJOR.$MINOR.$PATCH"
done
```

Two guards against reusing a version number, deliberately behaving differently.

The first is impossible if the code is right: the tag was just derived as the highest plus one, so finding it already present means the computation is broken or someone changed the pom.xml version. It fails the run.

The second is a state the system can recover from. A run that published an image and then failed before tagging leaves a number that git does not know about, and the next run would compute it again and overwrite a published image. The loop detects that and moves forward. `git rev-parse` rather than `git tag -l` here, because it returns an exit code instead of matching text.

**The resulting gap in the tags is correct, not a defect.** Git records releases, not builds. A version that was published but never tagged is an artifact that never became a release, and its absence is the accurate record. The computation takes the maximum and adds one, so it never needs the sequence to be continuous.

```bash
echo "new=$NEW" >> "$GITHUB_OUTPUT"
echo "old=$OLD" >> "$GITHUB_OUTPUT"
```

`$GITHUB_OUTPUT` holds a path to a temporary file. At the end of the step the runner publishes each `key=value` line as an output of this step's `id`, reachable as `steps.version.outputs.new` and, through the job's `outputs:` block, as `needs.build.outputs.version` in the `tag` job.


### Set up Buildx

`docker/setup-buildx-action@v3` creates a `docker-container` builder. Docker already uses BuildKit by default, but the built-in `docker:default` builder cannot export or import a layer cache, so without this step `cache-to` and `cache-from` do nothing and every run rebuilds from scratch, making the layer ordering in the Dockerfile worthless in CI.


### Build image

```yaml
- uses: docker/build-push-action@v6
  with:
    context: .
    load: true
    push: false
    build-args: |
      APP_VER=${{ steps.version.outputs.new }}
    tags: ${{ env.REPO }}:${{ steps.version.outputs.new }}
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

`push: false` with `load: true`: the image is exported from the builder into the local Docker daemon and nothing leaves the runner. Everything that follows tests a real local image, and the push is a separate step later, so exactly the object that passed the checks is the one published.

Only the version tag is applied. `latest` is created at the end, after the deployment succeeds.

`mode=max` caches intermediate layers as well as those in the final image. With a multistage build the default `min` would cache nothing from the build stage, which is where all the expensive work happens.

### Smoke test

Two checks on the image, both about the Dockerfile rather than the application code.

```bash
docker run --rm "$IMAGE"

RUN_UID=$(docker run --rm --entrypoint id "$IMAGE" -u)
[ "$RUN_UID" != "0" ] || {
  echo "::error::container runs as root"; exit 1; }
```

The first verifies the entrypoint resolves and the process exits `0`. Actions runs each script with `set -e`, so a non-zero exit fails the step on its own.

The second checks the effective UID. `--entrypoint id` replaces the entrypoint for this run, and `-u` is passed as an argument to it. This asserts what the base image and `USER` actually produce, rather than trusting that the Dockerfile says what it means.

### Extract jar from image

```bash
CID=$(docker create "$IMAGE")
docker cp "$CID:/app/app.jar" "./$JAR"
docker rm "$CID"
```

`docker create` builds a container's filesystem without starting it, which is all that is needed to read a file out of it.

Taking the jar from the image rather than building it separately on the runner means the artifact is byte-identical to what runs in production. A second `mvn package` would produce a jar that was probably the same, which is a weaker claim.

### Upload jar artifact

`actions/upload-artifact@v4`, with `if-no-files-found: error` so a rename or a path change fails loudly instead of uploading nothing.

`retention-days: 14` overrides the 90-day default. The jar already exists as a layer in the published image, so this is a convenience for inspection rather than an archive.

### Push version tag

```bash
docker push "$REPO:$VERSION"
```

A plain `docker push` rather than a second call to `build-push-action`. The action would rebuild, and even with a full cache hit that is a weaker claim than pushing the exact object that just passed the smoke test. This pushes the same digest.

Only the version tag goes up here. `latest` waits.

### Pull from DockerHub

```bash
docker rmi "$REPO:$VERSION"
docker pull "$REPO:$VERSION"
docker run --rm "$REPO:$VERSION"
```

`docker rmi` first is what makes the pull real. Without it the daemon already holds the image, the pull is a no-op, and the step proves nothing. Removing it forces a genuine round trip through the registry, which verifies that what was published is complete and runnable.

This satisfies task 5.7 and is also the last check before anything is deployed.

### Create kind cluster

`helm/kind-action@v1` builds a Kubernetes cluster inside the runner.

**Why not minikube.** Deploying on my own machine proves the chart works on my machine. A cluster created inside the pipeline is evidence attached to the run, reproducible by anyone reading it. minikube would also not work here: the runner has no nested virtualisation, so its default driver has nothing to run on.

The cluster is created empty, which makes the deployment pull from Docker Hub by necessity rather than by configuration. No image is preloaded, so a successful deployment proves the published image is pullable and runnable by a third party.

### Deploy with Helm

```bash
RENDERED=$(helm template hello chart/ \
  --set image.repository="$REPO" \
  --set image.tag="$VERSION" \
  | grep -oP '^\s*image:\s*"?\K[^"]+')

[ "$RENDERED" = "$REPO:$VERSION" ] || {
  echo "::error::chart renders $RENDERED, expected $REPO:$VERSION"
  exit 1; }
```

The chart falls back to `appVersion` when no tag is given, which is the right default for a manual install and a silent failure in CI. A `--set` that does not arrive would deploy `1.0.0`, run successfully, and leave the pipeline green while having deployed the wrong version.

`helm template` renders locally in a second, before the cluster is involved, so the check runs on what will be sent rather than on what came back.

```bash
helm install hello chart/ \
  --set image.repository="$REPO" \
  --set image.tag="$VERSION" \
  --wait --wait-for-jobs --timeout 3m

kubectl logs job/hello
```

`--wait` alone is not enough. It waits for resources to become ready, and for a Job that means created, not finished. `--wait-for-jobs` (Helm 3.5+) waits for completion. Without it `kubectl logs` runs against a pod still in `ContainerCreating`.

`--set image.repository` is passed as well as the tag, so a dry run deploys from the scratch repository rather than from the one named in `values.yaml`.

### Promote latest

```bash
docker tag "$REPO:$VERSION" "$REPO:latest"
docker push "$REPO:latest"
```

`latest` is a moving tag that people pull without thinking. Publishing it alongside the version tag would mean a build that fails to deploy still becomes the default for everyone. Moving it here changes its meaning from "the last thing built" to "the last thing successfully deployed", which is what its users already assume it means.

A tag is a pointer, not a copy, so this push transfers no layers. The registry recognises every digest and writes a new manifest.

The image being tagged is the one pulled back from Docker Hub and deployed, since the local build was removed in the pull step.

### Tag the release

A separate job:

```yaml
tag:
  needs: build
  if: ${{ !inputs.dry_run }}
  permissions:
    contents: write
```

**Why a second job.** `contents: write` is the only elevated permission in the workflow, and permissions exist at workflow and job level only, never per step. In a single job it would apply to every third-party action in the run. Splitting it means `setup-java`, `buildx`, `login-action`, `build-push-action`, `upload-artifact` and `kind-action` all execute read-only, and write exists for four lines of git.

**Why not split further.** The flow is sequential, so `needs:` between dependent jobs does not parallelise anything, it serialises them and adds roughly 30 seconds of runner allocation per split. Each job also starts with an empty Docker daemon, so the image does not survive the boundary. Keeping build, test, publish and deploy in one job is what allows the smoke test, the jar extraction and the push to all operate on the same object.

**What the split costs.** About a minute of billable time, since GitHub rounds each job up, and a slightly wider window between `docker push` and `git tag`.

```bash
git tag "v$VERSION"
git push origin "v$VERSION"
```

Last, so a failure anywhere earlier leaves no release recorded. A failed tag push is a hard failure rather than `|| true`: a tag that already exists means something unexpected happened and the run should say so. `git tag -f` is not used, because a tag that moves is the mechanism behind the `tj-actions/changed-files` attack.

`v$VERSION` creates a ref under `refs/tags/`, outside the branch the ruleset protects, so this needs no bypass.

### Dry run

```yaml
workflow_dispatch:
  inputs:
    dry_run:
      type: boolean
      default: true
```

`ci.yml` cannot be exercised by a pull request without publishing, so the manual trigger runs the full path against a scratch registry instead. The `REPO` expression appends `-ci`, and the `tag` job is skipped. Everything else runs for real: version computation, build, smoke test, push, pull, kind deployment, promotion.

**Usage:** Actions → CI → Run workflow, select the branch under "Use workflow from", leave dry run checked.

**What stays untested:** the four lines of `git tag`. There is no reversible way to exercise them, which is a known limitation rather than an oversight.

## 8 PR check

[pr.yml](.github/workflows/pr.yml)

`ci.yml` asks whether a commit is fit to publish. `pr.yml` asks whether a branch is fit to merge. Only the first one publishes, and separating them is what allows every pull request to be built and deployed without producing a version.

It is registered in the ruleset as a required status check under the job name `pr-check`. GitHub matches required checks by job name, so renaming the job without updating the ruleset leaves the check permanently "expected" and blocks every pull request.

### What it does

```yaml
on:
  pull_request:
    branches: [main]

permissions: {}

concurrency:
  group: pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true
```

Lint the chart, build the image with `APP_VER=0.0.0-pr`, smoke test it, create a kind cluster, deploy. Same checks as `ci.yml`, same Dockerfile, same chart.

**What it does not do:** compute a version, push to Docker Hub, or create a tag. No `setup-java` either, since nothing here reads the pom.

`permissions: {}` at workflow level and `contents: read` on the job, which is all `actions/checkout` needs.

`cancel-in-progress: true`, the opposite of `ci.yml`. `pull_request` fires on `synchronize` as well as `opened`, so pushing another commit starts a new run. The previous one is now testing code nobody will merge, and killing it costs nothing because it publishes nothing. In `ci.yml` a cancelled run could leave a published image untagged, which is why that one waits instead.

### Loading the image without a registry

```bash
kind load docker-image "$IMAGE" --name pr
```

Moves the image from the runner's Docker daemon straight into the cluster's nodes, with no registry involved.

`ci.yml` deliberately does not do this: there, pulling from Docker Hub *is* the evidence, proving the published image is complete and reachable. In a pull request there is no published image and nothing to prove about the registry, so loading directly is both faster and the only option.

### Cache read-only

```yaml
cache-from: type=gha
```

No `cache-to`. Reads the cache `main` builds, writes nothing back. The layers produced here come from a different `APP_VER`, so they would never be a hit for a release build, and writing them would only consume the cache budget and evict layers that are useful.

## 9 Helm chart

### Workload

`Job`, not `Deployment`. The program prints a line and exits. A `Deployment` requires `restartPolicy: Always`, so Kubernetes would restart the container on a clean `exit 0`, again and again, and report `CrashLoopBackOff` for a program that never failed.

Rewriting the application to loop forever was rejected: that adapts the program to the tool instead of picking the right tool.


### Choosing which version to deploy

`values.yaml` holds an empty `image.tag`, and the template falls back to `appVersion` from `Chart.yaml` when none is given:

```yaml
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
```

Deploy the version the chart is built around:

```bash
helm install hello ./chart
```

Deploy any other published version, without editing a file:

```bash
helm install hello ./chart --set image.tag=1.0.7
```

`--set` sits at the top of Helm's value precedence, so it overrides both
`values.yaml` and the `appVersion` fallback.


Both mechanisms are kept on purpose. Without `appVersion`, `helm install ./chart`
with no flags would have no version to deploy at all, without `--set`, deploying a
different one would mean editing, committing and merging a file. Together the
chart has a sensible default that is recorded in git, and an escape hatch for
everything else.

### appVersion is not updated automatically

`appVersion` is a fixed `1.0.0`, and the pipeline never writes to it.

An earlier version updated it with `sed` alongside the pom and committed both. That mechanism is gone with the commit-back approach (section 1), and there is nothing left to update it: a `sed` on the runner would edit a file that is discarded when the job ends.

The pipeline passes `--set image.tag` at install time instead, which sits at the top of Helm's value precedence. `appVersion` remains the default for a manual `helm install ./chart` with no flags, and is raised by hand when `MAJOR` or `MINOR` moves in the pom.

### Deployment in the pipeline

Every run deploys, in a kind cluster created inside the runner:

```bash
helm install hello chart/ \
  --set image.repository="$REPO" \
  --set image.tag="$VERSION" \
  --wait --wait-for-jobs --timeout 3m
```

The cluster starts empty, so the image is pulled from Docker Hub rather than loaded locally, which makes the deployment a real test of what was published. `helm template` runs first as a guard, verifying the chart renders the expected image reference before anything is installed. Section 7 covers both.

### Folder structure

- `chart/Chart.yaml` — the chart's metadata: name, description, and the two
  versions it carries
- `chart/values.yaml` — the values injected into the templates
- `chart/templates/job.yaml` — the Job manifest that gets rendered and deployed

### chart/Chart.yaml

- `apiVersion: v2` - uses helm 3
- `name: maven-hello-world` - the chart name
- `description: Hello World Java app deployed as a Kubernetes Job` - the chart description
- `type: application` - chart type
- `version: 0.1.0` - the chart version, changes when the chart changes, not the app
- `appVersion: "1.0.0"` - the default app version, used only when no `--set image.tag` is given

### chart/Values.yaml

- `image: repository: noamkux/maven-hello-world` - points to the repo and image to be used
- `tag: ""` - empty by default the template falls back to Chart.AppVersion 

### chart/templates/job.yaml

- `kind: Job` - uses a job workload the reason for that is explaind in the workload part
- `name: {{ .Release.Name }}` - uses the name we gave in the install command as the name of the relase
- `ttlSecondsAfterFinished: 300` - delete the job 300 seconds after the job is done
- `restartPolicy: Never` - do not restart the pod after the job has ended. The other option is `OnFailure`, which is not compatible with this use case
- `image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"`      
{{ .Values.image.repository }} - uses the image.repostery name from the chart/Values.yaml file.         
{{ .Values.image.tag | default .Chart.AppVersion }} - takes the version either from the --set command in the cli or the values.yaml file if nither xsist takes it from Chart.yaml
