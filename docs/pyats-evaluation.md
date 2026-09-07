# pyATS + Genie: evaluation and decision

**Date:** 6 September 2026
**Question:** should the Robot suites move to pyATS (Unicon connections, Genie parsers)?
**Decision:** adopt selectively, not wholesale. Details and evidence below.

## What was tested

A working port of `tests/04_ipsec.robot` lives in `tests_pyats/04_ipsec_genie.robot`,
built on `tools/genie_keywords.py` and the generated inventory `testbed/lab.yaml`.
It passes 5/5 against the live lab. Nothing in `tests/` was modified.

## What Unicon fixes

Three connection-layer bugs cost more time than anything else in this lab. Unicon
was tested against all three:

| failure mode | hand-rolled driver | Unicon |
|---|---|---|
| first prompt after login arrives with no leading newline | all 11 tests of the day failed | handled |
| `->` in `show monitor capture` output matched the prompt regex | silent desync; one run stalled for over an hour | handled, stayed in sync |
| `delete child entries? [no]:` confirmation | hung until timeout; needed a custom `run_confirm` | answered automatically |

## What Genie fixes

Parsers exist and work on real C8000V output for everything this suite reads:
`show crypto ipsec sa`, `show ip nat translations`, `show ntp associations`,
`show ip route`, `show ip interface brief`, `show ip bgp summary`.

| assertion | hand-rolled | Genie |
|---|---|---|
| ESP counters | regex + sum; two bugs (`#pkts` parsed as a Robot comment, `\d` escaping collapsed) | `ident.<n>.pkts_encaps` as an int |
| tunnel up/up | regex including the Method column; **broke twice** as config moved TFTP -> NVRAM | `status` / `protocol` fields |
| route via tunnel | substring search for `Tunnel0` | `outgoing_interface` field |
| negotiated transform | substring on raw text | `outbound_esp_sas.spi.<spi>.transform` |

The Method-column case is the strongest argument: that regex broke twice for
reasons unrelated to what the test was checking. Structured access makes that
class of failure impossible.

## What does not move

- **Packet-capture assertions.** Genie parses capture *configuration*, not buffer
  contents. Proving no cleartext appears on the wire is the most valuable thing
  this suite does, and it stays hand-rolled.
- **Throughput generation.** `dd | nc` on the cirros hosts; pyATS adds nothing.
- **Host-side shell.** Addressing and routes on the Linux hosts.

## Costs, honestly

- `genie.libs.robot` provides `parse` and `learn` but **no `execute`**. Anything
  imperative -- a ping, a clear, a config push -- needs a wrapper. That is
  `tools/genie_keywords.py`, ~70 lines.
- Navigating Genie's nested dicts inside Robot's `Evaluate` is *worse* than the
  regexes it replaces. The dict-walking has to live in Python for the suite to
  stay readable.
- Installation on Python 3.14 took three attempts and required `gcc` and
  `python3.14-dev`: genie pins a `ruamel.yaml.clib` with no cp314 wheel. The
  dependency count went from 4 small pure-Python packages to roughly 100,
  including IxNetwork and VMware clients this lab will never use.
- Parser structures must be discovered from real output, not assumed. The
  transform path is `outbound_esp_sas.spi.<spi>.transform`, not the
  `outbound.esp_sas` that seemed natural.

## Recommendation

1. **Keep `testbed/lab.yaml`** regardless. It replaces ~45 `--variable` arguments
   in `run-tests.sh` that broke once already, and it is inventory rather than
   command-line plumbing. Regenerate with `tools/make_testbed.py` whenever
   `lab.env` changes.
2. **Do not port the 14 passing suites.** 101 tests pass; rewriting them churns
   working code for no new coverage and would leave two idioms half-applied.
3. **Reach for pyATS when writing something new**, or when a hand-rolled parser
   breaks again. `tests_pyats/04_ipsec_genie.robot` is the worked reference.
4. **If adoption ever widens**, pin the lab to Python 3.12 or 3.13. Network
   tooling lags interpreter releases and 3.14 needed hand-holding.
