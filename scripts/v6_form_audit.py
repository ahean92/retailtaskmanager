"""v6 audit for platform 6.2 form rules:
1) property draws with the same sid added to one form twice (6.2: "was already defined")
2) same object name declared with different classes in extensions of one form
Output includes file:line, no collapsing.
"""
import re, glob, collections

OPT_WORDS = {"READONLY", "TOOLBAR", "PANEL", "GRID", "EDIT", "NEWSESSION", "DELETE", "NEW",
             "IN", "SHOWIF", "READONLYIF", "HEADER", "IMAGE", "EXTID", "CHARWIDTH", "DRAW", "BEFORE", "AFTER"}

def strip_comment(line):
    return line.split("//", 1)[0]

def parse_props(lines):
    out = []
    for text in lines:
        m = re.match(r"\s*PROPERTIES\s*(?:\(\s*([A-Za-z0-9_,\s]*)\))?(.*)$", text)
        if not m:
            continue
        ctx = [a.strip() for a in (m.group(1) or "").split(",") if a.strip()]
        rest = m.group(2)
        items, depth, cur = [], 0, ""
        for ch in rest:
            if ch in "(<":
                depth += 1
            elif ch in ")>":
                depth -= 1
            if ch == "," and depth == 0:
                items.append(cur); cur = ""
            else:
                cur += ch
        if cur.strip():
            items.append(cur)
        for it in items:
            it = it.strip()
            # strip leading option keywords (e.g. "READONLY name", "TOOLBAR open")
            while True:
                wm = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s+(.*)$", it, re.S)
                if wm and wm.group(1) in OPT_WORDS:
                    it = wm.group(2).strip()
                else:
                    break
            if not it:
                continue
            am = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\s*([^()]*)\))?", it)
            if not am:
                lm = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*=", it)
                if lm:
                    out.append((lm.group(1), tuple(ctx)))
                continue
            name, args = am.group(1), am.group(2)
            if name in OPT_WORDS:
                continue
            if args is None:
                out.append((name, tuple(ctx)))
            else:
                a = tuple(x.strip() for x in args.split(",") if x.strip())
                out.append((name, a or tuple(ctx)))
    return out

draws = collections.defaultdict(list)   # (form, name, args) -> [file:line]
objects = collections.defaultdict(dict) # form -> objname -> (class, file:line)
for path in glob.glob("storeTasks/**/*.lsf", recursive=True) + glob.glob("*.lsf"):
    cur_form, buf, start = None, [], 0
    with open(path, encoding="utf-8") as fh:
        for ln, raw in enumerate(fh, 1):
            line = strip_comment(raw)
            fm = re.match(r"\s*(?:EXTEND\s+)?FORM\s+([A-Za-z_][A-Za-z0-9_]*)", line)
            if fm:
                if cur_form and buf:
                    for (name, args) in parse_props(buf):
                        draws[(cur_form, name, args)].append(f"{path}:{start}")
                cur_form, buf, start = fm.group(1), [], ln
                continue
            if cur_form is None:
                continue
            om = re.match(r"\s*OBJECTS\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)", line)
            if om and cur_form:
                oname, ocls = om.group(1), om.group(2)
                prev = objects[cur_form].get(oname)
                if prev and prev[0] != ocls:
                    print(f"OBJ-CLASH form {cur_form}: OBJECTS {oname} = {oclass_diff(prev[0], ocls)} at {prev[1]} vs {path}:{ln}")
                elif not prev:
                    objects[cur_form][oname] = (ocls, f"{path}:{ln}")
            if re.match(r"\s*;\s*$", line):
                for (name, args) in parse_props(buf):
                    draws[(cur_form, name, args)].append(f"{path}:{start}")
                cur_form, buf = None, []
            else:
                buf.append(raw.rstrip("\n"))
    if cur_form and buf:
        for (name, args) in parse_props(buf):
            draws[(cur_form, name, args)].append(f"{path}:{start}")

def oclass_diff(a, b):
    return f"{a}!={b}"

dups = {k: v for k, v in draws.items() if len(v) > 1}
print(f"{len(dups)} duplicate draw(s):" if dups else "NO DUPLICATE DRAWS")
for (form, name, args), where in sorted(dups.items()):
    print(f"  FORM {form}: {name}({', '.join(args)})  ->  {', '.join(where)}")
