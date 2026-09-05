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

Create a ci.yml file.

[ci.yml](/maven-hello-world/.github/workflows/ci.yml)

```bash
cd ~/github/maven-hello-world
mkdir -p .github/workflows
cd .github/workflows
touch ci.yml
```

### Trigger & Permissions

**trigger :** The pipline will triger only on push to the main branch and on manual dispatch.


**permissions :** `permissions: {}` — no scopes at all. `GITHUB_TOKEN` is
created for every run regardless of whether it is used, so the empty block is
what reduces it to `none` everywhere. The pipeline pushes over SSH with a deploy
key and never touches the token. Full reasoning in section 3.

**timeout-minutes :** `20`. The default is 360 — six hours of runner time
before a hung `docker pull` or a stalled Maven download is cut off. A normal run
finishes in 3–5 minutes, so this leaves room without being theoretical.

### Job-level variables

`REPO` is declared once in the job's `env` block and used by every step that
references the image:

```yaml
env:
    REPO: ${{ vars.DOCKERHUB_USERNAME }}/maven-hello-world
```

The `env` context is available both in `with:` blocks and in shell steps, so one
declaration covers the build action and the scripts alike. `VERSION` cannot live
there — the `steps` context does not exist at job level, since step outputs are
produced during the run — so it is declared per step instead.

### Checkout

 - runs-on - settings the VM OS to ubuntu 22.04, usuing a specific version and not latest to ensure consistency
 - Checkout - uses the action : `actions/checkout@v4` which clones the repo to the runner.
 - Set up JDK 17 - uses `actions/setup-java@v4` with `distribution: temurin`, the
   same distribution as both Docker base images. The runner compiles nothing, but
   `help:evaluate` and `versions:set` run there and need Maven.

### Determine next version

Reads the current version, validates it, and computes the next one. This step
only calculates — nothing is written here.

- `CURRENT=$(mvn -B -q help:evaluate -Dexpression=project.version -DforceStdout)` —
  asks Maven for the effective project version. Not `grep`: this pom has ten
  `<version>` elements and only one of them is the project's. `-q` silences the
  logs and `-DforceStdout` forces a clean value to stdout.

- The format is validated before anything is parsed:

```bash
[[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "::error::unexpected version format: '$CURRENT' (expected X.Y.Z)"
  exit 1; }
```

  Without this guard the arithmetic below does not fail on malformed input, it
  produces a wrong answer. Bash evaluates an empty or non-numeric variable as `0`
  in arithmetic context, so `1.0` yields `1.0.1` with a patch component that
  never existed, and `1.0.0-SNAPSHOT` yields `1.0.1` — silently turning a
  development version into a release.


- Once the guard passes, `CURRENT` is known to be three numeric fields, so the
  split and the increment are operating on a validated string:

```bash
MAJOR=$(echo "$CURRENT" | cut -d. -f1)
MINOR=$(echo "$CURRENT" | cut -d. -f2)
PATCH=$(echo "$CURRENT" | cut -d. -f3)
NEW="$MAJOR.$MINOR.$((PATCH + 1))"
```

  `-d.` sets the delimiter, `cut` fields are numbered from 1. 

- Both values are published as step outputs:

```bash
echo "new=$NEW" >> "$GITHUB_OUTPUT"
echo "old=$CURRENT" >> "$GITHUB_OUTPUT"
```

  `$GITHUB_OUTPUT` is an environment variable holding a path to a temp file. At
  the end of the step the runner publishes each `key=value` line as an output of
  this step's `id`, reachable as `steps.version.outputs.new`.


### Bump pom.xml

```bash
mvn -B versions:set -DnewVersion="$NEW" -DgenerateBackupPoms=false
```

Writes the new version into the pom on the runner. The Docker build that follows
picks it up automatically, since `COPY myapp/pom.xml` copies the modified file.

`-DgenerateBackupPoms=false` suppresses the `pom.xml.versionsBackup` file the
plugin writes by default. On a runner the working tree is discarded when the job
ends, and the backup would otherwise have to be excluded from the commit.

### Bump helm chart

The chart carries the application version in its own metadata, so the same value
has to reach two files. `Chart.yaml` is plain YAML with no build tool behind it,
so this is a text substitution:

```bash
sed -i "s/^appVersion:.*/appVersion: \"$NEW\"/" chart/Chart.yaml
grep -q "^appVersion: \"$NEW\"$" chart/Chart.yaml || {
  echo "::error::failed to update appVersion in chart/Chart.yaml"
  exit 1; }
```

`sed` exits `0` whether or not the pattern matched anything — for a stream
editor, finding nothing to replace is a valid outcome, not an error. Any change
to how the field is written in `Chart.yaml`, such as indentation or a space
before the colon, would stop the pattern matching. The run would then finish
green with the chart still on an old version, and `git add` would find nothing
to stage, so the commit would succeed too. The mismatch would surface only when
someone ran `helm install` and got an image they did not expect.

The exit code of `sed` carries no information here because `sed` exits `0` 
whether or not the pattern matched anything, so the assertion cant happend here.
To check that the change to the chart was acctualy made grep is used to find 
the correct line, if not exsisting it will fail the pipeline.

### Buildx

Use the docker/setup-buildx-action@v3 to install buildx, the main reason for using buildx is
that it creates a `docker-container` builder, which can export and import its layer cache.
Docker already uses BuildKit by default, but the built-in `docker:default` builder cannot do
that — so without this step `cache-to` and `cache-from` fail and every CI run rebuilds from
scratch, making the layer ordering in the Dockerfile worthless in the pipeline.

### Docker login

Use the docker/login-action@v3 to allow communication with docker hub, inject the user name and password from github vars/sercrets (i have enterd those value at step "3 Setup"), it preform a docker login and write the credentials to `~/docker/.config.json`. 

### Build the image

uses the docker/build-push-action@v6 with the follwing arguments
- push: `false` - after the image is built dont push it to the registry, we want to test first and the push
- load: `true` - import the image from the builder continer to the docker daemon
- tags: `${{ env.REPO }}:${{ steps.version.outputs.version }}` - tags the image with the correct version, same as above we got the version from the Determine next version phase
- `${{ env.REPO }}:latest` a second tag named latest.
- cache-from: `type=gha` use the cache that is stored at git hub action cache a service that allows to store data outside the VM and call it for futere use, this is what makes our build faster with the usage of caching
- cache-to: `type=gha,mode=max` - where to cache the data, its the other side of the same coin, the `mode=max` arg tells github to store layers that are not present in the final image 

### Smoke test

decided to make two checks before uploading the image and the artifact, this check are relvent to the code i wrote in the docker file and not the code the developer wrote

**entrypoint check** - make sure the entry point in the docker file works and dosent return a status code diffrent the 0. it works because github action runs each script with the set -e command which drops the whole pipline if an exit code return a diffrent value then 0
`docker run --rm "$IMAGE"`


**non root user** - run the continer and ask for the user id back, ensure the user is not root

```bash
RUN_UID=$(docker run --rm --entrypoint id "$IMAGE" -u)
echo "Running as UID: $RUN_UID"
[ "$RUN_UID" != "0" ] || {
  echo "::error::container runs as root", exit 1, }
```

### Extract jar from image

- `IMAGE="${{ env.REPO }}:${{ steps.version.outputs.version }}"` - save the image name as a varibale named IMAGE, 
- `docker create "$IMAGE"` - uses the same image we just build and create a continar with this image, use docker create and not run because we dont need to run the continar we only need to acsses its FS to grab the jar file
- `docker cp "$CID:/app/app.jar" "./myapp-${{ steps.version.outputs.version }}.jar"` - use docker cp to copy the image from the conatiner FS to the local FS of the runner
- `docker rm "$CID"` - delete the container 
- `ls -lh ./myapp-*.jar` to check the file is present

### Upload jar artifact

- `actions/upload-artifact@v4` upload an artifact to git hub, enable to download the artifact directly from github for inspection.

- `retention-days: 14` overrides the 90-day default. The jar already exists as a
layer in the published image, so this artifact is a convenience for manual
inspection rather than an archive, and does not need to outlive the interest in
a given run.

### Push to Docker hub

use basic shell command to push the image to docker hub with the two tags, one with the jar version and one with latest.

### Pull and run

- use `docker rmi "$IMAGE"` delete the image if exsist in the local FS, ensure consistency for the testing.
- `docker pull "$IMAGE"` pull the newly created image from docker hub for testing

- `OUTPUT=$(docker run --rm "$IMAGE")` - run the contianer and save the output to a varibale named OUTPUT to print to screen later
- `echo "$OUTPUT"` - print the result of the docker run

### Commit and tag the release

The last step, so a failure anywhere earlier leaves the repository untouched.

```bash
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add myapp/pom.xml chart/Chart.yaml
git commit -m "chore: bump version to <version> [skip ci]"
git tag "v<version>"
git push origin HEAD:main
git push origin "v<version>"
```

- The email with the numeric prefix is the official user ID of
  `github-actions[bot]`, using it makes GitHub attribute the commit correctly.
- `git add myapp/pom.xml chart/Chart.yaml` rather than `git add .` — adds the pom.xml file and the Chart.yaml file to the commit because thy are the only one that have been changed.
- `[skip ci]` breaks the trigger loop, and here it is the only thing that does.
  The rule that commits pushed with the default `GITHUB_TOKEN` do not trigger
  workflows applies to that token alone — this push is made over SSH with a
  deploy key, which GitHub treats as an ordinary push. Without `[skip ci]` the
  bump commit would trigger the workflow, which would bump, commit and trigger
  again.
- `git push origin HEAD:main` rather than `git push` — the Actions checkout is in
  detached HEAD state, so the target must be named explicitly.


## 8 Helm chart

### workload
I have used a job workload becuase this program dosent run in a infinite loop, if i will used deployment Kubernetes will restart the continer after the program exists (Deployment restartPolicy have to be always) eventually this will caused a CrashLoopBackOff. 

### Choosing which version to deploy

The version is set as `appVersion` in `Chart.yaml`, and `values.yaml` holds an
empty `image.tag`. The template uses the tag when one is given and falls back to
`appVersion` when it isn't:

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

### Chart version bump

The pipeline updates `appVersion` alongside the pom version on every release, so
the chart's default always points at the most recent published image rather than
drifting behind it.
- Updating the chart thru the pipline is possible by taking the new app version and adding it to the Chart.yaml file           
`sed -i "s/^appVersion:.*/appVersion: \"$NEW\"/" ../chart/Chart.yaml`        
- Then the change is commited to git with the pom.xml file       
`git add myapp/pom.xml chart/Chart.yaml`

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
- `version: 0.1.0` - the chart version, changes when we change the chart not the app.
- `appVersion: "1.0.2"` - the app version that runs inside the cluster

### chart/Values.yaml

- `image: repository: noamkux/maven-hello-world` - points to the repo and image to be used
- `tag: ""` - empty by default the template falls back to Chart.AppVersion 

### chart/templates/job.yaml

- `kind: Job` - uses a job workload the reason for that is explaind in the workload part
- `name: {{ .Release.Name }}` - uses the name we gave in the install command as the name of the relase
- `ttlSecondsAfterFinished: 300` - delete the job 300 seconds after the job is done
- `restartPolicy: Never` - done try to reload the pod after the job has ended (the other optin is OnFailure and is not comptabile with the use case here)
- `image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"`      
{{ .Values.image.repository }} - uses the image.repostery name from the chart/Values.yaml file.         
{{ .Values.image.tag | default .Chart.AppVersion }} - takes the version either from the --set command in the cli or the values.yaml file if nither xsist takes it from Chart.yaml
