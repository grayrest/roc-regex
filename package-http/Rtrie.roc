## A radix trie over route bytes — matchit's own structure, and H4's measured
## reopen: M4 put 60% of a request's parse time in route selection, at ~707 ns
## per candidate route for a 20-byte path, which is fixed per-call cost rather
## than scanning (the `caps_email` shape). One descent now answers selection
## AND binds the parameters, so the regex engine leaves routing entirely.
##
## Nodes are parallel flat lists indexed by node id, as `Dfa.E` and `Arena.A`
## are: a record per node would put three heap fields in the lookup loop.
## Node 0 is a dummy so 0 can mean "no child"; the root is node 1.
##
## Priority is matchit's, and it is structural rather than sorted: at every
## node a static child is tried before the parameter child, and that before the
## catch-all. A deeper failure backtracks into the next kind.
import Route

Rtrie := [].{
    T : {
        # bytes consumed on entry to the node
        prefix : List(List(U8)),
        # static children; at most one can begin with any given byte
        kids : List(List(U64)),
        # the parameter child (consumes to the next `/`) and the catch-all
        # child (consumes to the end of the path); 0 = none
        param : List(U64),
        catchall : List(U64),
        # the name bound by the edge INTO this node
        name : List(Str),
        # route id + 1; 0 = no route ends here
        value : List(U64),
        # the route that created this node, + 1 — only so a conflict can name
        # the route it conflicts with
        owner : List(U64),
    }

    Err : [
        # a route ends where another already does; carries the other route's id
        Conflict(U64),
        # two routes disagree on a parameter's name at the same edge
        NameMismatch(U64),
    ]

    Hit : { value : U64, params : List({ name : Str, value : List(U8) }) }

    root : U64
    root = 1

    empty : Rtrie.T
    empty = {
        prefix: [[], []],
        kids: [[], []],
        param: [0, 0],
        catchall: [0, 0],
        name: ["", ""],
        value: [0, 0],
        owner: [0, 0],
    }

    n_nodes : Rtrie.T -> U64
    n_nodes = |t| List.len(t.prefix) - 1

    # --- construction -------------------------------------------------------

    ## Add a route. `value` is the caller's route id, reported back by `at`.
    insert : Rtrie.T, List(Route.Piece), U64 -> Try(Rtrie.T, Rtrie.Err)
    insert = |t, pieces, value| Rtrie.ins(t, Rtrie.root, pieces, value)

    ins : Rtrie.T, U64, List(Route.Piece), U64 -> Try(Rtrie.T, Rtrie.Err)
    ins = |t, id, pieces, value|
        match List.first(pieces) {
            Err(_) => {
                cur = List.get(t.value, id) ?? 0
                if cur != 0 { Err(Conflict(cur - 1)) } else { Ok(Rtrie.put_value(t, id, value + 1)) }
            }
            Ok(Static(bytes)) => Rtrie.ins_static(t, id, bytes, List.drop_first(pieces, 1), value)
            Ok(Param(nm)) => Rtrie.ins_edge(t, id, nm, List.drop_first(pieces, 1), value, True)
            Ok(CatchAll(nm)) => Rtrie.ins_edge(t, id, nm, List.drop_first(pieces, 1), value, False)
        }

    ins_static : Rtrie.T, U64, List(U8), List(Route.Piece), U64 -> Try(Rtrie.T, Rtrie.Err)
    ins_static = |t, id, bytes, rest, value|
        if List.is_empty(bytes) {
            Rtrie.ins(t, id, rest, value)
        } else {
            match Rtrie.kid_with(t, id, List.get(bytes, 0) ?? 0) {
                Err(_) => {
                    r = Rtrie.add(t, bytes, "", value)
                    t2 = Rtrie.put_kids(r.t, id, List.append(List.get(r.t.kids, id) ?? [], r.id))
                    Rtrie.ins(t2, r.id, rest, value)
                }
                Ok(c) => {
                    cp = List.get(t.prefix, c) ?? []
                    k = Rtrie.common(bytes, cp)
                    if k == List.len(cp) {
                        Rtrie.ins_static(t, c, List.drop_first(bytes, k), rest, value)
                    } else {
                        # the existing edge is longer than the shared part: split
                        # it, so `c` keeps the shared prefix and a new child holds
                        # everything `c` used to be
                        s = Rtrie.add(t, List.drop_first(cp, k), List.get(t.name, c) ?? "", value)
                        t1 = Rtrie.put_kids(s.t, s.id, List.get(s.t.kids, c) ?? [])
                        t2 = Rtrie.put_param(t1, s.id, List.get(t1.param, c) ?? 0)
                        t3 = Rtrie.put_catchall(t2, s.id, List.get(t2.catchall, c) ?? 0)
                        t4 = Rtrie.put_value(t3, s.id, List.get(t3.value, c) ?? 0)
                        t5 = Rtrie.put_owner(t4, s.id, List.get(t4.owner, c) ?? 0)
                        t6 = Rtrie.put_prefix(t5, c, List.take_first(cp, k))
                        t7 = Rtrie.put_kids(t6, c, [s.id])
                        t8 = Rtrie.put_param(t7, c, 0)
                        t9 = Rtrie.put_catchall(t8, c, 0)
                        ta = Rtrie.put_value(t9, c, 0)
                        Rtrie.ins_static(ta, c, List.drop_first(bytes, k), rest, value)
                    }
                }
            }
        }

    ins_edge : Rtrie.T, U64, Str, List(Route.Piece), U64, Bool -> Try(Rtrie.T, Rtrie.Err)
    ins_edge = |t, id, nm, rest, value, is_param| {
        cur = if is_param { List.get(t.param, id) ?? 0 } else { List.get(t.catchall, id) ?? 0 }
        if cur != 0 {
            if (List.get(t.name, cur) ?? "") != nm {
                Err(NameMismatch((List.get(t.owner, cur) ?? 1) - 1))
            } else {
                Rtrie.ins(t, cur, rest, value)
            }
        } else {
            r = Rtrie.add(t, [], nm, value)
            t2 = if is_param { Rtrie.put_param(r.t, id, r.id) } else { Rtrie.put_catchall(r.t, id, r.id) }
            Rtrie.ins(t2, r.id, rest, value)
        }
    }

    add : Rtrie.T, List(U8), Str, U64 -> { t : Rtrie.T, id : U64 }
    add = |t, prefix, name, owner| {
        id = List.len(t.prefix)
        {
            t: {
                prefix: List.append(t.prefix, prefix),
                kids: List.append(t.kids, []),
                param: List.append(t.param, 0),
                catchall: List.append(t.catchall, 0),
                name: List.append(t.name, name),
                value: List.append(t.value, 0),
                owner: List.append(t.owner, owner + 1),
            },
            id,
        }
    }

    put_prefix : Rtrie.T, U64, List(U8) -> Rtrie.T
    put_prefix = |t, id, v| { ..t, prefix: List.set(t.prefix, id, v) ?? t.prefix }
    put_kids : Rtrie.T, U64, List(U64) -> Rtrie.T
    put_kids = |t, id, v| { ..t, kids: List.set(t.kids, id, v) ?? t.kids }
    put_param : Rtrie.T, U64, U64 -> Rtrie.T
    put_param = |t, id, v| { ..t, param: List.set(t.param, id, v) ?? t.param }
    put_catchall : Rtrie.T, U64, U64 -> Rtrie.T
    put_catchall = |t, id, v| { ..t, catchall: List.set(t.catchall, id, v) ?? t.catchall }
    put_value : Rtrie.T, U64, U64 -> Rtrie.T
    put_value = |t, id, v| { ..t, value: List.set(t.value, id, v) ?? t.value }
    put_owner : Rtrie.T, U64, U64 -> Rtrie.T
    put_owner = |t, id, v| { ..t, owner: List.set(t.owner, id, v) ?? t.owner }

    # length of the shared prefix of two byte lists
    common : List(U8), List(U8) -> U64
    common = |x, y| Rtrie.common_at(x, y, 0)

    common_at : List(U8), List(U8), U64 -> U64
    common_at = |x, y, i|
        if i >= List.len(x) or i >= List.len(y) or (List.get(x, i) ?? 0) != (List.get(y, i) ?? 1) {
            i
        } else {
            Rtrie.common_at(x, y, i + 1)
        }

    # the static child whose edge begins with `b`; a radix trie has at most one
    kid_with : Rtrie.T, U64, U8 -> Try(U64, [NoKid])
    kid_with = |t, id, b|
        match List.find_first(List.get(t.kids, id) ?? [], |c| (List.get(t.prefix, c) ?? []).first() == Ok(b)) {
            Ok(c) => Ok(c)
            Err(_) => Err(NoKid)
        }

    # --- lookup -------------------------------------------------------------

    at : Rtrie.T, List(U8) -> Try(Rtrie.Hit, [NoMatch])
    at = |t, path| Rtrie.walk(t, Rtrie.root, path, 0, [])

    walk : Rtrie.T, U64, List(U8), U64, List({ name : Str, value : List(U8) }) -> Try(Rtrie.Hit, [NoMatch])
    walk = |t, id, path, pos, acc| {
        pre = List.get(t.prefix, id) ?? []
        if !Rtrie.starts_at(path, pos, pre) {
            Err(NoMatch)
        } else {
            p = pos + List.len(pre)
            n = List.len(path)
            v = List.get(t.value, id) ?? 0
            if p == n and v != 0 {
                Ok({ value: v - 1, params: acc })
            } else {
                st =
                    if p < n {
                        match Rtrie.kid_with(t, id, List.get(path, p) ?? 0) {
                            Ok(c) => Rtrie.walk(t, c, path, p, acc)
                            Err(_) => Err(NoMatch)
                        }
                    } else {
                        Err(NoMatch)
                    }
                match st {
                    Ok(h) => Ok(h)
                    Err(_) => Rtrie.try_dynamic(t, id, path, p, acc)
                }
            }
        }
    }

    # the parameter child, then the catch-all: matchit's order
    try_dynamic : Rtrie.T, U64, List(U8), U64, List({ name : Str, value : List(U8) }) -> Try(Rtrie.Hit, [NoMatch])
    try_dynamic = |t, id, path, p, acc| {
        n = List.len(path)
        pid = List.get(t.param, id) ?? 0
        r =
            if pid == 0 or p >= n {
                Err(NoMatch)
            } else {
                Rtrie.param_loop(t, pid, path, p, Rtrie.seg_end(path, p), acc)
            }
        match r {
            Ok(h) => Ok(h)
            Err(_) => {
                cid = List.get(t.catchall, id) ?? 0
                # a catch-all binds at least one byte, as matchit's does
                if cid == 0 or p >= n {
                    Err(NoMatch)
                } else {
                    Rtrie.walk(t, cid, path, n, List.append(acc, { name: List.get(t.name, cid) ?? "", value: List.sublist(path, { start: p, len: n - p }) }))
                }
            }
        }
    }

    # Longest first, then shorter. A parameter runs to the end of its segment,
    # but a static suffix in the same segment belongs to the route
    # (`/images/img{id}.png` binds "9", not "9.png"), and backtracking is what
    # finds where it starts.
    param_loop : Rtrie.T, U64, List(U8), U64, U64, List({ name : Str, value : List(U8) }) -> Try(Rtrie.Hit, [NoMatch])
    param_loop = |t, pid, path, p, e, acc|
        if e <= p {
            Err(NoMatch)
        } else {
            match Rtrie.walk(t, pid, path, e, List.append(acc, { name: List.get(t.name, pid) ?? "", value: List.sublist(path, { start: p, len: e - p }) })) {
                Ok(h) => Ok(h)
                Err(_) => Rtrie.param_loop(t, pid, path, p, e - 1, acc)
            }
        }

    # does `path` carry `pre` at `at`?
    starts_at : List(U8), U64, List(U8) -> Bool
    starts_at = |path, pos, pre| Rtrie.starts_loop(path, pos, pre, 0)

    starts_loop : List(U8), U64, List(U8), U64 -> Bool
    starts_loop = |path, pos, pre, i|
        if i >= List.len(pre) {
            True
        } else if pos + i >= List.len(path) or (List.get(path, pos + i) ?? 0) != (List.get(pre, i) ?? 1) {
            False
        } else {
            Rtrie.starts_loop(path, pos, pre, i + 1)
        }

    # the next `/` at or after `p`, else the end of the path
    seg_end : List(U8), U64 -> U64
    seg_end = |path, p|
        if p >= List.len(path) {
            p
        } else if (List.get(path, p) ?? 0) == '/' {
            p
        } else {
            Rtrie.seg_end(path, p + 1)
        }
}
