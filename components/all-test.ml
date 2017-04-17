
(*  ints *)
let abs x = if x > 0 then x else (-1)*x
(* ext ints *)
(* list folds *)

let rec sum x =
  if x = [] then 0 else (car x) + (sum (cdr x))

let mkList x = [x]




let mk_pair x y = [x;y]


