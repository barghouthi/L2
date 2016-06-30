(* pairs as lists *)
let snd x = car(car x)

let mk_pair x y = [x;y]


(* list folds *)

let rec append = fun l1 l2 ->
  if l1 = [] then l2 else
  if l2 = [] then l1 else
    (car l1) :: (append (cdr l1) l2)

let rec reverse = fun l ->
  if l = [] then [] else append (reverse (cdr l)) (car l :: [])

(*let rec product x =
  if x = [] then 1 else
    (car x) * (product (cdr x))

let rec sum x =
  if x = [] then 0 else (car x) + (sum (cdr x))
*)
let mkPair x y = [x;y]


(* ints *)

let abs x =
  if x < 0 then (-1) * x else x
