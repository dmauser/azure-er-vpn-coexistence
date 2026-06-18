# Work Routing

How to decide who handles what.

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|----------|
| Architecture / scope / address plan | Morpheus | Topology, coexistence design, trade-offs, reviewer gate |
| Azure Terraform (terraform/azure) | Trinity | Hub/spokes, VPN GW, ER GW, LNG, ER circuit |
| GCP Terraform (terraform/gcp) | Niobe | VPC, Classic VPN, Cloud Router, Partner Interconnect |
| Cross-state / integration / keys | Tank | remote_state wiring, shared key, Megaport handoff, validation |
| Docs / README / .gitignore | Switch | Guidance rewrite, archive README, prerequisites/cleanup |
| Code review | Morpheus | Review change set, enforce reviewer gate |
| Session logging | Scribe | Automatic — never needs routing |
| Work queue / keep-alive | Ralph | Backlog monitoring |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| squad | Triage: analyze issue, assign squad:{member} label | Morpheus |
| squad:{name} | Pick up issue and complete the work | Named member |

## Rules

1. Eager by default — spawn all agents who could usefully start work.
2. Scribe always runs after substantial work, always as background. Never blocks.
3. Quick facts -> coordinator answers directly.
4. When two agents could handle it, pick the one whose domain is the primary concern.
5. "Team, ..." -> fan-out. Spawn all relevant agents in parallel as background.
6. Anticipate downstream work.
7. Cross-state contract first. Tank locks output/variable names before Trinity/Niobe finalize.
