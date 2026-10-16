# Following our dependencies' security

Last verified: 2026-10-16.

Question (ticket [#8](https://github.com/Holo-Org/R-Type/issues/8)): what can monitor the Zig toolchain, raylib-zig and raylib for vulnerabilities over time, and what is the cheapest monitoring that the comparative study can describe and the repository can actually run?

Short answer: **no GitHub or Renovate feature reads `build.zig.zon`, and no advisory database covers Zig.** The one tool that can match our pinned dependencies against known vulnerabilities is OSV, through commit hashes, and it works today for raylib and raylib-zig. For the Zig toolchain, nothing automatic exists: it comes down to reading Zig's release notes. The recommended setup is at the end; it takes well under an hour.

Every fact links to its source. Lines marked **Assessment** or **Inference** are judgement, not fact. Anything I could not establish is marked "unknown" or "not verified". GitHub's documentation was read from its public source repository ([github/docs at ff759d8](https://github.com/github/docs/tree/ff759d8d323d8794ce98d1dedd758356e2940a84), 2026-10-16); the rendered pages on docs.github.com carry the same text.

## What we depend on

| Dependency | How it reaches us | Pinned by | Notes |
| --- | --- | --- | --- |
| raylib-zig | `.raylib_zig` in our `build.zig.zon` | commit [8758f4c](https://github.com/raylib-zig/raylib-zig/commit/8758f4cd3a5ae0df6941c4715257223d34c5ad3e) (2026-07-18) on `devel` | No GitHub release exists, and its newest tag is `v5.6-dev` ([releases](https://github.com/raylib-zig/raylib-zig/releases), [tags](https://github.com/raylib-zig/raylib-zig/tags)). |
| raylib | transitive, through raylib-zig's own `build.zig.zon` | tag `6.0` (commit [dbc56a8](https://github.com/raysan5/raylib/commit/dbc56a87da87d973a9c5baa4e7438a9d20121d28)), per [raylib-zig at 8758f4c](https://github.com/raylib-zig/raylib-zig/blob/8758f4cd3a5ae0df6941c4715257223d34c5ad3e/build.zig.zon) | raylib 6.2 was released on 2026-10-15 ([releases](https://github.com/raysan5/raylib/releases)). |
| GLFW 3.4, miniaudio 0.11.24, stb_image 2.30 and others | source copies inside raylib's `src/external` | raylib 6.0 | Version strings read from the headers at tag [6.0](https://github.com/raysan5/raylib/tree/6.0/src/external). Not separate entries in any manifest. |
| emsdk, zemscripten | raylib's and raylib-zig's `build.zig.zon` | their own commits | Not marked `lazy` in [raylib 6.0's manifest](https://github.com/raysan5/raylib/blob/6.0/build.zig.zon), so **inference**: Zig fetches them even for a desktop build. They are not linked into our programs. |
| Zig toolchain 0.16.0 | `mlugg/setup-zig` on CI, ziglang.org archives, nixpkgs | `minimum_zig_version` | 0.17.0 was released on 2026-10-01 ([download index](https://ziglang.org/download/index.json)). |
| GitHub Actions | `uses:` lines in the workflows | tag or commit | `mlugg/setup-zig` (latest [v2.2.1](https://github.com/mlugg/setup-zig/releases)), `renman-ymd/jj-ci@v1`, and whatever else we add. |

Per [ADR 0001](../adr/0001-engine-game-boundary.md), the Server links only the headless part of the Engine, so raylib reaches the Client only. The Server's exposure to hostile packets comes from our own code and Zig's standard library, which is part of the toolchain.

**Assessment**: the highest-value target is the Client's raylib (image, font and audio decoding of files we ship, plus the vendored decoders). Our Client does not load files from the network, which lowers its exposure, but I have not audited that.

## 1. GitHub dependency graph and Dependabot

### Dependency graph

- The dependency graph reads a fixed list of manifest files. The list covers Bazel, Cargo, Composer, Deno, NuGet, GitHub Actions workflows, Go, Gradle, Julia, Maven, npm, OpenTofu, pip, pnpm, pub, Poetry, RubyGems, Swift and Yarn ([supported ecosystems](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/code-security/reference/supply-chain-security/dependency-graph-supported-package-ecosystems.md)). **`build.zig.zon` and Zig are not in it**, and neither is C or C++.
- GitHub Actions workflows are: files in `.github/workflows/` are parsed, and every `jobs[*].steps[*].uses` and `jobs.<job_id>.uses` becomes a dependency (same page).
- The graph is on by default for public repositories ([gating note](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/data/reusables/gated-features/dependency-graph.md)).

### Dependabot alerts

- Dependabot alerts are available for organisation-owned and user-owned repositories ([gating note](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/data/reusables/gated-features/dependabot-alerts.md)). Repository administrators and organisation owners can enable them ([Dependabot alerts](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/code-security/concepts/supply-chain-security/dependabot-alerts.md)).
- An alert fires when a dependency in the graph matches an advisory in the GitHub Advisory Database. Alerts for Actions are generated only for actions that use semantic versioning, not SHA pins ([reusable note](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/data/reusables/dependabot/dependabot-alert-actions-semver.md)).
- Notifications go by default to people with write, maintain or admin permission on the repository ([notifications](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/code-security/how-tos/secure-your-supply-chain/manage-your-dependency-security/configure-dependabot-notifications.md)).

### Dependabot version updates

- Supported ecosystems include `github-actions`, `gitsubmodule`, `nix` (it watches `flake.lock`), `cargo`, `npm` and others. **Zig is not in the table** ([supported ecosystems](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/data/reusables/dependabot/supported-package-managers.md)). Version updates and security updates are both supported for `github-actions`.
- For `github-actions`, `directory: "/"` makes Dependabot search `.github/workflows` and the root `action.yml` ([options reference](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/code-security/reference/supply-chain-security/dependabot-options-reference.md)).
- It updates actions referenced as `owner/repo@tag` or `owner/repo@commit`, and refreshes a trailing `# tag` comment on the same line. It ignores local actions and `docker://` references ([caveats](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/data/reusables/actions/dependabot-version-updates-actions-caveats.md)).
- Version updates are available for all repositories on GitHub ([gating note](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/data/reusables/gated-features/dependabot-version-updates.md)).

### GitHub Advisory Database

- It reviews advisories only for packages that come from one of these registries: Composer, Erlang (Hex), Go, GitHub Actions, Maven, npm, NuGet, pip, pub, RubyGems, Rust (crates.io) and Swift ([Advisory Database](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/code-security/concepts/vulnerability-reporting-and-management/github-advisory-database.md)). **No Zig, no C or C++.**
- Dependabot creates no alerts for unreviewed advisories (same page).
- The REST API's `ecosystem` filter has the same list plus `other` ([REST description 1.1.4](https://github.com/github/rest-api-description/blob/51a4657888cc1db93d8bd68086d117909fd8221c/descriptions/api.github.com/api.github.com.2022-11-28.json)).
- I queried the global advisories for `ecosystem=actions` on `mlugg/setup-zig`, `renman-ymd/jj-ci` and `actions/checkout`, with `gh api advisories`: **none returned today**. The ecosystem itself has advisories, so the pipeline works.

**Assessment**: Dependabot is worth switching on for the workflows (cheap, covers the actions we trust with CI), and useless for the Zig dependencies.

## 2. Dependency submission API

- The API takes a snapshot of dependencies that static analysis cannot see. Submitted dependencies show up in the dependency graph, next to the ones found in manifests ([REST docs](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/rest/dependency-graph/dependency-submission.md)).
- A workflow can write its own submission, using the [Dependency Submission Toolkit](https://github.com/github/dependency-submission-toolkit) or the raw endpoint ([how-to](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/use-dependency-submission-api.md)). The example workflow there grants `contents: write`.
- Each dependency is identified by a package URL (purl): the schema's `package_url` must match `^pkg` ([REST description](https://github.com/github/rest-api-description/blob/51a4657888cc1db93d8bd68086d117909fd8221c/descriptions/api.github.com/api.github.com.2022-11-28.json)). The purl specification has a [`github` type](https://github.com/package-url/purl-spec/blob/c1dc0979f7b10d00e9ab002b1111638761ab1fc1/types/github-definition.json) whose version is "commit or tag", for example `pkg:github/raysan5/raylib@dbc56a87da87d973a9c5baa4e7438a9d20121d28`, and a [`generic` type](https://github.com/package-url/purl-spec/blob/c1dc0979f7b10d00e9ab002b1111638761ab1fc1/types/generic-definition.json). So a small workflow could submit our pins.
- The decisive sentence: "You will only get Dependabot alerts for dependencies that are from one of the supported ecosystems for the GitHub Advisory Database" ([REST docs](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/rest/dependency-graph/dependency-submission.md)). The Advisory Database list above has no Zig and no C or C++, and no `github` or `generic` purl type.
- **Inference, not tested** (testing means writing a snapshot to GitHub, which this research did not do): a submitted `pkg:github/...` entry would appear in the graph as an inventory, and **no Dependabot alert would ever fire for it**. The graph would then be a list of what we pin and nothing more. Building and running a submission workflow is therefore effort without a monitoring benefit.

## 3. OSV

### Ecosystems

- The OSV schema defines no Zig ecosystem. The defined ecosystems include `crates.io`, `Go`, `npm`, `PyPI`, `GitHub Actions`, `ConanCenter`, `vcpkg` and others ([OSV schema, defined ecosystems](https://github.com/ossf/osv-schema/blob/e1cced93dffbbb82f664ee3cb0f2bf90144c037a/docs/schema.md)). For software with no package ecosystem, the schema's pseudo-ecosystem is `GIT`: ranges of commits (`introduced`, `fixed`) in a repository, with an enumerated `versions` list of tags (same page).
- Where the commit ranges come from: OSV added them to more than 30,000 advisories derived from the NVD, using algorithms that match tags to the patch information in the CVE ([OSV blog, 2023-11-06](https://osv.dev/blog/posts/introducing-broad-c-c++-support/)).

### What OSV knows about our dependencies (queried through api.osv.dev on 2026-10-16)

- **raylib**: three records, all with `GIT` ranges on `https://github.com/raysan5/raylib`: CVE-2023-26123 (web build only, fixed in 4.5.0), CVE-2025-15533 and CVE-2025-15534 (font loading, heap overflow and integer overflow, both fixed at commit [5a3391f](https://github.com/raysan5/raylib/commit/5a3391fdce046bc5473e52afbd835dd2dc127146), 2026-01-01). The latter two were generated from the CVE list entries assigned by VulDB (field `osv_generated_from` in [the record](https://api.osv.dev/v1/vulns/CVE-2025-15533)).
- NVD itself holds the same three CVEs for a `raylib` keyword search (query done through the [NVD API](https://services.nvd.nist.gov/rest/json/cves/2.0?keywordSearch=raylib)).
- **raylib 6.0** (commit dbc56a8) matches none of them: an OSV commit query returns nothing, and GitHub's compare API says 6.0 is 451 commits ahead of the fix. Raylib 5.5 (commit c1ab645) matches CVE-2025-15533.
- **raylib-zig**: no record. Querying the `GIT` ecosystem with its repository URL returns nothing.
- **Zig**: no record. Querying `GIT` with `https://github.com/ziglang/zig` and `https://codeberg.org/ziglang/zig` returns nothing, and neither a CPE query (`cpe:2.3:a:ziglang:zig`) nor the keywords "ziglang" and "zig programming language" find a CVE in the NVD. Absence of records is not evidence of absence of bugs.
- The commit ranges are approximate. The record for CVE-2025-15533 carries an `unresolved_ranges` entry (`introduced`/`last_affected` as the abbreviated hash `909f040`), which is the CVE's own wording turned into a range.

### OSV-Scanner

- Version checked: [v2.7.0](https://github.com/google/osv-scanner/releases/tag/v2.7.0) (2026-10-12); nixpkgs ships 2.5.1, which I ran.
- **It does not read `build.zig.zon`**, and its list of supported lockfiles has no Zig entry. For C and C++ it reads `conan.lock`, git submodules, and vendored copies, whose versions it estimates through the `determineversion` API ([supported languages and lockfiles](https://github.com/google/osv-scanner/blob/f455353546889009663c1f8b640d5880a01c889a/docs/supported_languages_and_lockfiles.md)). **Inference**: Zig unpacks packages into its cache without a git history, and we use no submodules, so neither route applies to our pins.
- **It accepts a hand-written list of commits.** A file named `osv-scanner-custom.json`, in the same format as its JSON output, is picked up by `scan source -r`, with entries such as `{"package": {"name": "github.com/repo/url", "commit": "<sha>"}}` (same page, "Custom Lockfiles").
- I tested this with osv-scanner 2.5.1, in a scratch directory (nothing in the repository):
  - the two current pins (raylib 6.0 and raylib-zig 8758f4c): "found 2 packages", "No issues found";
  - a single raylib 5.5 commit: two vulnerabilities reported (CVE-2025-15533 and CVE-2025-15534, ecosystem `GIT`), non-zero exit code (documented in [output](https://github.com/google/osv-scanner/blob/f455353546889009663c1f8b640d5880a01c889a/docs/output.md): exit code 1 when vulnerabilities are found).
- GitHub Action: the project publishes reusable workflows for pull-request scans and for full scans on a schedule, with `fail-on-vuln` and an `upload-sarif` input; its default arguments are `-r ./` ([GitHub Action docs](https://github.com/google/osv-scanner/blob/f455353546889009663c1f8b640d5880a01c889a/docs/github-action.md), [reusable workflow at v2.7.0](https://github.com/google/osv-scanner-action/blob/v2.7.0/.github/workflows/osv-scanner-reusable.yml)). Not run here; I only ran the CLI.
- **Gaps** (all follow from the above; **inference** where marked):
  - the file is hand-maintained: nothing links it to `build.zig.zon`, and the raylib commit is only visible in raylib-zig's manifest, so every bump of raylib-zig needs a human to re-read it (inference);
  - OSV knows only vulnerabilities that someone turned into a CVE; raylib's own policy asks for reports in public issues and discussions, with no CVE step (see 5);
  - the vendored GLFW, miniaudio and stb sources inside raylib are not in the list; OSV may know them under their own repositories, but I did not check them.

**Assessment**: OSV is the only candidate that matches our pins against actual advisories. It is imperfect (CVE-derived, hand-fed), but it needs no account, no token, and no change to the build.

## 4. Renovate

- Renovate has no Zig manager. Its manager directory (renovate 44.164.10, [main at e21b57b](https://github.com/renovatebot/renovate/tree/e21b57bbefec863005a54940caabd5e12ab92a99/lib/modules/manager)) lists `cargo`, `github-actions`, `git-submodules`, `nix`, `conan`, `gleam`, `custom` and others, and nothing for Zig.
- It can be taught: the [`custom` regex manager](https://github.com/renovatebot/renovate/blob/e21b57bbefec863005a54940caabd5e12ab92a99/lib/modules/manager/custom/regex/readme.md) extracts a dependency from any file with named capture groups, and the [`git-refs` datasource](https://github.com/renovatebot/renovate/blob/e21b57bbefec863005a54940caabd5e12ab92a99/lib/modules/datasource/git-refs/readme.md) can track the head of a branch (`currentDigest`). So Renovate could notice that raylib-zig's `devel` moved.
- **Inference**: a Renovate pull request could rewrite the commit in `.url` but not recompute the `.hash` line next to it, which `zig fetch --save` produces. The pull request would fail to build until someone fixes the hash by hand. Running arbitrary commands after an update (`postUpgradeTasks`) is a self-hosted feature, blocked by default on the Mend-hosted app ([configuration options](https://github.com/renovatebot/renovate/blob/e21b57bbefec863005a54940caabd5e12ab92a99/docs/usage/configuration-options.md)). I did not test any of this.
- Renovate's OSV integration (`osvVulnerabilityAlerts`) works only for direct dependencies of ten datasources (`crate`, `go`, `hackage`, `hex`, `maven`, `npm`, `nuget`, `packagist`, `pypi`, `rubygems`), so it would not flag raylib even through a custom manager ([same document](https://github.com/renovatebot/renovate/blob/e21b57bbefec863005a54940caabd5e12ab92a99/docs/usage/configuration-options.md)).
- Setting it up also needs an app installation (an organisation owner's decision) or a self-hosted runner. Not worth it for this problem.

## 5. Upstream channels

### raylib

- [`SECURITY.md`](https://github.com/raysan5/raylib/blob/master/SECURITY.md) exists. It lists `6.0.x` as supported (`< 5.5` unsupported), and says that a discovered vulnerability can be reported "directly ... using the project Issues and/or Discussions". **There is no private channel and no embargo**: private vulnerability reporting is disabled (`GET /repos/raysan5/raylib/private-vulnerability-reporting` returns `{"enabled":false}`).
- The repository has published **no GitHub security advisories** (`gh api repos/raysan5/raylib/security-advisories` returns `[]`).
- **Inference**: the practical alert channels are (a) new CVEs, which OSV picks up, and (b) the public issue tracker and releases.
- Releases: [releases](https://github.com/raysan5/raylib/releases) shows 6.0 (2026-04-23) and 6.2 (2026-10-15). An Atom feed is available at `https://github.com/raysan5/raylib/releases.atom`.

### raylib-zig

- No `SECURITY.md` (404 on `devel`, `main` and `master`), no published advisories, private vulnerability reporting disabled (same API calls on `raylib-zig/raylib-zig`).
- **No GitHub release at all**, so "Watch → Releases" would never fire. The Atom feed [`releases.atom`](https://github.com/raylib-zig/raylib-zig/releases.atom) lists only tags, the latest `v5.6-dev` from 2026-04-14. Changes land on `devel`; its commit feed is `https://github.com/raylib-zig/raylib-zig/commits/devel.atom`.
- **It is moving on from our toolchain.** At `devel`'s head today (50d4500), `minimum_zig_version` is `0.17.0` and raylib is pinned to another raylib commit ([manifest](https://github.com/raylib-zig/raylib-zig/blob/50d450099da664bedd7dcc6ed40204ab0bb861a5/build.zig.zon)). Our pin requires 0.16.0. **Inference**: if raylib gets a security fix, getting it through raylib-zig's `devel` may force us onto Zig 0.17.0, or a manual backport. That is a decision for the team (see "Open points").

### Zig

- The GitHub repository `ziglang/zig` is dead: its description is "Moved to Codeberg" and the README says the repository is not mirrored. The announcement is dated 2025-11-26 ([news](https://ziglang.org/news/migrating-from-github-to-codeberg/)). **Watching `ziglang/zig` on GitHub therefore tells us nothing.** The project now lives at `codeberg.org/ziglang/zig`.
- I found **no security policy**: no `SECURITY.md` or similar in the first-level files of the [Codeberg repository](https://codeberg.org/ziglang/zig), no `security` page on ziglang.org (404 on `/security/`), no mention in the Codeberg README. Not verified: a policy that lives somewhere I did not look, such as the issue tracker or the community pages.
- Zig has published **no advisories** that I could find, in the NVD, in OSV or on GitHub, and `gh api repos/ziglang/zig/security-advisories` returns an empty list (for the abandoned GitHub repository).
- Zig does mention security in release notes: 0.16.0 "distributes musl 1.2.5 plus backported security fixes" and states that it "is not believed to be affected by CVE-2026-40200" ([0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)); 0.17.0 lists a fix to "reject path deps that escape the parent package root" ([0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html)). **Inference**: release notes are Zig's de facto channel for security-relevant changes.
- 0.17.0 moved package fetching, the HTTP client, TLS, the git protocol and the archive parsers out of the compiler binary into the build system, shipped in source form (same notes). This is where our `build.zig.zon` dependencies are downloaded and verified.
- Patch releases exist for some versions (0.14.1 after 0.14.0, 0.15.2 after 0.15.1; [download index](https://ziglang.org/download/index.json)). There is no 0.16.1 as of today. **Unknown**: whether 0.16.x receives backported fixes now that 0.17.0 is out; I found no support policy.
- Feeds: `https://ziglang.org/news/index.xml` (200; 0.16.0 and 0.17.0 releases appear there) and `https://ziglang.org/devlog/index.xml`. `https://ziglang.org/download/index.json` lists every release and could be polled.
- `mlugg/setup-zig` downloads the tarball from a set of mirrors and verifies its minisign signature ([README](https://github.com/mlugg/setup-zig/blob/main/README.md)), so a tampered mirror should not be able to serve us a different compiler. I did not verify the verification code.

### GitHub "Watch → Custom"

- The custom options are issues, pull requests, releases, security alerts and discussions ([notifications](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/subscriptions-and-notifications/get-started/configuring-notifications.md)); each person sets them for their own account.
- **Inference**: "security alerts" only mean something where the repository's Dependabot alerts or advisories reach watchers. Dependabot alert emails go to people with write access or above, so the option adds nothing for repositories we do not maintain. **Releases is the useful one for raylib; it is useless for raylib-zig and Zig on GitHub** (see above).
- Cost: a minute per person per repository. No care needed, but it only reaches people who set it up and read their notifications.

## 6. Anything else

- **Actions workflow security** is already inside the Dependabot and Advisory Database scope above. Pinning to commit SHAs makes the workflows reproducible, but then Dependabot raises *no alerts* for them (semver tags only), only version-update pull requests.
- **`dependabot.yml` has a `cooldown` option** for version updates ([options reference](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/code-security/reference/supply-chain-security/dependabot-options-reference.md)), which delays pull requests for brand-new versions. Optional.
- **Scheduled workflows have two caveats** ([events that trigger workflows](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/actions/reference/workflows-and-actions/events-that-trigger-workflows.md)): in a public repository they are disabled automatically after 60 days without repository activity, and failure notifications go to the person who last modified the `cron` line. A weekly scan is free for public repositories on standard runners ([billing](https://github.com/github/docs/blob/ff759d8d323d8794ce98d1dedd758356e2940a84/content/billing/concepts/product-billing/github-actions.md)).
- **Flake input** (if the repository ships an optional `flake.nix` with a lockfile): Dependabot's `nix` ecosystem tracks `flake.lock`, for version updates only, no security updates. It would track nixpkgs, not Zig's CVEs.

## Comparison

| Candidate | Zig toolchain | raylib-zig | raylib | Workflow actions | Effort |
| --- | --- | --- | --- | --- | --- |
| Dependency graph and Dependabot alerts | no | no | no | alerts for semver-tagged actions | one settings toggle |
| Dependabot version updates (`github-actions`) | no | no | no | pull requests for new versions | one 8-line file |
| Dependency submission API | inventory only, no alerts (inference) | same | same | not needed | a custom workflow, a purl choice, a token permission |
| OSV-Scanner on a hand-written commit list | no | yes, if a CVE is ever assigned | yes (tested) | no | one JSON file, one workflow |
| Renovate | no | version bumps with broken hashes (inference) | idem | pull requests | app or self-hosted |
| Watch → Releases (GitHub) | repository dead | no release exists | yes | n/a | a minute each |
| Zig news feed and release notes | yes, manually | n/a | n/a | n/a | read them |

## Recommendation

**Assessment**: three cheap pieces, set up in about half an hour, none needing upkeep beyond a line in a file when a pin moves. The comparative study can describe it as "monitoring by public data, with its limits stated".

1. **Dependabot for the workflows.** Enable Dependabot alerts in the repository settings, and commit this file:

   ```yaml
   # .github/dependabot.yml
   version: 2
   updates:
     - package-ecosystem: github-actions
       directory: /
       schedule:
         interval: weekly
   ```

2. **A weekly OSV scan fed with the pinned commits.** Commit `osv-scanner-custom.json` at the repository root, and the scheduled workflow from OSV's documentation (`upload-sarif` off, to avoid depending on code scanning being enabled; the reusable workflow is pinned to the commit of tag `v2.7.0`, which I resolved with `gh api repos/google/osv-scanner-action/commits/v2.7.0`):

   ```json
   {
     "results": [
       {
         "packages": [
           { "package": { "name": "github.com/raysan5/raylib", "commit": "dbc56a87da87d973a9c5baa4e7438a9d20121d28" } },
           { "package": { "name": "github.com/raylib-zig/raylib-zig", "commit": "8758f4cd3a5ae0df6941c4715257223d34c5ad3e" } }
         ]
       }
     ]
   }
   ```

   ```yaml
   # .github/workflows/osv-scanner.yml
   name: OSV-Scanner

   on:
     schedule:
       - cron: "30 12 * * 1"
     push:
       branches: [main]

   permissions:
     actions: read
     contents: read
     security-events: write # the reusable workflow declares it; it is only used when upload-sarif is on

   jobs:
     scan:
       uses: google/osv-scanner-action/.github/workflows/osv-scanner-reusable.yml@b1d267aea5211fa648d9d442fa64b90dbdcbdd36 # v2.7.0
       with:
         upload-sarif: false
   ```

   The workflow was **not run**; only the CLI was, at version 2.5.1 rather than 2.7.0. The first real run should be a manual dispatch (add `workflow_dispatch:` under `on:`). Rule for the team: whenever `zig fetch --save` moves raylib-zig, update both commits in `osv-scanner-custom.json` (raylib's from raylib-zig's manifest). A comment above `.dependencies` in `build.zig.zon` would remind everyone.

3. **Human watching, for what no tool covers.** One teammate (or all three) sets *Watch → Custom → Releases* on `raysan5/raylib`, and follows the Zig news feed (`https://ziglang.org/news/index.xml`) and the raylib-zig `devel` commit feed in a feed reader. Each Zig release's notes get read for "security" when we decide whether to move up.

### What this leaves uncovered

- **The Zig toolchain**: no automated source at all. A vulnerability in the compiler, standard library or fetcher is known to us only if Zig says so in release notes, or someone files a CVE that we then notice by hand.
- **raylib-zig**: its own code (the bindings and build script) has no advisory process, no release and no CVE history; OSV would only know it if a CVE ever names it.
- **Bugs that are public but never got a CVE**: raylib's policy sends reports to public issues. OSV only sees what reaches the CVE list; nobody reads the issue tracker for us. The Releases watch catches the fix once it ships, not the report.
- **Vendored C sources in raylib** (GLFW, miniaudio, stb): not in the commit list. Their own advisories reach us, if at all, through a raylib release.
- **The window between a CVE and our rescan**: weekly, plus every push to the main branch.
- **Silence is not proof**: a green scan means "no known CVE matches these commits", nothing more. The scan list can also drift from `build.zig.zon`, since it is maintained by hand.
- **The 60-day rule and the single recipient** for scheduled-workflow failures. During the project, pushes keep the repository active. Afterwards the scan quietly stops, which is acceptable for a school project but should be said in the study.
- **Workflows pinned by SHA** get no Dependabot alerts, only version-update pull requests.

## Open points

- **Unknown**: whether Zig has a vulnerability-reporting channel (no policy found), and whether 0.16.x receives security backports now that 0.17.0 is out.
- **Not tested**: dependency submission (writing to GitHub was out of scope), the OSV reusable workflow at v2.7.0, and a Renovate custom manager.
- **Team decision**: whether to stay on Zig 0.16.0 while raylib-zig `devel` requires 0.17.0, and what that means for taking a raylib security fix. Part 1 ends on 2026-10-18, so staying put is probably right, and the study can state the risk.
- **Team decision**: who watches raylib's releases and the Zig feeds, since a notification that reaches only one person is a single point of failure.
