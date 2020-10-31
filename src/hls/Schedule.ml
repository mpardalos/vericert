(*
 * Vericert: Verified high-level synthesis.
 * Copyright (C) 2020 Yann Herklotz <yann@yannherklotz.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *)

open Printf
open Clflags
open Camlcoq
open Datatypes
open Coqlib
open Maps
open AST
open Kildall
open Op
open RTLBlock
open HTL
open Verilog
open HTLgen
open HTLMonad
open HTLMonadExtra

module IMap = Map.Make (struct
  type t = int

  let compare = compare
end)

type dfg = { nodes : instruction list; edges : (int * int) list }
(** The DFG type defines a list of instructions with their data dependencies as [edges], which are
   the pairs of integers that represent the index of the instruction in the [nodes].  The edges
   always point from left to right. *)

let print_list f out_chan a =
  fprintf out_chan "[ ";
  List.iter (fprintf out_chan "%a " f) a;
  fprintf out_chan "]"

let print_tuple out_chan a =
  let l, r = a in
  fprintf out_chan "(%d,%d)" l r

let print_dfg out_chan dfg =
  fprintf out_chan "{ nodes = %a, edges = %a }"
    (print_list PrintRTLBlock.print_bblock_body)
    dfg.nodes (print_list print_tuple) dfg.edges

let read_process command =
  let buffer_size = 2048 in
  let buffer = Buffer.create buffer_size in
  let string = Bytes.create buffer_size in
  let in_channel = Unix.open_process_in command in
  let chars_read = ref 1 in
  while !chars_read <> 0 do
    chars_read := input in_channel string 0 buffer_size;
    Buffer.add_substring buffer (Bytes.to_string string) 0 !chars_read
  done;
  ignore (Unix.close_process_in in_channel);
  Buffer.contents buffer

(** Add a dependency if it uses a register that was written to previously. *)
let add_dep i tree deps curr =
  match PTree.get curr tree with None -> deps | Some ip -> (ip, i) :: deps

(** This function calculates the dependencies of each instruction.  The nodes correspond to previous
   register that were allocated and show which instruction caused it.

   This function only gathers the RAW constraints, and will therefore only be active for operations
   that modify registers, which is this case only affects loads and operations. *)
let accumulate_RAW_deps dfg curr =
  let i, dst_map, { edges; nodes } = dfg in
  let acc_dep_instruction rs dst =
    ( i + 1,
      PTree.set dst i dst_map,
      {
        nodes;
        edges = List.append (List.fold_left (add_dep i dst_map) [] rs) edges;
      } )
  in
  let acc_dep_instruction_nodst rs =
    ( i + 1,
      dst_map,
      {
        nodes;
        edges = List.append (List.fold_left (add_dep i dst_map) [] rs) edges;
      } )
  in
  match curr with
  | RBop (_, rs, dst) -> acc_dep_instruction rs dst
  | RBload (_mem, _addr, rs, dst) -> acc_dep_instruction rs dst
  | RBstore (_mem, _addr, rs, src) -> acc_dep_instruction_nodst (src :: rs)
  | _ -> (i + 1, dst_map, { edges; nodes })

(** Finds the next write to the [dst] register.  This is a small optimisation so that only one
   dependency is generated for a data dependency. *)
let rec find_next_dst_write i dst i' curr =
  let check_dst dst' curr' =
    if dst = dst' then Some (i, i')
    else find_next_dst_write i dst (i' + 1) curr'
  in
  match curr with
  | [] -> None
  | RBop (_, _, dst') :: curr' -> check_dst dst' curr'
  | RBload (_, _, _, dst') :: curr' -> check_dst dst' curr'
  | _ :: curr' -> find_next_dst_write i dst (i' + 1) curr'

let rec find_all_next_dst_read i dst i' curr =
  let check_dst rs curr' =
    if List.exists (fun x -> x = dst) rs
    then (i, i') :: find_all_next_dst_read i dst (i' + 1) curr'
    else find_all_next_dst_read i dst (i' + 1) curr'
  in
  match curr with
  | [] -> []
  | RBop (_, rs, _) :: curr' -> check_dst rs curr'
  | RBload (_, _, rs, _) :: curr' -> check_dst rs curr'
  | RBstore (_, _, rs, src) :: curr' -> check_dst (src :: rs) curr'
  | RBnop :: curr' -> find_all_next_dst_read i dst (i' + 1) curr'

let drop i lst =
  let rec drop' i' lst' =
    match lst' with
    | _ :: ls -> if i' = i then ls else drop' (i' + 1) ls
    | [] -> []
  in
  if i = 0 then lst else drop' 1 lst

let take i lst =
  let rec take' i' lst' =
    match lst' with
    | l :: ls -> if i' = i then [ l ] else l :: take' (i' + 1) ls
    | [] -> []
  in
  if i = 0 then [] else take' 1 lst

let rec next_store i = function
  | [] -> None
  | RBstore (_, _, _, _) :: _ -> Some i
  | _ :: rst -> next_store (i + 1) rst

let rec next_load i = function
  | [] -> None
  | RBload (_, _, _, _) :: _ -> Some i
  | _ :: rst -> next_load (i + 1) rst

let accumulate_RAW_mem_deps dfg curr =
  let i, { nodes; edges } = dfg in
  match curr with
  | RBload (_, _, _, _) -> (
      match next_store 0 (take i nodes |> List.rev) with
      | None -> (i + 1, { nodes; edges })
      | Some d -> (i + 1, { nodes; edges = (i - d - 1, i) :: edges }) )
  | _ -> (i + 1, { nodes; edges })

let accumulate_WAR_mem_deps dfg curr =
  let i, { nodes; edges } = dfg in
  match curr with
  | RBstore (_, _, _, _) -> (
      match next_load 0 (take i nodes |> List.rev) with
      | None -> (i + 1, { nodes; edges })
      | Some d -> (i + 1, { nodes; edges = (i - d - 1, i) :: edges }) )
  | _ -> (i + 1, { nodes; edges })

let accumulate_WAW_mem_deps dfg curr =
  let i, { nodes; edges } = dfg in
  match curr with
  | RBstore (_, _, _, _) -> (
      match next_store 0 (take i nodes |> List.rev) with
      | None -> (i + 1, { nodes; edges })
      | Some d -> (i + 1, { nodes; edges = (i - d - 1, i) :: edges }) )
  | _ -> (i + 1, { nodes; edges })

(** This function calculates the WAW dependencies, which happen when two writes are ordered one
   after another and therefore have to be kept in that order.  This accumulation might be redundant
   if register renaming is done before hand, because then these dependencies can be avoided. *)
let accumulate_WAW_deps dfg curr =
  let i, { edges; nodes } = dfg in
  let dst_dep dst =
    match find_next_dst_write i dst (i + 1) (drop (i + 1) nodes) with
    | Some d -> (i + 1, { nodes; edges = d :: edges })
    | _ -> (i + 1, { nodes; edges })
  in
  match curr with
  | RBop (_, _, dst) -> dst_dep dst
  | RBload (_, _, _, dst) -> dst_dep dst
  | RBstore (_, _, _, _) -> (
      match next_store (i + 1) (drop (i + 1) nodes) with
      | None -> (i + 1, { nodes; edges })
      | Some i' -> (i + 1, { nodes; edges = (i, i') :: edges }) )
  | _ -> (i + 1, { nodes; edges })

let accumulate_WAR_deps dfg curr =
  let i, { edges; nodes } = dfg in
  let dst_dep dst =
    let dep_list = find_all_next_dst_read i dst 0 (take i nodes |> List.rev)
        |> List.map (function (d, d') -> (i - d' - 1, d))
    in
    (i + 1, { nodes; edges = List.append dep_list edges })
  in
  match curr with
  | RBop (_, _, dst) -> dst_dep dst
  | RBload (_, _, _, dst) -> dst_dep dst
  | _ -> (i + 1, { nodes; edges })

let assigned_vars vars = function
  | RBnop -> vars
  | RBop (_, _, dst) -> dst :: vars
  | RBload (_, _, _, dst) -> dst :: vars
  | RBstore (_, _, _, _) -> vars

(** All the nodes in the DFG have to come after the source of the basic block, and should terminate
   before the sink of the basic block.  After that, there should be constraints for data
   dependencies between nodes. *)
let gather_bb_constraints debug bb =
  let _, _, dfg =
    List.fold_left accumulate_RAW_deps
      (0, PTree.empty, { nodes = bb.bb_body; edges = [] })
      bb.bb_body
  in
  if debug then printf "DFG : %a\n" print_dfg dfg else ();
  let _, dfg' = List.fold_left accumulate_WAW_deps (0, dfg) bb.bb_body in
  if debug then printf "DFG': %a\n" print_dfg dfg' else ();
  let _, dfg'' = List.fold_left accumulate_WAR_deps (0, dfg') bb.bb_body in
  if debug then printf "DFG'': %a\n" print_dfg dfg'' else ();
  let _, dfg''' =
    List.fold_left accumulate_RAW_mem_deps (0, dfg'') bb.bb_body
  in
  if debug then printf "DFG''': %a\n" print_dfg dfg''' else ();
  let _, dfg'''' =
    List.fold_left accumulate_WAR_mem_deps (0, dfg''') bb.bb_body
  in
  if debug then printf "DFG'''': %a\n" print_dfg dfg'''' else ();
  let _, dfg''''' =
    List.fold_left accumulate_WAW_mem_deps (0, dfg'''') bb.bb_body
  in
  if debug then printf "DFG''''': %a\n" print_dfg dfg''''' else ();
  match bb.bb_exit with
  | None -> assert false
  | Some e -> (List.length bb.bb_body, dfg''''', successors_instr e)

let gen_bb_name s i = sprintf "bb%d%s" (P.to_int i) s

let gen_bb_name_ssrc = gen_bb_name "ssrc"

let gen_bb_name_ssnk = gen_bb_name "ssnk"

let gen_var_name s c i = sprintf "v%d%s_%d" (P.to_int i) s c

let gen_var_name_b = gen_var_name "b"

let gen_var_name_e = gen_var_name "e"

let print_lt0 = sprintf "%s - %s <= 0;\n"

let print_bb_order i c = if P.to_int c < P.to_int i then
    print_lt0 (gen_bb_name_ssnk i) (gen_bb_name_ssrc c) else
    ""

let print_src_order i c =
  print_lt0 (gen_bb_name_ssrc i) (gen_var_name_b c i)
  ^ print_lt0 (gen_var_name_e c i) (gen_bb_name_ssnk i)
  ^ sprintf "%s - %s = 1;\n" (gen_var_name_e c i) (gen_var_name_b c i)

let print_src_type i c =
  sprintf "int %s;\n" (gen_var_name_e c i)
  ^ sprintf "int %s;\n" (gen_var_name_b c i)

let print_data_dep_order c (i, j) =
  print_lt0 (gen_var_name_e i c) (gen_var_name_b j c)

let rec gather_cfg_constraints (completed, (bvars, constraints, types)) c curr =
  if List.exists (fun x -> P.eq x curr) completed then
    (completed, (bvars, constraints, types))
  else
    match PTree.get curr c with
    | None -> assert false
    | Some (num_iters, dfg, next) ->
        let constraints' =
          constraints
          ^ String.concat "" (List.map (print_bb_order curr) next)
          ^ String.concat ""
              (List.map (print_src_order curr)
                 (List.init num_iters (fun x -> x)))
          ^ String.concat "" (List.map (print_data_dep_order curr) dfg.edges)
        in
        let types' =
          types
          ^ String.concat ""
              (List.map (print_src_type curr)
                 (List.init num_iters (fun x -> x)))
          ^ sprintf "int %s;\n" (gen_bb_name_ssrc curr)
          ^ sprintf "int %s;\n" (gen_bb_name_ssnk curr)
        in
        let bvars' =
          List.append
            (List.map
               (fun x -> gen_var_name_b x curr)
               (List.init num_iters (fun x -> x)))
            bvars
        in
        let next' = List.filter (fun x -> P.lt x curr) next in
        List.fold_left
          (fun compl curr' -> gather_cfg_constraints compl c curr')
          (curr :: completed, (bvars', constraints', types'))
          next'

let rec intersperse s = function
  | [] -> []
  | [ a ] -> [ a ]
  | x :: xs -> x :: s :: intersperse s xs

let update_schedule v = function Some l -> Some (v :: l) | None -> Some [ v ]

let parse_soln tree s =
  let r = Str.regexp "v\([0-9]+\)b_\([0-9]+\)[ ]+\([0-9]+\)" in
  if Str.string_match r s 0 then
    IMap.update
      (Str.matched_group 1 s |> int_of_string)
      (update_schedule
         ( Str.matched_group 2 s |> int_of_string,
           Str.matched_group 3 s |> int_of_string ))
      tree
  else tree

let solve_constraints vars constraints types =
  let oc = open_out "lpsolve.txt" in
  fprintf oc "min: ";
  List.iter (fprintf oc "%s") (intersperse " + " vars);
  fprintf oc ";\n";
  fprintf oc "%s" constraints;
  fprintf oc "%s" types;
  close_out oc;
  Str.split (Str.regexp_string "\n") (read_process "lp_solve lpsolve.txt")
  |> drop 3
  |> List.fold_left parse_soln IMap.empty

let find_min = function
  | [] -> assert false
  | l :: ls ->
      let rec find_min' current = function
        | [] -> current
        | l' :: ls' ->
            if snd l' < current then find_min' (snd l') ls'
            else find_min' current ls'
      in
      find_min' (snd l) ls

let find_max = function
  | [] -> assert false
  | l :: ls ->
      let rec find_max' current = function
        | [] -> current
        | l' :: ls' ->
            if snd l' > current then find_max' (snd l') ls'
            else find_max' current ls'
      in
      find_max' (snd l) ls

type registers = { reg_finish : reg; reg_return : reg; reg_stk : reg }

let ( >>= ) = bind

let translate_control_flow r curr_st instr =
  match instr with
  | RBgoto n ->
      fun state ->
        OK
          ( (),
            {
              state with
              st_controllogic =
                PTree.set curr_st (state_goto state.st_st n)
                  state.st_controllogic;
            } )
  | RBcond (c, rs, n1, n2) ->
      translate_condition c rs >>= fun ce state ->
      OK
        ( (),
          {
            state with
            st_controllogic =
              PTree.set curr_st
                (state_cond state.st_st ce n1 n2)
                state.st_controllogic;
          } )
  | RBreturn ret -> (
      let new_state state = state.st_freshstate in
      match ret with
      | None ->
          let fin =
            Vseq
              ( HTLgen.block r.reg_finish
                  (Vlit (ValueInt.coq_ZToValue (Z.of_uint 1))),
                HTLgen.block r.reg_return
                  (Vlit (ValueInt.coq_ZToValue (Z.of_uint 0))) )
          in
          fun state ->
            OK
              ( (),
                {
                  state with
                  st_datapath =
                    PTree.set (new_state state) fin state.st_datapath;
                  st_controllogic =
                    PTree.set curr_st
                      (state_goto state.st_st (new_state state))
                      state.st_controllogic;
                  st_freshstate = P.succ state.st_freshstate;
                } )
      | Some ret' ->
          let fin =
            Vseq
              ( HTLgen.block r.reg_finish
                  (Vlit (ValueInt.coq_ZToValue (Z.of_uint 1))),
                HTLgen.block r.reg_return (Vvar ret') )
          in
          fun state ->
            OK
              ( (),
                {
                  state with
                  st_datapath =
                    PTree.set (new_state state) fin state.st_datapath;
                  st_controllogic =
                    PTree.set curr_st
                      (state_goto state.st_st (new_state state))
                      state.st_controllogic;
                  st_freshstate = P.succ state.st_freshstate;
                } ) )
  | RBjumptable (r, tbl) ->
      fun state ->
      OK ( (),
        {
          state with
          st_controllogic = PTree.set curr_st (Vcase (Vvar r, HTLgen.tbl_to_case_expr state.st_st tbl, Some Vskip)) state.st_controllogic
        })
  | _ ->
      error
        (Errors.msg
           (coqstring_of_camlstring
              "Control flow instructions not implemented."))

let translate_instr r curr_st instr =
  let prev_instr state =
    match PTree.get curr_st state.st_datapath with None -> Vskip | Some v -> v
  in
  match instr with
  | RBnop ->
      fun state ->
        OK
          ( (),
            {
              state with
              st_datapath =
                PTree.set curr_st (prev_instr state) state.st_datapath;
            } )
  | RBop (op, rs, dst) ->
      translate_instr op rs >>= fun instr ->
      declare_reg None dst (Nat.of_int 32) >>= fun _ state ->
      let stmnt = Vseq (prev_instr state, nonblock dst instr) in
      OK
        ( (),
          { state with st_datapath = PTree.set curr_st stmnt state.st_datapath }
        )
  | RBload (mem, addr, rs, dst) ->
      translate_arr_access mem addr rs r.reg_stk >>= fun src ->
      declare_reg None dst (Nat.of_int 32) >>= fun _ state ->
      let stmnt = Vseq (prev_instr state, nonblock dst src) in
      OK
        ( (),
          { state with st_datapath = PTree.set curr_st stmnt state.st_datapath }
        )
  | RBstore (mem, addr, rs, src) ->
      translate_arr_access mem addr rs r.reg_stk >>= fun dst state ->
      OK
        ( (),
          {
            state with
            st_datapath =
              PTree.set curr_st
                (Vseq (prev_instr state, Vnonblock (dst, Vvar src)))
                state.st_datapath;
          } )

let combine_bb_schedule schedule s =
  let i, st = s in
  IMap.update st (update_schedule i) schedule

let add_schedules r bb_body min_sched curr ischedule =
  let i, schedule = ischedule in
  let curr_state = curr - i + min_sched in
  let instrs = List.map (List.nth bb_body) schedule in
  if curr_state = 20 then printf "HII: curr_state: %d : curr: %d\n" curr_state curr;
  collectlist (translate_instr r (P.of_int curr_state)) instrs >>= fun _ ->
  translate_control_flow r (P.of_int curr_state)
    (RBgoto (curr_state - 1 |> P.of_int))

(** Should generate the [HTL] code based on the input [RTLBlock] description. *)
let transf_htl r c (schedule : (int * int) list IMap.t) =
  let f bbs =
    let i, bb = bbs in
    match bb with
    | { bb_body = []; bb_exit = Some c } -> translate_control_flow r i c
    | { bb_body = bb_body'; bb_exit = Some ctrl_flow } ->
        let i_sched =
          try IMap.find (P.to_int i) schedule
          with Not_found -> (
            printf "Could not find %d\n" (P.to_int i);
            IMap.iter
              (fun d -> printf "%d: %a\n" d (print_list print_tuple))
              schedule;
            assert false
          )
        in
        let min_state = find_min i_sched in
        let max_state = find_max i_sched in
        let i_sched_tree =
          List.fold_left combine_bb_schedule IMap.empty i_sched
        in
        collectlist
          (add_schedules r bb_body' min_state (P.to_int i))
          (IMap.to_seq i_sched_tree |> List.of_seq)
        >>= fun _ ->
        printf "--------------- curr: %d, max: %d, min: %d, next: %d\n" (P.to_int i) max_state min_state (P.to_int i - max_state + min_state - 1);
        printf "HIIIII: %d orig: %d\n" (P.to_int i - max_state + min_state - 1) (P.to_int i);
        (match ctrl_flow with
         | RBgoto _ ->
           translate_control_flow r (P.of_int (P.to_int i - max_state + min_state)) ctrl_flow
         | _ ->
           translate_control_flow r (P.of_int (P.to_int i - max_state + min_state - 1)) ctrl_flow)
    | _ ->
        coqstring_of_camlstring "Illegal state reached in scheduler"
        |> Errors.msg |> error
  in
  collectlist f c

let second = function (_, a, _) -> a

let schedule entry r (c : code) =
  let debug = true in
  let c' = PTree.map1 (gather_bb_constraints false) c in
  let _ = if debug then PTree.map (fun r o -> printf "##### %d #####\n%a\n\n" (P.to_int r) print_dfg (second o)) c' else PTree.empty in
  let _, (vars, constraints, types) =
    gather_cfg_constraints ([], ([], "", "")) c' entry
  in
  let schedule' = solve_constraints vars constraints types in
  IMap.iter (fun a b -> printf "##### %d #####\n%a\n\n" a (print_list print_tuple) b) schedule';
  (*printf "Schedule: %a\n" (fun a x -> IMap.iter (fun d -> fprintf a "%d: %a\n" d (print_list print_tuple)) x) schedule';*)
  transf_htl r (PTree.elements c) schedule'

let transl_module' (f : RTLBlock.coq_function) : HTL.coq_module mon =
  create_reg (Some Voutput) (Nat.of_int 1) >>= fun fin ->
  create_reg (Some Voutput) (Nat.of_int 32) >>= fun rtrn ->
  create_arr None (Nat.of_int 32) (Nat.of_int (Z.to_int f.fn_stacksize / 4))
  >>= fun stack_var ->
  let stack, stack_len = stack_var in
  schedule f.fn_entrypoint
    { reg_finish = fin; reg_return = rtrn; reg_stk = stack }
    f.fn_code
  >>= fun _ ->
  collectlist (fun r -> declare_reg (Some Vinput) r (Nat.of_int 32)) f.fn_params
  >>= fun _ ->
  create_reg (Some Vinput) (Nat.of_int 1) >>= fun start ->
  create_reg (Some Vinput) (Nat.of_int 1) >>= fun rst ->
  create_reg (Some Vinput) (Nat.of_int 1) >>= fun clk current_state ->
  let m =
    {
      HTL.mod_params = f.fn_params;
      HTL.mod_datapath = current_state.st_datapath;
      HTL.mod_controllogic = current_state.st_controllogic;
      HTL.mod_entrypoint = f.fn_entrypoint;
      HTL.mod_st = current_state.st_st;
      HTL.mod_stk = stack;
      HTL.mod_stk_len = stack_len;
      HTL.mod_finish = fin;
      HTL.mod_return = rtrn;
      HTL.mod_start = start;
      HTL.mod_reset = rst;
      HTL.mod_clk = clk;
      HTL.mod_scldecls = current_state.st_scldecls;
      HTL.mod_arrdecls = current_state.st_arrdecls;
    }
  in
  OK (m, current_state)

let max_state f =
  let st = P.of_int 10000 in
  {
    (init_state st) with
    st_st = st;
    st_freshreg = P.succ st;
    st_freshstate = P.of_int 10000;
    st_scldecls =
      AssocMap.AssocMap.set st (None, Nat.of_int 32) (init_state st).st_scldecls;
  }

let transl_module (f : RTLBlock.coq_function) : HTL.coq_module Errors.res =
  run_mon (max_state f) (transl_module' f)