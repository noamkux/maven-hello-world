# maven-hello-world — CI/CD Pipeline

A Java/Maven "Hello World" application with a fully automated GitHub Actions
pipeline: automatic patch version bumping in pom.xml, multistage Docker build, non-root
runtime, Docker Hub publishing, and Kubernetes deployment via Helm.

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
merge PR to main
      |
      v
  read version from pom.xml  ->  bump patch  ->  versions:set
      |
      v
  multistage docker build  (pom already carries the new version)
      |
      v
  smoke test  (entrypoint + non-root)
      |
      +--> extract jar from image  ->  upload as build artifact
      |
      v
  push image to Docker Hub  (jar version + latest)
      |
      v
  pull the pushed image and run it
      |
      v
  commit the pom and tag the release  (v1.0.1)
```

The commit and tag are created last, after the image has been built, verified,
published, pulled and run. A failure anywhere earlier leaves the repository
untouched, so the version sequence has no gaps for builds that never produced an
image.

### Versioning Strategy

Two approaches were implemented during this project. The second replaced the
first, and was then reverted after a review raised a problem it did not solve.

**The requirement.** Task 5.2 sets the jar version to `1.0.0`, task 6.1
increases the patch part of *that* version automatically. They are one
requirement in two steps: a number that lives in the project and moves.

#### Option A — the version lives in pom.xml (chosen)

`mvn help:evaluate` reads the current version, the patch is incremented,
`mvn versions:set` writes it back, and the pipeline commits the modified pom and
tags the commit.

The version is read with `help:evaluate` rather than grepped out of the XML: this
pom contains ten `<version>` elements, most of them plugin versions, and
`help:evaluate` asks Maven for the effective project version after inheritance
and property resolution.

**For:**

- It is what the exercise asks for. The version is in the file, visible, and the
  mechanism is demonstrated by running the pipeline twice and reading one line.
- **A developer who clones the repository knows what version they have.** This is
  the argument that decided it. `mvn package` on a fresh clone produces
  `myapp-1.0.7.jar`, matching the published image. The IDE shows the real
  version, a consuming project resolves the right artifact, and tools that read
  the pom report accurately.

**Against, measured rather than assumed:**

- It invalidates the Docker layer cache every run. BuildKit hashes each layer
  against the result of the layers before it, so the dependency layer's key
  includes the output of `COPY myapp/pom.xml`. Rewriting one character changes
  that file's hash entirely and invalidates `dependency:go-offline` beneath it,
  re-downloading every Maven dependency.
- It requires writing to a protected branch — a bypass entry for
  `github-actions[bot]` on the ruleset.
- It creates a trigger loop, mitigated with `[skip ci]`.
- It leaves automated commits in the history.

#### Option B — the version lives in git tags

The pom holds `<version>${revision}</version>` defaulting to `0.0.0-SNAPSHOT`,
using Maven's CI-Friendly Versions mechanism. The pipeline reads the latest tag
with `git describe`, increments the patch, and injects the result as
`--build-arg REVISION` — declared in the Dockerfile *after* the dependency layer,
so a version change does not invalidate it.

This was fully implemented and measured:

| Build | Total | `dependency:go-offline` |
|---|---|---|
| First build, cold | 73.8s | 69.0s |
| Version-only change | **5.0s** | **CACHED** |

Under Option A the second build takes roughly 70 seconds again. Option B also
needs no write to the branch, no bypass, no trigger loop, and leaves no automated
commits — three concrete advantages against one.

**Why it was not kept:** the pom no longer states the real version. A developer
cloning the repository sees `0.0.0-SNAPSHOT`, builds `myapp-0.0.0-SNAPSHOT.jar`,
and has no way to know from the working tree that the current release is `1.0.7`.
Only `git tag -l` reveals it. The pom is accurate only inside the pipeline — the
one place nobody reads it.

That is not a presentation problem. The pom is the file every tool in the Java
ecosystem treats as the project's identity, and under Option B it is wrong on
every machine except the CI runner.

#### Reordering was considered and does not help

Building first and updating the pom only at the end keeps the pom stable *during*
a run — but the next run still sees a changed file, so the `COPY` layer breaks
anyway. Once the version lives in a file under version control, that layer changes
every release regardless of when in the pipeline it is written. It is a
consequence of the approach, not of the ordering.

#### The decision

Option A, accepting roughly 69 seconds of rebuild per run. The exercise asks for a
version in the project that increments, and a developer reading the repository
should see the same number the registry does. A faster pipeline that reports the
wrong version solves a different problem.

Git tags are still created, so the version has two synchronised representations:
the pom defines it, the tag records it in history.

The caching penalty is real but small at this scale, and it is a performance cost
rather than a correctness one. Section 12 covers how it would be removed where it
mattered.

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

### Fork & clone

```bash
git clone https://github.com/noamkux/maven-hello-world.git
cd maven-hello-world
```
### Docker Hub

A public repository at noamkux/maven-hello-world.

Public was a deliberate choice, for two reasons: the pipeline's final step pulls
and runs the image, which needs no authentication when the repository is public,
and the Helm deployment needs no `imagePullSecret`. A private repository would
have added an authentication step in both places for no benefit here.

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

Repository **Settings → Actions → General → Workflow permissions** is set to
**Read and write**, and the workflow additionally declares:

```yaml
permissions:
  contents: write
```

This is required so the pipeline can commit the version bump and push the release
tag. Declaring any permission explicitly also drops every other scope to `none`,
so the line narrows the token rather than merely describing it.

### Branch protection

`main` is protected by a repository ruleset: pull requests required, force pushes
blocked, deletions blocked. Required approvals is 0 — a single-contributor
repository cannot satisfy a review requirement, and a rule that cannot be met is
a rule that gets bypassed.

to let the runner push to the repo (tags and the updated pom file) i have
created a deploy key for the runner.
the deploy key is allowd to push to repo in the ruleset, the key itself is saved as a secret
in github and injected to the runner in the ci.yml file.

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
Copy only the pom.xml file, this file doesn't change as often
so this layer and the run command won't rerun
in every build, this will improve the performance of the build.

`RUN mvn -B -e dependency:go-offline`      
Use the -B flag to run in batch mode (no user input needed), -e shows the full error if there is any
dependency:go-offline uses the dependency plugin and sets the goal of go-offline.
This will allow downloading all the needed dependencies to a cache layer and improve the performance of the Dockerfile.

`COPY myapp/src ./src`       
Copy the source code, this separation is what makes the caching of the dependencies valuable,
because this layer can change frequently


`RUN mvn -B package`       
Use maven to package the app, maven will run until the package phase in the default lifecycle.

`FROM eclipse-temurin:17.0.13_11-jre-alpine`      
The start of a new stage using the JRE Alpine image. This image will be the
runtime image for the app

`RUN addgroup -S app && adduser -S -G app app`      
Create a non-root group and non-root user using the -S flag to create a system user/group.
This creates a user with a locked password, no home dir and a nologin shell

`WORKDIR /app`      
Create a new workdir for the runtime

`COPY --from=build --chown=app:app /build/target/myapp-*.jar /app/app.jar`      
Copy only the jar from the build stage, creating a smaller image and less attack surface

`USER app`      
Use the app user we created in the previous command

`ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-jar", "/app/app.jar"]`      
java - use the JVM launcher to run this app.
-XX:MaxRAMPercentage=75.0 - by default the JVM allows the program to use 25% of the container RAM for the heap.
In a situation of a single program that runs in a container this is a waste of memory, I have set the limit to
75% to use as much RAM as I can and still leave RAM for the other parts of the JVM
-jar - tells the JVM to read the manifest and find there the Main-Class
/app/app.jar - the path of the jar file



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
cd myapp && mvn versions:set -DnewVersion=1.0.1 -DgenerateBackupPoms=false && cd ..
docker build -t maven-hello-world:1.0.1 .
```

```
=> [build 3/6] COPY myapp/pom.xml .
=> [build 4/6] RUN mvn -B -e dependency:go-offline
```

**Note that both rebuild.** Changing the pom invalidates the `COPY` layer, and
everything below it goes with it — including the 69-second dependency download.
This is the measured cost of keeping the version in the pom, discussed in the
Versioning Strategy section above.

**Check the running user inside the continer is not root**

```bash
docker run --rm --entrypoint id maven-hello-world:1.0.0
```
```bash
uid=100(app) gid=101(app) groups=101(app)
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


**permissions :** this pipline gets permissions of write to the repo, it needs to push back the updated pom.xml and the new tag. also by declaring the permissions here we can implment POLP by giving a specific scope to the pipline (all the other premissions are none).

### Checkout

 - runs-on - settings the VM OS to ubuntu 22.04, usuing a specific version and not latest to ensure consistency
 - Checkout - uses the action : `actions/checkout@v4` which clones the repo to the runner.
 - Set up JDK 17 - uses `actions/setup-java@v4` with `distribution: temurin`, the
   same distribution as both Docker base images. The runner compiles nothing, but
   `help:evaluate` and `versions:set` run there and need Maven.

### Determine next version


- `CURRENT=$(mvn -B -q help:evaluate -Dexpression=project.version -DforceStdout)` —
  asks Maven for the effective project version. Not `grep`: this pom has ten
  `<version>` elements and only one of them is the project's. `-q` silences the
  logs and `-DforceStdout` forces a clean value to stdout.

```bash
MAJOR=$(echo "$CURRENT" | cut -d. -f1)
MINOR=$(echo "$CURRENT" | cut -d. -f2)
PATCH=$(echo "$CURRENT" | cut -d. -f3)
```

Breaks the version into three variables using `-d.` as the delimiter. `cut`
fields are numbered from 1.

- `NEW="$MAJOR.$MINOR.$((PATCH + 1))"` — increments the patch. `$(( ))` is bash
  arithmetic, distinct from `$( )` which runs a command.
- `sed -i "s/^appVersion:.*/appVersion: \"$NEW\"/" ../chart/Chart.yaml` - 
  update the version to the helm chart, explaind in the helm section.
- `mvn -B versions:set -DnewVersion="$NEW" -DgenerateBackupPoms=false` — writes
  the new version into the pom on the runner. The Docker build that follows picks
  it up automatically, since `COPY myapp/pom.xml` copies the modified file.
- `echo "version=$NEW" >> "$GITHUB_OUTPUT"` — writes the value to
  `$GITHUB_OUTPUT`, an env variable holding a path to a temp file. At the end of
  the step the runner publishes each `key=value` line as an output of this step's
  `id`, reachable as `steps.version.outputs.version`.
- `echo "Bumped $CURRENT -> $NEW"` — logging.

**Known limitation:** this assumes the version is strictly `X.Y.Z`. A version
like `1.0` leaves `PATCH` empty and the arithmetic fails.

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
- tags: `${{ vars.DOCKERHUB_USERNAME }}/maven-hello-world:${{ steps.version.outputs.version }}` - tags the image with the correct version, same as above we got the version from the Determine next version phase
- `${{ vars.DOCKERHUB_USERNAME }}/maven-hello-world:latest` a second tag named latest.
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

- `IMAGE="${{ vars.DOCKERHUB_USERNAME }}/maven-hello-world:${{ steps.version.outputs.version }}"` - save the image name as a varibale named IMAGE, 
- `docker create "$IMAGE"` - uses the same image we just build and create a continar with this image, use docker create and not run because we dont need to run the continar we only need to acsses its FS to grab the jar file
- `docker cp "$CID:/app/app.jar" "./myapp-${{ steps.version.outputs.version }}.jar"` - use docker cp to copy the image from the conatiner FS to the local FS of the runner
- `docker rm "$CID"` - delete the container 
- `ls -lh ./myapp-*.jar` to check the file is present

### Upload jar artifact

- `actions/upload-artifact@v4` upload an artifact to git hub, enable to download the artifact directly from github for inspection.

### Push to Docker hub

use basic shell command to push the image to docker hub with the two tags, one with the jar version and one with latest.

### Pull and run

- use `docker rmi "$IMAGE" || true` delete the image if exsist in the local FS, ensure consistency for the testing.
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
- `[skip ci]` breaks the trigger loop. It is technically redundant, since commits
  pushed with the default `GITHUB_TOKEN` do not trigger workflows — but that
  protection is invisible in the file and disappears the moment someone swaps in a
  PAT, which is exactly what people do when they want the bump commit to trigger
  something.
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
