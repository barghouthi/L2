
(*  ints *)
let abs x = if x > 0 then x else (-1)*x
(* ext ints *)
let max x y = if x>y then x else y
let min x y = if x > y then y else x
(* pairs as lists *)
let snd x = car(cdr x)

let mk_pair x y = [x;y]


