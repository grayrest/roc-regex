## The route table (H4): one radix trie per method, with 405 + `Allow` for a
## path that matches under another method.
##
## Precedence is matchit's and comes from the trie's structure rather than from
## sorting the table: at every node a static edge is tried before the parameter
## edge, and that before the catch-all, with backtracking into the next kind
## when a deeper match fails. Two routes that could match the same path are a
## conflict, as `matchit::InsertError::Conflict`.
import Route
import Rtrie

Router := [].{
    T : {
        # parallel: `tries[i]` holds the routes declared with `methods[i]`
        methods : List(Str),
        tries : List(Rtrie.T),
        # route id -> the route string it came from
        paths : List(Str),
    }

    Match : { method : Str, path : Str, params : List({ name : Str, value : List(U8) }) }

    Err : [
        BadRoute(Str, Route.Err),
        # two routes that can match the same path
        Conflict(Str, Str),
    ]

    ## Build a table from `{ method, path }` records. Declaration order does
    ## not affect which route wins — the trie decides that — but it does fix
    ## the route ids, and so the order `Allow` lists methods in.
    build : List({ method : Str, path : Str }) -> Try(Router.T, Router.Err)
    build = |decls|
        match Router.parse_all(decls, []) {
            Err(e) => Err(e)
            Ok(pieces) => {
                paths = List.map(decls, |d| d.path)
                methods = List.fold(decls, [], |acc, d| if List.contains(acc, d.method) { acc } else { List.append(acc, d.method) })
                match Router.build_tries(decls, pieces, paths, methods, 0, []) {
                    Err(e) => Err(e)
                    Ok(tries) => Ok({ methods, tries, paths })
                }
            }
        }

    parse_all : List({ method : Str, path : Str }), List(List(Route.Piece)) -> Try(List(List(Route.Piece)), Router.Err)
    parse_all = |decls, acc|
        match List.first(decls) {
            Err(_) => Ok(acc)
            Ok(d) =>
                match Route.parse(d.path) {
                    Err(e) => Err(BadRoute(d.path, e))
                    Ok(ps) => Router.parse_all(List.drop_first(decls, 1), List.append(acc, ps))
                }
        }

    build_tries : List({ method : Str, path : Str }), List(List(Route.Piece)), List(Str), List(Str), U64, List(Rtrie.T) -> Try(List(Rtrie.T), Router.Err)
    build_tries = |decls, pieces, paths, methods, i, acc|
        if i >= List.len(methods) {
            Ok(acc)
        } else {
            m = List.get(methods, i) ?? ""
            match Router.fill(decls, pieces, paths, m, 0, Rtrie.empty) {
                Err(e) => Err(e)
                Ok(t) => Router.build_tries(decls, pieces, paths, methods, i + 1, List.append(acc, t))
            }
        }

    fill : List({ method : Str, path : Str }), List(List(Route.Piece)), List(Str), Str, U64, Rtrie.T -> Try(Rtrie.T, Router.Err)
    fill = |decls, pieces, paths, m, i, t|
        if i >= List.len(decls) {
            Ok(t)
        } else if (List.get(decls, i) ?? { method: "", path: "" }).method != m {
            Router.fill(decls, pieces, paths, m, i + 1, t)
        } else {
            match Rtrie.insert(t, List.get(pieces, i) ?? [], i) {
                Ok(t2) => Router.fill(decls, pieces, paths, m, i + 1, t2)
                Err(Conflict(other)) => Err(Conflict(List.get(paths, other) ?? "", List.get(paths, i) ?? ""))
                Err(NameMismatch(other)) => Err(Conflict(List.get(paths, other) ?? "", List.get(paths, i) ?? ""))
            }
        }

    ## Select a route. `MethodNotAllowed` carries the methods that DO match the
    ## path, for the `Allow` header.
    at : Router.T, Str, List(U8) -> Try(Router.Match, [NotFound, MethodNotAllowed(List(Str))])
    at = |t, method, path|
        match List.find_first_index(t.methods, |m| m == method) {
            Ok(i) =>
                match Rtrie.at(List.get(t.tries, i) ?? Rtrie.empty, path) {
                    Ok(h) => Ok({ method, path: List.get(t.paths, h.value) ?? "", params: h.params })
                    Err(_) => Router.not_allowed(t, method, path)
                }
            Err(_) => Router.not_allowed(t, method, path)
        }

    # only reached when the request's own method did not match, so this pays
    # for the 404/405 answer and never for a hit
    not_allowed : Router.T, Str, List(U8) -> Try(Router.Match, [NotFound, MethodNotAllowed(List(Str))])
    not_allowed = |t, method, path| {
        allow = List.keep_if(t.methods, |m| m != method and Rtrie.at(List.get(t.tries, List.find_first_index(t.methods, |x| x == m) ?? 0) ?? Rtrie.empty, path) != Err(NoMatch))
        if List.is_empty(allow) { Err(NotFound) } else { Err(MethodNotAllowed(allow)) }
    }

    ## The named parameter of a match, as a slice of the path.
    param : Router.Match, Str -> Try(List(U8), [MissingParam])
    param = |m, name|
        match List.find_first(m.params, |p| p.name == name) {
            Ok(p) => Ok(p.value)
            Err(_) => Err(MissingParam)
        }
}
