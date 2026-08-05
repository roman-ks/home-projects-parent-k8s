# Tailscale migration — task breakdown & delegation plan

## Vision recap
Migrate `/home/roman/projects/home-projects-parent/tailscale` (docker-compose) to k8s using the
official Tailscale k8s operator, replacing the hand-rolled OAuth key-rotation script entirely.

**Architecture decided:** per-service exposure (`tailscale.com/expose` annotations), not a subnet
router — smaller blast radius by construction. Each exposed service gets its own proxy pod;
NetworkPolicy locks each proxy's egress to only its target Service (mirrors the existing
`charts/kopia` ingress-only pattern, applied to egress instead).

**Success criteria:** `memos.pi.home` and `pi.home:445` (Samba) reachable from the tailnet, with
automatic auth-key rotation via the operator. Auth/Immich/Gram/Samba's remaining pieces can be
added later without major changes. `*.pi.home` naming is a hard requirement (Immich mobile app
uses network-name detection to pick local vs. tailnet URL, and location permission is a no-go) —
this is why the custom Go DNS stub stays instead of relying on Tailscale MagicDNS names.

---

## Task 1 — Provision the Tailscale OAuth client & secrets

Replaces `auth/auth_token.py` + `rotate-key.sh` + cron entirely — the operator mints/rotates
ephemeral keys itself once it has OAuth client credentials.

- **Skills/knowledge needed:** Tailscale admin console (OAuth client scopes, tags), this repo's
  existing SOPS/age encryption workflow (`values/*.enc.yaml`).
- **Human strengths:** Creating the OAuth client is a credential-creation action in a third-party
  account — do it by hand, don't delegate it. Deciding the minimal scope set is a judgment call
  (least privilege).
- **AI leverage:** Looking up exactly which scopes the operator needs (easy to over-grant if
  guessing), drafting the SOPS-encrypted values file and the Secret manifest that references it.
- **Where collaboration matters:** AI proposes the minimal scope list and the secret plumbing;
  human reviews the scope list *before* creating the credential in the console. Never paste a raw
  OAuth secret to an agent — only the resulting SOPS-encrypted file should exist in-repo.

## Task 2 — Deploy & configure the Tailscale operator

- **Skills/knowledge needed:** Helm install/values authoring, Tailscale ACL (HuJSON) syntax.
- **Human strengths:** Deciding what the tag/ACL policy should actually permit — this *is* the
  security boundary (who/what can reach the nodes this creates) and encodes intent only you have.
- **AI leverage:** Drafting the operator's Helm values, translating a plain-language access intent
  into correct ACL syntax (fiddly, easy to be accidentally too permissive).
- **Where collaboration matters:** Human states the intended access model in plain language, AI
  drafts the ACL grants + values, human reads the actual diff before applying — an ACL is a
  security control, not something to rubber-stamp because it looks plausible.

## Task 3 — Expose Memos and Samba to the tailnet

Confirmed the operator supports Layer-3/TCP exposure (not just HTTP) via the same
`tailscale.com/expose` annotation, so Samba's raw SMB traffic is a supported case, not a
workaround. ([Tailscale KB: cluster egress](https://tailscale.com/kb/1438/kubernetes-operator-cluster-egress))

Use explicit `tailscale.com/hostname` annotations (e.g. `memos-proxy`, `samba-proxy`) rather than
relying on the operator's default `namespace-service` derived name — gives Task 5 a deliberate,
readable string to hardcode instead of an implicit dependency on which namespace each chart happens
to deploy into. The DNS stub's own tailnet exposure is *not* part of this task — it's covered in
Task 5, since it has no dependency on Memos/Samba being exposed first.

- **Skills/knowledge needed:** Service annotation syntax; L3 vs L7 exposure mode differences.
- **Human strengths:** Confirming the resulting tailnet hostnames don't collide with anything
  already in use.
- **AI leverage:** Drafting the annotation additions to `charts/memos` and `charts/samba` — low-risk
  boilerplate once tasks 1–2 are settled.
- **Where collaboration matters:** Minimal — close to pure execution, light review is enough.

## Task 4 — Lock down each proxy with NetworkPolicy, and prove it

The task where "the YAML looks right" isn't good enough — this is the actual security boundary for
the whole project, so it gets verified live, not just reviewed.

- **Skills/knowledge needed:** NetworkPolicy `podSelector`/`namespaceSelector` syntax (already
  established via `charts/kopia/templates/networkpolicy.yaml` — this mirrors it, egress instead of
  ingress), `kubectl debug` / ephemeral containers for testing from a pod with no shell.
- **Human strengths:** Deciding what counts as *proof* it works, and running that proof yourself.
  An agent can't exec into your live cluster and can't be trusted to just assert a policy is
  correct — this is the clearest "Diligence" moment in the whole project.
- **AI leverage:** Drafting the NetworkPolicy YAML, and proposing the test procedure below.
- **Agreed test procedure:**
  1. Exec into the *specific proxy pod* for the service under test — the operator creates one pod
     per exposed Service (typically `ts-<service>-...` in the `tailscale` namespace); the policy
     binds to that pod, not the main operator pod.
  2. The proxy image is minimal and likely has no curl/wget — use
     `kubectl debug -it <proxy-pod> --image=nicolaka/netshoot --target=tailscaled` to attach an
     ephemeral container sharing the pod's network namespace, rather than assuming the base image
     has tooling.
  3. Test in this order: (a) *before* applying the policy, confirm the proxy **can** reach another
     service's ClusterIP — validates the test methodology itself; (b) apply the policy; (c) re-run
     the same curl and confirm it now fails/times out; (d) confirm the intended target still
     succeeds.
- **Where collaboration matters:** AI drafts policy + procedure, human executes and reads the
  actual result — this task is the reason the whole exercise isn't just "trust the generated YAML."

## Task 5 — Migrate the DNS stub

Keeping the custom Go DNS stub is a **confirmed decision**, not open for re-litigation: Pi-hole's
lack of split-horizon DNS was already tried and failed for this — it returns the LAN IP
(`192.168.50.150`), which isn't reachable from the tailnet, and advertising the whole LAN into
Tailscale was explicitly ruled out.

**Scope is bigger than a config change.** The current `dns/main.go` only supports one shared target
for the canonical name and all aliases — fine when everything pointed at the same Traefik IP, but
`memos.pi.home` and `pi.home` (Samba) now need to resolve to *two different* proxies. Needs a small
refactor to a per-hostname map (host → target) instead of one global `TARGET_IP`.

**Targets are CNAMEs to MagicDNS names, not raw IPs.** The operator auto-registers a MagicDNS name
for every proxy the moment it joins the tailnet — no manual console step. With the explicit
`tailscale.com/hostname` annotation set in Task 3, that name is a predictable string (e.g.
`memos-proxy.<tailnet>.ts.net`), not something to look up after the fact. Pointing the stub's map
entries at these names instead of raw tailnet IPs means it keeps working even if a proxy's IP ever
changes (e.g. a Service delete/recreate) — MagicDNS tracks the current IP for that name
automatically. The operator does persist each proxy's tailnet identity in a per-replica k8s Secret,
so IPs are stable across normal restarts anyway, but CNAME is the more correct choice for the same
implementation cost as hardcoding IPs.

**The DNS stub itself needs tailnet exposure too** — Tailscale's Split DNS nameserver field takes an
IP address, so the stub needs its own stable tailnet presence before it can be registered there.
Same `tailscale.com/expose` + `tailscale.com/hostname` mechanism as Task 3, just applied to the
stub's own Service. This part has no dependency on Task 3 and can happen any time after the
operator (Task 2) is up — only the map-wiring step below needs Task 3's memos/samba hostnames to
exist first.

- **Skills/knowledge needed:** Go (small refactor: single target → per-host map), buildah
  cross-arch build for arm64, this repo's existing justfile + OCI-registry pattern (same shape as
  `/home/roman/projects/gram/justfile`), Tailscale Split DNS configuration.
- **Human strengths:** The decision to keep custom code here instead of the "supported" tool is
  exactly the kind of call an agent shouldn't silently reopen — it doesn't know you already hit
  the split-horizon limitation firsthand. Same for CNAME-vs-IP: worth reasoning through rather than
  picking whichever an agent finds easiest to generate.
- **AI leverage:** Writing the build/push justfile recipe (mirroring gram's), the k8s
  Deployment/Service manifests, the Go map refactor, wiring in the memos-proxy/samba-proxy MagicDNS
  names once Task 3 has run.
- **Where collaboration matters:** Mostly implementation now that both hard calls (keep custom
  code, CNAME not IP) are made. One low-stakes point left for implementation time, not planning:
  config format for the new host→target map (env var vs. ConfigMap). Source location: repo-root
  `dns-stub/` directory (sibling to `bootstrap/`, `certs/`), *not* inside `charts/`, matching how
  gram's source lives in its own project dir and `charts/gram/` only holds deployment manifests.
  Keeps every chart in this repo meaning the same thing ("deploy a pre-built image"); Helm only
  ever parses `templates/`, so it wouldn't actually break either way, but image-only charts is the
  existing convention.

## Task 6 — End-to-end validation & cutover

- **Skills/knowledge needed:** none new — a manual "did it actually work" check, though DNS
  resolution now has more hops than before (tailnet client → Split DNS → stub → CNAME → MagicDNS →
  real IP), so test the full chain with `dig`/`nslookup` from an actual tailnet device, not just
  raw port connectivity.
- **Human strengths:** Entirely human. Removing the old docker-compose `tailscale`/`dns-stub`
  containers is hard to casually undo, and "it works" is a claim only verifiable with a real device
  on your real tailnet — an agent has no phone and no tailnet membership.
- **AI leverage:** Can propose the verification checklist, but its account of "it should work" is
  not evidence — only your own test is.
- **Where collaboration matters:** Deliberately the lowest-AI-involvement task in the project. Worth
  keeping in the plan as-is: it's the clearest illustration of a task that's structurally
  non-delegable, not just one where delegation happens to be a bad idea this time.

## Task 7 — Document the repeatable pattern

- **Skills/knowledge needed:** writing a clear runbook (style match: `samba-immich-install.md`).
- **Human strengths:** Reviewing for accuracy against what was *actually done*, not what was
  planned — plans and reality drift once you hit real k8s/Tailscale quirks.
- **AI leverage:** Drafting the doc from the real, executed manifests/commands (written *after*
  Task 6 confirms what actually worked, not from this plan).
- **Where collaboration matters:** AI drafts from ground truth, human edits for accuracy.

---

## Delegation pattern across the project

A few shapes repeat across all seven tasks — useful to keep in mind heading into the
Description/Discernment/Diligence practice later in the course.

**What stayed human, every time:** anything irreversible or outside the cluster (creating the
OAuth credential, deleting the old compose stack), anything that *is* the security boundary (ACL
intent, proof that NetworkPolicy actually blocks traffic, the decision to keep custom code over a
"supported" tool), and anything only verifiable first-hand (the live NetworkPolicy test, the
tailnet phone check in Task 6 — an agent has no cluster shell and no phone).

**What AI reliably did well:** translating a stated intent into fiddly, easy-to-get-wrong syntax
(ACL HuJSON, NetworkPolicy selectors, Helm values), and drafting boilerplate once a design decision
was already locked (manifests, justfile recipes, the Go map refactor).

**The recurring shape of collaboration**, where it mattered: human states an intent or constraint
in plain language — often informed by something an agent has no way to know on its own (the
split-horizon DNS attempt that already failed, why `*.pi.home` is a hard requirement) — AI drafts
the technical implementation, human reads the actual artifact before applying it rather than
trusting a description of it. This mattered most in Tasks 4 and 5, where the back-and-forth
genuinely changed the plan (the egress-NetworkPolicy test procedure, the CNAME-over-IP call) — not
just restated it.

**Not every task needed equal collaboration.** Task 3 was close to pure execution; Task 6 was close
to pure human. The valuable middle ground was the handful of tasks where a real question ("but does
Tailscale actually enforce this, or are we trusting it?") surfaced something the first draft had
gotten wrong or left underspecified.
