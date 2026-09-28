"""Godot 3.x 编译脚本（.gdc，字节码版本 13）还原成可读的 GDScript，供阅读和对齐挂钩点。

.gdc 在 Godot 3 里只是分词后的脚本（标识符表 + 常量表 + 词元流），不是真正的字节码，
按词元表拼回去就是源码；只丢了注释和原始排版。输出可以直接读，基本也能直接编译。
词元和内置函数的编号对应 Godot 3.2 – 3.6 的 gdscript_tokenizer / gdscript_functions。

用法：
  python tools/gdc.py <解包目录> <输出目录>
"""
import struct, sys, os

TOKENS = ["", "<IDENT>", "<CONST>", "self", "<TYPE>", "<FUNC>", "in", "==", "!=", "<", "<=", ">", ">=",
    "and", "or", "not", "+", "-", "*", "/", "%", "<<", ">>", "=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=",
    "&=", "|=", "^=", "&", "|", "^", "~", "if", "elif", "else", "for", "while", "break", "continue", "pass",
    "return", "match", "func", "class", "class_name", "extends", "is", "onready", "tool", "static", "export",
    "setget", "const", "var", "as", "void", "enum", "preload", "assert", "yield", "signal", "breakpoint",
    "remote", "sync", "master", "slave", "puppet", "remotesync", "mastersync", "puppetsync", "[", "]", "{", "}",
    "(", ")", ",", ";", ".", "?", ":", "$", "->", "<NEWLINE>", "PI", "TAU", "_", "INF", "NAN", "<ERROR>", "<END>", "<CURSOR>"]
TYPES = ["null", "bool", "int", "float", "String", "Vector2", "Rect2", "Vector3", "Transform2D", "Plane", "Quat",
    "AABB", "Basis", "Transform", "Color", "NodePath", "RID", "Object", "Dictionary", "Array", "PoolByteArray",
    "PoolIntArray", "PoolRealArray", "PoolStringArray", "PoolVector2Array", "PoolVector3Array", "PoolColorArray"]
FUNCS = ["sin", "cos", "tan", "sinh", "cosh", "tanh", "asin", "acos", "atan", "atan2", "sqrt", "fmod", "fposmod",
    "posmod", "floor", "ceil", "round", "abs", "sign", "pow", "log", "exp", "is_nan", "is_inf", "is_equal_approx",
    "is_zero_approx", "ease", "decimals", "step_decimals", "stepify", "lerp", "lerp_angle", "inverse_lerp",
    "range_lerp", "smoothstep", "move_toward", "dectime", "randomize", "randi", "randf", "rand_range", "seed",
    "rand_seed", "deg2rad", "rad2deg", "linear2db", "db2linear", "polar2cartesian", "cartesian2polar", "wrapi",
    "wrapf", "max", "min", "clamp", "nearest_po2", "weakref", "funcref", "convert", "typeof", "type_exists", "char",
    "ord", "str", "print", "printt", "prints", "printerr", "printraw", "print_debug", "push_error", "push_warning",
    "var2str", "str2var", "var2bytes", "bytes2var", "range", "load", "inst2dict", "dict2inst", "validate_json",
    "parse_json", "to_json", "hash", "Color8", "ColorN", "print_stack", "get_stack", "instance_from_id", "len",
    "is_instance_valid", "deep_equal"]
T_IDENT, T_CONST, T_TYPE, T_FUNC, T_NEWLINE, T_END = 1, 2, 4, 5, 89, 96

UNARY_PREV = {None, '(', '[', '{', ',', '=', 'return', '==', '!=', '<', '>', '<=', '>=', '+', '-', '*', '/', '%',
              ':', 'and', 'or', 'not', '+=', '-=', '*=', '/=', 'in', 'if', 'elif', 'while', 'match'}
NO_SPACE_BEFORE = {')', ']', ',', '.', ':', '}'}
NO_SPACE_AFTER = {'(', '[', '.', '$', '{', '~'}


def u32(b, o):
    return struct.unpack_from('<I', b, o)[0]


def fmt_float(x):
    if x != x:
        return 'NAN'
    if x in (float('inf'), float('-inf')):
        return 'INF' if x > 0 else '-INF'
    return repr(x)


def read_str(b, o):
    n = u32(b, o)
    o += 4
    s = b[o:o + n].decode('utf-8', 'replace')
    o += n + (4 - n % 4) % 4
    return s, o


def decode_variant(b, o):
    h = u32(b, o)
    o += 4
    t = h & 0xFF
    f64 = h & (1 << 16)
    if t == 0:
        return 'null', o
    if t == 1:
        return ('true' if u32(b, o) else 'false'), o + 4
    if t == 2:
        if f64:
            return str(struct.unpack_from('<q', b, o)[0]), o + 8
        return str(struct.unpack_from('<i', b, o)[0]), o + 4
    if t == 3:
        if f64:
            return fmt_float(struct.unpack_from('<d', b, o)[0]), o + 8
        return fmt_float(struct.unpack_from('<f', b, o)[0]), o + 4
    if t == 4:
        s, o = read_str(b, o)
        esc = s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')
        return '"' + esc + '"', o
    if t == 5:
        x, y = struct.unpack_from('<2f', b, o)
        return 'Vector2(%s, %s)' % (fmt_float(x), fmt_float(y)), o + 8
    if t == 7:
        v = struct.unpack_from('<3f', b, o)
        return 'Vector3(%s, %s, %s)' % tuple(map(fmt_float, v)), o + 12
    if t == 14:
        c = struct.unpack_from('<4f', b, o)
        return 'Color(%s, %s, %s, %s)' % tuple(map(fmt_float, c)), o + 16
    if t == 15:
        n = u32(b, o)
        if n & 0x80000000:
            o += 4
            names = n & 0x7FFFFFFF
            sub = u32(b, o)
            o += 8
            parts = []
            for _ in range(names + sub):
                s, o = read_str(b, o)
                parts.append(s)
            return '@"' + '/'.join(parts) + '"', o
        s, o = read_str(b, o)
        return '@"' + s + '"', o
    raise ValueError('variant type %d at %d' % (t, o - 4))


def detok(data):
    assert data[:4] == b'GDSC', data[:4]
    nid, nconst, nline, ntok = (u32(data, 8 + 4 * i) for i in range(4))
    o = 24
    idents = []
    for _ in range(nid):
        ln = u32(data, o)
        o += 4
        s = bytes(c ^ 0xb6 for c in data[o:o + ln]).split(b'\0')[0].decode('utf-8', 'replace')
        o += ln
        idents.append(s)
    consts = []
    for _ in range(nconst):
        v, o = decode_variant(data, o)
        consts.append(v)
    o += 8 * nline
    toks = []
    for _ in range(ntok):
        b0 = data[o]
        if b0 & 0x80:
            t = u32(data, o) & ~0x80
            o += 4
        else:
            t = b0
            o += 1
        toks.append((t & 0xFF, t >> 8))

    out, line = [], []
    indent = 0
    prev = None
    prev_kind = 'other'
    prev_unary = False

    def flush():
        if line:
            out.append('\t' * indent + ''.join(line))

    for tt, d in toks:
        if tt == T_NEWLINE:
            flush()
            line = []
            indent = d
            prev = None
            prev_kind = 'other'
            prev_unary = False
            continue
        if tt == T_END:
            break
        if tt == T_IDENT:
            s = idents[d]
        elif tt == T_CONST:
            s = consts[d]
        elif tt == T_TYPE:
            s = TYPES[d] if d < len(TYPES) else '<type%d>' % d
        elif tt == T_FUNC:
            s = FUNCS[d] if d < len(FUNCS) else '<func%d>' % d
        else:
            s = TOKENS[tt] if tt < len(TOKENS) else '<tok%d>' % tt
        if line:
            sep = ' '
            if s in NO_SPACE_BEFORE or prev in NO_SPACE_AFTER:
                sep = ''
            if s == '(' and prev_kind == 'name':
                sep = ''
            if s == '[' and prev_kind in ('name', 'close'):
                sep = ''
            if prev_unary:
                sep = ''
            line.append(sep)
        prev_unary = s in ('-', 'not') and prev in UNARY_PREV and s == '-'
        line.append(s)
        prev = s
        if tt in (T_IDENT, T_TYPE, T_FUNC, 3, T_CONST) or s in ('preload', 'yield', 'assert'):
            prev_kind = 'name'
        elif s in (')', ']'):
            prev_kind = 'close'
        else:
            prev_kind = 'other'
    flush()
    return '\n'.join(out) + '\n'


if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    n = bad = 0
    for root, _, files in os.walk(src):
        for fn in files:
            if not fn.endswith('.gdc'):
                continue
            p = os.path.join(root, fn)
            q = os.path.join(dst, os.path.relpath(p, src))[:-4] + '.gd'
            os.makedirs(os.path.dirname(q), exist_ok=True)
            try:
                text = detok(open(p, 'rb').read())
                open(q, 'w', encoding='utf-8', newline='\n').write(text)
                n += 1
            except Exception as e:
                bad += 1
                print('FAIL', p, e)
    print('ok', n, 'fail', bad)
