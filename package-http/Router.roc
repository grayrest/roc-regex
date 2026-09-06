## The route table (H4): per-method lists in matchit's precedence order, with
## 405 + `Allow` for a path that matches under another method.
##
## Precedence is not registration order. matchit resolves static before
## parameter before catch-all at the first segment where two routes differ, so
## sorting the table by each route's segment-kind sequence puts the winner
## first and selection is "the first pattern that matches".
import sharp.Sharp
import Route

Router := [].{
    Entry : { method : Str, route : Route.T }

    T : { entries : List(Router.Entry) }

    Match : { method : Str, path : Str, params : List({ name : Str, value : List(U8) }) }

    Err : [
        BadRoute(Str, Route.Err),
        # two routes that can match the same path (matchit's InsertError::Conflict)
        Conflict(Str, Str),
    ]

    ## Build a table from `{ method, path }` records. Order does not matter:
    ## the table is sorted here.
    build : List({ method : Str, path : Str }) -> Try(Router.T, Router.Err)
    build = |decls|
        match Router.compile_all(decls, []) {
            Err(e) => Err(e)
            Ok(es) => {
                sorted = List.sort_with(es, |x, y| Router.cmp(Router.rank(x), Router.rank(y)))
                match Router.first_conflict(sorted) {
                    Ok(pair) => Err(Conflict(pair.a, pair.b))
                    Err(_) => Ok({ entries: sorted })
                }
            }
        }

    compile_all : List({ method : Str, path : Str }), List(Router.Entry) -> Try(List(Router.Entry), Router.Err)
    compile_all = |decls, acc|
        match List.first(decls) {
            Err(_) => Ok(acc)
            Ok(d) =>
                match Route.compile(d.path) {
                    Err(e) => Err(BadRoute(d.path, e))
                    Ok(r) => Router.compile_all(List.drop_first(decls, 1), List.append(acc, { method: d.method, route: r }))
                }
        }

    ## Lexicographic order over the rank bytes; the stdlib has no `Str` compare.
    cmp : List(U8), List(U8) -> [Before, Same, After]
    cmp = |x, y| Router.cmp_at(x, y, 0)

    cmp_at : List(U8), List(U8), U64 -> [Before, Same, After]
    cmp_at = |x, y, i| {
        nx = List.len(x)
        ny = List.len(y)
        if i >= nx or i >= ny {
            if nx < ny { Before } else if nx > ny { After } else { Same }
        } else {
            a = List.get(x, i) ?? 0
            b = List.get(y, i) ?? 0
            if a < b { Before } else if a > b { After } else { Router.cmp_at(x, y, i + 1) }
        }
    }

    ## The sort key: the method, then one character per piece -- `0` static,
    ## `1` parameter, `2` catch-all -- so a static segment sorts ahead of a
    ## parameter at the first place two routes differ, which is matchit's rule.
    ## The static bytes go in too, so routes that differ only in their statics
    ## keep a stable order.
    rank : Router.Entry -> List(U8)
    rank = |e|
        List.fold(e.route.pieces, Str.to_utf8(e.method), |acc, p|
            match p {
                Static(bytes) => List.concat(List.append(acc, Router.sep), List.prepend(bytes, '0'))
                Param(_) => List.concat(acc, [Router.sep, '1'])
                CatchAll(_) => List.concat(acc, [Router.sep, '2'])
            })

    # a byte no method or route can contain, so pieces cannot run together
    sep : U8
    sep = 0x1F

    ## Two routes conflict when they have the same method and the same shape --
    ## identical statics and identical piece kinds -- so no path can tell them
    ## apart and the parameter names alone differ (`/users/{id}` vs
    ## `/users/{name}`). Shapes are equal exactly when their ranks are, which
    ## the sort has already made adjacent.
    first_conflict : List(Router.Entry) -> Try({ a : Str, b : Str }, [NoConflict])
    first_conflict = |es|
        List.fold(List.map_with_index(es, |e, i| { e, i }), Err(NoConflict), |acc, x|
            match acc {
                Ok(_) => acc
                Err(_) =>
                    if x.i > 0 and Router.rank(x.e) == Router.rank(List.get(es, x.i - 1) ?? x.e) {
                        Ok({ a: (List.get(es, x.i - 1) ?? x.e).route.path, b: x.e.route.path })
                    } else {
                        acc
                    }
            })

    ## Select a route. `MethodNotAllowed` carries the methods that DO match the
    ## path, for the `Allow` header.
    at : Router.T, Str, List(U8) -> Try(Router.Match, [NotFound, MethodNotAllowed(List(Str))])
    at = |t, method, path|
        match List.find_first(t.entries, |e| e.method == method and Route.matches(e.route, path)) {
            Ok(e) =>
                match Route.params(e.route, path) {
                    Ok(ps) => Ok({ method, path: e.route.path, params: ps })
                    # the selection pattern matched, so the pieces must; if they
                    # do not it is a translation bug, reported as NotFound rather
                    # than guessed at
                    Err(_) => Err(NotFound)
                }
            Err(_) => {
                allow = List.map(List.keep_if(t.entries, |e| Route.matches(e.route, path)), |e| e.method)
                if List.is_empty(allow) { Err(NotFound) } else { Err(MethodNotAllowed(Router.dedup(allow))) }
            }
        }

    dedup : List(Str) -> List(Str)
    dedup = |xs| List.fold(xs, [], |acc, x| if List.contains(acc, x) { acc } else { List.append(acc, x) })

    ## The named parameter of a match, as a slice of the path.
    param : Router.Match, Str -> Try(List(U8), [MissingParam])
    param = |m, name|
        match List.find_first(m.params, |p| p.name == name) {
            Ok(p) => Ok(p.value)
            Err(_) => Err(MissingParam)
        }
}
