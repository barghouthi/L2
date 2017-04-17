(* list folds *)
let rec cat = fun l1 l2 ->
  if l1 = [] then l2 else
  if l2 = [] then l1 else
    (car l1) :: (cat (cdr l1) l2)

let rec stutter x n = 
    if n > 0 then  x :: (stutter x (n - 1)) else []

let rec length x = 
    if x = [] then 0 else 1 + length (cdr x)

let rec sum x =
  if x = [] then 0 else (car x) + (sum (cdr x))

let mkList x = [x]

let minl x = 
    let rec filter = fun l f ->
    if l = [] then [] else
    let rest = filter (cdr l) f in
    if f (car l) then (car l) :: rest else rest
    in

    let rec sort = fun l ->
    if l = [] then [] else
    let p = car l in
    let lesser = filter (cdr l) (fun e -> e < p) in
    let greater = filter (cdr l) (fun e -> e >= p) in
    cat (sort lesser) (p :: (sort greater))
    in

    car (sort x)

let maxl x = 
    
    let rec reverse = fun l ->
    if l = [] then [] else cat (reverse (cdr l)) (car l :: [])
    in
    
    let rec filter = fun l f ->
    if l = [] then [] else
    let rest = filter (cdr l) f in
    if f (car l) then (car l) :: rest else rest
    in

    let rec sort = fun l ->
    if l = [] then [] else
    let p = car l in
    let lesser = filter (cdr l) (fun e -> e < p) in
    let greater = filter (cdr l) (fun e -> e >= p) in
    cat (sort lesser) (p :: (sort greater))
    in

    car (reverse (sort x))


