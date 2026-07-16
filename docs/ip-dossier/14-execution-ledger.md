# 14 — Execution ledger (archived 2026-07-16)

> Verbatim copy of `.superpowers/sdd/progress.md`, which is **git-ignored**
> (`.superpowers/sdd/.gitignore`) and therefore lived only in one working tree.
> The handoff rule said *"trust the ledger and git log over recollection"* — while
> git did not hold the ledger. Archived here so that stops being true.
>
> It records the A′ readiness effort task by task. **The migration it prepares was
> not needed** — see `00-README.md`'s banner and R-23. Kept because the plans are
> the fallback if a second node is ever added.

```
Task 1: complete (commits 86782e7..246f152, review clean after 1 fix round)
Task 2: complete (commits fc07fde..bdac3c8, review clean after 1 fix round; A3's control now sits on the positive side of the netns boundary — proven RED with the backend scaled to 0)
Task 3: complete (commit 42e0cc4, review Approved — reviewer proved A6 goes red and A7's control is load-bearing)
  MINORS for the final review:
  - A6 (verify-aprime.sh:203-208) asserts inequality of a blob, not the absence of the forgery.
    Redness depends on grep emitting two lines; a future `| tail -1` would make it pass while blind.
    Fix: assert "$(... | grep -c '1\.2\.3\.4')" "0" + a control that an XFF line exists at all.
  - A7's leak test compares CN only (verify-aprime.sh:229-230). A cert with a different CN but a SAN
    covering the other brand would pass. Does not bite today (the fallback has no SANs).
  - A6's CLIENT_IP control is inherited from A5; would break silently if A5 were reordered.
  - PLAN BUG: Task 3's brief says "12 new PASS"; the real count is 14 (+3 controls = 17). The 12
    omits A7's two leak assertions — the ones that killed the single-controller design.
Task 4: complete (commits 770efd1..567b018, review Approved after 1 fix round)
  - The implementer "refuted" dossier 09 §4.5 (ConfigMap changes do not reload) by measuring the
    FILE. Measured on the WIRE it is false: gzip stayed up 75s+, reload counter flat, pod UID same.
    §4.5 HOLDS. Reverted in aaec5eb. The reviewer reproduced my correction independently.
  - Real per-key nuance found: typed keys (proxy-protocol) DO reload; raw frontend-config-snippet
    does not. Comment narrowed accordingly.
  - The gate was flaky (2/5 runs red) because an empty helm-template render made grep -c report
    "the digest was dropped". Now has a non-empty control + prints the render stderr.
  - PLAN BUG: Task 4's A11 used `curl -skI` (HEAD). HAProxy never compresses bodyless HEAD
    responses -- a permanent false negative. Implementer caught it; fixed to a GET.
Task 5: complete (commit 69dabc9, 62 PASS/0 FAIL; A13 hairpin + A14 live ACME both green; added a FATAL guard that the gate resolves to the lab, not prod)
Task 6: complete (commits ae9b38e..1569865; 68 PASS/0 FAIL. A16 proved the contrast: bad config wedges the new pod at 0/1 while the OLD pod keeps the brand at 200 -- path B's Recreate could not. A16 was racy on a fixed sleep; now polls. FOURTH blind check found+fixed: the CoreDNS prod-guard passed on leftover state because the backup was taken from an already-patched Corefile.)
Task 7: complete (commit 12fcd82, 70 PASS/0 FAIL from a DELETED-then-rebuilt cluster in 7m41s; the rebuild found the RESULT block's absence and A5's race)
Task 8: complete (commit 8032c38) — docs/superpowers/plans/2026-07-16-aprime-migration.md, Rev 1,
  1435 lines, 9 tasks, 11 sections, 13 risks. Text only; nothing outside docs/.
  The author caught ITSELF committing R-14: it wrote "every reference resolves" into the
  Self-Review BEFORE running the check; the check then found a real dangling Task 5 Step 9b.
  Recorded rather than quietly repaired.
  ITS OWN FLAGGED WEAK POINT (attack this first in Task 9): Task 5 Step 9's claim that
  "idle is provable in A'" -- the backends are ClusterIP Services reachable from the node's
  netns, which IS the edge's netns. That reasoning is sound, and it was sound the last two
  times this exact trap fired (gate A3; path B Rev 5's "idle = unobservable").
  Three checks in that step have never been run anywhere: 9b's reset, 9c's curl --haproxy-protocol,
  Step 3's yq. And 10.244.0.0/24 is COMPOSED from the node's podCIDR, not measured.
Task 9 (review round 1): complete — plan Rev 1 -> Rev 2; 74 PASS/0 FAIL from a DELETED-then-rebuilt cluster.
  1 BLOCKER, 2 HIGHs, 3 LOWs; all three of the first two categories were the SAME defect --
  "a check that returns the pass value while blind" -- now hit across 7 revisions of the two siblings.
  BLOCKER: the plan's header claimed edge.yaml "already carries the real prod IPs" and that
  "a fourth difference is a defect". It carries the REPLICA's 192.168.160.91/.90 in four dst ACLs,
  so the sentence told an operator who made the correct edit to REVERT it. Nothing gated it: Step 3
  read release-*.yaml only, "edge" appeared 0 times. Reproduced: wrong dst -> pod 1/1 Running,
  probe green, ALL of Step 9 returns its expected strings, hfc-ip+hfc host = 404 under
  CN=haproxy-main.haproxy-ingress; leadsfilter survives only via default_backend.
  Fixed in 3 places + the structural one: verify-aprime.sh A18 -- every dst must be an address the
  node ACTUALLY OWNS (asserts the property, not the strings). Made to fail on purpose: red, restore, green.
  HIGH-1: yq was NEVER in lab-aprime/bin/ (the SIBLING lab's bin has one). Step 3 run verbatim =>
  exit 127, two 0-byte files, diff prints nothing = its literal stated pass criterion. Now pinned
  v4.44.3 in the gate with a FATAL bootstrap check; test -s moved inside the loop, both brands.
  HIGH-2: 9b returned its pass value with haproxy-hfc scaled to zero (000/exit=7, control still 200).
  %{http_code} cannot tell reset from refused; the exit code was narrated, never asserted. And the
  control was the WRONG Service (hfc-wp, no expect-proxy) -> blind to A16. Now asserts RC=56 and 9c
  IS the control (same source, same Service, PROXY vs plain).
  LOWs: O-4 mis-cited 🟢 in 5 plan spots + 3 in 12-session + 1 in lab README (it is 🟡, 06:67);
  02-verified-facts §1.1 asserted "single node" as a ✅ VERIFIED fact from an `ip -4 addr` paste that
  cannot show node count -- contradicting O-4 and R-08's own closing line; --namespace on Step 3's renders.
  🔴 CARRY FORWARD: the blocker's fix touches header+Step 3+Step 9 at once -- the sibling's 5th defect
  was introduced by the fix for its 4th. Only A18 of the four new pieces was proven by failing.
  9b's RC plumbing and Step 3's edge grep have never been run. Task 4 Step 2's premise still untouched.
Task 9: IN PROGRESS — 2 adversarial rounds done, both found a BLOCKER. Plan now at Rev 3 (c0fc946).
  Round 1 (Rev 1): BLOCKER — edge.yaml ships the REPLICA's IPs in its dst ACLs while the header
    claimed "already carrying the real prod IPs" and "a fourth difference is a defect", i.e. it
    told the operator to revert the correct edit. Ungated. Proven: Task 5 Step 9 returned EVERY
    expected string while hfc was 404 under the wrong cert. +2 HIGH (yq not in bin/ -> the diff
    gate compared two empty files and called it a pass; 9b passed with the backend deleted).
  Round 2 (Rev 2): BLOCKER — a TRANSPOSED dst pair defeats BOTH of Rev 2's new controls and kills
    BOTH brands (Rev 1's took one -- a cheaper recovery, NOT a lesser failure: one dead brand already fails the migration outright, R-25). Step 3 counts occurrences, not pairings;
    A18 sort -u's the addresses and throws the use_backend target away. Proven on a live swapped
    cluster: both brands 404 under the other instance's cert, A18 4 PASS 0 FAIL.
    +2 HIGH (9b's control FAILS ON A HEALTHY SYSTEM -- lost the Host header; Rev 1's blocker
    sentence SURVIVED at Task 5 line 407), +2 MEDIUM, +3 LOW.
  *** THE ROUND'S REAL FINDING (Rev 3's fix report, concern 1): the reviewer's PRESCRIBED fix was
  itself blind to the blocker. Spec was "each brand's two ACLs carry the same address, and the
  brands' addresses differ" -- a full transposition satisfies BOTH. Implemented as written, A18
  would have gone GREEN on the transposition. Found ONLY by running the mandated fail-on-purpose
  experiment before shipping. R-13 at depth: check the reviewer too. ***
  Also: HIGH-2 had a THIRD copy the review never named (Global Constraints ~line 86), found by
  grepping rather than trusting Rev 2's changelog.
  Gate: 80 PASS / 0 FAIL from a deleted cluster, with A18 extended to assert the PAIRING.
  Gate (Rev 4): 89 PASS / 0 FAIL from a DELETED-then-rebuilt cluster (80 + 9 in A7 - 2 in A18 + 2
    in A16). Whole run captured; A18b prints its route set and A7 its per-name verdicts.
  *** FOUND BY VERIFYING THE FIX, NOT BY REVIEWING IT -- A GATE DEFECT: A16's restore is a wish.
  After the 87/0 run the lab was NOT clean: cm/haproxy-main still held A16's poison 10.244.0.1/33,
  a pod was wedged 0/1 Running, and helm history had NO revision for the restore. Reproduced with
  the stderr the gate throws away: `helm upgrade` re-fetches the chart from github and died on
  `connection refused` (exit=1, silenced by >/dev/null 2>&1); `rollout status` then timed out
  (also silenced); the gate printed passed: 87 failed: 0. The gate calls itself OFFLINE and is not.
  WHY NOTHING NOTICED IS A16'S OWN THESIS: a wedge is survivable -- the OLD pod kept leadsfilter
  at 200 -- so the one test whose lesson is "a wedge is invisible" was the step that hid one.
  Fixed: the restore retries AND is asserted (value read from values-main.yaml, not typed).
  Proven both ways: green on the restored lab; RED on the exact state the 87/0 run left behind,
  with leadsfilter still 200 on the wire. ***
  Round 3 (Rev 3): DO NOT EXECUTE -- TWO independent reviewers, each with a BLOCKER, both in the
    newest material (Rev 3's own fix for Rev 2's blocker). Plan now at Rev 4.
    BLOCKER (both, independently, from opposite sides): A18b and Step 3's four `grep -qE` assert
      PROJECTIONS of the route, never the route -- they read `use_backend ... if { dst ... }` lines
      and nothing else. FIVE mutations measured, each shipping a dead brand with edge-lb 1/1
      Running, A18 10 PASS/0 FAIL, Step 3 gate exit=0: a SERVER-line transposition (be_hfc_https
      dials haproxy-main -> hfc's public IP served a WORKING leadsfilter site under a VALID
      CN=leadsfilter.com cert, Verify return code: 0 (ok) -- R-21's killer, the D-1 link the
      two-IP split exists to hide); a COMMENTED-OUT ACL (grep -q is unanchored, the comment text
      satisfies it); an ACL in the WRONG FRONTEND (the patterns key on the backend NAME); a BIND
      swap; a default_backend FLIP.
    FIXED BY DELETING THE SECOND PARSER, NOT EXTENDING IT: Step 3 regenerates edge.yaml from the
      tested lab file (measured: the lab->prod delta is EXACTLY seven sed substitutions, zero
      stray hits) and diff -u's it against the shipped artifact. No allowlist to be blind through.
      Proven against 16 mutations incl. six nobody had enumerated (timeout, resolvers stanza,
      send-proxy-v2, runAsUser, strategy, server ports) + green on a correct file INCLUDING the
      collision case where prod's CoreDNS ClusterIP IS the lab's 10.96.0.10.
    *** THE GENERATOR'S OWN CONTROL IS THE PIECE THAT MATTERS: lab file reformatted so a sed stops
    matching AND the operator also left the replica's IP => THE DIFF IS CLEAN and .91 ships.
    Caught by the generator control and by nothing else. It is a control on the GENERATOR; the
    shipped file is validated by the DIFF. Do not conflate them. ***
    dst ground truth now from PUBLIC DNS (getent ahostsv4), not a hard-code shared with the edit:
      agrees with the dossier on all 4 names; 4 controls each fired on purpose (NX, two A records,
      www != apex, both brands identical). Honest limit written into the plan: DNS is ground truth
      only while the A records are correct.
    +HIGH-1 (the plan told the operator to build a file its own guard rejects -- Step 2's snippet
      showed `# was 192.168.160.91` comments and said "copied verbatim, comments included";
      built that way with PERFECT routing, Step 3 prints "🔴 STOP: the REPLICA's IPs reached prod").
    +HIGH-2 (false prose: "A18 catches any dst that cannot match, IN ANY ENVIRONMENT" -- the gate
      carries a FATAL guard at :465-469 that aborts rather than ever resolve to prod; A18 is
      structurally incapable of seeing prod's edge.yaml. The gate's own comment was honest and
      the plan contradicted it. Fixed in BOTH copies, found by grepping not by the changelog).
    +MEDIUM-A7 (the leak test compared a CN; R-21's leak is a VALID cert, and validity is SANs.
      Measured: hfc's OWN correct CN + DNS:leadsfilter.com in the SANs -> A7 8/8 PASS while .91
      served leadsfilter.com a cert a client ACCEPTS. Now a -verify_hostname probe against a trust
      store built from the SECRETS, apex AND www -- a WILDCARD SAN passes the apex probe and is
      caught only by the www one. Closes a ledger MINOR open since Task 3, recorded as "does not
      bite today" and never tested.)
    +MEDIUM-tmp (Task 4 Step 5 wrote /tmp/aprime-proxy-list.txt UNCONDITIONALLY after its own
      guards rejected the value -- both STOPs fired, poison on disk), +MEDIUM-loops
      (`|| { echo STOP; false; }` in a for loop: hfc STOPs, main passes last, block exit=0 -- the
      plan called it "not advice, a command with an exit status"; it was neither. All blocks now
      subshells, re-measured green on healthy artifacts), +MEDIUM-tests (test -s /tmp/edge.cfg
      cannot fail: yq -r '.data."haproxy.cfg"' on a multi-doc file emits `null` = 5 bytes with the
      ENTIRE ConfigMap deleted; fixed by select(.kind=="ConfigMap"), then made moot -- the
      canonical diff reads the artifact directly and /tmp/edge.cfg no longer exists).
    +LOW-1 (a FOURTH false count: "exactly six edits -- items 2-8" is SEVEN, and it sat inside
      Rev 3's own correction of the second false count), +LOW-2 (Step 9 exercised ONE of the
      edge's FOUR routes and one of two frontends; the three untouched include BOTH HTTPS backends,
      the ones carrying the certificates. Rev 4 adds an HTTPS probe -> two of four, and states the
      coverage out loud).
  *** THE ROUND'S REAL FINDING: round 2's reviewer prescribed a blind fix; round 3's reviewer A
  NEARLY REPEATED IT -- its first prescribed fix (an anchored (frontend, backend, dst) triple
  parse) passed CORRECT, caught TRANSPOSED, and then printed PASS on three mutations it had not
  thought of. THREE consecutive revisions each replaced one projection of the route with another
  projection of the route, each certified by the failure its author had just met. When three
  checks of the same shape have each been blind, THE SHAPE IS THE DEFECT. The escape was not a
  better projection -- it was to stop hand-maintaining a parser at all. ***
  FOUR of Rev 4's OWN pieces were blind/false when first written; RUNNING caught all four,
  reading caught none -- and TWO of them were in the fix for this round's blocker:
  (a) Step 3's block 4b called resolve1, a function defined in a DIFFERENT code block -- run
      verbatim in a fresh shell on a PERFECTLY CORRECT artifact: "resolve1: command not found",
      gate exit=1. A RED GATE ON A HEALTHY SYSTEM (Risk #1) inside the fix for a round whose
      HIGH-1 was exactly that. Blocks are now paste-safe alone.
  (b) the blocks' OWN exit status was the trailing echo's = 0, while the line they printed said 1.
      A human reads ">>> gate exit=1" and stops; an AGENTIC worker (which this plan mandates)
      running `bash -c '<block>'` reads 0. A check returning its pass value to the thing actually
      running it -- THE SPECIES, IN THE FIX FOR THE SPECIES. Now `rc=$?; echo ...; (exit $rc)`,
      re-measured 0 on correct / 1 on mutated.
  (c) the A18b parser used the regex interval {3}, which MAWK DOES NOT HONOUR -- it silently
      parsed every dst as "192.168.1", a clean self-consistent WRONG parse that would have
      reddened a CORRECT config.
  (d) the mutation harness piped the gate into `head` (SIGPIPE -> exit=141), then a later harness
      read the echo's status and reported exit=0 for NINE mutations the block had correctly
      rejected. BOTH TIMES THE HARNESS LIED TOWARD "it passed".
  Rev 4's Step 3 block was then run VERBATIM (extracted from the markdown, fresh shell): 14/14
  mutations exit=1, correct file exit=0 twice, and the blind-sed+operator-left-.91 case exit=1
  where a bare diff is CLEAN.
  REV 4 IS UNREVIEWED. Round 4 must target, in order:
  (a) THE GENERATOR, not the diff -- it is the newest material, and the newest material has
      produced the defect 8 times out of 8. Find a lab-file edit that keeps all five gen_ctl
      patterns matching while changing what they mean; find a substitution whose count is right
      and whose result is wrong.
  (b) resolve1 / the DNS derivation -- new, runs on the operator's workstation, and its output
      becomes a dst. Split-horizon resolver? search-domain suffix? CNAME chain? an /etc/hosts line
      on the operator's box? THERE IS NO CONTROL FOR "the resolver I asked is the one the internet
      uses".
  (c) Go and DISPROVE "the attack surface is those seven values" -- the measurement behind that
      sentence is one grep of one file on one day. Rev 2 and Rev 3 both said the class was covered.
  (d) THE WIRE. Everything here reads files; 09 §4.5 HOLDS (the controller rewrites the file and
      does NOT reload), so a stale edge-lb pod serving a previous config passes every static check
      at 100%. Prod has no 4-way probe before cutover. Design the check that would catch it and
      find out whether it can exist.
  (e) The remaining counting claims ("exactly 3 haproxy lines", "5 backends", "the four routes") --
      four false counts in three revisions; the rest are still uncounted.
Task 10 (ETP / hostPort+hostIP / who really SNATs): NOT STARTED.

================================================================================
ROUND 4 DONE. PLAN AT REV 5. 2026-07-16.
================================================================================
VERDICT ON REV 4: DO NOT EXECUTE, from TWO independent reviewers, each with a BLOCKER --
plus a USER REFUTATION (R-25) that inverted a load-bearing decision carried unexamined for
four revisions. NINE revisions, NINE defects, every one in the newest material. None found
by reading; all nine by making the check fail on purpose.

*** THE PREDICTION POOL WAS RIGHT FOR THE FIRST TIME, AND IT DID NOT HELP. ***
  Rev 4's ledger entry (b) said: "resolve1 / the DNS derivation -- new, runs on the operator's
  workstation, and its output becomes a dst ... THERE IS NO CONTROL FOR 'the resolver I asked is
  the one the internet uses'." THAT IS EXACTLY WHERE THE BLOCKER WAS. It was named, in the right
  words, in the right place, one revision in advance -- AND SHIPPED ANYWAY. Rev 2 did this too
  (Risk 14 predicted Rev 3's blocker by name). Naming the hazard prevents nothing; only running
  the experiment does. Entry (c) -- "go and disprove 'the attack surface is those seven values'" --
  was ALSO right (it was false; the surface moved to the LAB file). Two of five hits, both ignored.

WHAT ROUND 4 FOUND (all re-verified independently before Rev 5; both zone-A blockers
re-reproduced from scratch during implementation):
  R-25 (USER, outranks both blockers): THE CUTOVER ORDER WAS RANKED BY REVENUE. Wrong axis.
    hfc COLLECTS leads -- a visitor who meets an outage NEVER RETURNS, the lead is DESTROYED,
    and Google Ads degrades the AI optimiser (damage outlives the outage). leadsfilter SELLS
    them -- a buyer returns in an hour; the loss is a DELAY. So the plan aimed its FIRST,
    LEAST-REHEARSED cutover at the ONLY brand whose losses cannot be recovered and called it
    safe. THE REFUTATION WAS ALREADY IN THE DOSSIER, ONE PAGE AWAY (12-session:241, "a lead POST
    lost mid-restart is silently unrecoverable"). The knowledge was not missing -- IT WAS
    UNLINKED. The rationale sat in a PARENTHESIS -- "(lower revenue risk)" -- and four
    adversarial reviews read that line and attacked the machinery around it.
  R-25b TWO SCALES, MERGED: acceptance is DISCRETE (both IPs up or the task is FAILED; on that
    scale the brands are EXACTLY EQUAL and a dead "minor" brand is TOTAL FAILURE); ordering is a
    gradient. The plan framed a one-brand outage as "the milder case" in NINE places. All are
    already total failure. The mechanic (default_backend masking a dead ACL) is real; THE
    FRAMING LIED. Third instance of "two scales silently merged"; invisible for four reviews
    because both scales use the word "worse".
  BLOCKER-A: resolve1 NEVER READ DNS. getent walks nsswitch; `hosts: files dns` -> FILES WIN.
    MEASURED: four /etc/hosts lines -> HFC_IP=192.168.160.91 MAIN_IP=192.168.160.90, ALL FOUR of
    Rev 4's controls PASS, gate exit=0 -- the REPLICA'S ADDRESSES ship with a green tick, which is
    the single defect Task 5's header exists to prevent. Rev 4's claim "the ground truth now comes
    from PUBLIC DNS" was FALSE. Aggravator: lab_gone() disabled itself when its own subject
    appeared. Nothing asserted the VALUE of HFC_IP/MAIN_IP at all.
  BLOCKER-B: THE GATE WAS NOT REPRODUCIBLE -- 89/0 . 82/7 . 89/0, one box, one cluster. Seven
    assertions failing on a HEALTHY lab. Causes: (1) A15's restore was a silenced, unasserted
    `helm upgrade` -- THE IDENTICAL CONSTRUCT REV 4 FIXED IN A16 FIFTY LINES BELOW. It deleted
    hfc's Service, never restored it, then blamed `resolvers` (its own subject) = a PHANTOM
    defect; its control assert_ne "" "$OLD" printed PASS with the Service ABSENT = A2's defect,
    fixed for A2 and not for A15. THIS ALSO SOLVES ROUND 3'S UNEXPLAINED 75/5. (2) A7 raced the
    controller's TLS ingestion; the readiness loop that exists to prevent that race used
    `curl -sk`, which returns 200 on the SELF-SIGNED FALLBACK. Secret correct throughout; system
    converged with NO FIX APPLIED. RED ON A HEALTHY SYSTEM.
  HIGH: the canonical diff cannot see its own template and BOTH sides derive from it. MEASURED:
    strategy Recreate->RollingUpdate IN THE LAB FILE -> gate exit=0 AND IT SHIPS (Rev 4's table
    claims exit=1 -- measured on the SHIPPED file only). `!` before every { dst } IN THE LAB FILE
    -> every ACL inverted, both brands cross-routed, gen_ctl 5/5, lab_gone clean, diff IDENTICAL,
    exit=0. sha256sum/git-diff across the whole plan: ZERO HITS. "The attack surface collapses to
    those seven values" is FALSE -- it MOVED from SHIP to LAB, and LAB has strictly LESS coverage.
  HIGH: the digest cross-check read the LOCAL CACHE. pull status never consulted; unreachable
    registry -> exit=0. Its stated purpose ("or the tag advanced") is structurally unreachable.
    THE dst DEFECT REV 4 HAD JUST FIXED ("edit and check share one source"), REINTRODUCED 40 LINES
    LATER FOR ITEM 8, on the one shared-fate component.
  HIGH: A18b blind to ACL negation -- the FOURTH generation of the projection. Two chars (`!`) ->
    8 PASS / 0 FAIL, route set byte-identical to the control, while hfc's public IP served a
    WORKING leadsfilter site under a valid CN=leadsfilter.com, Verify return code: 0 (ok) = R-21's
    killer, live. Both reviewers found `!` independently, from opposite sides.
  MEDIUM: A7 reds on a healthy lab at 48h (certs -days 2, minted skip-if-exists, cluster reused)
    AND verifies_as collapses EVERY failure into "no" -- WHICH IS THE LEAK ASSERTIONS' PASS VALUE.
  MEDIUM: A16's restore assertion passes with the brand DELETED (grep -c '0/1' = 0 on an empty pod
    list) = A3's defect, fixed for A3 and not for A16's restore.
  LOWs: line ~79 contradicts line ~458 about what Step 3 does (both shipped, same revision); Rev 4's
    changelog carries FOUR mediums while its commit said three (FIFTH false count); "three cases A8
    is green on" is 2 of 3 (SIXTH false count).

R-26 -- FOUND DURING REV 5, from a user question, UNRECORDED ANYWHERE (grep -rn 'subPath' docs/ =
  ZERO HITS), AND THE PLAN ASSERTED THE OPPOSITE:
  Global Constraints said an edge "config change ... takes homefinanceclub AND leadsfilter down
  together". MEASURED AND ISOLATED: edge.yaml mounts haproxy.cfg with subPath; a subPath ConfigMap
  mount NEVER receives kubelet updates, and a ConfigMap edit does not roll the Deployment. The
  ISOLATING ARM is what makes it a finding: a second, NON-subPath mount of the SAME ConfigMap in
  the SAME pod updated within 10s while the subPath one never did. Wire kept the OLD routing; pod
  UID identical; RESTARTS 0. `rollout restart` = the control proving the change was real and
  reachable -- and then the transposition cross-routed BOTH brands. SO: an edit to the edge's
  config is a SILENT NO-OP -- the more dangerous direction. The plan's own remedy for its own #1
  risk ("fix the dst and reconcile") DOES NOTHING while every downstream check reads the file and
  goes green. It also explains an observation round 4 already had: every mutation needed an
  explicit rollout restart to reach the wire -- EVIDENCE GATHERED BEFORE THE HYPOTHESIS EXISTED.

WHAT REV 5 CHANGED:
  PLAN: Tasks 6/7/8 RESTRUCTURED, not name-swapped -- ONE WINDOW, THREE PHASES (user decision:
    "залить сперва 1 бренд, а через дни второй -- вариант для меня плохой"): T+0 leadsfilter ->
    T+10 renewal proof on leadsfilter -> T+25 homefinanceclub. R-25 not retracted; it compresses
    from days into minutes. Re-reasoned per phase: the interception mechanic, the certificate gate
    (Task 8 must now distinguish leadsfilter's DELIBERATE T+10 Order from an hfc blocker, or it
    aborts a healthy window), the iptables-save positive controls (Task 6 controls on .66; Task 8
    CANNOT control on .214 -- Task 6 deleted it 25 min earlier, so Rev 4's control would RED ON A
    HEALTHY SYSTEM at T+25), the per-phase rollbacks, and every "X stays fully live on nginx".
  GATE (verify-aprime.sh): 110 assertions, failed: 0, REPRODUCED 5x (4 rebuilt, 1 reused) where
    Rev 4 gave 89/0 . 82/7 . 89/0. A15 retry+stderr+restore asserted BEFORE assert_ne; A7's wait
    now compares the WIRE CERT'S FINGERPRINT to the SECRET'S (a DIFFERENT property from what A7
    asserts, so the wait cannot manufacture A7's green -- and it is what makes the expiry re-mint
    safe, since "not the fallback" is already true of a stale cert); A7 mints on missing OR
    checkend 86400; A16's restore gets A3's control; A18b = canonical diff of the LIVE ConfigMap vs
    `git show HEAD:...edge.yaml` (an INDEPENDENT channel -- the live CM came from the WORKING TREE)
    with two non-empty controls; NEW A18c (strategy/hostNetwork/runAsUser -- the Deployment half
    A18b structurally cannot see); NEW A19 = THE RENEWAL TEST THE LAB NEVER HAD.
  CLASS SWEEP (the brief's structural demand -- fix the CLASS, not the instance):
    42 silenced commands enumerated. Fixed where a silent failure produces a PHANTOM verdict
      (the backends' helm install -- IT FIRED FOR REAL on Rev 5's first from-scratch run:
      "dial tcp 140.82.121.3:443: connect: connection refused"; instead of a run of phantoms the
      gate stopped at 9/1 with helm's own error on screen -- A15/A16 restores, kubectl apply of
      edge.yaml and ingress-demo.yaml). JUSTIFIED and left silenced: rollout status/restart (each
      followed by an assertion on the thing it waited for), helm repo add/update, kubectl delete
      before create, the CoreDNS EXIT-trap restore (has DNSCHECK + a fatal abort).
      RULE LEFT BEHIND: a silenced command is acceptable ONLY when the NEXT assertion cannot pass
      if it failed.
    27 emptiness-blind controls enumerated. Two were LIVE DEFECTS (A15's assert_ne "", A16's
      grep -c '0/1' on an empty list) -- fixed. The rest already carry existence controls.
  A17's honest limit QUANTIFIED: ~759ms / ~834ms at full TCP rate. "approx 0s" = "shorter than a
    1s poll", NOT zero. Folded in.

REV 5's OWN DEFECTS, ALL FOUND BY RUNNING, NONE BY READING (this is the pattern, not an aside):
  1. A18b's canonical diff RED ON A HEALTHY SYSTEM on its first run -- yq terminates output with a
     newline, kubectl -o jsonpath does not: 3510 vs 3509 bytes, IDENTICAL config, passed: 105
     failed: 1. Risk #1, in the newest material, in the fix for a blocker.
  2. The renewal experiment WOULD HAVE PRESCRIBED THE DESTRUCTIVE METHOD WITH A GREEN TICK. It
     measured 0/10 fallback samples for delete-the-secret and concluded "safe". IT WAS A 240ms COIN
     FLIP: Pebble re-issues in 4909ms; the controller falls back to its self-signed default at
     5148ms. The DECOMPOSING CONTROL (delete with nothing able to re-issue) is the only reason the
     answer is right. AN EXPERIMENT THAT CANNOT SHOW THE FAILURE IS NOT EVIDENCE OF ITS ABSENCE.
     Real Let's Encrypt never wins a 5.1s race -> delete = an interstitial for (issuance - 5.1s).
     cmctl renew: 0/43 fallback, ~4.2s, structurally safe. THAT is what the plan prescribes.
  3. The resolve1 harness reported exit=1 on the HEALTHY case because dig was not yet in bin/.
     The control caught it; every verdict after it would have been meaningless.
  4. The ss snapshot chain, after the reorder, diffed against /tmp/ss-cut1.txt WHICH DID NOT EXIST
     YET (both tasks wrote ss-cut2). EXACTLY the "swapped instead of re-reasoned" defect the
     Self-Review tells a Rev 6 reviewer to hunt -- in my own new material. Found by grepping the
     write/read chain across tasks, not by reading.

REV 5 IS UNREVIEWED. Round 5 must target, in order:
  (a) THE ONE-WINDOW RESTRUCTURE (Tasks 6/7/8) -- newest material, and the newest material has
      produced the defect 9 times out of 9. Each brand-specific control was re-reasoned BY HAND.
      FIND THE ONE THAT WAS SWAPPED INSTEAD OF RE-REASONED. I found one myself (the ss chain);
      assume there is another. Start with every positive control that names an IP and ask whether
      it still holds AT ITS OWN T.
  (b) THE HASH PIN'S HOLE, WHICH REV 5 NAMES RATHER THAN HIDES: edit the lab file AND RE-RUN THE
      GATE -> the hash is re-blessed. A18c covers strategy/hostNetwork/runAsUser, A18b covers the
      config, A8 covers routing. FIND THE LAB-FILE MUTATION THAT SURVIVES ALL FOUR AND SHIPS.
  (c) A19 AGAINST SOMETHING THAT IS NOT PEBBLE. The 5148ms fallback is a measured LOCAL constant;
      prod is Let's Encrypt and the gap there is UNKNOWN. Go and make the number wrong.
  (d) THE WIRE, still -- and R-26 makes it WORSE than Rev 4 knew: the edge is stale by DEFAULT
      (subPath), not merely at risk of being stale. Design the check that catches a stale edge-lb
      pod BEFORE cutover.
  (e) EVERY REMAINING COUNTING CLAIM. FIVE false counts in four revisions. "exactly 3 haproxy
      lines", "5 backends", "the four routes", "106".
  (f) THE PROSE, AGAIN. It produced a blocker in Rev 1, a high in Rev 2, a high in Rev 3, and BOTH
      of Rev 4's worst findings (R-25, R-26) -- sentences asserting the OPPOSITE of the
      measurement ("this reads DNS": it did not; "a config change takes both brands down": it does
      nothing). PROSE HAS NO EXIT STATUS. Grep every claim about what a file/command/check ALREADY
      DOES, and open the thing.
  THE RULE ROUND 4 ADDS, narrower and harder than "make it fail on purpose": WHEN A CHECK COMPARES
  A AGAINST B, ASK WHAT A AND B ARE DERIVED FROM. If they share an ancestor, the check is blind to
  the ancestor -- and no amount of failing it on purpose against A or B will reveal that. Rev 4
  made its diff fail SIXTEEN ways and every one was a mutation of SHIP.
Task 10 (ETP / hostPort+hostIP / who really SNATs): NOT STARTED.
Task 11 (kube-vip): NOT STARTED -- a door to type: LoadBalancer, not a client-IP fix.
```
