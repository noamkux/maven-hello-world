# maven-hello-world — CI/CD Pipeline

A Java/Maven "Hello World" application with a fully automated GitHub Actions
pipeline: automatic patch version bumping, multistage Docker build, non-root
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
push to master
      |
      v
  bump patch version in pom.xml  ->  commit back [skip ci]
      |
      v
  multistage docker build  (compile + test + package inside the image)
      |
      +--> extract jar from image  ->  upload as build artifact
      |
      v
  push image to Docker Hub  (tagged with the jar version + latest)
      |
      v
  pull the pushed image and run it
```

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
JVMs, but the heap fraction still deserves to be explicit — this project sets
`-XX:MaxRAMPercentage` rather than relying on defaults.




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

- **Local** — the `~/.m2` directory on your machine. A cache; Maven looks here
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
  does nothing by itself; it is a point in time.
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
  `target/classes`. Test code is *not* compiled here; it has its own phase.
- **test** — runs unit tests, after compiling test sources separately into
  `target/test-classes`. This is the critical failure point: if a test fails the
  build stops, no jar is produced, and the pipeline fails. That is intentional —
  broken code should never become an artifact.
- **package** — takes the bytecode and packages it into the distribution format,
  here a jar, named from the artifactId and version.
- **verify** — runs integration tests and quality checks against the packaged
  artifact. Unit tests check an isolated component; this checks the finished
  product. Empty in a simple project, but this is where security scans and
  coverage gates belong in a serious pipeline.
- **install** — copies the jar into the local repository at `~/.m2`, so another
  project on the same machine can depend on it. That is its only purpose; it
  does not install anything into a real environment.
- **deploy** — uploads the jar to a remote repository, making it available
  across the organization.

**package vs install vs deploy.** All three produce the jar; the difference is
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
and executes unit tests; a failure stops everything immediately. Failsafe runs
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
and runs the image, which needs no authentication when the repository is public;
and the Helm deployment needs no `imagePullSecret`. A private repository would
have added an authentication step in both places for no benefit here.

### Credentials — secrets vs. variables

A docker personal access token was created to allow git lab to push a image
to the repo, after the token is issued save it in git lab as a secret.

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

### Update the pom.xml file

1. Change the version field in the pom.xml file, currently it states `<version>1.0-SNAPSHOT</version>`,
which is used for an applications which is still in development, change it usuing the commadn
```bash
cd ~/github/maven-hello-world/myapp
mvn versions:set -DnewVersion=1.0.0 -DgenerateBackupPoms=false
```

`-DgenerateBackupPoms=false` - by defualt maven create a backup of the pom file in evrey chngae
not nessecry here

2. Change the following lines in the pom.xml file, this will make the compiler run as a JDK 17 version.
using the source and target attributes in the pom file will enforce the usage of an allowed syntax in a specific
java version and add the proper label to the byte code, but doesn't enforce building with the correct JDK.
changing these to the release attribute also enforces the API of the declared version, so code cannot compile
against a method that doesn't exist in it.

from :
```XML
<maven.compiler.source>1.7</maven.compiler.source>
<maven.compiler.target>1.7</maven.compiler.target>
```

to :
```XML
<maven.compiler.release>17</maven.compiler.release>
```

### .gitignore

Create a git ignore file and add the follwing :

 - target/ - the .jar output, shouldnt be in the repo
 - *.versionsBackup - the pom backup created by the versions plugins (safty net)
 - .vscode/ - vs code settings
