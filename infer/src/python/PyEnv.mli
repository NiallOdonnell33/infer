(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module T = Textual

module Builtin : sig
  type textual =
    | IsTrue
    | BinaryAdd
    | PythonCall
    | PythonCallMethod
    | PythonClass
    | PythonClassConstructor
    | PythonCode
    | PythonIter
    | PythonIterNext
    | PythonLoadMethod
  [@@deriving compare]
end

module BuiltinSet : sig
  (** This module keeps track of the builtins used by a code unit. Only the necessary Textual
      declarations are generated. Note that primitive wrappers are always generated ([python_int],
      ...) *)
  type t

  val to_textual : t -> Textual.Module.decl list
  (** Encode a set of builtin declarations into Textual declarations *)
end

(** In Python, everything is an object, and the interpreter maintains a stack of references to such
    objects. Pushing and popping on the stack are always references to objets that leave in a heap.
    There is no need to model this heap, but the data stack is quite important. *)
module DataStack : sig
  type cell =
    | Const of int  (** index in [co_consts] *)
    | Name of int  (** reference to a global name, stored in [co_names] *)
    | VarName of int  (** reference to a local name, stored in [co_varnames] *)
    | Temp of T.Ident.t  (** SSA variable *)
    | Code of {fun_or_class: bool; qualified_name: string; code: FFI.Code.t}
        (** [code] Python object with its qualified name. It can be a function, class, closure, ... *)
    | Map of (string * cell) list
        (** Light encoding of raw Python tuples/dicts. Only used for type annotations at the moment. *)
    | BuiltinBuildClass  (** see Python's [LOAD_BUILD_CLASS] *)
  [@@deriving show]

  val as_code : FFI.Code.t -> cell -> FFI.Code.t option

  type t = cell list
end

(** Type information about various entities (toplevel declarations, temporaries, ...). *)
type info =
  { is_code: bool  (** is the entity a function / method ? *)
  ; is_class: bool  (** is the entity a class ? *)
  ; typ: T.Typ.t  (** Type annotation, if any (otherwise, [object] is used) *) }

module SMap : Caml.Map.S with type key = string

(** Fully expanded name of a symbol *)
type qualified_name = {value: string; loc: T.Location.t}

(** Information about symbols to correct do the translation to Textual's qualified names *)
type symbol_info = {qualified_name: qualified_name; is_builtin: bool; info: info}

(** Global environment used during bytecode processing. Stores common global information like the
    toplevel symbols processed so far, or more local ones like the set of labels or variable ids
    currently used by a declaration. *)
type t

module Label : sig
  (** Information about a "yet to reach" label location, with its name, type of ssa parameters, and
      a function to update the environment before processing the code after the label. For example,
      inserting some pruning operations before the label and the code. Since we don't always know
      the location of the label before-hand, the [prelude] is expecting one.

      We also keep track of the label status: if we already [processed] it within the [nodes]
      function. This is to avoid infinite loops. *)
  type info

  val mk : ?ssa_parameters:T.Typ.t list -> ?prelude:(T.Location.t -> t -> t) -> string -> info
  (** Create a [label_info] with the provided arguments. Mostly used with the defaults *)

  val update_ssa_parameters : info -> T.Typ.t list -> info
  (** Update the [ssa_parameters] of a label *)

  val is_processed : info -> bool
  (** Returns true iff the label was already encountered during processing *)

  val name : info -> string
  (** Returns the [name] of a label *)

  val to_textual : t -> T.Location.t -> info -> t * string * (T.Ident.t * T.Typ.t) list
  (** Process a label [info] and turn it into Textual information *)
end

val empty : t

val loc : t -> T.Location.t
(** Return the last recorded line information from the Python code-unit, if any. *)

val stack : t -> DataStack.t
(** Returns the [DataStack.t] for the current declaration *)

val globals : t -> symbol_info SMap.t
(** Return the [globals] map *)

val builtins : t -> BuiltinSet.t
(** Return the [builtins] map *)

val instructions : t -> T.Instr.t list
(** Returns the list of all instructions recorded for the current code unit *)

val label_of_offset : t -> int -> Label.info option
(** Check if the instruction is a possible jump location, and return the label information found
    there, if any. *)

val mk_fresh_ident : t -> info -> t * T.Ident.t
(** Generate a fresh temporary name *)

val get_ident_info : t -> T.Ident.t -> info option
(** Get back the information of a temporary *)

val mk_fresh_label : t -> t * string
(** Generate a fresh label name *)

val map : f:(t -> 'a -> t * 'b) -> env:t -> 'a list -> t * 'b list
(** Similar to [List.map] but an [env] is threaded along the way *)

val enter_proc : is_toplevel:bool -> t -> t
(** Set the environment when entering a new code unit (like reset the instruction buffer, or
    id/label generators. *)

val enter_node : t -> t
(** Set the environment when entering a new node. Reset the [instructions] buffer. *)

val reset_stack : t -> t
(** Reset the [stack] field of a [node] *)

val update_last_line : t -> int option -> t
(** Update the [last_line] field of an env, if new information is availbe. *)

val push : t -> DataStack.cell -> t
(** Push a new [DataStack.cell] on the datastack *)

val pop : t -> (t * DataStack.cell) option
(** Pop a [DataStack.cell] from the datastack, if any is available *)

val push_instr : t -> T.Instr.t -> t
(** Record a new instruction for the current code unit *)

val register_label : offset:int -> Label.info -> t -> t
(** Register the fact that a new label [info] must be inserted before the instruction at [offset] *)

val process_label : offset:int -> Label.info -> t -> t
(** Mark the label [info] at [offset] as processed *)

val register_symbol : t -> global:bool -> string -> qualified_name -> info -> t
(** Register a name (function, variable, ...). It might be a [global] symbol at the module level or
    in a local object. *)

val lookup_symbol : t -> global:bool -> string -> symbol_info option
(** Lookup information about a global/local symbol previously registered via [register_symbol] *)

val register_call : t -> string -> t
(** Register a function call. It enables us to deal correctly with builtin declaration. *)

val mk_builtin_call : t -> Builtin.textual -> T.Exp.t list -> t * T.Ident.t * T.Typ.t
(** Wrapper to compute the Textual version of a call to a "textual" builtin * function (a builtin we
    introduced for modeling purpose) *)

val register_function : t -> string -> T.Location.t -> PyCommon.annotated_name list -> t
(** Register a function declaration. We keep track of them since they might shadow Python builtins
    or previous definitions *)

val register_method :
  t -> enclosing_class:string -> method_name:string -> PyCommon.annotated_name list -> t
(** Register a method declaration. We mostly keep track of their signatures *)

val lookup_signature : t -> T.enclosing_class -> T.ProcName.t -> PyCommon.annotated_name list option
(** Lookup the signature of a function / method *)

val register_class : t -> string -> t
(** Register a class declaration (based on [LOAD_BUILD_CLASS]) *)

val get_classes : t -> string list
(** Get back the list of registered classes *)

val is_toplevel : t -> bool
(** Are we processing top level instructions, or something in a function/class ? *)
