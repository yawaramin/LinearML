(*
Copyright (c) 2011, Julien Verlaguet
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:
1. Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the
distribution.

3. Neither the name of Julien Verlaguet nor the names of
contributors may be used to endorse or promote products derived
from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)
open Utils
open Nast

module Subst = struct

  let rec type_expr env (p, ty) = 
    match ty with
    | Tvar (_, x) when IMap.mem x env -> IMap.find x env
    | _ -> p, type_expr_ env ty

  and type_expr_ env = function
    | Tany
    | Tabstract
    | Tprim _ | Tpath _
    | Tid _ | Tvar _ as x -> x
    | Tapply (ty, tyl) -> 
	let tyl = List.map (type_expr env) tyl in
	Tapply (type_expr env ty, tyl)
    | Ttuple tyl -> Ttuple (List.map (type_expr env) tyl)
    | Tfun (fk, ty1, ty2) -> Tfun (fk, type_expr env ty1, type_expr env ty2)
    | Talgebric vl -> Talgebric (IMap.map (variant env) vl)
    | Trecord fdl -> Trecord (IMap.map (field env) fdl)
    | Tabbrev ty -> Tabbrev (type_expr env ty)
    | Tabs (vl, ty) ->
	let xl = List.map snd vl in
	let env = List.fold_right IMap.remove xl env in
	Tabs (vl, type_expr env ty)

  and variant env (id, ty_opt) = 
    id, match ty_opt with 
    | None -> None
    | Some ty -> Some (type_expr env ty)

  and field env (id, ty) = id, type_expr env ty
end

module Tuple = struct

  let rec type_expr_tuple ((p, _) as ty) = 
    match List.rev (snd (type_expr p (100, []) ty)) with
    | [x] -> x
    | l -> p, Ttuple l

  and type_expr pos (n, acc) (p, ty) = 
    let type_expr = type_expr pos in
    if n <= 0
    then Error.tuple_too_big pos 
    else match ty with
    | Tany
    | Tprim _
    | Tabstract
    | Tvar _ | Tid _ 
    | Tpath _ as x -> n-1, (p, x) :: acc
    | Ttuple tyl -> List.fold_left type_expr (n, acc) tyl
    | Tapply (ty, tyl) -> 
	let tyl = List.map type_expr_tuple tyl in
	n-1, (p, Tapply (ty, tyl)) :: acc

    | Tfun (fk, ty1, ty2) -> 
	let ty1 = type_expr_tuple ty1 in
	let ty2 = type_expr_tuple ty2 in
	n-1, (p, Tfun (fk, ty1, ty2)) :: acc

    | Talgebric vl -> n-1, (p, Talgebric (IMap.map variant vl)) :: acc
    | Trecord fdl -> n-1, (p, Trecord (IMap.map field fdl)) :: acc
    | Tabbrev ty -> type_expr (n, acc) ty
    | Tabs (idl, ty) -> 
	let ty = type_expr_tuple ty in
	n-1, (p, Tabs (idl, ty)) :: acc

  and variant (id, ty_opt) = 
    match ty_opt with
    | None -> id, None
    | Some ty -> id, Some (type_expr_tuple ty)

  and field (id, ty) = id, type_expr_tuple ty

end

module Abbrevs: sig

  val program: Nast.program -> Nast.program
end = struct

  let check_abs id (p, ty) = 
    match ty with
    | Tabs (idl, _) -> Error.type_expects_arguments id (List.length idl) p
    | _ -> ()

  let rec program p = 
    let abbr = NastCheck.Abbrev.check p in
    let abbr = IMap.fold (fun _ x acc -> IMap.fold IMap.add x acc) abbr IMap.empty in
    let _, p = lfold (module_ abbr) IMap.empty p in
    p

  and module_ abbr mem md = 
    let mem, decls = lfold (decl abbr) mem md.md_decls in
    mem, { md with md_decls = decls }

  and decl abbr mem = function
    | Dtype tdl -> 
	let mem, tdl = List.fold_left (type_def abbr) (mem, []) tdl in
	mem, Dtype tdl 

    | Dval (ll, id, ty, x) -> 
	let mem, ty = type_expr abbr mem ty in
	let ty = Tuple.type_expr_tuple ty in
	mem, Dval (ll, id, ty, x)

  and type_def abbr (mem, acc) (id, ty) = 
    let mem, ty = type_expr abbr mem ty in
    let ty = Tuple.type_expr_tuple ty in
    if IMap.mem (snd id) abbr
    then mem, acc
    else mem, (id, ty) :: acc

  and type_expr abbr mem (p, ty) = 
    let mem, ty = type_expr_ abbr mem p ty in
    mem, (p, ty)

  and type_expr_ abbr mem p = function
    | Tany
    | Tabstract
    | Tprim _ | Tvar _ as x -> mem, x 

    | (Tpath (_, (_, x)) 
    | Tid (_, x)) when IMap.mem x mem -> 
	mem, snd (IMap.find x mem)

    | (Tpath (_, ((_, x) as id)) 
    | Tid ((_, x) as id)) when IMap.mem x abbr ->
	let mem, ty = type_expr abbr mem (IMap.find x abbr) in
	let mem = IMap.add x ty mem in
	check_abs id ty ;
	mem, (snd ty)

    | Tpath _ | Tid _ as x -> mem, x

    | Tapply ((p, Tpath ((p1,_), (p2, x))), ty) when IMap.mem x abbr -> 
	let px = Pos.btw p1 p2 in
	type_expr_ abbr mem p (Tapply ((p, Tid (px, x)), ty))

    | Tapply ((p, Tid (px, x)), tyl) when IMap.mem x abbr -> 
	let mem, tyl = lfold (type_expr abbr) mem tyl in
	let pdef, _ as ty = IMap.find x abbr in
	let args, ty = match ty with _, Tabs (vl, ty) -> vl, ty
	| _ -> Error.not_expecting_arguments px x pdef in
	let mem, ty = type_expr abbr mem ty in
	let size1 = List.length tyl in
	let size2 = List.length args in
	if size1 <> size2
	then Error.type_arity px x size1 size2 pdef ;
	let args = List.map snd args in
	let subst = List.fold_right2 IMap.add args tyl IMap.empty in
	let ty = Subst.type_expr subst ty in
	mem, snd ty

    | Tapply (ty, tyl) -> 
	let mem, ty = type_expr abbr mem ty in
	let mem, tyl = lfold (type_expr abbr) mem tyl in
	mem, Tapply (ty, tyl)

    | Ttuple tyl -> 
	let mem, tyl = lfold (type_expr abbr) mem tyl in
	mem, Ttuple tyl

    | Tfun (fk, ty1, ty2) -> 
	let mem, ty1 = type_expr abbr mem ty1 in
	let mem, ty2 = type_expr abbr mem ty2 in
	mem, Tfun (fk, ty1, ty2)

    | Talgebric vl -> 
	let mem, vl = imlfold (variant abbr) mem vl in
	mem, Talgebric vl 

    | Trecord fdl -> 
	let mem, fdl = imlfold (field abbr) mem fdl in
	mem, Trecord fdl 

    | Tabbrev ty -> 
	let mem, ty = type_expr abbr mem ty in
	mem, snd ty

    | Tabs (idl, ty) -> 
	let mem, ty = type_expr abbr mem ty in
	mem, Tabs (idl, ty)

  and variant abbr mem (id, ty_opt) = 
    match ty_opt with
    | None -> mem, (id, None)
    | Some ty -> 
	let mem, ty = type_expr abbr mem ty in
	mem, (id, Some ty)

  and field abbr mem (id, ty) = 
    let mem, ty = type_expr abbr mem ty in
    mem, (id, ty)

end

module Pat: sig

  val pat: Nast.pat -> Pos.t * (Pos.t * Nast.pat list) list

end = struct
  open Nast

  let append l1 l2 =
    List.map (fun x -> l1 @ x) l2

  let rec combine l1 l2 = 
    List.fold_right (fun x acc -> 
      append x l2 @ acc) l1 []

  let check b1 b2 = 
    match b1, b2 with
    | [], _ | _, [] -> assert false
    | x1 :: _, x2 :: _ -> 
	(* We don't have to check the rest of the list by construction *)
	let n1 = List.length x1 in
	let n2 = List.length x2 in
	if n1 <> n2
	then 
	  let p1, _ = Pos.list x1 in
	  let p2, _ = Pos.list x2 in
	  Error.pbar_arity p1 n1 p2 n2
	else ()

  let rec pat l = 
    match l with
    | [] -> [[]]
    | (_, Pbar (b1, b2)) :: rl -> 
	let rl = pat rl in
	let b1 = pat [b1] in
	let b2 = pat [b2] in
	check b1 b2 ;
	combine b1 rl @ combine b2 rl
    | (_, Ptuple l) :: rl ->
	let rl = pat rl in
	let l = List.map (fun x -> pat [x]) l in
	List.fold_right combine l rl 
    | x :: rl -> 
	let rl = pat rl in
	append [x] rl

  let add_pos l = 
    Pos.list (List.map Pos.list l)

  let pat p = 
    add_pos (pat [p])
	  
end


let rec program mdl = 
  let mdl = Abbrevs.program mdl in
  List.map module_ mdl

and module_ md = {
  Neast.md_sig = md.md_sig ;
  Neast.md_id = md.md_id ;
  Neast.md_decls = List.fold_left decl [] md.md_decls ;
  Neast.md_defs = List.map (def) md.md_defs ;
}

and decl acc = function
  | Dtype tdl -> List.fold_left tdef acc tdl
  | Dval (ll, x, (_, Tabs (_, ty)), v)
  | Dval (ll, x, ty, v) -> 
      match type_expr ty with
      | _, Neast.Tfun _ as ty -> Neast.Dval (ll, x, ty, v) :: acc
      | p, _ -> Error.expected_function p

and tdef acc (id, (p, ty)) = 
  match ty with
  | Tabstract -> Neast.Dabstract (id, []) :: acc
  | Tabs (idl, (_, Tabstract)) -> Neast.Dabstract (id, idl) :: acc
  | Talgebric vm -> algebric acc id [] vm
  | Tabs (idl, (_, Talgebric vm)) -> algebric acc id idl vm
  | Trecord fdm -> record acc id [] fdm
  | Tabs (idl, (_, Trecord fdm)) -> record acc id idl fdm
  | _ -> assert false

and algebric acc id idl vm =
  let vm = IMap.map variant vm in
  Neast.Dalgebric (new_tdef id idl vm) :: acc

and record acc id idl fdm = 
  let fdm = IMap.map field fdm in
  Neast.Drecord (new_tdef id idl fdm) :: acc

and new_tdef id idl tm = {
    Neast.td_id = id ;
    Neast.td_args = idl ;
    Neast.td_map  = tm ;
  }

and type_expr (p, ty) = p, type_expr_ ty
and type_expr_ = function
  | Tany -> Neast.Tany
  | Tabstract -> assert false
  | Tprim t -> Neast.Tprim t
  | Tvar (p, x) -> Neast.Tvar (p, x)
  | Tid x -> Neast.Tid x 
  | Tapply ((_, Tpath (md, x)), tyl) -> 
      let p, tyl = Pos.list tyl in
      let tyl = List.map type_expr tyl in
      let tyl = p, tyl in
      Neast.Tapply (x, tyl)
  | Tapply ((_, Tid x), tyl) -> 
      let p, tyl = Pos.list tyl in
      let tyl = List.map type_expr tyl in
      let tyl = p, tyl in
      Neast.Tapply (x, tyl)
  | Tapply ((p, _), _) -> Error.bad_type_app p
  | Tpath (x, y) -> 
      Neast.Tid y
  | Tfun (fk, ty1, ty2) -> 
      let ty1 = type_expr_tuple ty1 in
      let ty2 = type_expr_tuple ty2 in
      Neast.Tfun (fk, ty1, ty2)
  | Ttuple _ 
  | Talgebric _ 
  | Trecord _ 
  | Tabbrev _ 
  | Tabs _ -> assert false

and variant (x, ty) =
  x, match ty with
  | None -> fst x, []
  | Some ty -> type_expr_tuple ty

and field (x, ty) = 
  x, type_expr_tuple ty

and type_expr_tuple ((p, ty_) as ty) = 
  p, match ty_ with
  | Ttuple l -> (List.map type_expr l)
  | _ -> [type_expr ty]

and def (id, p, e) = 
  let e = tuple e in 
  let pl = pat_list p in
  id, pl, e

and tpat (p, ty) = pat_pos p, type_expr ty

and pat_list pl = 
  let pos, pl = Pos.list pl in
  pat (pos, Ptuple pl)

and pat p =
  let pos, p = Pat.pat p in
  pos, List.map (pat_bar pos) p

and pat_bar pos (_, x) = pos, List.map pat_pos x

and pat_pos (p, x) = p, pat_ x
and pat_ = function
  | Pvalue v -> Neast.Pvalue v
  | Pany -> Neast.Pany
  | Pid x -> Neast.Pid x
  | Pcstr x 
  | Pecstr (_, x) -> 
      Neast.Pvariant (x, (fst x, []))
  | Pevariant (_, x, p)
  | Pvariant (x, p) -> 
      Neast.Pvariant (x, pat p)
  | Precord pfl -> Neast.Precord (List.map pat_field pfl)
  | Pas (x, p) -> Neast.Pas (x, pat p)
  | Pbar _ -> assert false
  | Ptuple _ -> assert false

and pat_field (p, pf) = p, pat_field_ pf
and pat_field_ = function
  | PFany -> Neast.PFany
  | PFid x -> Neast.PFid x
  | PField (x, p) -> Neast.PField (x, pat p)

and tuple ((p, _) as e) = 
  p, expr e []

and expr (p, e) acc = 
  match e with
  | Etuple l -> List.fold_right expr l acc
  | _ -> (p, expr_ p e) :: acc

and expr_ p = function
  | Evalue v -> Neast.Evalue v
  | Eid x -> Neast.Eid x
  | Ecstr x -> Neast.Evariant (x, (p, []))
  | Efield (e, x) -> 
      let e = simpl_expr e in
      Neast.Efield (e, x)
  | Ebinop (bop, e1, e2) ->
      let e1 = simpl_expr e1 in
      let e2 = simpl_expr e2 in
      Neast.Ebinop (bop, e1, e2)
  | Euop (uop, e) ->
      let e = simpl_expr e in
      Neast.Euop (uop, e)
  | Etuple _ -> assert false
  | Erecord fdl -> 
      let fdl = List.map (fun (x, e) -> x, tuple e) fdl in
      Neast.Erecord fdl
  | Ewith (e, fdl) -> 
      let e = simpl_expr e in
      let fdl = List.map (fun (x, e) -> x, tuple e) fdl in
      Neast.Ewith (e, fdl)
  | Elet (p, e1, e2) -> 
      let p = pat p in
      let e1 = tuple e1 in
      let e2 = tuple e2 in
      Neast.Elet (p, e1, e2)
  | Eif (e1, e2, e3) -> 
      let e1 = simpl_expr e1 in
      let e2 = tuple e2 in
      let e3 = tuple e3 in
      Neast.Eif (e1, e2, e3)
  | Efun (k, obs, il, el) -> 
      let il = List.map (fun (x, ty) -> pat_pos x, type_expr ty) il in
      let el = tuple el in
      Neast.Efun (k, obs, il, el)
  | Eapply (e, el) -> 
      let p, el = Pos.list el in
      let el = List.fold_right expr el [] in
      apply (simpl_expr e) (p, el)
  | Epartial el -> 
      let f = simpl_expr (List.hd el) in
      let el = List.tl el in
      if List.length el = 0
      then Error.not_enough_args p ;
      let p, el = Pos.list el in
      let el = List.fold_right expr el [] in
      Neast.Epartial (f, (p, el))
  | Ematch (e, pel) -> 
      let e = tuple e in
      let pel = List.map (fun (p, e) -> pat p, tuple e) pel in
      Neast.Ematch (e, pel)
  | Eseq (e1, e2) -> 
      let e1 = simpl_expr e1 in
      let e2 = tuple e2 in
      Neast.Eseq (e1, e2)
  | Eobs x -> Neast.Eobs x
  | Efree x -> Neast.Efree x

and simpl_expr ((p, _) as e) = 
  match expr e [] with
  | [e] -> e
  | _ -> Error.no_tuple p 

and apply e1 e2 = 
  match snd e1 with
  | Neast.Evariant (x, (_, [])) -> Neast.Evariant (x, e2)
  | Neast.Evariant _ -> assert false
  | Neast.Eid id -> Neast.Eapply (id, e2)
  | e1_ -> 
      let x = Ident.make "fun" in
      let p = fst e1 in
      let e1 = p, [p, e1_] in
      let pat = (p, [p, [p, Neast.Pid (p, x)]]) in
      Neast.Elet (pat, e1, (p, [p, Neast.Eapply ((p, x), e2)]))
