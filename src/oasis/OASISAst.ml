
(** AST manipulation
    @author Sylvain Le Gall
  *)

open OASISTypes;;
open OASISAstTypes;;
open OASISUtils;;

type 'a acc_sections_t =
    {
      execs:      (name * executable) list;
      libs:       (name * library) list;
      flags:      (name * flag) list;
      src_repos:  (name * source_repository) list;
      tests:      (name * test) list;
    }
;;

(** Convert oasis AST into package 
  *)
let to_package fn ignore_unknown srcdir ast = 

  let default_ctxt =
    {
      oasisfn     = fn;
      srcdir      = Filename.dirname fn;
      cond        = None;
      valid_flags = [];
    }
  in

  (* Convert flags into ctxt *)
  let ctxt_of_flags flags =
    {default_ctxt with 
         valid_flags = List.map fst flags}
  in

  (* Merge an expression with a condition in a ctxt *)
  let ctxt_add_expr ctxt e =
    match ctxt with 
      | {cond = None} ->
          {ctxt with cond = Some e}
      | {cond = Some e'} ->
          {ctxt with cond = Some (EAnd (e', e))}
  in

  (* Explore statement, at this level it is possible that value
   * depends from condition (if expression is possible
   *)
  let rec stmt schm data ctxt =
    function
      | SField (nm, str) -> 
          (
            try
              PropList.Schema.set schm data nm ~context:ctxt str
            with (PropList.Unknown_field _) as exc ->
              if OASISPlugin.test_field_name nm && ignore_unknown then
                ()
              else
                raise exc
          )

      | SIfThenElse (e, stmt1, stmt2) -> 
          (* Check that we have a valid expression *)
          OASISExpr.check ctxt e;
          (* Explore if branch *)
          stmt 
            schm
            data
            (ctxt_add_expr ctxt e)
            stmt1;
          (* Explore then branch *)
          stmt 
            schm
            data 
            (ctxt_add_expr ctxt (ENot e))
            stmt2

      | SBlock blk ->
          List.iter (stmt schm data ctxt) blk
  in

  (* Explore statement and register data into a newly created
   * Schema.writer.
   *)
  let schema_stmt gen nm schm flags stmt' = 
    let data =
      PropList.Data.create ()
    in
    let ctxt =
      ctxt_of_flags flags
    in
      stmt schm data ctxt stmt';
      OASISCheck.check_schema schm data;
      gen nm data
  in

  (* Recurse into top-level statement. At this level there is 
   * no conditional expression but there is Flag, Library and
   * Executable structure defined.
   *) 
  let rec top_stmt pkg_data acc =
    function
      | TSLibrary (nm, stmt) -> 
          let lib = 
            schema_stmt 
              OASISLibrary.generator
              nm
              OASISLibrary.schema 
              acc.flags 
              stmt
          in
            {acc with libs = (nm, lib) :: acc.libs}

      | TSExecutable (nm, stmt) -> 
          let exec =
            schema_stmt
              OASISExecutable.generator
              nm
              OASISExecutable.schema
              acc.flags
              stmt
          in
            {acc with execs = (nm, exec) :: acc.execs}

      | TSFlag (nm, stmt) -> 
          let flag =
            schema_stmt 
              OASISFlag.generator 
              nm
              OASISFlag.schema 
              acc.flags
              stmt
          in
            {acc with flags = (nm, flag) :: acc.flags}

      | TSSourceRepository (nm, stmt) ->
          let src_repo =
            schema_stmt
              OASISSourceRepository.generator
              nm
              OASISSourceRepository.schema
              acc.flags
              stmt
          in
            {acc with src_repos = (nm, src_repo) :: acc.src_repos}

      | TSTest (nm, stmt) ->
          let test =
            schema_stmt
              OASISTest.generator
              nm
              OASISTest.schema
              acc.flags
              stmt
          in
            {acc with tests = (nm, test) :: acc.tests}

      | TSStmt stmt' -> 
          stmt 
            OASISPackage.schema
            pkg_data 
            (ctxt_of_flags acc.flags) 
            stmt';
          acc

      | TSBlock blk -> 
          List.fold_left 
            (top_stmt pkg_data) 
            acc 
            blk
  in

  (* Start with package schema/writer *)
  let data =
    PropList.Data.create ()
  in
  let acc =
    top_stmt 
      data
      {
        libs      = [];
        execs     = [];
        flags     = [];
        src_repos = [];
        tests     = [];
      }
      ast
  in
  let pkg = 
    OASISCheck.check_schema 
      OASISPackage.schema 
      data;
    OASISPackage.generator 
      data
      acc.libs 
      acc.execs 
      acc.flags 
      acc.src_repos
      acc.tests
  in

  (* Fix build depends to reflect internal dependencies *)
  let pkg = 
    (* Map of findlib name to internal libraries *)
    let internal_of_findlib =
      MapString.fold
        (fun k v acc -> MapString.add v k acc)
        (OASISLibrary.findlib_names pkg.libraries)
        MapString.empty
    in

    let map_internal_libraries what =
      List.map
        (function
           | (FindlibPackage (lnm, ver_opt)) as bd ->
               begin
                 try 
                   let lnm =
                     MapString.find lnm internal_of_findlib
                   in
                     if ver_opt <> None then
                       failwith 
                         (Printf.sprintf
                            "Cannot use versioned build depends \
                             on internal library %s in %s"
                            lnm
                            what);

                     InternalLibrary lnm

                 with Not_found ->
                   bd
               end
           | (InternalLibrary _) as bd ->
               bd)
    in
      {pkg with 
           libraries = 
             List.map 
               (fun (nm, lib) ->
                  nm,
                  {lib with 
                       lib_build_depends = 
                         map_internal_libraries
                           ("library "^nm)
                           lib.lib_build_depends})
               pkg.libraries;
           executables =
             List.map 
               (fun (nm, exec) ->
                  nm,
                  {exec with 
                       exec_build_depends =
                         map_internal_libraries
                           ("executable "^nm)
                           exec.exec_build_depends})
               pkg.executables}
  in
    (* TODO: check recursion and re-order library/tools using ocamlgraph *)
    pkg
;;

