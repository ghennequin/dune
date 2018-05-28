open Import
open Build.O

module CC = Compilation_context
module SC = Super_context

module Dep_graph = struct
  type t =
    { dir        : Path.t
    ; per_module : (unit, Module.t list) Build.t Module.Name.Map.t
    }

  let deps_of t (m : Module.t) =
    match Module.Name.Map.find t.per_module m.name with
    | Some x -> x
    | None ->
      Exn.code_error "Ocamldep.Dep_graph.deps_of"
        [ "dir", Path.sexp_of_t t.dir
        ; "modules", Sexp.To_sexp.(list Module.Name.t)
                       (Module.Name.Map.keys t.per_module)
        ; "module", Module.Name.t m.name
        ]

  let top_closed t modules =
    Build.all
      (List.map (Module.Name.Map.to_list t.per_module) ~f:(fun (unit, deps) ->
         deps >>^ fun deps -> (unit, deps)))
    >>^ fun per_module ->
    let per_module = Module.Name.Map.of_list_exn per_module in
    match
      Module.Name.Top_closure.top_closure modules
        ~key:Module.name
        ~deps:(fun m ->
          Option.value_exn (Module.Name.Map.find per_module (Module.name m)))
    with
    | Ok modules -> modules
    | Error cycle ->
      die "dependency cycle between modules in %s:\n   %a"
        (Path.to_string t.dir)
        (Fmt.list ~pp_sep:Fmt.nl (Fmt.prefix (Fmt.string "-> ") Module.Name.pp))
        (List.map cycle ~f:Module.name)

  let top_closed_implementations t modules =
    Build.memoize "top sorted implementations" (
      let filter_out_intf_only = List.filter ~f:Module.has_impl in
      top_closed t (filter_out_intf_only modules)
      >>^ filter_out_intf_only)

  let dummy (m : Module.t) =
    { dir = Path.root
    ; per_module = Module.Name.Map.singleton m.name (Build.return [])
    }
end

module Dep_graphs = struct
  type t = Dep_graph.t Ml_kind.Dict.t

  let dummy m =
    Ml_kind.Dict.make_both (Dep_graph.dummy m)
end

let parse_module_names ~(unit : Module.t) ~modules words =
  List.filter_map words ~f:(fun m ->
    let m = Module.Name.of_string m in
    if m = unit.name then
      None
    else
      Module.Name.Map.find modules m)

let is_alias_module cctx (m : Module.t) =
  match CC.alias_module cctx with
  | None -> false
  | Some alias -> alias.name = m.name

let parse_deps cctx ~file ~unit lines =
  let dir                  = CC.dir                  cctx in
  let alias_module         = CC.alias_module         cctx in
  let lib_interface_module = CC.lib_interface_module cctx in
  let modules              = CC.modules              cctx in
  let invalid () =
    die "ocamldep returned unexpected output for %s:\n\
         %s"
      (Path.to_string_maybe_quoted file)
      (String.concat ~sep:"\n"
         (List.map lines ~f:(sprintf "> %s")))
  in
  match lines with
  | [] | _ :: _ :: _ -> invalid ()
  | [line] ->
    match String.index line ':' with
    | None -> invalid ()
    | Some i ->
      let basename =
        String.sub line ~pos:0 ~len:i
        |> Filename.basename
      in
      if basename <> Path.basename file then invalid ();
      let deps =
        String.extract_blank_separated_words
          (String.sub line ~pos:(i + 1) ~len:(String.length line - (i + 1)))
        |> parse_module_names ~unit ~modules
      in
      (match lib_interface_module with
       | None -> ()
       | Some (m : Module.t) ->
         if unit.name <> m.name && not (is_alias_module cctx unit) &&
            List.exists deps ~f:(fun x -> Module.name x = m.name) then
           die "Module %a in directory %s depends on %a.\n\
                This doesn't make sense to me.\n\
                \n\
                %a is the main module of the library and is \
                the only module exposed \n\
                outside of the library. Consequently, it should \
                be the one depending \n\
                on all the other modules in the library."
             Module.Name.pp unit.name (Path.to_string dir)
             Module.Name.pp m.name
             Module.Name.pp m.name);
      match alias_module with
      | None -> deps
      | Some m -> m :: deps

let deps_of cctx ~ml_kind ~already_used unit =
  let sctx = CC.super_context cctx in
  let dir  = CC.dir           cctx in
  if is_alias_module cctx unit then
    Build.return []
  else
    match Module.file ~dir unit ml_kind with
    | None -> Build.return []
    | Some file ->
      let all_deps_path file =
        Path.extend_basename file ~suffix:".all-deps"
      in
      let context = SC.context sctx in
      let all_deps_file = all_deps_path file in
      let ocamldep_output = Path.extend_basename file ~suffix:".d" in
      if not (Module.Name.Set.mem already_used unit.name) then
        begin
          SC.add_rule sctx
            ( Build.run ~context (Ok context.ocamldep)
                [A "-modules"; Ml_kind.flag ml_kind; Dep file]
                ~stdout_to:ocamldep_output
            );
          let build_paths dependencies =
            let dependency_file_path m =
              let path =
                if is_alias_module cctx m then
                  None
                else
                  match Module.file ~dir m Ml_kind.Intf with
                  | Some _ as x -> x
                  | None -> Module.file ~dir m Ml_kind.Impl
              in
              Option.map path ~f:all_deps_path
            in
            List.filter_map dependencies ~f:dependency_file_path
          in
          SC.add_rule sctx
            ( Build.lines_of ocamldep_output
              >>^ parse_deps cctx ~file ~unit
              >>^ (fun modules ->
                (build_paths modules,
                 List.map modules ~f:(fun m ->
                   Module.Name.to_string (Module.name m))
                ))
              >>> Build.merge_files_dyn ~target:all_deps_file)
        end;
      Build.memoize (Path.to_string all_deps_file)
        ( Build.lines_of all_deps_file
          >>^ parse_module_names ~unit ~modules:(CC.modules cctx))

let rules_generic ?(already_used=Module.Name.Set.empty) cctx ~modules =
  Ml_kind.Dict.of_func
    (fun ~ml_kind ->
      let per_module =
        Module.Name.Map.map modules
          ~f:(deps_of cctx ~already_used ~ml_kind)
      in
      { Dep_graph.
        dir = CC.dir cctx
      ; per_module
      })

let rules ?already_used cctx =
  rules_generic ?already_used cctx ~modules:(CC.modules cctx)

let rules_for_auxiliary_module cctx (m : Module.t) =
  rules_generic cctx ~modules:(Module.Name.Map.singleton m.name m)
