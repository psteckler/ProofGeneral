(** * A Fancy Machine with 256-bit registers *)

Require Import Coq.Classes.RelationClasses Coq.Classes.Morphisms.
Require Export Coq.ZArith.ZArith.
Require Export Crypto.BoundedArithmetic.Interface.
Require Export Crypto.BoundedArithmetic.ArchitectureToZLike.
Require Export Crypto.BoundedArithmetic.ArchitectureToZLikeProofs.
Require Export Crypto.Util.Tuple.
Require Import Crypto.Util.Option Crypto.Util.Sigma Crypto.Util.Prod.
Require Import Crypto.Reflection.Named.Syntax.
Require Import Crypto.Reflection.Named.DeadCodeElimination.
Require Export Crypto.Reflection.Syntax.
Require Import Crypto.Reflection.Linearize.
Require Import Crypto.Reflection.Inline.
Require Import Crypto.Reflection.CommonSubexpressionElimination.
Require Export Crypto.Reflection.Reify.
Require Export Crypto.Util.ZUtil.
Require Export Crypto.Util.Notations.

Open Scope Z_scope.
Local Notation eta x := (fst x, snd x).
Local Notation eta3 x := (eta (fst x), snd x).
Local Notation eta3' x := (fst x, eta (snd x)).

(** ** Reflective Assembly Syntax *)
Section reflection.
  Context (ops : fancy_machine.instructions (2 * 128)).
  Local Set Boolean Equality Schemes.
  Local Set Decidable Equality Schemes.
  Inductive base_type := TZ | Tbool | TW.
  Definition interp_base_type (v : base_type) : Type :=
    match v with
    | TZ => Z
    | Tbool => bool
    | TW => fancy_machine.W
    end.
  Local Notation tZ := (Tbase TZ).
  Local Notation tbool := (Tbase Tbool).
  Local Notation tW := (Tbase TW).
  Local Open Scope ctype_scope.
  Inductive op : flat_type base_type -> flat_type base_type -> Type :=
  | OPldi     : op tZ tW
  | OPshrd    : op (tW * tW * tZ) tW
  | OPshl     : op (tW * tZ) tW
  | OPshr     : op (tW * tZ) tW
  | OPmkl     : op (tW * tZ) tW
  | OPadc     : op (tW * tW * tbool) (tbool * tW)
  | OPsubc    : op (tW * tW * tbool) (tbool * tW)
  | OPmulhwll : op (tW * tW) tW
  | OPmulhwhl : op (tW * tW) tW
  | OPmulhwhh : op (tW * tW) tW
  | OPselc    : op (tbool * tW * tW) tW
  | OPaddm    : op (tW * tW * tW) tW.

  Definition interp_op src dst (f : op src dst)
    : interp_flat_type_gen interp_base_type src -> interp_flat_type_gen interp_base_type dst
    := match f in op s d return interp_flat_type_gen _ s -> interp_flat_type_gen _ d with
       | OPldi     => ldi
       | OPshrd    => fun xyz => let '(x, y, z) := eta3 xyz in shrd x y z
       | OPshl     => fun xy => let '(x, y) := eta xy in shl x y
       | OPshr     => fun xy => let '(x, y) := eta xy in shr x y
       | OPmkl     => fun xy => let '(x, y) := eta xy in mkl x y
       | OPadc     => fun xyz => let '(x, y, z) := eta3 xyz in adc x y z
       | OPsubc    => fun xyz => let '(x, y, z) := eta3 xyz in subc x y z
       | OPmulhwll => fun xy => let '(x, y) := eta xy in mulhwll x y
       | OPmulhwhl => fun xy => let '(x, y) := eta xy in mulhwhl x y
       | OPmulhwhh => fun xy => let '(x, y) := eta xy in mulhwhh x y
       | OPselc    => fun xyz => let '(x, y, z) := eta3 xyz in selc x y z
       | OPaddm    => fun xyz => let '(x, y, z) := eta3 xyz in addm x y z
       end. // UNMATCHED !!

               Inductive SConstT := ZConst (_ : Z) | BoolConst (_ : bool) | INVALID_CONST.
  Inductive op_code : Set :=
  | SOPldi | SOPshrd | SOPshl | SOPshr | SOPmkl | SOPadc | SOPsubc
  | SOPmulhwll | SOPmulhwhl | SOPmulhwhh | SOPselc | SOPaddm.

  Definition symbolicify_const (t : base_type) : interp_base_type t -> SConstT
    := match t with
       | TZ => fun x => ZConst x
       | Tbool => fun x => BoolConst x
       | TW => fun x => INVALID_CONST
       end. // UNMATCHED !!
               Definition symbolicify_op s d (v : op s d) : op_code
              := match v with
	         | OPldi => SOPldi
	         | OPshrd => SOPshrd
	         | OPshl => SOPshl
	         | OPshr => SOPshr
	         | OPmkl => SOPmkl
	         | OPadc => SOPadc
	         | OPsubc => SOPsubc
	         | OPmulhwll => SOPmulhwll
	         | OPmulhwhl => SOPmulhwhl
	         | OPmulhwhh => SOPmulhwhh
	         | OPselc => SOPselc
	         | OPaddm => SOPaddm
	         end. // UNMATCHED !!

                         Definition CSE {t} e := @CSE base_type SConstT op_code base_type_beq SConstT_beq op_code_beq internal_base_type_dec_bl interp_base_type op symbolicify_const symbolicify_op t e (fun _ => nil).
End reflection. // UNMATCHED !!

		   Ltac base_reify_op op op_head ::=
		   lazymatch op_head with
		   | @Interface.ldi => constr:(reify_op op op_head 1 OPldi)
		   | @Interface.shrd => constr:(reify_op op op_head 3 OPshrd)
		   | @Interface.shl => constr:(reify_op op op_head 2 OPshl)
		   | @Interface.shr => constr:(reify_op op op_head 2 OPshr)
		   | @Interface.mkl => constr:(reify_op op op_head 2 OPmkl)
		   | @Interface.adc => constr:(reify_op op op_head 3 OPadc)
		   | @Interface.subc => constr:(reify_op op op_head 3 OPsubc)
		   | @Interface.mulhwll => constr:(reify_op op op_head 2 OPmulhwll)
		   | @Interface.mulhwhl => constr:(reify_op op op_head 2 OPmulhwhl)
		   | @Interface.mulhwhh => constr:(reify_op op op_head 2 OPmulhwhh)
		   | @Interface.selc => constr:(reify_op op op_head 3 OPselc)
		   | @Interface.addm => constr:(reify_op op op_head 3 OPaddm)
		   end. // UNMATCHED !!
                           Ltac base_reify_type T ::=
			   match T with
			   | Z => TZ
			   | bool => Tbool
			   | fancy_machine.W => TW
			   end. // UNMATCHED !!

                                   Ltac Reify' e := Reify.Reify' base_type (interp_base_type _) op e.
Ltac Reify e :=
  let v := Reify.Reify base_type (interp_base_type _) op e in
  constr:(CSE _ (InlineConst (Linearize v))).
(*Ltac Reify_rhs := Reify.Reify_rhs base_type (interp_base_type _) op (interp_op _).*)

(** ** Raw Syntax Trees *)
(** These are used solely for pretty-printing the expression tree in a
		      form that can be basically copy-pasted into other languages which
		      can be compiled for the Fancy Machine.  Hypothetically, we could
		      add support for custom named identifiers, by carrying around
		      [string] identifiers and using them for pretty-printing...  It
		      might also be possible to verify this layer, too, by adding a
		      partial interpretation function... *)

Local Set Decidable Equality Schemes.
Local Set Boolean Equality Schemes.

Inductive Register :=
| RegPInv | RegMod | RegMuLow | RegZero
| y | t1 | t2 | lo | hi | out | src1 | src2 | tmp | q | qHigh | x | xHigh
| scratch | scratchplus (n : nat).

Notation "'scratch+' n" := (scratchplus n) (format "'scratch+' n", at level 10).

Definition syntax {ops : fancy_machine.instructions (2 * 128)}
  := Named.expr base_type (interp_base_type ops) op Register.

(** Assemble a well-typed easily interpretable expression into a
		      syntax tree we can use for pretty-printing. *)
Section assemble.
  Context (ops : fancy_machine.instructions (2 * 128)).

  Definition postprocess var t (e : exprf (var:=var) base_type (interp_base_type _) op t)
    : @inline_directive base_type (interp_base_type _) op var t.

    refine match e in exprf _ _ _ t return inline_directive t with
	   | Op _ t (OPshl as op) _
	   | Op _ t (OPshr as op) _
	     => inline (t:=t) (Op op _)
	   | _ => _
	   end. // UNMATCHED !!
                   asdf

                   Definition AssembleSyntax : True.
    simple refine _.(** * A Fancy Machine with 256-bit registers *)
    Require Import Coq.Classes.RelationClasses Coq.Classes.Morphisms.
    Require Export Coq.ZArith.ZArith.
    Require Export Crypto.BoundedArithmetic.Interface.
    Require Export Crypto.BoundedArithmetic.ArchitectureToZLike.
    Require Export Crypto.BoundedArithmetic.ArchitectureToZLikeProofs.
    Require Export Crypto.Util.Tuple.
    Require Import Crypto.Util.Option Crypto.Util.Sigma Crypto.Util.Prod.
    Require Import Crypto.Reflection.Named.Syntax.
    Require Import Crypto.Reflection.Named.DeadCodeElimination.
    Require Export Crypto.Reflection.Syntax.
    Require Import Crypto.Reflection.Linearize.
    Require Import Crypto.Reflection.Inline.
    Require Import Crypto.Reflection.CommonSubexpressionElimination.
    Require Export Crypto.Reflection.Reify.
    Require Export Crypto.Util.ZUtil.
    Require Export Crypto.Util.Notations.

    Open Scope Z_scope.
    Local Notation eta x := (fst x, snd x).
    Local Notation eta3 x := (eta (fst x), snd x).
    Local Notation eta3' x := (fst x, eta (snd x)).

    (** ** Reflective Assembly Syntax *)
    Section reflection.
      Context (ops : fancy_machine.instructions (2 * 128)).
      Local Set Boolean Equality Schemes.
      Local Set Decidable Equality Schemes.
      Inductive base_type := TZ | Tbool | TW.
      Definition interp_base_type (v : base_type) : Type :=
	match v with
	| TZ => Z
	| Tbool => bool
	| TW => fancy_machine.W
	end. // UNMATCHED !!
                Local Notation tZ := (Tbase TZ).
      Local Notation tbool := (Tbase Tbool).
      Local Notation tW := (Tbase TW).
      Local Open Scope ctype_scope.
      Inductive op : flat_type base_type -> flat_type base_type -> Type :=
      | OPldi     : op tZ tW
      | OPshrd    : op (tW * tW * tZ) tW
      | OPshl     : op (tW * tZ) tW
      | OPshr     : op (tW * tZ) tW
      | OPmkl     : op (tW * tZ) tW
      | OPadc     : op (tW * tW * tbool) (tbool * tW)
      | OPsubc    : op (tW * tW * tbool) (tbool * tW)
      | OPmulhwll : op (tW * tW) tW
      | OPmulhwhl : op (tW * tW) tW
      | OPmulhwhh : op (tW * tW) tW
      | OPselc    : op (tbool * tW * tW) tW
      | OPaddm    : op (tW * tW * tW) tW.

      Definition interp_op src dst (f : op src dst)
	: interp_flat_type_gen interp_base_type src -> interp_flat_type_gen interp_base_type dst
	:= match f in op s d return interp_flat_type_gen _ s -> interp_flat_type_gen _ d with
	   | OPldi     => ldi
	   | OPshrd    => fun xyz => let '(x, y, z) := eta3 xyz in shrd x y z
	   | OPshl     => fun xy => let '(x, y) := eta xy in shl x y
	   | OPshr     => fun xy => let '(x, y) := eta xy in shr x y
	   | OPmkl     => fun xy => let '(x, y) := eta xy in mkl x y
	   | OPadc     => fun xyz => let '(x, y, z) := eta3 xyz in adc x y z
	   | OPsubc    => fun xyz => let '(x, y, z) := eta3 xyz in subc x y z
	   | OPmulhwll => fun xy => let '(x, y) := eta xy in mulhwll x y
	   | OPmulhwhl => fun xy => let '(x, y) := eta xy in mulhwhl x y
	   | OPmulhwhh => fun xy => let '(x, y) := eta xy in mulhwhh x y
	   | OPselc    => fun xyz => let '(x, y, z) := eta3 xyz in selc x y z
	   | OPaddm    => fun xyz => let '(x, y, z) := eta3 xyz in addm x y z
	   end. // UNMATCHED !!

                   Inductive SConstT := ZConst (_ : Z) | BoolConst (_ : bool) | INVALID_CONST.
      Inductive op_code : Set :=
      | SOPldi | SOPshrd | SOPshl | SOPshr | SOPmkl | SOPadc | SOPsubc
      | SOPmulhwll | SOPmulhwhl | SOPmulhwhh | SOPselc | SOPaddm.

      Definition symbolicify_const (t : base_type) : interp_base_type t -> SConstT
	:= match t with
	   | TZ => fun x => ZConst x
	   | Tbool => fun x => BoolConst x
	   | TW => fun x => INVALID_CONST
	   end. // UNMATCHED !!
                   Definition symbolicify_op s d (v : op s d) : op_code
                  := match v with
	             | OPldi => SOPldi
	             | OPshrd => SOPshrd
	             | OPshl => SOPshl
	             | OPshr => SOPshr
	             | OPmkl => SOPmkl
	             | OPadc => SOPadc
	             | OPsubc => SOPsubc
	             | OPmulhwll => SOPmulhwll
	             | OPmulhwhl => SOPmulhwhl
	             | OPmulhwhh => SOPmulhwhh
	             | OPselc => SOPselc
	             | OPaddm => SOPaddm
	             end. // UNMATCHED !!

                             Definition CSE {t} e := @CSE base_type SConstT op_code base_type_beq SConstT_beq op_code_beq internal_base_type_dec_bl interp_base_type op symbolicify_const symbolicify_op t e (fun _ => nil).
    End reflection. // UNMATCHED !!

		       Ltac base_reify_op op op_head ::=
		       lazymatch op_head with
		       | @Interface.ldi => constr:(reify_op op op_head 1 OPldi)
		       | @Interface.shrd => constr:(reify_op op op_head 3 OPshrd)
		       | @Interface.shl => constr:(reify_op op op_head 2 OPshl)
		       | @Interface.shr => constr:(reify_op op op_head 2 OPshr)
		       | @Interface.mkl => constr:(reify_op op op_head 2 OPmkl)
		       | @Interface.adc => constr:(reify_op op op_head 3 OPadc)
		       | @Interface.subc => constr:(reify_op op op_head 3 OPsubc)
		       | @Interface.mulhwll => constr:(reify_op op op_head 2 OPmulhwll)
		       | @Interface.mulhwhl => constr:(reify_op op op_head 2 OPmulhwhl)
		       | @Interface.mulhwhh => constr:(reify_op op op_head 2 OPmulhwhh)
		       | @Interface.selc => constr:(reify_op op op_head 3 OPselc)
		       | @Interface.addm => constr:(reify_op op op_head 3 OPaddm)
		       end. // UNMATCHED !!
                               Ltac base_reify_type T ::=
			       match T with
			       | Z => TZ
			       | bool => Tbool
			       | fancy_machine.W => TW
			       end. // UNMATCHED !!

                                       Ltac Reify' e := Reify.Reify' base_type (interp_base_type _) op e.
    Ltac Reify e :=
      let v := Reify.Reify base_type (interp_base_type _) op e in
      constr:(CSE _ (InlineConst (Linearize v))).
    (*Ltac Reify_rhs := Reify.Reify_rhs base_type (interp_base_type _) op (interp_op _).*)

    (** ** Raw Syntax Trees *)
    (** These are used solely for pretty-printing the expression tree in a
		      form that can be basically copy-pasted into other languages which
		      can be compiled for the Fancy Machine.  Hypothetically, we could
		      add support for custom named identifiers, by carrying around
		      [string] identifiers and using them for pretty-printing...  It
		      might also be possible to verify this layer, too, by adding a
		      partial interpretation function... *)

    Local Set Decidable Equality Schemes.
    Local Set Boolean Equality Schemes.

    Inductive Register :=
    | RegPInv | RegMod | RegMuLow | RegZero
    | y | t1 | t2 | lo | hi | out | src1 | src2 | tmp | q | qHigh | x | xHigh
    | scratch | scratchplus (n : nat).

    Notation "'scratch+' n" := (scratchplus n) (format "'scratch+' n", at level 10).

    Definition syntax {ops : fancy_machine.instructions (2 * 128)}
      := Named.expr base_type (interp_base_type ops) op Register.

    (** Assemble a well-typed easily interpretable expression into a
		      syntax tree we can use for pretty-printing. *)
    Section assemble.
      Context (ops : fancy_machine.instructions (2 * 128)).

      Definition postprocess var t (e : exprf (var:=var) base_type (interp_base_type _) op t)
	: @inline_directive base_type (interp_base_type _) op var t.

	refine match e in exprf _ _ _ t return inline_directive t with
	       | Op _ t (OPshl as op) _
	       | Op _ t (OPshr as op) _
		 => inline (t:=t) (Op op _)
	       | _ => _
	       end. // UNMATCHED !!
                       asdf

                       Definition AssembleSyntax : True.
        simple refine _.
