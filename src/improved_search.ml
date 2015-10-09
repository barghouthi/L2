open Core.Std

open Ast
open Collections
open Hypothesis
open Infer

module type Generalizer_intf = sig
  type t = Hole.t -> Specification.t -> (Hypothesis.t * Unifier.t) list
  val generalize : t
  val generalize_all : generalize:t -> Hypothesis.t -> Hypothesis.t list
end

module Generalizer_impl = struct
  type t = Hole.t -> Specification.t -> (Hypothesis.t * Unifier.t) list

  let generalize_all ~generalize:gen hypo =
    let open Hypothesis in
    List.fold_left
      (List.sort ~cmp:(fun (h1, _) (h2, _) -> Hole.compare h1 h2) (holes hypo))
      ~init:[ hypo ]
      ~f:(fun hypos (hole, spec) ->
          let children = List.filter (gen hole spec) ~f:(fun (c, _) ->
              kind c = Abstract || Specification.verify spec (skeleton c))
          in
          List.map hypos ~f:(fun p -> List.map children ~f:(fun (c, u) ->
              apply_unifier (fill_hole hole ~parent:p ~child:c) u))
          |> List.concat)
end

module type Deduction_intf = sig
  val push_specifications : Specification.t Skeleton.t -> Specification.t Skeleton.t Option.t
  val push_specifications_unification : Specification.t Skeleton.t -> Specification.t Skeleton.t Option.t
end

module L2_Deduction : Deduction_intf = struct
  module Sp = Specification
  module Sk = Skeleton

  let type_err name type_ =
    failwiths "Unexpected type for return value of function." (name, type_) <:sexp_of<id * Type.t>>

  let spec_err name spec =
    failwiths "Unexpected spec for return value of function." (name, spec) <:sexp_of<id * Sp.t>>

  let input_err name inp =
    failwiths "Unexpected input value for function." (name, inp) <:sexp_of<id * value>>

  let ret_err name ret =
    failwiths "Unexpected return value of function." (name, ret) <:sexp_of<id * value>>

  let lookup_err name id =
    failwiths "Variable name not present in context." (name, id) <:sexp_of<id * StaticDistance.t>>

  module type Deduce_2_intf = sig
      val name : string
      val examples_of_io : value -> value -> ((value * value) list, unit) Result.t
  end
  
  module Make_deduce_2 (M : Deduce_2_intf) = struct
    let lambda_spec collection_id parent_spec =
      let open Result.Monad_infix in
      match parent_spec with
      | Sp.Examples exs ->
        let m_hole_exs =
          List.map (Sp.Examples.to_list exs) ~f:(fun (ctx, out_v) ->
              let in_v = match StaticDistance.Map.find ctx collection_id with
                | Some in_v -> in_v
                | None -> lookup_err M.name collection_id
              in
              Result.map (M.examples_of_io in_v out_v) ~f:(fun io ->
                  List.map io ~f:(fun (i, o) -> (ctx, [i]), o)))
          |> Result.all
          >>| List.concat
          >>= fun hole_exs ->
          Result.map_error (Sp.FunctionExamples.of_list hole_exs) ~f:(fun _ -> ())
        in
        begin
          match m_hole_exs with
          | Ok hole_exs -> Sp.FunctionExamples hole_exs
          | Error () -> Sp.Bottom
        end
      | Sp.Top -> Sp.Top
      | Sp.Bottom -> Sp.Bottom
      | _ -> spec_err M.name parent_spec

    let deduce spec args =
      let open Result.Monad_infix in
      match args with
      | [ Sk.Id_h (Sk.StaticDistance sd, _) as list; lambda ] when (Sk.annotation lambda) = Sp.Top ->
        let child_spec = lambda_spec sd spec in
        [ list; Sk.map_annotation lambda ~f:(fun _ -> child_spec) ]
      | _ -> args
  end

  module type Deduce_fold_intf = sig
    val name : string
    val is_base_case : value -> bool
    val examples_of_io : value -> value -> ((value * value) list, unit) Result.t
  end

  module Make_deduce_fold (M : Deduce_fold_intf) = struct
    let base_spec collection_id parent_spec =
      match parent_spec with
      | Sp.Examples exs ->
        let exs = Sp.Examples.to_list exs in
        let m_base_exs =
          List.filter exs ~f:(fun (ctx, out_v) ->
              match StaticDistance.Map.find ctx collection_id with
              | Some v -> M.is_base_case v
              | None -> lookup_err (M.name ^ "-base-case") collection_id)
          |> Sp.Examples.of_list
        in
        begin
          match m_base_exs with
          | Ok base_exs -> Sp.Examples base_exs
          | Error _ -> Sp.Bottom
        end
      | Sp.Top -> Sp.Top
      | Sp.Bottom -> Sp.Bottom
      | _ -> spec_err (M.name ^ "-base-case") parent_spec

    let deduce spec args =
      let open Result.Monad_infix in
      match args with
      | [ Sk.Id_h (Sk.StaticDistance sd, _) as input; lambda; base ] ->
        let b_spec = Sk.annotation base in
        let b_spec = if b_spec = Sp.Top then base_spec sd spec else b_spec in
        [ input; lambda; Sk.map_annotation base ~f:(fun _ -> b_spec ) ]
      | _ -> args
  end

  module Deduce_map = Make_deduce_2 (struct
      let name = "map"
      let examples_of_io in_v out_v =
        let out = match out_v with
          | `List out -> out
          | _ -> ret_err name out_v
        in
        let inp = match in_v with
          | `List inp -> inp
          | _ -> input_err name in_v
        in
        Option.value_map (List.zip inp out) ~default:(Error ()) ~f:(fun io -> Ok (io))
    end)

  module Deduce_mapt = Make_deduce_2 (struct
      let name = "mapt"
      let examples_of_io in_v out_v =
        let out = match out_v with
          | `Tree out -> out
          | _ -> ret_err name out_v
        in
        let inp = match in_v with
          | `Tree inp -> inp
          | _ -> input_err name in_v
        in
        Option.map (Tree.zip inp out) ~f:(fun io -> Ok (Tree.flatten io))
        |> Option.value ~default:(Error ())
    end)

  module Deduce_filter = Make_deduce_2 (struct
      let name = "filter"

      let rec f = function
        (* If there are no inputs and no outputs, then there are no
           examples, but filter is valid. *)
        | [], [] -> Some []

        (* If there are some inputs and no outputs, then the inputs
           must have been filtered. *)
        | (_::_ as inputs), [] -> Some (List.map inputs ~f:(fun i -> i, `Bool false))

        (* If there are some outputs and no inputs, then filter is
           not valid. *)
        | [], _::_ -> None

        | i::is, o::os when i = o ->
          Option.map (f (is, os)) ~f:(fun exs -> (i, `Bool true)::exs)

        | i::is, (_::_ as outputs) ->
          Option.map (f (is, outputs)) ~f:(fun exs -> (i, `Bool false)::exs)

      let examples_of_io in_v out_v =
        let out = match out_v with
          | `List out -> out
          | _ -> ret_err name out_v
        in
        let inp = match in_v with
          | `List inp -> inp
          | _ -> input_err name in_v
        in
        Option.value_map (f (inp, out)) ~default:(Error ()) ~f:(fun io -> Ok io)
    end)

  module Deduce_foldl = Make_deduce_fold (struct
      let name = "foldl"
      let is_base_case v = v = `List []
      let examples_of_io _ _ = Error ()
    end)

  module Deduce_foldr = Make_deduce_fold (struct
      let name = "foldr"
      let is_base_case v = v = `List []
      let examples_of_io _ _ = Error ()
    end)

  module Deduce_foldt = Make_deduce_fold (struct
      let name = "foldt"
      let is_base_case v = v = `Tree Tree.Empty
      let examples_of_io _ _ = Error ()
    end)
  
  let deduce_lambda lambda spec =
    let (num_args, body) = lambda in
    if (Sk.annotation body) = Sp.Top then
      let child_spec = match Sp.increment_scope spec with
        | Sp.FunctionExamples exs ->
          let arg_names = StaticDistance.args num_args in
          let child_exs =
            Sp.FunctionExamples.to_list exs
            |> List.map ~f:(fun ((in_ctx, in_args), out) ->
                let value_ctx = StaticDistance.Map.of_alist_exn (List.zip_exn arg_names in_args) in
                let in_ctx = StaticDistance.Map.merge value_ctx in_ctx ~f:(fun ~key:_ v ->
                    match v with
                    | `Both (x, _)
                    | `Left x
                    | `Right x -> Some x)
                in
                (in_ctx, out))
            |> Sp.Examples.of_list_exn
          in
          Sp.Examples child_exs
        | Sp.Bottom -> Sp.Bottom
        | Sp.Top -> Sp.Top
        | _ -> spec_err "<lambda>" spec
      in
      (num_args, Sk.map_annotation body ~f:(fun _ -> child_spec))
    else lambda
  
  let rec push_specifications (skel: Specification.t Skeleton.t) : Specification.t Skeleton.t Option.t =
    let open Option.Monad_infix in
    match skel with
    | Sk.Num_h (_, s)
    | Sk.Bool_h (_, s)
    | Sk.Id_h (_, s)
    | Sk.Hole_h (_, s) -> if s = Sp.Bottom then None else Some skel
    | Sk.List_h (l, s) ->
      let m_l = List.map l ~f:push_specifications |> Option.all in
      m_l >>| fun l -> Sk.List_h (l, s)
    | Sk.Tree_h (t, s) ->
      let m_t = Tree.map t ~f:push_specifications |> Tree.all in
      m_t >>| fun t -> Sk.Tree_h (t, s)
    | Sk.Let_h ((bound, body), s) ->
      let m_bound = push_specifications bound in
      let m_body = push_specifications body in
      m_bound >>= fun bound -> m_body >>| fun body -> Sk.Let_h ((bound, body), s)
    | Sk.Lambda_h (lambda, s) ->
      let (num_args, body) = deduce_lambda lambda s in
      let m_body = push_specifications body in
      m_body >>| fun body -> Sk.Lambda_h ((num_args, body), s)
    | Sk.Op_h ((op, args), s) ->
      let m_args = List.map args ~f:push_specifications |> Option.all in
      m_args >>| fun args -> Sk.Op_h ((op, args), s)
    | Sk.Apply_h ((func, args), s) ->
      let args = match func with
        | Sk.Id_h (Sk.Name "map", _) -> Deduce_map.deduce s args
        | Sk.Id_h (Sk.Name "mapt", _) -> Deduce_mapt.deduce s args
        | Sk.Id_h (Sk.Name "filter", _) -> Deduce_filter.deduce s args
        | Sk.Id_h (Sk.Name "foldl", _) -> Deduce_foldl.deduce s args
        | Sk.Id_h (Sk.Name "foldr", _) -> Deduce_foldr.deduce s args
        | Sk.Id_h (Sk.Name "foldt", _) -> Deduce_foldt.deduce s args
        | _ -> args        
      in
      let m_args =
        if List.exists args ~f:(fun a -> Sk.annotation a = Sp.Bottom) then None else
          Option.all (List.map args ~f:push_specifications)
      in
      let m_func = push_specifications func in
      m_args >>= fun args -> m_func >>| fun func -> Sk.Apply_h ((func, args), s)

    let recursion_limit = 100

  let sterm_of_result r =
    let fresh_name = Util.Fresh.mk_fresh_name_fun () in
    let ctx = ref Hole.Id.Map.empty in
    let module U = Unify in
    let rec f r =
      let module SE = Symbolic_execution in
      let module Sk = Skeleton in
      match r with
      | SE.Num_r x -> U.K (Int.to_string x)
      | SE.Bool_r x -> U.K (if x then "true" else "false")
      | SE.List_r [] -> U.K "[]"
      | SE.List_r (x::xs) -> U.Cons (f x, f (SE.List_r xs))
      | SE.Id_r (Sk.StaticDistance sd) -> U.V (StaticDistance.to_string sd)
      | SE.Id_r (Sk.Name id) -> U.V id
      | SE.Op_r (RCons, [xs; x])
      | SE.Op_r (Cons, [x; xs]) -> U.Cons (f x, f xs)
      | SE.Symbol_r id -> 
        let var = match Hole.Id.Map.find !ctx id with
          | Some var -> var
          | None ->
            let var = fresh_name () in
            ctx := Hole.Id.Map.add !ctx ~key:id ~data:var; var
        in
        U.V var
      | SE.Apply_r _ -> U.V (fresh_name ())
      | SE.Closure_r _
      | SE.Tree_r _
      | SE.Op_r _ -> raise U.Unknown
    in
    try
      let sterm = f r in
      let ctx = Hole.Id.Map.to_alist !ctx |> List.map ~f:Tuple.T2.swap |> String.Map.of_alist_exn in
      Ok (sterm, ctx)
    with U.Unknown -> Error (Error.of_string "Unhandled construct.")

  let rec value_of_term t : value =
    let module U = Unify in
    match t with
    | U.Term ("[]", []) -> `List []
    | U.Term ("true", []) -> `Bool true
    | U.Term ("false", []) -> `Bool false
    | U.Term (s, []) -> `Num (Int.of_string s)
    | U.Term ("Cons", [x; y]) -> begin
        match value_of_term y with
        | `List y -> `List ((value_of_term x)::y)
        | _ -> failwith "Translation error"
      end
    | _ -> failwith "Translation error"
      
  let push_specifications_unification s =
    if (!Config.config).Config.deduction then
      let module SE = Symbolic_execution in
      let module Sp = Specification in
      match Skeleton.annotation s with
      | Sp.Examples exs ->
        let m_new_examples =
          List.fold (Sp.Examples.to_list exs) ~init:(Some Hole.Id.Map.empty) ~f:(fun m_exs (ins, out_e) ->
              Option.bind m_exs (fun exs -> 
                  try
                    (* Try symbolically executing the candidate in the example context. *)
                    let out_a = SE.partially_evaluate ~recursion_limit
                        ~ctx:(StaticDistance.Map.map ins ~f:SE.result_of_value) s
                    in

                    match out_a with
                    | Symbol_r _ -> None
                    | Apply_r _ -> m_exs
                    | _ -> begin
                        (* Convert output and expected output to terms and
                           unify. If unification fails, discard the candidate. *)
                        match sterm_of_result out_a with
                        | Ok (out_a, symbol_names) -> begin match Unify.sterm_of_value out_e with
                            | Some out_e -> begin try
                                  let sub = Unify.unify_one (Unify.translate out_a) (Unify.translate out_e) in
                                  (* let () = Debug.eprintf "U %s %s:\n%s" *)
                                  (*     (Unify.sterm_to_string out_a) (Unify.sterm_to_string out_e) *)
                                  (*     (Unify.sub_to_string sub) *)
                                  (* in *)
                                  Some (List.fold sub ~init:exs ~f:(fun exs (var, term) ->
                                      match String.Map.find symbol_names var with
                                      | Some id ->
                                        Hole.Id.Map.add_multi exs ~key:id ~data:(ins, value_of_term term)
                                      | None -> exs))
                                with Unify.Non_unifiable -> None
                              end
                            | None -> m_exs
                          end
                        | Error _ -> m_exs
                      end
                  with
                  (* These are non-fatal errors. We learn nothing about the
                     candidate, but we can't discard it either. *)
                  | SE.EvalError `HitRecursionLimit
                  | SE.EvalError `UnhandledConditional -> m_exs

                  (* All other errors are fatal, so we discard the candidate. *)
                  | SE.EvalError _ -> None))
        in
        Option.bind m_new_examples (fun new_exs ->
            let new_exs = Hole.Id.Map.map new_exs ~f:Sp.Examples.of_list in
            if Hole.Id.Map.exists new_exs ~f:Result.is_error then None else
              Some (Hole.Id.Map.map new_exs ~f:Or_error.ok_exn))
        |>  Option.map ~f:(fun new_exs -> Skeleton.map_hole s ~f:(fun (hole, old_spec) ->
            let s = Sk.Hole_h (hole, old_spec) in
            match Hole.Id.Map.find new_exs hole.Hole.id with
            | Some exs -> begin match old_spec with
                | Sp.Top -> Skeleton.Hole_h (hole, Sp.Examples exs)
                | _ -> s
              end
            | None -> s))
      | _ -> Some s
    else Some s
end

module L2_CostModel : CostModel_Intf = struct
  module Sk = Skeleton
    
  let id_cost = function
    | Sk.Name name -> begin match name with
        | "foldr"
        | "foldl"
        | "foldt" -> 3
        | "map"
        | "mapt"
        | "filter" -> 2
        | _ -> 1
      end
    | Sk.StaticDistance sd -> 1

  let op_cost = Expr.Op.cost
  let lambda_cost = 1
  let num_cost = 1
  let bool_cost = 1
  let hole_cost = 0
  let let_cost = 1
  let list_cost = 1
  let tree_cost = 1
end

module L2_Hypothesis = Hypothesis.Make(L2_CostModel)

module L2_Generalizer = struct
  include Generalizer_impl

  (* This generalizer generates programs of the following form. Each
     hole in the hypotheses that it returns is tagged with a symbol
     name that the generalizer uses to select the hypotheses that can
     be used to fill that hole later.

     L := fun x_1 ... x_n -> E

     E := map I (L)
        | filter I (L)
        | foldl I (L) C
        | ...
        | E'

     E' := car E'
         | cdr E'
         | cons E' E'
         | ...
         | C

     C := 0
        | 1
        | []
        | ...

     I := <identifier in current scope>
  *)

  module type Symbols_intf = sig
    val lambda : Symbol.t
    val combinator : Symbol.t
    val expression : Symbol.t
    val constant : Symbol.t
    val identifier : Symbol.t
    val base_case : Symbol.t
  end

  module Make (Symbols : Symbols_intf) = struct
    module Sp = Specification
    module H = L2_Hypothesis

    include Symbols

    let combinators = [
      "map"; "mapt"; "filter"; "foldl"; "foldr"; "foldt"; "rec"
    ]
    let functions = Ctx.filter Infer.stdlib_tctx ~f:(fun ~key:k ~data:_ ->
        not (List.mem ~equal:String.equal combinators k))

    let generate_constants hole spec =
      let constants = [
        Type.num, [
          H.num 0 spec;
          H.num 1 spec;
          H.num Int.max_value spec;
        ];
        Type.bool, [
          H.bool true spec;
          H.bool false spec;
        ];
        Type.list (Type.quant "a") |> instantiate 0, [
          H.list [] spec;
        ]
      ] in
      List.concat_map constants ~f:(fun (t, xs) ->
          match Infer.Unifier.of_types hole.Hole.type_ t with
          | Some u -> List.map xs ~f:(fun x -> (x, u))
          | None -> [])

    let generate_identifiers hole spec =
      List.filter_map (StaticDistance.Map.to_alist hole.Hole.ctx) ~f:(fun (id, id_t) ->
          Option.map (Unifier.of_types hole.Hole.type_ id_t) ~f:(fun u ->
              H.id_sd id spec, u))

    let generate_expressions hole spec =
      let op_exprs = List.filter_map Expr.Op.all ~f:(fun op ->
          let op_t = instantiate 0 (Expr.Op.meta op).Expr.Op.typ in
          match op_t with
          | Arrow_t (args_t, ret_t) ->
            (* Try to unify the return type of the operator with the type of the hole. *)
            Option.map (Unifier.of_types hole.Hole.type_ ret_t) ~f:(fun u ->
                (* If unification succeeds, apply the unifier to the rest of the type. *)
                let args_t = List.map args_t ~f:(Unifier.apply u) in
                let arg_holes = List.map args_t ~f:(fun t ->
                    H.hole (Hole.create hole.Hole.ctx t expression) Sp.Top)
                in
                H.op (op, arg_holes) spec, u)
          | _ -> None)
      in
      let apply_exprs = List.filter_map (Ctx.to_alist functions) ~f:(fun (func, func_t) ->
          let func_t = instantiate 0 func_t in
          match func_t with
          | Arrow_t (args_t, ret_t) ->
            (* Try to unify the return type of the operator with the type of the hole. *)
            Option.map (Unifier.of_types hole.Hole.type_ ret_t) ~f:(fun u ->
                (* If unification succeeds, apply the unifier to the rest of the type. *)
                let args_t = List.map args_t ~f:(Unifier.apply u) in
                let arg_holes = List.map args_t ~f:(fun t ->
                    H.hole (Hole.create hole.Hole.ctx t expression) Sp.Top)
                in
                H.apply (H.id_name func Sp.Top, arg_holes) spec, u)
          | _ -> None)
      in
      op_exprs @ apply_exprs

    let generate_lambdas hole spec =
      match hole.Hole.type_ with
      (* If the hole has an arrow type, generate a lambda expression with
         the right number of arguments and push the specification down. *)
      | Arrow_t (args_t, ret_t) ->
        let num_args = List.length args_t in
        let arg_names = StaticDistance.args num_args in
        let type_ctx =
          List.fold (List.zip_exn arg_names args_t)
            ~init:(StaticDistance.map_increment_scope hole.Hole.ctx)
            ~f:(fun ctx (arg, arg_t) -> StaticDistance.Map.add ctx ~key:arg ~data:arg_t)
        in
        let lambda =
          H.lambda (num_args, H.hole (Hole.create type_ctx ret_t combinator) Sp.Top) spec
        in
        [ lambda, Unifier.empty ]
      | _ -> []

    let generate_combinators hole spec =
      List.filter_map (Ctx.to_alist Infer.stdlib_tctx) ~f:(fun (func, func_t) ->
          if List.mem ~equal:String.equal combinators func then
            let func_t = instantiate 0 func_t in
            match func_t with
            | Arrow_t (args_t, ret_t) ->
              (* Try to unify the return type of the operator with the type of the hole. *)
              Option.map (Unifier.of_types ret_t hole.Hole.type_) ~f:(fun u ->
                  (* If unification succeeds, apply the unifier to the rest of the type. *)
                  let args_t = List.map args_t ~f:(Infer.Unifier.apply u) in
                  let arg_holes = match (func, args_t) with
                    | "map", [ t1; t2 ]
                    | "mapt", [ t1; t2 ]
                    | "filter", [ t1; t2 ] -> [
                        H.hole (Hole.create hole.Hole.ctx t1 identifier) Sp.Top;
                        H.hole (Hole.create hole.Hole.ctx t2 lambda) Sp.Top;
                      ]
                    | "foldr", [ t1; t2; t3 ]
                    | "foldl", [ t1; t2; t3 ]
                    | "foldt", [ t1; t2; t3 ] -> [
                        H.hole (Hole.create hole.Hole.ctx t1 identifier) Sp.Top;
                        H.hole (Hole.create hole.Hole.ctx t2 lambda) Sp.Top;
                        H.hole (Hole.create hole.Hole.ctx t3 base_case) Sp.Top;
                      ]
                    | name, _ -> failwith (sprintf "Unexpected combinator name: %s" name)
                  in
                  H.apply (H.id_name func Sp.Top, arg_holes) spec, u)
            | _ -> None
          else None)

    let select_generators symbol =
      if symbol = constant then
        [ generate_constants ]
      else if symbol = base_case then
        [ generate_constants; generate_identifiers ]
      else if symbol = identifier then
        [ generate_identifiers ]
      else if symbol = lambda then
        [ generate_lambdas ]
      else if symbol = expression then
        [ generate_expressions; generate_identifiers; generate_constants ]
      else if symbol = combinator then
        [ generate_combinators; generate_expressions; generate_constants ]
      else
        failwiths "Unknown symbol type." symbol Symbol.sexp_of_t

    let generalize hole spec =
      let generators = select_generators hole.Hole.symbol in
      List.concat (List.map generators ~f:(fun g -> g hole spec))
  end

  include Make (struct
      let lambda = Symbol.create "Lambda"
      let combinator = Symbol.create "Combinator"
      let expression = Symbol.create "Expression"
      let constant = Symbol.create "Constant"
      let identifier = Symbol.create "Identifier"
      let base_case = Symbol.create "BaseCase"
    end)
end

module type Synthesizer_intf = sig
  val synthesize : Hypothesis.t -> cost:int -> Hypothesis.t Option.t
end

module Make_BFS_Synthesizer (G: Generalizer_intf) : Synthesizer_intf = struct
  exception SynthesisException of Hypothesis.t Option.t

  let synthesize hypo ~cost:max_cost =
    let open Hypothesis in
    let heap = Heap.create ~cmp:compare_cost () in
    try
      Heap.add heap hypo;
      while true do
        match Heap.pop heap with
        | Some h ->
          (* Take the hole with the smallest id. *)
          let m_hole =
            List.min_elt (holes h) ~cmp:(fun (h1, _) (h2, _) -> Hole.compare h1 h2)
          in
          (match m_hole with
           | Some (hole, spec) ->
             List.iter (G.generalize hole spec) ~f:(fun (c, u) ->
                 if (kind c) = Abstract || Hypothesis.verify c then
                   let h = apply_unifier (fill_hole hole ~parent:h ~child:c) u in

                   match kind c with
                   | Concrete ->
                     let () = printf "%s\n" (Skeleton.to_string_hum (skeleton h)) in
                     if Hypothesis.verify h then raise (SynthesisException (Some h))
                   | Abstract -> Heap.add heap h)
           | None -> failwiths "BUG: Abstract hypothesis has no holes."
                       h Hypothesis.sexp_of_t)
        | None -> raise (SynthesisException None)
      done; None
    with SynthesisException h -> h
end

module L2_BFS_Synthesizer = Make_BFS_Synthesizer(L2_Generalizer)

module type Prune_intf = sig
  val should_prune : Hypothesis.t -> bool
end

(** Maps (hole, spec) pairs to the hypotheses that can fill in the hole and match the spec.

    The memoizer can be queried with a hole, a spec and a cost.

    Internally, the type of the hole and the types in the type context
    of the hole are normalized by substituting their free type
    variable ids with fresh ones. The memoizer only stores the
    normalized holes. This increases potential for sharing when
    different holes have the same type structure but different ids in
    their free type variables.
*)

module Memoizer = struct
  module type S = sig
    type t
    val create : unit -> t
    val get : t -> Hole.t -> Specification.t -> int -> (Hypothesis.t * Unifier.t) list
  end

  let denormalize_unifier u map =
    Unifier.to_alist u
    |> List.filter_map ~f:(fun (k, v) ->
        Option.map (IntMap.find map k) ~f:(fun k' -> k', v))
    |> Unifier.of_alist_exn

  module Key = struct
    module Hole_without_id = struct
      type t = {
        ctx : Type.t StaticDistance.Map.t;
        type_ : Type.t;
        symbol : Symbol.t;
      } with compare, sexp

      let normalize_free ctx t =
        let fresh_int = Util.Fresh.mk_fresh_int_fun () in
        let rec norm t = match t with
          | Var_t { contents = Quant _ }
          | Const_t _ -> t
          | App_t (name, args) -> App_t (name, List.map args ~f:norm)
          | Arrow_t (args, ret) -> Arrow_t (List.map args ~f:norm, norm ret)
          | Var_t { contents = Free (id, level) } ->
            (match IntMap.find !ctx id with
             | Some id -> Type.free id level
             | None ->
               let new_id = fresh_int () in
               ctx := IntMap.add !ctx ~key:new_id ~data:id;
               Type.free new_id level)
          | Var_t { contents = Link t } -> norm t
        in
        norm t

      let of_hole h =
        let free_ctx = ref IntMap.empty in
        let type_ = normalize_free free_ctx h.Hole.type_ in
        let type_ctx = StaticDistance.Map.map h.Hole.ctx ~f:(normalize_free free_ctx) in
        ({ ctx = type_ctx; symbol = h.Hole.symbol; type_; }, !free_ctx)
    end

    type t = {
      hole : Hole_without_id.t;
      spec : Specification.t;
    } with compare, sexp

    let hash = Hashtbl.hash

    let of_hole_spec hole spec =
      let (hole, map) = Hole_without_id.of_hole hole in
      ({ hole; spec; }, map)
  end

  module HoleTable = Hashtbl.Make(Key)
  module CostTable = Int.Table

  module HoleState = struct
    type t = {
      hypotheses : (Hypothesis.t * Unifier.t) list CostTable.t;
      generalizations : (Hypothesis.t * Unifier.t) list Lazy.t;
    } with sexp
  end

  module Make (G: Generalizer_intf) (D: Deduction_intf) : S = struct
    type t = HoleState.t HoleTable.t

    let create () = HoleTable.create ()

    let rec get m hole spec cost =
      if cost < 0 then raise (Invalid_argument "Argument out of range.") else
      if cost = 0 then [] else
        let module S = HoleState in
        let module H = Hypothesis in
        let (key, map) = Key.of_hole_spec hole spec in
        let state = HoleTable.find_or_add m key ~default:(fun () ->
            {
              S.hypotheses = CostTable.create ();
              S.generalizations = Lazy.from_fun (fun () -> G.generalize hole spec);
            })
        in
        let ret =
          match CostTable.find state.S.hypotheses cost with
          | Some hs -> hs
          | None ->
            let hs = List.concat_map (Lazy.force state.S.generalizations) ~f:(fun (p, p_u) ->
                match H.kind p with
                | H.Concrete -> if H.cost p = cost then [ (p, p_u) ] else []
                | H.Abstract -> if H.cost p  >= cost then [] else
                    let num_holes = List.length (H.holes p) in
                    let all_hole_costs =
                      Util.m_partition (cost - H.cost p) num_holes
                      |> List.concat_map ~f:Util.permutations
                    in
                    List.concat_map all_hole_costs ~f:(fun hole_costs ->
                        List.fold2_exn (H.holes p) hole_costs ~init:[ (p, p_u) ]
                          ~f:(fun hs (hole, spec) hole_cost ->
                              let hs =
                                List.filter_map hs ~f:(fun (h, u) ->
                                  Option.map (D.push_specifications_unification (H.skeleton h))
                                    ~f:(fun s -> L2_Hypothesis.of_skeleton s, u))
                              in
                              List.concat_map hs ~f:(fun (p, p_u) ->
                                  let children = get m hole spec hole_cost in
                                  List.map children ~f:(fun (c, c_u) ->
                                      let u = Unifier.compose c_u p_u in
                                      let h = H.fill_hole hole ~parent:p ~child:c in
                                      h, u))))
                    |> List.filter ~f:(fun (h, _) ->
                        (* let () = Debug.eprintf "Verifying %d %s" h.H.cost (H.to_string_hum h) in *)
                        match H.kind h with
                        | H.Concrete -> H.verify h
                        | H.Abstract -> failwiths "BUG: Did not fill in all holes." h H.sexp_of_t))
            in
            CostTable.add_exn state.S.hypotheses ~key:cost ~data:hs; hs
        in
        List.map ret ~f:(fun (h, u) -> (h, denormalize_unifier u map))
  end
end

module L2_Memoizer = Memoizer.Make
    (struct
      include Generalizer_impl

      let generalize hole spec =
        let symbol = hole.Hole.symbol in
        let generators =
          let open L2_Generalizer in
          if symbol = constant then
            [ generate_constants ]
          else if symbol = identifier then
            [ generate_identifiers ]
          else if symbol = lambda then
            [ ]
          else if symbol = expression then
            [ generate_expressions; generate_identifiers; generate_constants ]
          else if symbol = combinator then
            [ generate_expressions; generate_identifiers; generate_constants ]
          else
            failwiths "Unknown symbol type." symbol Symbol.sexp_of_t
        in
        List.concat_map generators ~f:(fun g -> g hole spec)
    end)
    (L2_Deduction)

module L2_Synthesizer = struct
  exception SynthesisException of Hypothesis.t

  let generalize_combinator hole spec =
    let symbol = hole.Hole.symbol in
    let generators =
      let open L2_Generalizer in
      if symbol = constant then
        [ generate_constants ]
      else if symbol = base_case then
        [ generate_constants; generate_identifiers ]
      else if symbol = identifier then
        [ generate_identifiers ]
      else if symbol = lambda then
        [ generate_lambdas ]
      else if symbol = expression then
        [ ]
      else if symbol = combinator then
        [ generate_combinators; ]
      else
        failwiths "Unknown symbol type." symbol Symbol.sexp_of_t
    in
    List.concat_map generators ~f:(fun g -> g hole spec)
    
  let memoizer = L2_Memoizer.create ()

  let total_cost (hypo_cost: int) (enum_cost: int) : int =
    hypo_cost + (Int.of_float (1.5 ** (Float.of_int enum_cost)))

  module AnnotatedH = struct
    type t = {
      hypothesis : Hypothesis.t;
      max_search_cost : int ref;
    }

    let of_hypothesis h = {
      hypothesis = h;
      max_search_cost = ref 0;
    }
  end

  let search hypo start_exh_cost end_cost : int =
    let module H = Hypothesis in
    let rec search (exh_cost: int) =
      (* If the cost of searching this level exceeds the max cost, end the search. *)
      if (total_cost (H.cost hypo) exh_cost) >= end_cost then exh_cost else
        (* Otherwise, examine the next row in the search tree. *)
        begin
          let num_holes = List.length (H.holes hypo) in
          List.concat_map (Util.m_partition exh_cost num_holes) ~f:(fun hole_costs ->
              List.fold2_exn (H.holes hypo) hole_costs ~init:[ (hypo, Unifier.empty) ]
                ~f:(fun hs (hole, spec) hole_cost -> List.concat_map hs ~f:(fun (p, p_u) ->
                    let children = L2_Memoizer.get memoizer hole spec hole_cost in
                    List.map children ~f:(fun (c, c_u) ->
                        let u = Unifier.compose c_u p_u in
                        let h = H.fill_hole hole ~parent:p ~child:c in
                        h, u))))
          |> List.iter ~f:(fun (h, _) ->
              match H.kind h with
              | H.Concrete -> if H.verify h then raise (SynthesisException h)
              | H.Abstract -> failwiths "BUG: Did not fill in all holes." h H.sexp_of_t);
          search (exh_cost + 1)
        end
    in
    search start_exh_cost

  let generalize_all ~generalize:gen hypo =
    let open Hypothesis in
    List.fold_left
      (List.sort ~cmp:(fun (h1, _) (h2, _) -> Hole.compare h1 h2) (holes hypo))
      ~init:[ hypo ]
      ~f:(fun hypos (hole, spec) ->
          let children = List.filter (gen hole spec) ~f:(fun (c, _) ->
              kind c = Abstract || Specification.verify spec (skeleton c))
          in
          List.map hypos ~f:(fun p -> List.map children ~f:(fun (c, u) ->
              apply_unifier (fill_hole hole ~parent:p ~child:c) u))
          |> List.concat

          (* After generalizing, try to push specifications down the
               skeleton. Filter out any hypothesis with a Bottom spec. *)
          |> List.filter_map ~f:(fun h ->
              Option.map (L2_Deduction.push_specifications (skeleton h))
                L2_Hypothesis.of_skeleton))
      
  let synthesize hypo ~cost:max_cost =
    let module H = Hypothesis in
    let module AH = AnnotatedH in
    let fresh_hypos = ref [ AH.of_hypothesis hypo ] in
    let stale_hypos = ref [] in

    try
      for cost = 1 to max_cost do
        (* Search each hypothesis that can be searched at this cost. If
           the search succeeds it will throw an exception. *)
        List.iter (!fresh_hypos @ !stale_hypos) ~f:(fun h ->
            if total_cost (H.cost h.AH.hypothesis) (!(h.AH.max_search_cost) + 1) <= cost then
              h.AH.max_search_cost := search h.AH.hypothesis !(h.AH.max_search_cost) cost);

        (* Generalize each hypothesis that is cheap enough to generalize. *)
        let (generalizable, remaining) = List.partition_tf !fresh_hypos ~f:(fun h ->
            (H.cost h.AH.hypothesis) < cost)
        in
        let children = List.concat_map generalizable ~f:(fun h ->
            (* let () = Debug.eprintf "Generalizing %s" (H.to_string h.AH.hypothesis) in *)
            generalize_all ~generalize:generalize_combinator h.AH.hypothesis
            |> List.map ~f:AH.of_hypothesis)
        in
        fresh_hypos := remaining @ children;
        stale_hypos := !stale_hypos @ generalizable;
      done; None
    with SynthesisException s -> Some s

  let initial_hypothesis examples =
    let exs = List.map examples ~f:(function
        | (`Apply (_, args), out) ->
          let ctx = StaticDistance.Map.empty in
          let args = List.map ~f:(Eval.eval (Ctx.empty ())) args in
          let ret = Eval.eval (Ctx.empty ()) out in
          ((ctx, args), ret)
        | ex -> failwiths "Unexpected example type." ex sexp_of_example)
              |> Specification.FunctionExamples.of_list_exn
    in
    let t = Infer.Type.normalize (Example.signature examples) in
    L2_Hypothesis.hole
      (Hole.create StaticDistance.Map.empty t L2_Generalizer.lambda)
      (Specification.FunctionExamples exs)
end
