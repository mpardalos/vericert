(*
 * Vericert: Verified high-level synthesis.
 * Copyright (C) 2020 Yann Herklotz <yann@yannherklotz.com>
 *               2020 James Pollard <j@mes.dev>
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

Require Import Coq.FSets.FMapPositive.

Require compcert.common.Events.
Require compcert.common.Globalenvs.
Require compcert.common.Smallstep.
Require compcert.common.Values.
Require compcert.lib.Integers.
Require Import compcert.lib.Maps.

Require Import vericert.common.Vericertlib.
Require Import vericert.hls.ValueInt.
Require Import vericert.hls.AssocMap.
Require Import vericert.hls.Array.
Require vericert.hls.Verilog.

(** The purpose of the hardware transfer language (HTL) is to create a more
hardware-like layout that is still similar to the register transfer language
(RTL) that it came from. The main change is that function calls become module
instantiations and that we now describe a state machine instead of a
control-flow graph. *)

Local Open Scope assocmap.

Definition reg := positive.
Definition node := positive.
Definition ident := positive.

Inductive datapath_stmnt :=
| HTLfork : ident -> list reg -> datapath_stmnt
| HTLjoin : ident -> reg -> datapath_stmnt
| HTLDataVstmnt : Verilog.stmnt -> datapath_stmnt.

Inductive control_stmnt :=
| HTLwait : ident -> reg -> Verilog.expr -> control_stmnt
| HTLCtrlVstmnt : Verilog.stmnt -> control_stmnt.

Definition datapath := PTree.t datapath_stmnt.
Definition controllogic := PTree.t control_stmnt.

Definition map_well_formed {A : Type} (m : PTree.t A) : Prop :=
  forall p0 : positive,
    In p0 (map fst (Maps.PTree.elements m)) ->
    Z.pos p0 <= Integers.Int.max_unsigned.

Record module: Type :=
  mkmodule {
    mod_params : list reg;
    mod_datapath : datapath;
    mod_controllogic : controllogic;
    mod_entrypoint : node;
    mod_st : reg;
    mod_stk : reg;
    mod_stk_len : nat;
    mod_finish : reg;
    mod_return : reg;
    mod_start : reg;
    mod_reset : reg;
    mod_clk : reg;
    mod_scldecls : AssocMap.t (option Verilog.io * Verilog.scl_decl);
    mod_arrdecls : AssocMap.t (option Verilog.io * Verilog.arr_decl);
    mod_wf : (map_well_formed mod_controllogic /\ map_well_formed mod_datapath);
  }.

Definition fundef := AST.fundef module.

Definition program := AST.program fundef unit.

Fixpoint init_regs (vl : list value) (rl : list reg) {struct rl} :=
  match rl, vl with
  | r :: rl', v :: vl' => AssocMap.set r v (init_regs vl' rl')
  | _, _ => empty_assocmap
  end.

Definition empty_stack (m : module) : Verilog.assocmap_arr :=
  (AssocMap.set m.(mod_stk) (Array.arr_repeat None m.(mod_stk_len)) (AssocMap.empty Verilog.arr)).

(** * Operational Semantics *)

Definition genv := Globalenvs.Genv.t fundef unit.

Inductive stackframe : Type :=
  Stackframe :
    forall  (res : reg)
            (m : module)
            (pc : node)
            (reg_assoc : Verilog.assocmap_reg)
            (arr_assoc : Verilog.assocmap_arr),
      stackframe.

Inductive state : Type :=
| State :
    forall (stack : list stackframe)
           (m : module)
           (st : node)
           (reg_assoc : Verilog.assocmap_reg)
           (arr_assoc : Verilog.assocmap_arr), state
| Returnstate :
    forall (res : list stackframe)
           (v : value), state
| Callstate :
    forall (stack : list stackframe)
           (m : module)
           (args : list value), state.

Inductive datapath_stmnt_runp:
  Verilog.fext -> Verilog.reg_associations -> Verilog.arr_associations ->
  datapath_stmnt -> Verilog.reg_associations -> Verilog.arr_associations -> Prop :=
(* TODO give it an actual semantics *)
| stmnt_runp_HTLfork : forall f ar al i args,
    datapath_stmnt_runp f ar al (HTLfork i args) ar al
| stmnt_runp_HTLcall : forall f ar al i dst,
    datapath_stmnt_runp f ar al (HTLjoin i dst) ar al
| stmnt_runp_HTLDataVstmnt : forall asr0 asa0 asr1 asa1 f stmnt,
    Verilog.stmnt_runp f asr0 asa0 stmnt asr1 asa1 ->
    datapath_stmnt_runp f asr0 asa0 (HTLDataVstmnt stmnt) asr1 asa1.

Inductive control_stmnt_runp:
  Verilog.fext -> Verilog.reg_associations -> Verilog.arr_associations ->
  control_stmnt -> Verilog.reg_associations -> Verilog.arr_associations -> Prop :=
(* TODO give it an actual semantics *)
| stmnt_runp_HTLwait : forall f ar al i reg expr,
    control_stmnt_runp f ar al (HTLwait i reg expr) ar al
| stmnt_runp_HTLCtrlVstmnt : forall asr0 asa0 asr1 asa1 f stmnt,
    Verilog.stmnt_runp f asr0 asa0 stmnt asr1 asa1 ->
    control_stmnt_runp f asr0 asa0 (HTLCtrlVstmnt stmnt) asr1 asa1.

Inductive step : genv -> state -> Events.trace -> state -> Prop :=
| step_module :
    forall g m st sf ctrl data
      asr asa
      basr1 basa1 nasr1 nasa1
      basr2 basa2 nasr2 nasa2
      asr' asa'
      f pstval,
      asr!(mod_reset m) = Some (ZToValue 0) ->
      asr!(mod_finish m) = Some (ZToValue 0) ->
      asr!(m.(mod_st)) = Some (posToValue st) ->
      m.(mod_controllogic)!st = Some ctrl ->
      m.(mod_datapath)!st = Some data ->
      control_stmnt_runp f
        (Verilog.mkassociations asr empty_assocmap)
        (Verilog.mkassociations asa (empty_stack m))
        ctrl
        (Verilog.mkassociations basr1 nasr1)
        (Verilog.mkassociations basa1 nasa1) ->
      basr1!(m.(mod_st)) = Some (posToValue st) ->
      datapath_stmnt_runp f
        (Verilog.mkassociations basr1 nasr1)
        (Verilog.mkassociations basa1 nasa1)
        data
        (Verilog.mkassociations basr2 nasr2)
        (Verilog.mkassociations basa2 nasa2) ->
      asr' = Verilog.merge_regs nasr2 basr2 ->
      asa' = Verilog.merge_arrs nasa2 basa2 ->
      asr'!(m.(mod_st)) = Some (posToValue pstval) ->
      Z.pos pstval <= Integers.Int.max_unsigned ->
      step g (State sf m st asr asa) Events.E0 (State sf m pstval asr' asa')
| step_finish :
    forall g m st asr asa retval sf,
    asr!(m.(mod_finish)) = Some (ZToValue 1) ->
    asr!(m.(mod_return)) = Some retval ->
    step g (State sf m st asr asa) Events.E0 (Returnstate sf retval)
| step_call :
    forall g m args res,
      step g (Callstate res m args) Events.E0
           (State res m m.(mod_entrypoint)
             (AssocMap.set (mod_reset m) (ZToValue 0)
              (AssocMap.set (mod_finish m) (ZToValue 0)
               (AssocMap.set (mod_st m) (posToValue m.(mod_entrypoint))
                (init_regs args m.(mod_params)))))
             (empty_stack m))
| step_return :
    forall g m asr asa i r sf pc mst,
      mst = mod_st m ->
      step g (Returnstate (Stackframe r m pc asr asa :: sf) i) Events.E0
           (State sf m pc ((asr # mst <- (posToValue pc)) # r <- i) asa).
Hint Constructors step : htl.

Inductive initial_state (p: program): state -> Prop :=
  | initial_state_intro: forall b m0 m,
      let ge := Globalenvs.Genv.globalenv p in
      Globalenvs.Genv.init_mem p = Some m0 ->
      Globalenvs.Genv.find_symbol ge p.(AST.prog_main) = Some b ->
      Globalenvs.Genv.find_funct_ptr ge b = Some (AST.Internal m) ->
      initial_state p (Callstate nil m nil).

Inductive final_state : state -> Integers.int -> Prop :=
| final_state_intro : forall retval retvali,
    retvali = valueToInt retval ->
    final_state (Returnstate nil retval) retvali.

Definition semantics (m : program) :=
  Smallstep.Semantics step (initial_state m) final_state
                      (Globalenvs.Genv.globalenv m).
