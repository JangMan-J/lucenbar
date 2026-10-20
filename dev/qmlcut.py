#!/usr/bin/env python3
"""Remove top-level-ish QML members by regex on their first line.

usage: qmlcut.py FILE INDENT 'regex1' 'regex2' ...
A member = optional leading comment lines at the same indent + first line +
its brace-balanced body or its more-indented continuation lines + one
trailing blank line (if the removal would leave two blanks).
"""
import re, sys

def strip_strings(line):
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', line)

def cut(text, indent, pattern):
    lines = text.split("\n")
    pad = " " * indent
    rx = re.compile(pattern)
    out, i, removed = [], 0, 0
    while i < len(lines):
        line = lines[i]
        if line.startswith(pad) and not line.startswith(pad + " ") and rx.search(line):
            # drop preceding comment lines at same indent
            while out and out[-1].startswith(pad + "//"):
                out.pop()
            s = strip_strings(line)
            depth = s.count("{") - s.count("}")
            j = i
            if depth > 0:
                while depth > 0:
                    j += 1
                    s = strip_strings(lines[j])
                    depth += s.count("{") - s.count("}")
            else:
                # continuation lines: more indented than the member
                while j + 1 < len(lines) and lines[j + 1].startswith(pad + " ") and lines[j + 1].strip():
                    j += 1
            i = j + 1
            removed += 1
            # collapse a blank line that follows if previous is blank
            if i < len(lines) and lines[i].strip() == "" and out and out[-1].strip() == "":
                i += 1
            continue
        out.append(line)
        i += 1
    return "\n".join(out), removed

if __name__ == "__main__":
    path, indent = sys.argv[1], int(sys.argv[2])
    text = open(path).read()
    total = []
    for pat in sys.argv[3:]:
        text, n = cut(text, indent, pat)
        total.append((pat, n))
    open(path, "w").write(text)
    for pat, n in total:
        print(f"{n:3d}  {pat}")
