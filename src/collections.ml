open Core.Std

module ListExt = struct
  include List

  let rec fold_left1 (l: 'a list) ~(f: 'a -> 'a -> 'a) : 'a = match l with
    | [] -> failwith "List must be non-empty."
    | [x] -> x
    | x::y::xs -> fold_left1 ((f x y)::xs) ~f:f

  let rec insert (l: 'a list) (x: 'a) ~(cmp: 'a -> 'a -> int) : 'a list =
    match l with
    | [] -> [x]
    | y::ys -> if cmp x y <= 0 then x::l else y::(insert ys x ~cmp:cmp)
end
module List = ListExt

module StreamExt = struct
  include Stream

  (* Create an infinite stream of 'value'. *)
  let repeat (value: 'a) : 'a t = from (fun _ -> Some value)

  (* Create a finite stream of 'value' of length 'n'. *)
  let repeat_n (n: int) (value: 'a) : 'a t =
    List.range 0 n |> List.map ~f:(fun _ -> value) |> of_list

  (* Concatenate two streams together. The second stream will not be
     inspected until the first stream is exhausted. *)
  let concat s1 s2 =
    from (fun _ ->
        match peek s1 with
        | Some _ -> Some (next s1)
        | None -> (match peek s2 with
            | Some _ -> Some (next s2)
            | None -> None))

  (* Map a function over a stream. *)
  let map s ~f = from (fun _ -> try Some (f (next s)) with Failure -> None)

  let group s ~break =
    from (fun _ ->
        let rec collect () =
          match npeek 2 s with
          | [] -> None
          | [_] -> Some [next s]
          | [x; y] -> if break x y then Some [next s] else collect ()
          | _ -> failwith "Stream.npeek returned a larger list than expected."
        in collect ())
end

module Stream = StreamExt

module Matrix = struct
  type 'a t = ('a list) Stream.t

  (* Map a function over a matrix. *)
  let map s ~f = Stream.map s ~f:(List.map ~f:f)

  let trans : (('a Stream.t) list -> 'a t) = function
    | [] -> Stream.repeat []
    | ss -> Stream.from (fun _ -> Some (List.map ss ~f:Stream.next))

  let diag (s: ('a Stream.t) Stream.t) : 'a t =
    Stream.from (fun i ->
        Some (List.map (Stream.npeek (i + 1) s) ~f:Stream.next))

  let join (x: ('a t) t) : 'a t =
    Stream.map x ~f:trans
    |> diag
    |> Stream.map ~f:(fun y -> y |> List.concat |> List.concat)

  let compose (f: 'a -> 'b t) (g: 'b -> 'c t) (x: 'a) : 'c t =
    x |> f |> (Stream.map ~f:(List.map ~f:g)) |> join
end

module Memoizer (Key: Map.Key) (Value: sig type t end) = struct
  module KMap = Map.Make(Key)

  type memo_stream = {
    index: int ref;
    head: Value.t list Int.Table.t;
    stream: Value.t Matrix.t;
  }
  type t = memo_stream KMap.t ref

  let empty () = ref KMap.empty

  (* Get access to a stream of results for 'typ'. *)
  let get memo typ stream : Value.t Matrix.t =
    let mstream = match KMap.find !memo typ with
      | Some s -> s
      | None ->
        let s = { index = ref 0; head = Int.Table.create (); stream = stream (); } in
        memo := KMap.add !memo ~key:typ ~data:s; s
    in
    Stream.from (fun i ->
        let sc = i + 1 in
        if sc <= !(mstream.index) then Some (Int.Table.find_exn mstream.head sc)
        else begin
          List.range ~stop:`inclusive (!(mstream.index) + 1) sc
          |> List.iter ~f:(fun j ->
              try
                Int.Table.add_exn
                  mstream.head ~key:j ~data:(Stream.next mstream.stream);
                incr mstream.index;
              with Stream.Failure -> ());
          if sc = !(mstream.index)
          then Some (Int.Table.find_exn mstream.head sc)
          else None
        end)
end

(** An inverted index maps sets to values so that queries can be
    performed that select all super- or sub-sets of the query set. *)
module InvertedIndex
    (KeyElem: sig
       type t
       val t_of_sexp : Sexplib.Sexp.t -> t
       val sexp_of_t : t -> Sexplib.Sexp.t
       val compare : t -> t -> int
     end)
    (Value: sig type t end) =
struct
  module KMap = Map.Make(KeyElem)
  module KSet = Set.Make(KeyElem)

  module KVPair = struct
    type t = KSet.t * Value.t

    let compare (x: t) (y: t) =
      let (x', _), (y', _) = x, y in
      KSet.compare x' y'
  end

  module IntPairSet = Set.Make(struct
      type t = int * int with sexp, compare
    end)

  type perf_counters = {
    mutable total_lookups: int;
    mutable total_full_lookups: int;
    mutable total_set_ops: int;
    mutable total_results_examined: int;
  }

  type t = {
    mutable index: IntPairSet.t KMap.t;
    store: KVPair.t Int.Table.t;
    fresh_int: unit -> int;
    perf: perf_counters;
  }

  let create () : t =
    {
      index = KMap.empty;
      store = Int.Table.create ();
      fresh_int = Util.Fresh.mk_fresh_int_fun ();
      perf =
        {
          total_lookups = 0;
          total_full_lookups = 0;
          total_set_ops = 0;
          total_results_examined = 0;
        };
    }

  let add (i: t) (k: KSet.t) (v: Value.t) : unit =
    let kv_key = i.fresh_int () in
    let kv_key_pair = (kv_key, Set.length k) in

    (* Generate a new index where the list mapped to each element in k
       contains the reference to the (k, v) pair *)
    let index' =
      List.fold_left (Set.to_list k) ~init:i.index ~f:(fun i e ->
          match KMap.find i e with
          | Some s -> KMap.add i ~key:e ~data:(IntPairSet.add s kv_key_pair)
          | None -> KMap.add i ~key:e ~data:(IntPairSet.singleton kv_key_pair))
    in

    (* Update the index. *)
    i.index <- index';

    (* Update the key-value store. *)
    Hashtbl.add_exn i.store ~key:kv_key ~data:(k, v)

  (* Merge a list of result lists. *)
  let merge_results = IntPairSet.union_list

  let store_lookup store id =
    try Hashtbl.find_exn store id with
    | Not_found -> failwith "Index contains reference to nonexistent item."

  let exists_subset_or_superset
      (i: t)
      (s: KSet.t)
      (subset_v: Value.t)
      (superset_v: Value.t) : Value.t option =
    let len = Set.length s in

    (* For each value in the query set, use the index to get
       references to the sets that contain that value. *)
    let result_ref_lists =
      List.filter_map (Set.to_list s) ~f:(fun elem ->
          match KMap.find i.index elem with
          | Some refs as r ->
            if Set.length refs = Hashtbl.length i.store then None else r
          | None -> None)
    in

    (* Merge the result lists. *)
    let result_refs = merge_results result_ref_lists in

    (* Update performance counters *)
    i.perf.total_lookups <- i.perf.total_lookups + 1;
    if Set.length result_refs = Hashtbl.length i.store then
      i.perf.total_full_lookups <- i.perf.total_full_lookups + 1;
    i.perf.total_results_examined <-
      i.perf.total_results_examined + Set.length result_refs;

    Set.find_map result_refs ~f:(fun (id, len') ->
        let (s', v') = store_lookup i.store id in
        if len' < len then
          if v' = subset_v && Set.subset s' s then
            (i.perf.total_set_ops <- i.perf.total_set_ops + 1; Some subset_v)
          else None
        else if len' = len then
          if v' = subset_v && Set.subset s' s then
            (i.perf.total_set_ops <- i.perf.total_set_ops + 1; Some subset_v)
          else if v' = superset_v && Set.subset s s' then
            (i.perf.total_set_ops <- i.perf.total_set_ops + 1; Some superset_v)
          else None
        else
        if v' = superset_v && Set.subset s s' then
          (i.perf.total_set_ops <- i.perf.total_set_ops + 1; Some superset_v)
        else None)

  (* Return a summary of the performance counters suitable for writing to a log. *)
  let log_summary (i: t) : string =
    sprintf "Total set operations: %d\n" i.perf.total_set_ops ^
    sprintf "Full lookups/Total lookups: %d/%d\n"
      i.perf.total_full_lookups i.perf.total_lookups ^
    sprintf "Average results per lookup: %f\n"
      ((Float.of_int i.perf.total_results_examined) /.
       (Float.of_int i.perf.total_lookups)) ^
    sprintf "Distinct set elements: %d\n" (Map.length i.index) ^
    sprintf "Total sets stored: %d\n" (Hashtbl.length i.store)
end

module StringMap = Map.Make(String)

module Ctx = struct
  type 'a t = 'a StringMap.t ref with compare
  exception UnboundError of string

  (** Return an empty context. *)
  let empty () : 'a t = ref StringMap.empty

  (** Look up an id in a context. *)
  let lookup ctx id = StringMap.find !ctx id
  let lookup_exn ctx id = match lookup ctx id with
    | Some v -> v
    | None -> raise (UnboundError id)

  (** Bind a type or value to an id, returning a new context. *)
  let bind ctx id data = ref (StringMap.add !ctx ~key:id ~data:data)
  let bind_alist ctx alist =
    List.fold alist ~init:ctx ~f:(fun ctx' (id, data) -> bind ctx' id data)

  (** Remove a binding from a context, returning a new context. *)
  let unbind ctx id = ref (StringMap.remove !ctx id)

  (** Bind a type or value to an id, updating the context in place. *)
  let update ctx id data = ctx := StringMap.add !ctx ~key:id ~data:data

  (** Remove a binding from a context, updating the context in place. *)
  let remove ctx id = ctx := StringMap.remove !ctx id

  let merge c1 c2 ~f:f = ref (StringMap.merge !c1 !c2 ~f:f)
  let merge_right (c1: 'a t) (c2: 'a t) : 'a t =
    merge ~f:(fun ~key v -> match v with
        | `Both (_, v) | `Left v | `Right v -> Some v)
      c1 c2
  let map ctx ~f:f = ref (StringMap.map !ctx ~f:f)
  let mapi ctx ~f:f = ref (StringMap.mapi !ctx ~f:f)
  let filter ctx ~f:f = ref (StringMap.filter !ctx ~f:f)
  let filter_mapi ctx ~f:f = ref (StringMap.filter_mapi !ctx ~f:f)

  let equal cmp c1 c2 = StringMap.equal cmp !c1 !c2

  let keys ctx = StringMap.keys !ctx
  let data ctx = StringMap.data !ctx

  let of_alist alist = ref (StringMap.of_alist alist)
  let of_alist_exn alist = ref (StringMap.of_alist_exn alist)
  let of_alist_mult alist = ref (StringMap.of_alist_multi alist)

  let to_alist ctx = StringMap.to_alist !ctx
  let to_string (ctx: 'a t) (str: 'a -> string) : string =
    to_alist ctx
    |> List.map ~f:(fun (key, value) -> key ^ ": " ^ (str value))
    |> String.concat ~sep:", "
    |> fun s -> "{ " ^ s ^ " }"
end

module Timings = struct
  type timing_info = {
    time : Time.Span.t;
    desc : string
  }

  type t = timing_info Ctx.t

  let empty () : t = Ctx.empty ()

  let add_zero (t: t) (name: string) (desc: string) : unit =
    Ctx.update t name { time = Time.Span.zero; desc; }

  let add (t: t) (name: string) (time: Time.Span.t) : unit =
    let time' = Ctx.lookup_exn t name in
    Ctx.update t name { time' with time = Time.Span.(+) time time'.time }

  let run_with_time (t: t) (name: string) (thunk: unit -> 'a) : 'a =
    let start_t = Time.now () in
    let x = thunk () in
    let end_t = Time.now () in
    add t name (Time.diff end_t start_t); x

  let to_strings (t: t) : string list =
    List.map (Ctx.data t) ~f:(fun { desc = d; time = t } ->
        sprintf "%s: %s" d (Time.Span.to_short_string t))
end
