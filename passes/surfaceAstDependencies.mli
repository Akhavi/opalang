(*
    Copyright © 2011 MLstate

    This file is part of OPA.

    OPA is free software: you can redistribute it and/or modify it under the
    terms of the GNU Affero General Public License, version 3, as published by
    the Free Software Foundation.

    OPA is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for
    more details.

    You should have received a copy of the GNU Affero General Public License
    along with OPA. If not, see <http://www.gnu.org/licenses/>.
*)
(*
    @author Rudy Sicard
**)


val reorder_toplevel :
  ?roots:(Ident.t list) ->
  (?roots:(int list) -> (int * IntSet.t) list -> (int * bool * IntSet.t) list * 'a) ->
  (Ident.t, SurfaceAst.dependency_directive) SurfaceAst.code ->
  (Ident.t, SurfaceAst.dependency_directive) SurfaceAst.code

val rewrite_modules :
  ((int * IntSet.t) list -> (int * bool * IntSet.t) list * 'a) ->
  (Ident.t, SurfaceAst.dependency_directive) SurfaceAst.code ->
  (Ident.t, SurfaceAst.basic_directive) SurfaceAst.code
