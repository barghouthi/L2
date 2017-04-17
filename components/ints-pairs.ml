
(*  ints *)
let abs x = if x > 0 then x else (-1)*x
(* pairs as lists *)
let snd x = car(cdr x)

let mk_pair x y = x :: y :: []

