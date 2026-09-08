#!/usr/bin/env python3
"""Build a human-readable PDF of the test run.

The Robot report is a pass/fail dashboard; this is the engineer's record: every
command sent to every router and Linux host during the run, with its output, in
the order it happened -- plus the device state the suite captured.

Source is results/output.xml, so the document reflects the run that actually
happened rather than a re-derivation of it.
"""
import os
import re
import sys
import textwrap
import xml.etree.ElementTree as ET
from datetime import datetime

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (BaseDocTemplate, Frame, KeepTogether, PageBreak,
                                PageTemplate, Paragraph, Preformatted, Spacer, Table,
                                TableStyle)

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(LAB, "results")
DEVICES = {"R1", "R2", "R3", "H1", "H2", "H3", "NMS"}
NMS_MARKER = "nms $ "     # tools/nms_lib.py logs every NMS command with this
ROUTERS = {"R1", "R2", "R3"}
WRAP = 108                      # characters per line of CLI text at 6.6pt Courier
MAX_OUTPUT_LINES = 14           # per command in the body; full text lives in results/

INK      = colors.HexColor("#121c26")
MUTED    = colors.HexColor("#5d6b7a")
RULE     = colors.HexColor("#d3dde4")
ENC      = colors.HexColor("#0b6e63")
CLEAR    = colors.HexColor("#8f5409")
FAILRED  = colors.HexColor("#a3231c")
SURFACE2 = colors.HexColor("#eef2f5")


# ---------------------------------------------------------------- extraction
def text_of(kw, sub_name):
    for sub in kw.findall("kw"):
        if sub.get("name") == sub_name:
            msgs = [m.text for m in sub.findall("msg") if m.text]
            if msgs:
                return msgs[0]
    return None


def walk(node, alias, out):
    """Depth-first over Robot's body elements, tracking which device is in scope.

    The alias comes either from a literal argument (Run On    R1    ...) or, inside
    a FOR, from the iteration variable that Robot records on each <iter>. Missing
    the <for>/<iter> elements silently drops every looped command, so they are
    handled explicitly rather than relying on findall('kw').
    """
    for child in node:
        tag = child.tag
        if tag == "kw":
            args = [a.text for a in child.findall("arg")]
            here = next((v for v in args if v in DEVICES), alias)
            if child.get("name") in ("Run On", "Run On Host"):
                cmd = text_of(child, "Write")
                res = text_of(child, "Read Until Prompt")
                if cmd:
                    out.append((here or "?", cmd.strip(), (res or "").strip()))
            # Commands run on the NMS come from a Python library rather than
            # SSHLibrary's Write, so they are logged with a marker instead.
            for msg in child.findall("msg"):
                if msg.text and msg.text.startswith(NMS_MARKER):
                    body = msg.text[len(NMS_MARKER):]
                    cmd, _, res = body.partition("\n")
                    out.append(("NMS", cmd.strip(), res.strip()))
            walk(child, here, out)
        elif tag == "iter":
            here = alias
            for v in child.findall("var"):
                if v.text and v.text.strip() in DEVICES:
                    here = v.text.strip()
            walk(child, here, out)
        elif tag in ("for", "while", "if", "try", "branch", "group"):
            walk(child, alias, out)


# How each assertion keyword reads as an acceptance criterion. The arguments in
# output.xml are the *source* ones -- "${out}" stays symbolic while the expected
# literal survives -- so the criterion states what was required, not what a
# variable happened to hold.
CRITERIA = {
    "Should Contain":            "output contains {1}",
    "Should Not Contain":        "output does not contain {1}",
    "Should Be Equal":           "{0} equals {1}",
    "Should Be Equal As Integers": "{0} equals {1}",
    "Should Be Equal As Strings": "{0} equals {1}",
    "Should Not Be Equal":       "{0} differs from {1}",
    "Should Not Be Equal As Integers": "{0} differs from {1}",
    "Should Match Regexp":       "output matches {1}",
    "Should Not Match Regexp":   "output does not match {1}",
    "Should Match":              "output matches {1}",
    "Should Be True":            "{0} holds",
    "Should Not Be True":        "{0} does not hold",
    "Should Be Empty":           "{0} is empty",
    "Should Not Be Empty":       "{0} is not empty",
    "Should Start With":         "{0} starts with {1}",
    "Should End With":           "{0} ends with {1}",
    "Length Should Be":          "{0} has exactly {1} entries",
    "Lists Should Be Equal":     "{0} matches {1} exactly",
    "List Should Contain Value": "{0} contains {1}",
    "Dictionary Should Contain Key": "{0} contains the key {1}",
}
ASSERTION_HINT = ("Should", "Length Should", "Lists Should", "List Should",
                  "Dictionary Should")


def _short(v, limit=90):
    """Collapse whitespace and undo Robot's escaping for display.

    A regexp written as "\\d+" in a .robot file means a literal "\\d+", and
    output.xml stores the source form -- so printing it raw shows the reader
    twice the backslashes the pattern actually has.
    """
    v = " ".join((v or "").split()).replace("\\\\", "\\")
    return v if len(v) <= limit else v[:limit - 1] + "\u2026"


def criteria_of(test):
    """The acceptance criteria a test actually applied, in order.

    Read from the assertion keywords rather than written by hand, so the list
    cannot drift from what the run enforced. Repeats are collapsed: a criterion
    inside a FOR loop over three routers is one criterion checked three times,
    not three different ones.
    """
    seen, out = {}, []
    for kw in test.iter("kw"):
        name = kw.get("name") or ""
        if not name.startswith(ASSERTION_HINT):
            continue
        args = [a.text or "" for a in kw.findall("arg")]
        template = CRITERIA.get(name)
        if template:
            try:
                text = template.format(*[f"<b>{esc(_short(a))}</b>" for a in args[:2]])
            except IndexError:
                text = f"{name} {esc(_short(' '.join(args[:2])))}"
        else:
            text = f"{esc(name)} {esc(_short(' '.join(args[:2])))}"
        # a trailing argument that reads as prose is the author's own statement
        # of why the check matters; it says more than the mechanical form
        why = ""
        for a in args[2:]:
            a = (a or "").strip()
            if a and " " in a and not a.startswith("$"):
                why = _short(a, 150)
                break
        key = (text, why)
        if key in seen:
            seen[key] += 1
        else:
            seen[key] = 1
            out.append(key)
    return [(t, w, seen[(t, w)]) for t, w in out]


def fixture_of(node, kind):
    """The SETUP or TEARDOWN keyword attached to a suite or a test, if any."""
    for kw in node.findall("kw"):
        if (kw.get("type") or "").upper() == kind:
            name = kw.get("name") or ""
            args = [a.text or "" for a in kw.findall("arg")]
            # "Run Keywords" carries the real work in its arguments
            if name == "Run Keywords":
                parts = [a for a in args if a and a != "AND"]
                return ", ".join(parts)
            return name + (f" ({', '.join(args)})" if args else "")
    return ""


def collect(xml_path):
    root = ET.parse(xml_path).getroot()
    top = root.find("suite")
    suites = []
    for suite_index, s in enumerate(top.findall("suite"), start=1):
        # the suite's own number where it has one ("04 Ipsec" -> 4), so the
        # numbering in the report matches the file names on disk
        lead = s.get("name", "").split()[0]
        section = int(lead) if lead.isdigit() else suite_index
        suite_setup = fixture_of(s, "SETUP")
        suite_teardown = fixture_of(s, "TEARDOWN")
        tests = []
        for test_index, t in enumerate(s.findall("test"), start=1):
            st = t.find("status")
            doc = t.find("doc")
            cmds = []
            walk(t, None, cmds)
            tests.append({
                "number": f"{section}.{test_index:02d}",
                "setup": fixture_of(t, "SETUP") or suite_setup,
                "setup_scope": "test" if fixture_of(t, "SETUP") else "suite",
                "teardown": fixture_of(t, "TEARDOWN") or suite_teardown,
                "teardown_scope": "test" if fixture_of(t, "TEARDOWN") else "suite",
                "criteria": criteria_of(t),
                "name": t.get("name"),
                "status": st.get("status"),
                "elapsed": float(st.get("elapsed") or 0),
                "doc": (doc.text or "").strip() if doc is not None else "",
                "message": (st.text or "").strip(),
                "commands": cmds,
            })
        suites.append({"name": s.get("name"), "section": section, "tests": tests})
    st = top.find("status")
    meta = {"start": st.get("start"), "elapsed": float(st.get("elapsed") or 0)}
    return suites, meta


# ------------------------------------------------------------------- styling
def styles():
    ss = getSampleStyleSheet()
    def add(name, **kw):
        ss.add(ParagraphStyle(name=name, **kw))
    add("CoverTitle", fontName="Helvetica-Bold", fontSize=27, leading=31, textColor=INK, spaceAfter=6)
    add("CoverSub", fontName="Helvetica", fontSize=12.5, leading=17, textColor=MUTED, spaceAfter=18)
    add("H1x", fontName="Helvetica-Bold", fontSize=16, leading=20, textColor=INK,
        spaceBefore=16, spaceAfter=8)
    add("H2x", fontName="Helvetica-Bold", fontSize=11.5, leading=15, textColor=INK,
        spaceBefore=12, spaceAfter=3)
    add("Body", fontName="Helvetica", fontSize=9.5, leading=13.5, textColor=INK, alignment=TA_LEFT)
    add("Doc", fontName="Helvetica-Oblique", fontSize=8.8, leading=12, textColor=MUTED, spaceAfter=5)
    add("Meta", fontName="Helvetica", fontSize=8.5, leading=11.5, textColor=MUTED)
    add("CmdLine", fontName="Courier-Bold", fontSize=7.4, leading=9.6, textColor=INK)
    add("Fail", fontName="Helvetica-Bold", fontSize=9, leading=12, textColor=FAILRED)
    ss.add(ParagraphStyle("Section", parent=ss["Body"], fontSize=8.5, leading=11.5,
                          spaceBefore=5, spaceAfter=1, textColor=INK))
    ss.add(ParagraphStyle("Criterion", parent=ss["Body"], fontSize=8.5, leading=11.5,
                          leftIndent=12, spaceBefore=0, spaceAfter=1, textColor=INK))
    return ss


def cli_block(text, color=INK, indent=8):
    lines = []
    for raw in text.splitlines():
        raw = raw.rstrip()
        lines.extend(textwrap.wrap(raw, WRAP) or [""])
    body = "\n".join(lines) if lines else "(no output)"
    st = ParagraphStyle("cli", fontName="Courier", fontSize=6.6, leading=8.4,
                        textColor=color, leftIndent=indent)
    return Preformatted(body, st)


def device_colour(dev):
    return ENC if dev in ROUTERS else CLEAR


# -------------------------------------------------------------------- render
def build(suites, meta, out_path):
    ss = styles()
    doc = BaseDocTemplate(out_path, pagesize=letter,
                          leftMargin=0.62 * inch, rightMargin=0.62 * inch,
                          topMargin=0.62 * inch, bottomMargin=0.68 * inch,
                          title="C8000V IPsec Testbed - Test Evidence",
                          author="c8000v-lab")
    frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id="body")

    def furniture(canvas, _doc):
        canvas.saveState()
        canvas.setFont("Helvetica", 7.5)
        canvas.setFillColor(MUTED)
        canvas.drawString(doc.leftMargin, 0.42 * inch, "C8000V IPsec Testbed - test evidence")
        canvas.drawRightString(letter[0] - doc.rightMargin, 0.42 * inch, f"page {canvas.getPageNumber()}")
        canvas.setStrokeColor(RULE)
        canvas.line(doc.leftMargin, 0.56 * inch, letter[0] - doc.rightMargin, 0.56 * inch)
        canvas.restoreState()

    doc.addPageTemplates([PageTemplate(id="all", frames=[frame], onPage=furniture)])

    total = sum(len(s["tests"]) for s in suites)
    passed = sum(1 for s in suites for t in s["tests"] if t["status"] == "PASS")
    ncmd = sum(len(t["commands"]) for s in suites for t in s["tests"])
    started = meta["start"]
    try:
        started = datetime.fromisoformat(meta["start"]).strftime("%d %B %Y, %H:%M UTC")
    except Exception:
        pass

    story = []

    # ---- cover -------------------------------------------------------------
    story.append(Paragraph("C8000V IPsec Testbed", ss["CoverTitle"]))
    story.append(Paragraph("Test evidence &mdash; every command run on every device", ss["CoverSub"]))

    summary = [
        ["Run started", started],
        ["Duration", f"{meta['elapsed']/60:.1f} minutes"],
        ["Result", f"{passed} of {total} tests passed" + ("" if passed == total else "  — SEE FAILURES")],
        ["Suites", str(len(suites))],
        ["Device commands recorded", str(ncmd)],
        ["Topology", "hub-and-spoke: R1 hub, R2 and R3 spokes, one Linux host per router"],
        ["Encryption", "IKEv2 + static VTI, ESP-AES-256 / SHA256, one tunnel per spoke"],
        ["Routing", "eBGP inside the tunnels; AS 65001 hub, AS 65002 / 65003 spokes"],
    ]
    t = Table(summary, colWidths=[1.85 * inch, doc.width - 1.85 * inch])
    t.setStyle(TableStyle([
        ("FONT", (0, 0), (0, -1), "Helvetica-Bold", 9),
        ("FONT", (1, 0), (1, -1), "Helvetica", 9),
        ("TEXTCOLOR", (0, 0), (0, -1), MUTED),
        ("TEXTCOLOR", (1, 0), (1, -1), INK),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 6),
        ("LINEBELOW", (0, 0), (-1, -2), 0.4, RULE),
    ]))
    story.append(t)
    story.append(Spacer(1, 20))

    story.append(Paragraph("Suite results", ss["H1x"]))
    rows = [["Suite", "Tests", "Passed", "Failed", "Commands", "Time"]]
    for s in suites:
        ts = s["tests"]
        f = sum(1 for x in ts if x["status"] != "PASS")
        rows.append([s["name"], str(len(ts)), str(len(ts) - f), str(f),
                     str(sum(len(x["commands"]) for x in ts)),
                     f"{sum(x['elapsed'] for x in ts):.0f}s"])
    t = Table(rows, colWidths=[doc.width - 4.5 * inch, 0.8 * inch, 0.85 * inch, 0.8 * inch, 1.15 * inch, 0.9 * inch])
    style = [
        ("FONT", (0, 0), (-1, 0), "Helvetica-Bold", 8),
        ("TEXTCOLOR", (0, 0), (-1, 0), MUTED),
        ("BACKGROUND", (0, 0), (-1, 0), SURFACE2),
        ("FONT", (0, 1), (-1, -1), "Helvetica", 9),
        ("ALIGN", (1, 0), (-1, -1), "RIGHT"),
        ("LINEBELOW", (0, 0), (-1, -1), 0.4, RULE),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]
    for i, s in enumerate(suites, start=1):
        if any(x["status"] != "PASS" for x in s["tests"]):
            style.append(("TEXTCOLOR", (3, i), (3, i), FAILRED))
    t.setStyle(TableStyle(style))
    story.append(t)
    story.append(Spacer(1, 10))
    story.append(Paragraph(
        "Each test below lists the commands it issued, in order, with the device that ran them "
        "and the output it returned. Router commands are marked in teal, Linux host commands in "
        "amber. Long output is trimmed to the first "
        f"{MAX_OUTPUT_LINES} lines; complete captures are in <font face='Courier'>results/</font>.",
        ss["Body"]))
    story.append(PageBreak())

    # ---- per suite ---------------------------------------------------------
    for s in suites:
        story.append(Paragraph(s["name"], ss["H1x"]))
        for t_ in s["tests"]:
            head = []
            mark = "PASS" if t_["status"] == "PASS" else "FAIL"
            colour = "#0b6e63" if mark == "PASS" else "#a3231c"
            head.append(Paragraph(
                f'<font color="#5d6b7a"><b>{t_["number"]}</b></font> &nbsp; '
                f'<font color="{colour}"><b>{mark}</b></font> &nbsp; {t_["name"]} '
                f'<font color="#5d6b7a" size="8">({t_["elapsed"]:.1f}s, {len(t_["commands"])} commands)</font>',
                ss["H2x"]))
            if t_["doc"]:
                head.append(Paragraph(t_["doc"].replace("\n", " "), ss["Doc"]))
            if t_["status"] != "PASS" and t_["message"]:
                head.append(Paragraph("FAILURE: " + t_["message"].splitlines()[0][:300], ss["Fail"]))
            story.append(KeepTogether(head))

            # ---- setup ------------------------------------------------------
            if t_["setup"]:
                scope = "suite" if t_["setup_scope"] == "suite" else "this test"
                story.append(Paragraph(
                    f'<b>Setup</b> &nbsp;<font color="#5d6b7a" size="8">({scope})</font>&nbsp; '
                    f'{esc(t_["setup"])}', ss["Section"]))
            else:
                story.append(Paragraph(
                    "<b>Setup</b> &nbsp; none — the test runs against the lab as left "
                    "by the preceding tests", ss["Section"]))

            # ---- acceptance criteria ---------------------------------------
            if t_["criteria"]:
                story.append(Paragraph("<b>Acceptance criteria</b>", ss["Section"]))
                for text, why, n in t_["criteria"]:
                    times = f' <font color="#5d6b7a" size="8">(checked {n}&#215;)</font>' if n > 1 else ""
                    line = f"&#8226; {text}{times}"
                    if why:
                        line += f'<br/><font color="#5d6b7a" size="8">{esc(why)}</font>'
                    story.append(Paragraph(line, ss["Criterion"]))
            else:
                story.append(Paragraph(
                    "<b>Acceptance criteria</b> &nbsp; none asserted directly — this test "
                    "captures state for the record, and is checked by the tests that read it",
                    ss["Section"]))

            # ---- how it was checked ----------------------------------------
            if not t_["commands"]:
                story.append(Paragraph(
                    "<b>How it was checked</b> &nbsp; no device commands of its own; the "
                    "assertion read output captured earlier in the suite", ss["Section"]))
                _teardown(story, ss, t_)
                story.append(Spacer(1, 9))
                continue
            story.append(Paragraph("<b>How it was checked</b>", ss["Section"]))

            for dev, cmd, out in t_["commands"]:
                col = device_colour(dev)
                story.append(Spacer(1, 3))
                story.append(Paragraph(
                    f'<font color="#{col.hexval()[2:]}"><b>{dev}</b></font> '
                    f'<font face="Courier"><b>{esc(cmd)}</b></font>', ss["CmdLine"]))
                lines = out.splitlines()
                shown = lines[:MAX_OUTPUT_LINES]
                body = "\n".join(shown)
                if len(lines) > MAX_OUTPUT_LINES:
                    body += f"\n... {len(lines) - MAX_OUTPUT_LINES} more lines"
                story.append(cli_block(body or "(no output)", MUTED))
            _teardown(story, ss, t_)
            story.append(Spacer(1, 9))
        story.append(PageBreak())

    # ---- appendix: captured device state -----------------------------------
    story.append(Paragraph("Appendix &mdash; captured device state", ss["H1x"]))
    story.append(Paragraph(
        "Written by suite <i>05 Capture State</i> during the run. Routing tables and "
        "protocol state first, then what the NMS sees for each router -- polled over "
        "SNMPv3, and received as syslog and traps -- then the full running "
        "configuration of each router.",
        ss["Body"]))
    order = (["R1-ip-route", "R2-ip-route", "R3-ip-route",
              "R1-bgp-summary", "R2-bgp-summary", "R3-bgp-summary",
              "R1-bgp-table", "R2-bgp-table", "R3-bgp-table",
              "R1-crypto-ikev2-sa", "R2-crypto-ikev2-sa", "R3-crypto-ikev2-sa"]
             + [f"{h}-{w}" for h in ("H1", "H2", "H3") for w in ("ip-addr", "ip-route")]
             + ["nms-network", "nms-snmp-version", "nms-collectors",
                "nms-collector-files"]
             + [f"nms-{r}-syslog" for r in ("R1", "R2", "R3")]
             + ["nms-snmptrapd"]
             + [f"nms-{r}-snmp-{w}" for r in ("R1", "R2", "R3")
                for w in ("system", "interfaces")]
             + ["R1-running-config", "R2-running-config", "R3-running-config"])
    for name in order:
        path = os.path.join(RESULTS, name + ".txt")
        if not os.path.exists(path):
            continue
        dev = name.split("-")[0]
        what = name.split("-", 1)[1].replace("-", " ")
        if name.startswith("nms-") and name.split("-")[1] in ROUTERS:
            dev = "NMS"
            kind, rest = name.split("-")[2], what.split(" ", 1)
            what = (f"{name.split('-')[1]} syslog received" if kind == "syslog"
                    else f"{name.split('-')[1]} polled over SNMPv3: {rest[1]}")
        elif name.startswith("nms-"):
            dev = "NMS"
        story.append(Paragraph(f"{dev} &mdash; {what}", ss["H2x"]))
        with open(path, encoding="utf-8", errors="replace") as fh:
            story.append(cli_block(fh.read().strip(), MUTED, indent=4))
        story.append(Spacer(1, 8))

    doc.build(story)
    return out_path, total, passed, ncmd


def _teardown(story, ss, t_):
    """Teardown is only worth a line when there is one -- most tests leave the
    lab exactly as they found it and say so, so an absent teardown is stated
    rather than left ambiguous."""
    if t_["teardown"]:
        scope = "suite" if t_["teardown_scope"] == "suite" else "this test"
        story.append(Paragraph(
            f'<b>Teardown</b> &nbsp;<font color="#5d6b7a" size="8">({scope})</font>&nbsp; '
            f'{esc(t_["teardown"])}', ss["Section"]))
    else:
        story.append(Paragraph(
            "<b>Teardown</b> &nbsp; none — the test changed nothing it needed to undo",
            ss["Section"]))


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


if __name__ == "__main__":
    xml_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(RESULTS, "output.xml")
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(RESULTS, "test-evidence.pdf")
    suites, meta = collect(xml_path)
    path, total, passed, ncmd = build(suites, meta, out)
    print(f"wrote {path}")
    print(f"  {passed}/{total} tests, {ncmd} device commands, {len(suites)} suites")
