# Writes unicode_alnum.zig's range table from the Unicode Character Database:
#   python3 -I gen_unicode_alnum.py <ucd dir> > ranges.txt
# with <ucd dir> holding DerivedCoreProperties.txt and
# extracted/DerivedGeneralCategory.txt of the Unicode version Rust's core
# uses (17.0.0 for the pinned toolchain), flattened into one folder.
# Ranges of code points where Rust's `char::is_alphanumeric` is true:
# Alphabetic (DerivedCoreProperties) or General_Category Nd/Nl/No.
import sys, re
def parse(path, want):
    out=[]
    for line in open(path, encoding='utf-8'):
        line=line.split('#',1)[0].strip()
        if not line: continue
        cps, prop = [x.strip() for x in line.split(';')[:2]]
        if prop not in want: continue
        if '..' in cps: a,b=cps.split('..'); out.append((int(a,16),int(b,16)))
        else: v=int(cps,16); out.append((v,v))
    return out
ucd=sys.argv[1]
r=parse(ucd+'/DerivedCoreProperties.txt',{'Alphabetic'})+parse(ucd+'/DerivedGeneralCategory.txt',{'Nd','Nl','No'})
r.sort()
merged=[]
for a,b in r:
    if merged and a<=merged[-1][1]+1: merged[-1]=(merged[-1][0],max(merged[-1][1],b))
    else: merged.append((a,b))
print(len(merged), file=sys.stderr)
for a,b in merged: print(f"    .{{ 0x{a:X}, 0x{b:X} }},")
