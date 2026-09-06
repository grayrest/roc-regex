import sharp.Sharp
A := [].{
    m : Sharp.T
    m = Sharp.unwrap(Sharp.compile("[A-Z]+"))
    run : List(U8) -> U64
    run = |h| match Sharp.longest_end(A.m, h) { Ok(e) => e, Err(_) => 0 }
}
