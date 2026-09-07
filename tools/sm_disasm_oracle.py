#!/usr/bin/env python3
"""Audit the generator's instruction boundaries against a hand-made disassembly.

The window relocation rewrites operands of the instructions it believes in,
and a wrong belief is a corrupted byte: every patch from v66 to v68 carried
`STA $2177` (the APU mailbox mirror) where stock has `STA $2117`, because
the static coverage extension took the immediate of `AND #$FC` before it as
`JSR ($178D,X)`. A session found that at the fourth site it reached. This
tool checks all of them at once, against the InsaneFirebat/sm_disassembly
sources (P.JBoy's bank logs, assemblable), whose every instruction line
carries its address in a trailing `;8XXXXX;` comment.

Usage:
    sm_disasm_oracle.py <sm_disassembly/src> <prefix>   (prefix.usage + prefix.cov from --cov-out)

Reports, per map (the profiled union, then its static extension):
    interior  — opcode flags at bytes the disassembly places INSIDE an instruction
    data      — opcode flags at bytes the disassembly places in data
    unknown   — opcode flags at bytes the disassembly does not list (padding, unassembled)
and, for information, how many of the disassembly's instruction starts the
generator's maps know. The generator must keep working without any
disassembly; this is a check, not a dependency.
"""
import glob
import os
import re
import sys

FLAG_OPCODE = 0x10
FLAG_EXEC = 0x20
ADDR_RE = re.compile(r";([0-9A-F]{6});")   # the address comment may carry more comment after it
DATA_TOKENS = ("DB", "DW", "DL", "DD", "FILL", "PAD", "INCBIN", "TABLE", "%")


MNEMONIC_RE = re.compile(r"^[A-Z]{3}(\.[BWL])?$")


def data_len(body):
    """Bytes a data directive emits, or None when it cannot be counted."""
    tok, _, rest = body.partition(" ")
    tok = tok.upper()
    size = {"DB": 1, "DW": 2, "DL": 3, "DD": 4}.get(tok)
    if size is None:
        return None
    if '"' in rest or "'" in rest:
        return None
    items = [x for x in rest.split(",") if x.strip()]
    return size * len(items)


def load_disassembly(src_dir):
    """Instruction-start map and data-byte set, by CPU address (bank $80+ form).

    Most lines carry their address in a trailing `;8XXXXX;` comment; lines
    whose operand is a label do not, and are placed by walking forward from
    the last addressed line (instruction lengths from the mnemonic, data
    lengths from the directive). An addressed line resyncs, and a mismatch
    there counts as a placement error (reported by --stats).
    """
    inst = {}
    data = set()
    stats = {"mismatch": 0, "inferred": 0}
    for path in sorted(glob.glob(os.path.join(src_dir, "bank_*.asm"))):
        cur = None
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                raw = line.rstrip("\n")
                m = ADDR_RE.search(raw)
                body = (raw[: m.start()] if m else raw.split(";")[0]).strip()
                if not body or body.startswith(";"):
                    continue
                # anonymous labels share the line with the instruction
                while body and body.split(None, 1)[0].strip("+-") == "":
                    body = body.split(None, 1)[1].strip() if " " in body else ""
                if not body:
                    continue
                tok = body.split()[0]
                up = tok.upper()
                if m:
                    addr = int(m.group(1), 16)
                    if cur is not None and cur != addr and not up.startswith(DATA_TOKENS):
                        stats["mismatch"] += 1
                    cur = addr
                elif cur is None:
                    continue
                elif up in ("ORG", "BANK", "BASE", "INCSRC", "INCBIN", "FILLBYTE", "PADBYTE", "FILL", "PAD", "TABLE", "CLEARTABLE") or up.startswith("%") or up.startswith("!") or tok.endswith(":") or tok.startswith("."):
                    if up in ("ORG", "BANK", "BASE", "INCSRC", "INCBIN", "FILL", "PAD") or up.startswith("%"):
                        cur = None  # unknown size or a new origin: wait for the next addressed line
                    continue
                addr = cur
                if up.startswith(DATA_TOKENS):
                    n = data_len(body)
                    if n is None:
                        cur = None
                        if m:
                            data.add(addr)
                        continue
                    for k in range(n):
                        data.add(addr + k)
                    cur = addr + n
                elif MNEMONIC_RE.match(up):
                    inst[addr] = body
                    if not m:
                        stats["inferred"] += 1
                    cur = addr + instr_len(body)
                else:
                    cur = None  # a directive or label form this parser does not size
    load_disassembly.stats = stats
    return inst, data


def instr_len(mnemonic_line):
    """Best-effort instruction length from the asar mnemonic suffix and operand."""
    body = mnemonic_line.split(";")[0].strip()
    # asar anonymous labels (`+`, `--`) share the line with the instruction
    while body and body.split(None, 1)[0].strip("+-") == "":
        body = body.split(None, 1)[1].strip() if " " in body else ""
    parts = body.split(None, 1)
    mn = parts[0].upper()
    operand = parts[1].strip() if len(parts) > 1 else ""
    base = mn.split(".")[0]
    suffix = mn.split(".")[1] if "." in mn else ""
    if not operand:
        return 1
    if base in ("BRL", "PER"):
        return 3
    if base in ("BCC", "BCS", "BEQ", "BNE", "BMI", "BPL", "BVC", "BVS", "BRA"):
        return 2
    if base in ("JML", "JSL"):
        # JML [abs] (indirect long, $DC) is three bytes; JML/JSL long are four
        return 3 if operand.startswith(("[", "(")) else 4
    if suffix == "L":
        return 4
    if base in ("MVN", "MVP"):
        return 3
    if base in ("PEA", "JMP", "JSR") and suffix != "B":
        return 3
    if operand.startswith("#"):
        # asar's .B/.W tell the width of an immediate
        if suffix == "W":
            return 3
        if suffix == "B":
            return 2
        return 2 if base in ("SEP", "REP", "COP", "BRK", "WDM") else 3
    if suffix == "B":
        return 2
    if suffix == "W":
        return 3
    if operand.startswith("$"):
        hexpart = operand[1:].split(",")[0].split(")")[0].split("]")[0]
        return 2 if len(hexpart) <= 2 else (4 if len(hexpart) >= 6 else 3)
    return 3


def interiors(inst):
    """Bytes inside an instruction (not its first byte)."""
    inner = set()
    for addr, line in inst.items():
        n = instr_len(line)
        for k in range(1, n):
            inner.add(addr + k)
    return inner


def audit(name, cov, inst, inner, data):
    n_interior = n_data = n_unknown = n_known = 0
    examples = {"interior": [], "data": [], "unknown": []}
    for bank in range(0x80, 0xE0):
        for a16 in range(0x8000, 0x10000):
            cpu = (bank << 16) | a16
            lo = ((bank & 0x7F) << 16) | a16
            fl = cov[cpu] | cov[lo]
            if not (fl & FLAG_OPCODE):
                continue
            if cpu in inst:
                n_known += 1
            elif cpu in inner:
                n_interior += 1
                if len(examples["interior"]) < 12:
                    examples["interior"].append("%06X" % cpu)
            elif cpu in data:
                n_data += 1
                if len(examples["data"]) < 12:
                    examples["data"].append("%06X" % cpu)
            else:
                n_unknown += 1
                if len(examples["unknown"]) < 12:
                    examples["unknown"].append("%06X" % cpu)
    total = n_known + n_interior + n_data + n_unknown
    print(f"{name}: {total} opcode flags — {n_known} on disassembly instruction starts, "
          f"{n_interior} INSIDE an instruction, {n_data} on data, {n_unknown} outside the disassembly")
    for kind in ("interior", "data", "unknown"):
        if examples[kind]:
            print(f"  {kind}: {' '.join(examples[kind])}")
    return n_interior, n_data


MAP_START = 0x10
MAP_INTERIOR = 0x20
MAP_DATA = 0x80
MAP_M_KNOWN = 0x04   # this immediate's accumulator width is known: MAP_M8 says 8-bit
MAP_X_KNOWN = 0x08   # this immediate's index width is known: MAP_X8 says 8-bit
MAP_M8 = 0x02
MAP_X8 = 0x01


def export_code_map(inst, data, path):
    """One flag byte per CPU address (16 MiB, bank $80+ form; the generator
    ORs the $00+ mirror itself): instruction start / interior / data, and for
    an immediate the operand width the assembler suffix names (`.B` = 8-bit,
    `.W` = 16-bit): the width flags a static walk needs and cannot infer."""
    m = bytearray(0x1000000)
    # The disassembly accounts for every byte of the ROM: what it does not
    # write as an instruction is data (tables behind macros, included
    # binaries, padding). Default the covered banks to data, then mark.
    banks = {a >> 16 for a in inst}
    for b in banks:
        for a in range((b << 16) | 0x8000, (b << 16) | 0x10000):
            m[a] = MAP_DATA
    for a in data:
        m[a] |= MAP_DATA
    for a, line in inst.items():
        m[a] = MAP_START
        body = line.split(";")[0].strip()
        while body and body.split(None, 1)[0].strip("+-") == "":
            body = body.split(None, 1)[1].strip() if " " in body else ""
        parts = body.split(None, 1)
        mn = parts[0].upper()
        operand = parts[1].strip() if len(parts) > 1 else ""
        base = mn.split(".")[0]
        suffix = mn.split(".")[1] if "." in mn else ""
        if operand.startswith("#") and base not in ("SEP", "REP", "COP", "BRK", "WDM"):
            imm8 = suffix == "B"
            imm16 = suffix == "W"
            if imm8 or imm16:
                if base in ("LDX", "LDY", "CPX", "CPY"):
                    m[a] |= MAP_X_KNOWN | (MAP_X8 if imm8 else 0)
                else:
                    m[a] |= MAP_M_KNOWN | (MAP_M8 if imm8 else 0)
        for k in range(1, instr_len(line)):
            m[a + k] = MAP_INTERIOR
    with open(path, "wb") as f:
        f.write(m)
    print(f"wrote {path}: {len(inst)} starts, {len(data)} data bytes")


def main():
    if len(sys.argv) == 4 and sys.argv[2] == "--export":
        inst, data = load_disassembly(sys.argv[1])
        export_code_map(inst, data, sys.argv[3])
        return
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    src_dir, prefix = sys.argv[1], sys.argv[2]
    inst, data = load_disassembly(src_dir)
    inner = interiors(inst)
    print(f"disassembly: {len(inst)} instruction starts, {len(inner)} interior bytes, {len(data)} data lines")
    bad = 0
    for suffix, name in ((".usage", "profiled union"), (".cov", "static extension")):
        path = prefix + suffix
        if not os.path.exists(path):
            print(f"{name}: {path} missing")
            continue
        with open(path, "rb") as f:
            cov = f.read()
        if len(cov) < 0x1000000:
            print(f"{name}: {path} is {len(cov)} bytes, expected a 16 MiB map")
            continue
        n_interior, n_data = audit(name, cov, inst, inner, data)
        bad += n_interior + n_data
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
