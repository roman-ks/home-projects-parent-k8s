# Diligence statement — Tailscale-to-Kubernetes migration

Project: migrating a docker-compose Tailscale subnet-router/DNS setup to a
Kubernetes-native deployment using the official Tailscale operator, as part of
coursework for the Claude Certified Architect – Foundations certification. See
`tailscale-tasks.md` in this folder for the task breakdown and delegation
analysis this statement follows on from.

## Creation Diligence

I chose Claude (Claude Code) specifically to build hands-on experience with it
ahead of the certification — the tool choice was driven by the learning goal,
not by a comparative evaluation of alternatives. The information I shared with
it was my own existing docker-compose project (a personal homelab setup) and
live state from my own Kubernetes cluster that Claude inspected directly while
debugging chart/values issues — chart directories, rendered manifests, `helm
template` output. All of it was my own infrastructure; no third-party or
external user data was involved at any point.

The one deliberate boundary I held throughout: real credentials (the
Tailscale OAuth client secret) never passed through the AI at all. Claude
created placeholder scaffolding and gave me instructions for generating the
credential myself in the Tailscale console; I filled in and SOPS-encrypted the
real values myself, and Claude was never permitted to run `apply`/`install`/
decrypt commands against my cluster. That separation was a conscious choice,
not an accident.

## Transparency Diligence

The audience for this project's output is just me — a personal homelab, not a
shared or public deliverable. There's no formal disclosure expectation from
anyone else, since no one else consumes this work directly (with the minor
exception that a couple of the exposed services are reachable by another
tailnet member I share access with, though they aren't stakeholders in the
deliverable itself). Because of that, I don't think transparency obligations
are a live risk here — but I'm keeping this statement and the accompanying
`tailscale-tasks.md` plan on record as an honest account of AI involvement, in
case that ever changes (e.g. if I share the setup or configs with someone else
later).

Concretely, AI contributed to: exploring architectural options (subnet router
vs. per-service exposure, DNS strategies) and stress-testing the tradeoffs
with me; breaking the project into tasks and analyzing what to delegate;
scaffolding chart, values, and justfile files; writing step-by-step manual
instructions for the steps that required my own judgment or credentials
(OAuth client creation, ACL edits); and explaining the reasoning behind the
setup as we went, including correcting itself when it got something wrong.

## Deployment Diligence

I verified AI contributions by actually deploying them to real hardware — not
just trusting that generated YAML looked correct. I manually confirmed the
deployed result met the intended goal (services reachable at the expected
tailnet names) rather than treating "helm install succeeded" as sufficient
proof. I also compared the AI's output against my original docker-compose
project files to check for functional parity and catch anything that might
have been dropped or changed unintentionally in translation.

I'm taking full responsibility for the final product. Using AI to draft,
research, and scaffold this work doesn't transfer accountability for what's
actually running on my cluster — I reviewed and applied every change myself,
and I own the outcome.
