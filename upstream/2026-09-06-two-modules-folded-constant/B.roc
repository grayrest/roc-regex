import sharp.Sharp
B := [].{
    m : Sharp.T
    m = Sharp.unwrap(Sharp.compile("[a-z]+"))
    run : List(U8) -> U64
    run = |h| match Sharp.longest_end(B.m, h) { Ok(e) => e, Err(_) => 0 }
}
